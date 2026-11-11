#if DEBUG
import DSHCore
import DSHProtocol
import Foundation

/// A Web session with two turns far apart (`-DSHMFakeScenario turns`), as in the user's bug
/// on a real iPhone (2026-11-07): the first turn is 2 h 37 min 15 s before the end of the second,
/// and the second turn took 1 min 24 s. The session is done and not read on this phone, and its
/// final answer is longer than the screen. The host answers `ReadSession` with the journal.
public enum FakeTurns {
    public static let taskID = "fake-web-turns"
    public static let title = "Plan a weekend in Hangzhou"
    public static let firstPrompt = "Plan a weekend in Hangzhou for two"
    public static let secondPrompt = "Make it a day trip instead"
    /// From the first turn's start to the end of the session: what the footer said before.
    public static let sinceFirstTurn: Int64 = 9_435_000
    /// The second turn, from its start to its end: what the footer says.
    public static let lastTurn: Int64 = 84 * 1000
    public static let answerStart = "Here is a day trip to Hangzhou, from the first train to the last."
    public static let answerEnd = "Have a good trip."
    static let firstReply = "Day 1: West Lake and Hefang Street. Day 2: Lingyin Temple and the tea fields of Longjing."
    static let finalReply = """
        \(answerStart)

        ## Morning

        - **07:00** · Take the G7311 from Shanghai Hongqiao. It arrives at Hangzhou East at 07:59.
        - **08:30** · Metro line 1 to Longxiangqiao, then walk to the lake.
        - **09:00** · Walk the Su Causeway from south to north. It is 2.8 km and flat.
        - **10:30** · A boat to the Three Pools Mirroring the Moon. Buy the ticket at the pier.

        ## Noon

        Lunch at Louwailou, by the lake. Order the West Lake fish in vinegar and the Dongpo pork. Book a table the day before; at noon the wait is long.

        ## Afternoon

        - **13:30** · Bus 7 to Lingyin Temple. Go early: after 15:00 the line at the gate is long.
        - **15:30** · A taxi to Longjing village. Sit in a tea house and try this year's tea.
        - **17:00** · Back to the lake for the sunset at Leifeng Pagoda.

        ## Evening

        Dinner on Hefang Street, then the metro back to Hangzhou East. The last fast train to Shanghai leaves at 21:52.

        ## What it costs

        | Item | For two |
        | --- | --- |
        | Trains | ¥ 300 |
        | Boat and temple | ¥ 210 |
        | Food | ¥ 400 |
        | Taxi and metro | ¥ 90 |

        \(answerEnd)
        """

    /// The session's summary; the times count back from now, so the footer is the same on each run.
    public static func summary(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Dshm_V1_TaskSummary {
        var s = Dshm_V1_TaskSummary()
        s.taskID = taskID
        s.title = title
        s.state = .completed
        s.updatedAtMs = now
        s.createdAtMs = now - sinceFirstTurn
        s.turnStartedAtMs = now - lastTurn
        s.externalSession = true
        s.sessionRevision = 4
        return s
    }

    /// The journal: two user messages and two replies.
    public static func journal() -> Dshm_V1_SessionPage {
        var page = Dshm_V1_SessionPage()
        page.messages = [(firstPrompt, true), (firstReply, false), (secondPrompt, true), (finalReply, false)]
            .enumerated().map { i, m in
                var message = Dshm_V1_SessionMessage()
                message.seq = UInt64(i + 1)
                message.fromUser = m.1
                message.text = m.0
                return message
            }
        page.throughSeq = 4
        return page
    }

    /// The FakeBridge host with this session on it.
    public static func host() -> FakeHost {
        FakeHost(seed: [summary()], journals: [taskID: journal()])
    }
}
#endif
