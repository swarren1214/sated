import AVFoundation
import Observation
import OSLog
import UIKit

nonisolated extension SettingsKey {
    /// The Kokoro voice Coach speaks with.
    static let coachVoice = "coach.voice"
}

/// Speaks Coach's replies out loud, entirely on the iPhone.
///
/// With the natural voice downloaded, Kokoro generates the speech on the device, a sentence or
/// two at a time, so the first words play while the rest is still being made. Without it (or
/// in the Simulator, where MLX can't run), the best Apple voice installed on the phone reads
/// the reply instead.
@Observable
final class CoachSpeaker: NSObject {
    static let shared = CoachSpeaker()

    enum State: Equatable {
        case idle
        /// Generating the first sentence.
        case preparing
        case speaking
    }

    private(set) var state: State = .idle
    var isActive: Bool { state != .idle }

    private let log = Logger(subsystem: "com.stephenwarren.sated", category: "speaker")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: KokoroSynth.sampleRate, channels: 1)!
    private let synthesizer = AVSpeechSynthesizer()
    /// Bumped by every speak and stop, so callbacks from an earlier reply are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var producer: Task<Void, Never>?
    @ObservationIgnored private var pendingBuffers = 0
    @ObservationIgnored private var producing = false
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?

    override init() {
        super.init()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        synthesizer.delegate = self
        // Another part of the app (or another app) took the audio hardware: stop cleanly.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// Whether replies use the natural voice right now.
    var usesNaturalVoice: Bool { KokoroModel.shared.isReady }

    private var voiceID: String {
        let saved = UserDefaults.standard.string(forKey: SettingsKey.coachVoice) ?? KokoroVoices.defaultID
        return KokoroVoices.voice(saved) == nil ? KokoroVoices.defaultID : saved
    }

    /// Loads the model ahead of a reply, so speech starts sooner.
    func prewarm() {
        if usesNaturalVoice { KokoroSynth.shared.prewarm() }
    }

    func speak(_ text: String) {
        stop()
        let prepared = KokoroText.prepare(text)
        guard !prepared.isEmpty else { return }
        let current = generation
        state = .preparing
        Task {
            do {
                try await AudioSessionControl.activateForPlayback()
            } catch {
                log.error("Couldn't start audio: \(error.localizedDescription, privacy: .public)")
            }
            guard current == generation else { return }
            if usesNaturalVoice {
                producer = Task { await speakNaturally(Self.groups(prepared), generation: current) }
            } else {
                speakWithSystemVoice(prepared)
            }
        }
    }

    func stop() {
        generation += 1
        producer?.cancel()
        producer = nil
        producing = false
        pendingBuffers = 0
        player.stop()
        if engine.isRunning { engine.stop() }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if state != .idle {
            state = .idle
            AudioSessionControl.deactivate()
        }
    }

    /// The reply is done: give the audio back so other apps' music comes back up.
    private func finished() {
        if engine.isRunning { engine.stop() }
        state = .idle
        AudioSessionControl.deactivate()
    }

    // MARK: Natural voice

    /// Generates sentence groups one after another and queues each as it's ready.
    private func speakNaturally(_ groups: [String], generation current: Int) async {
        guard startEngine() else {
            speakWithSystemVoice(groups.joined(separator: " "))
            return
        }
        producing = true
        player.play()
        for (index, piece) in groups.enumerated() {
            guard !Task.isCancelled, current == generation else { return }
            let samples: [Float]
            do {
                samples = try await KokoroSynth.shared.synthesize(piece, voice: voiceID, gpu: UIApplication.shared.applicationState == .active)
            } catch {
                guard current == generation else { return }
                log.error("Natural voice failed, using the system voice: \(error.localizedDescription, privacy: .public)")
                // Say the rest with the system voice rather than going quiet. Moving the
                // generation on first keeps the stopped buffers' callbacks from ending it.
                generation += 1
                producing = false
                pendingBuffers = 0
                player.stop()
                speakWithSystemVoice(groups[index...].joined(separator: " "))
                return
            }
            guard !Task.isCancelled, current == generation, let buffer = makeBuffer(samples) else { continue }
            pendingBuffers += 1
            state = .speaking
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in self?.bufferFinished(generation: current) }
            }
        }
        guard current == generation else { return }
        producing = false
        if pendingBuffers == 0 { finished() }
    }

    private func bufferFinished(generation current: Int) {
        guard current == generation else { return }
        pendingBuffers = max(pendingBuffers - 1, 0)
        if pendingBuffers == 0, !producing { finished() }
    }

    /// The first sentence alone so speech starts fast, then up to ~240 characters at a time.
    static func groups(_ text: String) -> [String] {
        let sentences = KokoroText.sentences(text).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = sentences.first else { return [] }
        var groups = [first]
        var current = ""
        for sentence in sentences.dropFirst() {
            if current.count + sentence.count > 240, !current.isEmpty {
                groups.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + sentence
        }
        if !current.isEmpty { groups.append(current) }
        return groups.flatMap { KokoroText.chunks($0) }
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        // A short breath after each group.
        let silence = Int(0.12 * KokoroSynth.sampleRate)
        let frames = samples.count + silence
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        (channel + samples.count).update(repeating: 0, count: silence)
        return buffer
    }

    /// Starts the engine; false when it can't (playing a node then would crash the app).
    private func startEngine() -> Bool {
        guard !engine.isRunning else { return true }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            log.error("Couldn't start the audio engine: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: System voice

    private func speakWithSystemVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestSystemVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        state = .speaking
        synthesizer.speak(utterance)
    }

    fileprivate func systemVoiceFinished() {
        guard !producing, state == .speaking, !synthesizer.isSpeaking else { return }
        finished()
    }

    /// The highest-quality English voice on the phone: Premium, then Enhanced, then the default.
    static var bestSystemVoice: AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier == "en" ? Locale.current.identifier.replacingOccurrences(of: "_", with: "-") : "en-US"
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let ranked = english.sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
            return (lhs.language == language ? 1 : 0) > (rhs.language == language ? 1 : 0)
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: language)
    }
}

extension CoachSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.systemVoiceFinished() }
    }
}
