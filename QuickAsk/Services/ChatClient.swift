import Foundation

// MARK: - API models

struct ChatMessage: Codable, Equatable {
    var role: String
    var content: String?
    var tool_calls: [ToolCall]?
    var tool_call_id: String?
    var name: String?

    static func system(_ text: String) -> ChatMessage { ChatMessage(role: "system", content: text) }
    static func user(_ text: String) -> ChatMessage { ChatMessage(role: "user", content: text) }
    static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: "assistant", content: text) }
}

struct ToolCall: Codable, Equatable {
    let id: String
    let type: String?
    let function: ToolFunctionCall
}

struct ToolFunctionCall: Codable, Equatable {
    let name: String
    let arguments: String
}

struct ChatRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
    let stream: Bool?
}

struct ChatChoice: Codable {
    struct Message: Codable {
        let role: String?
        let content: String?
    }
    let message: Message?
}

struct ChatResponse: Codable {
    let choices: [ChatChoice]?
    let error: APIErrorBody?
}

struct ModelsListResponse: Codable {
    struct Model: Codable { let id: String }
    let data: [Model]?
    let error: APIErrorBody?
}

struct APIErrorBody: Codable {
    let message: String?
    let type: String?
    let code: String?
}

enum ChatClientError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case httpStatus(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "API key is missing for the selected provider."
        case .invalidURL: return "Invalid provider base URL."
        case .httpStatus(let code, let body): return "HTTP \(code): \(body)"
        case .emptyResponse: return "Model returned an empty answer."
        }
    }
}

// MARK: - Client

/// Fast path: expand follow-ups → gather live context → one streamed completion.
actor ChatClient {
    private static let liveSystemAddon = """

    You receive LIVE CONTEXT from the app (web search and/or live weather and/or Wikipedia).
    Rules:
    - Prefer LIVE CONTEXT over training memory for current facts (weather, news, prices).
    - If LIVE WEATHER contains numbers, answer with those numbers. Do not refuse and do not invent different numbers.
    - Interpret short follow-ups using the conversation history (e.g. "а в Казани?" after a weather question means weather in Kazan).
    - Only say you lack data if LIVE CONTEXT truly has none for the ask.
    - Be concise. Cite sources briefly when using web search.
    """

    func ask(
        messages: [ChatMessage],
        profile: ProviderProfile,
        systemPrompt: String,
        webSearchEnabled: Bool,
        onStatus: (@Sendable (String?) -> Void)? = nil,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let apiKey = try requireAPIKey(for: profile)
        let url = try endpointURL(baseURL: profile.baseURL, suffix: "chat/completions")

        guard messages.contains(where: { $0.role == "user" && !($0.content ?? "").isEmpty }) else {
            throw ChatClientError.emptyResponse
        }

        var system = systemPrompt
        if webSearchEnabled {
            onStatus?("Searching…")
            let live = await LiveContext.gather(messages: messages)
            system += Self.liveSystemAddon
            system += "\n\n--- LIVE CONTEXT ---\n\(live.text)\n--- END LIVE CONTEXT ---"
        }

        var apiMessages: [ChatMessage] = [.system(system)]
        apiMessages.append(contentsOf: messages)

        onStatus?(webSearchEnabled ? "Writing…" : nil)
        let answer = try await streamComplete(
            messages: apiMessages,
            profile: profile,
            apiKey: apiKey,
            url: url,
            onDelta: onDelta
        )
        onStatus?(nil)
        return answer
    }

    func listModels(profile: ProviderProfile) async throws -> [String] {
        let apiKey = try requireAPIKey(for: profile)
        let url = try endpointURL(baseURL: profile.baseURL, suffix: "models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(&request, apiKey: apiKey, profile: profile)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatClientError.emptyResponse }
        if !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ChatClientError.httpStatus(http.statusCode, String(text.prefix(400)))
        }
        let decoded = try JSONDecoder().decode(ModelsListResponse.self, from: data)
        if let err = decoded.error?.message {
            throw ChatClientError.httpStatus(http.statusCode, err)
        }
        let ids = (decoded.data ?? []).map(\.id).filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw ChatClientError.emptyResponse }
        return ids.sorted()
    }

    // MARK: Streaming

    private func streamComplete(
        messages: [ChatMessage],
        profile: ProviderProfile,
        apiKey: String,
        url: URL,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let body = ChatRequest(
            model: profile.model,
            messages: messages,
            temperature: 0.3,
            stream: true
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuth(&request, apiKey: apiKey, profile: profile)
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 120

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatClientError.emptyResponse }

        if !(200..<300).contains(http.statusCode) {
            var errData = Data()
            for try await b in bytes { errData.append(b) }
            let text = String(data: errData, encoding: .utf8) ?? ""
            // Some gateways reject stream — fall back to non-stream.
            if http.statusCode == 400 || http.statusCode == 422 {
                return try await nonStreamComplete(messages: messages, profile: profile, apiKey: apiKey, url: url)
            }
            throw ChatClientError.httpStatus(http.statusCode, String(text.prefix(500)))
        }

        var assembled = ""

        for try await line in bytes.lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.hasPrefix("data:") else { continue }
            let payload = trimmedLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first else { continue }

            var piece = ""
            if let delta = first["delta"] as? [String: Any],
               let content = delta["content"] as? String {
                piece = content
            } else if let message = first["message"] as? [String: Any],
                      let content = message["content"] as? String {
                piece = content
            }
            if !piece.isEmpty {
                assembled += piece
                onDelta?(piece)
            }
        }

        let trimmed = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return try await nonStreamComplete(messages: messages, profile: profile, apiKey: apiKey, url: url)
        }
        return trimmed
    }

    private func nonStreamComplete(
        messages: [ChatMessage],
        profile: ProviderProfile,
        apiKey: String,
        url: URL
    ) async throws -> String {
        let body = ChatRequest(
            model: profile.model,
            messages: messages,
            temperature: 0.3,
            stream: false
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, apiKey: apiKey, profile: profile)
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatClientError.emptyResponse }
        if !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ChatClientError.httpStatus(http.statusCode, String(text.prefix(500)))
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        if let err = decoded.error?.message {
            throw ChatClientError.httpStatus(http.statusCode, err)
        }
        guard let content = decoded.choices?.first?.message?.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw ChatClientError.emptyResponse
        }
        return content
    }

    private func requireAPIKey(for profile: ProviderProfile) throws -> String {
        guard let apiKey = SecretStore.load(account: profile.id.uuidString), !apiKey.isEmpty else {
            throw ChatClientError.missingAPIKey
        }
        return apiKey
    }

    private func applyAuth(_ request: inout URLRequest, apiKey: String, profile: ProviderProfile) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("QuickAsk/1.0", forHTTPHeaderField: "User-Agent")
        if profile.kind == .openCodeGo {
            request.setValue(UUID().uuidString, forHTTPHeaderField: "x-opencode-session")
        }
    }

    private func endpointURL(baseURL: String, suffix: String) throws -> URL {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ChatClientError.invalidURL
        }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty || path == "/" {
            path = "/v1/\(suffix)"
        } else if !path.hasSuffix("/\(suffix)") {
            path += "/\(suffix)"
        }
        components.path = path
        guard let url = components.url else { throw ChatClientError.invalidURL }
        return url
    }
}
