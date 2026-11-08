import DSHCore
import DSHProtocol
import SwiftUI
import UIKit

/// T1 · one page for a new session (01) and a session (04). The app opens on it with no task:
/// a blank new session with the default host and workspace (STORY §3). The first message creates
/// the session, and this same page becomes the session page (ARCHITECTURE D51): no list routing.
struct SessionPage: View {
    let store: TaskListStore
    let taskKey: String?
    @Binding var showFirstTask: Bool
    /// S23: where the user last scrolled this session to, on this phone (`SessionLanding`).
    var lastPosition: CGFloat? = nil
    @Environment(ShellModel.self) private var shell

    var body: some View {
        let row = taskKey.flatMap { store.task($0) }
        VStack(spacing: 0) {
            if let taskKey {
                PageBar(title: row.map { $0.title.isEmpty ? $0.taskID : $0.title } ?? String(localized: "Session"),
                        subtitle: row?.hostName)
                SessionTranscript(store: store, taskKey: taskKey, lastPosition: lastPosition)
            } else {
                PageBar(title: String(localized: "New session"))
                NewSessionBody(store: store, showFirstTask: showFirstTask)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let taskKey {
                SessionComposer(store: store, taskKey: taskKey)
            } else {
                ComposerView(store: store) { key in
                    shell.show(.session(key))
                    showFirstTask = false
                }
            }
        }
        .background(DSHTheme.canvas.ignoresSafeArea())
    }
}

/// The empty middle of a new session; on the first run, a suggested first task (S11, S22).
private struct NewSessionBody: View {
    let store: TaskListStore
    let showFirstTask: Bool

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            if store.allHostsOffline {
                AllHostsOfflineCard(store: store)
            } else if store.tasks.isEmpty || showFirstTask {
                VStack(spacing: 10) {
                    if store.tasks.isEmpty {
                        Text("No tasks yet")
                            .foregroundStyle(DSHTheme.textSecondary)
                            .accessibilityIdentifier("tasklist.empty")
                    }
                    if store.prompt.isEmpty {
                        Button {
                            store.prompt = FirstRun.suggestion
                        } label: {
                            Label("Try a first task", systemImage: "text.bubble")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("firstRun.suggestion")
                        Text("You can edit the suggestion before sending it.")
                            .font(.footnote).foregroundStyle(DSHTheme.textTertiary)
                    } else if showFirstTask {
                        // S22 (D63): after the first pairing the first task is already in the composer.
                        Text("Your first task is ready below. Edit it if you like, then send it.", tableName: "FirstRun")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(DSHTheme.textSecondary)
                            .accessibilityIdentifier("firstRun.hint")
                    } else {
                        Text("Send your first task when you're ready.")
                            .foregroundStyle(DSHTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 24)
            } else {
                Text(verbatim: "deepseek")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.07))
                    .accessibilityHidden(true)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The page has no scroll view to drag the keyboard away, and the prompt field takes Return
        // as a new line: a tap on the empty page or a swipe down on it puts the keyboard away,
        // as in Messages. Buttons on the page keep their own taps.
        .contentShape(.rect)
        .onTapGesture { endEditing() }
        .gesture(DragGesture(minimumDistance: 20).onEnded { drag in
            if drag.translation.height > 30 { endEditing() }
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("newSession.body")
    }

    private func endEditing() { Keyboard.dismiss() }
}

/// The thin session page: milestone card on top (a tap opens the timeline sheet), approvals,
/// the user's message in a bubble on the right, and the M1 `TranscriptView`. While the host is
/// connected the transcript keeps streaming; after a reconnect the gap fills in from the bridge.
private struct SessionTranscript: View {
    let store: TaskListStore
    let taskKey: String
    @Environment(ShellModel.self) private var shell
    @State private var history: Dshm_V1_SessionPage?
    @State private var historyError: String?
    @State private var retry = 0
    /// S19: finished and not read when the page opened: it opens at the start of the final answer.
    @State private var opensAtAnswer: Bool
    /// S23: where the page lands when it opens (D65): the answer's start, the bottom, or the last
    /// position. Decided once, when the page is made.
    @State private var landing: SessionLanding
    /// S19, S23: false once the user scrolls; then the page stops going back to where it landed.
    @State private var followsLanding = true
    /// S23: scrolls a read session back to its last position.
    @State private var position = ScrollPosition()
    /// S23: the height of S19's rows before the final answer. A saved position counts from below
    /// them, so the same text comes back to the same place (S27, D76: the rows are now the same on
    /// every visit, because the marker of the unread visit is gone).
    @State private var leadHeight: CGFloat = 0

    init(store: TaskListStore, taskKey: String, lastPosition: CGFloat? = nil) {
        self.store = store
        self.taskKey = taskKey
        let landing = SessionLanding.landing(store.task(taskKey), lastPosition: lastPosition)
        _landing = State(initialValue: landing)
        _opensAtAnswer = State(initialValue: landing == .answerStart)
    }

    private struct HistoryRequest: Equatable {
        var key: String
        var revision: UInt64?
        var online: Bool
        var retry: Int
    }

    var body: some View {
        let row = store.task(taskKey)
        let host = store.hosts.first { $0.key == row?.hostKey }
        VStack(spacing: 0) {
            // S16: the milestone bar and the status line sit above the scroll view, so they stay
            // at the top while the transcript scrolls (ARCHITECTURE D23 (b)).
            // P1: an agent question waits: the bar says 等你回答, also before the first milestone.
            let asking = row?.blocks.pendingQuestion != nil
            if let timeline = row?.milestones, !timeline.isEmpty || asking {
                // S19: red, with the step, when the task failed (screen X1).
                let alert = row.flatMap(TaskOutcome.init)?.barAlert
                // S3: milestone summary by default; the timeline on demand, in a sheet.
                Button { shell.present(.milestones(taskKey: taskKey)) } label: {
                    MilestoneBar(timeline: timeline, state: row?.state, alert: alert, asking: asking)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(MilestoneBar.line(timeline, state: row?.state, alert: alert, asking: asking))
                .accessibilityValue(timeline.progressToken)
                .accessibilityHint("Shows all steps")
                .accessibilityIdentifier("milestone.card")
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
            statusRow(row, host: host)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            ScrollViewReader { proxy in
            ScrollView {
                if let row {
                    let outcome = TaskOutcome(row) // S19: nil while the task runs or waits
                    VStack(alignment: .leading, spacing: 12) {
                        PendingApprovalBar(store: store, row: row)
                        let messages = history?.messages ?? []
                        // D89: follow-ups sent from this phone sit in the streamed transcript; the
                        // journal takes over only for messages that another client sent.
                        let showJournal = row.externalSession
                            || messages.filter(\.fromUser).count > 1 + row.blocks.followUpCount
                        // S19: the final answer of a finished session with a journal.
                        let finalSeq = showJournal && outcome != nil ? messages.last(where: { !$0.fromUser })?.seq : nil
                        let firstUserSeq = messages.first(where: \.fromUser)?.seq
                        if firstUserSeq == nil && !row.title.isEmpty {
                            UserBubble(text: row.title, attachments: row.attachments)
                        }
                        // Without the journal: only the first prompt on top; the streamed transcript
                        // below holds the answers and this phone's follow-ups (D89).
                        let shown = showJournal ? messages : Array(messages.filter(\.fromUser).prefix(1))
                        ForEach(shown, id: \.seq) { message in
                            if message.fromUser {
                                UserBubble(text: message.text, attachments: Self.attachments(of: message, first: message.seq == firstUserSeq, row: row))
                            } else {
                                if message.seq == finalSeq {
                                    lead(row, outcome)
                                }
                                TranscriptView(source: message.text)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(message.text)
                                    .accessibilityIdentifier("session.message.assistant")
                            }
                        }
                        if !showJournal {
                            lead(row, outcome)
                            StructuredTranscriptView(row: row, text: row.singleTurnTranscript(messages), store: store) // S17, P1
                        } else if history == nil && historyError == nil {
                            if host?.reachability == .online { ProgressView() }
                            else { Text("Connect to this host to load the conversation.").foregroundStyle(DSHTheme.textSecondary) }
                        }
                        if showJournal {
                            // P1: the journal has no place for a card; a waiting question goes last.
                            ForEach(row.blocks.items.filter { $0.question != nil && $0.question?.outcome == nil }) { item in
                                QuestionCard(store: store, row: row, question: item.question!, answersBelow: true)
                            }
                        }
                        if let historyError {
                            Text(historyError).font(.footnote)
                            Button("Retry") { retry += 1 }
                        }
                        if let outcome {
                            OutcomeEnd(store: store, row: row, outcome: outcome,
                                       prompt: OutcomeAnchor.retryPrompt(row, messages: messages))
                        }
                    }
                    .foregroundStyle(DSHTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
            // Follow the stream at the bottom, but start a short transcript at the top.
            // S19: a finished session that is not read opens at the start of its final answer.
            // S23: a read one opens at its last position (D65).
            .defaultScrollAnchor(landing.anchor)
            .defaultScrollAnchor(.top, for: .alignment)
            .scrollPosition($position)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("session.transcript")
            .accessibilityValue(landing.token)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { followsLanding = false }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                // S23: remember where the user scrolled to, for the next time this page opens.
                // `ScrollPosition.scrollTo(y:)` takes the same content offset back.
                if !followsLanding { shell.lastPositions[taskKey] = y - leadHeight }
            }
            .task(id: "\(history?.throughSeq ?? 0)/\(row?.transcript.utf8.count ?? 0)") {
                // Again when the history or the text comes in, until the user scrolls.
                switch landing {
                case .answerStart, .lastPosition: break
                case .followBottom, .end: return
                }
                // A few times: the page can still be in its motion (S23 F2–F3), and a lazy
                // transcript lays out more text after the first scroll.
                for delay in [80, 250, 500] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard followsLanding, !Task.isCancelled else { return }
                    if case .lastPosition(let y) = landing { position.scrollTo(y: y + leadHeight) }
                    else { proxy.scrollTo(OutcomeAnchor.id, anchor: .top) }
                }
            }
            }
        }
        .task(id: HistoryRequest(key: taskKey, revision: row?.sessionRevision,
                                 online: host?.reachability == .online, retry: retry)) {
            guard let row else { return }
            historyError = nil
            history = store.cachedHistory(for: row)
            do {
                let result = try await store.readHistory(for: row)
                try Task.checkCancellation()
                history = result
            } catch {
                if !Task.isCancelled { historyError = String(describing: error) }
            }
        }
    }

    /// D107: a journal message's files; the first message also gets this phone's thumbnails.
    static func attachments(of message: Dshm_V1_SessionMessage, first: Bool, row: TaskListStore.TaskRow) -> [MessageAttachment] {
        let host = message.attachments.map(MessageAttachment.init)
        guard first else { return host }
        return host.isEmpty ? row.attachments : host.keepingThumbnails(of: row.attachments)
    }

    /// S19's rows before the final answer, in one stack so that S23 can measure them.
    @ViewBuilder
    private func lead(_ row: TaskListStore.TaskRow, _ outcome: TaskOutcome?) -> some View {
        if outcome != nil || opensAtAnswer {
            VStack(alignment: .leading, spacing: 12) {
                OutcomeLead(row: row, outcome: outcome, marksAnswer: opensAtAnswer)
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { leadHeight = $0 }
        }
    }

    private func statusRow(_ row: TaskListStore.TaskRow?, host: TaskListStore.HostStatus?) -> some View {
        let text = statusText(row, host: host)
        return HStack(spacing: 8) {
            if let row { TaskStateIcon(state: row.state) }
            Text(text)
                .font(.footnote)
                .foregroundStyle(DSHTheme.textSecondary)
                .lineLimit(3)
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityValue(row?.state.token ?? "unknown")
        .accessibilityIdentifier("task.status")
    }

    private func statusText(_ row: TaskListStore.TaskRow?, host: TaskListStore.HostStatus?) -> String {
        guard let row else { return String(localized: "This task is not in the list.") }
        let where_ = row.hostName
        switch row.state {
        case .running:
            if host?.reachability == .offline { return String(localized: "Was running on \(where_), which is offline. It will catch up when \(where_) is back.") }
            return String(localized: "Running on \(where_)")
        case .interrupted: return String(localized: "Interrupted on \(where_)")
        case .waitingOnUser: return String(localized: "Waiting on you (\(where_))")
        case .completed: return String(localized: "Done on \(where_)")
        case .failed: return row.failureText.isEmpty ? String(localized: "Failed: the task failed") : String(localized: "Failed: \(row.failureText)")
        }
    }
}

/// The user's message: a bubble on the right (DESIGN.md: bubble token).
/// The files sent with it (D95, D107) show above it.
struct UserBubble: View {
    let text: String
    var attachments: [MessageAttachment] = []

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !attachments.isEmpty {
                MessageAttachmentsView(attachments: attachments)
            }
            HStack {
                Spacer(minLength: 48)
                Text(verbatim: text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(DSHTheme.bubble, in: .rect(cornerRadius: 18))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityIdentifier("session.message.user")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The composer on a session page. A completed task on a host with `conversation.v1` takes a
/// follow-up (D89): its reply streams into this page. With `conversation.v2` (D101) it also takes
/// one while the task runs: the message waits above the field (`FollowUpQueueView`) and runs as
/// the next turn, unless the user sends it now; and one after a stop, which continues the task.
/// Otherwise the field is off. The model pill changes a running task's model (S6). While it runs,
/// the send key is the stop key (S5), and the send key again while the field has text.
private struct SessionComposer: View {
    let store: TaskListStore
    let taskKey: String
    @State private var requestingStop = false
    @State private var stopError: String?
    @State private var draft = ""
    @State private var sending = false
    @State private var sendError: String?
    @State private var dictation = Dictation() // D117
    @FocusState private var editing: Bool

    var body: some View {
        let row = store.task(taskKey)
        let host = store.hosts.first { $0.key == row?.hostKey }
        let followUp = row.map(store.canFollowUp) ?? false
        // P1 (D113): while an agent question waits, the field answers it; it is not a follow-up.
        let question = host?.capabilities.contains(DSHProtocolInfo.questionsCapability) == true ? row?.blocks.pendingQuestion : nil
        let typed = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 10) {
            if let row, !row.queue.isEmpty {
                FollowUpQueueView(store: store, row: row) { sendError = $0 }
            }
            if let sendError {
                Text(sendError)
                    .font(.footnote)
                    .foregroundStyle(DSHTheme.amber)
                    .accessibilityIdentifier("session.followUpError")
            }
            if followUp || question != nil {
                if question == nil { // D107: an answer to a question takes no attachment
                    AttachmentChips(store: store, target: .followUp(taskKey: taskKey), disabled: sending)
                }
                DictationNotice(dictation: dictation) // D117
                TextField(question != nil ? "Answer the agent…"
                            : row?.state.isTerminal == false ? "Add a message for the next turn" : "Reply to your agent",
                          text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($editing)
                    .foregroundStyle(DSHTheme.textPrimary)
                    .disabled(sending)
                    .accessibilityIdentifier("session.followUp")
            } else {
                HStack(spacing: 8) {
                    Text("Follow-ups come in a later version")
                        .foregroundStyle(DSHTheme.textTertiary)
                        .accessibilityIdentifier("session.followUp")
                    Spacer(minLength: 0)
                    // Screen 04 tags the follow-up field with its milestone.
                    Text(verbatim: "M2")
                        .font(DSHTheme.mono(.caption2).weight(.semibold))
                        .foregroundStyle(DSHTheme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 6))
                        .accessibilityHidden(true)
                }
            }
            HStack(spacing: 8) {
                if followUp, question == nil, let row, store.canAttach(to: row) {
                    AttachMenu(store: store, target: .followUp(taskKey: row.key), disabled: sending) // D107
                }
                if let row, !row.state.isTerminal, store.modelHosts.contains(row.hostKey) {
                    ModelControl(store: store, hostKey: row.hostKey, task: row)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
                Spacer()
                if followUp || question != nil {
                    MicKey(dictation: dictation, identifier: "session.mic", disabled: sending,
                           read: { draft }, write: { draft = $0 }) // D117
                }
                if let row, !row.state.isTerminal, let host, !((followUp || question != nil) && (typed || sending)),
                   host.reachability == .online, host.capabilities.contains(DSHProtocolInfo.interruptCapability) {
                    Button {
                        requestingStop = true
                        Task {
                            defer { requestingStop = false }
                            do { try await store.interrupt(row) }
                            catch { stopError = String(describing: error) }
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(width: 40, height: 40)
                            .background(DSHTheme.textPrimary, in: .circle)
                    }
                    .disabled(requestingStop)
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("task.interrupt")
                } else if let row, let question {
                    SendKey(enabled: typed && !sending, sending: sending) { answer(question, for: row) }
                        .accessibilityLabel("Answer")
                        .accessibilityIdentifier("session.send")
                } else if followUp, let row {
                    SendKey(enabled: typed && !sending, sending: sending) { send(row) }
                        .accessibilityLabel("Send")
                        .accessibilityIdentifier("session.send")
                } else {
                    SendKey(enabled: false, sending: false) {}
                        .accessibilityIdentifier("session.send")
                }
            }
        }
        .composerChrome()
        .onChange(of: taskKey) { dictation.cancel(); draft = ""; sendError = nil }
        .onDisappear { dictation.cancel() }
        // D101: follow-ups that a stop gave back come back into the field, to send again or not.
        .task(id: "\(taskKey)/\(store.returnedDrafts[taskKey]?.count ?? 0)") {
            let returned = store.takeReturnedDrafts(for: taskKey)
            guard !returned.isEmpty else { return }
            draft = ([draft] + returned).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        .alert("Couldn’t stop the task", isPresented: Binding(get: { stopError != nil }, set: { if !$0 { stopError = nil } })) {
            Button("OK") { stopError = nil }
        } message: {
            Text(stopError ?? "")
        }
    }
}

extension SessionComposer {
    /// D89: the message goes to the host; the page shows it when the host logs it.
    private func send(_ row: TaskListStore.TaskRow) {
        dictation.cancel() // D117: the field as it is now is what goes
        let text = draft
        sending = true
        sendError = nil
        Task {
            defer { sending = false }
            do {
                try await store.sendFollowUp(text, for: row)
                draft = ""
                editing = false
            } catch {
                sendError = String(localized: "The message was not sent: \(String(describing: error))")
            }
        }
    }

    /// P1 (D113): the typed text answers the waiting question; the card shows it when the host
    /// resolves the question, and the task continues.
    private func answer(_ question: AgentQuestion, for row: TaskListStore.TaskRow) {
        dictation.cancel() // D117
        let text = draft
        sending = true
        sendError = nil
        Task {
            defer { sending = false }
            do {
                try await store.answerQuestion(question, hostKey: row.hostKey, typed: text)
                draft = ""
                editing = false
            } catch {
                sendError = String(localized: "The answer was not sent: \(String(describing: error))")
            }
        }
    }
}

/// The composer of a new session: one line with "host · workspace" (and the host picker when
/// there are more hosts), the prompt, the model pill and the send key.
struct ComposerView: View {
    @Bindable var store: TaskListStore
    let opened: (String) -> Void
    @State private var dictation = Dictation() // D117
    @FocusState private var editingPrompt: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let key = store.composerHostKey {
                contextLine(key)
            }
            if let error = store.sendError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(DSHTheme.amber)
                    .accessibilityIdentifier("composer.error")
            }
            AttachmentChips(store: store, target: .composer, disabled: store.isSending) // D107
            DictationNotice(dictation: dictation) // D117
            TextField("One sentence for your agent", text: $store.prompt, axis: .vertical)
                .lineLimit(1...5)
                .focused($editingPrompt)
                .foregroundStyle(DSHTheme.textPrimary)
                .accessibilityIdentifier("composer.prompt")
                .onSubmit(send)
            HStack(spacing: 8) {
                if store.canAttach {
                    AttachMenu(store: store, target: .composer, disabled: store.isSending)
                }
                if let key = store.composerHostKey {
                    modelControl(key)
                }
                Spacer()
                MicKey(dictation: dictation, identifier: "composer.mic", disabled: store.isSending,
                       read: { store.prompt }, write: { store.prompt = $0 }) // D117
                SendKey(enabled: store.canSend, sending: store.isSending, action: send)
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("composer.send")
            }
        }
        .composerChrome()
        .onDisappear { dictation.cancel() }
    }

    /// "host · workspace", above the prompt.
    @ViewBuilder
    private func contextLine(_ key: String) -> some View {
        let host = store.hosts.first { $0.key == key }
        HStack(spacing: 6) {
            Circle()
                .fill(host?.reachability == .online ? DSHTheme.green : DSHTheme.textTertiary)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            if store.hosts.count > 1 {
                Picker("Send to", selection: Binding(get: { key }, set: { store.chooseHost($0) })) {
                    ForEach(store.hosts) { host in
                        Text(host.name).tag(host.key)
                    }
                }
                .pickerStyle(.menu)
                .tint(DSHTheme.textSecondary)
                .accessibilityIdentifier("composer.host")
                .disabled(store.isSending)
            } else if let host {
                Text(host.name)
                    .lineLimit(1)
                    .accessibilityIdentifier("composer.hostName")
            }
            Text(verbatim: "·").foregroundStyle(DSHTheme.textTertiary).accessibilityHidden(true)
            if let host, host.reachability == .online, host.capabilities.contains("workspaces.v1") {
                WorkspaceControl(store: store, hostKey: key)
                    .tint(DSHTheme.textSecondary)
            } else if let host, host.reachability == .online, store.composerWorkspaces[key] != nil {
                Button("Use default workspace on this host") { store.chooseWorkspace(nil, hostKey: key) }
            } else {
                Label(store.composerWorkspaces[key] ?? String(localized: "Default workspace"), systemImage: "folder")
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .foregroundStyle(DSHTheme.textSecondary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.context")
    }

    @ViewBuilder
    private func modelControl(_ key: String) -> some View {
        if store.modelHosts.contains(key) {
            ModelControl(store: store, hostKey: key, task: nil)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        } else if let choice = store.composerSelections[key],
                  store.hosts.contains(where: { $0.key == key && $0.reachability == .online && !$0.capabilities.contains("models.v1") }) {
            VStack(alignment: .leading) {
                Text("This host cannot select \(choice.model).").font(.footnote)
                Button("Use host default") { store.useHostDefault(hostKey: key) }
            }
        }
    }

    private func send() {
        dictation.cancel() // D117: the field as it is now is what goes
        Task {
            if let key = await store.send() {
                editingPrompt = false
                opened(key)
            }
        }
    }
}

/// The round key in the send position.
private struct SendKey: View {
    let enabled: Bool
    let sending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if sending { ProgressView().tint(DSHTheme.textPrimary) }
                else { Image(systemName: "arrow.up").font(.body.weight(.bold)) }
            }
            .foregroundStyle(enabled ? Color.white : DSHTheme.textTertiary)
            .frame(width: 40, height: 40)
            .background(enabled ? DSHTheme.blue : Color.white.opacity(0.1), in: .circle)
        }
        .disabled(!enabled)
    }
}

private extension View {
    /// The composer's card: bubble color, rounded, a hairline border.
    func composerChrome() -> some View {
        padding(16)
            .background(DSHTheme.bubble, in: .rect(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(DSHTheme.hairline))
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
    }
}

extension TaskState {
    /// Stable token for UI tests (`task.status` accessibility value; T0's tokens for its states).
    var token: String {
        switch self {
        case .running: "running"
        case .waitingOnUser: "waiting"
        case .completed: "completed"
        case .failed: "failed"
        case .interrupted: "interrupted"
        }
    }
}
