import Foundation
import Loupe

// loupe <explain|fix|refactor|tests> [model]   — reads the subject on stdin
let names = ["explain": Task.explain, "fix": .fix, "refactor": .refactor, "tests": .tests]
guard CommandLine.arguments.count > 1, let task = names[CommandLine.arguments[1].lowercased()] else {
    FileHandle.standardError.write("usage: loupe <explain|fix|refactor|tests> [model] < input\n".data(using: .utf8)!)
    exit(2)
}
let model = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "qwen3.5:0.8b"
let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    FileHandle.standardError.write("nothing on stdin\n".data(using: .utf8)!); exit(2)
}

let sem = DispatchSemaphore(value: 0)
var code: Int32 = 0
Loupe.run(task, over: input, model: model) { result in
    switch result {
    case .success(let a):
        // The RPR trace goes to stderr so `loupe fix < x.py > y.py` stays clean.
        let f = a.finding
        var trace = "RPR: period-\(f.period) \(f.scale) · lines \(f.start)–\(f.end)"
        trace += " · contrast " + String(format: "%.1f", f.contrast)
        trace += " · showed model lines \(a.shownLines.lowerBound)–\(a.shownLines.upperBound)"
        if a.refined { trace += " · refined once" }
        FileHandle.standardError.write(Data((trace + "\n\n").utf8))
        print(a.text)
    case .failure(let e):
        FileHandle.standardError.write(Data(("\(e)\n").utf8))
        code = 1
    }
    sem.signal()
}
sem.wait()
exit(code)
