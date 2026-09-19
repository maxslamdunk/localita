import Foundation
import Testing
@testable import TurboFieldfareAppCore

@Suite struct AppModelInstallationProbeTests {
    @Test func storageMetricsUseMetadataAndExcludeSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-metrics-\(UUID())", isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("abc".utf8).write(to: root.appendingPathComponent("a"))
        try Data("12345".utf8).write(to: nested.appendingPathComponent("b"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias"),
            withDestinationURL: nested.appendingPathComponent("b"))

        let metrics = try AppModelStorageMetrics.measure(at: root)
        #expect(metrics.logicalBytes == 8)
        #expect(metrics.allocatedBytes >= metrics.logicalBytes)
        #expect(metrics.availableBytes != nil)
    }

    @Test func missingDirectoryIsMissing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("turbofieldfare-missing-\(UUID().uuidString).gturbo")
        #expect(AppModelInstallationProbe.status(at: url) == .missing)
    }

    @Test func manifestWithoutFinalMetadataIsPartial() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("turbofieldfare-partial-\(UUID().uuidString).gturbo")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{}".utf8).write(to: url.appendingPathComponent("manifest.json"))
        guard case .partial = AppModelInstallationProbe.status(at: url) else {
            Issue.record("expected partial status")
            return
        }
    }

    @Test func validBoundedMetadataIsComplete() throws {
        let url = try makeCompleteModelInstall("probe")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AppModelInstallationProbe.status(at: url) == .complete)
    }

    @Test func loadFailureFixturePassesProbeButOmitsResidentWeights() throws {
        let output = try makeCompleteModelInstall("load-failure")
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(AppModelInstallationProbe.status(at: output) == .complete)
        #expect(!FileManager.default.fileExists(
            atPath: output.appendingPathComponent("model_weights.bin").path))
    }

    @Test func receiptBoundToDifferentPathIsPartial() throws {
        let url = try makeCompleteModelInstall("wrong-path")
        defer { try? FileManager.default.removeItem(at: url) }
        try bindReceipt(at: url, toPath: "/different/model.gturbo")
        // The argument is explicit rather than defaulted, because the default
        // is now platform-dependent: on iOS the path clause is off, so a test
        // taking the default would assert the opposite thing there. Naming it
        // keeps this test about the strict behaviour on either platform.
        guard case .partial = AppModelInstallationProbe.status(
            at: url, requiringReceiptDirectoryPath: true) else {
            Issue.record("expected partial status")
            return
        }
    }

    /// The iOS behaviour, exercised on macOS.
    ///
    /// This is the defect that reached the phone: a complete 14.3 GB model was
    /// reported as "Model required" because its receipt still named the Mac
    /// directory it had been verified in, and the probe treated that as a
    /// failed install. `swift test` is macOS-only, so without passing the flag
    /// explicitly this behaviour would be asserted nowhere at all.
    @Test func receiptBoundToADifferentPathIsCompleteWhenThePathIsNotBinding() throws {
        let url = try makeCompleteModelInstall("wrong-path-waived")
        defer { try? FileManager.default.removeItem(at: url) }
        try bindReceipt(
            at: url,
            toPath: "/Users/someone/turbo-fieldfare/scratch/gemma4.gturbo")
        #expect(AppModelInstallationProbe.status(
            at: url, requiringReceiptDirectoryPath: false) == .complete)
    }

    /// Literals per platform, for the reason `RuntimeConfigurationTests` gives:
    /// asserting the constant against itself proves nothing.
    @Test func theReceiptPathDefaultFollowsThePlatform() {
        #if os(iOS)
        #expect(AppModelInstallationProbe.receiptBindsDirectoryPath == false)
        #else
        #expect(AppModelInstallationProbe.receiptBindsDirectoryPath == true)
        #endif
    }

    private func bindReceipt(at directory: URL, toPath path: String) throws {
        let receiptURL = directory.appendingPathComponent("verified-install.json")
        var receipt = try JSONSerialization.jsonObject(
            with: Data(contentsOf: receiptURL)) as! [String: Any]
        receipt["modelDirectoryPath"] = path
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            .write(to: receiptURL)
    }

    @Test func differentCheckpointIsPartial() throws {
        let url = try makeCompleteModelInstall("wrong-checkpoint")
        defer { try? FileManager.default.removeItem(at: url) }
        let descriptor = AppModelInstallDescriptor(
            displayName: "different",
            repoID: "example/different",
            revision: "revision",
            sourceIndexSHA256: String(repeating: "f", count: 64),
            approximateDownloadBytes: 1,
            installedBytes: 1,
            rangeStagingBytes: 1,
            reserveBytes: 1)
        guard case .partial = AppModelInstallationProbe.status(at: url, descriptor: descriptor) else {
            Issue.record("expected checkpoint mismatch to be partial")
            return
        }
    }
}
