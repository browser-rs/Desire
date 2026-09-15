import AVFoundation
import Combine
import Foundation
import Speech

/// Voice input for AI commands — based on the proven IrsClawApp
/// VoiceInputService implementation. Press mic to record, tap again
/// or silence to stop, text goes to the AI agent.
@MainActor
class VoiceInputManager: ObservableObject {
    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasMicrophonePermission = false
    private var hasSpeechPermission = false

    var isAvailable: Bool {
        speechRecognizer?.isAvailable ?? false
    }

    init() {
        let cnRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        let enRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        print("[VoiceInput] zh-CN available: \(cnRecognizer?.isAvailable ?? false), en-US available: \(enRecognizer?.isAvailable ?? false)")

        self.speechRecognizer = cnRecognizer
            ?? enRecognizer
            ?? SFSpeechRecognizer()
        print("[VoiceInput] Using locale: \(self.speechRecognizer?.locale.identifier ?? "nil")")

        checkPermissions()
    }

    // MARK: - Permissions

    private func checkPermissions() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            hasSpeechPermission = true
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    self.hasSpeechPermission = status == .authorized
                }
            }
        default:
            hasSpeechPermission = false
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasMicrophonePermission = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.hasMicrophonePermission = granted
                }
            }
        default:
            hasMicrophonePermission = false
        }
    }

    // MARK: - Control

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording else { return }
        errorMessage = nil

        guard hasMicrophonePermission, hasSpeechPermission else {
            errorMessage = "需要麦克风和语音识别权限"
            checkPermissions()
            return
        }

        guard let recognizer = speechRecognizer else {
            errorMessage = "Speech recognizer not available"
            return
        }
        guard recognizer.isAvailable else {
            errorMessage = "Speech recognizer is busy. Try again later."
            return
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        if inputFormat.sampleRate == 0 {
            errorMessage = "No audio input device found"
            return
        }

        transcribedText = ""
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let error {
                let nsError = error as NSError
                if nsError.code != 216 {
                    Task { @MainActor [weak self] in
                        switch nsError.code {
                        case 203:
                            self?.errorMessage = "No speech detected. Please speak louder or check your microphone."
                        default:
                            self?.errorMessage = "Recognition error: \(nsError.localizedDescription)"
                        }
                    }
                }
            }

            if let result {
                Task { @MainActor [weak self] in
                    self?.transcribedText = result.bestTranscription.formattedString
                }
            }

            if result?.isFinal == true {
                Task { @MainActor [weak self] in
                    self?.stop()
                }
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            request.append(buffer)
        }

        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[VoiceInput] AVAudioSession setup failed: \(error)")
        }
        #endif

        isRecording = true
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            isRecording = false
            audioEngine.inputNode.removeTap(onBus: 0)
            errorMessage = "Failed to start microphone: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask = nil

        if !transcribedText.isEmpty {
            print("[VoiceInput] Final text (\(transcribedText.count) chars): \(transcribedText)")
        } else {
            print("[VoiceInput] No transcription result")
        }
    }
}
