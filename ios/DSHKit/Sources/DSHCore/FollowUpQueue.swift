import DSHProtocol
import Foundation

/// D101 · a follow-up that waits while its task runs (screen 04): above the composer until DSH
/// takes it into a turn. Then it is a `.userMessage` row of the transcript, where DSH took it.
public struct QueuedMessage: Codable, Equatable, Sendable, Identifiable {
    public enum Placement: String, Codable, Sendable {
        /// It runs as a new turn after the running turn (and after the messages queued before it).
        case queued
        /// "立即发送": it goes in at the next step of the running turn.
        case steering
        /// The user removed it; it does not run.
        case removed
        /// The task stopped before it ran; its text goes back to the composer.
        case returned

        /// Still waiting, so the queue above the composer shows it.
        public var isWaiting: Bool { self == .queued || self == .steering }

        init(wire: Dshm_V1_QueuePlacement) {
            self = switch wire {
            case .steering: .steering
            case .removed: .removed
            case .returned: .returned
            default: .queued
            }
        }
    }

    /// The bridge's message ID, also the `message_id` of its later `UserMessage`.
    public var id: String
    public var taskID: String
    public var text: String
    public var placement: Placement
    public var time: Date

    public init(id: String, taskID: String, text: String, placement: Placement, time: Date) {
        self.id = id
        self.taskID = taskID
        self.text = text
        self.placement = placement
        self.time = time
    }

    public init(_ wire: Dshm_V1_QueuedMessage) {
        self.init(id: wire.messageID, taskID: wire.taskID, text: wire.text, placement: Placement(wire: wire.placement),
                  time: Date(timeIntervalSince1970: TimeInterval(wire.timeMs) / 1000))
    }
}

/// D101 · a task's waiting follow-ups, in the order they were sent.
public struct FollowUpQueue: Codable, Equatable, Sendable {
    public private(set) var messages: [QueuedMessage] = []

    public init(messages: [QueuedMessage] = []) {
        self.messages = messages
    }

    public var isEmpty: Bool { messages.isEmpty }

    /// Applies one change from the host. A message that waits keeps its place when it moves
    /// (queued → steering); one that stops waiting leaves. Returns whether anything changed.
    @discardableResult
    public mutating func apply(_ change: QueuedMessage) -> Bool {
        let at = messages.firstIndex { $0.id == change.id }
        guard change.placement.isWaiting else {
            guard let at else { return false }
            messages.remove(at: at)
            return true
        }
        if let at {
            guard messages[at] != change else { return false }
            messages[at] = change
        } else {
            messages.append(change)
        }
        return true
    }

    /// DSH took the message into a turn: it is in the transcript now.
    @discardableResult
    public mutating func taken(_ messageID: String) -> Bool {
        guard let at = messages.firstIndex(where: { $0.id == messageID }) else { return false }
        messages.remove(at: at)
        return true
    }
}
