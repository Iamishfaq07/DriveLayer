import Foundation
#if canImport(Speech)
import Speech
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Turns speech into a question, on the device and nowhere else.
///
/// `SFSpeechRecognizer` sends audio to Apple's servers by default. For this product
/// that default is not a trade-off to weigh - it is the one thing the whole app
/// promises not to do - so `requiresOnDeviceRecognition` is set and, crucially,
/// **there is no server fallback**. A device that cannot recognise speech locally
/// gets an honest refusal rather than a quiet upload. That is the entire reason this
/// type has an `Unavailable` case instead of just working everywhere.
///
/// Nothing here is stored. Audio buffers go to the recogniser and are released; the
/// transcript exists only long enough to become a question.
@MainActor
final class VoiceCapture {

    enum Unavailable: Equatable {
        case notPermitted
        case speechNotAuthorised
        case onDeviceRecognitionUnsupported
        case failedToStart

        /// Said to a driver, so it names the fix rather than the fault.
        var message: String {
            switch self {
            case .notPermitted:
                return "DriveLayer needs microphone access to listen. You can turn it on in Settings."
            case .speechNotAuthorised:
                return "DriveLayer needs speech recognition access. You can turn it on in Settings."
            case .onDeviceRecognitionUnsupported:
                return "This iPhone can't recognise speech without sending audio to Apple, so DriveLayer won't listen. Tap a question instead."
            case .failedToStart:
                return "Couldn't start listening. Tap a question instead."
            }
        }
    }

    #if canImport(Speech) && canImport(AVFoundation)
    private let recogniser = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    #endif

    private var onTranscript: ((String) -> Void)?
    private var stopWorkItem: DispatchWorkItem?
    private(set) var isListening = false

    /// Everything that must be true before a single buffer is captured.
    ///
    /// Checked up front rather than discovered halfway through, so the caller can show
    /// one clear reason instead of starting a session that dies quietly.
    func availability() async -> Unavailable? {
        #if canImport(Speech) && canImport(AVFoundation)
        guard let recogniser, recogniser.isAvailable else { return .failedToStart }
        // The line this product will not cross: no local recognition, no listening.
        guard recogniser.supportsOnDeviceRecognition else { return .onDeviceRecognitionUnsupported }

        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return .speechNotAuthorised }

        let microphone = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard microphone else { return .notPermitted }
        return nil
        #else
        return .failedToStart
        #endif
    }

    /// Listens until the driver stops talking, or `maximumDuration` passes.
    ///
    /// - Parameter onTranscript: called once, on the main actor, with the final text.
    ///   Never called with a partial result: a question that acts on half a sentence
    ///   is worse than one that waits.
    @discardableResult
    func start(maximumDuration: TimeInterval = 10,
               onTranscript: @escaping (String) -> Void) async -> Unavailable? {
        if let unavailable = await availability() { return unavailable }
        #if canImport(Speech) && canImport(AVFoundation)
        guard !isListening, let recogniser else { return .failedToStart }
        self.onTranscript = onTranscript

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        self.request = request

        do {
            let session = AVAudioSession.sharedInstance()
            // Duck rather than interrupt: the driver asked a question, they did not
            // ask for their music to stop and stay stopped.
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1_024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            PrivacyLog.error(.app, "Could not start listening")
            cancel()
            return .failedToStart
        }

        isListening = true
        task = recogniser.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result, result.isFinal {
                    self.finish(with: result.bestTranscription.formattedString)
                } else if error != nil {
                    self.finish(with: nil)
                }
            }
        }

        // A hard ceiling, because a tap that never ends is a microphone left open in
        // someone's car.
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.endAudio() }
        }
        stopWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + maximumDuration, execute: timeout)
        return nil
        #else
        return .failedToStart
        #endif
    }

    /// Stops capturing but lets the recogniser finish what it already heard.
    func endAudio() {
        #if canImport(Speech) && canImport(AVFoundation)
        guard isListening else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        #endif
    }

    /// Stops everything and discards the attempt.
    func cancel() {
        #if canImport(Speech) && canImport(AVFoundation)
        stopWorkItem?.cancel()
        stopWorkItem = nil
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        task?.cancel()
        task = nil
        request = nil
        onTranscript = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func finish(with transcript: String?) {
        let handler = onTranscript
        let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
        cancel()
        if let text, !text.isEmpty { handler?(text) }
    }
}
