// Times LossyExpertSimulation.apply on one installed expert (layer 0,
// expert 0) and measures the error it adds, in units of the error variance of
// one INT4 rounding (s²/12 per weight).
//
//   swiftc -O -package-name bench -o bench \
//     ../../Sources/TurboFieldfare/Infrastructure/Streaming/LossyExpertSimulation.swift main.swift
//   ./bench <path to packed_experts/layer_00.bin>
import Foundation

let path = CommandLine.arguments[1]
let stride = 3_358_720
let fd = open(path, O_RDONLY)
var raw: UnsafeMutableRawPointer?
posix_memalign(&raw, 1 << 21, stride)
let base = raw!
let original = UnsafeMutableRawPointer.allocate(byteCount: stride, alignment: 64)
_ = pread(fd, original, stride, 0)
let tensors = [
    LossyExpertSimulation.Tensor(codesOffset: 0, scalesOffset: 991_232, biasesOffset: 1_053_184,
                                 rows: 704, cols: 2816),
    LossyExpertSimulation.Tensor(codesOffset: 1_115_136, scalesOffset: 2_106_368,
                                 biasesOffset: 2_168_320, rows: 704, cols: 2816),
    LossyExpertSimulation.Tensor(codesOffset: 2_230_272, scalesOffset: 3_221_504,
                                 biasesOffset: 3_283_456, rows: 2816, cols: 704),
]
let specs = CommandLine.arguments.count > 2
    ? Array(CommandLine.arguments[2...]) : ["all=3", "all=2", "noise=0.0833333"]
for spec in specs {
    let sim = try! LossyExpertSimulation(
        environment: [LossyExpertSimulation.environmentKey: spec], tensors: tensors)!
    var best = Double.infinity
    for _ in 0..<5 {
        memcpy(base, original, stride)
        let t0 = Date()
        sim.apply(to: base, layer: 0, expert: 0)
        best = min(best, Date().timeIntervalSince(t0))
    }
    var names = ["gate", "up", "down"]
    for (index, t) in tensors.enumerated() {
        var se = 0.0, ref = 0.0
        let groups = t.cols / 64
        for row in 0..<t.rows {
            for g in 0..<groups {
                let si = row * groups + g
                func f(_ p: UnsafeMutableRawPointer, _ off: Int) -> Float {
                    LossyExpertSimulation.bf16ToFloat(p.load(fromByteOffset: off + 2 * si, as: UInt16.self))
                }
                let s0 = f(original, t.scalesOffset), b0 = f(original, t.biasesOffset)
                let s1 = f(base, t.scalesOffset), b1 = f(base, t.biasesOffset)
                for k in 0..<32 {
                    let at = t.codesOffset + row * t.cols / 2 + g * 32 + k
                    let o = original.load(fromByteOffset: at, as: UInt8.self)
                    let n = base.load(fromByteOffset: at, as: UInt8.self)
                    for h in 0..<2 {
                        let qo = Float((o >> (4 * h)) & 15), qn = Float((n >> (4 * h)) & 15)
                        let d = Double((qo * s0 + b0) - (qn * s1 + b1))
                        se += d * d
                    }
                    ref += 2 * Double(s0 * s0) / 12
                }
            }
        }
        names[index] += String(format: " %.2f", se / ref)
    }
    print(String(format: "%@: %.1f ms per expert; added error / one INT4 rounding: %@",
                 spec, best * 1000, names.joined(separator: ", ")))
}
