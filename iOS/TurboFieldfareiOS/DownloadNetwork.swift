import Network
import Observation

/// What the phone's downloads need to know that `AppModel` does not track:
/// which network the phone is on, whether the user agreed to mobile data, and
/// which downloads the app paused itself when it was sent to the background.
@MainActor
@Observable
final class DownloadNetwork {
    /// Mobile data, or a hotspot: what iOS calls expensive.
    private(set) var isExpensive = false
    private(set) var isSatisfied = true

    /// The user's answer to "download over mobile data?", for this launch.
    /// Never assumed: every download starts Wi-Fi-only unless this is set.
    var allowsMobileData = false

    /// Set when leaving the app paused a download, so that coming back
    /// resumes it. A download the user cancelled stays cancelled.
    var resumesModelOnReturn = false
    var resumesImageSupportOnReturn = false

    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.isExpensive = expensive
                self?.isSatisfied = satisfied
            }
        }
        monitor.start(queue: .main)
    }

    /// What a paused download is waiting for, if it is waiting at all.
    var waitingReason: String? {
        if !isSatisfied { return "Waiting for a network connection." }
        if isExpensive && !allowsMobileData {
            return "Waiting for Wi-Fi. The download continues when the phone joins one."
        }
        return nil
    }
}
