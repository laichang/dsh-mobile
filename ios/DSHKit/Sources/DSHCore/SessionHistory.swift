import DSHProtocol
import Foundation

public struct SessionMessage: Equatable, Sendable {
    public let seq: UInt64
    public let fromUser: Bool
    public let text: String
    public let attachments: [MessageAttachment]

    init(_ wire: Dshm_V1_SessionMessage) {
        seq = wire.seq
        fromUser = wire.fromUser
        text = wire.text
        attachments = wire.attachments.map(MessageAttachment.init)
    }
}

public struct SessionHistory: Sendable {
    public let throughSeq: UInt64
    public let messages: [SessionMessage]
    // Preserve the existing protobuf cache format, including unknown message and attachment fields.
    let cacheData: Data

    init(_ page: Dshm_V1_SessionPage, cacheData: Data) {
        throughSeq = page.throughSeq
        messages = page.messages.map(SessionMessage.init)
        self.cacheData = cacheData
    }

    init(cacheData: Data) throws {
        self.init(try Dshm_V1_SessionPage(serializedBytes: cacheData), cacheData: cacheData)
    }
}
