import Metal

/// When a text prompt runs layer at a time across its chunks.
///
/// Chunk by chunk, every chunk streams nearly all of a layer's routed experts
/// again: a 1024-token chunk routes 8,192 pairs over 128 experts, and 24 slots
/// keep few of them. Layer at a time, each layer's attention still runs chunk
/// by chunk, because a chunk's attention needs only the earlier chunks' keys
/// and values at that layer, but its routed experts run once over the whole
/// prompt, so each expert is read once per layer. Every kernel involved works
/// per row or per pair, so the output does not change.
///
/// Only a prompt that starts an empty KV qualifies. Nothing commits until the
/// last layer, and by then the SWA rings have wrapped further than a failed
/// turn can rewind past; at position 0 a failed turn restarts from a reset,
/// which needs no rewind. The token cap bounds the prompt-wide buffers.
enum PrefillLayerMajorPolicy {
    /// "0" keeps every prompt chunk by chunk.
    static let environmentKey = "TURBO_FIELDFARE_PREFILL_LAYER_MAJOR"
    /// About 62 KB of prompt-wide rows per token: 254 MB at the cap.
    static let maxTokens = 4096

    static func applies(enabled: Bool, spanCount: Int, startPosition: Int, tokenCount: Int) -> Bool {
        enabled && spanCount > 1 && startPosition == 0 && tokenCount <= maxTokens
    }
}

/// The whole prompt's rows a layer-at-a-time prefill keeps between a layer's
/// attention, run chunk by chunk, and its routed experts, run once over the
/// prompt. Allocated for one prefill and released after it.
struct PrefillLayerMajorBuffers {
    let tokenCount: Int
    /// The residual stream, carried from layer to layer.
    let hidden: MTLBuffer
    /// The shared expert's output for the layer tail.
    let h1: MTLBuffer
    /// The routed experts' input, then the reduced routed output (`h2`): the
    /// reduce runs only after every routed tile has finished reading it.
    let routedX: MTLBuffer
    let routePartials: MTLBuffer
    let routeIDs: MTLBuffer
    let routeWeights: MTLBuffer

    static func bytes(tokenCount: Int, hiddenSize: Int, topK: Int) -> Int {
        let half = MemoryLayout<Float16>.stride
        return 3 * tokenCount * hiddenSize * half
            + tokenCount * topK * hiddenSize * half
            + tokenCount * topK * (MemoryLayout<UInt32>.stride + half)
    }

    init(device: MTLDevice, tokenCount: Int, hiddenSize: Int, topK: Int) throws {
        func buffer(_ bytes: Int, _ options: MTLResourceOptions, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(bytes, 1), options: options) else {
                throw ModelError.residentBufferWrapFailed
            }
            buffer.label = label
            return buffer
        }
        let half = MemoryLayout<Float16>.stride
        let rowBytes = tokenCount * hiddenSize * half
        self.tokenCount = tokenCount
        hidden = try buffer(rowBytes, .storageModePrivate, "prefill.layerMajor.hidden")
        h1 = try buffer(rowBytes, .storageModePrivate, "prefill.layerMajor.h1")
        routedX = try buffer(rowBytes, .storageModePrivate, "prefill.layerMajor.routedX")
        routePartials = try buffer(rowBytes * topK, .storageModePrivate, "prefill.layerMajor.routePartials")
        routeIDs = try buffer(tokenCount * topK * MemoryLayout<UInt32>.stride, .storageModeShared,
                              "prefill.layerMajor.routeIDs")
        routeWeights = try buffer(tokenCount * topK * half, .storageModeShared,
                                  "prefill.layerMajor.routeWeights")
    }
}
