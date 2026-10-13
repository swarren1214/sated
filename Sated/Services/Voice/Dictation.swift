import AVFoundation
import Foundation
import OSLog
import Speech

/// Live speech-to-text on the iPhone, for voice logging and talking to Coach.
///
/// Recognition is required to run on device, so audio never leaves the phone. Uses
/// SFSpeechRecognizer; SpeechAnalyzer (iOS 26) is the planned replacement once the voice
/// screens settle, and only this type needs to change.
@Observable
final class Dictation {
    enum State: Equatable {
        case idle
        case listening
        case denied
        case unavailable
    }

    private(set) var state: State = .idle
    private(set) var transcript = ""
    /// Recent input loudness, 0...1, for the waveform.
    private(set) var level: Double = 0

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let log = Logger(subsystem: "com.stephenwarren.sated", category: "dictation")

    var isListening: Bool { state == .listening }

    func start() async {
        guard state != .listening else { return }
        transcript = ""
        guard await Self.requestPermissions() else {
            state = .denied
            return
        }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            state = .unavailable
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.addsPunctuation = true
            self.request = request

            Self.installTap(on: engine.inputNode, request: request) { [weak self] level in
                Task { @MainActor in self?.level = level }
            }
            engine.prepare()
            try engine.start()

            task = Self.recognize(with: recognizer, request: request) { [weak self] text, isFinal, failed in
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if isFinal || failed { self.finish() }
                }
            }
            state = .listening
        } catch {
            log.error("Couldn't start listening: \(error.localizedDescription, privacy: .public)")
            finish()
            state = .unavailable
        }
    }

    /// Stops listening and keeps the transcript so far.
    func stop() {
        request?.endAudio()
        finish()
    }

    private func finish() {
        if engine.isRunning { engine.stop() }
        // Safe when no tap is installed; also clears one left by a start that failed.
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        level = 0
        if state == .listening { state = .idle }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // The audio tap and recognition callbacks run on background queues, so they're built in
    // nonisolated functions and hop to the main actor themselves.

    private nonisolated static func installTap(on input: AVAudioInputNode, request: SFSpeechAudioBufferRecognitionRequest, level: @escaping @Sendable (Double) -> Void) {
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            let rms = sqrt(sum / Float(count))
            level(min(Double(rms) * 12, 1))
        }
    }

    private nonisolated static func recognize(with recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest, update: @escaping @Sendable (String?, Bool, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            update(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    private nonisolated static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
