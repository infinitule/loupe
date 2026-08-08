import Foundation

/// PGVR — Parameterize → Ground → Verify → Refine.
///
/// The loop exists because a small local model cannot be trusted to *write* an
/// answer, but can be trusted to *fill in parameters*. So it never writes the
/// answer: it fills a schema, the schema is checked against the real input, and
/// the output is composed here, deterministically.
///
/// Which schema it gets is decided by `RPR` — the disrupted period tells you the
/// scale of the thing that broke, and a line-scale defect is not asked the same
/// questions as a section-scale one.

// MARK: - Tasks

public enum Task: Int, CaseIterable, Sendable {
    case explain = 0, fix, refactor, tests

    public var name: String {
        switch self {
        case .explain:  return "Explain"
        case .fix:      return "Fix"
        case .refactor: return "Refactor"
        case .tests:    return "Tests"
        }
    }

    public var verb: String {
        switch self {
        case .explain:  return "Describe what this does."
        case .fix:      return "Fix the defect."
        case .refactor: return "Rewrite this more clearly, same behaviour."
        case .tests:    return "Write tests for this."
        }
    }
}

// MARK: - Operations

/// A callable operation: a name plus the parameter set the model must fill.
public struct Op {
    public let name: String
    public let desc: String
    /// (parameter, JSON type, description)
    public let props: [(String, String, String)]

    var codeField: String? { props.map(\.0).first { $0 == "replacement" || $0 == "code" } }

    /// The JSON Schema handed to the model as a tool definition.
    public var schema: [String: Any] {
        var p: [String: Any] = [:]
        for (n, t, d) in props { p[n] = ["type": t, "description": d] }
        return ["type": "function",
                "function": ["name": name, "description": desc,
                             "parameters": ["type": "object", "properties": p,
                                            "required": props.map(\.0)]]]
    }
}

/// Span parameters activated at each structural scale. This is where RPR's
/// verdict does its work: a period-2 break is never asked for a section `unit`,
/// and a period-24 break is never squeezed onto one line.
func spanProps(_ s: RPR.Scale) -> [(String, String, String)] {
    switch s {
    case .line:
        return [("line", "integer", "the line number where the problem is")]
    case .block:
        return [("start", "integer", "first line of the block"),
                ("end",   "integer", "last line of the block")]
    case .section:
        return [("start", "integer", "first line of the section"),
                ("end",   "integer", "last line of the section"),
                ("unit",  "string",  "kind of unit: function, class, loop, or stanza")]
    }
}

/// Task × RPR scale → the single operation put in front of the model.
///
/// Field *names* carry most of the weight with a small model. An abstract name
/// like `what` invites it to echo the instruction back; a concrete name with a
/// worked example does not. That is not a style preference — it was the
/// difference between a real explanation and the prompt repeated verbatim.
public func op(for task: Task, scale: RPR.Scale) -> Op {
    let span = spanProps(scale)
    let sfx = scale == .line ? "line" : (scale == .block ? "block" : "section")
    switch task {
    case .explain:
        return Op(name: "explain_\(sfx)", desc: "Describe what this span of the input does.",
                  props: span + [
                    ("summary", "string",
                     "one sentence stating what the code actually does, in your own words. "
                     + "Example: 'Averages a list of numbers, dividing by zero when the list is empty.' "
                     + "Never repeat the instruction you were given."),
                    ("role", "string", "what it is for, a few words. Example: 'statistics helper'")])
    case .fix:
        return Op(name: "fix_\(sfx)", desc: "Report the defect and the corrected code for this span.",
                  props: span + [
                    ("issue", "string", "the defect, in a few words"),
                    ("replacement", "string",
                     "complete corrected code for that span, including any definition header")])
    case .refactor:
        return Op(name: "refactor_\(sfx)", desc: "Rewrite this span more clearly without changing behaviour.",
                  props: span + [
                    ("goal", "string", "what the rewrite improves, a few words"),
                    ("replacement", "string",
                     "complete rewritten code for that span, including any definition header")])
    case .tests:
        return Op(name: "test_\(sfx)", desc: "Write tests covering this span.",
                  props: span + [
                    ("target", "string", "name of the thing under test"),
                    ("cases",  "string", "edge cases covered, comma separated"),
                    ("code",   "string", "complete runnable test code including imports")])
    }
}

// MARK: - Ground

/// Show the model only the span RPR localised, with **absolute** line numbers so
/// Verify and Compose keep addressing the real file rather than the excerpt.
///
/// This is the highest-leverage step in the loop. Measured on a 35-line file
/// with qwen3.5:0.8b: the whole file produced 3,434 tokens of reasoning over
/// 193s and **no tool call at all**, while the same defect inside a 10-line
/// window returned a correct call in 31s.
public func ground(_ lines: [String], _ f: RPR.Finding,
                   pad: Int = 3) -> (text: String, lo: Int, hi: Int) {
    var lo = 1, hi = lines.count
    if f.confident, lines.count > 16 {
        lo = max(1, f.start - pad)
        hi = min(lines.count, f.end + pad)
    }
    guard lo <= hi, !lines.isEmpty else { return ("", 1, 1) }
    let text = (lo...hi).map { "\($0): \(lines[$0 - 1])" }.joined(separator: "\n")
    return (text, lo, hi)
}

// MARK: - Verify

/// Coerce span parameters into something usable, falling back to RPR's own span.
///
/// Verify stays strict about *content*; it has no business failing a run over
/// metadata. Observed repeatedly: `line` comes back as `"1: def avg(xs):"` — the
/// whole line rather than its number — and discarding a correct answer over that
/// is the wrong trade when RPR already localised the span deterministically.
public func normalize(_ args: [String: Any], op o: Op,
                      finding f: RPR.Finding, lines: [String]) -> [String: Any] {
    var a = args
    func lenient(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let d = v as? Double { return Int(d) }
        guard let s = v as? String else { return nil }
        if let n = Int(s.trimmingCharacters(in: .whitespaces)) { return n }
        let digits = s.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
    let lo = max(1, min(f.start, max(lines.count, 1)))
    let hi = max(lo, min(f.end, max(lines.count, 1)))
    if o.props.contains(where: { $0.0 == "line" }) {
        a["line"] = lenient(a["line"]) ?? lo
    } else {
        a["start"] = lenient(a["start"]) ?? lo
        a["end"]   = lenient(a["end"])   ?? hi
    }
    return a
}

/// The step that earns its keep. Measured on a stock 0.8B, two of three raw tool
/// calls were unusable — a span of lines 2–14 for a 2-line input, and a
/// `replacement` that was a bare broken expression. Both are rejected here
/// rather than handed back as an answer.
///
/// Returns `nil` when the call is sound, or a complaint to feed into Refine.
public func verify(_ args: [String: Any], op o: Op, lines: [String]) -> String? {
    func intArg(_ k: String) -> Int? {
        if let n = args[k] as? Int { return n }
        if let d = args[k] as? Double { return Int(d) }
        if let s = args[k] as? String { return Int(s) }
        return nil
    }
    var lo = 1, hi = lines.count
    if o.props.contains(where: { $0.0 == "line" }) {
        guard let l = intArg("line") else { return "the line number was missing" }
        lo = l; hi = l
    } else {
        guard let s = intArg("start"), let e = intArg("end") else {
            return "start and end were missing"
        }
        lo = s; hi = e
    }
    guard lo >= 1, hi <= lines.count, lo <= hi else {
        return "the span \(lo)–\(hi) is outside the input, which has \(lines.count) lines"
    }
    for (n, t, _) in o.props where t == "string" {
        let v = (args[n] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if v.isEmpty { return "the '\(n)' parameter was empty" }
    }
    // A code answer must be whole. If the span it claims contains a definition
    // header, the replacement has to as well — precisely the bare-fragment
    // failure that free-form generation kept producing.
    if let cf = o.codeField {
        let body = unfence((args[cf] as? String) ?? "")
        let original = lines[(lo - 1)..<min(hi, lines.count)].joined(separator: "\n")
        let headers = ["def ", "func ", "class ", "fn ", "function ", "public ", "private "]
        if headers.contains(where: { original.contains($0) }),
           !headers.contains(where: { body.contains($0) }) {
            return "'\(cf)' was only a fragment — it must repeat the full definition header"
        }
        if body.count < 3 { return "'\(cf)' was too short to be real code" }
    }
    return nil
}

// MARK: - Compose

/// Models ignore "no markdown fences" often enough that stripping is worth it.
public func unfence(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.hasPrefix("```") else { return t }
    if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
    if let r = t.range(of: "```", options: .backwards) { t = String(t[..<r.lowerBound]) }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Build the answer from verified fields. The model supplies the values; the
/// sentence structure is ours, so there is nothing left for it to ramble into.
public func compose(_ task: Task, args: [String: Any], op o: Op, finding f: RPR.Finding) -> String {
    func s(_ k: String) -> String {
        ((args[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func span() -> String {
        if let l = args["line"] as? Int { return "line \(l)" }
        let a = (args["start"] as? Int) ?? 0
        let b = (args["end"] as? Int) ?? 0
        let unit = s("unit")
        return unit.isEmpty ? "lines \(a)–\(b)" : "\(unit), lines \(a)–\(b)"
    }
    switch task {
    case .explain:
        var out = s("summary")
        let role = s("role")
        if !role.isEmpty { out += "\n\nRole: " + role }
        // Only mention periodicity when it found something; on a short input
        // "period-1, residual 0.00" is noise dressed as insight.
        if f.confident {
            out += "\n\nRPR: period-\(f.period) break at \(span()), "
                 + "residual \(String(format: "%.2f", f.residual))"
        }
        return out
    case .tests:
        return unfence(s("code"))
    case .fix, .refactor:
        return unfence(s(o.codeField ?? "replacement"))
    }
}
