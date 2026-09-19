import Foundation
import CryptoKit
import Combine

/// One routing event. This is the "proof" layer: for regulated data it
/// records that a query was kept on-device, without storing the query itself.
struct AuditEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    /// SHA-256 of the query — proves *which* query was routed without keeping PII.
    let queryHash: String
    let destination: RouteDestination
    let score: Double
    let reasons: [String]
    let latencyMs: Int

    init(query: String, decision: RoutingDecision, latencyMs: Int) {
        self.id = UUID()
        self.timestamp = Date()
        self.queryHash = SHA256.hash(data: Data(query.utf8))
            .compactMap { String(format: "%02x", $0) }.joined()
        self.destination = decision.destination
        self.score = decision.score
        self.reasons = decision.reasons
        self.latencyMs = latencyMs
    }
}

/// What the user sees per answer.
struct RoutedAnswer {
    let text: String
    let destination: RouteDestination
    let latencyMs: Int
    let entry: AuditEntry
}

/// Orchestrates the full loop: route → execute → audit.
@available(iOS 26.0, *)
@MainActor
final class RoutingEngine: ObservableObject {

    @Published private(set) var auditLog: [AuditEntry] = []

    private let local = LocalModelService()
    private let cloud: CloudService

    init() {
        self.cloud = CloudService(config: .init(
            endpoint: Secrets.cloudEndpoint,
            model: Secrets.cloudModel,
            apiKey: Secrets.cloudAPIKey
        ))
    }

    /// Route the query, run it in the right place, record the audit entry.
    func answer(_ query: String) async throws -> RoutedAnswer {
        let decision = OnDeviceRouter.route(query)
        let start = Date()

        let text: String
        switch decision.destination {
        case .local:
            text = try await local.respond(to: query)
        case .cloud:
            text = try await cloud.respond(to: query)
        }

        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
        let entry = AuditEntry(query: query, decision: decision, latencyMs: latencyMs)
        auditLog.insert(entry, at: 0)
        return RoutedAnswer(text: text, destination: decision.destination,
                            latencyMs: latencyMs, entry: entry)
    }

    /// Fraction of queries kept on-device this session → direct cloud-cost savings.
    var onDeviceRate: Double {
        guard !auditLog.isEmpty else { return 0 }
        return Double(auditLog.filter { $0.destination == .local }.count) / Double(auditLog.count)
    }
}
