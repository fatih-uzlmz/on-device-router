//
//  RouterTests.swift
//  OnDeviceRouterTests
//
//  The Swift router is a port of router_v1.py, which scored 100% routing
//  accuracy on this exact 33-query seed set at threshold 2.0.
//  These tests lock that behavior in — any keyword/weight/threshold change
//  that breaks parity with the evaluated Python version fails loudly.
//

import Testing
@testable import OnDeviceRouter

private struct SeedCase {
    let query: String
    let expected: RouteDestination
    let category: String
}

/// The 33-query evaluation seed set from router_v1.py, verbatim.
private let seedCases: [SeedCase] = [
    // LOCAL: chitchat / device tasks
    SeedCase(query: "Hey, how's it going?", expected: .local, category: "chitchat"),
    SeedCase(query: "Remind me to call mom at 5pm", expected: .local, category: "device_task"),
    SeedCase(query: "Set a timer for 20 minutes", expected: .local, category: "device_task"),
    SeedCase(query: "What did I ask you yesterday about my trip?", expected: .local, category: "memory_recall"),
    SeedCase(query: "Play some jazz music", expected: .local, category: "device_task"),
    // LOCAL: understanding / extraction / rewrite
    SeedCase(query: "Summarize this paragraph: The council approved the new transit plan after three hours of debate, with funding split evenly between bus lanes and bike infrastructure.", expected: .local, category: "summarization"),
    SeedCase(query: "Extract all the dates from this email: Hi team, let's meet on March 3rd, the deadline is April 15th, and the launch party is May 1st.", expected: .local, category: "extraction"),
    SeedCase(query: "Is this review positive or negative: 'The battery died after two hours, total waste of money.'", expected: .local, category: "classification"),
    SeedCase(query: "Translate 'good morning, how are you?' to Spanish", expected: .local, category: "translation"),
    SeedCase(query: "Rewrite this more politely: 'Send me the report now, I don't have all day.'", expected: .local, category: "rewrite"),
    SeedCase(query: "List the ingredients from this recipe: 2 eggs, 200g flour, 100ml milk, a pinch of salt.", expected: .local, category: "extraction"),
    SeedCase(query: "What is the capital of Japan?", expected: .local, category: "factual"),
    SeedCase(query: "How many ounces are in a cup?", expected: .local, category: "factual"),
    SeedCase(query: "Give me a one-sentence summary of this article about urban gardening.", expected: .local, category: "summarization"),
    SeedCase(query: "Correct the grammar: 'She don't like apples.'", expected: .local, category: "rewrite"),
    // PRIVACY: forced local, never cloud
    SeedCase(query: "What were my blood test results last month?", expected: .local, category: "privacy_health"),
    SeedCase(query: "Summarize my recent lab report and flag anything abnormal", expected: .local, category: "privacy_health"),
    SeedCase(query: "Did my doctor change my prescription dosage?", expected: .local, category: "privacy_health"),
    SeedCase(query: "What's my current bank account balance?", expected: .local, category: "privacy_finance"),
    SeedCase(query: "Did that large charge on my credit card go through?", expected: .local, category: "privacy_finance"),
    SeedCase(query: "Remind me what my dentist said about the root canal", expected: .local, category: "privacy_health"),
    // CLOUD: reasoning / math / code
    SeedCase(query: "Prove that the square root of 2 is irrational", expected: .cloud, category: "reasoning"),
    SeedCase(query: "Calculate the compound interest on $10,000 at 7% annual rate over 10 years with $200 monthly contributions", expected: .cloud, category: "math"),
    SeedCase(query: "Write a Python function that merges two sorted linked lists", expected: .cloud, category: "code"),
    SeedCase(query: "Debug this crash: NullPointerException at line 42 in UserService when the profile cache is cold", expected: .cloud, category: "code"),
    SeedCase(query: "Compare the pros and cons of a Roth vs traditional IRA for someone earning $120k with 25 years to retirement", expected: .cloud, category: "analysis"),
    SeedCase(query: "Solve step by step: A train leaves Chicago at 60mph heading east, another leaves St. Louis at 75mph heading north. When are they 500 miles apart?", expected: .cloud, category: "math"),
    SeedCase(query: "Explain the trade-offs between microservices and a monolith for a team of 8 engineers expecting 10x growth", expected: .cloud, category: "analysis"),
    SeedCase(query: "Derive the time complexity of quicksort in the average case", expected: .cloud, category: "reasoning"),
    SeedCase(query: "Write a SQL query that finds the top 5 customers by revenue in each region for Q3", expected: .cloud, category: "code"),
    SeedCase(query: "Analyze this argument for logical fallacies: 'We shouldn't build bike lanes because nobody bikes in winter, and my cousin crashed once.'", expected: .cloud, category: "reasoning"),
    SeedCase(query: "Plan a 5-day Tokyo itinerary under $1500 including transit passes, staying near Shinjuku, with two day trips", expected: .cloud, category: "planning"),
    SeedCase(query: "What are the second-order effects of a four-day work week on urban traffic patterns?", expected: .cloud, category: "analysis"),
]

struct RouterTests {

    /// The seed set must route exactly as the evaluated Python v1.
    @Test("Seed set routes to expected destination", arguments: seedCases)
    func seedSetRoutesCorrectly(_ seedCase: SeedCase) {
        let decision = OnDeviceRouter.route(seedCase.query)
        #expect(decision.destination == seedCase.expected,
                "[\(seedCase.category)] '\(seedCase.query)' routed \(decision.destination), expected \(seedCase.expected). Score \(decision.score), reasons: \(decision.reasons)")
    }

    /// Full seed-set accuracy, mirroring router_v1.py's evaluate().
    @Test("Seed set accuracy is 100%")
    func seedSetAccuracy() {
        let correct = seedCases.filter { OnDeviceRouter.route($0.query).destination == $0.expected }
        #expect(correct.count == seedCases.count,
                "\(seedCases.count - correct.count)/\(seedCases.count) seed queries misrouted")
    }

    /// The threshold must stay at the evaluated value (2.0) — drifting it
    /// silently invalidates the 100% accuracy claim from router_v1.py.
    @Test("Threshold matches the evaluated Python v1")
    func thresholdMatchesEvaluatedValue() {
        #expect(OnDeviceRouter.threshold == 2.0)
    }

    /// Privacy gate wins even when the query is full of cloud signals.
    @Test("Privacy gate overrides cloud keywords", arguments: [
        "Analyze my blood test results and derive the statistical trend over time",
        "Compare my bank balance across accounts and calculate the growth rate",
        "Debug why my prescription refill request failed in the pharmacy app",
        "Prove my lab results show improvement: run a regression on the values",
    ])
    func privacyGateBeatsCloudSignals(query: String) {
        let decision = OnDeviceRouter.route(query)
        #expect(decision.destination == .local,
                "'\(query)' escaped the privacy gate (score \(decision.score))")
        #expect(decision.reasons.contains(where: { $0.contains("PRIVACY GATE") }),
                "Privacy match not recorded in reasons")
    }

    /// The privacy gate must force on-device with a zeroed score, regardless
    /// of how many cloud keywords appear in the query.
    @Test("Privacy gate zeroes the complexity score")
    func privacyGateZeroesScore() {
        let decision = OnDeviceRouter.route(
            "Analyze and derive and prove everything about my blood test results")
        #expect(decision.destination == .local)
        #expect(decision.score == 0)
    }

    /// Audit entries must prove which query was routed without storing it —
    /// the privacy contract the whole product is built on.
    @Test("Audit entry stores query hash, not query text")
    func auditEntryHashesQuery() {
        let query = "What were my blood test results last month?"
        let decision = OnDeviceRouter.route(query)
        let entry = AuditEntry(query: query, decision: decision, latencyMs: 12)

        // SHA-256 hex digest: 64 lowercase hex chars.
        #expect(entry.queryHash.count == 64)
        #expect(entry.queryHash.allSatisfy { $0.isHexDigit })

        // Deterministic for the same query…
        let again = AuditEntry(query: query, decision: decision, latencyMs: 12)
        #expect(again.queryHash == entry.queryHash)

        // …and distinct for different queries.
        let other = AuditEntry(
            query: "What is the capital of Japan?",
            decision: OnDeviceRouter.route("What is the capital of Japan?"),
            latencyMs: 5)
        #expect(other.queryHash != entry.queryHash)
    }
}
