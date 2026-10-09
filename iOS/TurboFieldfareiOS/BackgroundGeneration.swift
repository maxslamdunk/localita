import AVFoundation
import AVKit
import CoreMedia
import SwiftUI
import TurboFieldfareAppCore
import UIKit

/// Keeps a reply generating after the user leaves the app, by showing it in a
/// Picture in Picture window, and tells the model's `GPUWorkGate` when the GPU
/// may be used.
///
/// What it rests on, measured on the iPhone 17 under iOS 26.6
/// (`validation-results-2026-10-09-ios-background-probes/`):
///
/// - A backgrounded app may not submit GPU work (`MTLCommandBufferError`
///   code 7), and `BGContinuedProcessingTask` does not offer the GPU on this
///   phone. **While the app shows Picture in Picture, it may.** A 512-token
///   decode ran in the background at foreground speed.
/// - Locking the phone refuses GPU work within about a second, PiP or not.
///   The turn then waits in the gate and runs the refused token again on
///   unlock.
/// - Closing the window with ✕ suspends the app at once. The turn is frozen
///   where it was and carries on when the user comes back.
///
/// The window shows the reply's last lines, drawn on the CPU a few times a
/// second. It offers only close and return-to-app controls: the private
/// `controlsStyle` 1 hides the play, skip and timeline controls, which mean
/// nothing here (checked by eye on the phone, 2026-10-09).
///
/// Caveat: a frozen 3 GB app is an early jetsam target. A turn paused by a
/// lock or a closed window lives only in memory until it finishes, so iOS
/// killing the app then loses it. A turn that leaves the app without a window
/// is stopped and saved instead (`Suspension`).
@MainActor
final class BackgroundGeneration: NSObject {
    static let shared = BackgroundGeneration()

    /// The layer PiP takes its picture from. `SourceView` puts it in the
    /// window, under the chat's opaque background.
    let layer = AVSampleBufferDisplayLayer()

    private weak var model: AppModel?
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var renderLoop: Task<Void, Never>?
    private var lastFrame: FrameContent?
    private var audioActive = false

    private(set) var isForeground = true
    /// Set by `protectedDataWillBecomeUnavailable`, which arrives at the moment
    /// of locking. Data protection itself only takes hold about 10 s later.
    private(set) var isLocked = false
    /// From `willStart` to `didStop`, so a window still opening counts.
    private(set) var isPiPActive = false

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(true) }
        }
        center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(false) }
        }
        updateAvailability()
    }

    // MARK: - Inputs

    func scenePhaseChanged(_ phase: ScenePhase) {
        isForeground = phase != .background
        if phase == .active {
            // Back in the app: the reply is on screen, so the window goes.
            controller?.stopPictureInPicture()
            isLocked = false
        }
        updateAvailability()
        update()
    }

    /// Called whenever the turn starts or ends, or the setting changes.
    func update() {
        guard let model else { return }
        let wanted = model.backgroundGeneration && model.isTurnInFlight
        if wanted {
            prepare()
            controller?.canStartPictureInPictureAutomaticallyFromInline = true
            startRenderLoop()
        } else {
            controller?.canStartPictureInPictureAutomaticallyFromInline = false
            if isPiPActive {
                // The reply finished in the window: leave it there, showing
                // the end, until the user closes it or comes back.
                render(force: true)
            } else {
                stopRenderLoop()
                deactivateAudio()
            }
        }
    }

    /// Whether a turn that just left the foreground carries on in the window,
    /// or waits out a lock. Asked by `Suspension` after a short grace period,
    /// because the window opens as the app leaves rather than before.
    var continuesInBackground: Bool {
        guard let model, model.backgroundGeneration else { return false }
        return isPiPActive || isLocked
    }

    private func setLocked(_ locked: Bool) {
        isLocked = locked
        TurnMemoryLog.shared.note(locked ? "phone-locked" : "phone-unlocked")
        updateAvailability()
    }

    /// The GPU is allowed while the app is in front, or in the window, and
    /// never while locked. The gate also retries every few seconds, so a wrong
    /// answer here costs a delay, not a stuck turn.
    private func updateAvailability() {
        let available = !isLocked && (isForeground || isPiPActive)
        guard let gate = model?.gpuWorkGate, gate.isAvailable != available else { return }
        gate.setAvailable(available)
        TurnMemoryLog.shared.note("gpu-available=\(available) foreground=\(isForeground) "
                                  + "pip=\(isPiPActive) locked=\(isLocked)")
    }

    // MARK: - Picture in Picture

    private func prepare() {
        activateAudio()
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else {
            return
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        // Private: 1 hides play/pause, ±10 s and the timeline, leaving close
        // and return-to-app. Checked before it is set, since a missing key
        // would raise.
        if controller.responds(to: NSSelectorFromString("setControlsStyle:")) {
            controller.setValue(1, forKey: "controlsStyle")
        }
        possibleObservation = controller.observe(\.isPictureInPicturePossible,
                                                 options: [.initial, .new]) { controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in TurnMemoryLog.shared.note("pip-possible=\(possible)") }
        }
        self.controller = controller
        render(force: true)
    }

    /// PiP needs an active playback session. Mixed with others, so starting a
    /// reply does not stop the user's music; the app plays no sound.
    private func activateAudio() {
        guard !audioActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
            audioActive = true
        } catch {
            TurnMemoryLog.shared.note("pip-audio-session-failed \(error)")
        }
    }

    private func deactivateAudio() {
        guard audioActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioActive = false
    }

    // MARK: - Frames

    private func startRenderLoop() {
        guard renderLoop == nil else { return }
        renderLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.render(force: false)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopRenderLoop() {
        renderLoop?.cancel()
        renderLoop = nil
    }

    /// What one frame shows; a frame is drawn only when this changes.
    private struct FrameContent: Equatable {
        var status: String
        var body: String
        var isThought: Bool
    }

    private func frameContent() -> FrameContent {
        guard let model else { return FrameContent(status: "", body: "", isThought: false) }
        let tokens = model.liveTokenCount
        let status: String
        if model.isWaitingForGPU {
            status = isLocked ? "Paused · unlock to continue" : "Paused · waiting for the GPU"
        } else if model.isTurnInFlight {
            switch model.phase {
            case .prefill:
                status = "Reading the message…"
            default:
                status = tokens > 0 ? "Writing · \(tokens) tokens" : "Starting…"
            }
        } else {
            status = model.error == nil ? "Done · \(tokens) tokens" : "Stopped"
        }
        let answer = model.outputText
        let isThought = answer.isEmpty && !model.thinkingText.isEmpty
        let text = isThought ? model.thinkingText : answer
        // The tail is all that can show; drawing more only costs time.
        return FrameContent(status: status, body: String(text.suffix(900)), isThought: isThought)
    }

    private static let frameSize = CGSize(width: 480, height: 360)

    private func render(force: Bool) {
        guard controller != nil else { return }
        let content = frameContent()
        guard force || content != lastFrame else { return }
        lastFrame = content
        guard let pixelBuffer = Self.draw(content) else { return }
        enqueue(pixelBuffer)
    }

    private static func draw(_ content: FrameContent) -> CVPixelBuffer? {
        let width = Int(frameSize.width), height = Int(frameSize.height)
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // UIKit draws top-down.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        UIColor(white: 0.08, alpha: 1).setFill()
        context.fill(CGRect(origin: .zero, size: frameSize))

        let margin: CGFloat = 18
        let statusFont = UIFont.systemFont(ofSize: 18, weight: .semibold)
        (content.status as NSString).draw(
            at: CGPoint(x: margin, y: 12),
            withAttributes: [.font: statusFont, .foregroundColor: UIColor(white: 0.65, alpha: 1)])

        // Bottom-aligned, so the newest line is always the last one visible.
        let top: CGFloat = 44
        let bodyRect = CGRect(x: margin, y: top, width: frameSize.width - 2 * margin,
                              height: frameSize.height - top - 12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSAttributedString(string: content.body, attributes: [
            .font: UIFont.systemFont(ofSize: 22),
            .foregroundColor: UIColor(white: content.isThought ? 0.6 : 0.95, alpha: 1),
            .paragraphStyle: paragraph,
        ])
        let needed = text.boundingRect(
            with: CGSize(width: bodyRect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        context.saveGState()
        context.clip(to: bodyRect)
        text.draw(with: CGRect(x: bodyRect.minX, y: bodyRect.maxY - ceil(needed),
                               width: bodyRect.width, height: ceil(needed)),
                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        context.restoreGState()
        return buffer
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
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
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0),
                                      to: CFMutableDictionary.self)
            CFDictionarySetValue(first,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    private func pipChanged(active: Bool, event: String) {
        isPiPActive = active
        TurnMemoryLog.shared.note(event)
        updateAvailability()
        if active {
            render(force: true)
        } else {
            update()
        }
    }

    /// Hosts `layer` in the window. PiP can start only from a layer that is in
    /// the view hierarchy and showing frames; this one sits behind the chat's
    /// opaque background, so it is never seen.
    struct SourceView: UIViewRepresentable {
        func makeUIView(context: Context) -> UIView {
            let view = LayerHost()
            view.isUserInteractionEnabled = false
            view.layer.addSublayer(BackgroundGeneration.shared.layer)
            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {}

        private final class LayerHost: UIView {
            override func layoutSubviews() {
                super.layoutSubviews()
                layer.sublayers?.forEach { $0.frame = bounds }
            }
        }
    }
}

extension BackgroundGeneration: AVPictureInPictureControllerDelegate,
                                AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ controller: AVPictureInPictureController) {
        Task { @MainActor in self.pipChanged(active: true, event: "pip-will-start") }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error) {
        let text = String(describing: error)
        Task { @MainActor in self.pipChanged(active: false, event: "pip-failed \(text)") }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController) {
        Task { @MainActor in self.pipChanged(active: false, event: "pip-stopped") }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
        completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                setPlaying playing: Bool) {}

    /// Live content: no timeline, no seeking.
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController) -> Bool { false }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime) async {}
}
