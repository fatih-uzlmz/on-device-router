import Foundation
import Testing
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
        #expect(diagnostics.schemaVersion == 2)
        #expect(diagnostics.migrationStatus.contains("Migrated 1 legacy turn"))
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
        FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-\(UUID().uuidString).json")
    }
}
