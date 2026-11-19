import AVFoundation

/// 全局音频会话：决定是否与其他 App 混音、被中断后是否恢复。
///
/// 只持有策略和一组弱引用的 player，不碰 view，也不参与播放状态管理 ——
/// 中断时它只负责 pause / play，状态回传仍走各自的 EventChannel。
public final class YUAudioSession {

    public static let shared = YUAudioSession()

    private var mixWithOthers = false
    private var duckOthers = false
    private var resumeAfterInterruption = true
    private var configured = false

    /// 参与中断处理的 player，弱引用：view 释放后自动移除，不阻止 AVPlayer 回收
    private let players = NSHashTable<AVPlayer>.weakObjects()
    /// 中断发生时正在播的 player，恢复时只恢复这些
    private var interrupted: [AVPlayer] = []
    private var observer: NSObjectProtocol?

    private init() {}

    // MARK: - 配置

    public func configure(mixWithOthers: Bool,
                   duckOthers: Bool,
                   resumeAfterInterruption: Bool) {
        self.mixWithOthers = mixWithOthers
        self.duckOthers = duckOthers
        self.resumeAfterInterruption = resumeAfterInterruption
        applyCategory()
        registerInterruptionIfNeeded()
    }

    /// view 创建时调用。没显式配置过就按默认策略（独占媒体）初始化一次。
    public func register(_ player: AVPlayer) {
        players.add(player)
        if !configured {
            applyCategory()
            registerInterruptionIfNeeded()
        }
    }

    public func unregister(_ player: AVPlayer) {
        players.remove(player)
        interrupted.removeAll { $0 === player }
    }

    // MARK: - 实现

    private func applyCategory() {
        configured = true
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = []
        if mixWithOthers {
            options.insert(.mixWithOthers)
        } else if duckOthers {
            options.insert(.duckOthers)
        }
        // .playback：静音开关不影响出声，也允许后台播放；
        // mode 用 .moviePlayback 让系统按影视内容处理（不启用通话优化）
        try? session.setCategory(.playback, mode: .moviePlayback, options: options)
        try? session.setActive(true)
    }

    private func registerInterruptionIfNeeded() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            // 记下被打断时正在播的实例，结束后只恢复它们
            interrupted = players.allObjects.filter { $0.rate > 0 }
            interrupted.forEach { $0.pause() }

        case .ended:
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            let shouldResume = resumeAfterInterruption && options.contains(.shouldResume)
            let pending = interrupted
            interrupted.removeAll()
            guard shouldResume else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            pending.forEach { $0.play() }

        @unknown default:
            break
        }
    }
}
