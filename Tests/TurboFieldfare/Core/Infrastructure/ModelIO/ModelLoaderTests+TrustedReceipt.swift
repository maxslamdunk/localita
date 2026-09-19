import Foundation
import Darwin
import Metal
import Testing

@testable import TurboFieldfare

extension ModelLoaderTests {
  @Test func receiptReaderRejectsFIFOWithoutBlocking() throws {
    let dir = try Self.writeToySynthetic()
    defer { try? FileManager.default.removeItem(at: dir) }
    let receipt = dir.appendingPathComponent(VerifiedInstallReceiptReader.fileName)
    #expect(mkfifo(receipt.path, 0o600) == 0)

    #expect(throws: ModelError.self) {
      _ = try VerifiedInstallReceiptReader.load(directoryURL: dir)
    }
  }

  @Test func trustedReceiptModeRequiresReceipt() throws {
    let dir = try Self.writeToySynthetic()
    defer { try? FileManager.default.removeItem(at: dir) }
    let device = try #require(MTLCreateSystemDefaultDevice())
    #expect {
      _ = try Model.load(
        directoryURL: dir,
        device: device,
        expecting: .gemma4Toy(),
        integrityPolicy: .sizeCheckTrustedReceipt)
    } throws: { error in
      if case ModelError.trustedReceiptInvalid = error { return true }
      return false
    }
  }

  @Test func trustedReceiptReaderRejectsOversizedMetadataBeforeDecode() throws {
    let dir = try Self.writeToySynthetic()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Self.writeVerifiedInstallReceipt(directoryURL: dir)

    #expect {
      _ = try VerifiedInstallReceiptReader.load(directoryURL: dir, maxBytes: 16)
    } throws: { error in
      if case ModelError.trustedReceiptInvalid(let detail) = error {
        return detail.contains("metadata cap")
      }
      return false
    }
  }

  @Test func trustedReceiptModeSkipsSameSizeLayerShaMismatch() throws {
    let dir = try Self.writeToySynthetic()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Self.writeVerifiedInstallReceipt(directoryURL: dir)
    let layerURL =
      dir
      .appendingPathComponent("packed_experts")
      .appendingPathComponent("layer_00.bin")
    try Self.flipByte(in: layerURL, at: 64)
    let device = try #require(MTLCreateSystemDefaultDevice())

    #expect {
      let defaultModel = try Model.load(
        directoryURL: dir,
        device: device,
        expecting: .gemma4Toy())
      _ = try defaultModel.routedExpert(layer: 0, expert: 0)
    } throws: { error in
      if case ModelError.checksumMismatch = error { return true }
      return false
    }

    let trustedModel = try Model.load(
      directoryURL: dir,
      device: device,
      expecting: .gemma4Toy(),
      integrityPolicy: .sizeCheckTrustedReceipt)
    _ = try trustedModel.routedExpert(layer: 0, expert: 0)
  }

  @Test func trustedReceiptModeRejectsWrongSizedLayerFile() throws {
    let dir = try Self.writeToySynthetic()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Self.writeVerifiedInstallReceipt(directoryURL: dir)
    let layerURL =
      dir
      .appendingPathComponent("packed_experts")
      .appendingPathComponent("layer_00.bin")
    let handle = try FileHandle(forWritingTo: layerURL)
    try handle.truncate(atOffset: 1024)
    try handle.close()

    let device = try #require(MTLCreateSystemDefaultDevice())
    #expect {
      _ = try Model.load(
        directoryURL: dir,
        device: device,
        expecting: .gemma4Toy(),
        integrityPolicy: .sizeCheckTrustedReceipt)
    } throws: { error in
      if case ModelError.trustedReceiptInvalid = error { return true }
      return false
    }
  }

  @Test func trustedReceiptModeReportsReceiptValidationTiming() throws {
    let dir = try Self.writeToySynthetic()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Self.writeVerifiedInstallReceipt(directoryURL: dir)
    let device = try #require(MTLCreateSystemDefaultDevice())
    var stats = ModelLoadStats()
    _ = try Model.load(
      directoryURL: dir,
      device: device,
      expecting: .gemma4Toy(),
      integrityPolicy: .sizeCheckTrustedReceipt,
      loadStats: &stats)
    #expect(stats.manifestSha256Nanos > 0)
    #expect(stats.receiptValidationNanos > 0)
    #expect(stats.eagerSha256Nanos > 0)
  }

  @Test func trustedReceiptModeRejectsExtraReceiptFileEntry() throws {
    let dir = try Self.writeToySynthetic()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Self.writeVerifiedInstallReceipt(directoryURL: dir)
    try Self.mutateReceipt(directoryURL: dir) { root in
      var files = root["files"] as! [String: Any]
      files["unexpected.bin"] = ["size": 0, "sha256": String(repeating: "0", count: 64)]
      root["files"] = files
    }
    let device = try #require(MTLCreateSystemDefaultDevice())
    #expect {
      _ = try Model.load(
        directoryURL: dir,
        device: device,
        expecting: .gemma4Toy(),
        integrityPolicy: .sizeCheckTrustedReceipt)
    } throws: { error in
      if case ModelError.trustedReceiptInvalid = error { return true }
      return false
    }
  }

  @Test func trustedReceiptModeRejectsMissingReceiptFileEntry() throws {
    let dir = try Self.writeToySynthetic()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Self.writeVerifiedInstallReceipt(directoryURL: dir)
    try Self.mutateReceipt(directoryURL: dir) { root in
      var files = root["files"] as! [String: Any]
      files.removeValue(forKey: "packed_experts/layer_00.bin")
      root["files"] = files
    }
    let device = try #require(MTLCreateSystemDefaultDevice())
    #expect {
      _ = try Model.load(
        directoryURL: dir,
        device: device,
        expecting: .gemma4Toy(),
        integrityPolicy: .sizeCheckTrustedReceipt)
    } throws: { error in
      if case ModelError.trustedReceiptInvalid(let detail) = error {
        return detail.contains("file set mismatch")
          && detail.contains("packed_experts/layer_00.bin")
      }
      return false
    }
  }

  @Test func trustedReceiptModeRejectsStaleManifestBindingBeforeManifestTrust() throws {
    let dir = try Self.writeToySynthetic()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Self.writeVerifiedInstallReceipt(directoryURL: dir)
    try Self.mutateReceipt(directoryURL: dir) { root in
      root["manifestSha256"] = String(repeating: "0", count: 64)
      var files = root["files"] as! [String: Any]
      files["manifest.json"] = [
        "size": (files["manifest.json"] as! [String: Any])["size"]!,
        "sha256": String(repeating: "0", count: 64),
      ]
      root["files"] = files
    }
    let device = try #require(MTLCreateSystemDefaultDevice())
    #expect {
      _ = try Model.load(
        directoryURL: dir,
        device: device,
        expecting: .gemma4Toy(),
        integrityPolicy: .sizeCheckTrustedReceipt)
    } throws: { error in
      if case ModelError.trustedReceiptInvalid(let detail) = error {
        return detail.contains("manifest SHA mismatch")
      }
      return false
    }
  }

  /// Waiving the directory path must not waive anything else.
  ///
  /// A receipt states both *which* bytes were verified (schema, manifest
  /// digest) and *where* they were. Only the second is environment-specific,
  /// and on iOS it cannot hold at all: the OS renames an app's data container
  /// on every install, so the recorded path is stale by construction. Leaving
  /// the clause enabled reported a complete, fully present model as missing.
  /// These three expectations pin the relaxation as a narrowing rather than a
  /// hole — no fixture or Metal device needed, since the receipt is a value.
  @Test func manifestBindingCanWaiveTheDirectoryPathWithoutWaivingContent() throws {
    let manifestSha = String(repeating: "a", count: 64)
    let receipt = VerifiedInstallReceipt(
      manifestSha256: manifestSha,
      modelDirectoryPath: "/Users/someone/turbo-fieldfare/scratch/gemma4.gturbo",
      verificationTimestamp: "2026-09-18T00:00:00Z",
      toolVersion: "ModelLoaderTests",
      files: [:])
    let live = URL(
      fileURLWithPath:
        "/var/mobile/Containers/Data/Application/1C5CF722/Library/Application Support"
        + "/TurboFieldfare/gemma4.gturbo")

    // Waived: a different path is accepted.
    try VerifiedInstallReceiptReader.validateManifestBinding(
      receipt, directoryURL: live, manifestSha256: manifestSha,
      requiringDirectoryPath: false)

    // Still enforced by default, which is what every macOS caller gets.
    #expect {
      try VerifiedInstallReceiptReader.validateManifestBinding(
        receipt, directoryURL: live, manifestSha256: manifestSha)
    } throws: { error in
      if case ModelError.trustedReceiptInvalid(let detail) = error {
        return detail.contains("model directory mismatch")
      }
      return false
    }

    // And waiving the path does not waive the digest.
    #expect {
      try VerifiedInstallReceiptReader.validateManifestBinding(
        receipt, directoryURL: live,
        manifestSha256: String(repeating: "b", count: 64),
        requiringDirectoryPath: false)
    } throws: { error in
      if case ModelError.trustedReceiptInvalid(let detail) = error {
        return detail.contains("manifest SHA mismatch")
      }
      return false
    }
  }

  @Test func trustedReceiptModeRejectsDifferentModelDirectoryBinding() throws {
    let dir = try Self.writeToySynthetic()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Self.writeVerifiedInstallReceipt(directoryURL: dir)
    try Self.mutateReceipt(directoryURL: dir) { root in
      root["modelDirectoryPath"] =
        dir
        .deletingLastPathComponent()
        .appendingPathComponent("other.gturbo")
        .standardizedFileURL
        .path
    }
    let device = try #require(MTLCreateSystemDefaultDevice())
    #expect {
      _ = try Model.load(
        directoryURL: dir,
        device: device,
        expecting: .gemma4Toy(),
        integrityPolicy: .sizeCheckTrustedReceipt)
    } throws: { error in
      if case ModelError.trustedReceiptInvalid(let detail) = error {
        return detail.contains("model directory mismatch")
      }
      return false
    }
  }

}
