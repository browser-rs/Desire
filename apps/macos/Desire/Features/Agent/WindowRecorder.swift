import AVFoundation
import AppKit
import Combine
import CoreGraphics
import os
import ScreenCaptureKit

/// Records a browser window to an MP4 via ScreenCaptureKit (window filter —
/// the stream keeps working even when the window is partially covered).
///
/// Flow: `start(window:)` picks the SCWindow for the NSWindow's windowNumber,
/// opens an AVAssetWriter (H.264) and pipes sample buffers into it; `stop()`
/// finalizes and returns the file URL. Requires macOS Screen Recording
/// permission (TCC) — surfaced as a friendly error when missing.
@MainActor
final class WindowRecorder: ObservableObject {
    static let shared = WindowRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var outputURL: URL?

    private var stream: SCStream?
    private var output: RecordingOutput?

    /// True when the OS has granted screen recording to this app.
    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    // MARK: - Start

    func start(window: NSWindow) async throws -> URL {
        guard !isRecording else {
            throw RecordingError.alreadyRecording(outputURL)
        }
        // TCC gate: request triggers the system dialog on first use; the
        // grant only lands after the app relaunches, so report precisely.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            throw RecordingError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == window.windowNumber }) else {
            throw RecordingError.windowNotFound
        }

        let scale: CGFloat = window.screen?.backingScaleFactor ?? 2
        // R2-24：分辨率封顶 2560——5K 全屏 @2x ≈ 59MB/帧 BGRA，queueDepth=10
        // 的缓冲池最坏数百 MB 峰值。长边 clamp 后等比缩放。
        let rawWidth = scWindow.frame.width * scale
        let rawHeight = scWindow.frame.height * scale
        let longEdge = max(rawWidth, rawHeight)
        let capped: CGFloat = longEdge > 2560 ? 2560 / longEdge : 1
        let config = SCStreamConfiguration()
        config.width = Int((rawWidth * capped).rounded())
        config.height = Int((rawHeight * capped).rounded())
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)   // 30 fps
        config.queueDepth = 10
        config.capturesAudio = false
        config.showsCursor = true

        let fileURL = Self.newRecordingURL()
        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: config.width,
                kCVPixelBufferHeightKey as String: config.height,
            ]
        )

        let output = RecordingOutput(writer: writer, input: input, adaptor: adaptor)
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()

        self.stream = stream
        self.output = output
        self.outputURL = fileURL
        startedAt = Date()
        isRecording = true
        return fileURL
    }

    // MARK: - Stop

    @discardableResult
    func stop() async -> URL? {
        guard isRecording, let stream else { return nil }
        try? await stream.stopCapture()
        let url = await output?.finish()
        self.stream = nil
        output = nil
        startedAt = nil
        isRecording = false
        outputURL = url
        return url
    }

    static func newRecordingURL() -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return downloads.appendingPathComponent("Desire-Recording-\(formatter.string(from: Date())).mp4")
    }
}

// MARK: - Sample output → AVAssetWriter

/// Drains screen sample buffers onto the writer. All buffer appends happen
/// on the dedicated queue (AVAssetWriterInput requirement).
final class RecordingOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "me.siwi.Desire.recorder")

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var sessionStarted = false
    private var frameCount = 0

    init(writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor) {
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard input.isReadyForMoreMediaData else { return }

        // AVAssetWriter is not thread-safe: confine every writer interaction
        // (and the sessionStarted/frameCount state) to this serial queue.
        // 本回调**已经在** queue 上跑（addStreamOutput 的 sampleHandlerQueue 就是
        // 它）——此前这里再 queue.sync 自身 = 教科书式 GCD 自死锁：首帧即卡死
        // 交付队列，录屏产出 0 帧坏文件、stop() 等 finish 永不返回（第二轮体检
        // ROUND2-P0，已实证）。直接裸执行即为正确的队列束缚。
        if !sessionStarted {
            // P1-15：startWriting 失败（磁盘满是典型）时置 failed 就走——
            // 状态仍是 .unknown/.failed 时 markAsFinished 会抛 ObjC 异常。
            if writer.startWriting() {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                sessionStarted = true
            } else {
                Log.agent.error("recorder startWriting failed: \(self.writer.error?.localizedDescription ?? "nil", privacy: .public)")
            }
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            frameCount += 1
        }
    }

    /// Finalizes the movie; returns the file URL when writing succeeded.
    func finish() async -> URL? {
        // markAsFinished + finishWriting 都在 sample 回调同一条串行队列上执行
        //（AVAssetWriter 单线程契约）；continuation 等 finishWriting **真正完成**
        // 才 resume——此前 enqueue 完就 resume，主线程的 finishWriting 与队列里
        // 残留的 append 竞态（第二轮体检 ROUND2-P0 附带）。
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                // P1-15：只在 .writing 态收尾——零帧（sessionStarted=false）或
                // startWriting 已失败时调用会抛 ObjC 异常。
                if self.sessionStarted, self.writer.status == .writing {
                    self.input.markAsFinished()
                    self.writer.finishWriting { continuation.resume() }
                    return
                }
                continuation.resume()
            }
        }
        let ok = writer.status == .completed
        if !ok {
            let status = writer.status.rawValue
            let message = writer.error?.localizedDescription ?? "nil"
            Log.agent.error("recorder finish status: \(status) \(message, privacy: .public)")
        }
        return ok ? writer.outputURL : nil
    }
}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case alreadyRecording(URL?)
    case permissionDenied
    case windowNotFound

    var errorDescription: String? {
        switch self {
        case .alreadyRecording(let url):
            "Already recording → \(url?.lastPathComponent ?? "?"). Call stopRecording first."
        case .permissionDenied:
            "Screen Recording permission is required. Grant it in System Settings → Privacy & Security → Screen Recording, then restart the app and try again."
        case .windowNotFound:
            "The browser window is not capturable (it may be minimized)."
        }
    }
}
