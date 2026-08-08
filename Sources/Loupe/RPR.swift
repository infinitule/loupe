import Foundation

// ── RPR: Ramanujan Periodicity Residual ──────────────────────────────────────
//
// Ported from the RPR project's periodicity core, with the signal swapped from
// 2-D texture patches to the 1-D structure of whatever is on the clipboard.
// The question is unchanged: not "does this look wrong?" but "does this still
// repeat the way it should?" — and, when it doesn't, *which* period broke.
//
// That disrupted period is a discrete selector, and it is what chooses which
// operations the model is allowed to call downstream.
public enum RPR {
    /// Highly composite candidates — the same trick RPR uses to cut a 32-period
    /// sweep to 8 without losing divisor coverage.
    public static let periods = [1, 2, 3, 4, 6, 8, 12, 24]

    /// Structural scale, derived from the disrupted period. It decides which
    /// ops are exposed: a broken 2-line cadence is a different kind of defect
    /// from a broken 24-line one, and they deserve different questions.
    public enum Scale { case line, block, section }

    public static func scale(for q: Int) -> Scale {
        switch q {
        case 1, 2:     return .line
        case 3, 4, 6:  return .block
        default:       return .section
        }
    }

    static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
    static func phi(_ q: Int) -> Int { (1...max(q, 1)).filter { gcd($0, q) == 1 }.count }

    /// c_q(n) = Σ_{k ≤ q, gcd(k,q)=1} cos(2πkn/q).
    /// Real, integer-valued, and — the property the whole method rests on —
    /// selective for exactly period q, not its harmonics or its neighbours.
    static func cq(_ q: Int, _ n: Int) -> Double {
        var s = 0.0
        for k in 1...max(q, 1) where gcd(k, q) == 1 {
            s += cos(2.0 * .pi * Double(k) * Double(n) / Double(q))
        }
        return s
    }

    /// FIR filter for period q, normalised to **unit L2 norm**.
    ///
    /// √φ(q) alone is not enough here. The identity Σ_{n<q} c_q(n)² = q·φ(q)
    /// means a √φ(q)-scaled filter still has squared norm q, so a longer period
    /// collects more energy purely by having more taps — under that scaling the
    /// bank misreported a period-8 grid as period 12. Unit norm makes energies
    /// comparable across the bank, which is the only thing we ever compare.
    static func filter(_ q: Int) -> [Double] {
        let taps = (0..<max(q, 1)).map { cq(q, $0) }
        let norm = sqrt(taps.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? taps.map { $0 / norm } : taps
    }
    static let bank: [[Double]] = periods.map { filter($0) }

    /// Per-period energy, L2-normalised — the periodicity signature of a window.
    ///
    /// The correlation is **circular**, over a length truncated to a multiple of
    /// 24. A linear sliding correlation leaves W−q+1 positions, which is not a
    /// whole number of output cycles, so energy depends on where the window
    /// happened to start — under that version a perfectly clean period-8 grid
    /// scored as anomalous as a deliberately broken one. Summing the q circular
    /// phases over whole cycles is phase-invariant by construction.
    /// `base` is the alignment unit: the length is truncated to a multiple of it,
    /// and any period that does not divide it is left at zero rather than
    /// reported with phase contamination. You cannot resolve a 24-line period in
    /// a 35-line file, so short inputs honestly report nothing for the long
    /// periods instead of guessing at them.
    static func signature(_ x: [Double], base: Int = 24) -> [Double] {
        var sig = [Double](repeating: 0, count: periods.count)
        let n = (x.count / base) * base
        guard n >= base else { return sig }
        for (i, h) in bank.enumerated() {
            let q = h.count
            guard base % q == 0 else { continue }
            var e = 0.0
            for s in 0..<q {
                var acc = 0.0
                for j in 0..<n { acc += x[j] * h[(j + s) % q] }
                e += acc * acc
            }
            sig[i] = e / Double(n * q)
        }
        let norm = sqrt(sig.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { for i in sig.indices { sig[i] /= norm } }
        return sig
    }

    static func cosineDistance(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return 1 - dot / (sqrt(na) * sqrt(nb))
    }

    /// Indentation is the load-bearing periodic signal in code. Prose barely
    /// indents, so when indent variance collapses, line length carries the
    /// rhythm instead.
    static func signal(_ lines: [String]) -> [Double] {
        let indent = lines.map { l -> Double in
            var d = 0.0
            for ch in l { if ch == " " { d += 1 } else if ch == "\t" { d += 4 } else { break } }
            return d
        }
        let len = lines.map { Double($0.count) }
        let base = variance(indent) > 0.5 ? indent : len
        let mean = base.reduce(0, +) / Double(max(base.count, 1))
        return base.map { $0 - mean }          // DC removal; c_q has no DC term for q>1
    }

    static func variance(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let m = x.reduce(0, +) / Double(x.count)
        return x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count)
    }

    public struct Finding {
        public var period: Int
        public var start: Int          // 1-based, inclusive
        public var end: Int
        public var residual: Double    // cosine distance of the worst window
        public var contrast: Double    // that distance over the median window's
        public var spectrum: [Double]  // global signature, for the strip display
        public var scale: Scale { RPR.scale(for: period) }

        /// Absolute cosine distance is the wrong yardstick: on real text every
        /// window shares most of its structure, so even a blatant break scores
        /// ~0.01. RPR reports anomalies as a multiple of the clean baseline, so
        /// contrast is what decides whether there is anything to report.
        public var confident: Bool { contrast > 2.5 && residual > 0.002 }
    }

    /// Slide a window, signature each one, and score it against the *median*
    /// signature of all windows — the stand-in for RPR's memory bank of known
    /// good patches. The worst-scoring window is the anomaly; the period whose
    /// energy dropped most inside it is the one that broke.
    public static func analyse(_ text: String) -> Finding {
        let lines = text.components(separatedBy: "\n")
        let x = signal(lines)

        // The window length is a common multiple of the periods it must resolve,
        // so every window holds a whole number of cycles for each of them. With
        // a ragged length, windows differ by phase alone and a perfectly clean
        // grid scores as anomalous as a deliberately broken one.
        //
        // Detecting a period needs several cycles of it, so the base scales with
        // the input: only a long input earns the full bank. A 36-line window
        // also needs enough windows for the median to mean anything.
        let base = x.count >= 48 ? 24 : 12
        let global = signature(x, base: base)

        guard x.count >= base + 3 else {
            return Finding(period: 1, start: 1, end: max(lines.count, 1),
                           residual: 0, contrast: 0, spectrum: global)
        }

        let w = base
        let hop = max(1, base / 4)
        var windows: [(Int, [Double])] = []
        var t = 0
        while t + w <= x.count {
            windows.append((t, signature(Array(x[t..<(t + w)]), base: base)))
            t += hop
        }
        guard windows.count >= 2 else {
            return Finding(period: 1, start: 1, end: lines.count,
                           residual: 0, contrast: 0, spectrum: global)
        }

        // Element-wise median across windows = the "good" reference signature.
        var reference = [Double](repeating: 0, count: periods.count)
        for i in periods.indices {
            let col = windows.map { $0.1[i] }.sorted()
            reference[i] = col[col.count / 2]
        }

        var worst = (dist: -1.0, offset: 0, sig: reference)
        var dists: [Double] = []
        for (off, sig) in windows {
            let d = cosineDistance(sig, reference)
            dists.append(d)
            if d > worst.dist { worst = (d, off, sig) }
        }
        // The median window is the "clean baseline" the worst one is judged against.
        let median = dists.sorted()[dists.count / 2]
        let contrast = worst.dist / max(median, 1e-6)

        // Attribution: which period broke. Ranking by absolute energy drop
        // favours whichever period was loudest to begin with — a mangled 6-line
        // block came back as period 2. Ranking by *fractional* loss, among only
        // those periods that carried real structure, names the period that
        // actually stopped repeating.
        let peak = reference.max() ?? 0
        var q = periods[0], best = -Double.infinity
        for i in periods.indices where reference[i] >= 0.2 * peak {
            let loss = (reference[i] - worst.sig[i]) / max(reference[i], 1e-9)
            if loss > best { best = loss; q = periods[i] }
        }

        // Divisor-family promotion. A period-6 block lives in the span of its
        // divisors, so a break in it shows up on q=2 as readily as on q=6 —
        // which would file a mangled *block* under the line-scale op set. Report
        // the coarsest member of the family that actually carries structure, so
        // the scale matches the thing that broke.
        for p in periods.reversed() where p % q == 0 && p != q {
            if let i = periods.firstIndex(of: p), reference[i] >= 0.2 * peak {
                q = p
                break
            }
        }

        return Finding(period: q,
                       start: worst.offset + 1,
                       end: min(worst.offset + w, lines.count),
                       residual: worst.dist,
                       contrast: contrast,
                       spectrum: global)
    }
}
