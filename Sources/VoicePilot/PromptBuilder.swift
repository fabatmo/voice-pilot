import Foundation

enum BuilderModel: String, CaseIterable {
    case haiku = "claude-haiku-4-5-20251001"
    case sonnet = "claude-sonnet-4-5-20250514"
    case opus = "claude-opus-4-5-20250514"

    var displayName: String {
        switch self {
        case .haiku: return "Haiku (fast)"
        case .sonnet: return "Sonnet (balanced)"
        case .opus: return "Opus (best)"
        }
    }
}

class PromptBuilder: ObservableObject {
    @Published var isActive = false
    @Published var currentDraft = ""
    @Published var isRefining = false
    @Published var conversationHistory: [(role: String, text: String)] = []

    var selectedModel: BuilderModel = .sonnet
    private let apiKey: String

    init() {
        // Load API key
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            self.apiKey = key
        } else if let key = Self.loadKey() {
            self.apiKey = key
        } else {
            self.apiKey = ""
        }
    }

    func start() {
        isActive = true
        currentDraft = ""
        conversationHistory = []
    }

    func stop() {
        isActive = false
        currentDraft = ""
        conversationHistory = []
    }

    func addInput(_ speech: String, completion: @escaping () -> Void) {
        guard isActive else { return }

        conversationHistory.append((role: "user", text: speech))
        isRefining = true

        buildPrompt { [weak self] result in
            DispatchQueue.main.async {
                self?.currentDraft = result
                self?.isRefining = false
                self?.conversationHistory.append((role: "assistant", text: result))
                completion()
            }
        }
    }

    private func buildPrompt(completion: @escaping (String) -> Void) {
        guard !apiKey.isEmpty else {
            // Fallback: just concatenate
            let combined = conversationHistory
                .filter { $0.role == "user" }
                .map { $0.text }
                .joined(separator: " ")
            completion(combined)
            return
        }

        let systemPrompt = """
        You are a prompt builder. The user is dictating a prompt for Claude Code CLI via voice.
        Your job: take all their input so far and produce ONE refined, professional prompt.

        RULES:
        1. Output ONLY the refined prompt. Nothing else.
        2. NEVER ask questions, add commentary, or explain yourself.
        3. Incorporate all user feedback and corrections into the prompt.
        4. If the user says to change something, update the prompt accordingly.
        5. Remove filler words, fix grammar, make it precise and actionable.
        6. The prompt should be ready to paste directly into Claude Code CLI.
        7. Keep it concise but complete — include all the user's requirements.
        """

        var messages: [[String: String]] = []
        for entry in conversationHistory {
            messages.append(["role": entry.role, "content": entry.text])
        }

        let body: [String: Any] = [
            "model": selectedModel.rawValue,
            "max_tokens": 500,
            "system": systemPrompt,
            "messages": messages
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(currentDraft)
            return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = jsonData
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String else {
                completion(self.currentDraft)
                return
            }
            completion(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }.resume()
    }

    private static func loadKey() -> String? {
        let paths = [
            "\(NSHomeDirectory())/claude-apps/voice-pilot/.env",
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
