// gpubench: run gpudecode.metal on gpucodec's dump, check it bit for bit
// against the original experts, and time it.
//
//   swiftc -O -o gpubench gpubench.swift
//   gpubench <dump dir> <gpudecode.metal>
import Foundation
import Metal

let stride: UInt32 = 3_358_720
let used = 3_345_408
let threadsPerExpert = 24 * 32

let args = CommandLine.arguments
let dir = URL(fileURLWithPath: args[1])
let source = try String(contentsOfFile: args[2], encoding: .utf8)
let device = MTLCreateSystemDefaultDevice()!
let options = MTLCompileOptions()
options.mathMode = .safe
let library = try device.makeLibrary(source: source, options: options)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "decode")!)
let queue = device.makeCommandQueue()!

func load(_ name: String) throws -> Data { try Data(contentsOf: dir.appendingPathComponent(name)) }
func buffer(_ d: Data) -> MTLBuffer {
  d.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: d.count, options: .storageModeShared)! }
}
let enc = buffer(try load("enc.bin"))
let indexData = try load("enc_index.bin")
let index = buffer(indexData)
let tables = buffer(try load("tables.bin"))
let orig = try load("orig.bin")
let n = indexData.count / 4 - 1
let out = device.makeBuffer(length: n * Int(stride), options: .storageModeShared)!

func run(first: Int, count: Int) -> (gpu: Double, wall: Double) {
  let cb = queue.makeCommandBuffer()!
  let ce = cb.makeComputeCommandEncoder()!
  ce.setComputePipelineState(pipeline)
  ce.setBuffer(enc, offset: 0, index: 0)
  ce.setBuffer(index, offset: 0, index: 1)
  ce.setBuffer(tables, offset: 0, index: 2)
  ce.setBuffer(out, offset: 0, index: 3)
  var s = stride, f = UInt32(first)
  ce.setBytes(&s, length: 4, index: 4)
  ce.setBytes(&f, length: 4, index: 5)
  let tg = min(64, pipeline.maxTotalThreadsPerThreadgroup)
  ce.dispatchThreads(MTLSize(width: count * threadsPerExpert, height: 1, depth: 1),
                     threadsPerThreadgroup: MTLSize(width: tg, height: 1, depth: 1))
  ce.endEncoding()
  let t0 = DispatchTime.now().uptimeNanoseconds
  cb.commit()
  cb.waitUntilCompleted()
  let wall = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
  return (cb.gpuEndTime - cb.gpuStartTime, wall)
}

// correctness: all experts at once
_ = run(first: 0, count: n)
var bad = 0
orig.withUnsafeBytes { o in
  for e in 0..<n where memcmp(out.contents() + e * Int(stride), o.baseAddress! + e * Int(stride), used) != 0 { bad += 1 }
}
print("GPU decode of \(n) experts: \(bad == 0 ? "bit-exact" : "FAILED (\(bad) differ)") against the installed bytes")

func stats(_ xs: [Double]) -> String {
  let v = xs.sorted()
  return String(format: "min %.0f us, median %.0f us", v[0] * 1e6, v[v.count / 2] * 1e6)
}
for count in [1, 3, n] {
  var gpu: [Double] = [], wall: [Double] = []
  for i in 0..<30 {
    let r = run(first: count == n ? 0 : (i * count) % (n - count + 1), count: count)
    gpu.append(r.gpu); wall.append(r.wall)
  }
  let best = gpu.min()!
  print(String(format: "%2d expert(s): GPU time %@; commit-to-complete %@; %.2f GB/s of output at the best GPU time",
               count, stats(gpu), stats(wall), Double(count * used) / best / 1e9))
}
