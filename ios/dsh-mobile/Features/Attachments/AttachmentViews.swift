import DSHCore
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The "+" key on a composer (STORY §7, phone as context; ARCHITECTURE D95, D107), as in the
/// Claude and Codex apps: a menu with the photo library, the camera and files. Each pick adds one
/// chip at the end; a composer holds at most `Attachments.maxCount` files.
struct AttachMenu: View {
    let store: TaskListStore
    let target: AttachTarget
    var disabled = false
    @State private var choosingPhoto = false
    @State private var takingPhoto = false
    @State private var choosingFile = false
    @State private var photo: PhotosPickerItem?
    @State private var loading = false

    private var full: Bool { store.attachments(on: target).count >= Attachments.maxCount }

    var body: some View {
        Menu {
            Button { choosingPhoto = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                .accessibilityIdentifier("attach.photos")
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { takingPhoto = true } label: { Label("Camera", systemImage: "camera") }
                    .accessibilityIdentifier("attach.camera")
            }
            Button { choosingFile = true } label: { Label("Files", systemImage: "folder") }
                .accessibilityIdentifier("attach.files")
        } label: {
            Group {
                if loading { ProgressView().tint(DSHTheme.textSecondary) }
                else { Image(systemName: "plus").font(.body.weight(.semibold)) }
            }
            .foregroundStyle(DSHTheme.textSecondary)
            .frame(width: 40, height: 40)
            .background(Color.white.opacity(0.08), in: .circle)
        }
        .disabled(disabled || full || loading)
        .dismissesKeyboardBeforeMenu() // D67
        .accessibilityLabel("Attach")
        .accessibilityIdentifier(target == .composer ? "composer.attach" : "session.attach")
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images, photoLibrary: .shared())
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            load { AttachmentReader.file(at: url) }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { data in load { PhotoTranscoder.attachment(from: data) } }
                .ignoresSafeArea()
        }
        .onChange(of: photo) { _, picked in
            guard let picked else { return }
            photo = nil
            loading = true
            Task {
                let data = try? await picked.loadTransferable(type: Data.self)
                loading = false
                if let file = data.flatMap({ PhotoTranscoder.attachment(from: $0) }) { store.attach(file, to: target) }
            }
        }
    }

    private func load(_ read: @escaping @Sendable () -> FileAttachment?) {
        loading = true
        Task {
            let file = await Task.detached(priority: .userInitiated) { read() }.value
            loading = false
            if let file { store.attach(file, to: target) }
        }
    }
}

/// The files on a composer, in order: one chip each, with its upload progress or its error, and
/// a key that removes it.
struct AttachmentChips: View {
    let store: TaskListStore
    let target: AttachTarget
    var disabled = false

    var body: some View {
        let list = store.attachments(on: target)
        if !list.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(list) { item in
                        AttachmentChip(item: item, disabled: disabled) { store.removeAttachment(item.id, from: target) }
                    }
                }
                .padding(.top, 8)
                .padding(.trailing, 8)
            }
            .scrollClipDisabled()
            .accessibilityIdentifier(target == .composer ? "composer.attachments" : "session.attachments")
        }
    }
}

/// One file on a composer: an image's thumbnail, or a card with the file's name, type and size.
struct AttachmentChip: View {
    let item: ComposerAttachment
    var disabled = false
    let remove: () -> Void

    private var failure: String? {
        switch item.status {
        case .tooLarge: String(localized: "Larger than \(Attachments.sizeText(Attachments.maxBytes))")
        case .failed(let message): message
        case .ready, .uploading: nil
        }
    }

    var body: some View {
        let file = item.attachment
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let thumbnail = file.thumbnail {
                    PhotoThumbnail(data: thumbnail, size: 56)
                } else {
                    FileCard(name: file.name, detail: Attachments.sizeText(file.size), compact: true)
                }
            }
            .overlay {
                if case .uploading(let fraction) = item.status {
                    RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.45))
                    ProgressView(value: fraction).progressViewStyle(.circular).tint(DSHTheme.textPrimary)
                        .accessibilityIdentifier("attachment.progress")
                }
            }
            .overlay {
                if failure != nil { RoundedRectangle(cornerRadius: 12).stroke(DSHTheme.amber, lineWidth: 1.5) }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(DSHTheme.textPrimary, Color.black.opacity(0.7))
                        .font(.body)
                }
                .offset(x: 7, y: -7)
                .disabled(disabled)
                .accessibilityLabel("Remove \(file.name)")
                .accessibilityIdentifier("attachment.remove.\(file.name)")
            }
            if let failure {
                Text(verbatim: failure)
                    .font(.caption2)
                    .foregroundStyle(DSHTheme.amber)
                    .lineLimit(2)
                    .frame(maxWidth: 160, alignment: .leading)
                    .accessibilityIdentifier("attachment.error")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: file.name))
        .accessibilityIdentifier("attachment.chip.\(file.name)")
    }
}

/// A file as a small card: a document icon, the name, and a detail line (type, size).
struct FileCard: View {
    let name: String
    let detail: String
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(for: name))
                .font(.title3)
                .foregroundStyle(DSHTheme.textSecondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(DSHTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: detail)
                    .font(.caption2)
                    .foregroundStyle(DSHTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: compact ? 168 : nil, height: 56, alignment: .leading)
        .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DSHTheme.hairline))
    }

    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "txt", "md", "rtf", "log", "csv": "doc.plaintext"
        case "jpg", "jpeg", "png", "gif", "webp", "heic": "photo"
        case "zip", "gz", "tar": "doc.zipper"
        case "swift", "ts", "js", "py", "json", "yaml", "yml", "sh": "chevron.left.forwardslash.chevron.right"
        default: "doc"
        }
    }
}

/// The files of a sent message, above its bubble: images as thumbnails (on the phone that sent
/// them), other files as cards with their name and size (D107).
struct MessageAttachmentsView: View {
    let attachments: [MessageAttachment]

    var body: some View {
        let photos = attachments.compactMap(\.thumbnail)
        let files = attachments.filter { $0.thumbnail == nil }
        VStack(alignment: .trailing, spacing: 6) {
            if !photos.isEmpty {
                HStack(spacing: 6) {
                    ForEach(photos.indices, id: \.self) { index in
                        PhotoThumbnail(data: photos[index], size: photos.count == 1 ? 140 : 96)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Photo")
                            .accessibilityIdentifier("session.message.user.photo")
                    }
                }
            }
            ForEach(files.indices, id: \.self) { index in
                let file = files[index]
                FileCard(name: file.name.isEmpty ? String(localized: "File") : file.name,
                         detail: [file.typeLabel, file.size > 0 ? Attachments.sizeText(file.size) : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                    .frame(maxWidth: 260, alignment: .trailing)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: file.name))
                    .accessibilityIdentifier("session.message.user.file")
            }
        }
    }
}

/// A rounded, square photo thumbnail (the composer chip and the user bubble).
struct PhotoThumbnail: View {
    let data: Data
    var size: CGFloat = 120

    var body: some View {
        Group {
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(DSHTheme.textTertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DSHTheme.hairline))
    }
}

/// Turns any photo (HEIC, PNG, …, from the library, the camera or Files) into what the host takes
/// (D95): a JPEG, at most `maxSide` pixels on its long side, and a small thumbnail JPEG.
enum PhotoTranscoder {
    static let maxSide: CGFloat = 2048
    static let thumbnailSide: CGFloat = 240

    static func attachment(from data: Data, name: String = "photo.jpg") -> FileAttachment? {
        guard let image = UIImage(data: data),
              let jpeg = resized(image, maxSide: maxSide).jpegData(compressionQuality: 0.8),
              let thumbnail = resized(image, maxSide: thumbnailSide).jpegData(compressionQuality: 0.7) else { return nil }
        return FileAttachment(data: jpeg, mediaType: "image/jpeg", name: name, thumbnail: thumbnail)
    }

    private static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxSide / max(longest, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

/// Reads a file the user picked in Files (D107). An image goes as a photo (`PhotoTranscoder`);
/// any other file goes as its bytes, with its media type from the extension. A file over the
/// limit is not read: its chip says it is too large.
enum AttachmentReader {
    static func file(at url: URL) -> FileAttachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        let mediaType = type?.preferredMIMEType ?? "application/octet-stream"
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > Attachments.maxBytes {
            return FileAttachment(data: Data(), mediaType: mediaType, name: name, size: size)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if type?.conforms(to: .image) == true,
           let photo = PhotoTranscoder.attachment(from: data, name: (name as NSString).deletingPathExtension + ".jpg") {
            return photo
        }
        return FileAttachment(data: data, mediaType: mediaType, name: name)
    }
}

/// The system camera, for one photo.
struct CameraPicker: UIViewControllerRepresentable {
    let taken: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) { parent.taken(data) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
