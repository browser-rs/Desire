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
    private var silenceTimer: Timer?
    private let silenceTimeout: TimeInterval = 2.0

    nonisolated static func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    init(locale: Locale = .current) {
        // Prefer system locale, fall back to zh-CN, then device default.
        speechRecognizer = SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer()
        if speechRecognizer == nil {
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
                    self?.setError("语音识别未授权 — 请在 系统设置 > 隐私与安全性 > 语音识别 中允许 Desire")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.setError("麦克风访问被拒绝 — 请在 系统设置 > 隐私与安全性 > 麦克风 中允许 Desire")
                            return
                        }
                        // Brief delay: the audio subsystem needs a moment
                        // after permission grant before the engine can start.
                        try? await Task.sleep(nanoseconds: 300_000_000)
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
            setError("语音识别不可用 — 请检查网络连接")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        // Specify a concrete format to force the system to convert input —
        // avoids the macOS pitfall where outputFormat returns 0 Hz / 0 ch
        // when no input device is pre-selected.
        let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100, channels: 1, interleaved: false
        )!
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            setError("音频引擎启动失败: \(error.localizedDescription)")
            return
        }

        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.partialTranscript = text
                    self.resetSilenceTimer()
                    if result.isFinal { self.stop() }
                }
                if error != nil { self.stop() }
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
        isListening = false
    }
}
