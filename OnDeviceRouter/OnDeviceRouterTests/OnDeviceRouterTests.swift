import Foundation
import Testing
@testable import OnDeviceRouter

private actor LocalModelSpy: LocalModelResponding {
    private(set) var prompts: [String] = []
    private(set) var contexts: [String] = []

    func respond(
        to prompt: String,
        memoryContext: String,
        status: @escaping LocalModelService.StatusHandler
    ) async throws -> String {
        prompts.append(prompt)
        contexts.append(memoryContext)
        await status(.ready)
        return "Local response"
    }

    func callCount() -> Int { prompts.count }
    func lastContext() -> String { contexts.last ?? "" }
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
