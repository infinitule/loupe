import Foundation

/// A minimal Ollama client — one schema-constrained tool call, nothing else.
public final class Ollama {
    public let host: String
    private let session: URLSession

    public init(host: String = "http://127.0.0.1:11434") {
        self.host = host
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 900
        c.timeoutIntervalForResource = 1800
        session = URLSession(configuration: c)
    }

    public func ping(_ cb: @escaping (Bool) -> Void) {
        var r = URLRequest(url: URL(string: host + "/api/version")!)
        r.timeoutInterval = 2
        session.dataTask(with: r) { _, resp, _ in
            cb((resp as? HTTPURLResponse)?.statusCode == 200)
        }.resume()
    }

    /// One tool call. The model fills parameters; it never writes prose.
    ///
    /// **Thinking must stay enabled.** Measured on qwen3.5:0.8b, `think:false`
    /// makes it emit ~80 tokens that Ollama discards, returning empty content and
    /// no tool call at all. The free-form path wants thinking off; tool-calling
    /// needs it on. `think:"low"`/`"medium"` are accepted and ignored.
    public func callTool(model: String, system: String, user: String, tool: [String: Any],
                         numPredict: Int = 900,
                         completion: @escaping (_ args: [String: Any]?, _ error: String?) -> Void) {
        let body: [String: Any] = [
            "model": model, "stream": false, "keep_alive": "30m",
            "tools": [tool],
            "messages": [["role": "system", "content": system],
                         ["role": "user", "content": user]],
            "options": ["temperature": 0, "num_predict": numPredict],
        ]
        var r = URLRequest(url: URL(string: host + "/api/chat")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: r) { d, _, err in
            if let err { completion(nil, err.localizedDescription); return }
            guard let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { completion(nil, "bad response"); return }
            if let e = j["error"] as? String { completion(nil, e); return }
            guard let msg = j["message"] as? [String: Any],
                  let calls = msg["tool_calls"] as? [[String: Any]],
                  let fn = calls.first?["function"] as? [String: Any],
                  let args = fn["arguments"] as? [String: Any]
            else { completion(nil, "no tool call"); return }
            completion(args, nil)
        }.resume()
    }
}
