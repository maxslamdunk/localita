import Combine
import CryptoKit
import SwiftUI
import TurboFieldfare
import TurboFieldfareAppCore
import UIKit

/// The standard benchmark: the three frozen `real-generation-v1` cases at the
/// protocol's settings, each from a freshly loaded model, with a cooldown
/// between them (`BenchmarkCooldown`). Each run gets a folder under
/// `Documents/Benchmarks` holding its `report.json` and one log per case, so
/// the person running it can open it in Files or share it as it is.
///
/// It is the `--autorun` harness driven from the screen, so a run here logs
/// exactly what a `devicectl` run logs.
@MainActor
final class StandardBenchmark: ObservableObject {
    enum Stage: Equatable {
        case idle
        case running(caseIndex: Int, HarnessProgress)
        case cooling(caseIndex: Int, seconds: Int)
    }

    @Published private(set) var stage = Stage.idle
    @Published private(set) var reports: [BenchmarkReport] = []

    let store = BenchmarkStore(root: FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Benchmarks", isDirectory: true))

    private let harness = Harness()
    private var task: Task<Void, Never>?
    private var progressSink: AnyCancellable?
    /// Why the run was stopped, when it was stopped rather than failing.
    private var stopReason: BenchmarkReport.Outcome?

    var isRunning: Bool { task != nil }

    init() {
        // `Harness` publishes on the main actor; delivered on the main queue
        // regardless, since `assumeIsolated` traps anywhere else.
        progressSink = harness.$progress.receive(on: DispatchQueue.main).sink {
            [weak self] progress in
            MainActor.assumeIsolated {
                guard let self, case .running(let index, _) = self.stage else { return }
                self.stage = .running(caseIndex: index, progress)
            }
        }
    }

    func refresh() {
        reports = store.list()
    }

    func start(model: BenchmarkReport.ModelInfo, directory: URL) {
        guard task == nil else { return }
        stopReason = nil
        task = Task {
            await run(model: model, directory: directory)
            task = nil
            stage = .idle
            refresh()
        }
    }

    /// `.cancelled` or `.interrupted`; the report records which.
    func stop(_ reason: BenchmarkReport.Outcome) {
        guard let task else { return }
        stopReason = reason
        task.cancel()
    }

    func delete(_ report: BenchmarkReport) {
        try? store.delete(report.id)
        refresh()
    }

    private func run(model: BenchmarkReport.ModelInfo, directory: URL) async {
        let started = Date()
        let runStartThermal = ProcessInfo.processInfo.thermalState
        guard let folder = try? store.makeRunFolder(started: started) else { return }
        var report = BenchmarkReport(
            id: folder.lastPathComponent, started: started, device: Self.device(),
            model: model,
            settings: .init(maxContext: BenchmarkProtocol.maxContext,
                            maxNewTokens: BenchmarkProtocol.maxNewTokens,
                            expertCacheSlots: RuntimeConfiguration.productionExpertCacheSlots,
                            temperature: BenchmarkProtocol.temperature,
                            topK: BenchmarkProtocol.topK, topP: BenchmarkProtocol.topP,
                            seed: BenchmarkProtocol.seed),
            plannedCases: BenchmarkProtocol.caseIDs)
        // Written before the first case, so a run the system kills still
        // leaves a report, marked as running.
        try? store.save(report)
        defer {
            report.finished = Date()
            try? store.save(report)
        }

        for (index, caseID) in BenchmarkProtocol.caseIDs.enumerated() {
            var cooldown: TimeInterval = 0
            if index > 0 {
                let began = Date()
                while !BenchmarkCooldown.isDone(elapsed: Date().timeIntervalSince(began),
                                                runStart: runStartThermal,
                                                now: ProcessInfo.processInfo.thermalState) {
                    stage = .cooling(caseIndex: index,
                                     seconds: Int(Date().timeIntervalSince(began)))
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        report.outcome = stopReason ?? .cancelled
                        return
                    }
                }
                cooldown = Date().timeIntervalSince(began)
            }

            stage = .running(caseIndex: index, .loading)
            var settings = HarnessSettings()
            settings.label = caseID
            settings.caseID = caseID
            settings.modelDirectory = directory
            settings.maxContext = BenchmarkProtocol.maxContext
            settings.maxNewTokens = BenchmarkProtocol.maxNewTokens
            settings.temperature = BenchmarkProtocol.temperature
            settings.topK = BenchmarkProtocol.topK
            settings.topP = BenchmarkProtocol.topP
            settings.seed = BenchmarkProtocol.seed
            switch await harness.logged(settings: settings, logDirectory: folder) {
            case .success(let result):
                guard let outcome = result.cases.first else {
                    report.outcome = .failed("the case produced no result")
                    return
                }
                let stats = outcome.stats
                report.cases.append(.init(
                    caseID: caseID,
                    promptSHA256: outcome.promptSHA256 ?? "",
                    promptTokens: outcome.promptTokens,
                    prefillSeconds: stats.prefillSeconds,
                    newTokens: stats.newTokens,
                    decodeSeconds: stats.decodeSeconds,
                    stopReason: String(describing: stats.reason),
                    decodeMiBPerToken: stats.decodeMegabytesPerToken,
                    decodeCacheHitRate: stats.decodeExpertIO.cacheHitRate,
                    cooldownSeconds: cooldown,
                    thermalAtStart: outcome.thermalAtStart,
                    thermalAtEnd: outcome.thermalAtEnd,
                    generatedSHA256: outcome.generatedSHA256,
                    logFile: result.log.lastPathComponent,
                    footers: [expertIOFooter(stats), phaseTimeFooter(stats),
                              gpuTimeFooter(stats), readLatencyFooter(stats)],
                    footprintBytes: outcome.footprintBytes,
                    peakFootprintBytes: outcome.peakFootprintBytes,
                    availableMemoryBytes: Int64(outcome.availableMemoryBytes)))
                try? store.save(report)
            case .failure(let error):
                report.outcome = stopReason
                    ?? (error is CancellationError ? .cancelled
                        : .failed(BenchmarkRedaction.redact(String(describing: error))))
                return
            }
        }
        report.outcome = .completed
    }

    private static func device() -> BenchmarkReport.DeviceInfo {
        var system = utsname()
        uname(&system)
        let identifier = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return .init(identifier: identifier,
                     physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                     osVersion: UIDevice.current.systemVersion,
                     appVersion: "\(version) (\(build))",
                     thermalAtStart: DeviceState.thermal(),
                     batteryAtStart: DeviceState.battery(),
                     lowPowerModeAtStart: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    static func modelInfo(_ descriptor: AppModelInstallDescriptor,
                          directory: URL) -> BenchmarkReport.ModelInfo {
        let manifest = try? Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return .init(name: descriptor.shortName, folder: descriptor.directoryName,
                     manifestSHA256: manifest.map {
                         SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
                     })
    }
}

/// Settings › Models › Benchmark. Opened with the chat model unloaded, since
/// the run loads its own copy and two do not fit.
struct BenchmarkView: View {
    @Bindable var model: AppModel
    @StateObject private var benchmark = StandardBenchmark()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            introSection
            if benchmark.stage == .idle {
                checklistSection
            }
            runSection
            if !benchmark.reports.isEmpty {
                Section("Results") {
                    ForEach(benchmark.reports, id: \.id) { report in
                        NavigationLink {
                            BenchmarkResultView(report: report,
                                                files: benchmark.store.files(for: report.id),
                                                store: benchmark.store,
                                                onSent: { benchmark.refresh() })
                        } label: {
                            BenchmarkRow(report: report)
                        }
                    }
                    .onDelete { offsets in
                        for offset in offsets { benchmark.delete(benchmark.reports[offset]) }
                    }
                    // Opening a result would take this screen away, and a
                    // run stops when it goes.
                    .disabled(benchmark.isRunning)
                }
            }
        }
        .navigationTitle("Benchmark")
        .navigationBarTitleDisplayMode(.inline)
        // Leaving mid-run would leave the run's copy of the model loaded
        // under a chat that loads its own.
        .navigationBarBackButtonHidden(benchmark.isRunning)
        .interactiveDismissDisabled(benchmark.isRunning)
        .onAppear { benchmark.refresh() }
        .onDisappear { benchmark.stop(.cancelled) }
        // A backgrounded app may not submit GPU work, so a run cannot carry
        // on; it stops and says why.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { benchmark.stop(.interrupted) }
        }
        .onChange(of: benchmark.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .onAppear { readPower() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.batteryStateDidChangeNotification)) { _ in readPower() }
        .onReceive(NotificationCenter.default.publisher(
            for: .NSProcessInfoPowerStateDidChange)) { _ in readPower() }
    }

    @State private var isPluggedIn = false
    @State private var isLowPowerModeOn = false

    private func readPower() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        isPluggedIn = state == .charging || state == .full
        isLowPowerModeOn = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Help tune the app for your iPhone")
                    .font(.headline)
                Text("Every iPhone model runs \(benchmarked.shortName) a "
                     + "little differently. A benchmark measures how yours does, and "
                     + "sharing the result shows what to tune for it.")
                Text("Results hold only the iPhone model, the iOS version and speed "
                     + "figures, never your chats. They stay on this iPhone until you "
                     + "share them.")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    /// How the project's own phone runs were taken: on the charger, Low Power
    /// Mode off (it caps the clocks), other apps closed. The first two are
    /// read live; the app cannot see the others.
    private var checklistSection: some View {
        Section {
            checklistRow("Plugged in", systemImage: "powerplug", met: isPluggedIn)
            checklistRow("Low Power Mode off", systemImage: "battery.100percent",
                         met: !isLowPowerModeOn)
            checklistRow("Other apps closed", systemImage: "square.stack", met: nil)
            checklistRow("10 to 15 minutes with the app open", systemImage: "clock",
                         met: nil)
        } header: {
            Text("Before you start")
        } footer: {
            Text("The screen stays on during the run. Leaving the app stops it.")
        }
    }

    /// `met` is nil for what the app cannot check.
    private func checklistRow(_ title: String, systemImage: String, met: Bool?) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if let met {
                Image(systemName: met ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(met ? .green : .orange)
                    .accessibilityLabel(met ? "Done" : "Not yet")
            }
        }
    }

    /// Always Gemma 4, whatever the chat is on: it is the model the
    /// project's phone rows, the fitted early-read guess and the protocol are
    /// for, so only its runs compare across devices. The chat's choice of
    /// model is left as it is.
    private let benchmarked = AppModelInstallDescriptor.default

    private var directory: URL {
        ModelLocation.directory(named: benchmarked.directoryName)
    }

    private var blocker: String? {
        if !ChatSession.isInstalled(benchmarked, current: model) {
            return "The benchmark runs \(benchmarked.shortName). Download it in "
                + "Models first."
        }
        if model.isInstallingModel || model.isInstallingVisionPack {
            return "Wait for the download to finish; it would slow the run down."
        }
        return nil
    }

    private var runSection: some View {
        Section {
            switch benchmark.stage {
            case .idle:
                Button("Run Benchmark") {
                    benchmark.start(
                        model: StandardBenchmark.modelInfo(benchmarked,
                                                           directory: directory),
                        directory: directory)
                }
                .disabled(blocker != nil)
                if let blocker {
                    Text(blocker).foregroundStyle(.secondary)
                }
            case .running(let index, let progress):
                status(index: index, detail: Self.describe(progress))
                stopButton
            case .cooling(let index, let seconds):
                status(index: index,
                       detail: "Letting the iPhone cool down · \(seconds) s")
                stopButton
            }
        } footer: {
            Text("Three fixed prompts, with a pause between them for the iPhone to "
                 + "cool. Results are also in the Files app, in this app's "
                 + "Benchmarks folder.")
        }
    }

    private func status(index: Int, detail: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Prompt \(index + 1) of \(BenchmarkProtocol.caseIDs.count) · "
                     + BenchmarkRow.caseName(BenchmarkProtocol.caseIDs[index]))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var stopButton: some View {
        Button("Stop", role: .destructive) { benchmark.stop(.cancelled) }
    }

    private static func describe(_ progress: HarnessProgress) -> String {
        switch progress {
        case .idle, .loading: return "Loading the model"
        case .prefill(let done, let total): return "Reading the prompt · \(done) of \(total)"
        case .generating(let tokens): return "Writing · \(tokens) tokens"
        }
    }
}

/// One run in the list: when, which model, and its speed per case.
private struct BenchmarkRow: View {
    let report: BenchmarkReport

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(report.started.formatted(date: .abbreviated, time: .shortened)) · "
                 + report.model.name)
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var summary: String {
        let speeds = report.cases
            .map { String(format: "%.2f", $0.tokensPerSecond) }
            .joined(separator: " · ")
        let suffix = speeds.isEmpty ? "" : " · \(speeds) tok/s"
        let sent = report.sentAt == nil ? "" : " · Sent"
        switch report.outcome {
        case .completed: return speeds + " tok/s" + sent
        case .running: return "Did not finish" + suffix + sent
        case .cancelled: return "Stopped" + suffix + sent
        case .interrupted: return "Stopped when the app was left" + suffix + sent
        case .failed: return "Failed" + suffix + sent
        }
    }

    static func caseName(_ caseID: String) -> String {
        switch caseID {
        case "short-explanation": return "Short"
        case "medium-review": return "Medium"
        case "long-synthesis": return "Long"
        default: return caseID
        }
    }
}

/// One run's figures and conditions, with its files to share and, for a
/// report in the current format, a way to send it to the project.
private struct BenchmarkResultView: View {
    @State private var report: BenchmarkReport
    let files: [URL]
    let store: BenchmarkStore
    let onSent: () -> Void
    @State private var isSending = false

    init(report: BenchmarkReport, files: [URL], store: BenchmarkStore,
         onSent: @escaping () -> Void) {
        _report = State(initialValue: report)
        self.files = files
        self.store = store
        self.onSent = onSent
    }

    var body: some View {
        Form {
            if BenchmarkSubmission.canSend(report) {
                sendSection
            }
            Section {
                ForEach(report.cases, id: \.caseID) { result in
                    LabeledContent {
                        Text(String(format: "%.2f tok/s", result.tokensPerSecond))
                            .monospacedDigit()
                    } label: {
                        Text(BenchmarkRow.caseName(result.caseID))
                        Text("\(result.promptTokens) prompt tokens read in "
                             + String(format: "%.1f s", result.prefillSeconds)
                             + " · \(result.newTokens) written · \(result.thermalAtEnd)")
                    }
                }
                if case .failed(let reason) = report.outcome {
                    Text(reason).foregroundStyle(.secondary)
                }
            } header: {
                Text("Speed")
            } footer: {
                Text("Writing speed per prompt. Reading the prompt is timed apart.")
            }
            Section("Conditions") {
                LabeledContent("Model", value: report.model.name)
                LabeledContent("Device", value: report.device.identifier)
                LabeledContent("Memory", value: ByteCountFormatter.string(
                    fromByteCount: Int64(report.device.physicalMemoryBytes), countStyle: .memory))
                LabeledContent("iOS", value: report.device.osVersion)
                LabeledContent("App", value: report.device.appVersion)
                LabeledContent("Thermal at start", value: report.device.thermalAtStart)
                LabeledContent("Battery at start", value: report.device.batteryAtStart)
                LabeledContent("Low Power Mode",
                               value: report.device.lowPowerModeAtStart ? "On" : "Off")
            }
        }
        .navigationTitle(report.started.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isSending) {
            BenchmarkSendSheet(report: report) { date in
                try? store.markSent(report.id, at: date)
                report.sentAt = date
                onSent()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(items: files) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(files.isEmpty)
            }
        }
    }

    private var sendSection: some View {
        Section {
            if let sentAt = report.sentAt {
                LabeledContent("Sent", value: sentAt.formatted(date: .abbreviated,
                                                               time: .shortened))
            } else {
                Button("Send to the Project…") { isSending = true }
            }
        } footer: {
            Text("Results from many iPhones show what to tune for each. You see "
                 + "exactly what is sent before it goes.")
        }
    }
}

/// What sending a run shows: a summary, what the report holds and where it
/// goes, and the report itself, byte for byte as it will be sent.
private struct BenchmarkSendSheet: View {
    let report: BenchmarkReport
    let onSent: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sending = false
    @State private var problem: String?

    private let endpoint = BenchmarkSubmission.defaultEndpoint

    private var payload: String {
        (try? BenchmarkSubmission.payload(for: report))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("This run") {
                    LabeledContent("iPhone", value: report.device.identifier)
                    LabeledContent("iOS", value: report.device.osVersion)
                    ForEach(report.cases, id: \.caseID) { result in
                        LabeledContent(BenchmarkRow.caseName(result.caseID),
                                       value: String(format: "%.2f tok/s",
                                                     result.tokensPerSecond))
                            .monospacedDigit()
                    }
                }
                Section {
                    Text("The iPhone model and its memory, the iOS and app versions, the "
                         + "battery and heat when each prompt ran, and the run's speed and "
                         + "memory figures. Never your chats, your name, an account, or "
                         + "anything that identifies this iPhone.")
                    Text("Results are stored on Cloudflare for the TurboFieldfare project "
                         + "and published in its public GitHub repository.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("What is sent")
                }
                Section {
                    DisclosureGroup("The report, as it will be sent") {
                        ScrollView(.horizontal) {
                            Text(payload)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .fixedSize()
                        }
                    }
                }
                if let problem {
                    Section {
                        Text(problem).foregroundStyle(.red)
                    }
                }
                if endpoint == nil {
                    Section {
                        Text("Sending is not set up in this build yet.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Send Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("Send") { send() }
                            .disabled(endpoint == nil)
                    }
                }
            }
            .interactiveDismissDisabled(sending)
        }
    }

    private func send() {
        guard let endpoint else { return }
        sending = true
        problem = nil
        Task {
            defer { sending = false }
            do {
                switch try await BenchmarkSubmission(endpoint: endpoint).send(report) {
                case .stored:
                    onSent(Date())
                    dismiss()
                case .refused(let reason):
                    problem = "The project's server did not accept this report: \(reason)"
                case .tryLater:
                    problem = "Too many results were sent from this network just now. "
                        + "Try again in a minute."
                case .failed(let status):
                    problem = "The project's server answered \(status). Try again later."
                }
            } catch {
                problem = "Could not reach the project's server. Check the connection "
                    + "and try again."
            }
        }
    }
}
