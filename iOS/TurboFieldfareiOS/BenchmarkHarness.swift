import Foundation
import Metal
import UIKit
import os
import TurboFieldfare

// Track A step 3: the smallest thing that can load the real model on the phone
// and generate from it. No optimization, 16 expert-cache slots, Mac parity —
// the point is a zero-loss reference on the device, which is the instrument
// Track B cannot work without.

/// Where `devicectl` pushes the model. This is the path
/// `AppModelLocation.resolve` already falls through to for a standalone app —
/// inside a bundle the package-root probe cannot match, so it lands here.
enum ModelLocation {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base
            .appendingPathComponent("TurboFieldfare", isDirectory: true)
            .appendingPathComponent("gemma4.gturbo", isDirectory: true)
    }
}

/// `phys_footprint` and the jetsam headroom, the two numbers A1 was measured in.
enum Mem {
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    static func available() -> Int { os_proc_available_memory() }

    /// ⚠️ With the increased-memory-limit entitlement this overstates the real
    /// kill point by ~841 MB (measured 2026-09-16). Log it, never size against it.
    static func line() -> String {
        "footprint=\(footprint()) available=\(available())"
    }
}

struct HarnessSettings {
    /// The benchmark protocol passes `--max-context 4096` explicitly, so the
    /// measured rows are 4K regardless of the 8K CLI default.
    var maxContext = 4096
    var maxNewTokens = 128
    /// Mac parity. Track B step 2 is where this gets raised against the 5.60 GB
    /// ceiling; raising it here first would make the first device number
    /// incomparable with every Mac row.
    var expertCacheSlots = 16
    var temperature: Float = 0.2
    var topK = 64
    var topP: Float = 0.95
    var seed: UInt64 = 1
    var label = "run"
    var prompt = "Explain what a mixture-of-experts language model is, and why "
        + "streaming experts from storage changes the engineering problem."

    static func fromLaunchArguments() -> HarnessSettings {
        var settings = HarnessSettings()
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        if let v = value("--label") { settings.label = v }
        if let v = value("--prompt") { settings.prompt = v }
        if let v = value("--max-new").flatMap(Int.init) { settings.maxNewTokens = v }
        if let v = value("--max-context").flatMap(Int.init) { settings.maxContext = v }
        if let v = value("--slots").flatMap(Int.init) { settings.expertCacheSlots = v }
        return settings
    }
}

/// One fsynced line per event. A run that ends in a jetsam kill leaves no
/// return value and no console, so the log has to be durable at every step —
/// the same reason the A1 probe fsynced. The last line written is the evidence.
final class RunLog {
    private let handle: FileHandle?
    private let started = DispatchTime.now().uptimeNanoseconds
    private var seq = 0

    let url: URL

    init(label: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let documents = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask)[0]
        url = documents.appendingPathComponent("decode-\(label)-\(stamp).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    @discardableResult
    func write(_ event: String, _ detail: String = "") -> String {
        seq += 1
        let ms = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let line = "\(seq), \(ms), \(event), \(Mem.line())\(detail.isEmpty ? "" : ", " + detail)"
        if let handle, let data = (line + "\n").data(using: .utf8) {
            handle.write(data)
            fsync(handle.fileDescriptor)
        }
        return line
    }
}

enum HarnessError: LocalizedError {
    case noMetalDevice
    case modelMissing(String)
    case tokenizerMissing(String)

    var errorDescription: String? {
        switch self {
        case .noMetalDevice:
            return "no Metal device"
        case .modelMissing(let path):
            return "no model at \(path) — push one with `devicectl device copy to`"
        case .tokenizerMissing(let path):
            return "no tokenizer sidecar under \(path)"
        }
    }
}

@MainActor
final class Harness: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var running = false

    private var log: RunLog?

    private func emit(_ event: String, _ detail: String = "") {
        let line = log?.write(event, detail) ?? "\(event) \(detail)"
        lines.append(line)
    }

    func run(settings: HarnessSettings = .fromLaunchArguments()) async {
        guard !running else { return }
        running = true
        defer { running = false }

        let log = RunLog(label: settings.label)
        self.log = log
        emit("start", "device=\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")

        do {
            try await generate(settings: settings)
        } catch {
            emit("failed", "\(error.localizedDescription)")
        }
    }

    private func generate(settings: HarnessSettings) async throws {
        let modelURL = ModelLocation.directory
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw HarnessError.modelMissing(modelURL.path)
        }
        emit("model-found", modelURL.path)

        // Resolved explicitly rather than through `load(forModelDirectory:)`,
        // whose fallback is a network fetch from the Hub. On a phone that would
        // turn a missing sidecar into a silent download instead of an error.
        guard let tokenizerFolder = GFTokenizer.tokenizerFolder(forModelDirectory: modelURL) else {
            throw HarnessError.tokenizerMissing(modelURL.path)
        }
        let tokenizer = try await GFTokenizer.load(from: tokenizerFolder)
        emit("tokenizer-loaded")

        // Compiles all 14 shader modules from source at startup. On the Mac this
        // is unmeasured noise; on the phone it is worth its own timestamp.
        guard let device = MetalContext.makeSystemDefaultDevice() else {
            throw HarnessError.noMetalDevice
        }
        emit("metal-device", "name=\(device.name) apple10=\(device.supportsFamily(.apple10))")
        let context = try MetalContext()
        emit("shaders-compiled")

        let config = GenerationConfig(
            maxNewTokens: settings.maxNewTokens,
            temperature: settings.temperature,
            topK: settings.topK,
            topP: settings.topP,
            seed: settings.seed)
        let runtime = RuntimeConfiguration(
            expertCacheSlots: settings.expertCacheSlots,
            // A sampling config cannot use the fused head's GPU argmax.
            forceLogitsHead: !config.isPureGreedy)

        // `.fullSha256` would SHA-256 each 410 MiB layer file on its first
        // routed touch, landing that cost inside the `io` phase it is trying to
        // measure. The receipt is written at install time and checked here
        // instead. If it is absent, say so loudly rather than quietly hashing.
        let hasReceipt = FileManager.default.fileExists(
            atPath: modelURL.appendingPathComponent("verified-install.json").path)
        if !hasReceipt {
            emit("no-install-receipt",
                 "falling back to fullSha256 — io timings from this run are contaminated")
        }
        let loadStarted = DispatchTime.now().uptimeNanoseconds
        let model = try Model.load(
            directoryURL: modelURL,
            device: context.device,
            streamingMode: .pread(slotCount: runtime.expertCacheSlots),
            expertCachePolicy: runtime.modelExpertCachePolicy,
            integrityPolicy: hasReceipt ? .sizeCheckTrustedReceipt : .fullSha256)
        emit("model-loaded",
             "ms=\((DispatchTime.now().uptimeNanoseconds - loadStarted) / 1_000_000)")

        let runner = try RealForwardRunner(
            model: model,
            context: context,
            maxContext: settings.maxContext,
            runtimeConfiguration: runtime)
        let scratch = try RawCompletionScratch(context: context, vocab: model.config.vocabSize)
        emit("runner-ready")

        let promptIds = tokenizer.encode(
            try tokenizer.applyChatTemplate([.init(role: .user, content: settings.prompt)]),
            addBOS: false)
        emit("prompt-encoded", "tokens=\(promptIds.count)")

        var text = ""
        let stats = try await runRawCompletion(
            producer: runner,
            tokenizer: tokenizer,
            promptIds: promptIds,
            config: config,
            context: context,
            scratch: scratch,
            prefillConfig: runtime.prefillConfig) { progress in
                switch progress {
                case .prefill:
                    break
                case .token(let index, _, let delta):
                    text += delta
                    // Footprint every 16 tokens: the jetsam-survival evidence
                    // Track A's definition of done asks for.
                    if index % 16 == 0 {
                        _ = self.log?.write("token", "index=\(index)")
                    }
                case .tail(let tail):
                    text += tail
                }
            }

        let tokensPerSecond = stats.decodeSeconds > 0
            ? Double(stats.newTokens) / stats.decodeSeconds
            : 0
        emit("done", "[stop=\(String(describing: stats.reason)) "
            + "prefill=\(stats.prefillTokens)tok new=\(stats.newTokens)tok "
            + "decode=\(String(format: "%.2f", stats.decodeSeconds))s "
            + "tok/s=\(String(format: "%.3f", tokensPerSecond))]")
        emit("expert-io", expertIOFooter(stats))
        emit("phase-time", phaseTimeFooter(stats))
        lines.append("--- generated ---")
        lines.append(text)
    }
}
