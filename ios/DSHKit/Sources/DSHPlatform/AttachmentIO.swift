import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

package enum AttachmentIO {
    package static func read(_ url: URL, limit: Int) throws -> (data: Data, size: Int, type: UTType?) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int(clamping: try handle.seekToEnd())
        guard size <= limit else { return (Data(), size, type) }
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        return (data.count <= limit ? data : Data(), data.count, type)
    }

    package static func photo(_ data: Data) -> (jpeg: Data, thumbnail: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        func jpeg(side: Int, quality: Double) -> Data? {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                           kCGImageSourceCreateThumbnailWithTransform: true,
                                           kCGImageSourceThumbnailMaxPixelSize: side]
            let bytes = NSMutableData()
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let output = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            return CGImageDestinationFinalize(output) ? bytes as Data : nil
        }
        guard let full = jpeg(side: 2048, quality: 0.8), let thumbnail = jpeg(side: 240, quality: 0.7) else { return nil }
        return (full, thumbnail)
    }

    package static func parts(of data: Data, size: Int) -> [Data] {
        stride(from: data.startIndex, to: data.endIndex, by: size).map { start in
            data.subdata(in: start..<min(start + size, data.endIndex))
        }
    }

    package static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
}
