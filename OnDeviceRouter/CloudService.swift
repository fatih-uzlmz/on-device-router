import Foundation

/// Frontier-model fallback for queries the on-device model can't handle.
/// Uses any OpenAI-compatible chat completions endpoint.
/// The API key lives in `Secrets.swift` (git-ignored) — never commit it.
struct CloudService {

    struct Config {
        /// e.g. "https://api.openai.com/v1/chat/completions"
        var endpoint: URL
        var model: String        // e.g. "gpt-4o-mini" — cheap tier is fine for fallback
        var apiKey: String
    }

    enum CloudError: Error, LocalizedError {
        case badResponse(Int)
        case decoding
        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "Cloud API returned HTTP \(code)"
            case .decoding: return "Could not decode cloud response"
            }
        }
    }

    private let config: Config

    init(config: Config) {
        self.config = config
    }

    func respond(to prompt: String) async throws -> String {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 512,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        else {
            throw CloudError.decoding
        }
        return content
    }
}
