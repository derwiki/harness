//
//  Dictation.swift
//  Harness
//

import AVFAudio
import Foundation
import Observation

/// Wispr-style dictation: records the microphone, then sends the audio through OpenRouter (zero data
/// retention) to an audio model that transcribes it and cleans it up in one step: filler words removed,
/// spoken self-corrections applied ("Tuesday, no wait, Wednesday"), punctuation added.
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case transcribing
    }

    /// Recordings shorter than this are treated as an accidental tap and discarded.
    static let minimumDuration: TimeInterval = 0.5
    /// About 9.6 MB of 16 kHz mono WAV; keeps the upload a reasonable size.
    static let maximumDuration: TimeInterval = 300

    /// Number of recent level samples kept for the meter (about 1.5 s at 20 samples per second).
    static let levelHistoryCount = 30

    private(set) var state: State = .idle
    var errorMessage: String?
    /// Recent microphone levels, 0 (silent) to 1 (loud), oldest first. Updated about 20 times per second.
    private(set) var levels: [Float] = Array(repeating: 0, count: levelHistoryCount)

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var transcription: Task<String?, Never>?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    // MARK: - Recording

    func start() async {
        guard state == .idle else { return }
        errorMessage = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone access is off. Turn it on in Settings > Privacy & Security > Microphone > Harness."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            // Uncompressed 16 kHz mono: in testing, compressed audio made transcription noticeably worse.
            let url = FileManager.default.temporaryDirectory.appending(path: "dictation-\(UUID().uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: Self.maximumDuration) else {
                throw DictationError(message: "Could not start recording.")
            }
            self.recorder = recorder
            state = .recording(startedAt: Date())
            startMetering(recorder)
        } catch {
            errorMessage = error.localizedDescription
            deactivateSession()
        }
    }

    /// Stops recording and returns the cleaned-up text, or nil if there was nothing to transcribe.
    func stopAndTranscribe() async -> String? {
        guard case .recording(let startedAt) = state, let recorder else { return nil }
        stopMetering()
        recorder.stop()
        self.recorder = nil
        deactivateSession()
        let url = recorder.url
        defer { try? FileManager.default.removeItem(at: url) }

        guard Date().timeIntervalSince(startedAt) >= Self.minimumDuration else {
            state = .idle
            return nil
        }
        // Audio models invent words ("Thank you") for silent clips, so never upload one.
        guard Self.containsSpeech(audioAt: url) else {
            errorMessage = "No speech was detected."
            state = .idle
            return nil
        }

        state = .transcribing
        let task = Task { () -> String? in
            do {
                let text = try await Self.transcribe(audioAt: url)
                if text.isEmpty { errorMessage = "No speech was detected." }
                return text.isEmpty ? nil : text
            } catch is CancellationError {
                return nil
            } catch let error as URLError where error.code == .cancelled {
                return nil
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
        }
        transcription = task
        let result = await task.value
        transcription = nil
        state = .idle
        return result
    }

    /// Discards the recording, or abandons a transcription in progress.
    func cancel() {
        stopMetering()
        if let recorder {
            recorder.stop()
            recorder.deleteRecording()
            self.recorder = nil
            deactivateSession()
        }
        transcription?.cancel()
        state = .idle
    }

    // MARK: - Level meter

    private func startMetering(_ recorder: AVAudioRecorder) {
        levels = Array(repeating: 0, count: Self.levelHistoryCount)
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                recorder.updateMeters()
                self?.pushLevel(Self.normalizedLevel(decibels: recorder.averagePower(forChannel: 0)))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
    }

    private func pushLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    /// Maps average power to 0...1: -50 dBFS (quiet room) is 0, -10 dBFS (loud speech) is 1.
    static func normalizedLevel(decibels: Float) -> Float {
        min(max((decibels + 50) / 40, 0), 1)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Speech check

    /// Loudness, in dBFS, that a 20 ms frame must reach to count as possible speech.
    /// Quiet rooms measure about -60 to -50 dBFS; normal speech about -35 to -10 dBFS.
    nonisolated static let speechThreshold: Float = -42
    /// Total loud audio needed to count as speech (15 frames of 20 ms = 0.3 s).
    nonisolated static let minimumSpeechFrames = 15

    /// True if the recording has enough loud frames to be worth transcribing.
    nonisolated static func containsSpeech(audioAt url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let samples = buffer.floatChannelData?[0]
        else { return true } // If the file cannot be analyzed, let the model decide.

        let frameLength = max(1, Int(file.processingFormat.sampleRate * 0.02))
        let count = Int(buffer.frameLength)
        var loudFrames = 0
        var start = 0
        while start < count {
            let end = min(start + frameLength, count)
            var sumOfSquares: Float = 0
            for index in start..<end { sumOfSquares += samples[index] * samples[index] }
            let rms = (sumOfSquares / Float(end - start)).squareRoot()
            if 20 * log10(max(rms, 1e-9)) >= speechThreshold {
                loudFrames += 1
                if loudFrames >= minimumSpeechFrames { return true }
            }
            start = end
        }
        return false
    }

    // MARK: - Transcription

    static let systemPrompt = """
        You are a dictation engine. Transcribe the speech and return only the text the speaker meant to type. \
        Remove filler words (um, uh, like, you know), stutters, and false starts. Apply spoken self-corrections \
        ("no wait", "actually", "scratch that", "never mind") so only the final intent remains. \
        Add punctuation and capitalization. Keep the speaker's own wording; do not answer, summarize, or add anything. \
        If there is no speech, return nothing.
        """

    private static func transcribe(audioAt url: URL) async throws -> String {
        guard let apiKey = KeychainStore.readAPIKey(), !apiKey.isEmpty else {
            throw DictationError(message: "Add your OpenRouter API key in Settings.")
        }
        let audio = try Data(contentsOf: url).base64EncodedString()
        let body: [String: Any] = [
            "model": AppSettings.dictationModelID,
            "provider": ["zdr": true],
            "max_tokens": 4_000,
            // Cleanup needs little thought; low effort keeps latency down.
            "reasoning": ["effort": "low"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": [
                    ["type": "input_audio", "input_audio": ["data": audio, "format": "wav"]],
                ]],
            ],
        ]

        var request = URLRequest(url: OpenRouterClient.endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Harness", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            throw DictationError(message: "Dictation failed (HTTP \(status)): \(message)")
        }
        let choices = json?["choices"] as? [[String: Any]]
        let content = (choices?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DictationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
