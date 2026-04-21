import Foundation

class PromptRefiner {
    func refine(_ rawSpeech: String, completion: @escaping (String) -> Void) {
        let cleaned = stripTriggerWords(rawSpeech)
        completion(cleanBasic(cleaned))
    }

    private func stripTriggerWords(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let triggerWords = ["send", "send it", "send now", "go", "go now"]
        let lower = cleaned.lowercased()
        for trigger in triggerWords {
            if lower.hasSuffix(trigger) {
                let endIndex = cleaned.index(cleaned.endIndex, offsetBy: -trigger.count)
                cleaned = String(cleaned[cleaned.startIndex..<endIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return cleaned.isEmpty ? text : cleaned
    }

    private func cleanBasic(_ text: String) -> String {
        var cleaned = stripTriggerWords(text)
        let fillers = ["um", "uh", "like", "you know", "basically", "actually", "so like", "I mean"]
        for filler in fillers {
            cleaned = cleaned.replacingOccurrences(
                of: "\\b\(filler)\\b",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
