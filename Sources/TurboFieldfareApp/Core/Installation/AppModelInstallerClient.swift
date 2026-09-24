import Foundation

public protocol AppModelInstallerClient: Sendable {
    var descriptor: AppModelInstallDescriptor { get }
    func checkInstallRequirement(outputDirectory: URL) throws -> AppModelInstallRequirement
    /// `allowsExpensiveNetwork: false` keeps the download off mobile data and
    /// hotspots: it waits for another network rather than failing.
    func installDefaultModel(outputDirectory: URL, allowsExpensiveNetwork: Bool)
        -> AsyncThrowingStream<AppModelInstallEvent, Error>
    func discardPartialInstall(outputDirectory: URL) async throws
    func cancel()
}

extension AppModelInstallerClient {
    /// Any network, as the Mac has always downloaded.
    public func installDefaultModel(outputDirectory: URL)
        -> AsyncThrowingStream<AppModelInstallEvent, Error> {
        installDefaultModel(outputDirectory: outputDirectory, allowsExpensiveNetwork: true)
    }
}
