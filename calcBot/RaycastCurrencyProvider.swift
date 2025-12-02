import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SoulverCore

private struct CurrencyLayerResponse: Codable {
    let success: Bool
    let source: String
    let quotes: [String: Double]
}

private struct CryptoCoinLayerResponse: Codable {
    let success: Bool
    let target: String
    let rates: [String: Double]
}

final class RaycastCurrencyProvider: CurrencyRateProvider {

    // MARK: - Nested Types

    private actor RateManager {
        private(set) var rates: [String: Decimal] = [:]
        private var isUpdating = false

        private let standardCurrenciesURL = URL(string: "https://backend.raycast.com/api/v1/currencies")!
        private let cryptoSymbols: [String] = ["BTC", "ETH", "SOL", "DOGE", "LTC", "XRP"]

        private var cryptoCurrenciesURL: URL {
            let symbolsString = cryptoSymbols.joined(separator: ",")
            return URL(string: "https://backend.raycast.com/api/v1/currencies/crypto?symbols=\(symbolsString)")!
        }

        func getRate(for code: String) -> Decimal? {
            rates[code]
        }

        /// Updates all currency rates from Raycast's backend.
        /// - Returns: `true` if new rates were successfully loaded and applied.
        func updateRates() async -> Bool {
            guard !isUpdating else { return false }
            isUpdating = true
            defer { isUpdating = false }

            async let standardRatesTask = fetchStandardRates()
            async let cryptoRatesTask = fetchCryptoRates()

            let (standardRates, cryptoRates) = await (standardRatesTask, cryptoRatesTask)

            var allRates = [String: Decimal]()
            allRates["USD"] = 1.0

            if let standardRates {
                for (key, value) in standardRates {
                    allRates[key] = Decimal(value)
                }
            }

            if let cryptoRates {
                for (key, value) in cryptoRates where value > 0 {
                    // API returns crypto -> USD, we need USD -> crypto
                    allRates[key] = 1.0 / Decimal(value)
                }
            }

            guard !allRates.isEmpty, allRates.count > 1 else {
                return false
            }

            self.rates = allRates
            return true
        }

        private func fetchStandardRates() async -> [String: Double]? {
            do {
                let (data, _) = try await URLSession.shared.data(from: standardCurrenciesURL)
                let response = try JSONDecoder().decode(CurrencyLayerResponse.self, from: data)
                guard response.success, response.source == "USD" else { return nil }

                var processedQuotes = [String: Double]()
                for (key, value) in response.quotes where key.hasPrefix("USD") {
                    let currencyCode = String(key.dropFirst(3))
                    processedQuotes[currencyCode] = value
                }
                return processedQuotes
            } catch {
                return nil
            }
        }

        private func fetchCryptoRates() async -> [String: Double]? {
            do {
                let (data, _) = try await URLSession.shared.data(from: cryptoCurrenciesURL)
                let response = try JSONDecoder().decode(CryptoCoinLayerResponse.self, from: data)
                guard response.success, response.target == "USD" else { return nil }
                return response.rates
            } catch {
                return nil
            }
        }
    }

    // MARK: - Properties

    private let rateManager = RateManager()

    // MARK: - CurrencyRateProvider

    func updateRates() async -> Bool {
        await rateManager.updateRates()
    }

    func rateFor(request: CurrencyRateRequest) -> Decimal? {
        let targetCode = request.currencyCode
        if targetCode == "USD" {
            return 1.0
        }

        let semaphore = DispatchSemaphore(value: 0)
        var rate: Decimal?

        let manager = self.rateManager
        Task {
            rate = await manager.getRate(for: targetCode)
            semaphore.signal()
        }

        semaphore.wait()
        return rate
    }

    func fetchRateInBackgroundFor(request: CurrencyRateRequest) async -> Decimal? {
        let targetCode = request.currencyCode
        if targetCode == "USD" {
            return 1.0
        }

        let manager = self.rateManager

        if let existing = await manager.getRate(for: targetCode) {
            return existing
        }

        // If we don't have a rate yet, try to refresh in the background
        _ = await manager.updateRates()
        return await manager.getRate(for: targetCode)
    }
}

