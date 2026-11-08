import DSHCore
import DSHTestSupport
import Foundation
import Testing

/// D116, D117 · voice input with the fake transcriber: partial and final results replace the
/// dictated range in the field and keep the typed text; a denied permission leaves the field as
/// it was; nothing is sent.
@MainActor
@Suite(.serialized) struct DictationTests {
    /// The composer's field.
    @MainActor final class Field {
        var text: String
        var writes = 0
        var seen: [String] = []
        init(_ text: String) { self.text = text }
    }

    func waitUntil(_ what: String = "", timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { Issue.record("timed out: \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func run(_ fake: FakeTranscriber, in field: Field, _ dictation: Dictation = Dictation()) async throws -> [String] {
        dictation.start(using: TranscriberFactory { fake }, read: { field.text }, write: { field.text = $0; field.writes += 1; field.seen.append($0) })
        try await waitUntil("done") { dictation.state == .idle && field.writes > 0 }
        return field.seen
    }

    @Test func partialAndFinalResultsReplaceTheDictatedRangeAndKeepTheTypedText() async throws {
        let field = Field("Typed first.")
        // A later partial changes a word of the one before it; the final one changes it again.
        let fake = FakeTranscriber(results: [
            .init("fix the"), .init("fix the flaky"), .init("fix the flaky test and"),
            .init("fix the flaky test and open a PR"), .init("Fix the flaky test and open a PR.", isFinal: true),
        ], step: .milliseconds(20))
        let seen = try await run(fake, in: field)
        #expect(seen == [
            "Typed first. fix the", "Typed first. fix the flaky", "Typed first. fix the flaky test and",
            "Typed first. fix the flaky test and open a PR", "Typed first. Fix the flaky test and open a PR.",
        ])
        #expect(field.text == "Typed first. Fix the flaky test and open a PR.")
    }

    @Test func revisedPartialsReplaceOnlyTheDictatedWordsInChinese() async throws {
        let field = Field("先")
        let fake = FakeTranscriber(results: [.init("整理桌"), .init("整理桌面的截图"), .init("整理桌面上的截图", isFinal: true)],
                                   step: .milliseconds(20))
        let seen = try await run(fake, in: field)
        #expect(seen == ["先整理桌", "先整理桌面的截图", "先整理桌面上的截图"]) // no space in Chinese
        #expect(field.text == "先整理桌面上的截图")
    }

    @Test func textTypedWhileSpeakingStaysAfterTheDictatedWords() async throws {
        let field = Field("")
        let fake = FakeTranscriber(results: [.init("hello"), .init("hello world"), .init("hello world again", isFinal: true)],
                                   step: .milliseconds(80))
        let dictation = Dictation()
        dictation.start(using: TranscriberFactory { fake }, read: { field.text }, write: { field.text = $0 })
        try await waitUntil("first words") { field.text == "hello" }
        field.text += " — typed" // the user types at the end while still speaking
        try await waitUntil("done") { dictation.state == .idle }
        #expect(field.text == "hello world again — typed")
    }

    @Test func editingTheDictatedWordsStopsDictationAndKeepsTheEdit() async throws {
        let field = Field("")
        let fake = FakeTranscriber(results: [.init("one"), .init("one two"), .init("one two three"), .init("one two three four", isFinal: true)],
                                   step: .milliseconds(80))
        let dictation = Dictation()
        dictation.start(using: TranscriberFactory { fake }, read: { field.text }, write: { field.text = $0 })
        try await waitUntil("first words") { field.text == "one" }
        field.text = "my own words"
        try await waitUntil("done") { dictation.state == .idle }
        #expect(field.text == "my own words")
        #expect(fake.stopped)
    }

    @Test func stopMakesWhatWasHeardTheFinalResult() async throws {
        let field = Field("Note:")
        let fake = FakeTranscriber(phrase: "please summarize the report for me", step: .milliseconds(60))
        let dictation = Dictation()
        dictation.start(using: TranscriberFactory { fake }, read: { field.text }, write: { field.text = $0 })
        try await waitUntil("some words") { field.text.hasPrefix("Note: please summarize") }
        dictation.toggle(using: TranscriberFactory { fake }, read: { field.text }, write: { field.text = $0 }) // the mic key again
        try await waitUntil("stopped") { dictation.state == .idle }
        let stoppedAt = field.text
        #expect(stoppedAt.hasPrefix("Note: please summarize"))
        #expect(stoppedAt != "Note: please summarize the report for me")
        try await Task.sleep(for: .milliseconds(300))
        #expect(field.text == stoppedAt, "nothing comes in after the stop")
    }

    @Test func deniedPermissionLeavesTheFieldAsItWas() async throws {
        let field = Field("keep this")
        let fake = FakeTranscriber(results: [.init("never", isFinal: true)], permission: .denied)
        let dictation = Dictation()
        dictation.start(using: TranscriberFactory { fake }, read: { field.text }, write: { field.text = $0; field.writes += 1 })
        try await waitUntil("refused") { dictation.state == .notAllowed(.denied) }
        #expect(field.text == "keep this")
        #expect(field.writes == 0)
        #expect(fake.starts == 0, "it does not listen")
        dictation.clearNotice()
        #expect(dictation.state == .idle)
    }

    @Test func cancelKeepsTheFieldAndIgnoresLaterResults() async throws {
        let field = Field("")
        let fake = FakeTranscriber(phrase: "send this now please", step: .milliseconds(60))
        let dictation = Dictation()
        dictation.start(using: TranscriberFactory { fake }, read: { field.text }, write: { field.text = $0 })
        try await waitUntil("some words") { !field.text.isEmpty }
        dictation.cancel() // the user taps send while it listens
        let sent = field.text
        #expect(dictation.state == .idle)
        try await Task.sleep(for: .milliseconds(300))
        #expect(field.text == sent)
    }

    @Test func spliceSpacesOnlyBetweenWordsOfSpacedLanguages() {
        var latin = DictationSplice(text: "Hi")
        #expect(latin.apply("there", to: "Hi") == "Hi there")
        var afterSpace = DictationSplice(text: "Hi ")
        #expect(afterSpace.apply("there", to: "Hi ") == "Hi there")
        var punctuation = DictationSplice(text: "Hi")
        #expect(punctuation.apply(", there", to: "Hi") == "Hi, there")
        var mixed = DictationSplice(text: "PR")
        #expect(mixed.apply("修好了", to: "PR") == "PR修好了")
        var empty = DictationSplice(text: "")
        #expect(empty.apply("hello", to: "") == "hello")
    }

    @Test func fakeSpeechLaunchArgumentChoosesThePhraseOrDenied() async throws {
        let options = DebugLaunchOptions.parse(["app", "-DSHMFakeSpeech", "整理桌面上的截图"])
        #expect(options.fakeSpeech == "整理桌面上的截图")
        #expect(FakeTranscriber.partials(of: "整理桌面上的截图") == ["整理", "整理桌面", "整理桌面上的"])
        #expect(FakeTranscriber.partials(of: "fix the test") == ["fix", "fix the"])
        let denied = FakeTranscriber.factory(FakeTranscriber.deniedValue).make()
        #expect(await denied.permission() == .denied)
    }
}
