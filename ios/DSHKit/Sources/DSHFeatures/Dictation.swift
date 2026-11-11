import Foundation
import Observation

/// What the user and the device allow for speech to text (STORY §7, voice).
public enum DictationPermission: Sendable, Equatable {
    case granted
    /// The user turned off the microphone or speech recognition for this app.
    case denied
    /// The device does not allow it (Screen Time, a managed device).
    case restricted
    /// This device has no on-device speech model for the language.
    case unavailable
}

/// One result of a transcriber: the whole text of this dictation so far. A later result can
/// change words of an earlier one.
public struct DictationResult: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool

    public init(_ text: String, isFinal: Bool = false) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// On-device speech to text. The app uses the Speech framework (`SpeechTranscriberAdapter`);
/// tests and the Debug launch argument `-DSHMFakeSpeech` use `FakeTranscriber`.
@MainActor
public protocol Transcriber: AnyObject {
    /// Asks for the microphone and speech recognition, the first time; then says what is allowed.
    func permission() async -> DictationPermission
    /// Starts to listen. The results come in order; the stream ends after the final result, or
    /// with an error.
    func start() async throws -> AsyncThrowingStream<DictationResult, any Error>
    /// Stops listening. What was heard becomes the final result, then the stream ends.
    func stop()
}

/// Makes a transcriber for one dictation.
public struct TranscriberFactory: Sendable {
    public let make: @MainActor @Sendable () -> any Transcriber

    public init(_ make: @escaping @MainActor @Sendable () -> any Transcriber) {
        self.make = make
    }
}

/// Where the dictated words are in the field. Dictation starts at the end of the text
/// that is already there; each result replaces the words of the result before it, and the text
/// around them stays as the user typed it, also text typed while the user speaks.
public struct DictationSplice: Equatable, Sendable {
    /// UTF-16 offset of the dictated words in the field.
    public private(set) var start: Int
    /// The words of the last result, with the space put in front of them (if any).
    public private(set) var dictated = ""

    public init(text: String) {
        start = text.utf16.count
    }

    /// The field's new text with `result` in place of the last result, or nil when the user
    /// changed the dictated words: then the user's edit wins and dictation stops.
    public mutating func apply(_ result: String, to text: String) -> String? {
        let field = text as NSString
        var location = start
        let length = dictated.utf16.count
        if location + length > field.length || field.substring(with: NSRange(location: location, length: length)) != dictated {
            guard !dictated.isEmpty else {
                // Nothing dictated yet and the text before moved: dictate at the end.
                location = field.length
                start = location
                return splice(result, into: field, at: location, length: 0)
            }
            let found = field.range(of: dictated, options: .backwards)
            guard found.location != NSNotFound else { return nil }
            location = found.location
            start = location
        }
        return splice(result, into: field, at: location, length: length)
    }

    private mutating func splice(_ result: String, into field: NSString, at location: Int, length: Int) -> String {
        let before = field.substring(to: location)
        let words = result.isEmpty ? "" : (Self.needsSpace(after: before, before: result) ? " " : "") + result
        dictated = words
        return field.replacingCharacters(in: NSRange(location: location, length: length), with: words)
    }

    /// A space between typed text and dictated words in languages that write spaces (English),
    /// not in Chinese or Japanese, and not after a space or a new line.
    static func needsSpace(after before: String, before words: String) -> Bool {
        guard let last = before.last, let first = words.first else { return false }
        if last.isWhitespace || first.isWhitespace { return false }
        if last.isCJK || first.isCJK { return false }
        if first.isPunctuation { return false }
        return true
    }
}

extension Character {
    /// Chinese, Japanese and Korean characters and their punctuation: written with no spaces.
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x2FA1F: true
            default: false
            }
        }
    }
}

/// One composer's dictation: the mic key starts and stops it, and the results go into the
/// field through `read` and `write`. Nothing is sent: the user edits the text and taps send.
@MainActor
@Observable
public final class Dictation {
    public enum State: Equatable, Sendable {
        case idle
        /// Asking for permission, or waiting for the speech model.
        case starting
        case listening
        /// The user or the device does not allow it; the field did not change.
        case notAllowed(DictationPermission)
        case failed(String)
    }

    public private(set) var state: State = .idle
    @ObservationIgnored private var transcriber: (any Transcriber)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init() {}

    public var isActive: Bool { state == .starting || state == .listening }

    /// The mic key: starts to listen, or stops.
    public func toggle(using factory: TranscriberFactory, read: @escaping @MainActor () -> String,
                       write: @escaping @MainActor (String) -> Void) {
        if isActive { stop() } else { start(using: factory, read: read, write: write) }
    }

    public func start(using factory: TranscriberFactory, read: @escaping @MainActor () -> String,
                      write: @escaping @MainActor (String) -> Void) {
        guard !isActive else { return }
        generation += 1
        let generation = generation
        state = .starting
        let transcriber = factory.make()
        self.transcriber = transcriber
        task = Task { [weak self] in
            let permission = await transcriber.permission()
            guard let self, self.generation == generation else { return }
            guard permission == .granted else {
                self.finish(generation, .notAllowed(permission))
                return
            }
            do {
                let results = try await transcriber.start()
                guard self.generation == generation else { transcriber.stop(); return }
                self.state = .listening
                var splice = DictationSplice(text: read())
                for try await result in results {
                    guard self.generation == generation else { break }
                    guard let text = splice.apply(result.text, to: read()) else {
                        transcriber.stop() // the user edited the dictated words: their edit wins
                        break
                    }
                    write(text)
                    if result.isFinal { break }
                }
                self.finish(generation, .idle)
            } catch is CancellationError {
                self.finish(generation, .idle)
            } catch {
                self.finish(generation, .failed(String(describing: error)))
            }
        }
    }

    /// Stops listening; the final result still comes into the field.
    public func stop() {
        guard isActive else { return }
        if state == .starting { cancel(); return }
        transcriber?.stop()
    }

    /// Stops at once, for example when the user taps send: the field keeps what it has.
    public func cancel() {
        guard isActive else { return }
        generation += 1
        transcriber?.stop()
        transcriber = nil
        task?.cancel()
        task = nil
        state = .idle
    }

    /// Hides the line that says dictation is not allowed or failed.
    public func clearNotice() {
        if !isActive { state = .idle }
    }

    private func finish(_ generation: Int, _ state: State) {
        guard self.generation == generation else { return }
        transcriber = nil
        task = nil
        self.state = state
    }
}
