import CryptoKit
import Foundation

/// What lets a checkpoint off the pinned list install: its text model is
/// Gemma 4 26B-A4B laid out exactly as the reference's.
///
/// The repacker copies quantized bytes as they are and never requantizes, and
/// the runtime has only ever run the reference's layout: affine 4-bit,
/// group-64 weights with 8-bit routers. So a community checkpoint is accepted
/// when its architecture, and every text tensor's name, dtype, shape and bit
/// width, match the reference's. Only the values may differ. SuperGemma 4 is
/// such a checkpoint, and so are most "heretic" and "abliterated" re-tunes.
///
/// Vision and audio tensors are left out, because the text model never reads
/// them: the reference has a vision tower and SuperGemma 4 has none, yet both
/// have the same text layout.
public enum ReferenceLayout {
    /// The layout fingerprint of `SupportedModelSource.gemma4`'s text model,
    /// computed from its pinned revision's headers.
    public static let gemma4SHA256 =
        "89e2c4663930ecd536a73fb80cbdf9c721d19b24e6d6eb7230c3feb0583f4572"

    /// SHA-256 over a canonical listing of the architecture and the text
    /// tensors, one line per tensor, sorted by name.
    static func fingerprint(arch: ArchInfo,
                            meta: IndexLoader.SourceMetadata,
                            shardHeaders: [Safetensors.Header]) -> String {
        var lines: [String] = [
            "hidden \(arch.hiddenSize) ffn \(arch.intermediateSize) moe \(arch.moeIntermediateSize)",
            "heads \(arch.numHeads) kv \(arch.numKVHeads) full-kv \(arch.numFullKVHeads)",
            "head-dim \(arch.headDim) full-head-dim \(arch.fullHeadDim)",
            "vocab \(arch.vocabSize) window \(arch.slidingWindow)",
            "softcap \(arch.finalLogitSoftcap) rope \(arch.ropeTheta) full-rope \(arch.fullRopeTheta)",
            "partial-rotary \(arch.partialRotaryFactor)",
            "layers \(arch.numLayers) experts \(arch.numExperts) top-k \(arch.topKExperts)",
            "tie \(arch.tieWordEmbeddings) k-eq-v \(arch.attentionKEqV) act \(arch.hiddenActivation)",
            "full-layers \(arch.fullAttentionLayerMask.map(String.init).joined())",
            "quant \(meta.baseMode) group \(meta.baseGroupSize)",
        ]
        var tensors: [String] = []
        for header in shardHeaders {
            for tensor in header.tensors
            where !RepackPlanner.isMultimodalTensorName(tensor.name) {
                var line = "\(tensor.name) \(tensor.dtype) "
                    + tensor.shape.map(String.init).joined(separator: "x")
                if tensor.dtype == .u32 && tensor.name.hasSuffix(".weight") {
                    line += " \(IndexLoader.quantSpec(forTensor: tensor.name, meta: meta).bits)-bit"
                }
                tensors.append(line)
            }
        }
        lines += tensors.sorted()
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Throws `sourceLayoutRejected` unless the text model matches the
    /// reference's layout.
    static func check(arch: ArchInfo,
                      meta: IndexLoader.SourceMetadata,
                      shardHeaders: [Safetensors.Header]) throws {
        let actual = fingerprint(arch: arch, meta: meta, shardHeaders: shardHeaders)
        guard actual == gemma4SHA256 else {
            throw RepackError.sourceLayoutRejected(
                reason: "its tensors are not laid out as Gemma 4 26B-A4B's "
                    + "(layout \(actual.prefix(12)))")
        }
    }

    /// A plain reason the `config.json` alone rules a checkpoint out, or nil
    /// when it may fit. Read before any weight header is fetched, so the usual
    /// misses (another model, another size, another bit width) are named.
    /// Passing here is not enough; `check` decides.
    public static func configRejection(configData: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: configData)
            as? [String: Any] else {
            return "Its config.json could not be read."
        }
        let modelType = root["model_type"] as? String ?? ""
        guard modelType == "gemma4" else {
            return modelType.isEmpty
                ? "Its config.json names no model type."
                : "This is a \(modelType) model; only Gemma 4 26B-A4B runs here."
        }
        let text = root["text_config"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { (text[key] as? NSNumber)?.intValue }
        guard int("num_hidden_layers") == 30, int("hidden_size") == 2816 else {
            return "This is another size of Gemma 4; only 26B-A4B runs here."
        }
        if let experts = int("num_experts"), experts != 128 {
            return "This build has \(experts) experts instead of 128 (a pruned "
                + "model); only the full 26B-A4B runs here."
        }
        guard let quant = root["quantization"] as? [String: Any] else {
            return "This build is not MLX-quantized; it needs an MLX 4-bit build."
        }
        let mode = quant["mode"] as? String ?? "affine"
        guard mode == "affine" else {
            return "This build uses \(mode) quantization; it needs MLX affine 4-bit."
        }
        let bits = (quant["bits"] as? NSNumber)?.intValue
        guard bits == 4 else {
            return "This is a \(bits.map(String.init) ?? "non-4")-bit build; "
                + "it needs MLX 4-bit."
        }
        let group = (quant["group_size"] as? NSNumber)?.intValue ?? 64
        guard group == 64 else {
            return "This build uses group size \(group); it needs group size 64."
        }
        let overrides: [(key: String, bits: Int)] = quant.compactMap { key, value in
            guard let entry = value as? [String: Any] else { return nil }
            return (key, (entry["bits"] as? NSNumber)?.intValue ?? 4)
        }
        if overrides.contains(where: { $0.key.contains("experts") && $0.bits != 4 }) {
            return "Some of its experts use other bit widths (a mixed build)."
        }
        if overrides.contains(where: {
            ($0.key.contains("self_attn") || $0.key.contains("embed")) && $0.bits != 4
        }) {
            return "Its attention or embedding weights are not 4-bit."
        }
        if overrides.contains(where: { $0.key.contains(".mlp.") && $0.bits != 4 }) {
            return "Its always-on shared expert is 8-bit, a layout not run "
                + "here yet (QAT and LM Studio builds use it)."
        }
        let routers = overrides.filter { $0.key.contains("router") }
        guard routers.count == 30, routers.allSatisfy({ $0.bits == 8 }) else {
            return "Its router is not 8-bit as in Gemma 4."
        }
        return nil
    }
}
