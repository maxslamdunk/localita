import AVFoundation
import AVKit
import BackgroundTasks
import CoreML
import Metal
import SwiftUI
import UIKit
import TurboFieldfare

/// Test-only, like `--autorun`: `--background-probe` opens this screen instead
/// of the chat, to find out what the app can still do once it leaves the
/// screen. Decode needs the GPU for every token, and iOS refuses GPU work from
/// a backgrounded app, so the questions are:
///
/// 1. Does this phone offer background GPU time (`BGTaskScheduler
///    .supportedResources` containing `.gpu`)? Logged at launch.
/// 2. Does the Neural Engine, through Core ML, still run in the background?
///    `ane-probe.mlmodelc` in `Documents` (see
///    `results/validation-results-2026-10-09-ios-background-probes/`) is timed every
///    beat; its CPU-only time is measured at start, so a background time near
///    that means Core ML fell back to the CPU.
/// 3. Does iOS keep the app alive at its chat footprint (model loaded, 24
///    slots filled by a short generation) under a continued-processing task
///    while other apps are used? The log simply stops if it does not; the next
///    probe launch says so.
/// 4. Do any states count as foreground for the GPU: the screen turned off by
///    the proximity sensor, or the app in Picture in Picture?
///
/// Every beat (2 s) logs the app state, the lock state, memory and, if
/// enabled, one small GPU command buffer's status and one Core ML prediction.
/// Each line is fsynced to `Documents/decode-background-probe-<stamp>.log`.
@MainActor
final class BackgroundProbe: NSObject, ObservableObject {
    static let isRequested = LaunchArguments.all.contains("--background-probe")

    @Published private(set) var lines: [String] = []
    @Published private(set) var beating = false
    @Published private(set) var modelReady = false
    @Published var probesGPU = arguments.contains("--probe-gpu")
    @Published var probesANE = arguments.contains("--probe-ane")
    @Published var usesProximity = false {
        didSet { UIDevice.current.isProximityMonitoringEnabled = usesProximity }
    }

    private static let arguments = LaunchArguments.all
    /// `--pip-controls-style N`: the private `controlsStyle` of the PiP window.
    /// 0 leaves iOS's controls, 1 hides the playback controls, 2 hides all of them.
    private static let pipControlsStyle: Int = {
        guard let i = arguments.firstIndex(of: "--pip-controls-style"), i + 1 < arguments.count,
              let value = Int(arguments[i + 1]) else { return 1 }
        return value
    }()
    private static let activeLogKey = "backgroundProbeActiveLog"
    private let log = RunLog(label: "background-probe")
    private var beat = 0
    private var startedAt: ContinuousClock.Instant?
    private var heartbeat: Task<Void, Never>?
    private var task: BGContinuedProcessingTask?

    // Held to keep the footprint at its chat level, and for `generate`.
    private var held: (context: MetalContext, model: Model, runner: RealForwardRunner,
                       scratch: RawCompletionScratch, tokenizer: GFTokenizer,
                       prefill: PrefillRuntimeConfig)?
    @Published private(set) var generating = false

    private let gpuDevice = MTLCreateSystemDefaultDevice()
    private lazy var gpuQueue = gpuDevice?.makeCommandQueue()
    private lazy var gpuBuffer = gpuDevice?.makeBuffer(length: 64 << 20, options: .storageModePrivate)

    private var aneModel: MLModel?
    private var aneInput: MLDictionaryFeatureProvider?

    let pipLayer = AVSampleBufferDisplayLayer()
    private var pip: AVPictureInPictureController?
    private var pipPossible: NSKeyValueObservation?

    override init() {
        super.init()
        let previous = UserDefaults.standard.string(forKey: Self.activeLogKey)
        UserDefaults.standard.set(log.url.lastPathComponent, forKey: Self.activeLogKey)
        emit("start", "os=\(UIDevice.current.systemVersion) thermal=\(DeviceState.thermal()) "
            + "battery=\(DeviceState.battery()) lowPower=\(DeviceState.lowPower())")
        if let previous {
            emit("previous-probe-ended-without-stop", previous)
        }
        let resources = BGTaskScheduler.supportedResources
        emit("supported-resources", "rawValue=\(resources.rawValue) "
            + "gpu=\(resources.contains(.gpu)) model=\(UIDevice.current.model)")
        observeLifecycle()
    }

    func emit(_ event: String, _ detail: String = "") {
        lines.append(log.write(event, detail))
    }

    // MARK: - Lifecycle events

    private func observeLifecycle() {
        let names: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "will-resign-active"),
            (UIApplication.didEnterBackgroundNotification, "did-enter-background"),
            (UIApplication.willEnterForegroundNotification, "will-enter-foreground"),
            (UIApplication.didBecomeActiveNotification, "did-become-active"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "locked"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "unlocked"),
            (UIApplication.didReceiveMemoryWarningNotification, "memory-warning"),
            (UIDevice.proximityStateDidChangeNotification, "proximity-changed"),
        ]
        for (name, event) in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    self.emit(event, self.stateLine())
                }
            }
        }
    }

    private func stateLine() -> String {
        let app: String
        switch UIApplication.shared.applicationState {
        case .active: app = "active"
        case .inactive: app = "inactive"
        case .background: app = "background"
        @unknown default: app = "unknown"
        }
        return "app=\(app) protectedData=\(UIApplication.shared.isProtectedDataAvailable) "
            + "proximity=\(UIDevice.current.proximityState) "
            + "pip=\(pip?.isPictureInPictureActive ?? false) "
            + "task=\(task != nil) thermal=\(DeviceState.thermal())"
    }

    // MARK: - Model hold

    /// Loads the model as the harness does and generates a few tokens, so the
    /// expert slots are filled and the footprint is the one a chat leaves.
    func loadModel() async {
        guard held == nil else { return }
        do {
            let context = try MetalContext()
            let modelURL = ModelLocation.directory
            guard let tokenizerFolder = GFTokenizer.tokenizerFolder(forModelDirectory: modelURL) else {
                throw HarnessError.tokenizerMissing(modelURL.path)
            }
            let tokenizer = try await GFTokenizer.load(from: tokenizerFolder)
            let settings = HarnessSettings()
            let runtime = RuntimeConfiguration(
                expertCacheSlots: settings.expertCacheSlots,
                prefillChunkTokens: 128,
                forceLogitsHead: true)
            emit("model-loading", "slots=\(runtime.expertCacheSlots)")
            let model: Model
            do {
                model = try Model.load(directoryURL: modelURL, device: context.device,
                                       streamingMode: .pread(slotCount: runtime.expertCacheSlots),
                                       expertCachePolicy: runtime.modelExpertCachePolicy,
                                       integrityPolicy: .sizeCheckTrustedReceipt)
            } catch {
                emit("receipt-unusable", "\(error) — loading with fullSha256")
                model = try Model.load(directoryURL: modelURL, device: context.device,
                                       streamingMode: .pread(slotCount: runtime.expertCacheSlots),
                                       expertCachePolicy: runtime.modelExpertCachePolicy,
                                       integrityPolicy: .fullSha256)
            }
            let runner = try RealForwardRunner(model: model, context: context,
                                               maxContext: settings.maxContext,
                                               runtimeConfiguration: runtime)
            let scratch = try RawCompletionScratch(context: context, vocab: model.config.vocabSize)
            emit("model-loaded")
            let promptIds = tokenizer.encode(
                try tokenizer.applyChatTemplate([.init(role: .user, content: settings.prompt)]),
                addBOS: false)
            let config = GenerationConfig(maxNewTokens: 48, temperature: settings.temperature,
                                          topK: settings.topK, topP: settings.topP, seed: settings.seed)
            let stats = try await runRawCompletion(
                producer: runner, tokenizer: tokenizer, promptIds: promptIds, config: config,
                context: context, scratch: scratch, prefillConfig: runtime.prefillConfig
            ) { _ in }
            emit("warm-generation-done", "tokens=\(stats.newTokens)")
            held = (context, model, runner, scratch, tokenizer, runtime.prefillConfig)
            modelReady = true
        } catch {
            emit("model-failed", String(describing: error))
        }
    }

    /// A real reply on the held model, logged every 16 tokens with the app
    /// state, so a log shows whether decode keeps going in the background.
    func generate(maxNewTokens: Int = 512) async {
        guard let held, !generating else { return }
        generating = true
        defer { generating = false }
        let settings = HarnessSettings()
        do {
            let promptIds = held.tokenizer.encode(
                try held.tokenizer.applyChatTemplate([.init(
                    role: .user,
                    content: "Write a long, detailed essay on the history of the printing press.")]),
                addBOS: false)
            let config = GenerationConfig(maxNewTokens: maxNewTokens, temperature: settings.temperature,
                                          topK: settings.topK, topP: settings.topP, seed: settings.seed)
            emit("generate-start", "maxNew=\(maxNewTokens) " + stateLine())
            let stats = try await runRawCompletion(
                producer: held.runner, tokenizer: held.tokenizer, promptIds: promptIds,
                config: config, context: held.context, scratch: held.scratch,
                prefillConfig: held.prefill
            ) { progress in
                if case .token(let index, _, _) = progress, index % 16 == 0 {
                    self.emit("generate-progress", "tokens=\(index) " + self.stateLine())
                }
            }
            emit("generate-done", "tokens=\(stats.newTokens) reason=\(stats.reason) "
                + String(format: "decode-tok/s=%.3f prefill-s=%.1f ",
                         Double(stats.newTokens) / max(stats.decodeSeconds, 0.001), stats.prefillSeconds)
                + stateLine())
        } catch {
            emit("generate-failed", String(describing: error) + " " + stateLine())
        }
    }

    // MARK: - Neural Engine

    func loadANE() async {
        guard aneModel == nil else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ane-probe.mlmodelc")
        guard FileManager.default.fileExists(atPath: url.path) else {
            emit("ane-model-missing", url.path)
            return
        }
        do {
            let input = try MLMultiArray(shape: [1, 1024, 1, 512], dataType: .float16)
            aneInput = try MLDictionaryFeatureProvider(dictionary: ["x": input])
            let cpuConfig = MLModelConfiguration()
            cpuConfig.computeUnits = .cpuOnly
            let cpuModel = try MLModel(contentsOf: url, configuration: cpuConfig)
            emit("ane-reference-cpu-only", "ms=\(time(cpuModel)) ms=\(time(cpuModel)) ms=\(time(cpuModel))")
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: url, configuration: config)
            emit("ane-reference-cpu-and-ne", "ms=\(time(model)) ms=\(time(model)) ms=\(time(model))")
            emit("ane-plan", await planSummary(url: url, configuration: config))
            aneModel = model
        } catch {
            emit("ane-failed", String(describing: error))
        }
    }

    private func time(_ model: MLModel) -> String {
        guard let aneInput else { return "no-input" }
        let start = ContinuousClock.now
        do {
            _ = try model.prediction(from: aneInput)
        } catch {
            return "error(\(error))"
        }
        let elapsed = ContinuousClock.now - start
        return String(format: "%.1f", Double(elapsed.components.attoseconds) / 1e15
                      + Double(elapsed.components.seconds) * 1000)
    }

    /// Where Core ML plans to run each operation, counted by device.
    private func planSummary(url: URL, configuration: MLModelConfiguration) async -> String {
        do {
            let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
            guard case .program(let program) = plan.modelStructure,
                  let main = program.functions["main"] else { return "not-a-program" }
            var counts: [String: Int] = [:]
            for operation in main.block.operations {
                let device: String
                switch plan.deviceUsage(for: operation)?.preferred {
                case .neuralEngine: device = "ne"
                case .gpu: device = "gpu"
                case .cpu: device = "cpu"
                case nil: device = "none"
                @unknown default: device = "other"
                }
                counts[device, default: 0] += 1
            }
            return counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
        } catch {
            return "error(\(error))"
        }
    }

    // MARK: - GPU

    /// One 64 MiB fill on the GPU. The status says whether iOS let it run.
    private func probeGPU() async -> String {
        guard let gpuQueue, let gpuBuffer,
              let buffer = gpuQueue.makeCommandBuffer(),
              let blit = buffer.makeBlitCommandEncoder() else { return "gpu=no-command-buffer" }
        blit.fill(buffer: gpuBuffer, range: 0..<gpuBuffer.length, value: UInt8(beat & 0xff))
        blit.endEncoding()
        let start = ContinuousClock.now
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            buffer.addCompletedHandler { _ in done.resume() }
            buffer.commit()
        }
        let ms = Double((ContinuousClock.now - start).components.attoseconds) / 1e15
        let error = buffer.error.map { e -> String in
            let ns = e as NSError
            return " error=\(ns.domain):\(ns.code)"
        } ?? ""
        return "gpu=\(buffer.status.rawValue)" + String(format: " gpu-ms=%.2f", ms) + error
    }

    // MARK: - Heartbeat and the continued-processing task

    /// The Start button. iOS accepts a continued-processing task only from a
    /// person's action while the app is open.
    func start() {
        guard !beating else { return }
        beating = true
        startedAt = .now
        submitTask()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        beating = false
        task?.setTaskCompleted(success: true)
        task = nil
        emit("stopped", stateLine())
        UserDefaults.standard.removeObject(forKey: Self.activeLogKey)
    }

    private func tick() async {
        beat += 1
        var detail = "beat=\(beat) " + stateLine()
        if probesGPU { detail += " " + (await probeGPU()) }
        if probesANE, let aneModel { detail += " ane-ms=" + time(aneModel) }
        emit("beat", detail)
        if let task, let startedAt {
            let seconds = (ContinuousClock.now - startedAt).components.seconds
            task.progress.completedUnitCount = min(seconds, task.progress.totalUnitCount - 1)
            task.updateTitle("Background probe", subtitle: "beat \(beat)")
        }
        enqueuePiPFrame()
    }

    private func submitTask() {
        let prefix = Bundle.main.bundleIdentifier ?? "io.github.maxslamdunk.Localita"
        let identifier = prefix + ".probe." + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier,
                                                         using: .main) { launched in
            MainActor.assumeIsolated {
                guard let launched = launched as? BGContinuedProcessingTask else {
                    launched.setTaskCompleted(success: false)
                    return
                }
                self.task = launched
                launched.progress.totalUnitCount = 3600
                launched.expirationHandler = {
                    Task { @MainActor in
                        self.emit("task-expired", self.stateLine())
                        self.task?.setTaskCompleted(success: false)
                        self.task = nil
                    }
                }
                self.emit("task-started", self.stateLine())
            }
        }
        guard registered else {
            emit("task-not-registered")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
                                                       title: "Background probe",
                                                       subtitle: "starting")
        request.strategy = .fail
        if BGTaskScheduler.supportedResources.contains(.gpu) {
            request.requiredResources = .gpu
        }
        do {
            try BGTaskScheduler.shared.submit(request)
            emit("task-submitted", "requiredResources=\(request.requiredResources.rawValue)")
        } catch {
            emit("task-submit-failed", String(describing: error))
        }
    }

    // MARK: - Picture in Picture

    /// PiP needs the playback audio session and a layer that is showing frames.
    func preparePiP() {
        guard pip == nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            emit("pip-audio-session-failed", String(describing: error))
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: pipLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true
        let style = Self.pipControlsStyle
        let styled = style != 0 && controller.responds(to: NSSelectorFromString("setControlsStyle:"))
        if styled { controller.setValue(style, forKey: "controlsStyle") }
        emit("pip-controls", "linear=true controlsStyle=\(style) applied=\(styled)")
        pipPossible = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { c, _ in
            let possible = c.isPictureInPicturePossible
            Task { @MainActor in self.emit("pip-possible", "\(possible)") }
        }
        pip = controller
        enqueuePiPFrame()
        emit("pip-prepared", "supported=\(AVPictureInPictureController.isPictureInPictureSupported())")
    }

    func startPiP() {
        pip?.startPictureInPicture()
    }

    private func enqueuePiPFrame() {
        guard pip != nil else { return }
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer)
        guard let pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, Int32(40 + (beat * 23) % 180), CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                 formatDescription: format, sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = pipLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}

extension BackgroundProbe: AVPictureInPictureControllerDelegate,
                           AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController) {
        Task { @MainActor in self.emit("pip-started", self.stateLine()) }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error) {
        let text = String(describing: error)
        Task { @MainActor in self.emit("pip-failed", text) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController) {
        Task { @MainActor in self.emit("pip-stopped", self.stateLine()) }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                setPlaying playing: Bool) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController) -> Bool { false }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime) async {}
}

struct BackgroundProbeView: View {
    @StateObject private var probe = BackgroundProbe()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background probe").font(.headline)
            Toggle("GPU command buffer each beat", isOn: $probe.probesGPU)
            Toggle("Core ML (Neural Engine) each beat", isOn: $probe.probesANE)
            Toggle("Proximity screen-off", isOn: $probe.usesProximity)
            HStack {
                Button("Load model") { Task { await probe.loadModel() } }
                    .disabled(probe.modelReady)
                Button("Generate") { Task { await probe.generate() } }
                    .disabled(!probe.modelReady || probe.generating)
            }
            .buttonStyle(.bordered)
            HStack {
                Button("Load Core ML") { Task { await probe.loadANE() } }
                Button("PiP") { probe.preparePiP() }
                Button("Start PiP") { probe.startPiP() }
            }
            .buttonStyle(.bordered)
            HStack {
                Button(probe.beating ? "Running" : "Start") { probe.start() }
                    .disabled(probe.beating)
                Button("Stop") { probe.stop() }
                    .disabled(!probe.beating)
            }
            .buttonStyle(.borderedProminent)
            PiPLayerView(layer: probe.pipLayer)
                .frame(width: 160, height: 90)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(probe.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                }
                .onChange(of: probe.lines.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
        .padding()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }
}

/// Hosts the sample-buffer layer PiP takes its picture from. It has to be in
/// the window and showing frames before PiP is possible.
private struct PiPLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        let view = LayerHost()
        view.hosted = layer
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class LayerHost: UIView {
        var hosted: CALayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }
}
