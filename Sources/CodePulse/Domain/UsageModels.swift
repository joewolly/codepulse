import CodePulseIntegration
import CryptoKit
import Foundation

/// Token counters are optional because local providers do not expose every
/// counter for every model or service mode.
struct UsageTokenCounts: Codable, Equatable {
    var input: Int?
    var output: Int?
    var cachedInput: Int?
    var cacheWriteInput: Int?
    var reasoning: Int?

    init(input: Int? = nil, output: Int? = nil, cachedInput: Int? = nil, cacheWriteInput: Int? = nil, reasoning: Int? = nil) {
        self.input = input
        self.output = output
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
        self.reasoning = reasoning
    }

    private enum CodingKeys: String, CodingKey { case input, output, cachedInput, cacheWriteInput, reasoning }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decodeIfPresent(Int.self, forKey: .input)
        output = try container.decodeIfPresent(Int.self, forKey: .output)
        cachedInput = try container.decodeIfPresent(Int.self, forKey: .cachedInput)
        cacheWriteInput = try container.decodeIfPresent(Int.self, forKey: .cacheWriteInput)
        reasoning = try container.decodeIfPresent(Int.self, forKey: .reasoning)
    }
}

/// These cases deliberately carry the label with the value. Callers cannot
/// render an estimate as a provider-reported charge by changing display text.
enum UsageCostRepresentation: String, Codable, CaseIterable, Identifiable {
    case providerReported
    case apiEquivalentEstimate
    case codexCreditEstimate
    case subscription
    case unpriced

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .providerReported: return "Provider-reported cost"
        case .apiEquivalentEstimate: return "API-equivalent estimate"
        case .codexCreditEstimate: return "Codex-credit estimate"
        case .subscription: return "Included/subscription — actual charge unknown"
        case .unpriced: return "Unpriced"
        }
    }

    var isEstimate: Bool {
        self == .apiEquivalentEstimate || self == .codexCreditEstimate
    }
}

enum PricingCatalogOrigin: String, Codable, Equatable {
    case bundled
    case remote
}

struct CostCalculationProvenance: Codable, Equatable {
    let representation: UsageCostRepresentation
    let catalogVersion: Int
    let catalogEffectiveDate: Date
    let catalogOrigin: PricingCatalogOrigin
    let modelID: String
    let serviceMode: String?
    let priceSourceURL: String
    let calculationMethod: String
    let confidence: String
    let calculatedAt: Date
}

struct CalculatedUsageCost: Codable, Equatable, Identifiable {
    let id: UUID
    let amount: Decimal
    let currency: String
    let provenance: CostCalculationProvenance

    init(id: UUID = UUID(), amount: Decimal, currency: String, provenance: CostCalculationProvenance) {
        self.id = id
        self.amount = amount
        self.currency = currency
        self.provenance = provenance
    }

    var representation: UsageCostRepresentation { provenance.representation }
}

/// A normalized usage record. No prompt, transcript, command, source-content,
/// or raw external session identifier belongs in this model.
struct UsageSample: Codable, Equatable, Identifiable {
    let id: UUID
    let integration: DeveloperTool
    let observedAt: Date
    let sessionFingerprint: String?
    let runID: UUID?
    let workspaceID: UUID?
    let model: String?
    let provider: String?
    let effort: String?
    let serviceMode: String?
    let tokens: UsageTokenCounts
    let providerReportedCost: Decimal?
    let providerReportedCurrency: String?
    /// An aggregate may include child-agent usage. Roll-ups use it instead of
    /// adding children a second time. Local Claude records are exclusive unless
    /// their supported metadata explicitly declares an aggregate.
    let includesSubagentUsage: Bool
    let calculatedCosts: [CalculatedUsageCost]

    init(
        id: UUID = UUID(),
        integration: DeveloperTool,
        observedAt: Date,
        sessionFingerprint: String? = nil,
        runID: UUID? = nil,
        workspaceID: UUID? = nil,
        model: String? = nil,
        provider: String? = nil,
        effort: String? = nil,
        serviceMode: String? = nil,
        tokens: UsageTokenCounts,
        providerReportedCost: Decimal? = nil,
        providerReportedCurrency: String? = nil,
        includesSubagentUsage: Bool = false,
        calculatedCosts: [CalculatedUsageCost] = []
    ) {
        self.id = id
        self.integration = integration
        self.observedAt = observedAt
        self.sessionFingerprint = sessionFingerprint
        self.runID = runID
        self.workspaceID = workspaceID
        self.model = model
        self.provider = provider
        self.effort = effort
        self.serviceMode = serviceMode
        self.tokens = tokens
        self.providerReportedCost = providerReportedCost
        self.providerReportedCurrency = providerReportedCurrency
        self.includesSubagentUsage = includesSubagentUsage
        self.calculatedCosts = calculatedCosts
    }

    private enum CodingKeys: String, CodingKey {
        case id, integration, observedAt, sessionFingerprint, runID, workspaceID
        case model, provider, effort, serviceMode, tokens, providerReportedCost
        case providerReportedCurrency, includesSubagentUsage, calculatedCosts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        integration = try container.decode(DeveloperTool.self, forKey: .integration)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        sessionFingerprint = try container.decodeIfPresent(String.self, forKey: .sessionFingerprint)
        runID = try container.decodeIfPresent(UUID.self, forKey: .runID)
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        serviceMode = try container.decodeIfPresent(String.self, forKey: .serviceMode)
        tokens = try container.decode(UsageTokenCounts.self, forKey: .tokens)
        providerReportedCost = try container.decodeIfPresent(Decimal.self, forKey: .providerReportedCost)
        providerReportedCurrency = try container.decodeIfPresent(String.self, forKey: .providerReportedCurrency)
        includesSubagentUsage = try container.decodeIfPresent(Bool.self, forKey: .includesSubagentUsage) ?? false
        calculatedCosts = try container.decodeIfPresent([CalculatedUsageCost].self, forKey: .calculatedCosts) ?? []
    }
}

enum UsageCostPresentation: Equatable {
    case providerReported(amount: Decimal, currency: String)
    case estimate(CalculatedUsageCost)
    case subscription
    case unpriced

    static func resolve(sample: UsageSample, preferred: UsageCostRepresentation) -> UsageCostPresentation {
        switch preferred {
        case .providerReported:
            if let amount = sample.providerReportedCost {
                return .providerReported(amount: amount, currency: sample.providerReportedCurrency ?? "USD")
            }
        case .subscription:
            return .subscription
        case .apiEquivalentEstimate, .codexCreditEstimate:
            if let estimate = sample.calculatedCosts.first(where: { $0.representation == preferred }) {
                return .estimate(estimate)
            }
        case .unpriced:
            return .unpriced
        }
        return .unpriced
    }
}

struct TokenRates: Codable, Equatable {
    /// Currency amount per one million tokens. A missing rate is unknown, not zero.
    let input: Decimal?
    let output: Decimal?
    let cachedInput: Decimal?
    let cacheWriteInput: Decimal?
    let reasoning: Decimal?

    init(input: Decimal? = nil, output: Decimal? = nil, cachedInput: Decimal? = nil, cacheWriteInput: Decimal? = nil, reasoning: Decimal? = nil) {
        self.input = input
        self.output = output
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
        self.reasoning = reasoning
    }
}

struct ModelPrice: Codable, Equatable, Identifiable {
    let modelID: String
    let aliases: [String]
    let serviceMode: String?
    let currency: String
    let effectiveDate: Date
    let rates: TokenRates
    let providerSourceURL: String

    var id: String { "\(modelID)|\(serviceMode ?? "default")|\(effectiveDate.timeIntervalSince1970)" }
}

struct PricingManifest: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let catalogVersion: Int
    let issuedAt: Date
    let expiresAt: Date
    let keyID: String
    let models: [ModelPrice]
    let signature: String

    init(
        schemaVersion: Int = PricingManifest.currentSchemaVersion,
        catalogVersion: Int,
        issuedAt: Date,
        expiresAt: Date,
        keyID: String = PricingManifestVerifier.defaultKeyID,
        models: [ModelPrice],
        signature: String
    ) {
        self.schemaVersion = schemaVersion
        self.catalogVersion = catalogVersion
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.keyID = keyID
        self.models = models
        self.signature = signature
    }

    private struct SignedPayload: Codable {
        let schemaVersion: Int
        let catalogVersion: Int
        let issuedAt: Date
        let expiresAt: Date
        let keyID: String
        let models: [ModelPrice]
    }

    func canonicalPayloadData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(SignedPayload(
            schemaVersion: schemaVersion,
            catalogVersion: catalogVersion,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            keyID: keyID,
            models: models
        ))
    }
}

enum PricingManifestVerificationError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case unrecognizedKeyID
    case invalidPublicKey
    case invalidSignatureEncoding
    case signatureMismatch
    case invalidValidityWindow
}

enum PricingManifestVerifier {
    static let defaultKeyID = "codepulse-pricing-p256-v1"
    // P-256 public key for the release catalog signing key. The private key is
    // intentionally not distributed with CodePulse.
    static let defaultPublicKeyBase64 = "d+ochTXPn5SGf0R5H03gAnjyo/JC4znpQEOydjR3HEw97mKNVVzfZpYSBWZ0HeEW52rloTPfmCaINU/MUoJtYA=="

    static func verify(_ manifest: PricingManifest, publicKeyData: Data? = nil) throws {
        guard manifest.schemaVersion == PricingManifest.currentSchemaVersion else {
            throw PricingManifestVerificationError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard manifest.keyID == defaultKeyID else { throw PricingManifestVerificationError.unrecognizedKeyID }
        guard manifest.issuedAt <= manifest.expiresAt else { throw PricingManifestVerificationError.invalidValidityWindow }
        let keyData = publicKeyData ?? Data(base64Encoded: defaultPublicKeyBase64)
        guard let keyData, let signatureData = Data(base64Encoded: manifest.signature) else {
            throw PricingManifestVerificationError.invalidSignatureEncoding
        }
        guard let key = try? P256.Signing.PublicKey(rawRepresentation: keyData) else {
            throw PricingManifestVerificationError.invalidPublicKey
        }
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData) else {
            throw PricingManifestVerificationError.invalidSignatureEncoding
        }
        guard key.isValidSignature(signature, for: try manifest.canonicalPayloadData()) else {
            throw PricingManifestVerificationError.signatureMismatch
        }
    }
}

struct PricingCatalog: Equatable {
    let manifest: PricingManifest

    var version: Int { manifest.catalogVersion }
    var isEmpty: Bool { manifest.models.isEmpty }

    func isExpired(at date: Date) -> Bool { manifest.expiresAt < date }

    /// A service-mode price wins only when the catalog explicitly lists that
    /// mode. Otherwise the default model price applies; effort never changes a rate.
    func resolve(model: String, serviceMode: String?) -> ModelPrice? {
        let normalizedModel = model.lowercased()
        let candidates = manifest.models.filter { price in
            price.modelID.lowercased() == normalizedModel || price.aliases.contains { $0.lowercased() == normalizedModel }
        }
        if let serviceMode,
           let exact = candidates.first(where: { $0.serviceMode?.caseInsensitiveCompare(serviceMode) == .orderedSame }) {
            return exact
        }
        return candidates.first(where: { $0.serviceMode == nil })
    }
}

struct PricingCatalogSnapshot: Equatable {
    let catalog: PricingCatalog
    let origin: PricingCatalogOrigin
    let isExpired: Bool
}

enum PricingCatalogStoreError: Error, Equatable {
    case bundledCatalogUnavailable
    case invalidManifest
    case rollbackRejected(currentVersion: Int, receivedVersion: Int)
    case insecureEndpoint
}

final class PricingCatalogStore {
    private let bundledURL: URL
    private let cacheURL: URL
    private let fileManager: FileManager

    init(bundledURL: URL? = Bundle.module.url(forResource: "pricing-catalog", withExtension: "json"), cacheURL: URL, fileManager: FileManager = .default) throws {
        guard let bundledURL else { throw PricingCatalogStoreError.bundledCatalogUnavailable }
        self.bundledURL = bundledURL
        self.cacheURL = cacheURL
        self.fileManager = fileManager
    }

    func current(at date: Date) throws -> PricingCatalogSnapshot {
        if let cached = try? loadManifest(at: cacheURL), !cached.catalog.isExpired(at: date) {
            return PricingCatalogSnapshot(catalog: cached.catalog, origin: .remote, isExpired: false)
        }
        let bundled = try loadManifest(at: bundledURL)
        return PricingCatalogSnapshot(catalog: bundled.catalog, origin: .bundled, isExpired: bundled.catalog.isExpired(at: date))
    }

    func highestKnownVersion() throws -> Int {
        let bundled = try loadManifest(at: bundledURL).catalog.version
        let cached = (try? loadManifest(at: cacheURL).catalog.version) ?? 0
        return max(bundled, cached)
    }

    func installVerifiedRemoteManifest(_ data: Data) throws -> PricingCatalog {
        let manifest = try decodeAndVerify(data)
        let currentVersion = try highestKnownVersion()
        guard manifest.catalogVersion > currentVersion else {
            throw PricingCatalogStoreError.rollbackRejected(currentVersion: currentVersion, receivedVersion: manifest.catalogVersion)
        }
        try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
        return PricingCatalog(manifest: manifest)
    }

    func decodeAndVerify(_ data: Data) throws -> PricingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(PricingManifest.self, from: data)
        try PricingManifestVerifier.verify(manifest)
        return manifest
    }

    private func loadManifest(at url: URL) throws -> (manifest: PricingManifest, catalog: PricingCatalog) {
        let manifest = try decodeAndVerify(Data(contentsOf: url))
        return (manifest, PricingCatalog(manifest: manifest))
    }
}

enum PricingCatalogRefreshResult: Equatable {
    case updated(version: Int)
    case ignored(reason: String)
}

final class PricingCatalogRefresher {
    private let store: PricingCatalogStore

    init(store: PricingCatalogStore) {
        self.store = store
    }

    func refresh(from data: Data) -> PricingCatalogRefreshResult {
        do {
            let catalog = try store.installVerifiedRemoteManifest(data)
            return .updated(version: catalog.version)
        } catch {
            // Failed refreshes never replace a verified cached or bundled catalog.
            return .ignored(reason: String(describing: error))
        }
    }

    func refresh(from endpoint: URL, completion: @escaping (PricingCatalogRefreshResult) -> Void) {
        guard endpoint.scheme?.lowercased() == "https" else {
            completion(.ignored(reason: String(describing: PricingCatalogStoreError.insecureEndpoint)))
            return
        }
        URLSession.shared.dataTask(with: endpoint) { [weak self] data, _, error in
            guard let self, let data, error == nil else {
                completion(.ignored(reason: "network-unavailable"))
                return
            }
            completion(self.refresh(from: data))
        }.resume()
    }
}

enum UsageCostCalculator {
    static func calculate(
        representation: UsageCostRepresentation,
        sample: UsageSample,
        catalog: PricingCatalogSnapshot,
        calculatedAt: Date
    ) -> CalculatedUsageCost? {
        guard representation.isEstimate, let model = sample.model,
              let price = catalog.catalog.resolve(model: model, serviceMode: sample.serviceMode) else {
            return nil
        }
        let componentPairs = [
            (sample.tokens.input, price.rates.input),
            (sample.tokens.output, price.rates.output),
            (sample.tokens.cachedInput, price.rates.cachedInput),
            (sample.tokens.cacheWriteInput, price.rates.cacheWriteInput),
            (sample.tokens.reasoning, price.rates.reasoning)
        ]
        guard componentPairs.allSatisfy({ tokens, rate in tokens == nil || tokens == 0 || rate != nil }) else {
            return nil
        }
        let components = componentPairs.compactMap { priced(tokens: $0.0, rate: $0.1) }
        guard !components.isEmpty else { return nil }
        let total = components.reduce(Decimal.zero, +)
        let provenance = CostCalculationProvenance(
            representation: representation,
            catalogVersion: catalog.catalog.version,
            catalogEffectiveDate: price.effectiveDate,
            catalogOrigin: catalog.origin,
            modelID: price.modelID,
            serviceMode: price.serviceMode,
            priceSourceURL: price.providerSourceURL,
            calculationMethod: "per-million-token-rate",
            confidence: catalog.isExpired ? "catalog-expired" : "catalog-verified",
            calculatedAt: calculatedAt
        )
        return CalculatedUsageCost(amount: rounded(total, scale: 6), currency: price.currency, provenance: provenance)
    }

    private static func priced(tokens: Int?, rate: Decimal?) -> Decimal? {
        guard let tokens, tokens >= 0, let rate else { return nil }
        return Decimal(tokens) * rate / Decimal(1_000_000)
    }

    private static func rounded(_ value: Decimal, scale: Int) -> Decimal {
        var value = value
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .bankers)
        return result
    }
}

enum UsageCostPresentationSelector {
    static func primaryRepresentation(
        preference: UsageCostRepresentation,
        providerReportedCost: Decimal?,
        calculatedCosts: [CalculatedUsageCost],
        isIncludedInSubscription: Bool = false
    ) -> UsageCostRepresentation {
        let available: Set<UsageCostRepresentation> = Set(calculatedCosts.map(\.representation))
            .union(providerReportedCost == nil ? [] : [.providerReported])
            .union(isIncludedInSubscription ? [.subscription] : [])
        if available.contains(preference) { return preference }
        for fallback: UsageCostRepresentation in [.providerReported, .apiEquivalentEstimate, .codexCreditEstimate, .subscription] {
            if available.contains(fallback) { return fallback }
        }
        return .unpriced
    }
}

extension CodePulseSettings {
    func primaryCostDisplay(for integration: DeveloperTool) -> UsageCostRepresentation {
        primaryCostDisplays[integration.rawValue] ?? .providerReported
    }

    mutating func setPrimaryCostDisplay(_ display: UsageCostRepresentation, for integration: DeveloperTool) {
        primaryCostDisplays[integration.rawValue] = display
    }
}
