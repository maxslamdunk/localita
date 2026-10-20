import Foundation
import TurboFieldfare

public enum AppExpertCachePolicy: String, CaseIterable, Sendable, Identifiable {
    case lfu
    case lru

    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() }
}

public enum AppRDAdvicePolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    case `default`
    case bounded
    case adaptive

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    var runtimeValue: RDAdvicePolicyMode {
        switch self {
        case .off: return .off
        case .default: return .default
        case .bounded: return .bounded
        case .adaptive: return .adaptive
        }
    }
}

public enum AppModelVerification: String, CaseIterable, Sendable, Identifiable {
    case fullSha256 = "full-sha256"
    case trustedInstall = "trusted-install"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fullSha256: return "Full SHA-256"
        case .trustedInstall: return "Trust verified install"
        }
    }

    var runtimeValue: ModelIntegrityPolicy {
        switch self {
        case .fullSha256: return .fullSha256
        case .trustedInstall: return .sizeCheckTrustedReceipt
        }
    }
}

public struct AppRuntimeOptions: Equatable, Sendable {
    public static let allowedSlotCounts = RuntimeConfiguration.allowedExpertCacheSlots
    public static let allowedPrefillChunkTokens = RuntimeConfiguration.allowedPrefillChunkTokens
    /// Early expert reads per layer the app offers: off, one (the default) or
    /// two. Two measured slower on the iPhone 17 and faster on the M1; it is
    /// offered for other devices, whose storage may serve reads differently.
    public static let allowedEarlyExpertReads = [0, 1, 2]

    public var expertCacheSlots: Int
    public var expertCachePolicy: AppExpertCachePolicy
    public var prefillEnabled: Bool
    public var prefillChunkTokens: Int
    public var rdadvisePolicy: AppRDAdvicePolicy
    public var modelVerification: AppModelVerification
    public var visionResidencyPolicy: VisionResidencyPolicy
    /// 0 turns the early expert read off; 1 or 2 is how many of the next
    /// layer's experts it reads (`RuntimeConfiguration.earlyExpertReadsPerLayer`).
    public var earlyExpertReads: Int
    /// `F_NOCACHE` on routed-expert reads (`RuntimeConfiguration.expertReadsBypassFileCache`).
    public var expertReadsBypassFileCache: Bool

    /// `expertCacheSlots` defaults to the platform's production constant rather
    /// than a literal, so a caller that does not name it gets 16 on macOS and
    /// 32 on iOS. `prefillChunkTokens` deliberately does not: the measured-best
    /// iOS policy is `auto`, which depends on the prompt length and so cannot
    /// be a constant, and `IOS_PORT.md` requires the shared default stay 128 on
    /// every platform. A platform that wants otherwise sets it per request —
    /// prefill is outside `AppLoadedRuntimeKey`, so changing it never makes a
    /// loaded session stale.
    public init(expertCacheSlots: Int = RuntimeConfiguration.productionExpertCacheSlots,
                expertCachePolicy: AppExpertCachePolicy = .lfu,
                prefillEnabled: Bool = true,
                prefillChunkTokens: Int = 128,
                rdadvisePolicy: AppRDAdvicePolicy = .off,
                modelVerification: AppModelVerification = .fullSha256,
                visionResidencyPolicy: VisionResidencyPolicy = .onDemand,
                earlyExpertReads: Int = 1,
                expertReadsBypassFileCache: Bool = PreadExpertStreamer.readsBypassFileCacheByDefault) {
        self.expertCacheSlots = expertCacheSlots
        self.expertCachePolicy = expertCachePolicy
        self.prefillEnabled = prefillEnabled
        self.prefillChunkTokens = prefillChunkTokens
        self.rdadvisePolicy = rdadvisePolicy
        self.modelVerification = modelVerification
        self.visionResidencyPolicy = visionResidencyPolicy
        self.earlyExpertReads = earlyExpertReads
        self.expertReadsBypassFileCache = expertReadsBypassFileCache
    }

    public func validate() throws {
        guard Self.allowedSlotCounts.contains(expertCacheSlots) else {
            throw AppInferenceError.invalidRequest(
                "expert cache slots must be one of \(Self.allowedSlotCounts)")
        }
        guard Self.allowedPrefillChunkTokens.contains(prefillChunkTokens) else {
            throw AppInferenceError.invalidRequest(
                "prefill chunk size must be one of \(Self.allowedPrefillChunkTokens)")
        }
        guard Self.allowedEarlyExpertReads.contains(earlyExpertReads) else {
            throw AppInferenceError.invalidRequest(
                "early expert reads must be one of \(Self.allowedEarlyExpertReads)")
        }
        // Refused here rather than inside the first prefill chunk, which is
        // after the model load and, on an image turn, after every attachment
        // has already been encoded on the GPU.
        let minimumSlots = RuntimeConfiguration.minimumExpertCacheSlotsForChunkedPrefill
        guard !prefillEnabled || expertCacheSlots >= minimumSlots else {
            throw AppInferenceError.invalidRequest(
                "Prefill needs at least \(minimumSlots) expert cache slots, and Slots is set to "
                    + "\(expertCacheSlots). Raise Slots to \(minimumSlots) or turn Prefill off.")
        }
    }

    public var prefillConfig: PrefillRuntimeConfig {
        prefillEnabled ? .production(chunkTokens: prefillChunkTokens) : .off
    }

    public var resultSummary: String {
        let prefill = prefillEnabled ? "prefill \(prefillChunkTokens)" : "prefill off"
        let verification = modelVerification == .fullSha256 ? "full SHA-256" : "trusted receipt"
        return "Cache \(expertCacheSlots) \(expertCachePolicy.label), \(prefill), FP16 KV, RDADVISE \(rdadvisePolicy.label.lowercased()), \(verification)"
    }

    public static func slotsLabel(for slots: Int) -> String {
        switch slots {
        case 8: "8, -0.8 GB"
        case 16: "16, Default"
        case 24: "24, +0.8 GB"
        case 32: "32, +1.61 GB"
        default: "\(slots)"
        }
    }

    public func resolvedRuntimeConfiguration(forceLogitsHead: Bool) throws -> RuntimeConfiguration {
        try validate()
        return RuntimeConfiguration(
            expertCacheSlots: expertCacheSlots,
            expertCachePolicy: expertCachePolicy == .lru ? .lru : .lfu,
            rdadvisePolicy: rdadvisePolicy.runtimeValue,
            prefillEnabled: prefillEnabled,
            prefillChunkTokens: prefillChunkTokens,
            forceLogitsHead: forceLogitsHead,
            earlyExpertRead: earlyExpertReads > 0,
            earlyExpertReadsPerLayer: max(earlyExpertReads, 1),
            expertReadsBypassFileCache: expertReadsBypassFileCache)
    }
}

public struct AppLoadedRuntimeKey: Equatable, Sendable {
    public var modelDirectory: URL
    public var maxContextTokens: Int
    public var expertCacheSlots: Int
    public var expertCachePolicy: AppExpertCachePolicy
    public var rdadvisePolicy: AppRDAdvicePolicy
    public var modelVerification: AppModelVerification
    public var visionResidencyPolicy: VisionResidencyPolicy
    public var earlyExpertReads: Int
    public var expertReadsBypassFileCache: Bool
    public var forceLogitsHead: Bool

    public init(modelDirectory: URL,
                maxContextTokens: Int,
                options: AppRuntimeOptions,
                forceLogitsHead: Bool = false) {
        self.modelDirectory = modelDirectory.standardizedFileURL
        self.maxContextTokens = maxContextTokens
        self.expertCacheSlots = options.expertCacheSlots
        self.expertCachePolicy = options.expertCachePolicy
        self.rdadvisePolicy = options.rdadvisePolicy
        self.modelVerification = options.modelVerification
        self.visionResidencyPolicy = options.visionResidencyPolicy
        self.earlyExpertReads = options.earlyExpertReads
        self.expertReadsBypassFileCache = options.expertReadsBypassFileCache
        self.forceLogitsHead = forceLogitsHead
    }

    /// The options this session was actually loaded with. A run has to be built
    /// from these rather than from the current settings, or a pending change the
    /// user has not reloaded for is refused by the loaded session.
    ///
    /// Prefill is passed in because it is deliberately not part of this key:
    /// it is chosen per request and changing it must not make a loaded
    /// session stale.
    public func options(prefillEnabled: Bool,
                        prefillChunkTokens: Int) -> AppRuntimeOptions {
        AppRuntimeOptions(
            expertCacheSlots: expertCacheSlots,
            expertCachePolicy: expertCachePolicy,
            prefillEnabled: prefillEnabled,
            prefillChunkTokens: prefillChunkTokens,
            rdadvisePolicy: rdadvisePolicy,
            modelVerification: modelVerification,
            visionResidencyPolicy: visionResidencyPolicy,
            earlyExpertReads: earlyExpertReads,
            expertReadsBypassFileCache: expertReadsBypassFileCache)
    }
}
