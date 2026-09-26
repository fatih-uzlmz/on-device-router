import Foundation

/// A proposed atomic fact from the on-device language model. The source quote
/// and object are checked against the user's message before anything is stored.
nonisolated struct MemoryCandidate: Codable, Sendable {
    let subject: String
    let predicate: String
    let object: String
    let evidence: String
    let replacesFactID: UUID?

    init(subject: String, predicate: String, object: String,
         evidence: String, replacesFactID: UUID?) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.evidence = evidence
        self.replacesFactID = replacesFactID
    }

    private enum CodingKeys: String, CodingKey {
        case subject, predicate, object, evidence, replacesFactID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        subject = try values.decode(String.self, forKey: .subject)
        predicate = try values.decode(String.self, forKey: .predicate)
        object = try values.decode(String.self, forKey: .object)
        evidence = try values.decode(String.self, forKey: .evidence)
        let id = try values.decodeIfPresent(String.self, forKey: .replacesFactID)
        replacesFactID = id.flatMap(UUID.init(uuidString:))
    }
}

nonisolated enum MemoryExtraction {
    static func sentences(in message: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"[^.!?]+[.!?]?"#) else {
            return [message]
        }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        return expression.matches(in: message, range: range).prefix(6).compactMap { match in
            guard let range = Range(match.range, in: message) else { return nil }
            let sentence = message[range].trimmingCharacters(in: .whitespacesAndNewlines)
            return sentence.isEmpty ? nil : sentence
        }
    }

    static func prompt(for message: String) -> String {
        return """
            Extract facts about the user from the message. Return only a JSON array.
            Each fact needs subject, predicate, object, evidence. Copy evidence
            EXACTLY from the message. Copy object EXACTLY from the evidence.
            One fact per item. Questions and guesses produce [].
            Example message: My dog is named Snow.
            Example output: [{"subject":"user_dog","predicate":"name","object":"Snow","evidence":"My dog is named Snow."}]
            Example message: I live in San Francisco.
            Example output: [{"subject":"user","predicate":"lives_in","object":"San Francisco","evidence":"I live in San Francisco."}]
            Message:
            \(message)
            JSON:
            """
    }

    static func parse(_ response: String, source: String, existingFacts: [DurableFact]) -> [MemoryCandidate] {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"), start <= end,
              let data = String(response[start...end]).data(using: .utf8),
              let candidates = try? JSONDecoder().decode([MemoryCandidate].self, from: data) else {
            return []
        }
        return Array(candidates.prefix(6)).compactMap {
            validated($0, source: source, existingFacts: existingFacts)
        }
    }

    static func validated(
        _ candidate: MemoryCandidate,
        source: String,
        existingFacts: [DurableFact]
    ) -> MemoryCandidate? {
        let evidence = candidate.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        let object = candidate.object.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let objectWords = object.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let meaninglessObjects: Set<String> = ["a", "an", "at", "by", "for", "from", "in", "is",
                                                "of", "on", "or", "the", "to", "with", "yes", "no"]
        guard !evidence.isEmpty, !object.isEmpty, !evidence.contains("?"),
              objectWords.count <= 12,
              !meaninglessObjects.contains(object.lowercased()),
              source.contains(evidence), evidence.contains(object) else {
            return nil
        }
        let subjectTerms = candidate.subject.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { !["user", "person", "self", "my", "i"].contains($0) }
        let evidenceTerms = Set(evidence.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        guard subjectTerms.isEmpty || subjectTerms.contains(where: evidenceTerms.contains) else {
            return nil
        }

        var replacement = candidate.replacesFactID
        if let id = replacement {
            guard let old = existingFacts.first(where: { $0.id == id && $0.isActive }),
                  slotsOverlap(candidate, old) else { return nil }
            replacement = old.id
        } else if isSingleValued(candidate) || isExplicitCorrection(source) {
            let matching = existingFacts.filter {
                $0.isActive && slotsOverlap(candidate, $0)
                    && $0.triple.object.compare(object, options: .caseInsensitive) != .orderedSame
            }
            if matching.count == 1 { replacement = matching[0].id }
        }
        let replaced = replacement.flatMap { id in existingFacts.first { $0.id == id } }
        guard let subject = replaced?.triple.subject ?? canonicalIdentifier(candidate.subject),
              let predicate = replaced?.triple.predicate ?? canonicalIdentifier(candidate.predicate)
        else { return nil }
        return MemoryCandidate(subject: subject,
                               predicate: predicate,
                               object: object, evidence: evidence,
                               replacesFactID: replacement)
    }

    private static func canonicalIdentifier(_ value: String) -> String? {
        let words = value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !words.isEmpty, words.joined().count <= 80 else { return nil }
        if words == ["i"] || words == ["me"] || words == ["my"] { return "user" }
        return words.joined(separator: "_")
    }

    private static func slotsOverlap(_ candidate: MemoryCandidate, _ old: DurableFact) -> Bool {
        let candidateTerms = Set((candidate.subject + " " + candidate.predicate)
            .lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let oldTerms = Set((old.triple.subject + " " + old.triple.predicate)
            .lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let shared = candidateTerms.intersection(oldTerms).subtracting(["user", "value", "is"])
        return candidate.subject == old.triple.subject && candidate.predicate == old.triple.predicate
            || shared.count >= 2
    }

    private static func isSingleValued(_ candidate: MemoryCandidate) -> Bool {
        let slot = candidate.subject.lowercased() + "_" + candidate.predicate.lowercased()
        return ["favorite", "name", "lives_in", "location", "birthplace", "birthday"]
            .contains(where: slot.contains)
    }

    private static func isExplicitCorrection(_ source: String) -> Bool {
        let text = source.lowercased()
        return ["changed", "new ", "actually", "instead", "no longer", "now", "rather"]
            .contains(where: text.contains)
    }
}
