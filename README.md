# YUVideoPlayerIOS (iOS)

把远程视频的开头若干字节缓存到磁盘，让起播直接从磁盘读、其余仍走网络。
基于 `AVAssetResourceLoader`，不需要本地服务器，也不需要 ATS 例外。

这是 `yu_video_player` 的 iOS 原生核心，不依赖 Flutter，可单独用于原生 iOS 工程。

## 集成

Swift Package Manager：

```swift
dependencies: [
    .package(url: "https://github.com/yonglemingyu/yu_video_player_ios.git", from: "1.0.0")
]
```

要求 iOS 15.0 及以上。

## 用法

```swift
import YUVideoPlayerIOS

// 1. 容量（可选，默认全局 1GB、单条 16MB）
YUVideoCache.maxTotalBytes = 1024 * 1024 * 1024
YUVideoCache.maxBytesPerVideo = 16 * 1024 * 1024

// 2. 曝光时预取，失败静默
YUVideoCache.prefetch(vid: "3412", realURL: url)

// 3. 用缓存过的 item 替代 AVPlayerItem(url:)
let item = YUVideoCache.playerItem(vid: "3412", realURL: url)
player.replaceCurrentItem(with: item)

// 4. 离开播放页：释放这个 vid 的使用计数
YUVideoCache.release(vid: "3412")

// 5. 用量与清理
let entries = YUVideoCache.entries
print(entries.count, YUVideoCache.totalSize)
YUVideoCache.clear(vid: "3412")
YUVideoCache.clearAll()
```

缓存以 `vid` 为 key，与 URL 无关，签名变化不影响命中。

## 签名续签

```swift
YUVideoCache.renew = { oldURL in
    // 返回当前有效的地址
    return refreshed(oldURL)
}
```

## 注意

- `playerItem` 每次调用都会占用一次使用计数，必须与 `release(vid:)` 一一配对。
- 只缓存从 0 开始的一段；往回拖到前缀之外需要重新下载。

## License

MIT
