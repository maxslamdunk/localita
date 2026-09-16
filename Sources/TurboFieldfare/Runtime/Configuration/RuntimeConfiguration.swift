public enum RuntimeHeadPath: String, Codable, Sendable {
    case fusedRows = "fused-rows"
    case logits
}

public enum RuntimePrefillPolicy: String, Codable, Sendable {
    case off
    case chunked
}

public enum RuntimePrefillAttentionPath: String, Codable, Sendable {
    case causalTiled = "causal-tiled"
    case fullTensorOps2DPreferred = "full-tensorops-2d-preferred"
    case fullTensorOps2DValidityV2 = "full-tensorops-2d-validity-v2"
}

public enum RuntimeExpertCachePolicy: String, Codable, Sendable {
    case lfu
    case lru
}

public struct RuntimeConfiguration: Sendable, Equatable {
    public static let allowedExpertCacheSlots = [8, 16, 24, 32]
    public static let allowedPrefillChunkTokens = PrefillRuntimeConfig.allowedChunkTokens
    public static let minimumExpertCacheSlotsForChunkedPrefill = 16

    /// The production slot count, which differs by platform because what it
    /// costs differs by platform. Slots are **per layer**: 30 × `slotCount`
    /// buffers of 3,358,720 B, so 16 → 32 is **+1.61 GB**, not +54 MB.
    ///
    /// **16 on macOS.** CACHE-03 measured 32 as actively harmful on the 8 GB
    /// validation host, where the cache thrashed and decode collapsed to
    /// 1.578 tok/s with `io` at 318.3 ms/token.
    ///
    /// **32 on iOS.** The iPhone 17 supplies the memory condition CACHE-03
    /// deferred the experiment on: peak `phys_footprint` 3.77 GB against a
    /// measured 5.60 GB jetsam ceiling. Measured 2026-09-16 at **+59 / +56 /
    /// +34%** over 16 slots, hit rate 67.7/64.9/62.3% → 86.5/83.0/80.6%, and
    /// bytes/token −58.3 / −51.7 / −48.7%. The Mac's thrashing failure does not
    /// reproduce there: `io` falls monotonically as slots rise.
    ///
    /// This is memory-funded speed, not a free win — report it as such.
    ///
    /// Prefill chunk size deliberately gets **no** equivalent constant. The
    /// measured-best iOS policy is `auto`, which picks the smallest allowed
    /// size covering the prompt and so cannot be expressed as a fixed default;
    /// it is resolved where the prompt length is known, as `Run.swift` does for
    /// the CLI.
    public static let productionExpertCacheSlots: Int = {
        #if os(iOS)
        return 32
        #else
        return 16
        #endif
    }()
    /// The one rendering shared by every help text and every rejection that
    /// names one of the arrays above, so neither can name a value the guard
    /// does not accept: the hardcoded "32, 64, or 128" outlived the widening of
    /// the allowed set and told users 256 was illegal while the guard accepted
    /// it. It lives here, beside the arrays, because the CLI's usage and the
    /// server's usage and rejections all render the same sets.
    ///
    /// `alsoAccepting` appends parse-level aliases after the integers, so
    /// `--prefill-chunk-tokens` renders "32, 64, 128, 256, or auto". They come
    /// last because they are not members of the array the guards test, and
    /// because the help line's integers are read back by
    /// `usageNamesExactlyTheAllowedValues`.
    public static func allowedValueList(_ values: [Int],
                                        alsoAccepting aliases: [String] = []) -> String {
        let words = values.map(String.init) + aliases
        switch words.count {
        case 0: return ""
        case 1: return words[0]
        case 2: return "\(words[0]) or \(words[1])"
        default:
            return words.dropLast().joined(separator: ", ") + ", or " + words[words.count - 1]
        }
    }

    public let expertCacheSlots: Int
    public let expertCachePolicy: RuntimeExpertCachePolicy
    public let rdadvisePolicy: RDAdvicePolicyMode
    public let prefillPolicy: RuntimePrefillPolicy
    public let prefillChunkTokens: Int
    public let prefillAttentionPath: RuntimePrefillAttentionPath
    public let headPath: RuntimeHeadPath

    public init(expertCacheSlots: Int = RuntimeConfiguration.productionExpertCacheSlots,
                expertCachePolicy: RuntimeExpertCachePolicy = .lfu,
                rdadvisePolicy: RDAdvicePolicyMode = .off,
                prefillEnabled: Bool = true,
                prefillChunkTokens: Int = 128,
                prefillAttentionPath: RuntimePrefillAttentionPath = .fullTensorOps2DPreferred,
                forceLogitsHead: Bool = false) {
        precondition(Self.allowedExpertCacheSlots.contains(expertCacheSlots),
                     "unsupported expert-cache slot count")
        precondition(Self.allowedPrefillChunkTokens.contains(prefillChunkTokens),
                     "unsupported prefill chunk size")
        self.expertCacheSlots = expertCacheSlots
        self.expertCachePolicy = expertCachePolicy
        self.rdadvisePolicy = rdadvisePolicy
        self.prefillPolicy = prefillEnabled ? .chunked : .off
        self.prefillChunkTokens = prefillChunkTokens
        self.prefillAttentionPath = prefillAttentionPath
        self.headPath = forceLogitsHead ? .logits : .fusedRows
    }

    public static var production: RuntimeConfiguration {
        RuntimeConfiguration()
    }

    public var fp16RingEnabled: Bool { true }
    public var rdadviseEnabled: Bool { rdadvisePolicy != .off }
    public var prefillConfig: PrefillRuntimeConfig {
        switch prefillPolicy {
        case .off:
            return .off
        case .chunked:
            return .production(chunkTokens: prefillChunkTokens)
        }
    }
    public var modelExpertCachePolicy: ExpertCachePolicy {
        expertCachePolicy == .lru ? .lru : .lfu
    }
}
