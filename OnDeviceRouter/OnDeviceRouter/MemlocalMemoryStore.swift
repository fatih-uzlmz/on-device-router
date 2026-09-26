import Foundation
import MemlocalCore

/// Keeps the existing Swift ledger authoritative and uses MemLocal as an
/// in-memory BM25 index for additional local retrieval candidates.
@available(iOS 26.0, *)
actor MemlocalMemoryStore: MemoryStore {
    private let primary: SimpleMemoryStore
    private var index: MemlocalSearchIndex?
    private var didHydrateIndex = false
    private var hydrationTask: Task<MemorySnapshot, Never>?
    private var indexedContentByID: [String: String] = [:]
    private var indexFailure: String?

    init(primary: SimpleMemoryStore = SimpleMemoryStore()) {
        self.primary = primary
        self.index = nil
    }

    func ingest(userMessage: String, assistantMessage: String, route: String) async {
        await ensureIndexIsHydrated()
        await primary.ingest(userMessage: userMessage,
                             assistantMessage: assistantMessage,
                             route: route)
        synchronizeIndex(with: await primary.snapshot())
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
            relationships: relationshipsByID.values.sorted { $0.createdAt > $1.createdAt }
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
        synchronizeIndex(with: await primary.snapshot())
    }

    private var isIndexAvailable: Bool {
        index?.isAvailable == true && indexFailure == nil
    }

    private func ensureIndexIsHydrated() async {
        guard !didHydrateIndex else { return }
        if index == nil {
            let index = MemlocalSearchIndex()
            self.index = index
            if let error = index.initializationError {
                indexFailure = error
                didHydrateIndex = true
                print("[Memory][Memlocal] unavailable; using Swift retrieval: \(error)")
                return
            }
        }
        guard isIndexAvailable else {
            didHydrateIndex = true
            return
        }
        if hydrationTask == nil {
            hydrationTask = Task { await primary.snapshot() }
        }
        guard let hydrationTask else { return }
        let snapshot = await hydrationTask.value
        guard !didHydrateIndex else { return }
        synchronizeIndex(with: snapshot)
        didHydrateIndex = true
        self.hydrationTask = nil
        print("[Memory][Memlocal] text index ready; indexed=\(indexedContentByID.count)")
    }

    private func synchronizeIndex(with snapshot: MemorySnapshot) {
        guard isIndexAvailable, let index else { return }
        let activeFacts = Dictionary(uniqueKeysWithValues: snapshot.durableFacts.map {
            ($0.id.uuidString, $0)
        })
        let activeIDs = Set(activeFacts.keys)

        for staleID in Array(indexedContentByID.keys) where !activeIDs.contains(staleID) {
            guard index.delete(id: staleID) else {
                disableIndex(index.lastError ?? "delete failed")
                return
            }
            indexedContentByID.removeValue(forKey: staleID)
        }

        for (id, fact) in activeFacts where indexedContentByID[id] != fact.statement {
            guard index.put(id: id, content: fact.statement) else {
                disableIndex(index.lastError ?? "put failed")
                return
            }
            indexedContentByID[id] = fact.statement
        }
    }

    private func disableIndex(_ error: String) {
        indexFailure = error
        index?.close()
        index = nil
        indexedContentByID.removeAll()
        print("[Memory][Memlocal] disabled; using Swift retrieval: \(error)")
    }
}

/// Synchronous, actor-confined owner of the C ABI handle.
nonisolated private final class MemlocalSearchIndex {
    private let config = #"{"storage":{"in_memory":true}}"#
    private var handle: UnsafeMutableRawPointer?
    private(set) var initializationError: String?
    private(set) var lastError: String?

    var isAvailable: Bool { handle != nil }

    init() {
        handle = config.withCString { memlocal_open($0) }
        if handle == nil {
            initializationError = currentError()
        }
    }

    func put(id: String, content: String) -> Bool {
        guard let handle else { return false }
        let status = config.withCString { configPointer in
            id.withCString { idPointer in
                content.withCString { contentPointer in
                    memlocal_put_memory_with_id(handle, configPointer, idPointer, contentPointer)
                }
            }
        }
        return record(status)
    }

    func delete(id: String) -> Bool {
        guard let handle else { return false }
        return record(id.withCString { memlocal_delete_memory(handle, $0) })
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
