import AVFoundation
import Combine
import Foundation
import os
import Speech

/// Speech-to-text engine for voice commands. Wraps `SFSpeechRecognizer` +
/// `AVAudioEngine` with live partial results and silence auto-stop.
///
/// Requires Info.plist entries (add via Xcode target settings):
/// - `NSMicrophoneUsageDescription`
/// - `NSSpeechRecognitionUsageDescription`
@MainActor
final class VoiceInputManager: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isAvailable = true
    @Published var errorMessage: String?

    /// Live partial transcript (updated as the user speaks).
    @Published private(set) var partialTranscript = ""

    /// Called when the user stops talking and a final transcript is ready.
    var onFinalTranscript: ((String) -> Void)?

    private var audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Silence auto-stop timer — resets on every new speech, fires after
    /// `silenceTimeout` seconds of no new recognition results.
    private var silenceTimer: Timer?

    private let silenceTimeout: TimeInterval = 2.0

    nonisolated static func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    init(locale: Locale = .current) {
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        if speechRecognizer == nil || speechRecognizer?.isAvailable != true {
            isAvailable = false
        }
    }

    // MARK: - Start / Stop

    func start() {
        guard !isListening else { return }
        errorMessage = nil
        partialTranscript = ""

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self, status == .authorized else {
                    self?.setError("Speech recognition not authorized")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.setError("Microphone access denied — enable in System Settings > Privacy > Microphone")
                            return
                        }
                        self.beginRecognition()
                    }
                }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        silenceTimer?.invalidate()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        // Deliver whatever we have as final.
        let final = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !final.isEmpty {
            onFinalTranscript?(final)
        }
        partialTranscript = ""
    }

    func toggle() {
        if isListening { stop() } else { start() }
    }

    // MARK: - Recognition pipeline

    private func beginRecognition() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            setError("Speech recognition unavailable")
            return
        }

        request = SFSpeechAudioBufferRecognitionRequest()
        request?.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request?.requiresOnDeviceRecognition = false // server is fine, better accuracy
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            setError("Audio engine failed: \(error.localizedDescription)")
            return
        }

        isListening = true
        task = recognizer.recognitionTask(with: request!) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.partialTranscript = text
                    self.resetSilenceTimer()
                    if result.isFinal {
                        self.stop()
                    }
                }
                if error != nil {
                    self.stop()
                }
            }
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
    }

    private func setError(_ message: String) {
        errorMessage = message
        Log.ai.error("voice input: \(message, privacy: .public)")
    }
}
