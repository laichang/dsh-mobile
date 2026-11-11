#if DEBUG
import DSHCore
import DSHFeatures
import Foundation

/// A transcriber that "hears" a fixed phrase: partial results that grow a few
/// characters or a word at a time, `step` apart, then the final result. Debug builds choose it
/// with `-DSHMFakeSpeech <phrase>`; `-DSHMFakeSpeech denied` makes it report that the user turned
/// speech recognition off.
@MainActor
public final class FakeTranscriber: Transcriber {
    public static let deniedValue = "denied"

    public let results: [DictationResult]
    public let allowed: DictationPermission
    public let step: Duration
    /// What `start` was asked, for tests.
    public private(set) var starts = 0
    public private(set) var stopped = false
    private var continuation: AsyncThrowingStream<DictationResult, any Error>.Continuation?
    private var heard: DictationResult?
    private var feeder: Task<Void, Never>?

    public init(results: [DictationResult], permission: DictationPermission = .granted, step: Duration = .milliseconds(200)) {
        self.results = results
        allowed = permission
        self.step = step
    }

    /// Partial results of `phrase` that grow until it is whole, then the final one.
    public convenience init(phrase: String, permission: DictationPermission = .granted, step: Duration = .milliseconds(200)) {
        self.init(results: Self.partials(of: phrase).map { DictationResult($0) } + [DictationResult(phrase, isFinal: true)], permission: permission, step: step)
    }

    /// The transcriber of a `-DSHMFakeSpeech` value. Slow enough that a UI test sees it listen.
    public static func factory(_ value: String, step: Duration = .milliseconds(600)) -> TranscriberFactory {
        TranscriberFactory {
            value == deniedValue ? FakeTranscriber(results: [], permission: .denied) : FakeTranscriber(phrase: value, step: step)
        }
    }

    /// A word at a time when the phrase has spaces; else two characters at a time (Chinese).
    public static func partials(of phrase: String) -> [String] {
        if phrase.contains(" ") {
            let words = phrase.split(separator: " ")
            return words.indices.dropLast().map { words[...$0].joined(separator: " ") }
        }
        let characters = Array(phrase)
        return stride(from: 2, to: characters.count, by: 2).map { String(characters[..<$0]) }
    }

    public func permission() async -> DictationPermission { allowed }

    public func start() async throws -> AsyncThrowingStream<DictationResult, any Error> {
        starts += 1
        let (stream, continuation) = AsyncThrowingStream<DictationResult, any Error>.makeStream()
        self.continuation = continuation
        let results = results
        let step = step
        feeder = Task { [weak self] in
            for result in results {
                try? await Task.sleep(for: step)
                guard let self, !Task.isCancelled, let continuation = self.continuation else { return }
                self.heard = result
                continuation.yield(result)
                if result.isFinal { self.end() }
            }
            self?.end()
        }
        return stream
    }

    /// What was heard so far becomes the final result.
    public func stop() {
        stopped = true
        feeder?.cancel()
        if let heard, !heard.isFinal { continuation?.yield(DictationResult(heard.text, isFinal: true)) }
        end()
    }

    private func end() {
        continuation?.finish()
        continuation = nil
    }
}
#endif
