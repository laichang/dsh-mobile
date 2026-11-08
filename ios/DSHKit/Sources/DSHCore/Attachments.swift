import CryptoKit
import Foundation

/// Attachments (ARCHITECTURE D95): a photo larger than one Noise message (65535 bytes, D21) goes to
/// the host in parts before the `CreateTask` that names it (protocol/attachments.proto).
public enum Attachments {
    /// Data bytes in one `UploadChunk`. Must match `PART_SIZE` in bridge/src/attachments/staging.ts.
    public static let partSize = 48 * 1024
    /// Largest file the bridge takes (`MAX_UPLOAD_BYTES`).
    public static let maxBytes = 20 * 1024 * 1024

    /// The parts of `data`, in order, each at most `partSize` bytes.
    public static func parts(of data: Data, size: Int = partSize) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { offset in
            let start = data.startIndex + offset
            return data.subdata(in: start..<min(start + size, data.endIndex))
        }
    }

    public static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
}

/// One photo on the composer: the bytes the host gets, and a small thumbnail that stays on the phone.
public struct PhotoAttachment: Sendable, Equatable {
    public var data: Data
    /// `image/jpeg`, `image/png`, `image/webp` or `image/gif` (what DSH takes in a prompt).
    public var mediaType: String
    public var name: String
    /// A small JPEG for the composer chip and the user bubble.
    public var thumbnail: Data

    public init(data: Data, mediaType: String, name: String, thumbnail: Data) {
        self.data = data
        self.mediaType = mediaType
        self.name = name
        self.thumbnail = thumbnail
    }
}
