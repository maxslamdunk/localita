import Foundation

/// Research-only trace of decode routing, written when the environment
/// variable `TURBO_FIELDFARE_ROUTING_TRACE` names a directory. Off otherwise,
/// and the runner does no extra work when it is off.
///
/// It exists to score next-layer expert prediction offline. The directory
/// gets `meta.json`, one dense router matrix per layer (`router_LNN.f32`,
/// row-major `[numExperts][hiddenSize]` Float32, already multiplied by the
/// effective scale, so scores = matrix · router input), and `trace.bin`:
/// one fixed-size record per decode token per layer, in the order produced.
///
/// Record layout, little-endian (`recordBytes` in `meta.json`):
/// - Int32 position, Int32 layer, Int32 miss count (−1 when no cache plan)
/// - Int32 × topK expert IDs, in router order
/// - Int32 × topK missed expert IDs, padded with −1
/// - Float32 × numExperts router scores
/// - Float16 × hiddenSize router input (normalized state after attention)
/// - Float16 × hiddenSize layer output (the next layer's input)
///
/// Capturing the layer output means waiting for the layer's routed command
/// buffer, which changes timing but no numbers. Timings from a traced run are
/// not benchmark figures.
final class RoutingTraceWriter {
    static let environmentKey = "TURBO_FIELDFARE_ROUTING_TRACE"

    let hiddenSize: Int
    let numExperts: Int
    let topK: Int
    private let directory: URL
    private let trace: FileHandle

    var recordBytes: Int {
        4 * (3 + 2 * topK) + 4 * numExperts + 2 * 2 * hiddenSize
    }

    init?(environment: [String: String] = ProcessInfo.processInfo.environment,
          config: ArchConfig) throws {
        guard let path = environment[Self.environmentKey], !path.isEmpty else {
            return nil
        }
        hiddenSize = config.hiddenSize
        numExperts = config.numExperts
        topK = config.topKExperts
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let traceURL = directory.appendingPathComponent("trace.bin")
        FileManager.default.createFile(atPath: traceURL.path, contents: nil)
        trace = try FileHandle(forWritingTo: traceURL)
        let meta: [String: Int] = [
            "hiddenSize": hiddenSize, "numExperts": numExperts, "topK": topK,
            "numLayers": config.numLayers, "recordBytes": recordBytes,
        ]
        try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("meta.json"))
    }

    deinit {
        try? trace.close()
    }

    func writeRouterMatrix(layer: Int, _ values: [Float]) throws {
        precondition(values.count == numExperts * hiddenSize)
        let name = String(format: "router_L%02d.f32", layer)
        try values.withUnsafeBytes { Data($0) }
            .write(to: directory.appendingPathComponent(name))
    }

    func append(position: Int,
                layer: Int,
                experts: [Int],
                missedExperts: [Int]?,
                scores: UnsafePointer<Float>,
                routerInput: UnsafeRawPointer,
                layerOutput: UnsafeRawPointer) throws {
        precondition(experts.count == topK)
        var record = Data(capacity: recordBytes)
        func put(_ value: Int32) {
            withUnsafeBytes(of: value.littleEndian) { record.append(contentsOf: $0) }
        }
        put(Int32(position))
        put(Int32(layer))
        put(Int32(missedExperts?.count ?? -1))
        for e in experts { put(Int32(e)) }
        let misses = missedExperts ?? []
        for i in 0..<topK { put(i < misses.count ? Int32(misses[i]) : -1) }
        record.append(UnsafeBufferPointer(start: scores, count: numExperts))
        record.append(routerInput.assumingMemoryBound(to: UInt8.self),
                      count: 2 * hiddenSize)
        record.append(layerOutput.assumingMemoryBound(to: UInt8.self),
                      count: 2 * hiddenSize)
        precondition(record.count == recordBytes)
        try trace.write(contentsOf: record)
    }
}
