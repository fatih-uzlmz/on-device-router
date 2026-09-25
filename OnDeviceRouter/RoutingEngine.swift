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

/// Local-only memory lab. The router and cloud service remain in the project for
/// later work, but are intentionally absent from this active execution path.
@available(iOS 26.0, *)
@MainActor
final class RoutingEngine: ObservableObject {

    @Published private(set) var auditLog: [AuditEntry] = []
    @Published private(set) var localModelStatus: LocalModelStatus = .waiting
    @Published private(set) var memoryDiagnostics: MemoryDiagnostics = .empty
    @Published private(set) var memorySnapshot: MemorySnapshot = .empty
    @Published private(set) var lastRecallHitCount = 0

    private let local: any LocalModelResponding
    private let memory: any MemoryStore

    init(
        local: any LocalModelResponding = LocalModelService(),
        memory: any MemoryStore = MemlocalMemoryStore()
    ) {
        self.local = local
        self.memory = memory
        print("[Debug][App] Local-only memory mode initialized; cloud routing and privacy scoring are disabled")
        Task {
            await refreshMemoryDiagnostics()
            print("[Debug][Memory] startup: stored=\(memoryDiagnostics.storedCount), vectors=\(memoryDiagnostics.embeddedCount), graphEdges=\(memoryDiagnostics.graphEdgeCount), types=\(memoryDiagnostics.typeCounts), fileExists=\(memoryDiagnostics.fileExists), bytes=\(memoryDiagnostics.fileSizeBytes)")
        }
    }

    /// Run every query locally, recall related on-device turns, then persist the
    /// completed exchange back to the same local store.
    func answer(_ query: String) async throws -> RoutedAnswer {
        let turnID = String(UUID().uuidString.prefix(8))
        print("[Debug][Turn \(turnID)] started in local-only mode")

        let recall = await memory.recall(matching: query, limit: 5)
        lastRecallHitCount = recall.facts.count
        print("[Debug][Turn \(turnID)] recall complete: \(recall.facts.count) durable fact(s), \(recall.episodes.count) episode(s)")

        let decision = RoutingDecision(
            destination: .local,
            score: 0,
            reasons: ["LOCAL-ONLY MEMORY MODE — routing, cloud, and privacy scoring disabled"]
        )
        let start = Date()
        print("[Debug][Turn \(turnID)] Llama generation started with structured local memory")

        let engine = self
        let text: String
        do {
            text = try await local.respond(to: query, memoryContext: recall.promptContext) { status in
                await engine.updateLocalModelStatus(status)
            }
        } catch {
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            print("[Debug][Turn \(turnID)] FAILED after \(latencyMs)ms: \(error.localizedDescription)")
            throw error
        }

        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
        print("[Debug][Turn \(turnID)] Llama generation complete: \(latencyMs)ms, \(text.count) characters")
        let entry = AuditEntry(query: query, decision: decision, latencyMs: latencyMs)
        auditLog.insert(entry, at: 0)

        await memory.ingest(userMessage: query,
                            assistantMessage: text,
                            route: RouteDestination.local.rawValue)
        await refreshMemoryDiagnostics()
        print("[Debug][Turn \(turnID)] persisted: stored=\(memoryDiagnostics.storedCount), fileExists=\(memoryDiagnostics.fileExists), bytes=\(memoryDiagnostics.fileSizeBytes)")
        print("[Debug][Turn \(turnID)] finished")

        return RoutedAnswer(text: text, destination: decision.destination,
                            latencyMs: latencyMs, entry: entry)
    }

    /// Fraction of queries kept on-device this session → direct cloud-cost savings.
    var onDeviceRate: Double {
        guard !auditLog.isEmpty else { return 0 }
        return Double(auditLog.filter { $0.destination == .local }.count) / Double(auditLog.count)
    }

    private func updateLocalModelStatus(_ status: LocalModelStatus) {
        localModelStatus = status
    }

    func refreshMemoryDiagnostics() async {
        memoryDiagnostics = await memory.diagnostics()
        memorySnapshot = await memory.snapshot()
    }
}
