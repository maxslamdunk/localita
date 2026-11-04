import Foundation

/// Research-only: simulates a lossy routed-expert format by rewriting each
/// expert in memory right after it is read, before any kernel sees it. Off
/// unless the environment variable `TURBO_FIELDFARE_LOSSY_EXPERTS` is set, and
/// then it changes the model's output on purpose. Timings from such a run are
/// not benchmark figures: the rewrite costs CPU time a real format would not.
///
/// The rewritten expert stays in the installed affine INT4 layout, so no
/// kernel changes. That works because every lower-bit affine group is also a
/// valid INT4 group: k-bit codes 0..<2^k are INT4 codes, with the group's own
/// scale and bias. The bytes a real k-bit format would read are arithmetic,
/// not measured here.
///
/// Spec, comma-separated:
/// - `all=<k>`, or `gate=<k>`, `up=<k>`, `down=<k>`: requantize those tensors
///   to k bits (1...4) per group of 64, from the installed INT4 values. 4
///   leaves a tensor untouched.
/// - `noise=<p>`: instead, move each INT4 code by ±1 with probability p
///   (p/2 each way, clamped), seeded by position. p = 1/12 adds error of the
///   variance one INT4 rounding has (s²/12), a yardstick for the others.
/// - `experts=<path>`: only experts listed in the file, one `layer expert`
///   pair per line, are rewritten. Without it, all are.
package struct LossyExpertSimulation: Sendable {
    package static let environmentKey = "TURBO_FIELDFARE_LOSSY_EXPERTS"

    package struct Tensor: Sendable {
        let codesOffset: Int
        let scalesOffset: Int
        let biasesOffset: Int
        let rows: Int
        let cols: Int
    }

    /// Bits per tensor, in `tensors` order (gate, up, down).
    let bits: [Int]
    let noiseProbability: Double
    let selected: Set<Int>?
    let tensors: [Tensor]

    package static let groupSize = 64

    package init?(environment: [String: String] = ProcessInfo.processInfo.environment,
                  tensors: [Tensor]) throws {
        guard let spec = environment[Self.environmentKey], !spec.isEmpty else { return nil }
        var bits = [4, 4, 4]
        var noise = 0.0
        var selected: Set<Int>?
        for item in spec.split(separator: ",") {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw LossyExpertSimulationError.badSpec(spec) }
            switch parts[0] {
            case "all", "gate", "up", "down":
                guard let k = Int(parts[1]), (1...4).contains(k) else {
                    throw LossyExpertSimulationError.badSpec(spec)
                }
                switch parts[0] {
                case "gate": bits[0] = k
                case "up": bits[1] = k
                case "down": bits[2] = k
                default: bits = [k, k, k]
                }
            case "noise":
                guard let p = Double(parts[1]), p >= 0, p <= 1 else {
                    throw LossyExpertSimulationError.badSpec(spec)
                }
                noise = p
            case "experts":
                let text = try String(contentsOfFile: parts[1], encoding: .utf8)
                var set = Set<Int>()
                for line in text.split(separator: "\n") {
                    let fields = line.split(separator: " ").compactMap { Int($0) }
                    if fields.count == 2 { set.insert(Self.key(layer: fields[0], expert: fields[1])) }
                }
                selected = set
            default:
                throw LossyExpertSimulationError.badSpec(spec)
            }
        }
        self.bits = bits
        self.noiseProbability = noise
        self.selected = selected
        self.tensors = tensors
    }

    static func key(layer: Int, expert: Int) -> Int { layer &* 4096 &+ expert }

    package var description: String {
        noiseProbability > 0
            ? "noise p=\(noiseProbability)"
            : "bits gate=\(bits[0]) up=\(bits[1]) down=\(bits[2])"
        + (selected.map { " experts=\($0.count)" } ?? "")
    }

    /// Rewrites one expert in place.
    package func apply(to base: UnsafeMutableRawPointer, layer: Int, expert: Int) {
        if let selected, !selected.contains(Self.key(layer: layer, expert: expert)) { return }
        nonisolated(unsafe) let base = base
        for (index, tensor) in tensors.enumerated() {
            let k = bits[index]
            guard noiseProbability > 0 || k < 4 else { continue }
            // A group on the global queue, not `concurrentPerform`: reads
            // already run inside one, and a nested one runs serially.
            let chunks = 16
            let rowsPerChunk = (tensor.rows + chunks - 1) / chunks
            let group = DispatchGroup()
            for chunk in 0..<chunks {
                let start = chunk * rowsPerChunk
                let end = min(tensor.rows, start + rowsPerChunk)
                guard start < end else { continue }
                DispatchQueue.global(qos: .userInitiated).async(group: group) {
                    self.rewriteRows(base: base, tensor: tensor, rows: start..<end, bits: k,
                                     seed: UInt64(layer) << 40 ^ UInt64(expert) << 24 ^ UInt64(index) << 20)
                }
            }
            group.wait()
        }
    }

    private func rewriteRows(base: UnsafeMutableRawPointer, tensor: Tensor,
                             rows: Range<Int>, bits: Int, seed: UInt64) {
        let groups = tensor.cols / Self.groupSize
        let rowBytes = tensor.cols / 2
        let codes = base.advanced(by: tensor.codesOffset).assumingMemoryBound(to: UInt8.self)
        let scales = base.advanced(by: tensor.scalesOffset).assumingMemoryBound(to: UInt16.self)
        let biases = base.advanced(by: tensor.biasesOffset).assumingMemoryBound(to: UInt16.self)
        for row in rows {
            for g in 0..<groups {
                let groupCodes = codes.advanced(by: row * rowBytes + g * (Self.groupSize / 2))
                let sideIndex = row * groups + g
                if noiseProbability > 0 {
                    Self.addNoise(groupCodes, probability: noiseProbability,
                                  seed: seed ^ UInt64(sideIndex) &* 0x9E37_79B9_7F4A_7C15)
                } else {
                    Self.requantize(groupCodes, scale: &scales[sideIndex],
                                    bias: &biases[sideIndex], levels: 1 << bits)
                }
            }
        }
    }

    static func bf16ToFloat(_ bits: UInt16) -> Float { Float(bitPattern: UInt32(bits) << 16) }

    static func floatToBF16(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        if value.isNaN { return 0x7FC0 }
        let rounding = UInt32(0x7FFF) + ((bits >> 16) & 1)
        return UInt16(truncatingIfNeeded: (bits &+ rounding) >> 16)
    }

    /// Moves each of the group's 64 codes by ±1 with `probability`, clamped.
    static func addNoise(_ group: UnsafeMutablePointer<UInt8>, probability: Double, seed: UInt64) {
        var state = seed | 1
        let threshold = UInt64(probability * Double(UInt32.max))
        for byte in 0..<(groupSize / 2) {
            var value = group[byte]
            for half in 0..<2 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let draw = (state >> 32) & 0xFFFF_FFFF
                guard draw < threshold else { continue }
                let shift = UInt8(half * 4)
                var q = Int((value >> shift) & 0x0F)
                q = draw < threshold / 2 ? max(0, q - 1) : min(15, q + 1)
                value = (value & ~(0x0F << shift)) | (UInt8(q) << shift)
            }
            group[byte] = value
        }
    }

    /// Requantizes one group of 64 INT4 codes to `levels` affine levels.
    ///
    /// The group's values are `q·s + b` for its INT4 codes q, so a grid
    /// `c·S + B` fits them exactly as well as `c·α + β` fits the codes, with
    /// `S = α·s` and `B = β·s + b`. The search therefore runs on the 16-bin
    /// histogram of codes: clipping ranges [lo, hi] up to two codes in from
    /// each end, then one weighted least-squares refit of α and β for the
    /// chosen codes, keeping whichever has the least squared error. Scale and
    /// bias are rounded to BF16 last, which moves the grid by under 0.4%.
    static func requantize(_ group: UnsafeMutablePointer<UInt8>,
                           scale: inout UInt16, bias: inout UInt16, levels: Int) {
        // Scratch on the stack: per-lane SIMD subscripting is slow in Swift.
        let (hist, qmin, qmax) = withUnsafeTemporaryAllocation(of: Float.self, capacity: 16) { h in
            h.initialize(repeating: 0)
            for byte in 0..<(groupSize / 2) {
                let value = group[byte]
                h[Int(value & 0x0F)] += 1
                h[Int(value >> 4)] += 1
            }
            var qmin = 0
            while h[qmin] == 0 { qmin += 1 }
            var qmax = 15
            while h[qmax] == 0 { qmax -= 1 }
            return (UnsafeRawPointer(h.baseAddress!).loadUnaligned(as: SIMD16<Float>.self), qmin, qmax)
        }
        let q = SIMD16<Float>(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
        let top = Float(levels - 1)

        func fit(_ alpha: Float, _ beta: Float) -> (codes: SIMD16<Float>, err: Float) {
            // Adding and subtracting 1.5·2²³ rounds to nearest even in plain
            // vector arithmetic; SIMD `rounded` and `clamped` go lane by lane.
            let magic = SIMD16<Float>(repeating: 12_582_912)
            var c = ((q - beta) * (1 / alpha) + magic) - magic
            c = pointwiseMin(pointwiseMax(c, SIMD16(repeating: 0)), SIMD16(repeating: top))
            let e = q - (c * alpha + beta)
            return (c, (hist * e * e).sum())
        }

        var best = (alpha: Float(1), beta: Float(qmin), codes: SIMD16<Float>(), err: Float.infinity)
        for lo in qmin...max(qmin, min(qmin + 2, qmax - 1)) {
            for hi in max(lo, qmax - 2)...qmax {
                let span = Float(hi - lo)
                let alpha = span <= top ? 1 : span / top
                let (c, err) = fit(alpha, Float(lo))
                if err < best.err { best = (alpha, Float(lo), c, err) }
            }
        }
        // Weighted least squares for α, β given the chosen codes.
        let c = best.codes
        let n = hist.sum(), sc = (hist * c).sum(), sq = (hist * q).sum()
        let scc = (hist * c * c).sum(), scq = (hist * c * q).sum()
        let det = n * scc - sc * sc
        if det > 0 {
            let alpha = (n * scq - sc * sq) / det
            let beta = (sq * scc - sc * scq) / det
            if alpha > 0 {
                let (c2, err) = fit(alpha, beta)
                if err < best.err { best = (alpha, beta, c2, err) }
            }
        }
        let s = bf16ToFloat(scale)
        let b = bf16ToFloat(bias)
        scale = floatToBF16(best.alpha * s)
        bias = floatToBF16(best.beta * s + b)
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16) { lut in
            let codes = SIMD16<UInt8>(truncatingIfNeeded: SIMD16<Int32>(best.codes))
            UnsafeMutableRawPointer(lut.baseAddress!).storeBytes(of: codes, as: SIMD16<UInt8>.self)
            for byte in 0..<(groupSize / 2) {
                let value = group[byte]
                group[byte] = lut[Int(value & 0x0F)] | (lut[Int(value >> 4)] << 4)
            }
        }
    }
}

package enum LossyExpertSimulationError: Error, CustomStringConvertible {
    case badSpec(String)

    package var description: String {
        switch self {
        case .badSpec(let spec):
            return "\(LossyExpertSimulation.environmentKey): cannot parse '\(spec)'"
        }
    }
}
