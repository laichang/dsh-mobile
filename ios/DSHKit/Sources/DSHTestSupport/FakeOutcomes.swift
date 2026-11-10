#if DEBUG
import DSHCore
import Foundation

/// Done and failed (screens 06 and X1), `-DSHMFakeScenario outcomes`. Debug only.
///
/// - A prompt that contains `FakeBridge.outcomeDonePrompt` ("open a PR"): five todos. After four,
///   the task asks to run `git push` (the approval), then streams a final answer longer than the
///   screen, finishes the fifth todo, and ends done: eight milestones and one answered approval.
/// - A prompt that contains `FakeBridge.outcomeFailPrompt` ("upload"): four todos. After two, it
///   says what it did and fails on the third with `FakeBridge.outcomeFailure`.
/// - A prompt that contains `FakeBridge.outcomeHoldPrompt` ("Rename"): stays running after its
///   first milestone until the user stops it (`interrupt.v1`).
extension FakeBridge {
    public static let outcomeDonePrompt = "open a PR"
    public static let outcomeFailPrompt = "upload"
    public static let outcomeHoldPrompt = "Rename"
    public static let outcomeFailure = "upload: 403 Forbidden (token expired)"
    public static let outcomeDoneItems = ["Find the failing test", "Reproduce it", "Fix the order of replayed events",
                                          "Run the tests", "Open a pull request"]
    public static let outcomeFailItems = ["Find yesterday's downloads", "Compress them into one file",
                                          "Upload it to the cloud drive", "Share the link"]
    public static let outcomeApproval = FakeBridge.PendingApproval(
        title: "", tool: "bash", arguments: #"{"command":"git push origin fix/replay-order"}"#,
        reason: "Push the fix so that I can open the pull request")
    /// The first line of the done task's final answer, and its last line.
    public static let outcomeAnswerStart = "Done: the CI test passes again, and the pull request is open."
    public static let outcomeAnswerEnd = "Nothing else changed on this Mac."
    public static let outcomeDoneReply = """
        \(outcomeAnswerStart)

        ## What was wrong

        `TaskListStoreTests/resume` failed because replayed events were put **after** the live ones. A fast live event could land first, and the replay then wrote an older state over it.

        ## What I changed

        - `TaskListStore.apply` now sorts a replay by `host_seq` before it merges.
        - Live events wait until the replay is in.
        - The cache keeps the highest `host_seq` it has seen.

        ```swift
        let ordered = replay.sorted { $0.hostSeq < $1.hostSeq }
        for event in ordered where event.hostSeq > lastSeq {
            apply(event)
        }
        ```

        ## How I checked it

        I added `resumeFillsGapInOrder`. It drops the connection after two events, sends three live events, and then lets the replay in. Before the fix the cache ended on the second event; now it ends on the fifth. The whole suite passes on the simulator: 214 tests, 0 failures.

        ## The pull request

        The branch is `fix/replay-order`. I pushed it after you allowed `git push`, and opened pull request #128 with the fix and the new test. The description says what changed and how to check it.

        \(outcomeAnswerEnd)
        """
    public static let outcomeFailReply = "214 files are compressed into `media-1104.zip` (3.1 GB). The upload failed."
}

extension FakeBridge.Script {
    /// The outcomes host: the done task is the default; the failing upload is a variant.
    public static func outcomes(delay: Duration = .milliseconds(300)) -> Self {
        func list(_ items: [String], done: Int) -> [Todo] {
            items.enumerated().map { i, content in
                Todo(content: content, status: i < done ? .completed : i == done ? .inProgress : .pending)
            }
        }
        let doneItems = FakeBridge.outcomeDoneItems
        var script = Self(
            reply: FakeBridge.outcomeDoneReply.split(separator: "\n", omittingEmptySubsequences: false).map { $0 + "\n" },
            chunkDelay: .milliseconds(30),
            milestones: [
                FakeBridge.Step(.started),
                FakeBridge.Step(.planned, todos: list(doneItems, done: 0)),
                FakeBridge.Step(.todoDone, doneItems[0], todos: list(doneItems, done: 1)),
                FakeBridge.Step(.todoDone, doneItems[1], todos: list(doneItems, done: 2)),
                FakeBridge.Step(.todoDone, doneItems[2], todos: list(doneItems, done: 3)),
                FakeBridge.Step(.todoDone, doneItems[3], todos: list(doneItems, done: 4)),
                FakeBridge.Step(.todoDone, doneItems[4], todos: list(doneItems, done: 5)),
            ],
            milestoneDelay: delay)
        script.replyAfterMilestones = 6
        script.ask = (FakeBridge.outcomeDonePrompt, FakeBridge.outcomeApproval)
        script.holdPrompt = FakeBridge.outcomeHoldPrompt
        script.interruptible = true

        let failItems = FakeBridge.outcomeFailItems
        var failing = Self(
            reply: [FakeBridge.outcomeFailReply],
            chunkDelay: .milliseconds(30),
            failWith: FakeBridge.outcomeFailure,
            milestones: [
                FakeBridge.Step(.started),
                FakeBridge.Step(.planned, todos: list(failItems, done: 0)),
                FakeBridge.Step(.todoDone, failItems[0], todos: list(failItems, done: 1)),
                FakeBridge.Step(.todoDone, failItems[1], todos: list(failItems, done: 2)),
            ],
            milestoneDelay: delay)
        failing.interruptible = true
        script.variants = [.init(prompt: FakeBridge.outcomeFailPrompt, script: failing)]
        return script
    }
}
#endif
