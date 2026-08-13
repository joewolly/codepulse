import Foundation
import XCTest
@testable import CodePulse

final class PricingCatalogTests: XCTestCase {
    func testBundledCatalogVerifiesAndResolvesAliases() throws {
        let store = try makeStore()
        let snapshot = try store.current(at: date("2026-08-14T00:00:00Z"))

        XCTAssertEqual(snapshot.origin, .bundled)
        XCTAssertFalse(snapshot.isExpired)
        XCTAssertEqual(snapshot.catalog.version, 1)
        XCTAssertEqual(snapshot.catalog.resolve(model: "gpt-5-chat-latest", serviceMode: "priority")?.modelID, "gpt-5")
    }

    func testValidRefreshCachesNewerManifestAndRejectsReplay() throws {
        let cacheURL = try temporaryDirectory().appendingPathComponent("catalog.json")
        let store = try PricingCatalogStore(cacheURL: cacheURL)
        let refresher = PricingCatalogRefresher(store: store)

        XCTAssertEqual(refresher.refresh(from: remoteManifestData), .updated(version: 2))
        XCTAssertEqual(try store.current(at: date("2026-08-14T00:00:00Z")).origin, .remote)
        XCTAssertEqual(refresher.refresh(from: remoteManifestData), .ignored(reason: String(describing: PricingCatalogStoreError.rollbackRejected(currentVersion: 2, receivedVersion: 2))))
    }

    func testInvalidRefreshDoesNotReplaceOfflineCatalog() throws {
        let cacheURL = try temporaryDirectory().appendingPathComponent("catalog.json")
        let store = try PricingCatalogStore(cacheURL: cacheURL)
        let refresher = PricingCatalogRefresher(store: store)
        var object = try JSONSerialization.jsonObject(with: remoteManifestData) as! [String: Any]
        object["signature"] = "not-a-signature"
        let invalid = try JSONSerialization.data(withJSONObject: object)

        guard case .ignored = refresher.refresh(from: invalid) else {
            return XCTFail("Expected invalid remote manifest to be ignored")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertEqual(try store.current(at: date("2026-08-14T00:00:00Z")).origin, .bundled)
    }

    func testExpiredCacheFallsBackToBundledCatalogAndIsLabeled() throws {
        let cacheURL = try temporaryDirectory().appendingPathComponent("catalog.json")
        try remoteManifestData.write(to: cacheURL)
        let store = try PricingCatalogStore(cacheURL: cacheURL)

        let snapshot = try store.current(at: date("2026-10-01T00:00:00Z"))
        XCTAssertEqual(snapshot.origin, .bundled)
        XCTAssertTrue(snapshot.isExpired)
    }

    func testCostCalculatorKeepsEstimateLabelAndImmutableCatalogProvenance() throws {
        let store = try makeStore()
        let snapshot = try store.current(at: date("2026-08-14T00:00:00Z"))
        let sample = UsageSample(
            integration: .codex,
            observedAt: date("2026-08-14T00:00:00Z"),
            model: "gpt-5",
            effort: "high",
            serviceMode: "priority",
            tokens: UsageTokenCounts(input: 1_000_000, output: 500_000, cachedInput: 2_000_000)
        )

        let cost = UsageCostCalculator.calculate(
            representation: .apiEquivalentEstimate,
            sample: sample,
            catalog: snapshot,
            calculatedAt: date("2026-08-14T00:01:00Z")
        )

        XCTAssertEqual(cost?.amount, Decimal(string: "6.5"))
        XCTAssertEqual(cost?.currency, "USD")
        XCTAssertEqual(cost?.provenance.representation, .apiEquivalentEstimate)
        XCTAssertEqual(cost?.provenance.catalogVersion, 1)
        XCTAssertEqual(cost?.provenance.serviceMode, nil, "The catalog has no priority price, so effort/service mode cannot invent one.")
        XCTAssertEqual(UsageCostRepresentation.apiEquivalentEstimate.displayLabel, "API-equivalent estimate")
        XCTAssertNil(UsageCostCalculator.calculate(representation: .providerReported, sample: sample, catalog: snapshot, calculatedAt: Date()))
        XCTAssertNil(UsageCostCalculator.calculate(
            representation: .apiEquivalentEstimate,
            sample: UsageSample(integration: .codex, observedAt: Date(), model: "gpt-5", tokens: UsageTokenCounts(reasoning: 10)),
            catalog: snapshot,
            calculatedAt: Date()
        ))
    }

    func testCostDisplayPreferenceDefaultsToReportedCostAndRoundTrips() throws {
        var settings = CodePulseSettings()
        XCTAssertEqual(settings.primaryCostDisplay(for: .claudeCode), .providerReported)
        settings.setPrimaryCostDisplay(.codexCreditEstimate, for: .codex)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(CodePulseSettings.self, from: data)
        XCTAssertEqual(decoded.primaryCostDisplay(for: .codex), .codexCreditEstimate)
        XCTAssertEqual(UsageCostRepresentation.codexCreditEstimate.displayLabel, "Codex-credit estimate")
        XCTAssertEqual(UsageCostRepresentation.subscription.displayLabel, "Included/subscription — actual charge unknown")
        XCTAssertEqual(
            UsageCostPresentationSelector.primaryRepresentation(
                preference: .providerReported,
                providerReportedCost: nil,
                calculatedCosts: [CalculatedUsageCost(
                    amount: 1,
                    currency: "USD",
                    provenance: CostCalculationProvenance(
                        representation: .apiEquivalentEstimate,
                        catalogVersion: 1,
                        catalogEffectiveDate: Date(),
                        catalogOrigin: .bundled,
                        modelID: "example",
                        serviceMode: nil,
                        priceSourceURL: "https://example.com",
                        calculationMethod: "test",
                        confidence: "test",
                        calculatedAt: Date()
                    )
                )]
            ),
            .apiEquivalentEstimate
        )
    }

    private func makeStore() throws -> PricingCatalogStore {
        try PricingCatalogStore(cacheURL: try temporaryDirectory().appendingPathComponent("catalog.json"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CodePulsePricingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private var remoteManifestData: Data {
        Data("""
        {"catalogVersion":2,"expiresAt":"2026-09-13T00:00:00Z","issuedAt":"2026-08-13T00:00:00Z","keyID":"codepulse-pricing-p256-v1","models":[{"aliases":["gpt-5-chat-latest","gpt-5-2025-08-07"],"currency":"USD","effectiveDate":"2026-08-13T00:00:00Z","modelID":"gpt-5","providerSourceURL":"https://developers.openai.com/api/docs/models/gpt-5","rates":{"cachedInput":0.125,"input":1.25,"output":10}}],"schemaVersion":1,"signature":"OuZadkkJ3KJbKfkcY1P3fTfqAICOVqtrWkGEdLSJmSk9PiPiviplVJWz1yQrMyJ/jI7QM8jgc/7VIgTMvxqXiw=="}
        """.utf8)
    }
}
