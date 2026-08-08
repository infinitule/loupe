import XCTest
@testable import Loupe

/// Validation gate for the RPR maths, split the way the original RPR project
/// splits it: identities in isolation, then synthetic defect injection.
final class RPRTests: XCTestCase {

    func testRamanujanIdentities() {
        for q in RPR.periods {
            // c_q(0) = phi(q): at n=0 every coprime term is cos(0)=1.
            XCTAssertEqual(RPR.cq(q, 0), Double(RPR.phi(q)), accuracy: 1e-9, "c_\(q)(0)")
            // Integer-valued — a non-obvious property of these sums.
            for n in 0..<24 {
                XCTAssertEqual(RPR.cq(q, n).rounded(), RPR.cq(q, n), accuracy: 1e-9)
            }
            // Period q.
            for n in 0..<12 {
                XCTAssertEqual(RPR.cq(q, n), RPR.cq(q, n + q), accuracy: 1e-9)
            }
        }
        // Sum over one period vanishes for q > 1 — no DC component.
        for q in RPR.periods where q > 1 {
            let s = (0..<q).reduce(0.0) { $0 + RPR.cq(q, $1) }
            XCTAssertEqual(s, 0, accuracy: 1e-9, "sum c_\(q)")
        }
    }

    func testPeriodSelectivity() {
        // A pure period-q wave must peak on q or a member of its divisor family,
        // never on an unrelated coprime period.
        for q in [2, 3, 4, 6, 8, 12] {
            let x = (0..<96).map { Double($0 % q < q / 2 ? 1 : -1) }
            let sig = RPR.signature(x)
            let peak = RPR.periods[sig.firstIndex(of: sig.max()!)!]
            XCTAssertTrue(peak == q || q % peak == 0 || peak % q == 0,
                          "period-\(q) wave peaked at q=\(peak)")
        }
    }

    private func grid(_ n: Int, period: Int) -> [String] {
        (0..<n).map { String(repeating: " ", count: ($0 % period) * 2) + "line\($0)" }
    }

    func testSyntheticDefectInjection() {
        let clean = RPR.analyse(grid(64, period: 8).joined(separator: "\n"))
        var broken = grid(64, period: 8)
        for i in 30..<38 { broken[i] = "        # flat — the repeat is broken here" }
        let bad = RPR.analyse(broken.joined(separator: "\n"))

        XCTAssertGreaterThan(bad.residual, clean.residual)
        XCTAssertTrue(bad.confident, "contrast \(bad.contrast)")
        XCTAssertFalse(clean.confident, "clean grid must not flag; contrast \(clean.contrast)")
        XCTAssertTrue(bad.start <= 38 && bad.end >= 31, "span \(bad.start)–\(bad.end)")
    }

    func testRealWorldFunctionBlocks() {
        // Six 5-line functions plus a blank = period 6 in indent depth, with one
        // block's indentation mangled. This is the shape that reaches real users.
        func block(_ n: String, broken: Bool) -> [String] {
            broken ? ["def \(n)(rows):", "    out = []", "    for r in rows:",
                      "      out.append(r)", "        return out", ""]
                   : ["def \(n)(rows):", "    out = []", "    for r in rows:",
                      "        out.append(r)", "    return out", ""]
        }
        var src: [String] = []
        for (i, n) in ["users","orders","items","prices","totals","taxes"].enumerated() {
            src += block(n, broken: i == 3)          // 4th block mangled -> lines 19-24
        }
        let f = RPR.analyse(src.joined(separator: "\n"))
        XCTAssertTrue(f.confident, "contrast \(f.contrast)")
        XCTAssertTrue(f.start <= 24 && f.end >= 19, "span \(f.start)–\(f.end)")
        XCTAssertEqual(f.scale, .block, "a mangled block should select the block-scale ops")
    }

    func testDegenerateInputs() {
        for text in ["", "hello", "a\nb\nc", "\n\n\n\n"] {
            let f = RPR.analyse(text)
            XCTAssertGreaterThanOrEqual(f.start, 1)
            XCTAssertGreaterThanOrEqual(f.end, f.start)
            XCTAssertTrue(RPR.periods.contains(f.period))
        }
    }
}
