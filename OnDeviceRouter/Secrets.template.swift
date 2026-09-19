import Foundation

// MARK: - Secrets template
//
// 1. Copy this file to `Secrets.swift` (same folder).
// 2. Fill in your real API key.
// 3. Never commit `Secrets.swift` — it is already in .gitignore.
//
// The app does not compile without Secrets.swift: RoutingEngine reads the
// cloud config from it at startup.

enum Secrets {
    static let cloudAPIKey = "<#YOUR_API_KEY#>"
    static let cloudEndpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    static let cloudModel = "gpt-4o-mini"
}
