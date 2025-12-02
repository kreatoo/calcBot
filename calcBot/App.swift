//
//  main.swift
//  calcBot
//
//  Created by Kreato on 2.12.2025.
//

import Foundation
import SoulverCore
import DiscordBM

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

    func onMessageCreate(_ payload: Gateway.MessageCreate) async throws {
        // Ignore messages from bots to avoid loops
        if payload.author?.bot == true {
            return
        }

        // Get message content
        let content = payload.content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip out Discord custom emoji tokens like <:name:id> or <a:name:id>
        // so they don't interfere with Soulver parsing.
        let emojiPattern = "<a?:[^>]+>"
        let expression = content.replacingOccurrences(
            of: emojiPattern,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip empty messages
        guard !expression.isEmpty else {
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
