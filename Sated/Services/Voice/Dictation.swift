import AVFoundation
import Foundation
import Observation
import OSLog
import os
import Speech

/// Live speech-to-text on the iPhone, for voice logging and talking to Coach.
///
/// Recognition is required to run on device, so audio never leaves the phone. (The Simulator
/// has no on-device speech model, so debug runs there fall back to Apple's server.) Uses
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

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Bumped on every start and finish, so callbacks from an earlier listen are ignored.
    @ObservationIgnored private var session = 0
    /// Microphone buffers received in this listen, to notice a silent microphone.
    @ObservationIgnored private let buffersSeen = OSAllocatedUnfairLock(initialState: 0)
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.sated", category: "dictation")

    var isListening: Bool { state == .listening }

    init() {
        // The first recording after launch can switch the audio hardware a moment after the
        // engine starts; the engine then stops itself and the microphone goes quiet.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartMicrophone() }
        }
    }

    func start() async {
        guard state != .listening else { return }
        // Coach may still be talking: it has to stop before the microphone opens.
        CoachSpeaker.shared.stop()
        session += 1
        let current = session
        transcript = ""
        guard await Self.requestPermissions() else {
            state = .denied
            return
        }
        guard let recognizer, recognizer.isAvailable, Self.canRecognize(with: recognizer) else {
            log.error("Speech recognition unavailable")
            state = .unavailable
            return
        }
        do {
            try await AudioSessionControl.activateForRecording()
            guard current == session else { return }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            request.addsPunctuation = true
            self.request = request

            try startMicrophone(request: request, session: current)

            task = Self.recognize(with: recognizer, request: request) { [weak self] text, isFinal, failed in
                let dictation = self
                Task { @MainActor in
                    guard let self = dictation, current == self.session else { return }
                    if let text { self.transcript = text }
                    if isFinal || failed { self.finish() }
                }
            }
            state = .listening
            watchForSilence(session: current)
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

    /// Installs the tap with the input's current format and starts the engine.
    private func startMicrophone(request: SFSpeechAudioBufferRecognitionRequest, session current: Int) throws {
        let seen = buffersSeen
        seen.withLock { $0 = 0 }
        engine.inputNode.removeTap(onBus: 0)
        Self.installTap(on: engine.inputNode, request: request) { [weak self] level in
            seen.withLock { $0 += 1 }
            let dictation = self
            Task { @MainActor in
                guard let self = dictation, current == self.session else { return }
                self.level = level
            }
        }
        engine.prepare()
        try engine.start()
    }

    /// Starts the microphone again into the same recognition request.
    private func restartMicrophone() {
        guard state == .listening, let request else { return }
        log.notice("Restarting the microphone after a configuration change")
        if engine.isRunning { engine.stop() }
        do {
            try startMicrophone(request: request, session: session)
            watchForSilence(session: session)
        } catch {
            log.error("Couldn't restart the microphone: \(error.localizedDescription, privacy: .public)")
            finish()
            state = .unavailable
        }
    }

    /// If no audio arrives soon after starting, restart the microphone once.
    private func watchForSilence(session current: Int, retry: Bool = true) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self, current == self.session, self.state == .listening else { return }
            guard self.buffersSeen.withLock({ $0 }) == 0 else { return }
            if retry, let request = self.request {
                self.log.notice("No microphone audio yet; restarting")
                if self.engine.isRunning { self.engine.stop() }
                do {
                    try self.startMicrophone(request: request, session: current)
                    self.watchForSilence(session: current, retry: false)
                    return
                } catch {}
            }
            self.log.error("The microphone stayed silent")
            self.finish()
            self.state = .unavailable
        }
    }

    private func finish() {
        watchdog?.cancel()
        watchdog = nil
        // Anything still arriving from this listen is now stale.
        session += 1
        if engine.isRunning { engine.stop() }
        // Safe when no tap is installed; also clears one left by a start that failed.
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        level = 0
        if state == .listening { state = .idle }
        AudioSessionControl.deactivate()
    }

    /// On a real iPhone, only on-device recognition is allowed. The Simulator has none.
    private static func canRecognize(with recognizer: SFSpeechRecognizer) -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return recognizer.supportsOnDeviceRecognition
        #endif
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
