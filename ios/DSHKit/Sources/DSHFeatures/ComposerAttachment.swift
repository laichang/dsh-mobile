import DSHCore
import Foundation

/// One attachment on a composer, and where its upload is. The chip draws the status.
public struct ComposerAttachment: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case ready
        /// The fraction of its parts the host has acknowledged.
        case uploading(Double)
        /// Over `Attachments.maxBytes`: it cannot be sent; remove it.
        case tooLarge
        /// The host refused it (the error's text). The next send tries it again.
        case failed(String)
    }

    public var attachment: FileAttachment
    public var status: Status
    public var id: UUID { attachment.id }

    public init(_ attachment: FileAttachment) {
        self.attachment = attachment
        self.status = attachment.isTooLarge ? .tooLarge : .ready
    }
}

/// Which composer an attachment is on: the new-session composer (01) or a session page's (04).
public enum AttachTarget: Hashable, Sendable {
    case composer
    case followUp(taskKey: String)
}
