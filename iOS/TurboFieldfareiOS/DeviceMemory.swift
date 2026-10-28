import Foundation

/// Whether this iPhone has less memory than the one phone the app has been
/// tested on, said beside the download so nobody spends 15 GB to find out.
///
/// Every measurement is from an iPhone 17, 8 GB, which reports 8,044,216,320
/// bytes (`benchmark-submissions/`). There the app rests at about 3.3 GB and is
/// killed from about 5.6 GB (`AGENTS.md`, the memory ceiling). What a 6 GB
/// phone allows is unmeasured, so it gets a warning, not a refusal. Fewer
/// expert slots should fit: each 8 per layer is about 0.8 GB, and 16 is the
/// fewest that Settings offers and chunked prefill accepts.
enum DeviceMemory {
    static let bytes = ProcessInfo.processInfo.physicalMemory

    /// Below every 8 GB iPhone and above every 6 GB one.
    static let isBelowTested = bytes < 7_000_000_000

    static var warning: String? {
        guard isBelowTested else { return nil }
        let gigabytes = Int((Double(bytes) / 1e9).rounded())
        return "This iPhone has \(gigabytes) GB of memory. \(AppName.display) has only "
            + "been tested on an iPhone with 8 GB, so nobody knows yet whether the "
            + "model runs here. It may, more slowly: if it doesn't load, try 16 "
            + "expert slots in Settings › Memory."
    }
}
