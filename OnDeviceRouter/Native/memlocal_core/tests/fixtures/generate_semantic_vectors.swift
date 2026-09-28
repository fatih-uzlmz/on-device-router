// Run from this directory with:
// swift generate_semantic_vectors.swift > semantic_vectors.json
import Foundation
import NaturalLanguage

let sentences = [
    "My sister Sarah loves chocolate cake",
    "My sibling enjoys hiking on weekends",
    "I live in Toronto",
    "I visited Tokyo last spring",
    "My favorite programming language is Rust",
    "Python is popular for data science",
    "My car gets serviced every six months",
    "The meeting is scheduled for Tuesday morning",
    "What dessert does my sibling enjoy?",
    "Which city do I reside in?",
    "What coding language do I prefer?",
]

guard let model = NLEmbedding.sentenceEmbedding(for: .english) else {
    fatalError("English sentence embedding is unavailable")
}
guard model.revision == 1, model.dimension == 512 else {
    fatalError("Expected nl-en-rev-1 with 512 dimensions, got revision \(model.revision) and \(model.dimension) dimensions")
}

var vectors: [String: [Double]] = [:]
for sentence in sentences {
    guard let vector = model.vector(for: sentence), vector.count == 512 else {
        fatalError("Could not embed: \(sentence)")
    }
    let magnitude = sqrt(vector.reduce(0.0) { $0 + $1 * $1 })
    guard magnitude > 0 else {
        fatalError("Zero embedding for: \(sentence)")
    }
    vectors[sentence] = vector.map { $0 / magnitude }
}

let data = try JSONSerialization.data(withJSONObject: vectors, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
