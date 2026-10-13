import Foundation
import Testing
@testable import TurboFieldfareRepackCore

/// The gate a community model passes: Gemma 4 26B-A4B, laid out exactly as the
/// reference. The fingerprint's value for the real checkpoints was taken from
/// their Hugging Face headers (gemma4 and supergemma4 agree); these tests pin
/// what it covers.
struct ReferenceLayoutTests {
    // MARK: - config.json reasons

    private func config(modelType: String = "gemma4",
                        layers: Int = 30,
                        hidden: Int = 2816,
                        experts: Int = 128,
                        quantization: [String: Any]? = nil) -> Data {
        var routers: [String: Any] = [:]
        for layer in 0..<30 {
            routers["language_model.model.layers.\(layer).router.proj"] =
                ["bits": 8, "group_size": 64]
        }
        var quant: [String: Any] = ["bits": 4, "group_size": 64, "mode": "affine"]
        quant.merge(routers) { $1 }
        let root: [String: Any] = [
            "model_type": modelType,
            "text_config": ["num_hidden_layers": layers, "hidden_size": hidden,
                            "num_experts": experts],
            "quantization": quantization ?? quant,
        ]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    @Test func theReferenceConfigPasses() {
        #expect(ReferenceLayout.configRejection(configData: config()) == nil)
    }

    @Test func eachCommonMisfitIsNamed() {
        let cases: [(Data, String)] = [
            (config(modelType: "qwen3_moe"), "qwen3_moe"),
            (config(layers: 62, hidden: 5376), "another size"),
            (config(experts: 64), "64 experts"),
            (config(quantization: ["bits": 8, "group_size": 64]), "8-bit build"),
            (config(quantization: ["bits": 4, "group_size": 32]), "group size 32"),
            (config(quantization: ["bits": 4, "group_size": 64, "mode": "mxfp4"]), "mxfp4"),
            (config(quantization: ["bits": 4, "group_size": 64]), "router"),
            (Data("not json".utf8), "could not be read"),
        ]
        for (data, phrase) in cases {
            let reason = ReferenceLayout.configRejection(configData: data)
            #expect(reason?.contains(phrase) == true, "\(phrase): \(reason ?? "nil")")
        }
    }

    private func sharedExpertConfig(bits: Int) throws -> Data {
        let base = try #require(
            JSONSerialization.jsonObject(with: config()) as? [String: Any])
        var quant = try #require(base["quantization"] as? [String: Any])
        for layer in 0..<30 {
            for proj in ["gate_proj", "up_proj", "down_proj"] {
                quant["language_model.model.layers.\(layer).mlp.\(proj)"] =
                    ["bits": bits, "group_size": 64]
            }
        }
        return config(quantization: quant)
    }

    /// QAT and LM Studio builds: the runtime runs an 8-bit shared expert.
    @Test func anEightBitSharedExpertPasses() throws {
        #expect(ReferenceLayout.configRejection(configData: try sharedExpertConfig(bits: 8))
            == nil)
    }

    @Test func anotherSharedExpertWidthIsRejectedByName() throws {
        let reason = ReferenceLayout.configRejection(
            configData: try sharedExpertConfig(bits: 6))
        #expect(reason?.contains("shared expert is 6-bit") == true)
    }

    @Test func bothRunnableLayoutsAreAcceptedAndNothingElse() {
        #expect(ReferenceLayout.accepts(ReferenceLayout.gemma4SHA256))
        #expect(ReferenceLayout.accepts(ReferenceLayout.gemma4SharedExpertInt8SHA256))
        #expect(!ReferenceLayout.accepts(String(repeating: "0", count: 64)))
    }

    @Test func aConfigWithoutQuantizationIsNotMLX() {
        var root = try! JSONSerialization.jsonObject(with: config()) as! [String: Any]
        root["quantization"] = nil
        let data = try! JSONSerialization.data(withJSONObject: root)
        #expect(ReferenceLayout.configRejection(configData: data)?.contains("not MLX") == true)
    }

    // MARK: - The fingerprint

    private func snapshot() throws -> (dir: String,
                                       arch: ArchInfo,
                                       meta: IndexLoader.SourceMetadata,
                                       header: Safetensors.Header) {
        let dir = tmpDirForRemote("layout")
        let snap = try SyntheticSnapshot.build(at: dir)
        let meta = try IndexLoader.load(snapshotDir: dir)
        return (dir, try ArchInfo.load(configPath: meta.configPath), meta,
                try Safetensors.parseHeader(path: snap.shardPath))
    }

    @Test func visionTensorsDoNotCount() throws {
        let s = try snapshot()
        defer { cleanUpRemote([s.dir]) }
        let vision = Safetensors.Header(
            path: "vision.safetensors", payloadBaseOffset: 0,
            tensors: [SourceTensor(name: "vision_tower.encoder.layers.0.mlp.fc1.weight",
                                   shardPath: "vision.safetensors", dtype: .bf16,
                                   shape: [16, 16], absoluteOffset: 0, sizeBytes: 512)])
        #expect(ReferenceLayout.fingerprint(arch: s.arch, meta: s.meta, shardHeaders: [s.header])
            == ReferenceLayout.fingerprint(arch: s.arch, meta: s.meta,
                                           shardHeaders: [s.header, vision]))
    }

    @Test func aShapeOrBitWidthChangeDoes() throws {
        let s = try snapshot()
        defer { cleanUpRemote([s.dir]) }
        let reference = ReferenceLayout.fingerprint(
            arch: s.arch, meta: s.meta, shardHeaders: [s.header])

        // The header's order is a dictionary's, so it changes from run to run;
        // pick a text tensor, since vision tensors are left out by design.
        var tensors = s.header.tensors
        let index = try #require(tensors.firstIndex {
            !RepackPlanner.isMultimodalTensorName($0.name)
        })
        let first = tensors[index]
        tensors[index] = SourceTensor(name: first.name, shardPath: first.shardPath,
                                  dtype: first.dtype, shape: first.shape.map { $0 * 2 },
                                  absoluteOffset: first.absoluteOffset,
                                  sizeBytes: first.sizeBytes)
        let reshaped = Safetensors.Header(path: s.header.path,
                                          payloadBaseOffset: s.header.payloadBaseOffset,
                                          tensors: tensors)
        #expect(ReferenceLayout.fingerprint(arch: s.arch, meta: s.meta, shardHeaders: [reshaped])
            != reference)

        let quantized = try #require(s.header.tensors.first {
            $0.dtype == .u32 && $0.name.hasSuffix(".weight")
                && !RepackPlanner.isMultimodalTensorName($0.name)
                && IndexLoader.quantSpec(forTensor: $0.name, meta: s.meta).bits == 4
        })
        var overrides = s.meta.bitsOverrides
        overrides[String(quantized.name.dropLast(".weight".count))] = QuantSpec(bits: 8)
        let rebitted = IndexLoader.SourceMetadata(
            indexPath: s.meta.indexPath, configPath: s.meta.configPath,
            indexSha256Hex: s.meta.indexSha256Hex, weightMap: s.meta.weightMap,
            baseBits: s.meta.baseBits, baseGroupSize: s.meta.baseGroupSize,
            baseMode: s.meta.baseMode, bitsOverrides: overrides,
            shardFilenames: s.meta.shardFilenames)
        #expect(ReferenceLayout.fingerprint(arch: s.arch, meta: rebitted, shardHeaders: [s.header])
            != reference)
    }

    @Test func theSyntheticLayoutIsNotTheReference() throws {
        let s = try snapshot()
        defer { cleanUpRemote([s.dir]) }
        #expect(throws: RepackError.self) {
            try ReferenceLayout.check(arch: s.arch, meta: s.meta, shardHeaders: [s.header])
        }
    }
}

/// The installer and the checker, against the fake Hugging Face server.
@Suite(.serialized)
struct ReferenceLayoutInstallTests {
    private func serveSnapshot(_ tag: String) throws -> String {
        let dir = tmpDirForRemote(tag)
        let snap = try SyntheticSnapshot.build(at: dir)
        resetFakeHF()
        FakeHFURLProtocol.files = try remoteFiles(snapshotDir: dir, snap: snap,
                                                  includeRequiredTokenizer: true,
                                                  includeOptionalTokenizer: false)
        return dir
    }

    private func pinnedOptions(output: String,
                               acceptsReferenceLayout: Bool) -> RemoteStreamingRepackOptions {
        RemoteStreamingRepackOptions(
            repoID: "owner/model",
            revision: "main",
            outputDir: output,
            requireKnownSource: true,
            acceptsReferenceLayout: acceptsReferenceLayout,
            rangeChunkBytes: 4096,
            minFreeReserveBytes: 0,
            overwrite: true,
            downloadSession: fakeHFSession(),
            baseURL: URL(string: "https://hf.test")!,
            retryBaseDelayNs: 0)
    }

    /// Off the pinned list, a checkpoint is refused by its index digest unless
    /// the reference layout is accepted, and then it is refused by its layout.
    @Test func anUnlistedCheckpointIsRefusedByDigestOrByLayout() async throws {
        let dir = try serveSnapshot("gate")
        let output = tmpPathForRemote("gate-out")
        defer { cleanUpRemote([dir, output]) }

        await #expect {
            _ = try await RemoteStreamingRepacker(
                options: pinnedOptions(output: output, acceptsReferenceLayout: false)).run()
        } throws: { error in
            if case RepackError.sourceFingerprintRejected = error { return true }
            return false
        }
        await #expect {
            _ = try await RemoteStreamingRepacker(
                options: pinnedOptions(output: output, acceptsReferenceLayout: true)).run()
        } throws: { error in
            if case RepackError.sourceLayoutRejected = error { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: output))
    }

    /// The manifest names the repository the model came from, which is what
    /// the app labels answers and matches chats by.
    @Test func theManifestNamesTheSourceRepository() async throws {
        let dir = try serveSnapshot("model-id")
        let output = tmpPathForRemote("model-id-out")
        defer { cleanUpRemote([dir, output]) }
        _ = try await RemoteStreamingRepacker(
            options: remoteOptions(outputDir: output, session: fakeHFSession(),
                                   repoID: "someone/retune-4bit")).run()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(
            fileURLWithPath: (output as NSString).appendingPathComponent("manifest.json"))))
            as? [String: Any]
        #expect(manifest?["modelID"] as? String == "someone/retune-4bit")
    }

    @Test func theCheckerNamesWhyACheckpointDoesNotFit() async throws {
        let dir = try serveSnapshot("check")
        defer { cleanUpRemote([dir]) }
        let check = try await RemoteModelInspector.check(
            repoID: "owner/model", downloadSession: fakeHFSession(),
            baseURL: URL(string: "https://hf.test")!)
        guard case .incompatible(let reason, _) = check else {
            Issue.record("expected a rejection, got \(check)")
            return
        }
        #expect(reason.contains("another size"))
    }

    @Test func theCheckerTellsAMissingRepositoryFromAMissingConfig() async throws {
        resetFakeHF()
        FakeHFURLProtocol.failures = ["HEAD:config.json": [.http(401)]]
        let gated = try await RemoteModelInspector.check(
            repoID: "owner/private", downloadSession: fakeHFSession(),
            baseURL: URL(string: "https://hf.test")!)
        guard case .incompatible(let gatedReason, _) = gated else {
            Issue.record("expected a rejection, got \(gated)")
            return
        }
        #expect(gatedReason.contains("private or gated"))

        resetFakeHF()
        let missing = try await RemoteModelInspector.check(
            repoID: "owner/gguf", downloadSession: fakeHFSession(),
            baseURL: URL(string: "https://hf.test")!)
        guard case .incompatible(let missingReason, _) = missing else {
            Issue.record("expected a rejection, got \(missing)")
            return
        }
        #expect(missingReason.contains("no config.json"))
    }
}
