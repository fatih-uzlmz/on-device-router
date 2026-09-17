import Foundation
import FoundationModels

/// On-device inference via Apple's Foundation Models framework.
/// Free, offline, private — runs the ~3B on-device model. Requires
/// iPhone 15 Pro or newer with Apple Intelligence enabled, iOS 26+.
@available(iOS 26.0, *)
actor LocalModelService {

    enum LocalError: Error, LocalizedError {
        case modelUnavailable(String)
        var errorDescription: String? {
            if case .modelUnavailable(let reason) = self {
                return "On-device model unavailable: \(reason)"
            }
            return nil
        }
    }

    private let session = LanguageModelSession()

    /// Check before calling — surface a clear message if unavailable.
    static func availability() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            return String(describing: reason)
        }
    }

    func respond(to prompt: String) async throws -> String {
        if let reason = Self.availability() {
            throw LocalError.modelUnavailable(reason)
        }
        let response = try await session.respond(to: prompt)
        return response.content
    }
}
