import Foundation

/// Where a query should be executed.
enum RouteDestination: String, Codable {
    case local   // on-device SLM via Apple Foundation Models
    case cloud   // frontier model via API
}

/// The router's verdict for one query, with human-readable justification.
struct RoutingDecision {
    let destination: RouteDestination
    let score: Double
    let reasons: [String]
}

/// Privacy-first intelligent router (Swift port of router_v1.py).
///
/// Pipeline per query:
///   1. PRIVACY GATE — health / finance / personal data is forced on-device.
///      It never reaches the cloud, regardless of complexity.
///   2. COMPLEXITY SCORER — heuristic features produce a score.
///   3. DECISION — score >= threshold → cloud, otherwise on-device.
struct OnDeviceRouter {

    static let threshold = 2.0

    // MARK: - Privacy gate (forced local)

    private static let privacyPatterns: [String] = [
        #"\bmy (blood|lab|prescription|diagnosis|doctor|medical|health|dentist|therapy|symptoms)\b"#,
        #"\b(my|the) (lab report|test results)\b"#,
        #"\bmy (bank|account|credit card|balance|transaction|ssn|social security)\b"#,
        #"\b(charge|payment) on my\b"#,
    ]

    // MARK: - Complexity signals

    /// Reasoning-heavy signals push toward the cloud; positive weight.
    private static let cloudKeywords: [(String, Double)] = [
        ("prove", 3), ("proof", 3), ("theorem", 3), ("derive", 3), ("derivation", 3),
        ("calculate", 2), ("solve", 2), ("equation", 2), ("complexity", 2),
        ("debug", 3), ("stack trace", 2), ("nullpointer", 2), ("algorithm", 2),
        ("write a python", 3), ("write a sql", 3), ("function that", 2), ("refactor", 2),
        ("compare", 2), ("pros and cons", 3), ("trade-offs", 3), ("tradeoffs", 3),
        ("analyze", 2), ("analysis", 1), ("fallacies", 2),
        ("step by step", 3), ("itinerary", 2), ("second-order", 2),
    ]

    /// Device-friendly task signals pull toward on-device; negative weight.
    private static let localKeywords: [(String, Double)] = [
        ("summarize", -2), ("summary", -2), ("extract", -2), ("translate", -2),
        ("rewrite", -2), ("remind me", -3), ("set a timer", -3), ("play some", -2),
        ("correct the grammar", -2), ("capital of", -2), ("how many ounces", -2),
    ]

    // MARK: - Routing

    static func route(_ query: String) -> RoutingDecision {
        let q = query.lowercased()

        for pattern in privacyPatterns {
            if q.range(of: pattern, options: .regularExpression) != nil {
                return RoutingDecision(
                    destination: .local, score: 0,
                    reasons: ["PRIVACY GATE matched /\(pattern)/ → forced on-device"]
                )
            }
        }

        var score = 0.0
        var reasons: [String] = []

        for (keyword, weight) in cloudKeywords where q.contains(keyword) {
            score += weight
            reasons.append("+\(weight) keyword '\(keyword)'")
        }
        for (keyword, weight) in localKeywords where q.contains(keyword) {
            score += weight
            reasons.append("\(weight) keyword '\(keyword)'")
        }

        let wordCount = q.split(separator: " ").count
        if wordCount > 25 {
            score += 1.5
            reasons.append("+1.5 long query (\(wordCount) words)")
        } else if wordCount < 8 {
            score -= 1.0
            reasons.append("-1.0 short query (\(wordCount) words)")
        }

        let numericSignals = #"\$[\d,]+|[\d]+%|\d+\s*(mph|miles|years|months)"#
        if q.range(of: numericSignals, options: .regularExpression) != nil {
            score += 1.5
            reasons.append("+1.5 numeric reasoning signals")
        }
        if query.contains("?") && wordCount > 15 {
            score += 0.5
            reasons.append("+0.5 long question")
        }

        let destination: RouteDestination = score >= threshold ? .cloud : .local
        reasons.append("score \(String(format: "%.1f", score)) vs threshold \(threshold) → \(destination.rawValue)")
        return RoutingDecision(destination: destination, score: score, reasons: reasons)
    }
}
