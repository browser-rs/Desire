import AVFoundation
import AVKit
import Combine
import Foundation

/// 本地媒体播放引擎（v0.8.27 播放器批）：AVPlayer + 定制控制层的状态中枢。
/// 视图（MediaViewerView）只渲染；播放/seek/倍速/音量/续播/画中画都收在这里。
///
/// 约定：
/// - 周期时间观察者（0.25s）驱动进度；倍速走 `defaultRate`（暂停后恢复仍是倍速）。
/// - **续播**：进度按文件路径存 UserDefaults（每 5 秒 + 暂停/seek 落一次），
///   重开同一文件在 (10s, 结束前 5s) 区间内自动跳回。
/// - 音频/视频判定先按扩展名猜，ready 后以真实音视频轨为准（mkv 抽音轨等边界）。
@MainActor
final class MediaPlayerModel: ObservableObject {

    let fileURL: URL
    let player: AVPlayer

    @Published private(set) var isReady = false
    @Published private(set) var hasVideo: Bool
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var bufferedSeconds: Double = 0
    @Published private(set) var rate: Double = 1
    @Published private(set) var loadError: String?
    @Published var volume: Double = 1 {
        didSet { player.volume = Float(volume) }
    }
    @Published var isMuted = false {
        didSet { player.isMuted = isMuted }
    }
    @Published private(set) var canPictureInPicture = false
    private(set) var pipController: AVPictureInPictureController?

    private var timeObserverToken: Any?
    private var cancellables = Set<AnyCancellable>()
    private var lastSavedBucket = 0

    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    init(url: URL) {
        fileURL = url
        hasVideo = !MediaEditCore.isAudioFile(url)
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        player = AVPlayer(playerItem: item)
        player.volume = 1
        bindObservers()
    }

    deinit {
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
    }

    // MARK: - 观察接线

    private func bindObservers() {
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main) { [weak self] time in
                // 队列就是 main，直接 assumeIsolated 满足严格并发。
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.currentTime = time.seconds
                    self.autosavePosition()
                }
            }

        player.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                guard let self else { return }
                self.isPlaying = status != .paused
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
            .store(in: &cancellables)

        guard let item = player.currentItem else { return }
        item.publisher(for: \.status)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.markReady()
                case .failed:
                    self.loadError = item.error?.localizedDescription
                        ?? String(localized: "Couldn't play this file")
                default:
                    break
                }
            }
            .store(in: &cancellables)
        item.publisher(for: \.loadedTimeRanges)
            .sink { [weak self] ranges in
                guard let self, let first = ranges.first else { return }
                let range = first.timeRangeValue
                self.bufferedSeconds = range.start.seconds + range.duration.seconds
            }
            .store(in: &cancellables)
    }

    private func markReady() {
        guard !isReady else { return }
        isReady = true
        Task { [weak self] in
            guard let self, let asset = self.player.currentItem?.asset else { return }
            let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let loaded = (try? await asset.load(.duration).seconds) ?? 0
            self.hasVideo = !videoTracks.isEmpty
            self.duration = loaded.isFinite ? max(0, loaded) : 0
            // 续播：上次位置在 (10s, 结束前 5s) 才跳回（片头/片尾不折腾）。
            let saved = Self.savedPosition(for: self.fileURL)
            if saved > 10, self.duration > 0, saved < self.duration - 5 {
                self.seek(to: saved, precise: false)
            }
            self.player.play()
        }
    }

    // MARK: - 控制

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
        savePosition()
    }

    func seek(to seconds: Double, precise: Bool = true) {
        let clamped = min(max(0, seconds), max(0, duration - 0.05))
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        if precise {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player.seek(to: time)
        }
        currentTime = clamped
        savePosition()
    }

    func step(_ delta: Double) {
        seek(to: currentTime + delta)
    }

    func setRate(_ newRate: Double) {
        rate = newRate
        player.defaultRate = Float(newRate)
        if isPlaying { player.rate = Float(newRate) }
    }

    // MARK: - 画中画

    /// 视图层拿到 AVPlayerLayer 后接线（内容层画中画，macOS 12+）。
    func setupPictureInPicture(layer: AVPlayerLayer) {
        guard pipController == nil else { return }
        let source = AVPictureInPictureController.ContentSource(playerLayer: layer)
        let controller = AVPictureInPictureController(contentSource: source)
        pipController = controller
        canPictureInPicture = controller.isPictureInPicturePossible
        controller.publisher(for: \.isPictureInPicturePossible)
            .sink { [weak self] possible in
                self?.canPictureInPicture = possible
            }
            .store(in: &cancellables)
    }

    func togglePictureInPicture() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    // MARK: - 进度续存

    private func autosavePosition() {
        let bucket = Int(currentTime / 5)
        if bucket != lastSavedBucket { savePosition() }
    }

    func savePosition() {
        lastSavedBucket = Int(currentTime / 5)
        let remaining = duration - currentTime
        UserDefaults.standard.set(remaining < 5 ? 0 : currentTime,
                                  forKey: Self.resumeKey(for: fileURL))
    }

    private static func savedPosition(for url: URL) -> Double {
        UserDefaults.standard.double(forKey: resumeKey(for: url))
    }

    private static func resumeKey(for url: URL) -> String {
        "media.resume.\(url.path)"
    }
}
