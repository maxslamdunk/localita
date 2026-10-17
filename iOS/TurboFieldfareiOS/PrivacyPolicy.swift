import Foundation

/// The app's privacy policy, served by the benchmark results Worker
/// (`server/benchmark-worker/src/privacy.ts`). The App Store listing names the
/// same address, so it stays fixed.
enum PrivacyPolicy {
    static let url = URL(string: "https://localita.maxslamdunk.workers.dev/privacy")!
}
