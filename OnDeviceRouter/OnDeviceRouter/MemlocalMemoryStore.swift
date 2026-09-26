import Foundation
import MemlocalCore

/// Keeps Swift authoritative while maintaining a persistent, verified
/// MemLocal shadow ledger and using its text index for supplemental recall.
@available(iOS 26.0, *)
actor MemlocalMemoryStore: MemoryStore {
    private let primary: SimpleMemoryStore
    private var index: MemlocalSearchIndex?
    private var didHydrateIndex = false
    private var hydrationTask: Task<MemorySnapshot, Never>?
    private var indexFailure: String?

    init(primary: SimpleMemoryStore = SimpleMemoryStore()) {
        self.primary = primary
        self.index = nil
    }

    func ingest(userMessage: String, assistantMessage: String, route: String) async {
        await ingest(userMessage: userMessage, assistantMessage: assistantMessage,
                     route: route, extractedFacts: [])
    }

    func ingest(userMessage: String, assistantMessage: String, route: String,
                extractedFacts: [MemoryCandidate]) async {
        await ensureIndexIsHydrated()
        await primary.ingest(userMessage: userMessage,
                             assistantMessage: assistantMessage,
                             route: route, extractedFacts: extractedFacts)
        synchronizeLedger(with: await primary.snapshot())
    }

    func snapshot() async -> MemorySnapshot {
        await primary.snapshot()
    }

    func recall(matching query: String, limit: Int) async -> MemoryRecall {
        await ensureIndexIsHydrated()
        let swiftRecall = await primary.recall(matching: query, limit: limit)
        guard isIndexAvailable, let index else { return swiftRecall }

        let snapshot = await primary.snapshot()
        let factsByID = Dictionary(uniqueKeysWithValues: snapshot.durableFacts.map {
            ($0.id.uuidString, $0)
        })
        var facts = swiftRecall.facts
        var selectedIDs = Set(facts.map(\.id))
        var supplementalIDs = Set<UUID>()
        let resultLimit = max(1, min(limit, 8))

        for id in index.search(query: query, limit: max(resultLimit * 2, 8)) {
            guard let fact = factsByID[id],
                  SimpleMemoryStore.matchesTopic(of: fact, query: query),
                  selectedIDs.insert(fact.id).inserted else { continue }
            facts.append(fact)
            supplementalIDs.insert(fact.id)
            if facts.count >= resultLimit { break }
        }

        guard !supplementalIDs.isEmpty else { return swiftRecall }
        await primary.recordExternalRecall(supplementalIDs)

        var relationshipsByID = Dictionary(uniqueKeysWithValues: swiftRecall.relationships.map {
            ($0.id, $0)
        })
        for relationship in snapshot.relationships
        where relationship.isActive && selectedIDs.contains(relationship.sourceFactID) {
            relationshipsByID[relationship.id] = relationship
        }

        print("[Memory][Memlocal] added \(supplementalIDs.count) text-search result(s)")
        return MemoryRecall(
            facts: facts,
            episodes: swiftRecall.episodes,
            relationships: relationshipsByID.values.sorted { $0.createdAt > $1.createdAt },
            conversationEvidence: swiftRecall.conversationEvidence
        )
    }

    func count() async -> Int {
        await primary.count()
    }

    func diagnostics() async -> MemoryDiagnostics {
        await ensureIndexIsHydrated()
        return await primary.diagnostics()
    }

    func clear() async {
        await ensureIndexIsHydrated()
        await primary.clear()
        index?.close()
        index = nil
        do {
            try Self.removeLedgerDatabaseFiles()
            indexFailure = nil
            didHydrateIndex = false
            hydrationTask = nil
            await ensureIndexIsHydrated()
        } catch {
            disableIndex("could not remove cleared shadow ledger: \(error.localizedDescription)")
        }
    }

    private var isIndexAvailable: Bool {
        index?.isAvailable == true && indexFailure == nil
    }

    private func ensureIndexIsHydrated() async {
        guard !didHydrateIndex else { return }
        if hydrationTask == nil {
            hydrationTask = Task { await primary.snapshot() }
        }
        guard let hydrationTask else { return }
        let snapshot = await hydrationTask.value
        guard !didHydrateIndex else { return }
        self.hydrationTask = nil

        do {
            let envelope = try MemoryLedgerTransferEnvelope(snapshot: snapshot)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(envelope)
            guard let json = String(data: data, encoding: .utf8) else {
                throw LedgerShadowError.invalidUTF8
            }
            let verified = try Self.openVerifiedLedger(envelope: envelope, json: json)
            index = verified
            indexFailure = nil
            print("[Memory][Memlocal] persistent ledger ready; records=\(envelope.records.count)")
        } catch {
            disableIndex(error.localizedDescription)
        }
        didHydrateIndex = true
    }

    private func synchronizeLedger(with snapshot: MemorySnapshot) {
        guard isIndexAvailable, let index else { return }
        do {
            let envelope = try MemoryLedgerTransferEnvelope(snapshot: snapshot)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(envelope)
            guard let json = String(data: data, encoding: .utf8) else {
                throw LedgerShadowError.invalidUTF8
            }
            guard index.syncLedger(json) else {
                disableIndex(index.lastError ?? "ledger synchronization failed")
                return
            }
            guard index.exportLedger() == envelope else {
                disableIndex("Rust ledger snapshot did not match Swift after synchronization")
                return
            }
        } catch {
            disableIndex(error.localizedDescription)
        }
    }

    private nonisolated static func openVerifiedLedger(
        envelope: MemoryLedgerTransferEnvelope,
        json: String
    ) throws -> MemlocalSearchIndex {
        let databaseURL = ledgerDatabaseURL()
        let parent = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        func attempt(recreate: Bool) throws -> MemlocalSearchIndex {
            if recreate { try removeLedgerDatabaseFiles() }
            let writer = MemlocalSearchIndex(databaseURL: databaseURL)
            guard writer.isAvailable else {
                let error = writer.initializationError ?? "unknown Rust database initialization error"
                writer.close()
                throw LedgerShadowError.memlocal(error)
            }
            guard writer.syncLedger(json) else {
                let error = writer.lastError ?? "Rust ledger synchronization failed"
                writer.close()
                throw LedgerShadowError.memlocal(error)
            }
            guard writer.exportLedger() == envelope else {
                writer.close()
                throw LedgerShadowError.mismatch("Rust export differed before reopen")
            }
            writer.close()

            let reopened = MemlocalSearchIndex(databaseURL: databaseURL)
            guard reopened.isAvailable else {
                let error = reopened.initializationError ?? "unknown Rust database reopen error"
                reopened.close()
                throw LedgerShadowError.memlocal(error)
            }
            guard reopened.exportLedger() == envelope else {
                let error = reopened.lastError ?? "Rust export differed after reopening the database"
                reopened.close()
                throw LedgerShadowError.mismatch(error)
            }
            return reopened
        }

        do {
            return try attempt(recreate: false)
        } catch {
            // The Swift JSON ledger remains canonical. A failed Rust shadow is
            // disposable, so rebuild it from the complete current snapshot.
            return try attempt(recreate: true)
        }
    }

    private nonisolated static func ledgerDatabaseURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemLocal", isDirectory: true)
            .appendingPathComponent("router-ledger.sqlite")
    }

    private nonisolated static func removeLedgerDatabaseFiles() throws {
        let databaseURL = ledgerDatabaseURL()
        let paths = [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    private func disableIndex(_ error: String) {
        indexFailure = error
        index?.close()
        index = nil
        print("[Memory][Memlocal] disabled; using Swift retrieval: \(error)")
    }
}

private enum LedgerShadowError: LocalizedError {
    case invalidUTF8
    case memlocal(String)
    case mismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "Ledger JSON could not be encoded as UTF-8"
        case .memlocal(let message):
            return "MemLocal shadow ledger failed: \(message)"
        case .mismatch(let message):
            return "MemLocal ledger verification failed: \(message)"
        }
    }
}

/// Synchronous, actor-confined owner of the C ABI handle.
nonisolated private final class MemlocalSearchIndex {
    private let config: String
    private var handle: UnsafeMutableRawPointer?
    private(set) var initializationError: String?
    private(set) var lastError: String?

    var isAvailable: Bool { handle != nil }

    init(databaseURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let configObject: [String: Any] = [
                "storage": [
                    "in_memory": false,
                    "db_path": databaseURL.path,
                    "embedding_dimensions": RouterEmbeddingIndex.dimension
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: configObject, options: [.sortedKeys])
            guard let config = String(data: data, encoding: .utf8) else {
                throw LedgerShadowError.invalidUTF8
            }
            self.config = config
        } catch {
            self.config = "{}"
            initializationError = error.localizedDescription
            return
        }
        handle = config.withCString { memlocal_open($0) }
        if handle == nil {
            initializationError = currentError()
        }
    }

    func syncLedger(_ json: String) -> Bool {
        guard let handle else { return false }
        return record(json.withCString { memlocal_sync_router_ledger(handle, $0) })
    }

    func exportLedger() -> MemoryLedgerTransferEnvelope? {
        guard let handle else { return nil }
        var jsonPointer: UnsafeMutablePointer<CChar>?
        let status = memlocal_export_router_ledger(handle, &jsonPointer)
        guard record(status), let jsonPointer else { return nil }
        defer { memlocal_free_string(jsonPointer) }

        guard let data = String(cString: jsonPointer).data(using: .utf8),
              let envelope = try? JSONDecoder().decode(MemoryLedgerTransferEnvelope.self, from: data) else {
            lastError = "MemLocal returned invalid ledger JSON"
            return nil
        }
        return envelope
    }

    func search(query: String, limit: Int) -> [String] {
        guard let handle else { return [] }
        var jsonPointer: UnsafeMutablePointer<CChar>?
        let status = query.withCString {
            memlocal_search_text(handle, $0, UInt32(limit), &jsonPointer)
        }
        guard record(status), let jsonPointer else { return [] }
        defer { memlocal_free_string(jsonPointer) }

        struct SearchResult: Decodable { let id: String }
        guard let data = String(cString: jsonPointer).data(using: .utf8),
              let results = try? JSONDecoder().decode([SearchResult].self, from: data) else {
            lastError = "MemLocal returned invalid search JSON"
            return []
        }
        return results.map(\.id)
    }

    func searchHybrid(query: String, embedding: [Double], limit: Int) -> [String] {
        guard let handle else { return [] }
        guard let data = try? JSONEncoder().encode(embedding),
              let embeddingJSON = String(data: data, encoding: .utf8) else {
            lastError = "Could not encode the on-device query embedding"
            return []
        }
        var jsonPointer: UnsafeMutablePointer<CChar>?
        let status = query.withCString { queryPointer in
            embeddingJSON.withCString { embeddingPointer in
                memlocal_search_router_hybrid(
                    handle, queryPointer, embeddingPointer,
                    UInt32(clamping: limit), &jsonPointer
                )
            }
        }
        guard record(status), let jsonPointer else { return [] }
        defer { memlocal_free_string(jsonPointer) }

        struct SearchResult: Decodable { let id: String }
        guard let data = String(cString: jsonPointer).data(using: .utf8),
              let results = try? JSONDecoder().decode([SearchResult].self, from: data) else {
            lastError = "MemLocal returned invalid hybrid search JSON"
            return []
        }
        return results.map(\.id)
    }

    func close() {
        guard let handle else { return }
        _ = memlocal_close(handle)
        self.handle = nil
    }

    deinit {
        close()
    }

    @discardableResult
    private func record(_ status: Int32) -> Bool {
        guard status == 0 else {
            lastError = currentError()
            return false
        }
        lastError = nil
        return true
    }

    private func currentError() -> String {
        guard let pointer = memlocal_last_error() else { return "unknown MemLocal error" }
        let error = String(cString: pointer)
        memlocal_free_error(pointer)
        return error
    }
}

nonisolated private enum RouterEmbeddingIndex {
    static let dimension = 128
}
