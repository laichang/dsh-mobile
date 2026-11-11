import CryptoKit
import DSHProtocol
import Foundation

/// Attachments: a file larger than one Noise message (65535 bytes)
/// goes to the host in parts before the `CreateTask` or `SendMessage` that names it
/// (protocol/attachments.proto).
public enum Attachments {
    /// Data bytes in one `UploadChunk`. Must match `PART_SIZE` in bridge/src/attachments/staging.ts.
    public static let partSize = 48 * 1024
    /// Largest file the bridge takes (`MAX_UPLOAD_BYTES`). The app refuses a larger file before the upload.
    public static let maxBytes = 20 * 1024 * 1024
    /// Attachments in one message (`MAX_UPLOADS_PER_CONNECTION`).
    public static let maxCount = 5
    /// The image types DSH takes in a prompt; any other file goes as a file part.
    public static let imageMediaTypes: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/gif"]

    public static func isImage(_ mediaType: String) -> Bool { imageMediaTypes.contains(mediaType.lowercased()) }

    /// The parts of `data`, in order, each at most `partSize` bytes.
    public static func parts(of data: Data, size: Int = partSize) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { offset in
            let start = data.startIndex + offset
            return data.subdata(in: start..<min(start + size, data.endIndex))
        }
    }

    public static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// "20 MB", "340 KB", "12 B" for a chip.
    public static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// How an attachment enters the prompt: an image the model sees, or a file it reads from a saved path.
public enum AttachmentKind: String, Codable, Sendable {
    case image, file
}

/// One file on a composer: the bytes the host gets, and a small thumbnail of an image that stays
/// on the phone.
public struct FileAttachment: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var data: Data
    /// Any media type. `image/jpeg`, `image/png`, `image/webp` and `image/gif` enter as images.
    public var mediaType: String
    public var name: String
    /// A small JPEG for the chip and the user bubble; nil for a file.
    public var thumbnail: Data?
    /// The file's size: `data.count`, or the size on disk of a file too large to read.
    public var size: Int

    /// - Parameter size: only for a file over the limit, whose bytes the app does not read (`data` empty).
    public init(id: UUID = UUID(), data: Data, mediaType: String, name: String, thumbnail: Data? = nil, size: Int? = nil) {
        self.id = id
        self.data = data
        self.mediaType = mediaType
        self.name = name
        self.thumbnail = thumbnail
        self.size = size ?? data.count
    }

    public var kind: AttachmentKind { Attachments.isImage(mediaType) ? .image : .file }

    /// Over `Attachments.maxBytes`: refused before the upload.
    public var isTooLarge: Bool { size > Attachments.maxBytes }

    /// What the sent message shows for it.
    public var sent: MessageAttachment {
        MessageAttachment(kind: kind, name: name, size: size, mediaType: mediaType, thumbnail: thumbnail)
    }
}

/// One attachment of a user message, as the transcript shows it: a chip with its name, or the
/// thumbnail of an image on the phone that sent it. The host keeps the bytes.
public struct MessageAttachment: Codable, Equatable, Sendable {
    public var kind: AttachmentKind
    public var name: String
    public var size: Int
    /// Empty when the host does not know it (a file from the DSH journal).
    public var mediaType: String
    /// A small JPEG, only on the phone that sent the image.
    public var thumbnail: Data?

    public init(kind: AttachmentKind, name: String, size: Int, mediaType: String = "", thumbnail: Data? = nil) {
        self.kind = kind
        self.name = name
        self.size = size
        self.mediaType = mediaType
        self.thumbnail = thumbnail
    }

    package init(_ wire: Dshm_V1_AttachmentRef) {
        self.init(kind: wire.kind == .image ? .image : .file, name: wire.name, size: Int(clamping: wire.size),
                  mediaType: wire.mediaType)
    }

    /// The file's extension in capitals ("PDF", "TXT"), or nil.
    public var typeLabel: String? {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? nil : ext.uppercased()
    }
}

extension Array where Element == MessageAttachment {
    /// The phone's own copy (with thumbnails) where it matches the host's list, else the host's.
    public func keepingThumbnails(of local: [MessageAttachment]?) -> [MessageAttachment] {
        guard let local, local.count == count else { return self }
        return zip(self, local).map { wire, mine in
            var merged = wire
            if wire.kind == mine.kind { merged.thumbnail = mine.thumbnail }
            return merged
        }
    }
}
