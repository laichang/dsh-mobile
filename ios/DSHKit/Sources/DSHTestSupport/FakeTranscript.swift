#if DEBUG
import DSHCore
import DSHProtocol
import Foundation

/// S17 · a coding task with thinking and tool calls (`-DSHMFakeScenario transcript`, PLAN.md S17
/// Demo): "已思考 8 秒 ›", "Read TaskListStore.swift" and "Edit TaskListStore.swift +12 −3", with the
/// blocks a bridge with `transcript.v1` sends (bridge/src/transcript/mapper.ts).
public enum FakeTranscript {
    public static let capability = DSHProtocolInfo.transcriptCapability
    public static let storePath = "ios/DSHKit/Sources/DSHCore/Sync/TaskListStore.swift"
    public static let reasoning = "The resume test fails after a reconnect. Read the store first, then fix the order of replayed events."
    /// The last words of the reply, for UI tests.
    public static let replyEnd = "The tests pass now."

    public static func script(chunkDelay: Duration = .milliseconds(250)) -> FakeBridge.Script {
        var script = FakeBridge.Script(
            reply: [
                "The failing test is `TaskListStoreTests/resume`. ",
                "Replayed events landed after live ones.\n\n",
                "I sorted the replay by `host_seq` before the merge.\n\n",
                "Running `swift test --filter resume`.\n\n",
                replyEnd,
            ],
            chunkDelay: chunkDelay)
        script.blocks = [
            (0, thinking(.running, ms: 0)),
            (0, thinking(.done, ms: 8_000)),
            (2, tool("call-read", "read", target: storePath, .running)),
            (2, tool("call-read", "read", target: storePath, .done)),
            (3, tool("call-edit", "edit", target: storePath, .running)),
            (3, tool("call-edit", "edit", target: storePath, .done, added: 12, removed: 3)),
            (4, tool("call-bash", "bash", target: "swift test --filter resume", .running)),
            (4, tool("call-bash", "bash", target: "swift test --filter resume", .done)),
        ]
        return script
    }

    static func thinking(_ state: Dshm_V1_TranscriptBlockState, ms: UInt64) -> Dshm_V1_TranscriptBlock {
        var block = Dshm_V1_TranscriptBlock()
        block.blockID = "thinking-1-0"
        block.state = state
        block.timeMs = Int64(Date().timeIntervalSince1970 * 1000)
        var thinking = Dshm_V1_ThinkingBlock()
        thinking.durationMs = ms
        thinking.text = reasoning
        block.thinking = thinking
        return block
    }

    static func tool(_ id: String, _ name: String, target: String, _ state: Dshm_V1_TranscriptBlockState,
                     added: UInt32 = 0, removed: UInt32 = 0) -> Dshm_V1_TranscriptBlock {
        var block = Dshm_V1_TranscriptBlock()
        block.blockID = id
        block.state = state
        block.timeMs = Int64(Date().timeIntervalSince1970 * 1000)
        var tool = Dshm_V1_ToolBlock()
        tool.tool = name
        tool.target = target
        tool.linesAdded = added
        tool.linesRemoved = removed
        let key = name == "bash" ? "command" : "file_path"
        tool.arguments = "{\"\(key)\":\"\(target)\"}"
        block.tool = tool
        return block
    }
}
#endif
