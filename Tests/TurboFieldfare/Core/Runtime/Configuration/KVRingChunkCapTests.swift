import Testing
@testable import TurboFieldfare

/// What `PrefillRuntimeConfig.maxChunkTokens` costs in KV ring bytes.
///
/// This suite is the precondition that constant's own comment asked for:
/// "raising this past 280 should come with a test that asserts ring bytes the
/// way `PrefillChunkScratchTests` asserts scratch." The cost is easy to miss
/// because it is **unconditional** — `RealForwardRunner` sizes `KVCacheManager`
/// from the static cap, not from the chunk a run actually selects, so every
/// run on the platform pays it including decode-only ones and ones that never
/// ask for a chunk larger than 128.
///
/// Arithmetic rather than allocation: the sizing is a pure function of the arch
/// config and the cap, so asserting it needs no Metal device and no model, and
/// runs on any host.
///
/// Filed under `Configuration/` rather than beside the prefill tests because the
/// iOS test bundle compiles `Runtime/Configuration` and not `Runtime/Prefill`.
/// The cap is platform-split, so a suite the phone never compiles would assert
/// the macOS value twice and the iOS value never — the same trap
/// `RuntimeConfigurationTests` fell into, and the reason that suite is in this
/// directory too.
@Suite struct KVRingChunkCapTests {
    private let cfg = ArchConfig.gemma4_26B_A4B

    /// `KVCacheManager` gives a sliding-window layer a ring of
    /// `min(maxContext, slidingWindow + maxPrefillChunkTokens)` tokens, and a
    /// full-attention layer the whole context regardless. Only the first kind
    /// scales with the cap, so only it appears here.
    private func ringBytes(cap: Int, maxContext: Int) -> Int {
        let swaStride = cfg.numKVHeads * cfg.headDim * 2
        let capacity = min(maxContext, cfg.slidingWindow + max(cap, pooledTokenFloor))
        let swaLayers = cfg.fullAttentionLayerMask.filter { $0 == 0 }.count
        // K and V are separate buffers of the same length.
        return swaLayers * capacity * swaStride * 2
    }

    /// The runner floors the chunk at the pooled-image span, so no cap below
    /// this changes the geometry at all.
    private let pooledTokenFloor = 280

    @Test func theArchShapeTheseFiguresRestOnIsWhatWeThinkItIs() {
        #expect(cfg.numLayers == 30)
        #expect(cfg.slidingWindow == 1024)
        #expect(cfg.numKVHeads * cfg.headDim * 2 == 4096)
        // 5 full-attention layers at indices 5, 11, 17, 23, 29; the other 25
        // slide, and only those 25 have a ring whose size the cap moves.
        #expect(cfg.fullAttentionLayerMask.filter { $0 == 1 }.count == 5)
        #expect(cfg.fullAttentionLayerMask.filter { $0 == 0 }.count == 25)
    }

    /// Every cap up to the 280-token pooled image span is free, which is the
    /// claim that let 256 in without a measurement.
    @Test func capsUpToThePooledFloorCostNothing() {
        let floor = ringBytes(cap: pooledTokenFloor, maxContext: 4096)
        for cap in [32, 64, 128, 256, 280] {
            #expect(ringBytes(cap: cap, maxContext: 4096) == floor)
        }
    }

    /// The numbers quoted in `maxChunkTokens`' comment, pinned so that comment
    /// cannot drift away from the code silently.
    @Test func theQuotedRingCostsAreWhatTheCapActuallyBuys() {
        let base = ringBytes(cap: pooledTokenFloor, maxContext: 4096)
        #expect(base == 25 * 1304 * 4096 * 2)

        #expect(ringBytes(cap: 512, maxContext: 4096) - base == 47_513_600)
        #expect(ringBytes(cap: 1024, maxContext: 4096) - base == 152_371_200)
    }

    /// A short context clamps the ring before the cap can grow it, so a device
    /// configured small does not pay for a ceiling it cannot reach.
    @Test func aContextShorterThanTheRingClampsItFirst() {
        // At or below the smallest ring the cap can produce (slidingWindow +
        // the 280-token pooled floor = 1304), the context is the only term and
        // the cap cannot be seen at all.
        #expect(ringBytes(cap: 1024, maxContext: 1024)
                == ringBytes(cap: 256, maxContext: 1024))

        // Between the two the clamp binds for the larger cap only, so the cost
        // is the context's rather than the cap's: 1536 instead of 2048 tokens.
        #expect(ringBytes(cap: 1024, maxContext: 1536) == 25 * 1536 * 4096 * 2)
        #expect(ringBytes(cap: 256, maxContext: 1536) == 25 * 1304 * 4096 * 2)

        // And the full +152.4 MB only appears once the context can hold it.
        #expect(ringBytes(cap: 1024, maxContext: 2048)
                == ringBytes(cap: 1024, maxContext: 4096))
    }

    /// The cap the platform actually ships, asserted per platform. Split
    /// because `swift test` runs only on macOS: a single assertion here would
    /// keep passing on the Mac while the iOS value went entirely unchecked,
    /// which is exactly the trap `RuntimeConfigurationTests` fell into when the
    /// expert-cache slot default was platform-split.
    @Test func theShippedCapMatchesThePlatformItShipsOn() {
        #if os(iOS)
        #expect(PrefillRuntimeConfig.maxChunkTokens == 1024)
        #expect(PrefillRuntimeConfig.allowedChunkTokens == [32, 64, 128, 256, 512, 1024])
        // The phone spends 152.4 MB of ring on this and has the headroom for
        // it: a measured 3.81 GB peak against a 5.60 GB jetsam floor.
        #expect(ringBytes(cap: PrefillRuntimeConfig.maxChunkTokens, maxContext: 4096)
                - ringBytes(cap: pooledTokenFloor, maxContext: 4096) == 152_371_200)
        #else
        #expect(PrefillRuntimeConfig.maxChunkTokens == 256)
        #expect(PrefillRuntimeConfig.allowedChunkTokens == [32, 64, 128, 256])
        // The 8 GB validation host pays nothing, which is the point of the split.
        #expect(ringBytes(cap: PrefillRuntimeConfig.maxChunkTokens, maxContext: 4096)
                == ringBytes(cap: pooledTokenFloor, maxContext: 4096))
        #endif
    }

    /// `allowedChunkTokens` and `maxChunkTokens` are two doors onto the same
    /// policy and have disagreed before - see `supportedChunkTokens`.
    @Test func theAllowedListAndTheCapAgree() {
        #expect(PrefillRuntimeConfig.allowedChunkTokens.last == PrefillRuntimeConfig.maxChunkTokens)
        #expect(PrefillRuntimeConfig.allowedChunkTokens.allSatisfy {
            $0 <= PrefillRuntimeConfig.maxChunkTokens
        })
        #expect(PrefillRuntimeConfig.allowedChunkTokens.sorted()
                == PrefillRuntimeConfig.allowedChunkTokens)
    }
}
