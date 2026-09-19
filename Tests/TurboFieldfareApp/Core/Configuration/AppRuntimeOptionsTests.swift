import Foundation
import Testing
import TurboFieldfare
@testable import TurboFieldfareAppCore

@Suite struct AppRuntimeOptionsTests {
    @Test func defaultsMatchProduction() throws {
        let options = AppRuntimeOptions()
        // Literals per platform, for the reason `RuntimeConfigurationTests`
        // gives: asserting `productionExpertCacheSlots` alone would compare the
        // constant against itself. The second expectation is the one that
        // catches a literal being re-hardcoded here — which is how the iOS
        // default was overridden silently once already, by this very type.
        #if os(iOS)
        #expect(options.expertCacheSlots == 32)
        #else
        #expect(options.expertCacheSlots == 16)
        #endif
        #expect(options.expertCacheSlots == RuntimeConfiguration.productionExpertCacheSlots)
        #expect(options.expertCachePolicy == .lfu)
        #expect(options.prefillEnabled)
        // 128 on every platform, deliberately: the measured-best iOS policy is
        // `auto`, which depends on prompt length and so cannot be a constant.
        // A platform that wants otherwise sets it per request.
        #expect(options.prefillChunkTokens == 128)
        #expect(options.rdadvisePolicy == .off)
        #expect(options.modelVerification == .fullSha256)

        let runtime = try options.resolvedRuntimeConfiguration(forceLogitsHead: false)
        #expect(runtime == .production)
        #expect(options.resultSummary ==
            "Cache \(RuntimeConfiguration.productionExpertCacheSlots) LFU, prefill 128, "
                + "FP16 KV, RDADVISE off, full SHA-256")
    }

    @Test func everyPublicChoiceMapsToRuntime() throws {
        for slots in AppRuntimeOptions.allowedSlotCounts {
            let prefillEnabled =
                slots >= RuntimeConfiguration.minimumExpertCacheSlotsForChunkedPrefill
            let runtime = try AppRuntimeOptions(expertCacheSlots: slots,
                                               prefillEnabled: prefillEnabled)
                .resolvedRuntimeConfiguration(forceLogitsHead: false)
            #expect(runtime.expertCacheSlots == slots)
        }
        for chunk in AppRuntimeOptions.allowedPrefillChunkTokens {
            let runtime = try AppRuntimeOptions(prefillChunkTokens: chunk)
                .resolvedRuntimeConfiguration(forceLogitsHead: false)
            #expect(runtime.prefillConfig.chunkTokens == chunk)
        }
        for policy in AppRDAdvicePolicy.allCases {
            let runtime = try AppRuntimeOptions(rdadvisePolicy: policy)
                .resolvedRuntimeConfiguration(forceLogitsHead: false)
            #expect(runtime.rdadvisePolicy == policy.runtimeValue)
        }
    }

    @Test func runtimeAndTrustChoicesAreExplicit() throws {
        let options = AppRuntimeOptions(
            expertCacheSlots: 32,
            expertCachePolicy: .lru,
            prefillEnabled: false,
            prefillChunkTokens: 64,
            rdadvisePolicy: .adaptive,
            modelVerification: .trustedInstall)
        let runtime = try options.resolvedRuntimeConfiguration(forceLogitsHead: true)
        #expect(runtime.modelExpertCachePolicy == .lru)
        #expect(runtime.prefillConfig == .off)
        #expect(runtime.rdadvisePolicy == .adaptive)
        #expect(runtime.headPath == .logits)
        #expect(options.modelVerification.runtimeValue == .sizeCheckTrustedReceipt)
    }

    @Test func validationRejectsValuesOutsideClosedSets() {
        #expect(throws: AppInferenceError.self) {
            try AppRuntimeOptions(expertCacheSlots: 12).validate()
        }
        #expect(throws: AppInferenceError.self) {
            try AppRuntimeOptions(prefillChunkTokens: 96).validate()
        }
    }

    @Test func loadedRuntimeKeyTracksOnlyLoadTimeChoices() {
        let directory = URL(fileURLWithPath: "/tmp/model.gturbo")
        let base = AppRuntimeOptions()
        let baseline = AppLoadedRuntimeKey(
            modelDirectory: directory, maxContextTokens: 4096, options: base)

        var variants: [AppRuntimeOptions] = []
        var value = base
        value.expertCacheSlots = 24; variants.append(value)
        value = base; value.expertCachePolicy = .lru; variants.append(value)
        value = base; value.rdadvisePolicy = .bounded; variants.append(value)
        value = base; value.modelVerification = .trustedInstall; variants.append(value)

        for variant in variants {
            #expect(AppLoadedRuntimeKey(
                modelDirectory: directory,
                maxContextTokens: 4096,
                options: variant) != baseline)
        }
        #expect(AppLoadedRuntimeKey(
            modelDirectory: directory,
            maxContextTokens: 4096,
            options: base,
            forceLogitsHead: true) != baseline)

        value = base; value.prefillEnabled = false
        #expect(AppLoadedRuntimeKey(
            modelDirectory: directory,
            maxContextTokens: 4096,
            options: value) == baseline)
        value = base; value.prefillChunkTokens = 64
        #expect(AppLoadedRuntimeKey(
            modelDirectory: directory,
            maxContextTokens: 4096,
            options: value) == baseline)
    }
    /// Refused at selection, not inside the first prefill chunk - which is
    /// after the model load and, on an image turn, after every attachment has
    /// already been encoded on the GPU.
    @Test func slotsBelowTheChunkedPrefillMinimumRequirePrefillOff() {
        let minimum = RuntimeConfiguration.minimumExpertCacheSlotsForChunkedPrefill
        for slots in AppRuntimeOptions.allowedSlotCounts where slots < minimum {
            #expect(throws: AppInferenceError.self) {
                try AppRuntimeOptions(expertCacheSlots: slots, prefillEnabled: true).validate()
            }
            #expect(throws: Never.self) {
                try AppRuntimeOptions(expertCacheSlots: slots, prefillEnabled: false).validate()
            }
        }
    }

}
