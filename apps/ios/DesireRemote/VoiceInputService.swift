import AVFoundation
import Combine
import Speech

/// 语音输入（Speech + AVAudioEngine，中文识别；权限懒请求）。
@MainActor
final class VoiceInputService: ObservableObject {
    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var errorMessage: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        Task { @MainActor in
            // 懒请求权限（只在用户点击时）
            let speechOK: Bool = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
            let micOK: Bool = await withCheckedContinuation { cont in
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
            guard speechOK, micOK else {
                errorMessage = "需要麦克风与语音识别权限（设置 → 隐私）"
                return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)

                let req = SFSpeechAudioBufferRecognitionRequest()
                req.shouldReportPartialResults = true
                request = req
                transcribedText = ""
                errorMessage = nil

                // 局部弱引用：闭包不写捕获列表——Swift 的所有权检查对
                // "[weak self] + 内层 Task 捕获" 组合会误报（clean build 才暴露）
                weak let callbackTarget = self
                task = recognizer?.recognitionTask(with: req) { result, error in
                    guard let callbackTarget else { return }
                    Task { @MainActor in
                        if let result {
                            callbackTarget.transcribedText = result.bestTranscription.formattedString
                            if result.isFinal { callbackTarget.stop() }
                        }
                        if error != nil, callbackTarget.isRecording { callbackTarget.stop() }
                    }
                }

                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    req.append(buffer)
                }
                engine.prepare()
                try engine.start()
                isRecording = true
            } catch {
                errorMessage = error.localizedDescription
                stop()
            }
        }
    }

    func stop() {
        guard isRecording || engine.isRunning else { return }
        isRecording = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
