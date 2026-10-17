import BackgroundTasks
import Foundation
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation
import UIKit
import UserNotifications
import os

/// Keeps a model download running after the app leaves the screen, and says
/// so when it stops.
///
/// Built on iOS 26's continued-processing task: the download the user
/// starts is wrapped in a `BGContinuedProcessingTask`, which keeps the process
/// running in the background and shows the progress in a system Live Activity
/// (Lock Screen and Dynamic Island) with a Stop button. The installer itself is
/// unchanged; it still writes a checkpoint after every 64 MiB range.
///
/// On the iPhone 17 (2026-10-07) the task kept downloading with the app in the
/// background, with other apps in use, and on a locked phone. iOS ended it
/// about 25 s after the phone left Wi-Fi, since bytes stopped arriving, and it
/// ends it when the app is swiped away. It can also end it at any other time
/// (heat, load, the Stop button), and it can only be started while the app is
/// open, so three things cover a stop:
/// - **A notification.** One "download stopped" notification is always kept
///   about two minutes ahead and pushed back while bytes arrive. If the
///   download stops for any reason, including the app being swiped away,
///   which the app is never told about, it goes off by itself.
/// - **Automatic resume.** The download the user asked for is remembered
///   across launches until it finishes or is cancelled, and opening the app
///   resumes it from its checkpoint.
/// - **A log.** Every event goes to `Documents/download-background.log`, so a
///   test on the phone can be read back afterwards.
@MainActor
enum BackgroundDownload {
    static let log = Logger(subsystem: "TurboFieldfare", category: "download")

    /// The folder whose download was asked for and has neither finished nor
    /// been cancelled. Kept across launches, which is what lets a download that
    /// iOS stopped, or that died with the app, resume when the app opens.
    private static let intentKey = "downloadIntentFolder"
    private static let notificationID = "model-download-status"
    /// How long without progress before the notification fires on its own.
    private static let watchdogDelay: TimeInterval = 120
    /// The task's progress is reported in these units; the download is 98% of
    /// them, and verifying the written files the rest, so that the last phase
    /// also shows movement and the task is not marked stalled.
    private static let progressUnits: Int64 = 10_000

    private static var task: BGContinuedProcessingTask?
    private static var pendingRequestID: String?
    private static var monitor: Task<Void, Never>?
    /// The last progress seen, for the notifications: once the download has
    /// paused, the model no longer reports a fraction.
    private static var lastFraction: Double?

    /// Whether the background task is keeping the download alive, in which
    /// case leaving the app must not pause it.
    static var keepsDownloadRunning: Bool { task != nil }

    // MARK: - Starting, stopping, resuming

    /// The Download button. A person's tap is what iOS requires before it
    /// accepts a continued-processing task.
    static func start(_ model: AppModel, network: DownloadNetwork, allowingMobileData: Bool) {
        network.allowsMobileData = allowingMobileData
        UserDefaults.standard.set(ModelLocation.folderName, forKey: intentKey)
        requestNotificationPermission()
        record("start requested (mobile data \(allowingMobileData ? "allowed" : "not allowed"))")
        begin(model, network: network)
    }

    /// A model's files were deleted: a download still wanted for its folder
    /// is dropped with them.
    static func forget(folder: String) {
        if UserDefaults.standard.string(forKey: intentKey) == folder {
            UserDefaults.standard.removeObject(forKey: intentKey)
        }
    }

    /// The Cancel button: stop and stay stopped.
    static func cancel(_ model: AppModel) {
        UserDefaults.standard.removeObject(forKey: intentKey)
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [notificationID])
        record("cancelled by the user")
        model.cancelInstall()
    }

    /// The Discard button: what was downloaded is removed, and nothing resumes.
    static func discard(_ model: AppModel) {
        UserDefaults.standard.removeObject(forKey: intentKey)
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [notificationID])
        record("discarded by the user")
        model.discardModelDownload()
    }

    /// Resumes a download that was asked for and is not running: after iOS
    /// stopped it, after the app was killed, or after leaving the app paused
    /// it. Called whenever the app comes to the front, including at launch.
    static func resumeIfWanted(_ model: AppModel, network: DownloadNetwork) {
        guard wantsDownload(model) else { return }
        Task {
            // A pause requested on the way out may still be landing; starting
            // over a cancelling install is refused.
            let deadline = ContinuousClock.now + .seconds(30)
            while model.isInstallingModel && ContinuousClock.now < deadline {
                if task != nil || monitor != nil { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard wantsDownload(model), !model.isInstallingModel,
                  UIApplication.shared.applicationState == .active else { return }
            record("resuming on return to the app")
            begin(model, network: network)
        }
    }

    private static func begin(_ model: AppModel, network: DownloadNetwork) {
        if !model.isInstallingModel {
            model.installModel(allowsExpensiveNetwork: network.allowsMobileData)
        }
        guard model.isInstallingModel else {
            record("installer did not start: \(model.installPhaseLabel), "
                   + "readiness \(String(describing: model.installReadiness))")
            return
        }
        submit(model, network: network)
        watch(model, network: network)
    }

    private static func wantsDownload(_ model: AppModel) -> Bool {
        UserDefaults.standard.string(forKey: intentKey) == ModelLocation.folderName
            && model.requiresModelInstallation
    }

    // MARK: - The continued-processing task

    private static func submit(_ model: AppModel, network: DownloadNetwork) {
        guard task == nil, pendingRequestID == nil else { return }
        // Each request gets its own identifier under the wildcard in
        // Info.plist, registered right before it is submitted. Registering the
        // wildcard itself does not match unique identifiers (FB, Apple forums
        // thread 799126).
        let prefix = Bundle.main.bundleIdentifier ?? "io.github.maxslamdunk.TurboFieldfareiOS"
        let identifier = prefix + ".download." + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: .main
        ) { launched in
            MainActor.assumeIsolated {
                guard let launched = launched as? BGContinuedProcessingTask else {
                    launched.setTaskCompleted(success: false)
                    return
                }
                attach(launched, model: model, network: network)
            }
        }
        guard registered else {
            record("task handler not registered")
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title(model),
            subtitle: subtitle(model, network: network))
        // Queued rather than refused when the system has no room right now; it
        // then starts the task as soon as it can.
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            pendingRequestID = identifier
            record("task submitted")
        } catch {
            record("task submit failed: \(error)")
        }
    }

    private static func attach(_ launched: BGContinuedProcessingTask,
                               model: AppModel, network: DownloadNetwork) {
        pendingRequestID = nil
        task = launched
        record("task started (app \(stateName))")
        launched.progress.totalUnitCount = progressUnits
        launched.expirationHandler = {
            Task { @MainActor in expire(model: model, network: network) }
        }
        // Started from the queue later: the download may have stopped by then.
        if !model.isInstallingModel, wantsDownload(model) {
            model.installModel(allowsExpensiveNetwork: network.allowsMobileData)
        }
        guard model.isInstallingModel else {
            finishTask(success: model.isModelInstalled)
            return
        }
        watch(model, network: network)
    }

    /// iOS ended the task, or the person tapped Stop in the Live Activity;
    /// the app cannot tell which. Pause at the checkpoint, say so, and resume
    /// on the next return to the app.
    private static func expire(model: AppModel, network: DownloadNetwork) {
        record("task expired at \(percentText(model)) (app \(stateName), "
               + "network \(networkName(network)))")
        if model.isInstallingModel && model.canCancelInstall {
            network.resumesModelOnReturn = true
            model.cancelInstall()
        }
        let notice = stopNotice(model, network: network)
        notify(title: notice.title, body: notice.body, after: nil)
        finishUnfinished(model)
        // Let the cancellation reach its checkpoint before iOS suspends us.
        let window = BackgroundWindow()
        window.id = UIApplication.shared.beginBackgroundTask(withName: "Pause download") {
            window.end()
        }
        Task {
            let deadline = ContinuousClock.now + .seconds(20)
            while model.isInstallingModel && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            window.end()
        }
    }

    private final class BackgroundWindow {
        var id = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    private static func finishTask(success: Bool) {
        if let task {
            task.setTaskCompleted(success: success)
            record("task completed (\(success ? "success" : "not finished"))")
        }
        task = nil
        if let pendingRequestID {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: pendingRequestID)
        }
        pendingRequestID = nil
    }

    // MARK: - Progress, watchdog, end

    /// Runs while the download does, in the foreground and the background:
    /// reports progress to the task, keeps the stop notification ahead, and
    /// settles everything when the download ends.
    private static func watch(_ model: AppModel, network: DownloadNetwork) {
        guard monitor == nil else { return }
        monitor = Task {
            var units: Int64 = 0
            var lastUnits: Int64 = -1
            var hashedFiles: Set<String> = []
            var lastWatchdog = ContinuousClock.now - .seconds(3_600)
            var lastSubtitle = ContinuousClock.now - .seconds(3_600)
            var lastLoggedGB: UInt64 = 0
            var lastNetwork = networkName(network)
            while !Task.isCancelled && model.isInstallingModel {
                switch model.installState {
                case .copyingPayload:
                    let fraction = model.installProgressFraction ?? 0
                    lastFraction = fraction
                    units = max(units, Int64(fraction * Double(progressUnits) * 0.98))
                    let gb = (model.installDownloadedBytes ?? 0) / 1_000_000_000
                    if gb > lastLoggedGB {
                        lastLoggedGB = gb
                        record("\(gb) GB (app \(stateName), "
                               + "task \(task == nil ? "none" : "running"))")
                    }
                case .hashingOutput(let file):
                    hashedFiles.insert(file)
                    units = max(units, progressUnits * 98 / 100 + Int64(hashedFiles.count))
                case .finalizing:
                    units = max(units, progressUnits - 1)
                default:
                    break
                }
                let now = ContinuousClock.now
                if let task {
                    task.progress.completedUnitCount = units
                    if now - lastSubtitle >= .seconds(3) {
                        task.updateTitle(title(model),
                                         subtitle: subtitle(model, network: network))
                        lastSubtitle = now
                    }
                }
                // The pending notification is re-worded as soon as the network
                // changes, so a download that stalls waiting for Wi-Fi says so.
                let currentNetwork = networkName(network)
                let networkChanged = currentNetwork != lastNetwork
                if networkChanged {
                    record("network: \(currentNetwork) (app \(stateName))")
                    lastNetwork = currentNetwork
                }
                if networkChanged
                    || (units != lastUnits && now - lastWatchdog >= .seconds(15)) {
                    let notice = stopNotice(model, network: network)
                    notify(title: notice.title, body: notice.body, after: watchdogDelay)
                    lastWatchdog = now
                }
                lastUnits = units
                try? await Task.sleep(for: .seconds(1))
            }
            monitor = nil
            ended(model)
        }
    }

    private static func ended(_ model: AppModel) {
        if model.isModelInstalled {
            UserDefaults.standard.removeObject(forKey: intentKey)
            lastFraction = nil
            record("installed")
            notify(title: "Model ready",
                   body: "\(model.installDescriptor.shortName) is downloaded and verified.",
                   after: nil)
            finishTask(success: true)
            return
        }
        guard wantsDownload(model) else {
            // Cancelled or discarded by the person: what they asked for was
            // done, so the task ends as completed. Ended as failed, iOS would
            // show "Task Failed" for a choice they made.
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: [notificationID])
            finishTask(success: true)
            return
        }
        switch model.installState {
        case .failed(let message), .recoverable(let message):
            record("stopped with an error: \(message)")
            notify(title: "Download stopped",
                   body: "\(model.installDescriptor.shortName) stopped at "
                       + "\(percentText(model)): \(message). Open \(AppName.display) to retry.",
                   after: nil)
        default:
            // Paused at a checkpoint. The pending notification fires if the
            // app does not come back to resume it within the delay.
            record("paused: \(model.installPhaseLabel) (app \(stateName))")
        }
        finishUnfinished(model)
    }

    /// Ends a task whose download has not finished. iOS then shows its own
    /// "Task Failed" under the title, and no app can change that line
    /// (Apple forums thread 815830); the title above it can still be set, so
    /// it says the download is only paused and how to continue it.
    private static func finishUnfinished(_ model: AppModel) {
        task?.updateTitle(
            "\(model.installDescriptor.shortName) paused at \(percentText(model)) · "
                + "open the app to continue",
            subtitle: "Nothing downloaded is lost")
        finishTask(success: false)
    }

    // MARK: - Text

    private static func title(_ model: AppModel) -> String {
        "Downloading \(model.installDescriptor.shortName)"
    }

    private static func subtitle(_ model: AppModel, network: DownloadNetwork) -> String {
        let progress: String
        if let done = model.installDownloadedBytes, let total = model.installTotalBytes {
            progress = "\(MetricFormat.storage(done)) of \(MetricFormat.storage(total))"
        } else {
            progress = model.installPhaseLabel
        }
        if !network.isSatisfied { return "No connection · " + progress }
        if waitsForWiFi(network) { return "Waiting for Wi-Fi · " + progress }
        return progress
    }

    /// What a stop notification says, worded by why the download is likely
    /// to have stopped: no network at all, or only mobile data, which this
    /// download may not use.
    private static func stopNotice(_ model: AppModel,
                                   network: DownloadNetwork) -> (title: String, body: String) {
        let name = model.installDescriptor.shortName
        let at = percentText(model)
        let kept = "nothing downloaded is lost."
        if !network.isSatisfied {
            return ("Download waiting for a connection",
                    "\(name) paused at \(at): the iPhone has no internet connection. "
                        + "Open \(AppName.display) once it is back to continue; " + kept)
        }
        if waitsForWiFi(network) {
            return ("Download waiting for Wi-Fi",
                    "\(name) paused at \(at) when the iPhone left Wi-Fi; it does not "
                        + "use mobile data. Open \(AppName.display) on Wi-Fi to continue; " + kept)
        }
        return ("Download paused",
                "\(name) paused at \(at). Open \(AppName.display) to continue; " + kept)
    }

    private static func waitsForWiFi(_ network: DownloadNetwork) -> Bool {
        network.isExpensive && !network.allowsMobileData
    }

    private static func networkName(_ network: DownloadNetwork) -> String {
        if !network.isSatisfied { return "none" }
        if network.isExpensive {
            return network.allowsMobileData ? "mobile data (allowed)" : "mobile data (not allowed)"
        }
        return "Wi-Fi"
    }

    private static func percentText(_ model: AppModel) -> String {
        guard let fraction = model.installProgressFraction ?? lastFraction else {
            return "the start"
        }
        return MetricFormat.percent(fraction * 100)
    }

    private static var stateName: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    // MARK: - Notifications

    private static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, error in
            let text = "notifications \(granted ? "allowed" : "not allowed")"
                + (error.map { ": \($0)" } ?? "")
            Task { @MainActor in record(text) }
        }
    }

    /// One notification at a time: each call replaces the pending one.
    /// `after: nil` delivers it now.
    private static func notify(title: String, body: String, after delay: TimeInterval?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = delay.map {
            UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false)
        }
        let request = UNNotificationRequest(identifier: notificationID,
                                            content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            let text = "notification not scheduled: \(error)"
            Task { @MainActor in record(text) }
        }
    }

    // MARK: - Log

    private static let logURL = FileManager.default.urls(for: .documentDirectory,
                                                         in: .userDomainMask)[0]
        .appendingPathComponent("download-background.log")

    private static func record(_ message: String) {
        log.info("\(message, privacy: .public)")
        let line = Date.now.formatted(.iso8601) + " " + message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}
