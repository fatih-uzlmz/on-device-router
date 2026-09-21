import Foundation
import NaturalLanguage

/// Local-first hybrid memory engine.
///
/// This keeps the app's small `MemoryStore` boundary, but implements the useful
/// parts of the Memlocal design without a cloud database: typed memories,
/// on-device sentence embeddings, lexical fallback, persisted triples,
/// relationship edges, two-hop graph expansion, recency, confidence, and
/// reinforcement-aware ranking. All data remains in the app's JSON file.
@available(iOS 26.0, *)
actor SimpleMemoryStore: MemoryStore {
    private let capacity = 500
    private let fileURL: URL
    private var sentenceEmbedding: NLEmbedding? = nil

    private var exchanges: [MemoryExchange]
    private var persistenceError: String?
    private var hasMigratedMetadata = false

    init(fileURL: URL? = nil) {
        let resolvedURL = fileURL ?? Self.storeURL(fileName: "memories.json")
        self.fileURL = resolvedURL
        self.exchanges = Self.load(from: resolvedURL)
        print("[Memory] loaded \(exchanges.count) locally stored turn(s); sentence embeddings deferred")
    }

    func save(_ exchange: MemoryExchange) async {
        ensureMetadata()
        let enriched = enrich(exchange)
        invalidateContradictions(with: enriched)

        if let existingIndex = exchanges.firstIndex(where: { isDuplicate($0, of: enriched) }) {
            var existing = exchanges[existingIndex]
            existing.assistantMessage = enriched.assistantMessage
            existing.route = enriched.route
            existing.timestamp = enriched.timestamp
            existing.embedding = enriched.embedding
            existing.triple = enriched.triple ?? existing.triple
            existing.memoryType = enriched.memoryType
            existing.confidence = max(existing.confidence, enriched.confidence)
            existing.reinforcementCount += 1
            exchanges[existingIndex] = existing
            print("[Memory] reinforced existing \(existing.id.uuidString.prefix(8)) (count=\(existing.reinforcementCount))")
        } else {
            exchanges.append(enriched)
        }

        if exchanges.count > capacity {
            exchanges.removeFirst(exchanges.count - capacity)
        }
        rebuildGraph()
        persist()
        print("[Memory] saved turn, total stored: \(exchanges.count), graph edges: \(graphEdgeCount())")
    }

    func recall(matching query: String, limit: Int = 5) async -> [MemoryExchange] {
        ensureMetadata()
        let words = Set(Self.keywords(in: query))
        guard !words.isEmpty else {
            print("[Memory] recall skipped: query has no meaningful keywords")
            return []
        }

        let queryEmbedding = embedding(for: query)
        let queryVector = queryEmbedding.vector
        let queryTriple = Self.extractTriple(from: query)
        var ranked = exchanges.compactMap { exchange -> RankedMemory? in
            guard Self.isUsefulForRecall(exchange) else { return nil }
            guard exchange.invalidAt == nil else { return nil }
            let lexical = lexicalScore(exchange, words: words)
            let semantic = Self.cosine(queryVector, exchange.embedding)
            let triple = tripleScore(queryTriple, record: exchange)
            let qualifies = lexical > 0 || triple > 0 || (queryEmbedding.isSemantic && semantic >= 0.78)
            guard qualifies else { return nil }

            let recency = recencyScore(for: exchange)
            let importance = importanceScore(for: exchange)
            let base = (semantic * 0.35)
                + (lexical * 0.30)
                + (triple * 0.15)
                + (recency * 0.10)
                + (importance * 0.10)
            return RankedMemory(exchange: exchange, score: base, lexical: lexical, semantic: semantic)
        }

        let seedIDs = ranked
            .sorted { $0.score > $1.score }
            .prefix(5)
            .map { $0.exchange.id }
        let distances = graphDistances(from: seedIDs, maxHops: 2)
        ranked = ranked.map { item in
            guard let distance = distances[item.exchange.id], distance > 0 else { return item }
            let graphBonus = distance == 1 ? 0.15 : 0.08
            return RankedMemory(exchange: item.exchange,
                                score: item.score + graphBonus,
                                lexical: item.lexical,
                                semantic: item.semantic)
        }

        let selected = ranked
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.exchange.timestamp > $1.exchange.timestamp
            }
            .prefix(max(1, min(limit, 8)))
            .map { $0.exchange }

        let selectedIDs = Set(selected.map(\.id))
        for index in exchanges.indices where selectedIDs.contains(exchanges[index].id) {
            exchanges[index].accessCount += 1
            exchanges[index].lastAccessedAt = Date()
        }
        if !selected.isEmpty { persist() }

        let summary = ranked
            .sorted { $0.score > $1.score }
            .prefix(selected.count)
            .map { "\($0.exchange.id.uuidString.prefix(8)):\(String(format: "%.2f", $0.score))" }
            .joined(separator: ", ")
        print("[Memory] hybrid recall → \(selected.count) hit(s), top scores=[\(summary)]")
        return selected
    }

    func promptContext(matching query: String, limit: Int = 5) async -> String {
        let hits = await recall(matching: query, limit: limit)
        guard !hits.isEmpty else { return "" }
        let lines = hits.map { memory in
            let fact = memory.triple.map { " | Fact: \($0.subject) \($0.predicate) \($0.object)" } ?? ""
            return "- [\(memory.memoryType.rawValue)] User: \(memory.userMessage)\n  Assistant: \(memory.assistantMessage)\(fact)"
        }
        return "Relevant memories from earlier conversations:\n" + lines.joined(separator: "\n")
    }

    func count() async -> Int { exchanges.count }

    func diagnostics() async -> MemoryDiagnostics {
        ensureMetadata()
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        var typeCounts: [String: Int] = [:]
        for exchange in exchanges {
            typeCounts[exchange.memoryType.rawValue, default: 0] += 1
        }
        return MemoryDiagnostics(
            storedCount: exchanges.count,
            filePath: fileURL.path,
            fileExists: FileManager.default.fileExists(atPath: fileURL.path),
            fileSizeBytes: size,
            persistenceError: persistenceError,
            embeddedCount: exchanges.filter { !$0.embedding.isEmpty }.count,
            graphEdgeCount: graphEdgeCount(),
            typeCounts: typeCounts
        )
    }

    func clear() async {
        exchanges = []
        persist()
        print("[Memory] cleared all stored turns, facts, vectors, and graph edges")
    }

    // MARK: - Migration and enrichment

    private func ensureMetadata() {
        guard !hasMigratedMetadata else { return }
        sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
        var changed = false
        for index in exchanges.indices {
            let enriched = enrich(exchanges[index])
            if enriched.embedding != exchanges[index].embedding
                || enriched.triple != exchanges[index].triple
                || enriched.memoryType != exchanges[index].memoryType {
                exchanges[index] = enriched
                changed = true
            }
        }
        rebuildGraph()
        hasMigratedMetadata = true
        if changed { persist() }
        // Persisted vectors do not require keeping Apple's embedding model
        // resident beside the 1B Llama container.
        sentenceEmbedding = nil
        if changed { print("[Memory] migrated existing turns to typed/vector/graph metadata") }
    }

    private func enrich(_ exchange: MemoryExchange) -> MemoryExchange {
        var result = exchange
        let combined = "\(result.userMessage) \(result.assistantMessage)"
        if result.embedding.isEmpty { result.embedding = embedding(for: combined).vector }
        if result.triple == nil { result.triple = Self.extractTriple(from: result.userMessage) }
        if result.memoryType == .episodic { result.memoryType = Self.classify(result.userMessage) }
        return result
    }

    private func isDuplicate(_ lhs: MemoryExchange, of rhs: MemoryExchange) -> Bool {
        if Self.normalized(lhs.userMessage) == Self.normalized(rhs.userMessage) { return true }
        let lexical = lexicalScore(lhs, words: Set(Self.keywords(in: rhs.userMessage)))
        let semantic = Self.cosine(lhs.embedding, rhs.embedding)
        return lexical >= 0.90 && semantic >= 0.90
    }

    // MARK: - Hybrid ranking

    private struct RankedMemory {
        let exchange: MemoryExchange
        let score: Double
        let lexical: Double
        let semantic: Double
    }

    private func lexicalScore(_ exchange: MemoryExchange, words: Set<String>) -> Double {
        guard !words.isEmpty else { return 0 }
        let userBM25 = bm25Score(document: exchange.userMessage, queryWords: words)
        let assistantBM25 = bm25Score(document: exchange.assistantMessage, queryWords: words)
        return min(1, userBM25 * 0.75 + assistantBM25 * 0.25)
    }

    /// BM25-style local term weighting. This keeps exact names and dates strong
    /// without letting common words dominate the semantic/vector score.
    private func bm25Score(document: String, queryWords: Set<String>) -> Double {
        let tokens = Self.keywords(in: document)
        guard !tokens.isEmpty else { return 0 }
        let documentLength = Double(tokens.count)
        let allDocuments = exchanges.map { "\($0.userMessage) \($0.assistantMessage)" }
        let averageLength = max(1, allDocuments
            .map { Double(Self.keywords(in: $0).count) }
            .reduce(0, +) / Double(max(allDocuments.count, 1)))
        let documentSet = Set(tokens)
        let totalDocuments = Double(max(allDocuments.count, 1))
        let k1 = 1.2
        let b = 0.75
        var raw = 0.0

        for word in queryWords {
            let termFrequency = Double(tokens.filter { $0 == word }.count)
            guard termFrequency > 0 else { continue }
            let documentFrequency = Double(allDocuments.reduce(into: 0) { count, candidate in
                if Set(Self.keywords(in: candidate)).contains(word) { count += 1 }
            })
            let idf = log((totalDocuments - documentFrequency + 0.5)
                / (documentFrequency + 0.5) + 1)
            let lengthNormalization = k1 * (1 - b + b * documentLength / averageLength)
            raw += idf * ((termFrequency * (k1 + 1)) / (termFrequency + lengthNormalization))
        }
        // Convert the unbounded BM25 sum into a stable 0...1 channel weight.
        return documentSet.isEmpty ? 0 : raw / (raw + 2)
    }

    private func tripleScore(_ query: MemoryTriple?, record: MemoryExchange) -> Double {
        guard let query, let triple = record.triple else { return 0 }
        let queryParts = Set([query.subject, query.predicate, query.object].map(Self.normalized))
        let recordParts = Set([triple.subject, triple.predicate, triple.object].map(Self.normalized))
        guard !queryParts.isEmpty else { return 0 }
        return Double(queryParts.intersection(recordParts).count) / Double(queryParts.count)
    }

    private func recencyScore(for exchange: MemoryExchange) -> Double {
        let days = max(0, Date().timeIntervalSince(exchange.timestamp) / 86_400)
        let decay: Double = switch exchange.memoryType {
        case .prospective: 0.020
        case .episodic, .spatial, .affective: 0.005
        default: 0.002
        }
        return exp(-decay * days)
    }

    private func importanceScore(for exchange: MemoryExchange) -> Double {
        let reinforcement = min(1, log1p(Double(exchange.reinforcementCount)) / log1p(10))
        let access = min(1, log1p(Double(exchange.accessCount)) / log1p(100))
        return min(1, 0.45 * exchange.confidence + 0.30 * reinforcement + 0.25 * access)
    }

    private func invalidateContradictions(with newRecord: MemoryExchange) {
        guard let newTriple = newRecord.triple else { return }
        for index in exchanges.indices {
            guard let oldTriple = exchanges[index].triple,
                  exchanges[index].invalidAt == nil,
                  Self.normalized(oldTriple.subject) == Self.normalized(newTriple.subject),
                  Self.normalized(oldTriple.predicate) == Self.normalized(newTriple.predicate),
                  Self.normalized(oldTriple.object) != Self.normalized(newTriple.object)
            else { continue }

            exchanges[index].invalidAt = newRecord.timestamp
            exchanges[index].confidence *= 0.5
            print("[Memory] invalidated contradicted fact \(exchanges[index].id.uuidString.prefix(8))")
        }
    }

    // MARK: - Graph

    private func rebuildGraph() {
        guard exchanges.count > 1 else { return }
        var links = Array(repeating: Set<UUID>(), count: exchanges.count)
        for left in exchanges.indices {
            for right in exchanges.indices where right > left {
                guard Self.related(exchanges[left], exchanges[right]) else { continue }
                links[left].insert(exchanges[right].id)
                links[right].insert(exchanges[left].id)
            }
        }
        for index in exchanges.indices {
            exchanges[index].relatedMemoryIDs = Array(links[index])
        }
    }

    private func graphDistances(from seeds: [UUID], maxHops: Int) -> [UUID: Int] {
        var distances: [UUID: Int] = [:]
        var queue = seeds.map { ($0, 0) }
        while !queue.isEmpty {
            let (id, distance) = queue.removeFirst()
            if distances[id] != nil || distance > maxHops { continue }
            distances[id] = distance
            guard let exchange = exchanges.first(where: { $0.id == id }) else { continue }
            for neighbor in exchange.relatedMemoryIDs where distances[neighbor] == nil {
                queue.append((neighbor, distance + 1))
            }
        }
        return distances
    }

    private func graphEdgeCount() -> Int {
        exchanges.reduce(0) { $0 + $1.relatedMemoryIDs.count } / 2
    }

    nonisolated private static func related(_ lhs: MemoryExchange, _ rhs: MemoryExchange) -> Bool {
        if let left = lhs.triple, let right = rhs.triple {
            let leftEntities = Set([left.subject, left.object].map(normalized))
            let rightEntities = Set([right.subject, right.object].map(normalized))
            if !leftEntities.isDisjoint(with: rightEntities) { return true }
        }
        let leftWords = Set(keywords(in: lhs.userMessage))
        let rightWords = Set(keywords(in: rhs.userMessage))
        return leftWords.intersection(rightWords).count >= 2
    }

    // MARK: - On-device embeddings

    private func embedding(for text: String) -> (vector: [Double], isSemantic: Bool) {
        let model = sentenceEmbedding ?? NLEmbedding.sentenceEmbedding(for: .english)
        if let vector = model?.vector(for: text), !vector.isEmpty {
            return (Self.normalizedVector(vector), true)
        }
        return (Self.hashedEmbedding(for: text, dimensions: 128), false)
    }

    nonisolated private static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        var dot = 0.0
        var leftMagnitude = 0.0
        var rightMagnitude = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            leftMagnitude += lhs[index] * lhs[index]
            rightMagnitude += rhs[index] * rhs[index]
        }
        guard leftMagnitude > 0, rightMagnitude > 0 else { return 0 }
        return max(0, min(1, dot / (sqrt(leftMagnitude) * sqrt(rightMagnitude))))
    }

    nonisolated private static func normalizedVector(_ vector: [Double]) -> [Double] {
        let magnitude = sqrt(vector.reduce(0) { $0 + ($1 * $1) })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    nonisolated private static func hashedEmbedding(for text: String, dimensions: Int) -> [Double] {
        var vector = Array(repeating: 0.0, count: dimensions)
        for word in keywords(in: text) {
            let hash = stableHash(word)
            let first = Int(hash % UInt64(dimensions))
            let second = Int((hash / UInt64(dimensions)) % UInt64(dimensions))
            vector[first] += 1
            vector[second] += 0.5
        }
        return normalizedVector(vector)
    }

    nonisolated private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    // MARK: - Local extraction

    nonisolated private static func classify(_ text: String) -> MemoryType {
        let value = normalized(text)
        if value.contains("remind") || value.contains("tomorrow") || value.contains("next week") || value.contains("will ") {
            return .prospective
        }
        if value.contains("how to") || value.contains("steps") || value.contains("workflow") {
            return .procedural
        }
        if value.contains("feel") || value.contains("happy") || value.contains("sad") || value.contains("angry") {
            return .affective
        }
        if value.contains("friend") || value.contains("mother") || value.contains("father") || value.contains("team") {
            return .social
        }
        if value.contains("live in") || value.contains("located") || value.contains("near ") || value.contains("address") {
            return .spatial
        }
        if value.contains("my ") || value.contains("i like") || value.contains("i prefer") || value.contains("favorite") || value.contains("name is") {
            return .factual
        }
        if value.contains("because") || value.contains("means") || value.contains("definition") {
            return .semantic
        }
        return .episodic
    }

    nonisolated private static func extractTriple(from text: String) -> MemoryTriple? {
        let value = normalized(text)
        let words = keywords(in: value)
        guard !words.isEmpty else { return nil }

        if let nameRange = value.range(of: "name is ") {
            let before = String(value[..<nameRange.lowerBound])
            let after = String(value[nameRange.upperBound...])
            let subject = before
                .replacingOccurrences(of: "my ", with: "")
                .replacingOccurrences(of: " dog's ", with: " ")
                .replacingOccurrences(of: " dog\'s ", with: " ")
                .split(separator: " ")
                .last
                .map(String.init)
            let object = after.split(separator: " ").first.map(String.init)
            if let subject, let object { return MemoryTriple(subject: subject, predicate: "name", object: object) }
        }

        for predicate in ["like", "love", "prefer", "hate"] {
            if let range = value.range(of: "i \(predicate) ") {
                let object = String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !object.isEmpty { return MemoryTriple(subject: "user", predicate: predicate, object: object) }
            }
        }

        if let myRange = value.range(of: "my ") {
            let remainder = String(value[myRange.upperBound...])
            let parts = remainder.components(separatedBy: " is ")
            if parts.count == 2, let subject = parts[0].split(separator: " ").first, let object = parts[1].split(separator: " ").first {
                return MemoryTriple(subject: String(subject), predicate: "is", object: String(object))
            }
        }
        return nil
    }

    nonisolated private static func keywords(in text: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "did", "does",
            "for", "from", "had", "has", "have", "how", "i", "in", "is", "it", "its", "me",
            "my", "not", "of", "on", "or", "that", "the", "this", "to", "was", "what", "when",
            "where", "which", "who", "why", "with", "would", "you", "your"
        ]
        let words = normalized(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        return Array(Set(words))
    }

    nonisolated private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func isUsefulForRecall(_ exchange: MemoryExchange) -> Bool {
        let answer = exchange.assistantMessage.lowercased()
        let genericRefusalMarkers = [
            "can't provide information or assistance",
            "cannot provide information or assistance",
            "could be used to harm a child",
        ]
        return !genericRefusalMarkers.contains { answer.contains($0) }
    }

    // MARK: - Persistence

    nonisolated private static func storeURL(fileName: String) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    nonisolated private static func load(from url: URL) -> [MemoryExchange] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([MemoryExchange].self, from: data)
        } catch {
            print("[Memory] load FAILED: \(error.localizedDescription)")
            return []
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(exchanges)
            try data.write(to: fileURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
            print("[Memory] persistence FAILED: \(error.localizedDescription)")
        }
    }
}
