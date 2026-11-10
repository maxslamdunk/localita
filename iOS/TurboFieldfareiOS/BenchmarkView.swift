import Combine
import CryptoKit
import SwiftUI
import TurboFieldfare
import TurboFieldfareAppCore
import UIKit

/// The in-app benchmark: the three frozen `real-generation-v1` cases at the
/// protocol's settings, each from a freshly loaded model, with a cooldown
/// between them (`BenchmarkCooldown`). A standard run is one pass at the
/// defaults; a settings sweep (`BenchmarkSweep`, 12 GB phones only) is seven,
/// each at its own settings, with a longer pause between them. Each pass gets
/// a folder under `Documents/Benchmarks` holding its `report.json` and one log
/// per case. A pass leaves the phone only when the person sends it.
///
/// It is the `--autorun` harness driven from the screen, so a run here logs
/// exactly what a `devicectl` run logs.
@MainActor
final class StandardBenchmark: ObservableObject {
    enum Kind { case standard, sweep }

    /// Which pass of how many, and at what settings; for a standard run, 1 of 1.
    struct Pass: Equatable {
        let index: Int
        let count: Int
        let configuration: BenchmarkConfiguration
    }

    enum Stage: Equatable {
        case idle
        case running(Pass, caseIndex: Int, HarnessProgress)
        case cooling(Pass, caseIndex: Int, seconds: Int)
        /// Waiting before the next pass of a sweep.
        case pausing(next: Pass, seconds: Int)
    }

    @Published private(set) var stage = Stage.idle
    @Published private(set) var entries: [BenchmarkListEntry] = []

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
                guard let self, case .running(let pass, let index, _) = self.stage else { return }
                self.stage = .running(pass, caseIndex: index, progress)
            }
        }
    }

    func refresh() {
        entries = BenchmarkListEntry.group(store.list())
    }

    func start(_ kind: Kind, model: BenchmarkReport.ModelInfo, directory: URL) {
        guard task == nil else { return }
        stopReason = nil
        task = Task {
            await run(kind, model: model, directory: directory)
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

    func delete(_ entry: BenchmarkListEntry) {
        for report in entry.reports { try? store.delete(report.id) }
        refresh()
    }

    private func run(_ kind: Kind, model: BenchmarkReport.ModelInfo, directory: URL) async {
        let configurations = kind == .standard
            ? [BenchmarkConfiguration.standard] : BenchmarkSweep.configurations
        // Every pass cools back to where the first began, so a sweep's later
        // passes start no warmer than its first.
        let startThermal = ProcessInfo.processInfo.thermalState
        let sweepSubmissionID = UUID().uuidString
        var sweepID: String?
        for (index, configuration) in configurations.enumerated() {
            let pass = Pass(index: index + 1, count: configurations.count,
                            configuration: configuration)
            if index > 0 {
                guard await wait(minimum: BenchmarkSweep.pauseMinimum,
                                 maximum: BenchmarkSweep.pauseMaximum,
                                 from: startThermal,
                                 stage: { .pausing(next: pass, seconds: $0) }) != nil
                else { return }
            }
            let started = Date()
            guard let folder = try? store.makeRunFolder(started: started) else { return }
            let sweep = kind == .standard ? nil : BenchmarkReport.Sweep(
                id: sweepID ?? folder.lastPathComponent, index: pass.index,
                count: pass.count, submissionID: sweepSubmissionID)
            sweepID = sweep?.id
            let outcome = await runPass(pass, sweep: sweep, started: started, folder: folder,
                                        startThermal: startThermal, model: model,
                                        directory: directory)
            guard outcome == .completed else { return }
        }
    }

    /// Waits as `BenchmarkCooldown` says, showing the seconds through `stage`.
    /// Returns how long it waited, or nil when the run was stopped meanwhile.
    private func wait(minimum: TimeInterval, maximum: TimeInterval,
                      from startThermal: ProcessInfo.ThermalState,
                      stage: (Int) -> Stage) async -> TimeInterval? {
        let began = Date()
        while !BenchmarkCooldown.isDone(elapsed: Date().timeIntervalSince(began),
                                        runStart: startThermal,
                                        now: ProcessInfo.processInfo.thermalState,
                                        minimum: minimum, maximum: maximum) {
            self.stage = stage(Int(Date().timeIntervalSince(began)))
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return nil
            }
        }
        return Date().timeIntervalSince(began)
    }

    /// One pass of the three cases at `pass.configuration`, written to its
    /// own report. Returns the report's outcome.
    private func runPass(_ pass: Pass, sweep: BenchmarkReport.Sweep?, started: Date,
                         folder: URL, startThermal: ProcessInfo.ThermalState,
                         model: BenchmarkReport.ModelInfo,
                         directory: URL) async -> BenchmarkReport.Outcome {
        let configuration = pass.configuration
        var report = BenchmarkReport(
            id: folder.lastPathComponent, started: started, device: Self.device(),
            model: model, settings: configuration.runSettings,
            plannedCases: BenchmarkProtocol.caseIDs, sweep: sweep)
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
                guard let waited = await wait(
                    minimum: BenchmarkCooldown.minimum, maximum: BenchmarkCooldown.maximum,
                    from: startThermal,
                    stage: { .cooling(pass, caseIndex: index, seconds: $0) })
                else {
                    report.outcome = stopReason ?? .cancelled
                    return report.outcome
                }
                cooldown = waited
            }

            stage = .running(pass, caseIndex: index, .loading)
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
            settings.expertCacheSlots = configuration.expertCacheSlots
            settings.expertSkipMissThreshold = configuration.expertSkipMissThreshold
            settings.earlyExpertReads = configuration.earlyExpertReads
            switch await harness.logged(settings: settings, logDirectory: folder) {
            case .success(let result):
                guard let outcome = result.cases.first else {
                    report.outcome = .failed("the case produced no result")
                    return report.outcome
                }
                // A report says what it ran at, so a run that got anything
                // else is a failure, not a result under the wrong label.
                guard outcome.expertCacheSlots == configuration.expertCacheSlots,
                      outcome.expertSkip == configuration.expertSkipDescription,
                      outcome.earlyExpertReads == configuration.earlyExpertReads else {
                    report.outcome = .failed(
                        "asked for \(configuration.label) but ran "
                        + "\(outcome.expertCacheSlots) slots, skip \(outcome.expertSkip ?? "off"), "
                        + "\(outcome.earlyExpertReads) early reads")
                    return report.outcome
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
                return report.outcome
            }
        }
        report.outcome = .completed
        return report.outcome
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
            if !benchmark.entries.isEmpty {
                Section("Results") {
                    ForEach(benchmark.entries) { entry in
                        NavigationLink {
                            switch entry {
                            case .single(let report):
                                BenchmarkResultView(report: report, store: benchmark.store,
                                                    allowsSending: true,
                                                    onSent: { benchmark.refresh() })
                            case .sweep(_, let runs):
                                BenchmarkSweepView(runs: runs, store: benchmark.store,
                                                   onSent: { benchmark.refresh() })
                            }
                        } label: {
                            BenchmarkRow(entry: entry)
                        }
                    }
                    .onDelete { offsets in
                        for offset in offsets { benchmark.delete(benchmark.entries[offset]) }
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

    /// 12 GB phones only; see `BenchmarkSweep`.
    private let offersSweep = DeviceMemory.offersLargeExpertCache

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Help tune the app for your iPhone")
                    .font(.headline)
                Text("Every iPhone model runs \(benchmarked.shortName) a "
                     + "little differently. A benchmark measures how yours does, and "
                     + "sending the result shows what to tune for it.")
                Text("Results hold only the iPhone model, the iOS version and speed "
                     + "figures, never your chats. They stay on this iPhone unless you "
                     + "send them.")
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
            checklistRow(offersSweep
                         ? "10 to 15 minutes with the app open, about 80 for the sweep"
                         : "10 to 15 minutes with the app open",
                         systemImage: "clock", met: nil)
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

    private func start(_ kind: StandardBenchmark.Kind) {
        benchmark.start(kind,
                        model: StandardBenchmark.modelInfo(benchmarked, directory: directory),
                        directory: directory)
    }

    private var runSection: some View {
        Section {
            switch benchmark.stage {
            case .idle:
                Button("Run Benchmark") { start(.standard) }
                    .disabled(blocker != nil)
                if offersSweep {
                    Button("Run Settings Sweep") { start(.sweep) }
                        .disabled(blocker != nil)
                }
                if let blocker {
                    Text(blocker).foregroundStyle(.secondary)
                }
            case .running(let pass, let index, let progress):
                status(pass, caseIndex: index, detail: Self.describe(progress))
                stopButton
            case .cooling(let pass, let index, let seconds):
                status(pass, caseIndex: index,
                       detail: "Letting the iPhone cool down · \(seconds) s")
                stopButton
            case .pausing(let next, let seconds):
                status(next, caseIndex: nil,
                       detail: "Letting the iPhone cool down before this run · \(seconds) s")
                stopButton
            }
        } footer: {
            if offersSweep {
                Text("Three fixed prompts, with a pause between them for the iPhone to "
                     + "cool. The settings sweep runs them seven times, at 24 and 32 "
                     + "expert slots and three expert-skipping settings, to show which "
                     + "suits this iPhone.")
            } else {
                Text("Three fixed prompts, with a pause between them for the iPhone to "
                     + "cool.")
            }
        }
    }

    /// `caseIndex` is nil while waiting for the pass to begin.
    private func status(_ pass: StandardBenchmark.Pass, caseIndex: Int?,
                        detail: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                if pass.count > 1 {
                    Text("Run \(pass.index) of \(pass.count) · \(pass.configuration.label)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let caseIndex {
                    Text("Prompt \(caseIndex + 1) of \(BenchmarkProtocol.caseIDs.count) · "
                         + BenchmarkRow.caseName(BenchmarkProtocol.caseIDs[caseIndex]))
                }
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

/// One line in the list: a run, or a whole sweep.
private struct BenchmarkRow: View {
    let entry: BenchmarkListEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var title: String {
        let when = entry.started.formatted(date: .abbreviated, time: .shortened)
        switch entry {
        case .single(let report): return "\(when) · \(report.model.name)"
        case .sweep: return "\(when) · Settings sweep"
        }
    }

    private var summary: String {
        switch entry {
        case .single(let report):
            return Self.summary(report)
        case .sweep(_, let runs):
            let count = runs.first?.sweep?.count ?? runs.count
            let finished = runs.count == count && runs.last?.outcome == .completed
            let sent = runs.allSatisfy { $0.sentAt != nil } ? " · Sent" : ""
            return (finished ? "\(count) runs" : "Stopped after \(runs.count) of \(count) runs")
                + sent
        }
    }

    static func summary(_ report: BenchmarkReport) -> String {
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

    /// What a report ran at, from its own record. Format 2 did not record
    /// skipping or early reads, so it says only the slots.
    static func settingsLabel(_ settings: BenchmarkReport.RunSettings) -> String {
        guard let skip = settings.expertSkipThreshold,
              let early = settings.earlyExpertReads else {
            return "\(settings.expertCacheSlots) slots"
        }
        return BenchmarkConfiguration(expertCacheSlots: settings.expertCacheSlots,
                                      expertSkipThreshold: skip,
                                      earlyExpertReads: early).label
    }
}

/// A sweep's runs, in order, sent together.
private struct BenchmarkSweepView: View {
    @State private var runs: [BenchmarkReport]
    let store: BenchmarkStore
    let onSent: () -> Void
    @State private var isSending = false
    /// The runs the open send sheet sends, fixed when it opens, so the list
    /// does not shrink under it as each one is stored.
    @State private var toSend: [BenchmarkReport] = []

    init(runs: [BenchmarkReport], store: BenchmarkStore, onSent: @escaping () -> Void) {
        _runs = State(initialValue: runs)
        self.store = store
        self.onSent = onSent
    }

    private var unsent: [BenchmarkReport] {
        runs.filter { $0.sentAt == nil && BenchmarkSubmission.canSend($0) }
    }

    var body: some View {
        Form {
            sendSection
            Section {
                ForEach(runs, id: \.id) { run in
                    NavigationLink {
                        BenchmarkResultView(report: run, store: store, allowsSending: false,
                                            onSent: {})
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Run \(run.sweep?.index ?? 0) · "
                                 + BenchmarkRow.settingsLabel(run.settings))
                            Text(BenchmarkRow.summary(run))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("Runs")
            } footer: {
                Text("Writing speed for the short, medium and long prompts. The first "
                     + "and last runs use the same settings, so they show how much two "
                     + "runs differ by chance.")
            }
            if let first = runs.first {
                Section("Conditions") {
                    LabeledContent("Model", value: first.model.name)
                    LabeledContent("Device", value: first.device.identifier)
                    LabeledContent("Memory", value: ByteCountFormatter.string(
                        fromByteCount: Int64(first.device.physicalMemoryBytes),
                        countStyle: .memory))
                    LabeledContent("iOS", value: first.device.osVersion)
                    LabeledContent("App", value: first.device.appVersion)
                    LabeledContent("Battery at start", value: first.device.batteryAtStart)
                }
            }
        }
        .navigationTitle("Settings Sweep")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isSending) {
            BenchmarkSendSheet(reports: toSend) { id, date in
                try? store.markSent(id, at: date)
                if let index = runs.firstIndex(where: { $0.id == id }) {
                    runs[index].sentAt = date
                }
                onSent()
            }
        }
    }

    private var sendSection: some View {
        Section {
            if unsent.isEmpty, let sentAt = runs.compactMap(\.sentAt).max() {
                LabeledContent("Sent", value: sentAt.formatted(date: .abbreviated,
                                                               time: .shortened))
                // One ID for the whole sweep, the only way to name it when
                // asking for it to be removed.
                if let submissionID = runs.first?.sweep?.submissionID {
                    LabeledContent("Sweep ID") {
                        Text(submissionID)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                Link("Privacy Policy", destination: PrivacyPolicy.url)
            } else if !unsent.isEmpty {
                Button(unsent.count == runs.count
                       ? "Send to the Project…"
                       : "Send the Other \(unsent.count) Runs…") {
                    toSend = unsent
                    isSending = true
                }
            }
        } footer: {
            if unsent.isEmpty {
                Text("To have this sweep removed, email its sweep ID to the address in "
                     + "the privacy policy.")
            } else {
                Text("Sends one report per run. You see exactly what is sent before it "
                     + "goes.")
            }
        }
    }
}

/// One run's figures and conditions and, for a run of its own in a format the
/// Worker takes, a way to send it to the project. A sweep's runs are sent
/// from the sweep.
private struct BenchmarkResultView: View {
    @State private var report: BenchmarkReport
    let store: BenchmarkStore
    let allowsSending: Bool
    let onSent: () -> Void
    @State private var isSending = false

    init(report: BenchmarkReport, store: BenchmarkStore, allowsSending: Bool,
         onSent: @escaping () -> Void) {
        _report = State(initialValue: report)
        self.store = store
        self.allowsSending = allowsSending
        self.onSent = onSent
    }

    var body: some View {
        Form {
            if allowsSending && BenchmarkSubmission.canSend(report) {
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
                LabeledContent("Settings", value: BenchmarkRow.settingsLabel(report.settings))
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
            BenchmarkSendSheet(reports: [report]) { id, date in
                try? store.markSent(id, at: date)
                report.sentAt = date
                onSent()
            }
        }
    }

    private var sendSection: some View {
        Section {
            if let sentAt = report.sentAt {
                LabeledContent("Sent", value: sentAt.formatted(date: .abbreviated,
                                                               time: .shortened))
                // The only way to name a sent result, which holds nothing
                // about its sender, when asking for it to be removed.
                if let submissionID = report.submissionID {
                    LabeledContent("Report ID") {
                        Text(submissionID)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                Link("Privacy Policy", destination: PrivacyPolicy.url)
            } else {
                Button("Send to the Project…") { isSending = true }
            }
        } footer: {
            if report.sentAt == nil {
                Text("Results from many iPhones show what to tune for each. You see "
                     + "exactly what is sent before it goes.")
            } else {
                Text("To have this result removed, email its report ID to the address "
                     + "in the privacy policy.")
            }
        }
    }
}

/// What sending shows: a summary, what a report holds and where it goes, and
/// each report itself, byte for byte as it will be sent. A sweep sends one
/// report per run, in order, and a run already stored counts as sent.
private struct BenchmarkSendSheet: View {
    let reports: [BenchmarkReport]
    /// Called once per report the Worker stored, with the report's `id`.
    let onSent: (String, Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sending = false
    @State private var problem: String?
    @State private var stored: Set<String> = []

    private let endpoint = BenchmarkSubmission.defaultEndpoint

    private func payload(_ report: BenchmarkReport) -> String {
        (try? BenchmarkSubmission.payload(for: report))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private var isSweep: Bool { reports.contains { $0.sweep != nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section(isSweep ? "This sweep" : "This run") {
                    if let first = reports.first {
                        LabeledContent("iPhone", value: first.device.identifier)
                        LabeledContent("iOS", value: first.device.osVersion)
                    }
                    if isSweep {
                        ForEach(reports, id: \.id) { report in
                            LabeledContent("Run \(report.sweep?.index ?? 0)",
                                           value: BenchmarkRow.settingsLabel(report.settings))
                        }
                    } else {
                        ForEach(reports.first?.cases ?? [], id: \.caseID) { result in
                            LabeledContent(BenchmarkRow.caseName(result.caseID),
                                           value: String(format: "%.2f tok/s",
                                                         result.tokensPerSecond))
                                .monospacedDigit()
                        }
                    }
                }
                Section {
                    Text("The iPhone model and its memory, the iOS and app versions, the "
                         + "settings each run used, the battery and heat when each prompt "
                         + "ran, and the speed and memory figures. Never your chats, your "
                         + "name, an account, or anything that identifies this iPhone.")
                    Text("Results are stored on Cloudflare for the \(AppName.display) project "
                         + "and published in its public GitHub repository.")
                        .foregroundStyle(.secondary)
                    Link("Privacy Policy", destination: PrivacyPolicy.url)
                } header: {
                    Text("What is sent")
                }
                Section {
                    DisclosureGroup(reports.count == 1
                                    ? "The report, as it will be sent"
                                    : "The \(reports.count) reports, as they will be sent") {
                        ForEach(reports, id: \.id) { report in
                            if reports.count > 1 {
                                Text("Run \(report.sweep?.index ?? 0)")
                                    .font(.caption.bold())
                            }
                            ScrollView(.horizontal) {
                                Text(payload(report))
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .fixedSize()
                            }
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
                            .disabled(endpoint == nil || reports.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(sending)
        }
    }

    /// One report at a time, stopping at the first that is not stored; a
    /// later Send picks up from there.
    private func send() {
        guard let endpoint else { return }
        sending = true
        problem = nil
        Task {
            defer { sending = false }
            let submission = BenchmarkSubmission(endpoint: endpoint)
            for report in reports where !stored.contains(report.id) {
                do {
                    switch try await submission.send(report) {
                    case .stored:
                        stored.insert(report.id)
                        onSent(report.id, Date())
                        continue
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
                if reports.count > 1, !stored.isEmpty {
                    problem = (problem ?? "") + " \(stored.count) of \(reports.count) "
                        + "runs were sent."
                }
                return
            }
            dismiss()
        }
    }
}
