import DSHTransport
import Foundation

extension HostSync {
    /// One configured host: how to reach it and the key its cache rows use.
    public struct HostConfig: Sendable {
        public var key: String
        let connection: HostConnection
        public var name: String?

        public init?(paired host: PairedHost, using pairing: Pairing) {
            guard let endpoint = host.addresses.first, let connection = try? pairing.connection(to: host) else { return nil }
            self.init(key: host.cacheKey, connection: connection, name: host.name.isEmpty ? endpoint.description : host.name)
        }

        package init(key: String, connection: HostConnection, name: String? = nil) {
            self.key = key
            self.name = name
            self.connection = connection
        }
    }

    public enum Reachability: Equatable, Sendable {
        case connecting
        case online
        case offline
        case needsBridgeUpdate(version: String, supported: String)

        package var isUpdateRequired: Bool {
            if case .needsBridgeUpdate = self { true } else { false }
        }

        /// Stable token for UI tests (`host.status` accessibility value).
        public var token: String {
            switch self {
            case .connecting: "connecting"
            case .online: "online"
            case .offline: "offline"
            case .needsBridgeUpdate: "bridgeUpdateRequired"
            }
        }
    }

    public struct HostStatus: Identifiable, Equatable, Sendable {
        public var id: String { key }
        public var key: String
        public var name: String
        public var reachability: Reachability
        public var lastConnectedAt: Date?
        /// The negotiated channel shown in the host status row.
        public var channelName: String
        public var isEncrypted: Bool { channelName == "TLS 1.3" }
        var capabilities: [String]
        /// The address of the host in use while online, or the last one that worked.
        package var address: HostEndpoint? = nil
        public var addressDescription: String? { address?.description }
        /// While offline, the last error of each address of the host, in the order tried.
        public var addressFailures: [AddressFailure] = []

        /// While not online, the failure that says most about the host
        /// (`AddressFailure.mostTelling`). It stays during the next try, so X3 does not flash.
        public var offlineReason: AddressFailure? {
            reachability == .online ? nil : AddressFailure.mostTelling(addressFailures)
        }
    }

    /// A task as the views show it (a value copy of `CachedTask`).
    public struct TaskRow: Identifiable, Equatable, Sendable {
        public var id: String { key }
        public var key: String
        public var hostKey: String
        public var hostName: String
        public var taskID: String
        public var title: String
        public var state: TaskState
        public var message: String
        public var transcript: String
        public var createdAt: Date
        public var updatedAt: Date
        public var latestReply: String?
        public var sessionRevision: UInt64?
        public var externalSession: Bool
        public var approvalOnly: Bool
        public var approvals: [Approval]
        /// Milestones, from the cache: the list row shows the card.
        public var milestones: MilestoneTimeline
        public var modelSelection: ModelSelection?
        /// The session's workspace directory on the host (`drawer.v1`), from the cache.
        public var workspace: String? = nil
        /// Finished, and changed since the user last saw it on this phone.
        public var unread = false
        /// How many approvals of this task were answered, on any client.
        public var approvalsAnswered = 0
        /// Thinking and tool-call rows (`transcript.v1`), in transcript order.
        public var blocks = StructuredTranscript()
        /// When the latest turn started, if the host said.
        public var turnStartedAt: Date? = nil
        /// Follow-ups that wait while the task runs, in the order they were sent.
        public var queue: [QueuedMessage] = []
        /// The files this phone sent with the first message, with image thumbnails.
        public var attachments: [MessageAttachment] = []
        /// DSH's failure class when the task failed on its model (`QUOTA`, `AUTH`, …); empty otherwise.
        public var failureCode = ""

        /// Where the done footer's 用时 starts: the latest turn's start, else the task's
        /// creation (a single turn, or an older bridge). Never before `createdAt` or after `updatedAt`.
        public var lastTurnStart: Date {
            guard let turnStartedAt else { return createdAt }
            return min(max(turnStartedAt, createdAt), updatedAt)
        }

        /// Chunks stream the first phone turn. Its committed journal restores text after a truncated replay.
        /// A conversation with follow-ups keeps its streamed transcript, where the messages sit.
        public func singleTurnTranscript(_ messages: [SessionMessage]) -> String {
            guard state.isTerminal, blocks.followUpCount == 0 else { return transcript }
            let reply = messages.filter { !$0.fromUser }.map(\.text).joined(separator: "\n\n")
            return reply.isEmpty || transcript.contains(reply) ? transcript : reply
        }

    }
}
