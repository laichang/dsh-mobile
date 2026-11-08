@preconcurrency import AVFoundation
import DSHCore
import Speech

/// On-device speech to text with iOS 26's `SpeechAnalyzer` (ARCHITECTURE D116): the microphone
/// goes through `AVAudioEngine` into the analyzer, in the language of the phone. It uses
/// `SpeechTranscriber` where the device has it, else `DictationTranscriber` (the keyboard's
/// dictation model, on more devices). Nothing leaves the phone; the first use of a language can
/// download its model (the system's own assets).
@MainActor
final class SpeechFrameworkTranscriber: Transcriber {
    enum Failure: Error, CustomStringConvertible {
        case noLanguage
        case noMicrophone

        var description: String {
            switch self {
            case .noLanguage: String(localized: "Speech to text is not available for this language on this iPhone.", table: "Voice")
            case .noMicrophone: String(localized: "The microphone is not available.", table: "Voice")
            }
        }
    }

    nonisolated static let factory = TranscriberFactory { SpeechFrameworkTranscriber() }

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var audio: AsyncStream<AnalyzerInput>.Continuation?
    private var listening = false

    func permission() async -> DictationPermission {
        let speech = await withCheckedContinuation { (done: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
        }
        switch speech {
        case .authorized: break
        case .restricted: return .restricted
        default: return .denied
        }
        guard await AVAudioApplication.requestRecordPermission() else { return .denied }
        return .granted
    }

    func start() async throws -> AsyncThrowingStream<DictationResult, any Error> {
        let (stream, out) = AsyncThrowingStream<DictationResult, any Error>.makeStream()
        let module: any SpeechModule
        let pump: Task<Void, Never>
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
            module = transcriber
            pump = Self.forward(transcriber.results, to: out) { (String($0.text.characters), $0.isFinal) }
        } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) {
            let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
            module = transcriber
            pump = Self.forward(transcriber.results, to: out) { (String($0.text.characters), $0.isFinal) }
        } else {
            throw Failure.noLanguage
        }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = engine.inputNode
            let natural = input.outputFormat(forBus: 0)
            guard natural.channelCount > 0 else { throw Failure.noMicrophone }
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: natural) ?? natural
            let analyzer = SpeechAnalyzer(modules: [module])
            try await analyzer.prepareToAnalyze(in: format)
            let (inputs, audio) = AsyncStream<AnalyzerInput>.makeStream()
            input.installTap(onBus: 0, bufferSize: 4096, format: natural, block: Self.tap(from: natural, to: format, into: audio))
            engine.prepare()
            try engine.start()
            try await analyzer.start(inputSequence: inputs)
            self.analyzer = analyzer
            self.audio = audio
            listening = true
        } catch {
            pump.cancel()
            out.finish()
            stopAudio()
            throw error
        }
        out.onTermination = { _ in pump.cancel() }
        return stream
    }

    func stop() {
        guard listening else { return }
        listening = false
        stopAudio()
        audio?.finish()
        audio = nil
        let analyzer = analyzer
        self.analyzer = nil
        // The words still in the analyzer become final; then its results end, and so does the stream.
        Task { try? await analyzer?.finalizeAndFinishThroughEndOfInput() }
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Finalized words add up; the volatile words after them change until they are final (D117).
    private nonisolated static func forward<Results: AsyncSequence & Sendable>(
        _ results: Results, to out: AsyncThrowingStream<DictationResult, any Error>.Continuation,
        _ read: @escaping @Sendable (Results.Element) -> (String, Bool)
    ) -> Task<Void, Never> {
        Task {
            var finalized = ""
            do {
                for try await element in results {
                    let (text, isFinal) = read(element)
                    if isFinal { finalized += text; out.yield(DictationResult(finalized)) }
                    else { out.yield(DictationResult(finalized + text)) }
                }
                out.yield(DictationResult(finalized, isFinal: true))
                out.finish()
            } catch {
                out.finish(throwing: error)
            }
        }
    }

    /// The microphone tap runs on the audio thread, so it is made outside the main actor. Each
    /// buffer is converted to the analyzer's format when the two are not the same.
    private nonisolated static func tap(from natural: AVAudioFormat, to format: AVAudioFormat,
                                        into audio: AsyncStream<AnalyzerInput>.Continuation) -> AVAudioNodeTapBlock {
        let converter = natural == format ? nil : AVAudioConverter(from: natural, to: format)
        return { buffer, _ in
            guard let converter else {
                audio.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / natural.sampleRate).rounded(.up)) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            let fed = Fed()
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if fed.done { status.pointee = .noDataNow; return nil }
                fed.done = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, converted.frameLength > 0 { audio.yield(AnalyzerInput(buffer: converted)) }
        }
    }

    private nonisolated final class Fed: @unchecked Sendable {
        var done = false
    }
}
