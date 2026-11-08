import DSHCore
import PhotosUI
import SwiftUI
import UIKit

/// The photo key on composer 01 (STORY §7, phone as context; ARCHITECTURE D95). It opens the
/// system photo picker; the picked photo becomes a JPEG for the host and a thumbnail for the chip.
struct PhotoKey: View {
    let store: TaskListStore
    @State private var item: PhotosPickerItem?
    @State private var loading = false

    var body: some View {
        PhotosPicker(selection: $item, matching: .images, photoLibrary: .shared()) {
            Group {
                if loading { ProgressView().tint(DSHTheme.textSecondary) }
                else { Image(systemName: "photo").font(.body.weight(.semibold)) }
            }
            .foregroundStyle(DSHTheme.textSecondary)
            .frame(width: 40, height: 40)
            .background(Color.white.opacity(0.08), in: .circle)
        }
        .disabled(store.isSending || loading)
        .accessibilityLabel("Attach a photo")
        .accessibilityIdentifier("composer.photo")
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            loading = true
            Task {
                defer { loading = false; item = nil }
                guard let data = try? await picked.loadTransferable(type: Data.self),
                      let photo = PhotoTranscoder.attachment(from: data) else {
                    store.attachPhoto(nil)
                    return
                }
                store.attachPhoto(photo)
            }
        }
    }
}

/// The one photo on the composer: its thumbnail and a key that removes it.
struct PhotoChip: View {
    let store: TaskListStore
    let photo: PhotoAttachment

    var body: some View {
        HStack(spacing: 0) {
            PhotoThumbnail(data: photo.thumbnail, size: 56)
                .overlay(alignment: .topTrailing) {
                    Button { store.attachPhoto(nil) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(DSHTheme.textPrimary, Color.black.opacity(0.6))
                            .font(.body)
                    }
                    .offset(x: 6, y: -6)
                    .disabled(store.isSending)
                    .accessibilityLabel("Remove the photo")
                    .accessibilityIdentifier("composer.photo.remove")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("composer.photoChip")
            Spacer(minLength: 0)
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

/// Turns any photo the picker gives (HEIC, PNG, …) into what the host takes (D95): a JPEG, at most
/// `maxSide` pixels on its long side, and a small thumbnail JPEG.
enum PhotoTranscoder {
    static let maxSide: CGFloat = 2048
    static let thumbnailSide: CGFloat = 240

    static func attachment(from data: Data) -> PhotoAttachment? {
        guard let image = UIImage(data: data),
              let jpeg = resized(image, maxSide: maxSide).jpegData(compressionQuality: 0.8),
              let thumbnail = resized(image, maxSide: thumbnailSide).jpegData(compressionQuality: 0.7),
              jpeg.count <= Attachments.maxBytes else { return nil }
        return PhotoAttachment(data: jpeg, mediaType: "image/jpeg", name: "photo.jpg", thumbnail: thumbnail)
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
