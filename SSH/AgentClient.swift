import Foundation

/// 对话里的一条消息。存原始 JSON，这样 AI 的回答能原样发回去（有的服务商带自己的额外字段）
nonisolated struct AgentMessage: Sendable {
    let json: Data

    private init(object: [String: Any]) throws {
        json = try JSONSerialization.data(withJSONObject: object)
    }

    init(raw: Data) { json = raw }

    static func user(_ text: String) -> AgentMessage {
        // 只有字符串，序列化不会失败
        try! AgentMessage(object: ["role": "user", "content": text])
    }

    static func tool(id: String, text: String) -> AgentMessage {
        try! AgentMessage(object: ["role": "tool", "tool_call_id": id, "content": text])
    }

    static func system(_ text: String) -> AgentMessage {
        try! AgentMessage(object: ["role": "system", "content": text])
    }
}

/// AI 想调用的一个工具
nonisolated struct AgentToolCall: Sendable {
    let id: String
    let name: String
    let arguments: String
}

/// AI 的一次回答：可能有文字，可能想调用工具
nonisolated struct AgentAnswer: Sendable {
    let message: AgentMessage
    let text: String
    let calls: [AgentToolCall]
}

nonisolated enum AgentError: LocalizedError {
    case badAddress
    case badKey
    case noCredit
    case notFound
    case rateLimited
    case server(Int, String)
    case timedOut
    case network(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .badAddress: tr("接口地址不对，要以 http:// 或 https:// 开头。")
        case .badKey: tr("API Key 不对，或者没有权限。")
        case .noCredit: tr("这个账号的额度用完了。")
        case .notFound: tr("找不到这个接口或模型，检查一下接口地址和模型名。")
        case .rateLimited: tr("请求太频繁，或者额度用完了，等一会儿再试。")
        case .server(let code, let message): tr("AI 服务返回错误 {0}：{1}", code, message)
        case .timedOut: tr("等 AI 回答超时了。")
        case .network(let message): tr("连不上 AI 服务：{0}", message)
        case .badResponse: tr("AI 服务的回答看不懂，可能不是 OpenAI 兼容格式。")
        }
    }
}

/// 用 OpenAI 兼容格式问一次 AI，回答边生成边传回来
nonisolated struct AgentClient: Sendable, Equatable {
    let baseURL: String
    let model: String
    let apiKey: String

    private static let session = URLSession(configuration: .ephemeral)

    private static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "run_command",
                "description": "Run one non-interactive shell command on the connected device and get its output and exit code. Read-only commands run right away; the app asks the user about anything else.",
                "parameters": [
                    "type": "object",
                    "properties": ["command": ["type": "string", "description": "The shell command to run"]],
                    "required": ["command"],
                ] as [String: Any],
            ] as [String: Any],
        ],
        [
            "type": "function",
            "function": [
                "name": "list_devices",
                "description": "List the devices xrsh found on the local network: IP, name, guessed type, whether SSH is open, whether passwordless login is set up.",
                "parameters": ["type": "object", "properties": [String: Any]()] as [String: Any],
            ] as [String: Any],
        ],
        [
            "type": "function",
            "function": [
                "name": "connect",
                "description": "Switch the session to another device over SSH. Only works for devices with passwordless login set up. This closes the current connection, and the app asks the user first.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "host": ["type": "string", "description": "The device's IP or host name, as shown by list_devices"],
                        "user": ["type": "string", "description": "Optional user name"],
                    ] as [String: Any],
                    "required": ["host"],
                ] as [String: Any],
            ] as [String: Any],
        ],
    ]

    var endpoint: URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if !text.hasSuffix("/chat/completions") { text += "/chat/completions" }
        guard let url = URL(string: text), url.host != nil,
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    /// onText：每收到一段回答文字就调用一次
    func complete(
        system: String,
        messages: [AgentMessage],
        onText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> AgentAnswer {
        guard let endpoint else { throw AgentError.badAddress }

        let objects = try ([AgentMessage.system(system)] + messages).map {
            try JSONSerialization.jsonObject(with: $0.json)
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": objects,
            "tools": Self.tools,
            "stream": true,
        ] as [String: Any])

        do {
            let (bytes, response) = try await Self.session.bytes(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                switch status {
                case 401, 403: throw AgentError.badKey
                case 402: throw AgentError.noCredit
                case 404: throw AgentError.notFound
                case 429: throw AgentError.rateLimited
                default: throw AgentError.server(status, Self.errorMessage(from: try await Self.collect(bytes)))
                }
            }
            // 有的服务不支持流式，会直接回一整段 JSON
            let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard contentType.contains("event-stream") else {
                let answer = try Self.parse(try await Self.collect(bytes))
                if !answer.text.isEmpty { await onText(answer.text) }
                return answer
            }
            return try await Self.parseStream(bytes, onText: onText)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw AgentError.timedOut
            default: throw AgentError.network(error.localizedDescription)
            }
        }
    }

    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        // 回答和报错都不该有这么长，防止被撑爆
        for try await byte in bytes where data.count < 2_000_000 { data.append(byte) }
        return data
    }

    /// 把一段段流式数据拼回一条完整的消息。工具调用是按序号分好几段传的
    private static func parseStream(
        _ bytes: URLSession.AsyncBytes,
        onText: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> AgentAnswer {
        struct PartialCall {
            var id = ""
            var name = ""
            var arguments = ""
        }
        var text = ""
        var reasoning = ""
        var partial: [Int: PartialCall] = [:]

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let failure = object["error"] as? [String: Any] {
                throw AgentError.server(0, String((failure["message"] as? String ?? "").prefix(200)))
            }
            guard let delta = (object["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { continue }
            if let piece = delta["content"] as? String, !piece.isEmpty {
                text += piece
                await onText(piece)
            }
            if let piece = delta["reasoning_content"] as? String { reasoning += piece }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = call["index"] as? Int ?? 0
                var current = partial[index] ?? PartialCall()
                if let id = call["id"] as? String, !id.isEmpty { current.id = id }
                let function = call["function"] as? [String: Any]
                if let name = function?["name"] as? String, !name.isEmpty { current.name = name }
                if let piece = function?["arguments"] as? String { current.arguments += piece }
                partial[index] = current
            }
        }

        let calls = partial.sorted { $0.key < $1.key }.map { index, call in
            AgentToolCall(id: call.id.isEmpty ? "call_\(index)" : call.id, name: call.name, arguments: call.arguments)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !calls.isEmpty else { throw AgentError.badResponse }

        var message: [String: Any] = ["role": "assistant", "content": text.isEmpty ? NSNull() : text]
        // 有的服务商要求把思考内容原样发回去
        if !reasoning.isEmpty { message["reasoning_content"] = reasoning }
        if !calls.isEmpty {
            message["tool_calls"] = calls.map { call -> [String: Any] in
                ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments]]
            }
        }
        guard let raw = try? JSONSerialization.data(withJSONObject: message) else { throw AgentError.badResponse }
        return AgentAnswer(message: AgentMessage(raw: raw), text: trimmed, calls: calls)
    }

    private static func errorMessage(from data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (object?["error"] as? [String: Any])?["message"] as? String
        return String((message ?? String(decoding: data, as: UTF8.self)).prefix(200))
    }

    private static func parse(_ data: Data) throws -> AgentAnswer {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let raw = try? JSONSerialization.data(withJSONObject: message) else {
            throw AgentError.badResponse
        }
        let calls: [AgentToolCall] = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { call in
            guard let id = call["id"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            return AgentToolCall(id: id, name: name, arguments: function["arguments"] as? String ?? "")
        }
        let text = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !calls.isEmpty else { throw AgentError.badResponse }
        return AgentAnswer(message: AgentMessage(raw: raw), text: text, calls: calls)
    }
}
