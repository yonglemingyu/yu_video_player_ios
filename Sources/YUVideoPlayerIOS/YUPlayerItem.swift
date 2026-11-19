import AVFoundation

/// 一条 item 独占一条数据管道（loader）。
///
/// 为什么必须独占：
/// - loader 里面的 `URLSession` 会**强引用**它的 delegate（也就是 loader 自己），
///   形成自环；只有 `cancel()`（内部 `invalidateAndCancel`）才能断开；
/// - `cancel()` 是 session 级别的，一旦调用，这个 loader 所有在飞的请求都会失败。
///   所以绝不能让两个播放器共用同一个 loader —— 谁先结束，另一个就断粮。
///
/// 把 loader 挂成 item 的强属性后，"持有者"和"取消者"就是同一个对象：
/// item 一释放，`deinit` 里立刻 cancel，不存在忘记释放的分支。
/// 缓存文件本身（`YUPrefixStore`）仍然是按 vid 共享的，两者互不影响。
final class YUPlayerItem: AVPlayerItem {

    private let prefixLoader: YUPrefixResourceLoader?
    /// 缓存主键：日志里以它为准。片源 CDN 的文件名不唯一
    /// （20 条里有 6 条都叫 v.f42905.mp4），只看 url 认不出是哪一条
    private let vid: String

    /// 日志编号与创建时刻：item 是最容易漏放的一环，借它判断有没有被回收
    private let logId = YULog.nextId()
    private let createdAt = CFAbsoluteTimeGetCurrent()
    private let logName: String

    init(asset: AVURLAsset, loader: YUPrefixResourceLoader?, vid: String) {
        self.prefixLoader = loader
        self.vid = vid
        self.logName = YUPlayerItem.shortName(asset.url)
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)
        YULog.birth("播放项", logId, "vid=\(vid) url=\(logName) 走缓存=\(loader != nil)")
    }

    deinit {
        YULog.death("播放项", logId, "\(YULog.alive(since: createdAt)) vid=\(vid) url=\(logName)")
        prefixLoader?.cancel()
    }

    /// 当前 item 是否走了缓存通道
    var usingPrefixCache: Bool {
        (asset as? AVURLAsset)?.url.scheme == "prefix"
    }

    /// 日志里显示的短名：签名地址很长，取路径末段截断即可定位
    private static func shortName(_ url: URL) -> String {
        let name = url.lastPathComponent
        if name.isEmpty { return url.host ?? "-" }
        return String(name.prefix(24))
    }
}
