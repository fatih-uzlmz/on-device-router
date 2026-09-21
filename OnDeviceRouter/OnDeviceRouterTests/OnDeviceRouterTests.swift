//
//  OnDeviceRouterTests.swift
//  OnDeviceRouterTests
//
//  Created by Bedri Uzulmez on 9/19/26.
//

import Foundation
import Testing
@testable import OnDeviceRouter

@MainActor
struct OnDeviceRouterTests {

    @Test func memoryPersistsAcrossStoreInstances() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let firstStore = SimpleMemoryStore(fileURL: url)
        await firstStore.save(MemoryExchange(
            userMessage: "My dog's name is Snow",
            assistantMessage: "I'll remember that Snow is your dog.",
            route: "local"
        ))

        let reloadedStore = SimpleMemoryStore(fileURL: url)
        #expect(await reloadedStore.count() == 1)
        let hits = await reloadedStore.recall(matching: "What is my dog's name?", limit: 3)
        #expect(hits.count == 1)
        #expect(hits.first?.userMessage == "My dog's name is Snow")
    }

    @Test func memoryReplacesDuplicatesAndRejectsUnrelatedTurns() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SimpleMemoryStore(fileURL: url)
        await store.save(MemoryExchange(
            userMessage: "My dog's name is Snow",
            assistantMessage: "Got it.",
            route: "local"
        ))
        await store.save(MemoryExchange(
            userMessage: "My dog's name is Snow",
            assistantMessage: "I will remember Snow.",
            route: "local"
        ))

        #expect(await store.count() == 1)
        #expect(await store.recall(matching: "dog name", limit: 3).count == 1)
        #expect(await store.recall(matching: "solar energy", limit: 3).isEmpty)
    }

    @Test func memoryAddsTypedVectorsAndGraphLinks() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SimpleMemoryStore(fileURL: url)
        await store.save(MemoryExchange(
            userMessage: "My dog's name is Snow",
            assistantMessage: "Snow is your dog.",
            route: "local"
        ))
        await store.save(MemoryExchange(
            userMessage: "Snow likes long walks with my dog",
            assistantMessage: "That sounds like a happy routine.",
            route: "local"
        ))

        let diagnostics = await store.diagnostics()
        #expect(diagnostics.embeddedCount == 2)
        #expect(diagnostics.graphEdgeCount >= 1)
        #expect(diagnostics.typeCounts[MemoryType.factual.rawValue] == 2)

        let hits = await store.recall(matching: "What is my dog's name?", limit: 5)
        #expect(hits.first?.userMessage == "My dog's name is Snow")
    }

    @Test func newerFactInvalidatesContradictedFact() async throws {
        let url = temporaryMemoryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SimpleMemoryStore(fileURL: url)
        await store.save(MemoryExchange(
            userMessage: "My dog's name is Snow",
            assistantMessage: "Understood.",
            route: "local"
        ))
        await store.save(MemoryExchange(
            userMessage: "My dog's name is Luna",
            assistantMessage: "I will use the updated name.",
            route: "local"
        ))

        let hits = await store.recall(matching: "What is my dog's name?", limit: 5)
        #expect(hits.count == 1)
        #expect(hits.first?.userMessage == "My dog's name is Luna")
    }

    private func temporaryMemoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-\(UUID().uuidString).json")
    }

}
