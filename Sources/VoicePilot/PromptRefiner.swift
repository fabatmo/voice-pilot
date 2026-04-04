import Foundation

class PromptRefiner {
    private let apiKey: String
    private let model = "claude-sonnet-4-5-20250514"

    init() {
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            self.apiKey = key
        } else if let key = Self.loadKeyFromEnvFile() {
            self.apiKey = key
        } else {
            self.apiKey = ""
            print("Warning: No ANTHROPIC_API_KEY found. Prompt refinement will pass through raw text.")
        }
    }

    func refine(_ rawSpeech: String, completion: @escaping (String) -> Void) {
        // Use basic cleanup only — fast and reliable
        let cleaned = stripTriggerWords(rawSpeech)
        completion(cleanBasic(cleaned))
        return

        guard !apiKey.isEmpty else {
            completion(cleanBasic(rawSpeech))
            return
        }

        let _unused = stripTriggerWords(rawSpeech)

        let systemPrompt = """
        You are a speech-to-prompt converter. Input: messy voice transcription. Output: clean CLI prompt.

        RULES:
        1. Output ONLY the cleaned prompt. Zero other text.
        2. No questions. No commentary. No apologies. No explanations.
        3. No prefixes like "Here's..." or "Refined:". Just the prompt.
        4. Remove filler words (um, uh, like, you know).
        5. Fix grammar and make intent clear.
        6. 1-3 sentences max. Be direct.
        7. If input is unclear, make your best guess. NEVER ask for clarification.

        Example input: "uh can you like check the docker file and um make sure the ports are right send"
        Example output: Check the Dockerfile and verify all port mappings are correct.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 150,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": cleaned]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(cleanBasic(rawSpeech))
            return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = jsonData
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let rawText = content.first?["text"] as? String else {
                completion(self?.cleanBasic(cleaned) ?? cleaned)
                return
            }

            let result = self.extractPrompt(rawText)
            completion(result.isEmpty ? self.cleanBasic(cleaned) : result)
        }.resume()
    }

    private func extractPrompt(_ text: String) -> String {
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Validate — if it contains questions or commentary, reject
        let lower = result.lowercased()
        let badPatterns = [
            "i need more", "could you provide", "please provide",
            "i apologize", "i'm sorry", "let me reconsider",
            "however,", "here's my", "here is my", "here's the",
            "what specific", "what do you want",
            "i don't have", "i cannot", "breaking my own",
            "confidence", "status", "budget"
        ]
        for pattern in badPatterns {
            if lower.contains(pattern) {
                return ""
            }
        }

        // If response is way longer than input, it's probably rambling
        if result.count > text.count * 3 {
            return ""
        }

        return result
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

    private static func loadKeyFromEnvFile() -> String? {
        let paths = [
            "\(NSHomeDirectory())/.env",
            "\(NSHomeDirectory())/claude-apps/voice-pilot/.env",
            "\(NSHomeDirectory())/claude-apps/neo-agent/.env",
            "\(NSHomeDirectory())/claude-apps/listo/.env",
            "\(NSHomeDirectory())/claude-apps/listo-local/.env",
            "\(NSHomeDirectory())/claude-apps/connectivity-hub/.env"
        ]
        for path in paths {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                for line in contents.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("ANTHROPIC_API_KEY=") {
                        let value = String(trimmed.dropFirst("ANTHROPIC_API_KEY=".count))
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        if !value.isEmpty { return value }
                    }
                }
            }
        }
        return nil
    }
}
