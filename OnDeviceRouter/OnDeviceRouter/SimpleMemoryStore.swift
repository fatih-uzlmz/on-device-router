import Foundation
import NaturalLanguage

/// Fact-first, fully local memory inspired by MemLocal's useful concepts.
///
/// This store remains native Swift: deterministic extraction comes first, JSON
/// is versioned, raw turns expire, and only compact personal facts are eligible
/// for durable storage. The app-level MemLocal adapter only indexes active facts.
@available(iOS 26.0, *)
actor SimpleMemoryStore: MemoryStore {
    nonisolated private static let schemaVersion = 2
    nonisolated private static let durableCapacity = 200
    nonisolated private static let invalidatedCapacity = 100
    nonisolated private static let relationshipCapacity = 400
    nonisolated private static let episodeCapacity = 40
    nonisolated private static let turnCapacity = 24
    nonisolated private static let transientLifetime: TimeInterval = 24 * 60 * 60

    private struct StoreDocument: Codable {
        var version: Int
        var createdAt: Date
        var updatedAt: Date
        var durableFacts: [DurableFact]
        var relationships: [EntityRelationship]
        var episodes: [EpisodicMemory]
        var conversationTurns: [TemporaryConversationTurn]

        static func empty(now: Date = Date()) -> StoreDocument {
            StoreDocument(
                version: schemaVersion,
                createdAt: now,
                updatedAt: now,
                durableFacts: [],
                relationships: [],
                episodes: [],
                conversationTurns: []
            )
        }
    }

    /// Decoder for both the original five-field MVP and the later broad ledger.
    private struct LegacyExchange: Decodable {
        let userMessage: String
        let assistantMessage: String
        let route: String
        let timestamp: Date

        private enum CodingKeys: String, CodingKey {
            case userMessage, assistantMessage, route, timestamp
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            userMessage = try values.decode(String.self, forKey: .userMessage)
            assistantMessage = try values.decodeIfPresent(String.self, forKey: .assistantMessage) ?? ""
            route = try values.decodeIfPresent(String.self, forKey: .route) ?? "local"
            timestamp = try values.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        }
    }

    private struct ExtractedFact {
        let triple: MemoryTriple
        let statement: String
        let importance: Double
        let relationships: [MemoryTriple]
    }

    private struct RankedFact {
        let fact: DurableFact
        var score: Double
        let lexical: Double
        let semantic: Double
        let entity: Double
        let graphHops: Int?
    }

    private let fileURL: URL
    private var document: StoreDocument
    private var persistenceError: String?
    private var migrationStatus: String
    private var sentenceEmbedding: NLEmbedding?

    init(fileURL: URL? = nil) {
        let resolvedURL = fileURL ?? Self.storeURL(fileName: "memories.json")
        let loaded = Self.load(from: resolvedURL)
        self.fileURL = resolvedURL
        self.document = loaded.document
        self.migrationStatus = loaded.status
        self.persistenceError = loaded.error
        self.sentenceEmbedding = nil

        if loaded.shouldPersist {
            Self.write(document: loaded.document, to: resolvedURL)
        }
        print("[Memory] \(loaded.status); facts=\(loaded.document.durableFacts.filter(\.isActive).count), turns=\(loaded.document.conversationTurns.count)")
    }

    func ingest(userMessage: String, assistantMessage: String, route: String) async {
        await ingest(userMessage: userMessage, assistantMessage: assistantMessage,
                     route: route, extractedFacts: [])
    }

    func ingest(userMessage: String, assistantMessage: String, route: String,
                extractedFacts: [MemoryCandidate]) async {
        let now = Date()
        purgeExpired(now: now)

        document.conversationTurns.append(TemporaryConversationTurn(
            id: UUID(),
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            route: route,
            timestamp: now,
            expiresAt: now.addingTimeInterval(Self.transientLifetime)
        ))

        let activeFacts = document.durableFacts.filter(\.isActive)
        let modelFacts = extractedFacts.compactMap { candidate -> (ExtractedFact, UUID?)? in
            guard let valid = MemoryExtraction.validated(candidate, source: userMessage,
                                                         existingFacts: activeFacts) else { return nil }
            let replaced = valid.replacesFactID.flatMap { id in activeFacts.first { $0.id == id } }
            let triple = MemoryTriple(subject: replaced?.triple.subject ?? valid.subject,
                                      predicate: replaced?.triple.predicate ?? valid.predicate,
                                      object: valid.object)
            let statement = replaced.map {
                $0.statement.replacingOccurrences(of: $0.triple.object, with: valid.object)
            } ?? Self.statement(for: triple)
            return (ExtractedFact(triple: triple, statement: statement,
                                  importance: 0.9, relationships: []), replaced?.id)
        }
        let deterministicFacts = MemoryExtraction.sentences(in: userMessage)
            .flatMap { Self.extractDurableFacts(from: $0) }
        let facts = deterministicFacts.map { deterministic -> (ExtractedFact, UUID?) in
            // Keep the model's correction link even when a pattern also found
            // the new value. Otherwise a wording change can leave both active.
            if let model = modelFacts.first(where: {
                Self.normalized($0.0.triple.object) == Self.normalized(deterministic.triple.object)
                    && $0.1 != nil
            }) {
                return model
            }
            return (deterministic, nil)
        } + modelFacts.filter { modelFact in
            !deterministicFacts.contains {
                Self.normalized($0.triple.object) == Self.normalized(modelFact.0.triple.object)
            }
        }
        let episodes = Self.extractEpisodes(from: userMessage, now: now)
        if facts.isEmpty {
            print("[Memory][Extract] skipped durable storage: no personal fact in ‘\(Self.logSnippet(userMessage))’")
        } else {
            print("[Memory][Extract] \(facts.count) durable fact(s): \(facts.map { $0.0.statement }.joined(separator: " | "))")
        }

        for (extracted, replacedID) in facts {
            upsert(extracted, sourceText: userMessage, timestamp: now,
                   replacesFactID: replacedID)
        }
        for episode in episodes {
            document.episodes.removeAll { $0.kind == episode.kind }
            document.episodes.append(episode)
            print("[Memory][Episode] \(episode.kind)=\(episode.value), expires=\(episode.expiresAt)")
        }

        rebuildFactGraph()
        enforceBounds()
        persist()
    }

    func snapshot() async -> MemorySnapshot {
        purgeExpired(now: Date())
        let activeFacts = document.durableFacts
            .filter(\.isActive)
            .sorted { $0.updatedAt > $1.updatedAt }
        let invalidated = document.durableFacts
            .filter { !$0.isActive }
            .sorted { ($0.invalidatedAt ?? .distantPast) > ($1.invalidatedAt ?? .distantPast) }
        return MemorySnapshot(
            durableFacts: activeFacts,
            relationships: document.relationships.sorted { $0.createdAt > $1.createdAt },
            episodes: document.episodes.sorted { $0.createdAt > $1.createdAt },
            conversationTurns: document.conversationTurns.sorted { $0.timestamp > $1.timestamp },
            invalidatedFacts: invalidated
        )
    }

    func recall(matching query: String, limit: Int = 5) async -> MemoryRecall {
        purgeExpired(now: Date())
        let activeFacts = document.durableFacts.filter(\.isActive)
        let terms = Self.expandedQueryTerms(for: query)
        let topicTerms = Self.queryTopicTerms(for: query)
        let evidence = document.conversationTurns
            .sorted { $0.timestamp > $1.timestamp }
            .first { turn in
                !Set(Self.keywords(in: turn.userMessage)).isDisjoint(with: topicTerms)
                    && !turn.userMessage.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
            }.map { [$0] } ?? []
        guard !terms.isEmpty, !activeFacts.isEmpty else {
            print("[Memory][Recall] no candidates (terms=\(terms.count), activeFacts=\(activeFacts.count))")
            return MemoryRecall(facts: [], episodes: [], relationships: [],
                                conversationEvidence: evidence)
        }

        let queryEmbedding = embedding(for: query + " " + terms.joined(separator: " "))
        var ranked: [RankedFact] = activeFacts.compactMap { fact in
            // Broad relation words such as "name" can otherwise make an
            // unrelated memory look relevant to a domain-specific question.
            guard Self.matchesTopic(of: fact, topicTerms: topicTerms) else { return nil }

            let lexical = bm25Score(documentText: fact.statement + " " + fact.sources.map(\.text).joined(separator: " "),
                                    queryTerms: terms,
                                    corpus: activeFacts)
            let semantic = Self.cosine(queryEmbedding.vector, fact.embedding)
            let entity = Self.entityScore(fact.triple, queryTerms: terms)
            let qualifies = lexical > 0 || entity > 0 || (queryEmbedding.isSemantic && semantic >= 0.72)
            guard qualifies else { return nil }

            let ageDays = max(0, Date().timeIntervalSince(fact.updatedAt) / 86_400)
            let recency = exp(-0.001 * ageDays)
            let reinforcement = min(1, log1p(Double(fact.reinforcementCount)) / log1p(10))
            let importance = min(1, fact.importance * 0.65 + reinforcement * 0.35)
            let score = lexical * 0.32 + semantic * 0.24 + entity * 0.22
                + recency * 0.07 + importance * 0.15
            return RankedFact(fact: fact, score: score, lexical: lexical,
                              semantic: semantic, entity: entity, graphHops: nil)
        }

        let seedIDs = ranked.sorted { $0.score > $1.score }.prefix(4).map { $0.fact.id }
        let graphDistances = graphDistances(from: Array(seedIDs), maxHops: 2)
        let rankedIDs = Set(ranked.map { $0.fact.id })
        for fact in activeFacts where !rankedIDs.contains(fact.id) {
            guard let hops = graphDistances[fact.id], hops > 0 else { continue }
            ranked.append(RankedFact(
                fact: fact,
                score: hops == 1 ? 0.22 : 0.12,
                lexical: 0,
                semantic: 0,
                entity: 0,
                graphHops: hops
            ))
            print("[Memory][Graph] expanded \(hops) hop(s) to \(fact.statement)")
        }

        ranked = ranked.map { item in
            guard let hops = graphDistances[item.fact.id], hops > 0 else { return item }
            var updated = item
            updated.score += hops == 1 ? 0.12 : 0.06
            return updated
        }

        let selectedRanked = ranked.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.fact.updatedAt > $1.fact.updatedAt
        }.prefix(max(1, min(limit, 8)))
        let selected = selectedRanked.map(\.fact)
        let selectedIDs = Set(selected.map(\.id))

        for index in document.durableFacts.indices where selectedIDs.contains(document.durableFacts[index].id) {
            document.durableFacts[index].accessCount += 1
            document.durableFacts[index].lastAccessedAt = Date()
        }

        let relevantEpisodes = document.episodes.filter { episode in
            !Set(Self.keywords(in: episode.value + " " + episode.kind)).isDisjoint(with: Set(terms))
        }.prefix(2)
        let relevantRelationships = document.relationships.filter {
            $0.isActive && selectedIDs.contains($0.sourceFactID)
        }

        for item in selectedRanked {
            print("[Memory][Recall] candidate score=\(Self.format(item.score)) lex=\(Self.format(item.lexical)) sem=\(Self.format(item.semantic)) entity=\(Self.format(item.entity)) graph=\(item.graphHops.map(String.init) ?? "-") :: \(item.fact.statement)")
        }
        if !selected.isEmpty { persist() }
        return MemoryRecall(facts: selected,
                            episodes: Array(relevantEpisodes),
                            relationships: relevantRelationships,
                            conversationEvidence: evidence)
    }

    func count() async -> Int {
        document.durableFacts.filter(\.isActive).count
    }

    /// Records recall hits supplied by an additional retrieval index.
    func recordExternalRecall(_ factIDs: Set<UUID>) {
        guard !factIDs.isEmpty else { return }
        let accessedAt = Date()
        for index in document.durableFacts.indices where factIDs.contains(document.durableFacts[index].id) {
            document.durableFacts[index].accessCount += 1
            document.durableFacts[index].lastAccessedAt = accessedAt
        }
        persist()
    }

    func diagnostics() async -> MemoryDiagnostics {
        purgeExpired(now: Date())
        let activeFacts = document.durableFacts.filter(\.isActive)
        let invalidated = document.durableFacts.count - activeFacts.count
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return MemoryDiagnostics(
            storedCount: activeFacts.count + document.episodes.count + document.conversationTurns.count,
            durableFactCount: activeFacts.count,
            relationshipCount: document.relationships.filter(\.isActive).count,
            episodicCount: document.episodes.count,
            temporaryTurnCount: document.conversationTurns.count,
            invalidatedFactCount: invalidated,
            filePath: fileURL.path,
            fileExists: FileManager.default.fileExists(atPath: fileURL.path),
            fileSizeBytes: size,
            persistenceError: persistenceError,
            embeddedCount: activeFacts.filter { !$0.embedding.isEmpty }.count,
            graphEdgeCount: activeFacts.reduce(0) { $0 + $1.relatedFactIDs.count } / 2,
            schemaVersion: document.version,
            migrationStatus: migrationStatus,
            typeCounts: [
                MemoryRecordKind.durableFact.rawValue: activeFacts.count,
                MemoryRecordKind.relationship.rawValue: document.relationships.filter(\.isActive).count,
                MemoryRecordKind.episodic.rawValue: document.episodes.count,
                MemoryRecordKind.conversationTurn.rawValue: document.conversationTurns.count,
                MemoryRecordKind.invalidatedFact.rawValue: invalidated,
            ]
        )
    }

    func clear() async {
        document = .empty()
        migrationStatus = "Created schema v\(Self.schemaVersion)"
        persist()
        print("[Memory] cleared facts, relationships, episodes, and temporary turns")
    }

    // MARK: - Fact lifecycle

    private func upsert(_ extracted: ExtractedFact, sourceText: String, timestamp: Date,
                        replacesFactID: UUID? = nil) {
        let key = Self.factKey(extracted.triple)
        let object = Self.normalized(extracted.triple.object)
        if let index = document.durableFacts.firstIndex(where: {
            $0.isActive && Self.factKey($0.triple) == key
                && Self.normalized($0.triple.object) == object
        }) {
            document.durableFacts[index].updatedAt = timestamp
            document.durableFacts[index].confidence = min(1, document.durableFacts[index].confidence + 0.03)
            document.durableFacts[index].reinforcementCount += 1
            if !document.durableFacts[index].sources.contains(where: { $0.text == sourceText }) {
                document.durableFacts[index].sources.append(FactSource(text: sourceText, timestamp: timestamp))
                document.durableFacts[index].sources = Array(document.durableFacts[index].sources.suffix(5))
            }
            print("[Memory][Dedup] reinforced \(extracted.statement) count=\(document.durableFacts[index].reinforcementCount)")
            return
        }

        if Self.singleValuedPredicates.contains(Self.normalized(extracted.triple.predicate))
            || replacesFactID != nil {
            for index in document.durableFacts.indices where document.durableFacts[index].isActive
                && (Self.factKey(document.durableFacts[index].triple) == key
                    || document.durableFacts[index].id == replacesFactID)
                && Self.normalized(document.durableFacts[index].triple.object) != object {
                document.durableFacts[index].invalidatedAt = timestamp
                document.durableFacts[index].confidence *= 0.5
                let invalidID = document.durableFacts[index].id
                for relationshipIndex in document.relationships.indices
                    where document.relationships[relationshipIndex].sourceFactID == invalidID {
                    document.relationships[relationshipIndex].invalidatedAt = timestamp
                }
                print("[Memory][Contradiction] invalidated \(document.durableFacts[index].statement) → \(extracted.statement)")
            }
        }

        let factID = UUID()
        let fact = DurableFact(
            id: factID,
            triple: extracted.triple,
            statement: extracted.statement,
            sources: [FactSource(text: sourceText, timestamp: timestamp)],
            createdAt: timestamp,
            updatedAt: timestamp,
            invalidatedAt: nil,
            confidence: 0.92,
            reinforcementCount: 1,
            accessCount: 0,
            lastAccessedAt: nil,
            importance: extracted.importance,
            embedding: embedding(for: extracted.statement).vector,
            relatedFactIDs: []
        )
        document.durableFacts.append(fact)
        for triple in Self.uniqueTriples([extracted.triple] + extracted.relationships) {
            document.relationships.append(EntityRelationship(
                id: UUID(), triple: triple, sourceFactID: factID,
                createdAt: timestamp, invalidatedAt: nil, confidence: 0.92
            ))
        }
        print("[Memory][Store] added durable fact \(extracted.statement)")
    }

    private func rebuildFactGraph() {
        let activeIndices = document.durableFacts.indices.filter { document.durableFacts[$0].isActive }
        var links: [UUID: Set<UUID>] = [:]
        for leftOffset in activeIndices.indices {
            let leftIndex = activeIndices[leftOffset]
            for rightOffset in activeIndices.indices where rightOffset > leftOffset {
                let rightIndex = activeIndices[rightOffset]
                let left = document.durableFacts[leftIndex]
                let right = document.durableFacts[rightIndex]
                guard Self.factsAreRelated(left, right, relationships: document.relationships) else { continue }
                links[left.id, default: []].insert(right.id)
                links[right.id, default: []].insert(left.id)
            }
        }
        for index in document.durableFacts.indices {
            document.durableFacts[index].relatedFactIDs = Array(links[document.durableFacts[index].id] ?? [])
        }
    }

    private func graphDistances(from seeds: [UUID], maxHops: Int) -> [UUID: Int] {
        var distances: [UUID: Int] = [:]
        var queue = seeds.map { ($0, 0) }
        while !queue.isEmpty {
            let (id, distance) = queue.removeFirst()
            if distances[id] != nil || distance > maxHops { continue }
            distances[id] = distance
            guard let fact = document.durableFacts.first(where: { $0.id == id && $0.isActive }) else { continue }
            queue.append(contentsOf: fact.relatedFactIDs.map { ($0, distance + 1) })
        }
        return distances
    }

    // MARK: - Deterministic extraction

    nonisolated private static let relativeKinds: Set<String> = [
        "sister", "brother", "mother", "father", "mom", "dad", "wife", "husband", "partner"
    ]
    nonisolated private static let petKinds: Set<String> = ["dog", "cat", "bird", "rabbit", "pet"]
    nonisolated private static let singleValuedPredicates: Set<String> = ["name", "lives_in", "value"]
    nonisolated private static let genericMemoryQueryTerms: Set<String> = [
        "name", "named", "fact", "facts", "memory", "memories", "remember", "saved", "stored",
        "told", "asked", "know", "about"
    ]
    nonisolated private static let queryExpansions: [String: Set<String>] = [
        "dog": ["pet", "owns", "name"], "pet": ["dog", "cat", "owns", "name"],
        "name": ["named"], "dessert": ["cake", "chocolate", "likes", "prefers"],
        "supermarket": ["food", "cake", "chocolate", "likes", "prefers"],
        "family": ["sister", "brother", "mother", "father", "mom", "dad", "wife", "husband", "partner"],
        "restaurant": ["place", "places", "prefers", "likes"],
        "where": ["lives", "location"], "live": ["lives", "location"],
    ]

    nonisolated private static func extractDurableFacts(from source: String) -> [ExtractedFact] {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
        guard !text.isEmpty, !text.contains("?") else { return [] }

        // An explicit "remember …" request is a durable assertion even when
        // it does not fit one of the narrower personal-fact patterns below.
        // Ignore any conversational lead-in before the word "remember".
        if let remembered = captures(#"\bremember\s+(?:that\s+)?(.+)$"#, in: text)?.first {
            let content = remembered.trimmingCharacters(in: .whitespacesAndNewlines)
            let structuredFacts = extractDurableFacts(from: content)
            if !structuredFacts.isEmpty { return structuredFacts }

            if let assertion = captures(#"^(.+?)\s+(?:is|are|=)\s+(.+?)[.!]?$"#, in: content) {
                return [rememberedAssertionFact(subject: assertion[0], value: assertion[1])]
            }
        }

        if let captures = captures(#"^my\s+([a-z][a-z -]*?)'s\s+name\s+is\s+(.+?)[.!]?$"#, in: text) {
            return [namedEntityFact(kind: captures[0], name: captures[1])]
        }
        if let captures = captures(#"^my\s+([a-z][a-z -]*?)\s+is\s+named\s+(.+?)[.!]?$"#, in: text) {
            return [namedEntityFact(kind: captures[0], name: captures[1])]
        }
        if let captures = captures(#"^i\s+have\s+(?:a|an)\s+([a-z][a-z -]*?)\s+named\s+(.+?)[.!]?$"#, in: text) {
            return [namedEntityFact(kind: captures[0], name: captures[1])]
        }
        if let captures = captures(#"^my\s+(sister|brother|mother|father|mom|dad|wife|husband|partner)\s+is\s+(.+?)[.!]?$"#, in: text) {
            return [namedEntityFact(kind: captures[0], name: captures[1])]
        }
        if let captures = captures(#"^my\s+(?:favorite|favourite|fav)\s+([a-z][a-z0-9 -]*?)\s+is\s+(.+?)[.!]?$"#, in: text) {
            let kind = normalized(captures[0]).replacingOccurrences(of: " ", with: "_")
            let value = cleanObject(captures[1])
            return [ExtractedFact(
                triple: MemoryTriple(subject: "user_favorite_\(kind)", predicate: "value", object: value),
                statement: "User's favorite \(captures[0].lowercased()) is \(value).",
                importance: 0.9,
                relationships: []
            )]
        }
        if let captures = captures(#"^my\s+([a-z][a-z -]*?)\s+(loves|likes|prefers|hates)\s+(.+?)[.!]?$"#, in: text) {
            let kind = normalized(captures[0]).replacingOccurrences(of: " ", with: "_")
            let verb = canonicalPreferenceVerb(captures[1])
            let object = cleanObject(captures[2])
            return [ExtractedFact(
                triple: MemoryTriple(subject: "user_\(kind)", predicate: verb, object: object),
                statement: "User's \(captures[0].lowercased()) \(displayVerb(verb)) \(object).",
                importance: 0.86,
                relationships: []
            )]
        }
        if let captures = captures(#"^i\s+(like|love|prefer|hate)\s+(.+?)[.!]?$"#, in: text) {
            let verb = canonicalPreferenceVerb(captures[0])
            let object = cleanObject(captures[1])
            return [ExtractedFact(
                triple: MemoryTriple(subject: "user", predicate: verb, object: object),
                statement: "User \(displayVerb(verb)) \(object).",
                importance: 0.78,
                relationships: []
            )]
        }
        if let captures = captures(#"^i\s+live\s+in\s+(.+?)[.!]?$"#, in: text) {
            let place = cleanObject(captures[0])
            return [ExtractedFact(
                triple: MemoryTriple(subject: "user", predicate: "lives_in", object: place),
                statement: "User lives in \(place).",
                importance: 0.9,
                relationships: []
            )]
        }
        return []
    }

    nonisolated private static func rememberedAssertionFact(subject rawSubject: String, value rawValue: String) -> ExtractedFact {
        let subjectText = cleanObject(rawSubject)
            .replacingOccurrences(
                of: #"^(?:the|a|an|my|our|your|this|that|thr)\s+"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        let subjectTerms = keywords(in: subjectText)
        let subject = subjectTerms.isEmpty ? "remembered_item" : subjectTerms.joined(separator: "_")
        let value = cleanObject(rawValue)
        let readableSubject = subjectTerms.isEmpty ? subjectText : subjectTerms.joined(separator: " ")
        return ExtractedFact(
            triple: MemoryTriple(subject: "user_\(subject)", predicate: "value", object: value),
            statement: "Remembered: \(readableSubject) is \(value).",
            importance: 0.93,
            relationships: []
        )
    }

    nonisolated private static func namedEntityFact(kind rawKind: String, name rawName: String) -> ExtractedFact {
        let kind = normalized(rawKind).replacingOccurrences(of: " ", with: "_")
        let name = cleanObject(rawName)
        let subject = "user_\(kind)"
        var relationships = [MemoryTriple(subject: name, predicate: "is_a", object: rawKind.lowercased())]
        let statement: String
        if petKinds.contains(kind) {
            relationships.insert(MemoryTriple(subject: "user", predicate: "owns", object: name), at: 0)
            statement = "User has a \(rawKind.lowercased()) named \(name)."
        } else if relativeKinds.contains(kind) {
            relationships.insert(MemoryTriple(subject: "user", predicate: "has_\(kind)", object: name), at: 0)
            statement = "User's \(rawKind.lowercased()) is named \(name)."
        } else {
            statement = "User's \(rawKind.lowercased()) is named \(name)."
        }
        return ExtractedFact(
            triple: MemoryTriple(subject: subject, predicate: "name", object: name),
            statement: statement,
            importance: 0.95,
            relationships: relationships
        )
    }

    nonisolated private static func statement(for triple: MemoryTriple) -> String {
        let subject = triple.subject.replacingOccurrences(of: "_", with: " ")
        let predicate = triple.predicate.replacingOccurrences(of: "_", with: " ")
        return "\(subject.capitalized) \(predicate) \(triple.object)."
    }

    nonisolated private static func extractEpisodes(from source: String, now: Date) -> [EpisodicMemory] {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
        var results: [EpisodicMemory] = []
        if let captures = captures(#"^i(?:'m|\s+am)\s+(?:currently\s+)?working\s+on\s+(.+?)[.!]?$"#, in: text) {
            results.append(episode(kind: "current_task", value: captures[0], source: source, now: now))
        } else if let captures = captures(#"^i(?:'m|\s+am)\s+(?:currently\s+)?(?:at|in)\s+(.+?)[.!]?$"#, in: text) {
            results.append(episode(kind: "current_location", value: captures[0], source: source, now: now))
        }
        return results
    }

    nonisolated private static func episode(kind: String, value: String, source: String, now: Date) -> EpisodicMemory {
        EpisodicMemory(
            id: UUID(), kind: kind, value: cleanObject(value), sourceText: source,
            createdAt: now, expiresAt: now.addingTimeInterval(transientLifetime)
        )
    }

    // MARK: - Retrieval

    private func bm25Score(documentText: String, queryTerms: [String], corpus: [DurableFact]) -> Double {
        let tokens = Self.keywords(in: documentText)
        guard !tokens.isEmpty else { return 0 }
        let averageLength = max(1, corpus.map { Double(Self.keywords(in: $0.statement).count) }.reduce(0, +)
            / Double(max(corpus.count, 1)))
        let documentLength = Double(tokens.count)
        let totalDocuments = Double(max(corpus.count, 1))
        let k1 = 1.2
        let b = 0.75
        var raw = 0.0
        for term in Set(queryTerms) {
            let frequency = Double(tokens.filter { $0 == term }.count)
            guard frequency > 0 else { continue }
            let documentFrequency = Double(corpus.reduce(into: 0) { count, fact in
                if Set(Self.keywords(in: fact.statement)).contains(term) { count += 1 }
            })
            let idf = log((totalDocuments - documentFrequency + 0.5) / (documentFrequency + 0.5) + 1)
            let normalization = k1 * (1 - b + b * documentLength / averageLength)
            raw += idf * (frequency * (k1 + 1) / (frequency + normalization))
        }
        return raw / (raw + 2)
    }

    nonisolated private static func expandedQueryTerms(for query: String) -> [String] {
        var terms = Set(keywords(in: query))
        for term in Array(terms) {
            terms.formUnion(queryExpansions[term] ?? [])
        }
        return Array(terms)
    }

    nonisolated private static func queryTopicTerms(for query: String) -> Set<String> {
        let terms = Set(keywords(in: query))
        var topics = terms.subtracting(genericMemoryQueryTerms)
        for term in terms {
            topics.formUnion((queryExpansions[term] ?? []).subtracting(genericMemoryQueryTerms))
        }
        return topics
    }

    nonisolated static func matchesTopic(of fact: DurableFact, query: String) -> Bool {
        matchesTopic(of: fact, topicTerms: queryTopicTerms(for: query))
    }

    nonisolated private static func matchesTopic(of fact: DurableFact, topicTerms: Set<String>) -> Bool {
        guard !topicTerms.isEmpty else { return true }
        let factTerms = Set(keywords(in: fact.statement + " " + fact.triple.subject + " "
            + fact.triple.predicate + " " + fact.triple.object + " "
            + fact.sources.map(\.text).joined(separator: " ")))
        return !topicTerms.isDisjoint(with: factTerms)
    }

    nonisolated private static func entityScore(_ triple: MemoryTriple, queryTerms: [String]) -> Double {
        let entityTerms = Set(keywords(in: triple.subject + " " + triple.predicate + " " + triple.object))
        guard !entityTerms.isEmpty else { return 0 }
        return min(1, Double(entityTerms.intersection(Set(queryTerms)).count) / 2)
    }

    // MARK: - Embeddings

    private func embedding(for text: String) -> (vector: [Double], isSemantic: Bool) {
        if sentenceEmbedding == nil {
            sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
        }
        if let vector = sentenceEmbedding?.vector(for: text), !vector.isEmpty {
            return (Self.normalizedVector(vector), true)
        }
        return (Self.hashedEmbedding(for: text, dimensions: 128), false)
    }

    nonisolated private static func hashedEmbedding(for text: String, dimensions: Int) -> [Double] {
        var vector = Array(repeating: 0.0, count: dimensions)
        for word in keywords(in: text) {
            let hash = stableHash(word)
            vector[Int(hash % UInt64(dimensions))] += 1
            vector[Int((hash / UInt64(dimensions)) % UInt64(dimensions))] += 0.5
        }
        return normalizedVector(vector)
    }

    nonisolated private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    nonisolated private static func normalizedVector(_ vector: [Double]) -> [Double] {
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        return magnitude > 0 ? vector.map { $0 / magnitude } : vector
    }

    nonisolated private static func cosine(_ left: [Double], _ right: [Double]) -> Double {
        guard !left.isEmpty, left.count == right.count else { return 0 }
        let dot = zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
        let leftMagnitude = sqrt(left.reduce(0) { $0 + $1 * $1 })
        let rightMagnitude = sqrt(right.reduce(0) { $0 + $1 * $1 })
        guard leftMagnitude > 0, rightMagnitude > 0 else { return 0 }
        return max(0, min(1, dot / (leftMagnitude * rightMagnitude)))
    }

    // MARK: - Persistence and migration

    private func purgeExpired(now: Date) {
        let oldEpisodeCount = document.episodes.count
        let oldTurnCount = document.conversationTurns.count
        document.episodes.removeAll { $0.expiresAt <= now }
        document.conversationTurns.removeAll { $0.expiresAt <= now }
        if oldEpisodeCount != document.episodes.count || oldTurnCount != document.conversationTurns.count {
            print("[Memory][Lifecycle] expired \(oldEpisodeCount - document.episodes.count) episode(s), \(oldTurnCount - document.conversationTurns.count) turn(s)")
            persist()
        }
    }

    private func enforceBounds() {
        let active = document.durableFacts.filter(\.isActive).sorted { $0.updatedAt > $1.updatedAt }
        let invalidated = document.durableFacts.filter { !$0.isActive }
            .sorted { ($0.invalidatedAt ?? .distantPast) > ($1.invalidatedAt ?? .distantPast) }
        let keptActive = Array(active.prefix(Self.durableCapacity))
        let keptInvalidated = Array(invalidated.prefix(Self.invalidatedCapacity))
        let keptFactIDs = Set((keptActive + keptInvalidated).map(\.id))
        document.durableFacts = keptActive + keptInvalidated
        document.relationships = Array(document.relationships
            .filter { keptFactIDs.contains($0.sourceFactID) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(Self.relationshipCapacity))
        document.episodes = Array(document.episodes.sorted { $0.createdAt > $1.createdAt }.prefix(Self.episodeCapacity))
        document.conversationTurns = Array(document.conversationTurns.sorted { $0.timestamp > $1.timestamp }.prefix(Self.turnCapacity))
    }

    private func persist() {
        document.version = Self.schemaVersion
        document.updatedAt = Date()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: fileURL, options: .atomic)
            persistenceError = nil
            print("[Memory][Persistence] schema=v\(document.version), bytes=\(data.count), facts=\(document.durableFacts.count), turns=\(document.conversationTurns.count), migration=\(migrationStatus)")
        } catch {
            persistenceError = error.localizedDescription
            print("[Memory][Persistence] FAILED: \(error.localizedDescription)")
        }
    }

    nonisolated private static func load(from url: URL) -> (document: StoreDocument, status: String, error: String?, shouldPersist: Bool) {
        guard let data = try? Data(contentsOf: url) else {
            return (.empty(), "Created schema v\(schemaVersion)", nil, false)
        }
        do {
            let document = try JSONDecoder().decode(StoreDocument.self, from: data)
            guard document.version <= schemaVersion else {
                return (.empty(), "Unsupported future schema v\(document.version)", "Memory schema is newer than this app", false)
            }
            return (document, "Loaded schema v\(document.version)", nil, document.version < schemaVersion)
        } catch {
            do {
                let exchanges = try JSONDecoder().decode([LegacyExchange].self, from: data)
                let migrated = migrate(exchanges: exchanges)
                return (migrated, "Migrated \(exchanges.count) legacy turn(s) to schema v\(schemaVersion)", nil, true)
            } catch let migrationError {
                return (.empty(), "Load failed; preserved unreadable file", migrationError.localizedDescription, false)
            }
        }
    }

    nonisolated private static func migrate(exchanges: [LegacyExchange]) -> StoreDocument {
        let now = Date()
        var result = StoreDocument.empty(now: now)
        for exchange in exchanges.sorted(by: { $0.timestamp < $1.timestamp }) {
            for extracted in extractDurableFacts(from: exchange.userMessage) {
                let key = factKey(extracted.triple)
                let object = normalized(extracted.triple.object)
                if let duplicate = result.durableFacts.firstIndex(where: {
                    $0.isActive && factKey($0.triple) == key && normalized($0.triple.object) == object
                }) {
                    result.durableFacts[duplicate].reinforcementCount += 1
                    result.durableFacts[duplicate].updatedAt = exchange.timestamp
                    continue
                }
                if singleValuedPredicates.contains(normalized(extracted.triple.predicate)) {
                    for index in result.durableFacts.indices where result.durableFacts[index].isActive
                        && factKey(result.durableFacts[index].triple) == key {
                        result.durableFacts[index].invalidatedAt = exchange.timestamp
                        let invalidID = result.durableFacts[index].id
                        for relationshipIndex in result.relationships.indices
                            where result.relationships[relationshipIndex].sourceFactID == invalidID {
                            result.relationships[relationshipIndex].invalidatedAt = exchange.timestamp
                        }
                    }
                }
                let factID = UUID()
                result.durableFacts.append(DurableFact(
                    id: factID, triple: extracted.triple, statement: extracted.statement,
                    sources: [FactSource(text: exchange.userMessage, timestamp: exchange.timestamp)],
                    createdAt: exchange.timestamp, updatedAt: exchange.timestamp,
                    invalidatedAt: nil, confidence: 0.9, reinforcementCount: 1,
                    accessCount: 0, lastAccessedAt: nil, importance: extracted.importance,
                    embedding: hashedEmbedding(for: extracted.statement, dimensions: 128), relatedFactIDs: []
                ))
                for triple in uniqueTriples([extracted.triple] + extracted.relationships) {
                    result.relationships.append(EntityRelationship(
                        id: UUID(), triple: triple, sourceFactID: factID,
                        createdAt: exchange.timestamp, invalidatedAt: nil, confidence: 0.9
                    ))
                }
            }
            if exchange.timestamp.addingTimeInterval(transientLifetime) > now {
                result.conversationTurns.append(TemporaryConversationTurn(
                    id: UUID(), userMessage: exchange.userMessage,
                    assistantMessage: exchange.assistantMessage, route: exchange.route,
                    timestamp: exchange.timestamp,
                    expiresAt: exchange.timestamp.addingTimeInterval(transientLifetime)
                ))
            }
        }
        result.durableFacts = Array(result.durableFacts.suffix(durableCapacity + invalidatedCapacity))
        result.relationships = Array(result.relationships.suffix(relationshipCapacity))
        result.conversationTurns = Array(result.conversationTurns.suffix(turnCapacity))
        rebuildMigratedGraph(in: &result)
        return result
    }

    nonisolated private static func rebuildMigratedGraph(in document: inout StoreDocument) {
        let activeIndices = document.durableFacts.indices.filter { document.durableFacts[$0].isActive }
        var links: [UUID: Set<UUID>] = [:]
        for leftOffset in activeIndices.indices {
            let leftIndex = activeIndices[leftOffset]
            for rightOffset in activeIndices.indices where rightOffset > leftOffset {
                let rightIndex = activeIndices[rightOffset]
                let left = document.durableFacts[leftIndex]
                let right = document.durableFacts[rightIndex]
                guard factsAreRelated(left, right, relationships: document.relationships) else { continue }
                links[left.id, default: []].insert(right.id)
                links[right.id, default: []].insert(left.id)
            }
        }
        for index in document.durableFacts.indices {
            document.durableFacts[index].relatedFactIDs = Array(links[document.durableFacts[index].id] ?? [])
        }
    }

    nonisolated private static func write(document: StoreDocument, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: url, options: .atomic)
        } catch {
            print("[Memory][Migration] persistence FAILED: \(error.localizedDescription)")
        }
    }

    nonisolated private static func storeURL(fileName: String) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    // MARK: - Helpers

    nonisolated private static func factsAreRelated(
        _ left: DurableFact,
        _ right: DurableFact,
        relationships: [EntityRelationship]
    ) -> Bool {
        let leftEntities = graphEntityTerms(in: left.triple.subject + " " + left.triple.object)
        let rightEntities = graphEntityTerms(in: right.triple.subject + " " + right.triple.object)
        if !leftEntities.isDisjoint(with: rightEntities) { return true }

        let leftRelations = relationships.filter { $0.isActive && $0.sourceFactID == left.id }.map(\.triple)
        let rightRelations = relationships.filter { $0.isActive && $0.sourceFactID == right.id }.map(\.triple)
        let leftGraphEntities = Set(leftRelations.flatMap { graphEntityTerms(in: $0.subject + " " + $0.object) })
        let rightGraphEntities = Set(rightRelations.flatMap { graphEntityTerms(in: $0.subject + " " + $0.object) })
        return !leftGraphEntities.isDisjoint(with: rightGraphEntities)
    }

    nonisolated private static func graphEntityTerms(in text: String) -> Set<String> {
        // `user` is a universal graph hub, not evidence that two facts are related.
        Set(keywords(in: text)).subtracting(["user"])
    }

    nonisolated private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range), match.range.location != NSNotFound else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }

    nonisolated private static func canonicalPreferenceVerb(_ value: String) -> String {
        switch normalized(value) {
        case "love", "loves", "like", "likes": "likes"
        case "prefer", "prefers": "prefers"
        default: "hates"
        }
    }

    nonisolated private static func displayVerb(_ value: String) -> String {
        switch value {
        case "likes": "likes"
        case "prefers": "prefers"
        default: "dislikes"
        }
    }

    nonisolated private static func cleanObject(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    nonisolated private static func factKey(_ triple: MemoryTriple) -> String {
        normalized(triple.subject) + "|" + normalized(triple.predicate)
    }

    nonisolated private static func uniqueTriples(_ triples: [MemoryTriple]) -> [MemoryTriple] {
        var seen: Set<String> = []
        return triples.filter {
            seen.insert(factKey($0) + "|" + normalized($0.object)).inserted
        }
    }

    nonisolated private static func keywords(in text: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "did", "does",
            "for", "from", "had", "has", "have", "how", "i", "in", "is", "it", "its", "me",
            "my", "not", "of", "on", "or", "that", "the", "this", "to", "was", "what", "when",
            "which", "who", "why", "with", "would", "you", "your"
        ]
        return normalized(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    nonisolated private static func logSnippet(_ text: String) -> String {
        String(text.prefix(80)).replacingOccurrences(of: "\n", with: " ")
    }

    nonisolated private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
