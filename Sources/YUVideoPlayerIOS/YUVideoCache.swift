import AVFoundation

/// 业务层唯一依赖的门面。
///
/// 暴露：配置、预取、取 item、释放、清理。
/// Store / Loader / URLSession 全部藏在 YUPrefixCache 内部。
public enum YUVideoCache {

    /// 签名续签：接业务自己的逻辑，默认不处理
    public static var renew: (URL) -> URL = { $0 }

    // MARK: - 配置

    /// 预取总开关，默认关闭。
    ///
    /// 关闭时不探测总长、不下载前缀，包括 `playerItem` 里那次隐式预取。
    /// 因为 meta 建不出来，缓存链路也就一直不会生效。磁盘上已有的前缀照常
    /// 命中：播放仍走缓存链路，只是不再往前补。
    public static var prefetchEnabled = false

    /// 全局可用缓存总量，默认 1GB
    public static var maxTotalBytes: Int64 {
        get { YUPrefixCache.maxTotalBytes }
        set { YUPrefixCache.maxTotalBytes = max(0, newValue) }
    }

    /// 单条视频可缓存的上限，默认 6MB
    public static var maxBytesPerVideo: Int64 {
        get { YUPrefixCache.maxBytesPerVideo }
        set { YUPrefixCache.maxBytesPerVideo = max(0, newValue) }
    }

    // MARK: - 预取

    /// 详情页曝光时调用，失败静默，不阻塞任何 UI。
    ///
    /// 预取开关关闭时直接返回，连后台任务都不起。
    public static func prefetch(vid: String, realURL: URL) {
        guard prefetchEnabled else { return }
        let renewer = renew
        Task.detached(priority: .utility) {
            await YUPrefixCache.prefetch(vid: vid, realURL: realURL, renew: renewer)
        }
    }

    // MARK: - 取 item

    /// 永远返回可播放的 item。
    ///
    /// 只要探测过总长（有 meta），就走 loader 版 item，哪怕前缀一字节都没下：
    /// 播放过程中会顺序把前缀补齐，下次进来直接命中。
    /// 只有从未探测过总长时，才退回纯网络 item，并在后台开始探测。
    ///
    /// 同一个 vid 可以同时被任意多个 item 使用：它们共享同一份 `YUPrefixStore`
    /// （缓存资源），但各自持有独立的 loader。用完之后务必调用 `release(vid:)`，
    /// 否则该条目会被永久视为"正在使用"，淘汰不掉的只有磁盘空间占用。
    public static func playerItem(vid: String, realURL: URL) -> AVPlayerItem {
        // 无条件占位：这里代表"有播放器开始用这个 vid 了"，与 view 卸载时的
        // release(vid:) 一一配对。不能只在走缓存分支时 acquire —— 否则一旦
        // 缓存已被清掉（走纯网络分支），release 会把别人的计数也减掉。
        YUPrefixCache.acquire(vid: vid)

        if let store = YUPrefixCache.storeIfReady(vid: vid),
           let item = YUPrefixCache.makeItem(vid: vid, realURL: realURL, store: store, renew: renew) {
            return item
        }
        prefetch(vid: vid, realURL: realURL)   // 开关关闭时这里是 no-op
        // 纯网络 item 是系统类，没法挂 deinit 打点，这里用事件日志标一条，
        // 避免在日志里"凭空少一个播放项"
        YULog.log("[事件] 纯网络播放项 vid=\(vid)（无 meta，不计入播放项存活）")
        return AVPlayerItem(url: realURL)
    }

    /// 调试用：当前 item 是否走了缓存通道
    public static func isCachedItem(_ item: AVPlayerItem) -> Bool {
        (item.asset as? AVURLAsset)?.url.scheme == "prefix"
    }

    // MARK: - 生命周期

    /// 离开播放页时调用：使用计数减一。
    /// 真正取消 loader 的是 item 自己（`YUPlayerItem.deinit`），不在这里。
    public static func release(vid: String) {
        YUPrefixCache.release(vid: vid)
    }

    // MARK: - 容量

    /// 当前占用的总字节数
    public static var totalSize: Int64 {
        YUPrefixCache.totalDiskUsage()
    }

    /// 全部缓存快照，按最后使用时间倒序
    public static var entries: [YUPrefixCache.YUCacheEntry] {
        YUPrefixCache.entries()
    }

    /// 缓存条数
    public static var count: Int {
        YUPrefixCache.entries().count
    }

    /// 超过全局上限时按最久未使用淘汰；启动/回前台可主动调一次
    public static func enforceLimit() {
        YUPrefixCache.scheduleEnforce()
    }

    // MARK: - 清理

    public static func clear(vid: String) {
        YUPrefixCache.clear(vid: vid)
    }

    public static func clearAll() {
        YUPrefixCache.clearAll()
    }
}
