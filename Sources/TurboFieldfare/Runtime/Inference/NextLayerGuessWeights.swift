import Darwin
import Foundation
import Metal

/// The fitted next-layer guess for `NextLayerExpertPrefetcher`, mapped
/// read-only from the file `fit_guess.py` writes. For each target layer
/// 1..numLayers-1 it holds one router-shaped matrix: that layer's router plus
/// a ridge correction fitted offline, already multiplied by the effective
/// scale. It is stored in the router's own 8-bit affine format, so
/// `router_gemv_gemma4_r4` runs it unchanged with `unitScale` as the
/// effective scale. See
/// `benchmark-results-2026-10-03-ios-fitted-guess/predictions.md`.
///
/// Layout, little-endian: a 64-byte header (8-byte magic `TFNLG1\0\0`, then
/// UInt32 numLayers, numExperts, hiddenSize, groupSize, firstTargetLayer,
/// targetLayerCount), then per target layer UInt8 weights [E][D], BF16
/// scales [E][D/64] and BF16 biases [E][D/64].
final class NextLayerGuessWeights {
    static let environmentKey = "TURBO_FIELDFARE_EARLY_EXPERT_GUESS"
    static let magic: [UInt8] = Array("TFNLG1".utf8) + [0, 0]
    static let headerBytes = 64

    struct Matrix {
        let weightsOffset: Int
        let scalesOffset: Int
        let biasesOffset: Int
    }

    /// The whole mapped file; `Matrix` offsets index into it.
    let buffer: MTLBuffer
    /// `hiddenSize` BF16 ones, the effective scale the guess runs with.
    let unitScale: MTLBuffer
    private let numLayers: Int
    private let weightBytes: Int
    private let groupBytes: Int

    init(fileURL: URL, numLayers: Int, numExperts: Int, hiddenSize: Int,
         device: MTLDevice) throws {
        let groups = hiddenSize / Quantization.groupSize
        weightBytes = numExperts * hiddenSize
        groupBytes = numExperts * groups * MemoryLayout<UInt16>.size
        let expectedSize = Self.headerBytes
            + (numLayers - 1) * (weightBytes + 2 * groupBytes)

        var info = stat()
        guard stat(fileURL.path, &info) == 0 else {
            throw ModelError.posixFailed(call: "stat(\(fileURL.path))", errno: errno)
        }
        guard Int(info.st_size) == expectedSize else {
            throw ModelError.indexCorrupt(detail: "next-layer guess file is \(info.st_size) "
                + "bytes, expected \(expectedSize)")
        }
        // The buffer's deallocator unmaps the file.
        buffer = try ResidentBuffer(fileURL: fileURL, fileOffset: 0,
                                    residentSize: UInt64(expectedSize), device: device).buffer

        let header = UnsafeRawBufferPointer(start: buffer.contents(), count: Self.headerBytes)
        let fields = (0..<6).map {
            UInt32(littleEndian: header.loadUnaligned(fromByteOffset: 8 + 4 * $0,
                                                      as: UInt32.self))
        }
        let expected = [numLayers, numExperts, hiddenSize, Quantization.groupSize,
                        1, numLayers - 1].map(UInt32.init)
        guard Array(header.prefix(8)) == Self.magic, fields == expected else {
            throw ModelError.indexCorrupt(detail: "next-layer guess header \(fields) does not "
                + "match this model \(expected)")
        }
        self.numLayers = numLayers

        guard let ones = device.makeBuffer(length: hiddenSize * MemoryLayout<UInt16>.size,
                                           options: .storageModeShared) else {
            throw MetalError.noDevice
        }
        let one = Quantization.bf16Bits(1)
        ones.contents().initializeMemory(as: UInt16.self, repeating: one, count: hiddenSize)
        unitScale = ones
    }

    /// The guess matrix that scores `targetLayer`'s experts, 1..numLayers-1.
    func matrix(targetLayer: Int) -> Matrix {
        precondition(targetLayer >= 1 && targetLayer < numLayers)
        let start = Self.headerBytes + (targetLayer - 1) * (weightBytes + 2 * groupBytes)
        return Matrix(weightsOffset: start,
                      scalesOffset: start + weightBytes,
                      biasesOffset: start + weightBytes + groupBytes)
    }
}
