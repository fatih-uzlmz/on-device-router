import Foundation

/// Cognitive memory categories used by the local memory engine.
enum MemoryType: String, Codable, CaseIterable, Sendable {
    case episodic
    case factual
    case semantic
    case procedural
    case social
    case spatial
    case prospective
    case affective
}

/// A compact subject-predicate-object fact extracted on-device.
struct MemoryTriple: Codable, Hashable, Sendable {
    let subject: String
    let predicate: String
    let object: String
}

/// An on-device relationship between two memories.
struct MemoryEdge: Codable, Hashable, Sendable {
    let memoryID: UUID
    let relation: String
    let weight: Double
}

/// One saved conversation turn plus the local retrieval metadata derived from it.
struct MemoryExchange: Identifiable, Codable, Sendable {
    let id: UUID
    var userMessage: String
    var assistantMessage: String
    /// "local" or "cloud" — useful context for later analysis.
    var route: String
    var timestamp: Date
    var memoryType: MemoryType
    var triple: MemoryTriple?
    var embedding: [Double]
    var confidence: Double
    var reinforcementCount: Int
    var accessCount: Int
    var validFrom: Date
    var invalidAt: Date?
    var lastAccessedAt: Date?
    var relatedMemoryIDs: [UUID]

    init(userMessage: String, assistantMessage: String, route: String) {
        self.id = UUID()
        self.userMessage = userMessage
        self.assistantMessage = assistantMessage
        self.route = route
        self.timestamp = Date()
        self.memoryType = .episodic
        self.triple = nil
        self.embedding = []
        self.confidence = 0.75
        self.reinforcementCount = 0
        self.accessCount = 0
        self.validFrom = self.timestamp
        self.invalidAt = nil
        self.lastAccessedAt = nil
        self.relatedMemoryIDs = []
    }

    /// Backward-compatible decoding for the original MVP JSON format.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.userMessage = try values.decode(String.self, forKey: .userMessage)
        self.assistantMessage = try values.decode(String.self, forKey: .assistantMessage)
        self.route = try values.decodeIfPresent(String.self, forKey: .route) ?? "local"
        self.timestamp = try values.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        self.memoryType = try values.decodeIfPresent(MemoryType.self, forKey: .memoryType) ?? .episodic
        self.triple = try values.decodeIfPresent(MemoryTriple.self, forKey: .triple)
        self.embedding = try values.decodeIfPresent([Double].self, forKey: .embedding) ?? []
        self.confidence = try values.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.75
        self.reinforcementCount = try values.decodeIfPresent(Int.self, forKey: .reinforcementCount) ?? 0
        self.accessCount = try values.decodeIfPresent(Int.self, forKey: .accessCount) ?? 0
        self.validFrom = try values.decodeIfPresent(Date.self, forKey: .validFrom) ?? self.timestamp
        self.invalidAt = try values.decodeIfPresent(Date.self, forKey: .invalidAt)
        self.lastAccessedAt = try values.decodeIfPresent(Date.self, forKey: .lastAccessedAt)
        self.relatedMemoryIDs = try values.decodeIfPresent([UUID].self, forKey: .relatedMemoryIDs) ?? []
    }
}

/// Read-only state exposed by the memory store for local debugging.
struct MemoryDiagnostics: Sendable {
    let storedCount: Int
    let filePath: String
    let fileExists: Bool
    let fileSizeBytes: Int
    let persistenceError: String?
    let embeddedCount: Int
    let graphEdgeCount: Int
    let typeCounts: [String: Int]

    static let empty = MemoryDiagnostics(
        storedCount: 0,
        filePath: "",
        fileExists: false,
        fileSizeBytes: 0,
        persistenceError: nil,
        embeddedCount: 0,
        graphEdgeCount: 0,
        typeCounts: [:]
    )
}

/// The app's memory interface. Everything the app needs from memory lives here,
/// so the implementation can be swapped later without touching calling code.
protocol MemoryStore {
    func save(_ exchange: MemoryExchange) async
    func recall(matching query: String, limit: Int) async -> [MemoryExchange]
    func promptContext(matching query: String, limit: Int) async -> String
    func count() async -> Int
    func diagnostics() async -> MemoryDiagnostics
    func clear() async
}
