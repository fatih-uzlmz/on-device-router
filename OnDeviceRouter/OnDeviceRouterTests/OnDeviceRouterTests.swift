import Foundation
import Testing
import SQLite3
import CryptoKit
@testable import OnDeviceRouter

private actor LocalModelSpy: LocalModelResponding {
    private(set) var prompts: [String] = []
    private(set) var contexts: [String] = []
    private(set) var histories: [[String]] = []
    private var extractionResults: [String: [MemoryCandidate]] = [:]

    func respond(
        to prompt: String,
        memoryContext: String,
        recentUserMessages: [String],
        status: @escaping LocalModelService.StatusHandler
    ) async throws -> String {
        prompts.append(prompt)
        contexts.append(memoryContext)
        histories.append(recentUserMessages)
        await status(.ready)
        return "Local response"
    }

    func callCount() -> Int { prompts.count }
    func lastContext() -> String { contexts.last ?? "" }
    func lastHistory() -> [String] { histories.last ?? [] }
    func setExtraction(_ facts: [MemoryCandidate], for message: String) {
        extractionResults[message] = facts
    }
    func extractMemories(from message: String, existingFacts: [DurableFact]) async -> [MemoryCandidate] {
        extractionResults[message] ?? []
    }
}

private struct LegacyMemoryFixture: Codable {
    let id: UUID
    let userMessage: String
    let assistantMessage: String
    let route: String
    let timestamp: Date
}

@MainActor
struct OnDeviceRouterTests {
    @Test func dogFactPersistsAndRecallsAcrossRestart() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let firstStore = SimpleMemoryStore(fileURL: url)
        await firstStore.ingest(
            userMessage: "My dog is named Snow",
            assistantMessage: "I'll remember that.",
            route: "local"
        )

        let firstSnapshot = await firstStore.snapshot()
        #expect(firstSnapshot.durableFacts.count == 1)
        #expect(firstSnapshot.durableFacts.first?.triple.object == "Snow")

        let reloadedStore = SimpleMemoryStore(fileURL: url)
        let recall = await reloadedStore.recall(matching: "What is my dog's name?", limit: 3)
        #expect(recall.facts.count == 1)
        #expect(recall.facts.first?.statement == "User has a dog named Snow.")
        #expect(recall.promptContext.contains("Snow"))
        #expect(!recall.promptContext.contains("Assistant:"))
    }

    @Test func legacyArrayMigratesToVersionedFactDocument() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = [LegacyMemoryFixture(
            id: UUID(),
            userMessage: "My dog's name is Snow",
            assistantMessage: "Saved.",
            route: "local",
            timestamp: Date()
        )]
        try JSONEncoder().encode(legacy).write(to: url)

        let store = SimpleMemoryStore(fileURL: url)
        let snapshot = await store.snapshot()
        let diagnostics = await store.diagnostics()

        #expect(snapshot.durableFacts.first?.triple.object == "Snow")
        #expect(diagnostics.schemaVersion == 3)
        #expect(diagnostics.migrationStatus.contains("Migrated 1 legacy turn"))
    }

    @Test func unknownEmbeddingProvenanceIsRegeneratedOnLoad() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = SimpleMemoryStore(fileURL: url)
        await original.ingest(userMessage: "My dog is named Snow", assistantMessage: "OK", route: "local")

        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var facts = try #require(json["durableFacts"] as? [[String: Any]])
        facts[0].removeValue(forKey: "embeddingProviderVersion")
        facts[0]["embedding"] = Array(repeating: 1.0, count: 128)
        json["durableFacts"] = facts
        json["version"] = 2
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let reloaded = SimpleMemoryStore(fileURL: url)
        let fact = try #require(await reloaded.snapshot().durableFacts.first)
        #expect(fact.embeddingProviderVersion != nil)
        #expect(fact.embedding != Array(repeating: 1.0, count: 128))
        #expect(await reloaded.diagnostics().schemaVersion == 3)
    }

    @Test func hybridShadowEvaluatesFourPromotionCasesWithoutChangingSwiftRecall() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let shadowURL = url.deletingPathExtension().appendingPathExtension("sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: shadowURL.path + suffix)
            }
        }
        let primary = SimpleMemoryStore(fileURL: url)
        let shadow = MemlocalMemoryStore(primary: primary, databaseURL: shadowURL)
        let semanticAvailable = await primary.queryEmbedding(for: "embedding probe")
            .providerVersion.hasPrefix("nl-en-rev-")
        var passed = 0

        func evaluate(_ label: String, query: String, expected: String?, forbidden: String? = nil) async {
            let rustAvailable = await shadow.shadowIndexIsAvailable()
            let swift = await primary.recall(matching: query, limit: 5)
            let rust = await shadow.shadowHybridIDs(matching: query, limit: 5)
            let facts = await primary.snapshot().durableFacts
            let rustObjects = rust.compactMap { id in
                facts.first { $0.id.uuidString == id }?.triple.object
            }
            let swiftObjects = swift.facts.map { $0.triple.object }
            let swiftPass = (expected.map { swiftObjects.contains($0) } ?? swiftObjects.isEmpty)
                && (forbidden.map { !swiftObjects.contains($0) } ?? true)
            let rustPass = Set(rust) == Set(swift.facts.map { $0.id.uuidString })
            if semanticAvailable && rustPass && swiftPass { passed += 1 }
            print("[Memory][HybridGate] \(label): swift=\(swiftObjects) rust=\(rustObjects) pass=\(semanticAvailable ? String(rustPass && swiftPass) : "unscored-hash-fallback")")
            #expect(swiftPass)
            if rustAvailable && !semanticAvailable { #expect(rust.isEmpty) }
        }

        await shadow.ingest(userMessage: "My sister loves chocolate cake", assistantMessage: "OK", route: "local")
        // Note: shadow may be unavailable in sim due to rare code-14; evaluate() handles it.
        await evaluate("paraphrase", query: "What dessert should I buy for my family?", expected: "chocolate cake")

        await shadow.ingest(userMessage: "My favorite programming language is python", assistantMessage: "OK", route: "local")
        await shadow.ingest(userMessage: "My favorite programming language is Rust", assistantMessage: "OK", route: "local")
        await evaluate("correction", query: "What's my favorite programming language?", expected: "Rust", forbidden: "python")

        await shadow.ingest(userMessage: "My dog is named Snow", assistantMessage: "OK", route: "local")
        await shadow.ingest(userMessage: "My dog is named Max", assistantMessage: "OK", route: "local")
        await evaluate("contradiction", query: "What is my dog's name?", expected: "Max", forbidden: "Snow")
        await evaluate("irrelevant-fact rejection", query: "What is my cat's name?", expected: nil)
        print("[Memory][HybridGate] \(semanticAvailable ? "\(passed)/4" : "deferred: NLEmbedding unavailable"); promotion requires 4/4")
        if semanticAvailable { #expect(passed == 4) }
    }

    @Test func ledgerVerificationAllowsJSONTimestampRoundingButChecksPayload() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SimpleMemoryStore(fileURL: url)
        await store.ingest(userMessage: "My dog is named Snow", assistantMessage: "OK", route: "local")
        let original = try MemoryLedgerTransferEnvelope(snapshot: await store.snapshot())
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var records = try #require(json["records"] as? [[String: Any]])
        let timestamp = try #require(records.first?["createdAt"] as? Double)
        records[0]["createdAt"] = timestamp.nextUp
        json["records"] = records
        let rounded = try JSONDecoder().decode(MemoryLedgerTransferEnvelope.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        #expect(original.matchesExport(rounded))

        records[0]["payloadJSON"] = "{}"
        json["records"] = records
        let changed = try JSONDecoder().decode(MemoryLedgerTransferEnvelope.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        #expect(!original.matchesExport(changed))
    }

    @Test func deterministicExtractorAcceptsRequiredPhrases() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SimpleMemoryStore(fileURL: url)

        await store.ingest(userMessage: "I have a dog named Snow.", assistantMessage: "OK", route: "local")
        await store.ingest(userMessage: "My sister is Sarah.", assistantMessage: "OK", route: "local")
        await store.ingest(userMessage: "My sister loves chocolate cake.", assistantMessage: "OK", route: "local")
        await store.ingest(userMessage: "I like coffee.", assistantMessage: "OK", route: "local")
        await store.ingest(userMessage: "I prefer quiet places.", assistantMessage: "OK", route: "local")
        await store.ingest(userMessage: "I live in San Francisco.", assistantMessage: "OK", route: "local")

        let snapshot = await store.snapshot()
        #expect(snapshot.durableFacts.count == 6)
        #expect(snapshot.durableFacts.contains { $0.triple.object == "Sarah" })
        #expect(snapshot.durableFacts.contains { $0.triple.object == "chocolate cake" })
        #expect(snapshot.durableFacts.contains { $0.triple.object == "San Francisco" })
    }

    @Test func explicitRememberPersistsAndRecallsTheMatchingProjectFact() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let firstStore = MemlocalMemoryStore(primary: SimpleMemoryStore(fileURL: url))
        await firstStore.ingest(
            userMessage: "My dog is named Snowball.",
            assistantMessage: "Got it.",
            route: "local"
        )
        await firstStore.ingest(
            userMessage: "For this test, remember thr project code name is cedar -17.",
            assistantMessage: "Cedar-17.",
            route: "local"
        )

        let savedFacts = await firstStore.snapshot().durableFacts
        #expect(savedFacts.count == 2)
        #expect(savedFacts.contains { $0.statement == "Remembered: project code name is cedar -17." })

        let restartedStore = MemlocalMemoryStore(primary: SimpleMemoryStore(fileURL: url))
        let recall = await restartedStore.recall(matching: "What's the project name?", limit: 5)
        #expect(recall.facts.count == 1)
        #expect(recall.facts.first?.statement == "Remembered: project code name is cedar -17.")
        #expect(recall.promptContext.contains("cedar -17"))
        #expect(!recall.promptContext.contains("Snowball"))
    }

    @Test func sisterPreferenceCreatesRelationshipAndSupportsDessertRecall() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SimpleMemoryStore(fileURL: url)

        await store.ingest(
            userMessage: "My sister loves chocolate cake",
            assistantMessage: "That sounds delicious.",
            route: "local"
        )

        let snapshot = await store.snapshot()
        #expect(snapshot.relationships.contains {
            $0.triple.subject == "user_sister"
                && $0.triple.predicate == "likes"
                && $0.triple.object == "chocolate cake"
        })

        let recall = await store.recall(
            matching: "I'm at the supermarket. What dessert should I buy for my family?",
            limit: 5
        )
        #expect(recall.facts.contains { $0.triple.object == "chocolate cake" })
    }

    @Test func genericQuestionsAreTemporaryNotDurable() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SimpleMemoryStore(fileURL: url)

        await store.ingest(
            userMessage: "What is the capital of Japan?",
            assistantMessage: "Tokyo.",
            route: "local"
        )

        let snapshot = await store.snapshot()
        #expect(snapshot.durableFacts.isEmpty)
        #expect(snapshot.conversationTurns.count == 1)
    }

    @Test func repeatedFactsReinforceWithoutDuplicates() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SimpleMemoryStore(fileURL: url)

        await store.ingest(userMessage: "My dog's name is Snow", assistantMessage: "OK", route: "local")
        await store.ingest(userMessage: "My dog is named Snow", assistantMessage: "Still Snow.", route: "local")

        let snapshot = await store.snapshot()
        #expect(snapshot.durableFacts.count == 1)
        #expect(snapshot.durableFacts.first?.reinforcementCount == 2)
    }

    @Test func contradictoryFactsInvalidateHistoryAndExcludeItFromRecall() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SimpleMemoryStore(fileURL: url)

        await store.ingest(userMessage: "My dog is named Snow", assistantMessage: "OK", route: "local")
        await store.ingest(userMessage: "My dog is named Max", assistantMessage: "Updated.", route: "local")

        let snapshot = await store.snapshot()
        #expect(snapshot.durableFacts.count == 1)
        #expect(snapshot.durableFacts.first?.triple.object == "Max")
        #expect(snapshot.invalidatedFacts.count == 1)
        #expect(snapshot.invalidatedFacts.first?.triple.object == "Snow")

        let recall = await store.recall(matching: "What is my dog's name?", limit: 5)
        #expect(recall.facts.count == 1)
        #expect(recall.facts.first?.triple.object == "Max")
        #expect(!recall.facts.contains { $0.triple.object == "Snow" })
    }

    @Test func consolidationApplyInvalidatesOlderSingleValuedFact() async throws {
        let url = temporaryMemoryURL()
        let databaseURL = url.deletingPathExtension().appendingPathExtension("sqlite")
        defer { removeMemoryFixture(at: url, databaseURL: databaseURL) }
        let primary = SimpleMemoryStore(fileURL: url)
        let (oldID, newID) = try await seedConsolidationPair(in: primary, predicate: " Name ")
        let store = MemlocalMemoryStore(primary: primary, databaseURL: databaseURL)

        #expect(await store.shadowIndexIsAvailable())
        await store.runConsolidationMaintenance(apply: true)

        let snapshot = await store.snapshot()
        let old = try #require(snapshot.invalidatedFacts.first { $0.id == oldID })
        let new = try #require(snapshot.durableFacts.first { $0.id == newID })
        #expect(!old.isActive)
        #expect(new.isActive)
        #expect(old.confidence == 0.46)
        #expect(snapshot.relationships.filter { $0.sourceFactID == oldID }.allSatisfy { !$0.isActive })

        let restarted = MemlocalMemoryStore(primary: SimpleMemoryStore(fileURL: url), databaseURL: databaseURL)
        #expect(await restarted.shadowIndexIsAvailable())
        let restored = await restarted.snapshot()
        #expect(restored.invalidatedFacts.contains { $0.id == oldID })
        #expect(restored.durableFacts.contains { $0.id == newID })
    }

    @Test func consolidationApplyPreservesMultiValuedFacts() async throws {
        let url = temporaryMemoryURL()
        let databaseURL = url.deletingPathExtension().appendingPathExtension("sqlite")
        defer { removeMemoryFixture(at: url, databaseURL: databaseURL) }
        let primary = SimpleMemoryStore(fileURL: url)
        let (oldID, newID) = try await seedConsolidationPair(in: primary, predicate: "likes")
        let store = MemlocalMemoryStore(primary: primary, databaseURL: databaseURL)

        #expect(await store.shadowIndexIsAvailable())
        await store.runConsolidationMaintenance(apply: true)

        let snapshot = await store.snapshot()
        #expect(snapshot.durableFacts.contains { $0.id == oldID })
        #expect(snapshot.durableFacts.contains { $0.id == newID })
        #expect(snapshot.invalidatedFacts.isEmpty)
    }

    @Test func favoriteCorrectionReplacesDurableFactBeforeNextAnswer() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let firstChat = SimpleMemoryStore(fileURL: url)
        await firstChat.ingest(
            userMessage: "My favorite programming language is python",
            assistantMessage: "Got it.", route: "local"
        )
        #expect(await firstChat.snapshot().durableFacts.first?.triple.object == "python")

        let secondChat = MemlocalMemoryStore(primary: SimpleMemoryStore(fileURL: url))
        let local = LocalModelSpy()
        let engine = RoutingEngine(local: local, memory: secondChat)
        _ = try await engine.answer("my fav programming language is rust")
        _ = try await engine.answer("whats my favorite programming language")

        let snapshot = await secondChat.snapshot()
        #expect(snapshot.durableFacts.map(\.triple.object) == ["rust"])
        #expect(snapshot.invalidatedFacts.map(\.triple.object) == ["python"])
        let context = await local.lastContext()
        #expect(context.contains("favorite programming language is rust"))
        #expect(!context.contains("python"))
        #expect(await local.lastHistory() == ["my fav programming language is rust"])
    }

    @Test func recentChatStatementIsPassedEvenWhenExtractorDoesNotRecognizeIt() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SimpleMemoryStore(fileURL: url)
        await store.ingest(userMessage: "My favorite programming language is python",
                           assistantMessage: "OK", route: "local")
        let local = LocalModelSpy()
        let engine = RoutingEngine(local: local, memory: store)

        _ = try await engine.answer("Actually, Rust is my favorite programming language now.")
        _ = try await engine.answer("What's my favorite programming language?")

        #expect(await store.snapshot().durableFacts.first?.triple.object == "python")
        #expect(await local.lastHistory() == ["Actually, Rust is my favorite programming language now."])
        let prompt = LocalModelService.structuredPrompt(
            "What's my favorite programming language?",
            memoryContext: await local.lastContext(),
            recentUserMessages: await local.lastHistory()
        )
        let oldFactPosition = prompt.range(of: "python")?.lowerBound
        let newStatementPosition = prompt.range(of: "Rust")?.lowerBound
        #expect(oldFactPosition != nil && newStatementPosition != nil)
        if let oldFactPosition, let newStatementPosition {
            #expect(newStatementPosition < oldFactPosition)
        }
        #expect(prompt.contains("Recent user statements"))
    }

    @Test func modelExtractedCorrectionPersistsAcrossRestart() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = SimpleMemoryStore(fileURL: url)
        await original.ingest(userMessage: "My favorite programming language is Python",
                              assistantMessage: "OK", route: "local")
        let oldFact = try #require(await original.snapshot().durableFacts.first)
        let correction = "I changed my mind. My new favorite language is Rust"
        let candidate = MemoryCandidate(
            subject: "user", predicate: "favorite_language", object: "Rust",
            evidence: "My new favorite language is Rust", replacesFactID: oldFact.id
        )
        let local = LocalModelSpy()
        await local.setExtraction([candidate], for: correction)
        let engine = RoutingEngine(local: local, memory: original)
        _ = try await engine.answer(correction)

        let restarted = SimpleMemoryStore(fileURL: url)
        let snapshot = await restarted.snapshot()
        let recall = await restarted.recall(matching: "What's my favorite programming language?",
                                            limit: 5)
        #expect(snapshot.durableFacts.map(\.triple.object) == ["Rust"])
        #expect(snapshot.invalidatedFacts.map(\.triple.object) == ["Python"])
        #expect(recall.facts.map(\.triple.object) == ["Rust"])
        #expect(!recall.promptContext.contains("Python"))
    }

    @Test func extractedFactsRequireVerbatimUserEvidence() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SimpleMemoryStore(fileURL: url)
        let invented = MemoryCandidate(subject: "user", predicate: "favorite_language",
                                       object: "Rust", evidence: "My favorite language is Rust",
                                       replacesFactID: nil)
        await store.ingest(userMessage: "I like Python",
                           assistantMessage: "OK", route: "local",
                           extractedFacts: [invented])
        let snapshot = await store.snapshot()
        #expect(!snapshot.durableFacts.contains { $0.triple.object == "Rust" })
    }

    @Test func modelCorrectionLinkSurvivesPatternExtraction() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SimpleMemoryStore(fileURL: url)
        await store.ingest(userMessage: "My favorite programming language is Python",
                           assistantMessage: "OK", route: "local")
        let old = try #require(await store.snapshot().durableFacts.first)
        let message = "My favorite language is Rust"
        let candidate = MemoryCandidate(subject: "user", predicate: "favorite_language",
                                        object: "Rust", evidence: message,
                                        replacesFactID: old.id)
        await store.ingest(userMessage: message, assistantMessage: "OK", route: "local",
                           extractedFacts: [candidate])
        let snapshot = await store.snapshot()
        #expect(snapshot.durableFacts.map(\.triple.object) == ["Rust"])
        #expect(snapshot.invalidatedFacts.map(\.triple.object) == ["Python"])
    }

    @Test func modelCannotTurnAQuestionIntoADurableFact() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SimpleMemoryStore(fileURL: url)
        let message = "Is my favorite language Rust?"
        let candidate = MemoryCandidate(subject: "user", predicate: "favorite_language",
                                        object: "Rust", evidence: message,
                                        replacesFactID: nil)
        await store.ingest(userMessage: message, assistantMessage: "I don't know.",
                           route: "local", extractedFacts: [candidate])
        #expect(await store.snapshot().durableFacts.isEmpty)
    }

    @Test func onDeviceModelExtractsNaturalLanguageCorrection() async throws {
        #if targetEnvironment(simulator)
        // 1B model cannot load in simulator; device-only test.
        return
        #endif
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SimpleMemoryStore(fileURL: url)
        await store.ingest(userMessage: "My favorite programming language is Python",
                           assistantMessage: "OK", route: "local")
        let oldFact = try #require(await store.snapshot().durableFacts.first)
        let correction = "I changed my mind. My new favorite language is Rust"
        let candidates = await LocalModelService().extractMemories(
            from: correction, existingFacts: [oldFact]
        )
        #expect(candidates.contains { $0.object == "Rust" })
    }

    @Test func onDeviceModelExtractsMultipleAtomicFacts() async {
        #if targetEnvironment(simulator)
        // 1B model cannot load in simulator; device-only test.
        return
        #endif
        let message = "My dog is named Snow. I live in San Francisco."
        let candidates = await LocalModelService().extractMemories(
            from: message, existingFacts: []
        )
        #expect(candidates.contains { $0.object == "Snow" })
        #expect(candidates.contains { $0.object == "San Francisco" })
    }

    @Test func unrelatedFactsDoNotContaminateRecall() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SimpleMemoryStore(fileURL: url)

        await store.ingest(userMessage: "My dog is named Snow", assistantMessage: "OK", route: "local")
        await store.ingest(userMessage: "I prefer quiet restaurants", assistantMessage: "OK", route: "local")

        let recall = await store.recall(matching: "What is my dog's name?", limit: 5)
        #expect(recall.facts.contains { $0.triple.object == "Snow" })
        #expect(!recall.facts.contains { $0.triple.object == "quiet restaurants" })
    }

    @Test func activeExecutionUsesOnlyInjectedLocalModel() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SimpleMemoryStore(fileURL: url)
        await store.ingest(userMessage: "My dog is named Snow", assistantMessage: "OK", route: "local")
        let local = LocalModelSpy()
        let engine = RoutingEngine(local: local, memory: store)

        let answer = try await engine.answer("What is my dog's name?")

        #expect(answer.destination == .local)
        #expect(await local.callCount() == 1)
        #expect(await local.lastContext().contains("Snow"))
    }



    private func temporaryMemoryURL() -> URL {
        // TEST: use Caches instead of tmp to see if code-14 is tmp-specific
        FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-\(UUID().uuidString).json")
    }

    private func seedConsolidationPair(in store: SimpleMemoryStore, predicate: String) async throws -> (UUID, UUID) {
        await store.ingest(userMessage: "I like cake", assistantMessage: "OK", route: "local")
        await store.ingest(userMessage: "I like pie", assistantMessage: "OK", route: "local")
        let snapshot = await store.snapshot()
        var facts = snapshot.durableFacts
        let oldIndex = try #require(facts.firstIndex { $0.triple.object == "cake" })
        let newIndex = try #require(facts.firstIndex { $0.triple.object == "pie" })
        facts[oldIndex].triple = MemoryTriple(subject: "user", predicate: predicate, object: "cake")
        facts[newIndex].triple = MemoryTriple(subject: "user", predicate: predicate, object: "pie")
        let now = Date()
        facts[oldIndex].createdAt = now.addingTimeInterval(-120)
        facts[oldIndex].updatedAt = now.addingTimeInterval(-60)
        facts[newIndex].createdAt = now.addingTimeInterval(-30)
        facts[newIndex].updatedAt = now
        // Keep source relationships to verify invalidation, but give them a
        // distinct triple so ledger reconciliation leaves both fact triples indexed.
        var relationships = snapshot.relationships
        for index in relationships.indices {
            relationships[index].triple = MemoryTriple(
                subject: "user", predicate: "observed", object: relationships[index].triple.object
            )
        }
        await store.restoreLedger(MemorySnapshot(
            durableFacts: facts, relationships: relationships,
            episodes: snapshot.episodes, conversationTurns: snapshot.conversationTurns,
            invalidatedFacts: []
        ))
        return (facts[oldIndex].id, facts[newIndex].id)
    }

    @Test func rustSourceMatchesPrebuiltXcframework() throws {
        // Drift guard: the committed MemlocalCore.xcframework must be built from the
        // current Rust sources. build-memlocal-xcframework.sh writes
        // Frameworks/rust-source-sha.txt; this test recomputes the digest from the
        // working tree and fails if they differ.
        // Canonical form (must match Native/rust_source_sha.py):
        //   SHA256( concat over files sorted by relpath of (relpath_utf8 + newline + file_bytes) )
        //   files = <crate>/{src/**, include/**, Cargo.toml, Cargo.lock},
        //   crates = memlocal_core, memlocal_swift_shim, relpath = "<crate>/<rest>".
        let testFile = URL(fileURLWithPath: #filePath, isDirectory: false)
        let repoRoot = testFile.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let nativeDir = repoRoot.appendingPathComponent("OnDeviceRouter/Native")
        let sidecar = repoRoot.appendingPathComponent("OnDeviceRouter/Frameworks/rust-source-sha.txt")

        let recorded: String = {
            guard let raw = try? String(contentsOf: sidecar, encoding: .utf8) else { return "" }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        guard !recorded.isEmpty else {
            Issue.record("rust-source-sha.txt is missing or empty -- rebuild the xcframework with OnDeviceRouter/Native/build-memlocal-xcframework.sh")
            return
        }

        let fm = FileManager.default
        let base = nativeDir.path + "/"
        var relPaths: [String] = []
        for crate in ["memlocal_core", "memlocal_swift_shim"] {
            let crateDir = nativeDir.appendingPathComponent(crate)
            for top in ["src", "include"] {
                let topURL = crateDir.appendingPathComponent(top)
                guard let enumerator = fm.enumerator(at: topURL, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                for case let url as URL in enumerator {
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                    guard values?.isRegularFile == true, url.path.hasPrefix(base) else { continue }
                    relPaths.append(String(url.path.dropFirst(base.count)))
                }
            }
            for rootFile in ["Cargo.toml", "Cargo.lock"] {
                let url = crateDir.appendingPathComponent(rootFile)
                if fm.fileExists(atPath: url.path), url.path.hasPrefix(base) {
                    relPaths.append(String(url.path.dropFirst(base.count)))
                }
            }
        }
        relPaths.sort()

        var hasher = SHA256()
        for rel in relPaths {
            let bytes = try Data(contentsOf: nativeDir.appendingPathComponent(rel))
            hasher.update(data: Data(rel.utf8))
            hasher.update(data: Data([0x0A]))
            hasher.update(data: bytes)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(digest == recorded, "Rust sources changed without rebuilding the xcframework. Run OnDeviceRouter/Native/build-memlocal-xcframework.sh and commit the result.")
    }

    private func removeMemoryFixture(at url: URL, databaseURL: URL) {
        try? FileManager.default.removeItem(at: url)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
    }
}
