import Foundation
import MemlocalCore

/// Keeps Swift's fact rules while using the verified Rust ledger for durable
/// persistence, hybrid retrieval, and search seeding for graph expansion.
@available(iOS 26.0, *)
actor MemlocalMemoryStore: MemoryStore {
    private let primary: SimpleMemoryStore
    private let databaseURL: URL
    private var index: MemlocalSearchIndex?
    private var didHydrateIndex = false
    private var hydrationTask: Task<MemorySnapshot, Never>?
    private var indexFailure: String?
    /// Set when a Rust ledger sync fails; retried on next ingest and launch.
    /// Swift JSON persistence stays enabled as the crash-safe cache meanwhile.
    private var ledgerDirty = false

    init(primary: SimpleMemoryStore = SimpleMemoryStore(), databaseURL: URL? = nil) {
        self.primary = primary
        self.databaseURL = databaseURL ?? Self.ledgerDatabaseURL(for: primary)
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
        let snapshot = await primary.snapshot()
        if !synchronizeLedger(with: snapshot) {
            // Rust is the commit point; keep Swift JSON as crash-safe cache
            // and retry the sync on the next ingest instead of diverging silently.
            ledgerDirty = true
            await primary.configurePersistence(enabled: true, persistCurrent: true)
        } else if ledgerDirty {
            ledgerDirty = false
            print("[Memory][Memlocal] dirty ledger recovered on ingest")
        }
    }

    /// Retry a failed Rust sync (see ledgerDirty). Returns true when clean.
    private func retryDirtyLedger() async -> Bool {
        guard ledgerDirty, isIndexAvailable else { return !ledgerDirty }
        if synchronizeLedger(with: await primary.snapshot()) {
            ledgerDirty = false
            print("[Memory][Memlocal] dirty ledger recovered on retry")
            return true
        }
        return false
    }

    func snapshot() async -> MemorySnapshot {
        await primary.snapshot()
    }

    /// Read-only evaluation hook for the shadow promotion gate.
    func shadowHybridIDs(matching query: String, limit: Int) async -> [String] {
        await ensureIndexIsHydrated()
        guard isIndexAvailable, let index else { return [] }
        let embedding = await primary.queryEmbedding(for: query)
        let rawIDs = index.searchHybrid(query: query, embedding: embedding.vector,
                                        providerVersion: embedding.providerVersion, limit: limit)
        let factsByID = Dictionary(uniqueKeysWithValues: await primary.snapshot().durableFacts.map {
            ($0.id.uuidString, $0)
        })
        let eligibleIDs = rawIDs.filter { id in
            factsByID[id].map { SimpleMemoryStore.matchesTopic(of: $0, query: query) } ?? false
        }
        print("[Memory][HybridShadow] raw=\(rawIDs) topicEligible=\(eligibleIDs)")
        return eligibleIDs
    }

    func shadowIndexIsAvailable() async -> Bool {
        await ensureIndexIsHydrated()
        return isIndexAvailable
    }

    func recall(matching query: String, limit: Int) async -> MemoryRecall {
        await ensureIndexIsHydrated()
        let swiftRecall = await primary.recall(matching: query, limit: limit)
        guard isIndexAvailable, let index else { return swiftRecall }

        let snapshot = await primary.snapshot()
        let factsByID = Dictionary(uniqueKeysWithValues: snapshot.durableFacts.map {
            ($0.id.uuidString, $0)
        })
        let queryEmbedding = await primary.queryEmbedding(for: query)
        let rawHybridIDs = index.searchHybrid(query: query, embedding: queryEmbedding.vector,
                                              providerVersion: queryEmbedding.providerVersion,
                                              limit: max(1, min(limit, 8)))
        let eligibleHybridIDs = rawHybridIDs.filter { id in
            factsByID[id].map { SimpleMemoryStore.matchesTopic(of: $0, query: query) } ?? false
        }
        let swiftIDs = swiftRecall.facts.map { $0.id.uuidString }
        print("[Memory][HybridRecall] provider=\(queryEmbedding.providerVersion) swift=\(swiftIDs) raw=\(rawHybridIDs) topicEligible=\(eligibleHybridIDs) match=\(Set(swiftIDs) == Set(eligibleHybridIDs))")
        let resultLimit = max(1, min(limit, 8))
        var facts: [DurableFact] = []
        var selectedIDs = Set<UUID>()

        func append(_ fact: DurableFact) {
            guard facts.count < resultLimit,
                  SimpleMemoryStore.matchesTopic(of: fact, query: query),
                  selectedIDs.insert(fact.id).inserted else { return }
            facts.append(fact)
        }

        // Hybrid results now lead factual recall. Keep the topic filter on every
        // Rust-sourced candidate before it can enter the model context.
        let graphSeedLimit = max(1, min(3, resultLimit - 1))
        let graphSeedIDs = Array(eligibleHybridIDs.prefix(graphSeedLimit))
        for id in graphSeedIDs {
            if let fact = factsByID[id] { append(fact) }
        }

        // Expand through the Rust knowledge graph (2 hops from hybrid seeds).
        // Falls back to Swift's traversal when Rust yields nothing.
        let rustGraphIDs = index.searchGraph(seedIDs: graphSeedIDs, maxHops: 2)
        print("[Memory][GraphRecall] rust=\(rustGraphIDs.count) seeds=\(graphSeedIDs.count)")
        let rustGraphFacts = rustGraphIDs.compactMap { factsByID[$0] }
        if rustGraphFacts.isEmpty {
            let graphSeeds = graphSeedIDs.compactMap(UUID.init(uuidString:))
            for fact in await primary.graphExpansion(from: graphSeeds, maxHops: 2) { append(fact) }
        } else {
            for fact in rustGraphFacts { append(fact) }
        }

        for id in eligibleHybridIDs.dropFirst(graphSeedIDs.count) {
            if let fact = factsByID[id] { append(fact) }
        }

        // Preserve Swift's lexical/entity candidates as fallback when hybrid
        // search or the topic filter yields fewer than the requested results.
        for fact in swiftRecall.facts { append(fact) }

        for id in index.search(query: query, limit: max(resultLimit * 2, 8)) {
            guard let fact = factsByID[id] else { continue }
            append(fact)
            if facts.count >= resultLimit { break }
        }

        let swiftIDSet = Set(swiftRecall.facts.map(\.id))
        let externallySelected = selectedIDs.subtracting(swiftIDSet)
        await primary.recordExternalRecall(externallySelected)
        let latestSnapshot = await primary.snapshot()
        if !synchronizeLedger(with: latestSnapshot) {
            await primary.configurePersistence(enabled: true, persistCurrent: true)
        }

        var relationshipsByID = Dictionary(uniqueKeysWithValues: swiftRecall.relationships.map {
            ($0.id, $0)
        })
        for relationship in latestSnapshot.relationships
        where relationship.isActive && selectedIDs.contains(relationship.sourceFactID) {
            relationshipsByID[relationship.id] = relationship
        }

        print("[Memory][Memlocal] recalled \(facts.count) fact(s); Rust additions=\(externallySelected.count), graph seeds=\(graphSeedIDs.count)")
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
        var diagnostics = await primary.diagnostics()
        if isIndexAvailable,
           !synchronizeLedger(with: await primary.snapshot()) {
            await primary.configurePersistence(enabled: true, persistCurrent: true)
            diagnostics = await primary.diagnostics()
        }
        guard isIndexAvailable else {
            let errors = [indexFailure, diagnostics.persistenceError]
                .compactMap { $0 }.joined(separator: "; ")
            return diagnostics.replacingPersistence(
                path: diagnostics.filePath,
                exists: diagnostics.fileExists,
                size: diagnostics.fileSizeBytes,
                error: errors.isEmpty ? nil : errors
            )
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return diagnostics.replacingPersistence(
            path: databaseURL.path,
            exists: FileManager.default.fileExists(atPath: databaseURL.path),
            size: size,
            error: nil
        )
    }

    func clear() async {
        await ensureIndexIsHydrated()
        await primary.clear()
        // Persist an empty fallback before removing Rust's old canonical ledger.
        await primary.configurePersistence(enabled: true, persistCurrent: true)
        _ = synchronizeLedger(with: await primary.snapshot())
        index?.close()
        index = nil
        do {
            try Self.removeLedgerDatabaseFiles(at: databaseURL)
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
            let (verified, rustEnvelope) = try Self.openLedgerPreferringRust(
                envelope: envelope, json: json, databaseURL: databaseURL
            )
            let restoringRustSource = !rustEnvelope.matchesExport(envelope)
            if restoringRustSource {
                await primary.restoreLedger(try rustEnvelope.makeSnapshot())
            }
            index = verified
            indexFailure = nil
            await primary.configurePersistence(enabled: false)
            if restoringRustSource,
               !synchronizeLedger(with: await primary.snapshot()) {
                await primary.configurePersistence(enabled: true, persistCurrent: true)
            }
            if isIndexAvailable {
                print("[Memory][Memlocal] Rust ledger authoritative; records=\(rustEnvelope.records.count)")
            }
            // Consolidation runs dry-run/log-only until apply mode is enabled
            // after on-device log review (a bug here could wipe real memories).
            await runConsolidationMaintenance(apply: false)
            await retryDirtyLedger()
        } catch {
            disableIndex(error.localizedDescription)
        }
        didHydrateIndex = true
    }

    /// Scan for contradicting triples and log them. Dry-run by default:
    /// apply mode (which would invalidate the older fact) stays off until
    /// the on-device logs are reviewed.
    func runConsolidationMaintenance(apply: Bool = false) async {
        await ensureIndexIsHydrated()
        guard isIndexAvailable, let index else { return }
        let pairs = index.findContradictingTriples()
        guard !pairs.isEmpty else {
            print("[Memory][Consolidation] scan complete; no contradictions")
            return
        }
        print("[Memory][Consolidation] found \(pairs.count) contradicting triple(s) (apply=\(apply))")
        for pair in pairs {
            print("[Memory][Consolidation] \(pair.subject) | \(pair.predicate) | old='\(pair.oldObject)' (\(pair.oldMemoryId)) -> new='\(pair.newObject)' (\(pair.newMemoryId))")
        }
        if apply {
            // Apply mode: invalidate the older fact in Swift, then re-sync.
            // Deliberately unwired until dry-run logs are reviewed on device.
            print("[Memory][Consolidation] apply mode requested but not yet enabled; no changes made")
        }
    }

    private func synchronizeLedger(with snapshot: MemorySnapshot) -> Bool {
        guard isIndexAvailable, let index else { return false }
        do {
            let envelope = try MemoryLedgerTransferEnvelope(snapshot: snapshot)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(envelope)
            guard let json = String(data: data, encoding: .utf8) else {
                throw LedgerShadowError.invalidUTF8
            }
            guard index.syncLedger(json) else {
                disableAndDiscardIndex(index.lastError ?? "ledger synchronization failed")
                return false
            }
            let exported = index.exportLedger()
            guard envelope.matchesExport(exported) else {
                print("[Memory][Memlocal] shadow mismatch after sync; \(Self.mismatchSummary(expected: envelope, actual: exported)), rebuilding")
                index.close()
                self.index = nil
                self.index = try Self.openVerifiedLedger(envelope: envelope, json: json, databaseURL: databaseURL)
                indexFailure = nil
                print("[Memory][Memlocal] shadow rebuilt and verified; records=\(envelope.records.count)")
                return true
            }
            return true
        } catch {
            disableAndDiscardIndex(error.localizedDescription)
            return false
        }
    }

    private nonisolated static func openLedgerPreferringRust(
        envelope: MemoryLedgerTransferEnvelope,
        json: String,
        databaseURL: URL
    ) throws -> (MemlocalSearchIndex, MemoryLedgerTransferEnvelope) {
        let databaseAlreadyExists = [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
            .contains { FileManager.default.fileExists(atPath: $0) }
        let existing = MemlocalSearchIndex(databaseURL: databaseURL)
        guard existing.isAvailable else {
            let error = existing.initializationError ?? "unknown Rust database initialization error"
            existing.close()
            guard !databaseAlreadyExists else { throw LedgerShadowError.memlocal(error) }
            let bootstrapped = try openVerifiedLedger(
                envelope: envelope, json: json, databaseURL: databaseURL
            )
            guard let exported = bootstrapped.exportLedger(), envelope.matchesExport(exported) else {
                bootstrapped.close()
                throw LedgerShadowError.mismatch("Rust bootstrap did not preserve the source ledger")
            }
            return (bootstrapped, exported)
        }

        guard let rustEnvelope = existing.exportLedger() else {
            let error = existing.lastError ?? "Rust ledger export failed"
            existing.close()
            throw LedgerShadowError.memlocal(error)
        }
        if !rustEnvelope.records.isEmpty {
            guard (try? rustEnvelope.makeSnapshot()) != nil else {
                existing.close()
                throw LedgerShadowError.mismatch("Existing Rust ledger payloads could not be restored")
            }
            return (existing, rustEnvelope)
        }
        existing.close()

        let bootstrapped = try openVerifiedLedger(
            envelope: envelope, json: json, databaseURL: databaseURL
        )
        guard let rustEnvelope = bootstrapped.exportLedger(),
              envelope.matchesExport(rustEnvelope) else {
            bootstrapped.close()
            throw LedgerShadowError.mismatch("Rust bootstrap did not preserve the source ledger")
        }
        return (bootstrapped, rustEnvelope)
    }

    private nonisolated static func openVerifiedLedger(
        envelope: MemoryLedgerTransferEnvelope,
        json: String,
        databaseURL: URL
    ) throws -> MemlocalSearchIndex {
        let parent = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        func attempt(recreate: Bool) throws -> MemlocalSearchIndex {
            if recreate { try removeLedgerDatabaseFiles(at: databaseURL) }
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
            let written = writer.exportLedger()
            guard envelope.matchesExport(written) else {
                writer.close()
                throw LedgerShadowError.mismatch("Rust export differed before reopen: \(mismatchSummary(expected: envelope, actual: written))")
            }
            writer.close()

            let reopened = MemlocalSearchIndex(databaseURL: databaseURL)
            guard reopened.isAvailable else {
                let error = reopened.initializationError ?? "unknown Rust database reopen error"
                reopened.close()
                throw LedgerShadowError.memlocal(error)
            }
            guard envelope.matchesExport(reopened.exportLedger()) else {
                let error = reopened.lastError ?? "Rust export differed after reopening the database"
                reopened.close()
                throw LedgerShadowError.mismatch(error)
            }
            return reopened
        }

        do {
            return try attempt(recreate: false)
        } catch {
            // A failed Rust database can be recreated from the recovery snapshot.
            return try attempt(recreate: true)
        }
    }

    private nonisolated static func ledgerDatabaseURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemLocal", isDirectory: true)
            .appendingPathComponent("router-ledger.sqlite")
    }

    private nonisolated static func ledgerDatabaseURL(for primary: SimpleMemoryStore) -> URL {
        guard !primary.usesDefaultPersistenceFile else { return ledgerDatabaseURL() }
        let sourceURL = URL(fileURLWithPath: primary.persistenceFilePath)
        return sourceURL.deletingPathExtension().appendingPathExtension("memlocal.sqlite")
    }

    private nonisolated static func mismatchSummary(
        expected: MemoryLedgerTransferEnvelope, actual: MemoryLedgerTransferEnvelope?
    ) -> String {
        let expectedByID = Dictionary(uniqueKeysWithValues: expected.records.map { ($0.id, $0) })
        let actualByID = Dictionary(uniqueKeysWithValues: (actual?.records ?? []).map { ($0.id, $0) })
        let differences = Set(expectedByID.keys).union(actualByID.keys).sorted().compactMap { id -> String? in
            let wanted = expectedByID[id]
            let found = actualByID[id]
            guard wanted != found else { return nil }
            let fields = [
                "kind=\(wanted?.kind == found?.kind)",
                "content=\(wanted?.content == found?.content)",
                "createdAt=\(wanted?.createdAt.bitPattern == found?.createdAt.bitPattern) \(wanted?.createdAt ?? 0)->\(found?.createdAt ?? 0)",
                "updatedAt=\(wanted?.updatedAt.bitPattern == found?.updatedAt.bitPattern) \(wanted?.updatedAt ?? 0)->\(found?.updatedAt ?? 0)",
                "invalidatedAt=\(wanted?.invalidatedAt == found?.invalidatedAt)"
            ].joined(separator: ",")
            return "\(wanted?.kind.rawValue ?? found?.kind.rawValue ?? "missing"):\(id)" +
                "(present=\(found != nil),payloadEqual=\(wanted?.payloadJSON == found?.payloadJSON),\(fields))"
        }
        return "expected=\(expected.records.count), actual=\(actual?.records.count ?? -1), differences=\(differences)"
    }

    private nonisolated static func removeLedgerDatabaseFiles(at databaseURL: URL) throws {
        let paths = [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    private func disableIndex(_ error: String) {
        indexFailure = error
        index?.close()
        index = nil
        print("[Memory][Memlocal] disabled; using Swift fallback: \(error)")
    }

    private func disableAndDiscardIndex(_ error: String) {
        disableIndex(error)
        do {
            try Self.removeLedgerDatabaseFiles(at: databaseURL)
        } catch {
            indexFailure = "\(indexFailure ?? error.localizedDescription); could not discard stale Rust ledger: \(error.localizedDescription)"
        }
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

nonisolated private struct RouterHybridEmbedding: Encodable {
    let vector: [Double]
    let providerVersion: String
}

/// A pair of triples where a newer memory contradicts an older one.
/// Returned by the Rust consolidation scan; Swift decides what to do.
struct ContradictingTriple: Decodable {
    let subject: String
    let predicate: String
    let oldObject: String
    let newObject: String
    let oldMemoryId: String
    let newMemoryId: String
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

    func searchHybrid(query: String, embedding: [Double], providerVersion: String, limit: Int) -> [String] {
        guard let handle else { return [] }
        let request = RouterHybridEmbedding(vector: embedding, providerVersion: providerVersion)
        guard let data = try? JSONEncoder().encode(request),
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

    func searchGraph(seedIDs: [String], maxHops: Int) -> [String] {
        guard let handle else { return [] }
        guard let data = try? JSONEncoder().encode(seedIDs),
              let seedJSON = String(data: data, encoding: .utf8) else {
            lastError = "Could not encode graph seed IDs"
            return []
        }
        var jsonPointer: UnsafeMutablePointer<CChar>?
        let status = seedJSON.withCString { seedPointer in
            memlocal_search_router_graph(handle, seedPointer, UInt32(clamping: maxHops), &jsonPointer)
        }
        guard record(status), let jsonPointer else { return [] }
        defer { memlocal_free_string(jsonPointer) }

        struct SearchResult: Decodable { let id: String }
        guard let data = String(cString: jsonPointer).data(using: .utf8),
              let results = try? JSONDecoder().decode([SearchResult].self, from: data) else {
            lastError = "MemLocal returned invalid graph search JSON"
            return []
        }
        return results.map(\.id)
    }

    func findContradictingTriples() -> [ContradictingTriple] {
        guard let handle else { return [] }
        var jsonPointer: UnsafeMutablePointer<CChar>?
        let status = memlocal_find_contradicting_triples(handle, &jsonPointer)
        guard record(status), let jsonPointer else { return [] }
        defer { memlocal_free_string(jsonPointer) }

        guard let data = String(cString: jsonPointer).data(using: .utf8),
              let pairs = try? JSONDecoder().decode([ContradictingTriple].self, from: data) else {
            lastError = "MemLocal returned invalid contradiction JSON"
            return []
        }
        return pairs
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
