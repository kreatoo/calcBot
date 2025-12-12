//
//  main.swift
//  calcBot
//
//  Created by Kreato on 2.12.2025.
//

import Foundation
import SoulverCore
import DiscordBM

// Define commands
enum DiscordCommand: String, CaseIterable {
    case calculate

    var description: String {
        switch self {
        case .calculate:
            return "Force a calculation (bypassing filters)"
        }
    }

    var options: [ApplicationCommand.Option]? {
        switch self {
        case .calculate:
            return [ApplicationCommand.Option(
                type: .string,
                name: "expression",
                description: "The expression to calculate",
                required: true
            )]
        }
    }
}

@main
struct EntryPoint {
    static func main() async throws {
        // Get bot token from environment variable
        guard let token = ProcessInfo.processInfo.environment["DISCORD_BOT_TOKEN"] else {
            fatalError("DISCORD_BOT_TOKEN environment variable is not set")
        }

        // Set up calculator with live currency rates (Raycast backend)
        let currencyRateProvider = RaycastCurrencyProvider()
        var customization = EngineCustomization.standard
        customization.currencyRateProvider = currencyRateProvider
        
        // Update currency rates on startup
        print("Updating currency rates...")
        let ratesUpdated = await currencyRateProvider.updateRates()
        if ratesUpdated {
            print("Currency rates updated successfully")
        } else {
            print("Warning: Failed to update currency rates, using cached/default rates")
        }
        
        // Create shared calculator instance with live rates
        let calculator = Calculator(customization: customization)

        // Initialize the bot
        // NOTE: The 'messageContent' intent is a PRIVILEGED INTENT and must be enabled
        // in the Discord Developer Portal at https://discord.com/developers/applications
        // Go to your bot -> Bot -> Privileged Gateway Intents -> Enable "MESSAGE CONTENT INTENT"
        let bot = await BotGatewayManager(
            token: token,
            presence: .init(
                activities: [.init(name: "Calculating how much 🗿 to send", type: .game)],
                status: .online,
                afk: false
            ),
            intents: [.guilds, .guildMessages, .messageContent]
        )

        // Register slash commands
        let commands = DiscordCommand.allCases.map { command in
            Payloads.ApplicationCommandCreate(
                name: command.rawValue,
                description: command.description,
                options: command.options
            )
        }
        
        do {
            try await bot.client
                .bulkSetApplicationCommands(payload: commands)
                .guardSuccess()
            print("Successfully registered commands")
        } catch {
            print("Failed to register commands: \(error)")
        }

        // Run bot connection and event handling concurrently
        await withTaskGroup(of: Void.self) { taskGroup in
            // Task: connect the bot
            taskGroup.addTask {
                await bot.connect()
            }

            // Task: periodically update currency rates
            taskGroup.addTask {
                while true {
                    try? await Task.sleep(nanoseconds: 3_600_000_000_000) // 1 hour
                    let updated = await currencyRateProvider.updateRates()
                    if updated {
                        print("Currency rates refreshed")
                    }
                }
            }

            // Task: handle events
            taskGroup.addTask {
                for await event in await bot.events {
                    await EventHandler(event: event, client: bot.client, calculator: calculator).handleAsync()
                }
            }
        }
    }
}

struct EventHandler: GatewayEventHandler {
    let event: Gateway.Event
    let client: any DiscordClient
    let calculator: Calculator

    func onInteractionCreate(_ interaction: Interaction) async throws {
        switch interaction.data {
        case let .applicationCommand(command):
            switch DiscordCommand(rawValue: command.name) {
            case .calculate:
                // Defer response to show we are processing
                try await client.createInteractionResponse(
                    id: interaction.id,
                    token: interaction.token,
                    payload: .deferredChannelMessageWithSource()
                ).guardSuccess()
                
                guard let expression = command.option(named: "expression")?.value?.asString else {
                    try await client.updateOriginalInteractionResponse(
                        token: interaction.token,
                        payload: Payloads.EditWebhookMessage(
                            content: "Please provide an expression to calculate."
                        )
                    ).guardSuccess()
                    return
                }
                
                // Calculate
                let result = calculator.calculate(expression)
                let resultString = result.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Create embed
                let embed = Embed(
                    title: "Calculation Result",
                    description: "```\n\(expression)\n= \(resultString)\n```",
                    timestamp: Date(),
                    color: .blue,
                    footer: .init(text: "SoulverCore")
                )
                
                // Send response
                try await client.updateOriginalInteractionResponse(
                    token: interaction.token,
                    payload: Payloads.EditWebhookMessage(
                        embeds: [embed]
                    )
                ).guardSuccess()
                
            case .none:
                break
            }
        default:
            break
        }
    }

    func onMessageCreate(_ payload: Gateway.MessageCreate) async throws {
        // Ignore messages from bots to avoid loops
        if payload.author?.bot == true {
            return
        }

        // Get message content
        let content = payload.content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip out code blocks (```...```) and inline code (`...`) first so that
        // example snippets don't accidentally get treated as expressions.
        let tripleBacktickPattern = #"```[\s\S]*?```"#
        let inlineBacktickPattern = #"`[^`]*`"#

        let withoutTripleBackticks = content.replacingOccurrences(
            of: tripleBacktickPattern,
            with: "",
            options: .regularExpression
        )

        let withoutBackticks = withoutTripleBackticks.replacingOccurrences(
            of: inlineBacktickPattern,
            with: "",
            options: .regularExpression
        )

        // Strip out Discord custom emoji tokens like <:name:id> or <a:name:id>
        // so they don't interfere with Soulver parsing.
        let emojiPattern = "<a?:[^>]+>"
        let expression = withoutBackticks.replacingOccurrences(
            of: emojiPattern,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip empty messages
        guard !expression.isEmpty else {
            return
        }

        let trimmedExpression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        // Recognize simple currency conversion phrases like "1 usd to try" and amounts with thousands/decimal separators
        let currencyConversionPattern = #"^\s*[-+]?(?:\d{1,3}(?:[.,]\d{3})+|\d+)(?:[.,]\d+)?\s+[a-zA-Z]{3}\s+(to|in)\s+[a-zA-Z]{3}\s*$"#
        let isCurrencyConversion = trimmedExpression.range(
            of: currencyConversionPattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil

        // Allow \"simple\" math expressions (only numbers, operators, dots, parentheses, and
        // whitespace) to always pass through, e.g. \"1+1\", \"(2 + 3) * 4\".
        let simpleMathPattern = #"^[0-9+\-*/%^×÷().\s]+$"#
        let isSimpleMath = trimmedExpression.range(of: simpleMathPattern, options: .regularExpression) != nil

        // If it's simple math, check if it's just a bare number (no operators).
        // Bare numbers like "2077" that just get formatted as "2,077" aren't meaningful calculations.
        if isSimpleMath {
            let hasOperator = trimmedExpression.range(of: #"[+\-*/%^×÷]"#, options: .regularExpression) != nil
            if !hasOperator {
                // It's just a bare number, skip it
                return
            }
        }

        if !isSimpleMath {
            // Require the expression to be \"direct\" (not a full sentence). If the first
            // non-whitespace character is a letter, treat it as plain text and ignore.
            if let first = trimmedExpression.first, first.isLetter {
                return
            }

            // Additional heuristic to skip natural-language sentences:
            // - If there are 2+ long alphabetic words (>= 4 chars), it's a sentence
            // - OR if there are 3+ alphabetic words total (even short ones), it's likely a sentence
            // Examples: \"30 kirven var +1 kivren eklendi kaç oldu\", \"2018 de yayınladılar mı ki\"
            let tokens = trimmedExpression.split(whereSeparator: { $0.isWhitespace })
            let alphaWords = tokens.filter { token in
                token.contains { $0.isLetter }
            }
            // If text mixes letters with a bare percent but no real math operators,
            // treat it as sentence-y (e.g. "100% test") and skip.
            let mathOperatorPattern = #"[+\-*/×÷^]"#
            let hasMathOperator = trimmedExpression.range(of: mathOperatorPattern, options: .regularExpression) != nil
            let hasPercent = trimmedExpression.contains("%")
            if hasPercent && !hasMathOperator && !alphaWords.isEmpty && !isCurrencyConversion {
                return
            }

            let longAlphaWordsCount = alphaWords.filter { $0.count >= 4 }.count
            if (longAlphaWordsCount >= 2 || alphaWords.count >= 3) && !isCurrencyConversion {
                return
            }
        }

        // If the expression ends with an operator (e.g. \"322-\", \"10+\"), it's
        // probably an incomplete thought rather than a real calculation, so skip it.
        if let last = expression.trimmingCharacters(in: .whitespacesAndNewlines).last,
           "+-*/%^×÷".contains(last) {
            return
        }

        // Try to calculate the expression
        do {
            let result = calculator.calculate(expression)
            let resultString = result.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            // Check if calculation was successful and produced a meaningful result
            // Skip if result is empty or same as input (likely means SoulverCore couldn't parse it)
            guard !resultString.isEmpty && resultString != expression else {
                return
            }

            // If the user entered something like "1 klavye" and Soulver effectively
            // just returns the same bare number (no operators, same numeric value),
            // don't reply as it's not a meaningful calculation.
            let operatorPattern = #"[+\-*/%^×÷]"#
            let hasOperator = expression.range(of: operatorPattern, options: .regularExpression) != nil

            if !hasOperator {
                // Heuristic: if the expression contains no operators and the first
                // numeric value matches the first numeric value in the result, then
                // it's just echoing the input (e.g. \"1 klavye\", \"31$\"), so skip.
                let numberPattern = #"[-+]?\d*[\.,]?\d+"#

                func firstNumericValue(in text: String) -> Double? {
                    guard let range = text.range(of: numberPattern, options: .regularExpression) else {
                        return nil
                    }
                    var numeric = String(text[range])
                    // Normalise comma decimals for Double parsing
                    if numeric.contains(",") && !numeric.contains(".") {
                        numeric = numeric.replacingOccurrences(of: ",", with: ".")
                    }
                    return Double(numeric)
                }

                if let exprNumber = firstNumericValue(in: expression),
                   let resultNumber = firstNumericValue(in: resultString),
                   exprNumber == resultNumber {
                    return
                }
                
                // Check if result is just a decimal-shifted version of an input number
                // Example: "9294" -> "9.294" (same value, just decimal point moved)
                func normalizeNumberString(_ str: String) -> String {
                    // Remove decimal points, commas, and signs to compare digit sequences
                    return str.replacingOccurrences(of: "[.,+-]", with: "", options: .regularExpression)
                }
                
                func extractAllNumbers(from text: String) -> [String] {
                    return text.matches(of: try! Regex(numberPattern)).map { String(text[$0.range]) }
                }
                
                let resultNumbers = extractAllNumbers(from: resultString)
                if let resultNum = resultNumbers.first {
                    let normalizedResult = normalizeNumberString(resultNum)
                    let inputNumbers = extractAllNumbers(from: expression)
                    
                    // Check if any input number's normalized form matches the result's normalized form
                    // This catches cases like "9294" -> "9.294" (both normalize to "9294")
                    for inputNum in inputNumbers {
                        let normalizedInput = normalizeNumberString(inputNum)
                        if normalizedInput == normalizedResult {
                            // Same digits, just different decimal placement - skip response
                            return
                        }
                    }
                }
                
                // Additional heuristic: if the expression has multiple separate numbers
                // mixed with random letter sequences (not recognized units/currencies),
                // and Soulver just extracts one of them, skip it.
                // Examples: "2026 djd 7" -> 7, "6 y 93 j 5272" -> 5272
                // These are gibberish, not calculations.
                let numbersInExpression = extractAllNumbers(from: expression)
                if numbersInExpression.count >= 2 {
                    // Check if there are random single-letter or short nonsense tokens between numbers
                    let tokens = expression.split(whereSeparator: { $0.isWhitespace })
                    let nonNumericTokens = tokens.filter { token in
                        // Token is non-numeric if it doesn't match a number pattern
                        String(token).range(of: #"^[-+]?\d*[\.,]?\d+$"#, options: .regularExpression) == nil
                    }
                    // If we have short gibberish tokens (1-3 chars) that are just letters,
                    // this is likely random text, not a calculation
                    let gibberishTokens = nonNumericTokens.filter { token in
                        let str = String(token)
                        return str.count <= 3 && str.allSatisfy { $0.isLetter }
                    }
                    if !gibberishTokens.isEmpty && !isCurrencyConversion {
                        return
                    }
                }
            }

            // Create an embed with the result
            let embed = Embed(
                title: "Calculation Result",
                description: "```\n\(content)\n= \(resultString)\n```",
                timestamp: Date(),
                color: .blue,
                footer: .init(text: "SoulverCore")
            )

            // Reply to the user with the embed
            try await client.createMessage(
                channelId: payload.channel_id,
                payload: .init(
                    embeds: [embed]
                )
            ).guardSuccess()
        } catch {
            // If calculation fails, silently ignore (don't spam chat with errors)
            return
        }
    }
}
