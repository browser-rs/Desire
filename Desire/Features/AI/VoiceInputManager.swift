import AVFoundation
import Combine
import Foundation
import os
import Speech

/// Speech-to-text engine for voice commands. Wraps `SFSpeechRecognizer` +
/// `AVAudioEngine` with live partial results and silence auto-stop.
///
/// Permissions are checked in `init` and re-requested on `start()` if not
/// yet granted. Recognition only begins after BOTH permissions are confirmed.
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

    private var hasMicPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private var hasSpeechPermission: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    nonisolated static func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    init(locale: Locale = .current) {
        // Try zh-CN first (target market), then system locale, then default.
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer()
        if speechRecognizer == nil {
            isAvailable = false
            Log.ai.error("voice: SFSpeechRecognizer init returned nil")
        }
    }

    // MARK: - Start / Stop

    func start() {
        guard !isListening else { return }
        errorMessage = nil
        partialTranscript = ""

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "语音识别不可用"
            return
        }

        // Request permissions if not yet granted — returns after triggering
        // the system dialog. User taps mic again after granting.
        if !hasMicPermission {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            errorMessage = "请允许麦克风权限后重试"
            return
        }
        if !hasSpeechPermission {
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    if status != .authorized {
                        self.errorMessage = "语音识别未授权 — 请在系统设置中允许"
                    }
                    // User will tap mic again after granting.
                }
            }
            errorMessage = "请在弹窗中允许语音识别后重试"
            return
        }

        beginRecognition(with: recognizer)
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

    private func beginRecognition(with recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Prefer on-device when supported: works offline (important for
        // China network) and avoids server round-trip latency.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        // Guard against invalid format (no input device selected).
        guard inputFormat.sampleRate > 0 else {
            errorMessage = "未检测到音频输入设备"
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            setError("音频引擎启动失败: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            return
        }

        isListening = true
        // Max listening duration safety net (30s).
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
        }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.partialTranscript = text
                    self.resetSilenceTimer()
                    if result.isFinal { self.stop() }
                }
                if let error {
                    let nsError = error as NSError
                    if nsError.code != 216 { // 216 = user cancelled
                        self.errorMessage = "识别错误: \(nsError.localizedDescription)"
                        self.isListening = false
                    }
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
        isListening = false
    }
}
