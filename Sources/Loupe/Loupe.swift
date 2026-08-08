import Foundation

public struct Answer {
    public let text: String
    public let task: Task
    public let finding: RPR.Finding
    public let shownLines: ClosedRange<Int>   // the span the model actually saw
    public let refined: Bool
}

public enum LoupeError: Error, CustomStringConvertible {
    case unreachable(String)
    case noToolCall(String)
    case rejected(String)

    public var description: String {
        switch self {
        case .unreachable(let h): return "Ollama unreachable at \(h)"
        case .noToolCall(let e):  return "no tool call: \(e)"
        case .rejected(let c):    return "rejected after one refine: \(c)"
        }
    }
}

/// The whole loop, in one call.
///
///     Loupe.run(.fix, over: source) { result in ... }
///
/// Parameterize → Ground → Verify → Refine, with RPR choosing the schema.
public enum Loupe {
    public static func run(_ task: Task, over input: String,
                           model: String = "qwen3.5:0.8b",
                           client: Ollama = Ollama(),
                           completion: @escaping (Result<Answer, LoupeError>) -> Void) {
        let lines = input.components(separatedBy: "\n")
        let finding = RPR.analyse(input)          // instant, deterministic, no model
        client.ping { up in
            guard up else { completion(.failure(.unreachable(client.host))); return }
            attempt(task, lines, finding, model, client, complaint: nil, refined: false,
                    completion: completion)
        }
    }

    private static func attempt(_ task: Task, _ lines: [String], _ f: RPR.Finding,
                                _ model: String, _ client: Ollama,
                                complaint: String?, refined: Bool,
                                completion: @escaping (Result<Answer, LoupeError>) -> Void) {
        let o = op(for: task, scale: f.scale)
        let (excerpt, lo, hi) = ground(lines, f)

        var system = """
            You fill in parameters. Call \(o.name) exactly once and never answer in prose. \
            The input is line-numbered; all line numbers you give must be between \(lo) and \(hi).
            """
        // RPR's verdict is evidence, not a suggestion — it is the one part of
        // this pipeline that is deterministic and checkable.
        if f.confident {
            system += " Periodicity analysis: the period-\(f.period) structure breaks "
                    + "around lines \(f.start)–\(f.end). Focus your answer there."
        }
        if let c = complaint {
            system += "\n\nYour previous call was rejected because \(c). Correct exactly that."
        }

        client.callTool(model: model, system: system,
                        user: task.verb + "\n\n" + excerpt, tool: o.schema) { args, err in
            guard let args else { completion(.failure(.noToolCall(err ?? "unknown"))); return }
            let fixed = normalize(args, op: o, finding: f, lines: lines)
            if let c = verify(fixed, op: o, lines: lines) {
                // Refine is allowed exactly one retry: a second failure is
                // reported rather than looped on, so a stubborn model cannot
                // burn minutes in silence.
                if refined { completion(.failure(.rejected(c))); return }
                attempt(task, lines, f, model, client, complaint: c, refined: true,
                        completion: completion)
                return
            }
            completion(.success(Answer(text: compose(task, args: fixed, op: o, finding: f),
                                       task: task, finding: f,
                                       shownLines: lo...hi, refined: refined)))
        }
    }
}
