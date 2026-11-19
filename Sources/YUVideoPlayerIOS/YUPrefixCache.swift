import AVFoundation
import Foundation

/// 缓存门面：业务层只与这里交互，不接触 Store / Loader / URLSession。
public enum YUPrefixCache {

    // MARK: - 配置

    /// 全局可占用的磁盘上限，默认 1GB
    static var maxTotalBytes: Int64 = 1024 * 1024 * 1024

    /// 单条视频可占用的上限，默认 16MB
    static var maxBytesPerVideo: Int64 = YUPrefixMeta.defaultMaxBytesPerVideo

    // MARK: - 路径

    static func cacheRoot() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaCache", isDirectory: true)
    }

    static func directory(vid: String) -> URL {
        cacheRoot().appendingPathComponent(sanitize(vid), isDirectory: true)
    }

    /// vid 可能含中文或斜杠，落到目录名前统一处理。
    /// 只保留 ASCII 字母数字与 -_，与 Android 实现保持一致。
    private static func sanitize(_ vid: String) -> String {
        let mapped = vid.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            let isLower = v >= 97 && v <= 122
            let isUpper = v >= 65 && v <= 90
            let isDigit = v >= 48 && v <= 57
            let isDash = v == 45 || v == 95
            return (isLower || isUpper || isDigit || isDash) ? Character(scalar) : "_"
        }
        return String(mapped)
    }

    // MARK: - 查询

    /// 只要探测到总长（有 meta）就返回 store，前缀下没下完不影响使用：
    /// loader 会在播放过程中顺序补齐剩余部分。
    ///
    /// store 按 vid 全局共享。多个播放器播同一条时必须拿到**同一个实例**，
    /// 否则各自的 `downloaded` 只是打开那一刻的快照：后打开的那个读不到缓存
    /// （`read` 的边界判断用的是自己那份旧值），写也写不进去（`append` 的
    /// `offset == downloaded` 永远不成立），等于白下。
    static func storeIfReady(vid: String) -> YUPrefixStore? {
        let key = sanitize(vid)

        if let cached = cachedStore(key) {
            cached.touch()
            return cached
        }

        guard let opened = YUPrefixStore.open(dir: directory(vid: vid)) else {
            YULog.log("[缓存] vid=\(key) 没下过，走纯网络")
            return nil
        }
        let snap = opened.snapshot()
        guard snap.totalLength > 0, snap.limit > 0 else {
            YULog.log("[缓存] vid=\(key) 目录在但没有 meta，走纯网络")
            return nil
        }

        // 双检：并发进来时只留一个实例，后来者用已经存下的那个
        let installed = publish(opened, for: key)
        installed.touch()
        let now = installed.snapshot()
        YULog.log("[缓存] vid=\(key) 命中 已下=\(YULog.mb(now.downloaded))"
                  + "/\(YULog.mb(now.limit)) 总长=\(YULog.mb(now.totalLength))")
        return installed
    }

    private static func cachedStore(_ key: String) -> YUPrefixStore? {
        storeLock.lock(); defer { storeLock.unlock() }
        return stores[key]
    }

    /// 把新实例放进共享表；表里已有则返回已有的那个。
    private static func publish(_ store: YUPrefixStore, for key: String) -> YUPrefixStore {
        storeLock.lock(); defer { storeLock.unlock() }
        if let existing = stores[key] { return existing }
        stores[key] = store
        return store
    }

    /// 该 vid 是否有播放器正在使用（引用计数 > 0）。
    /// 内部按 sanitize 后的名字查表，传原始 vid 或目录名都能命中。
    static func isActive(vid: String) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return (active[sanitize(vid)] ?? 0) > 0
    }

    /// 正在对该 vid 顺序写盘的 loader 数量。
    ///
    /// 和 `isActive` 是两件事：播放器可能在播，但走的是纯网络 item（还没 meta），
    /// 此时没有任何 loader 在写文件。预取要判断的是「有没有人和我抢这份文件」，
    /// 所以看这个而不是看有没有人在播。
    static func isWriting(vid: String) -> Bool {
        writerLock.lock(); defer { writerLock.unlock() }
        return (writers[sanitize(vid)] ?? 0) > 0
    }

    /// loader 创建时调用，与 `endWrite` 配对（在 `cancel` / `deinit` 里各一次）
    static func beginWrite(vid: String) {
        let key = sanitize(vid)
        writerLock.lock()
        writers[key, default: 0] += 1
        writerLock.unlock()
    }

    /// loader 结束时调用。归零后这条 vid 若也没人播、没预取任务，就把内存里的
    /// store 摘掉 —— 磁盘文件不动，下次用的时候重新 open。
    static func endWrite(vid: String) {
        let key = sanitize(vid)
        writerLock.lock()
        let next = (writers[key] ?? 1) - 1
        if next > 0 {
            writers[key] = next
        } else {
            writers.removeValue(forKey: key)
        }
        writerLock.unlock()

        forgetIfIdle(key)
    }

    // MARK: - 预取

    /// 正在预取的 vid：同一个视频被快速切来切去时会重复触发，
    /// 两个任务会各自 probe → 各自 create，而 create 会删掉已有的 prefix.dat，
    /// 结果就是白下一遍、甚至把刚写好的缓存清掉。这里只放一个任务进去。
    private static var prefetching: Set<String> = []
    private static let prefetchLock = NSLock()

    /// 同步登记，返回 false 表示已有任务在下这条视频（NSLock 不能直接在 async 上下文用）
    private static func beginPrefetch(_ key: String) -> Bool {
        prefetchLock.lock(); defer { prefetchLock.unlock() }
        if prefetching.contains(key) { return false }
        prefetching.insert(key)
        return true
    }

    private static func endPrefetch(_ key: String) {
        prefetchLock.lock()
        prefetching.remove(key)
        prefetchLock.unlock()
        // 预取期间新建的 store 如果没人接手，到这里就该放了
        forgetIfIdle(key)
    }

    /// 探测总长并把前 N 字节下到磁盘；已下载一部分时只补剩余部分。
    /// 失败静默返回，不影响播放。
    /// renew 在每次真实请求前调用，保证预取用的是当前有效签名。
    static func prefetch(vid: String,
                         realURL: URL,
                         renew: @escaping (URL) -> URL = { $0 }) async {
        let dir = directory(vid: vid)
        let key = sanitize(vid)

        guard beginPrefetch(key) else {
            YULog.log("[预取] vid=\(key) 跳过：已有任务在下")
            return
        }
        defer { endPrefetch(key) }

        if let cached = cachedStore(key), cached.snapshot().isComplete {
            YULog.log("[预取] vid=\(key) 跳过：前缀已下满")
            return
        }

        // 表里没有：先**只读**看一眼磁盘，满了就直接收工，不进共享表。
        //
        // 直接走 storeIfReady 的话会把 store 塞进表里、`touch()` 一次 updatedAt，
        // 然后被 endPrefetch 立刻摘掉：每切一次视频（左右相邻两条）白刷 6 行日志，
        // 「余 N 份」在 1↔3 之间跳；更要紧的是 touch 会把「从没看过的视频」的
        // 最后使用时间刷成现在，等磁盘到 1GB 淘汰时它反而排在真正该留的前面。
        //
        // 代价：这里 open 一次、下面 storeIfReady 再 open 一次。只有"没下满、
        // 真要下载"这条路上会开两次，可接受。
        if cachedStore(key) == nil,
           let peek = YUPrefixStore.open(dir: dir),
           peek.snapshot().isComplete {
            YULog.log("[预取] vid=\(key) 跳过：前缀已下满（磁盘，未入表）")
            return
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        let store: YUPrefixStore
        // 走共享表：播放中的 store 就是它，绝不能另开一份
        if let ready = storeIfReady(vid: vid) {
            store = ready
        } else {
            guard let info = await probe(url: renew(realURL)) else {
                YULog.log("[预取] vid=\(key) 失败：探测总长没拿到（服务端不支持 Range？）")
                return
            }
            let limitBytes = min(maxBytesPerVideo, info.length)
            guard limitBytes > 0 else {
                YULog.log("[预取] vid=\(key) 失败：总长 \(info.length) 不合法")
                return
            }

            // 探测期间可能已经有播放器建好了 store，别把人家正在用的文件重置掉
            if let installed = cachedStore(key) {
                store = installed
            } else {
                guard let created = YUPrefixStore.create(dir: dir,
                                                       totalLength: info.length,
                                                       limitBytes: limitBytes,
                                                       etag: info.etag) else {
                    YULog.log("[预取] vid=\(key) 失败：建缓存目录出错")
                    return
                }
                store = publish(created, for: key)
                YULog.log("[预取] vid=\(key) 建条目 总长=\(YULog.mb(info.length))"
                          + " 前缀上限=\(YULog.mb(limitBytes))")
            }
        }

        let startSnap = store.snapshot()
        let from = startSnap.downloaded
        let to = startSnap.limit
        guard from < to else {
            YULog.log("[预取] vid=\(key) 跳过：已下 \(YULog.mb(from))，到达上限")
            return
        }

        // 有 loader 正在顺序写这条：再并发下载只会被丢弃，换源时尤其浪费。
        //
        // 这里刻意用「有没有人在写」而不是「有没有人在播」：首次播放走的是纯网络
        // item（meta 还没建出来），根本没有 loader，此时下载不会和谁抢文件，
        // 正好把这条的前缀补上 —— 否则第一次看的那条永远是 0 字节，
        // 要「看第二遍」才开始缓存。
        if isWriting(vid: vid) {
            YULog.log("[预取] vid=\(key) 跳过：loader 正在写盘")
            return
        }
        if isActive(vid: vid) {
            YULog.log("[预取] vid=\(key) 播放中但没走缓存链路，照常下载")
        }

        YULog.log("[预取] vid=\(key) 开始 范围=\(YULog.mb(from))→\(YULog.mb(to))")

        guard let tmp = await downloadRange(url: renew(realURL), from: from, to: to) else {
            YULog.log("[预取] vid=\(key) 失败：下载没拿到 206")
            return
        }

        // 下载期间 loader 可能已经开始顺序写：这里绝不能替换或追加，
        // 否则文件与 meta 会错位。丢弃这次的临时文件，交给 loader 边播边写。
        guard !isWriting(vid: vid), store.snapshot().downloaded == from else {
            try? FileManager.default.removeItem(at: tmp)
            YULog.log("[预取] vid=\(key) 丢弃：loader 已开始写盘")
            return
        }

        if from == 0 {
            store.install(fileAt: tmp)     // 整段替换
        } else {
            store.appendFile(at: tmp)      // 续传追加
        }

        let done = store.snapshot()
        YULog.log("[预取] vid=\(key) 完成 已下=\(YULog.mb(done.downloaded))"
                  + "/\(YULog.mb(done.limit)) \(YULog.cost(since: startedAt))")

        // 新增了数据，检查是否超出全局上限
        scheduleEnforce()
    }

    /// 返回总长与 ETag
    private static func probe(url: URL) async -> (length: Int64, etag: String?)? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        request.timeoutInterval = 10

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }

        let etag = http.value(forHTTPHeaderField: "ETag")

        // 支持 Range：从 Content-Range 里取总长
        if http.statusCode == 206,
           let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let totalText = contentRange.split(separator: "/").last,
           let total = Int64(totalText) {
            return (total, etag)
        }

        // 不支持 Range：退回 Content-Length
        if let lengthText = http.value(forHTTPHeaderField: "Content-Length"),
           let total = Int64(lengthText), total > 0 {
            return (total, etag)
        }
        return nil
    }

    private static func downloadRange(url: URL, from: Int64, to: Int64) async -> URL? {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(from)-\(to - 1)", forHTTPHeaderField: "Range")

        guard let (tmp, response) = try? await URLSession.shared.download(for: request),
              let http = response as? HTTPURLResponse else { return nil }

        // 续传必须 206；首次允许 200（服务端忽略 Range 时整体返回，install 会截断）
        let ok = http.statusCode == 206 || (from == 0 && http.statusCode == 200)
        return ok ? tmp : nil
    }

    // MARK: - 生成 item

    /// 用自定义 scheme 生成 item，scheme 变了 loader 才会被调用。
    ///
    /// loader 由返回的 item **独占持有**，item 释放时在 `YUPlayerItem.deinit` 里 cancel。
    /// 因此同一个 vid 可以同时被任意多个播放器使用：它们共享同一份 store（缓存资源），
    /// 但各用各的管道，谁结束都不会影响别人。
    static func makeItem(vid: String,
                         realURL: URL,
                         store: YUPrefixStore,
                         renew: @escaping (URL) -> URL) -> AVPlayerItem? {
        guard var comps = URLComponents(url: realURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = "prefix"
        guard let assetURL = comps.url else { return nil }

        let asset = AVURLAsset(url: assetURL)
        let loader = YUPrefixResourceLoader(vid: vid, realURL: realURL, store: store, renew: renew)

        // 必须与 loader 内部串行队列一致
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)

        return YUPlayerItem(asset: asset, loader: loader, vid: vid)
    }

    // MARK: - 生命周期

    /// 缓存资源：一个 vid 一份 store，可被多个 loader 共享。
    /// store 自身带锁，并发读写由它保证；这里只管"一个 vid 只有一个实例"。
    private static var stores: [String: YUPrefixStore] = [:]
    private static let storeLock = NSLock()

    /// 使用中的播放器数量：淘汰时跳过计数 > 0 的条目。
    /// 用计数而不是集合，因为同一个 vid 可能被多个播放器同时使用。
    private static var active: [String: Int] = [:]
    private static let stateLock = NSLock()

    /// 正在顺序写盘的 loader 数量（每个 vid 一份）
    private static var writers: [String: Int] = [:]
    private static let writerLock = NSLock()

    /// 一个播放器开始使用该 vid（生成 item 时调用，与 `release` 配对）
    static func acquire(vid: String) {
        stateLock.lock()
        let key = sanitize(vid)
        active[key, default: 0] += 1
        let now = active[key] ?? 0
        stateLock.unlock()
        // 泄漏时这里会只看到占用没有配对的释放，计数永远归不了零
        YULog.log("[占用] vid=\(key) 使用中=\(now)")
    }

    /// 一个播放器结束使用该 vid。归零之后才解除淘汰保护。
    /// 与旧实现不同，这里**不**取消任何 loader —— loader 由 item 自己管。
    static func release(vid: String) {
        stateLock.lock()
        let key = sanitize(vid)
        let next = (active[key] ?? 0) - 1
        if next > 0 {
            active[key] = next
        } else {
            active.removeValue(forKey: key)
        }
        let total = active.values.reduce(0, +)
        stateLock.unlock()

        YULog.log("[释放] vid=\(key) 使用中=\(max(0, next)) 全局使用中=\(total)")

        // 最后一个播放器也走了：内存里这份 store 可以放掉（磁盘文件保留）。
        // 否则每看过一条视频就常驻一份，直到 app 被杀 —— 单条体积不大，
        // 但条数无界，且 1GB 上限下要 500 条才轮到淘汰，等于永不回收。
        if next <= 0 { forgetIfIdle(key) }

        // 播放结束后写入停止，此时检查一次容量最合适
        scheduleEnforce()
    }

    /// 把不再被使用的 store 从共享表里摘掉：**只掉内存实例，磁盘文件不动**，
    /// 下次 `storeIfReady` 会重新 open 一份。
    ///
    /// 三个条件缺一不可，否则会出现「同一 vid 两份 store」：
    /// 旧的那份还在被 loader / 预取任务拿着写，新的那份按自己的
    /// `downloaded` 快照读，两边对不上，等于白下。
    private static func forgetIfIdle(_ key: String) {
        stateLock.lock()
        let busy = (active[key] ?? 0) > 0
        stateLock.unlock()
        guard !busy else { return }

        writerLock.lock()
        let writing = (writers[key] ?? 0) > 0
        writerLock.unlock()
        guard !writing else { return }

        prefetchLock.lock()
        let fetching = prefetching.contains(key)
        prefetchLock.unlock()
        guard !fetching else { return }

        storeLock.lock()
        let removed = stores.removeValue(forKey: key) != nil
        let left = stores.count
        storeLock.unlock()

        if removed {
            YULog.log("[缓存] vid=\(key) 已无人使用，释放内存里的 store（余 \(left) 份）")
        }
    }

    /// 条目被删除时从共享表里摘掉，下次访问重新 open
    private static func forgetStore(_ key: String) {
        storeLock.lock(); defer { storeLock.unlock() }
        stores.removeValue(forKey: key)
    }

    // MARK: - 容量控制

    /// 一条缓存的可读快照
    public struct YUCacheEntry {
        /// 目录名（即 sanitize 后的 vid）
        public let key: String
        /// prefix.dat 实际占用字节
        public let bytes: Int64
        /// 已写入前缀的字节数
        public let downloaded: Int64
        /// 前缀上限（字节）
        public let limit: Int64
        /// 整片总字节数
        public let totalLength: Int64
        public let updatedAt: Date

        /// 前缀完成度 0...1
        public var progress: Double {
            guard limit > 0 else { return 0 }
            return min(1, Double(downloaded) / Double(limit))
        }
    }

    /// 列出全部缓存，按最后使用时间倒序。
    /// 只读 meta 与文件大小，不做校验，不会产生副作用。
    static func entries() -> [YUCacheEntry] {
        let root = cacheRoot()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }

        var result: [YUCacheEntry] = []
        for name in names where !name.hasPrefix(".") {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(YUPrefixMeta.self, from: data) else { continue }

            let attrs = try? FileManager.default.attributesOfItem(
                atPath: dir.appendingPathComponent("prefix.dat").path)
            let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

            result.append(YUCacheEntry(key: name,
                                     bytes: bytes,
                                     downloaded: meta.downloaded,
                                     limit: meta.limit,
                                     totalLength: meta.totalLength,
                                     updatedAt: meta.updatedAt))
        }

        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 串行执行容量检查，避免多处触发时并发扫描目录
    private static let maintainQueue = DispatchQueue(label: "prefix.maintain", qos: .utility)

    /// 异步触发一次容量检查（不阻塞调用方）
    static func scheduleEnforce() {
        maintainQueue.async { enforceTotalBytes() }
    }

    /// 全局占用（字节）
    static func totalDiskUsage() -> Int64 {
        entries().reduce(0) { $0 + $1.bytes }
    }

    /// 超过全局上限时，按最后使用时间从最旧的开始整条删除。
    /// 正在播放的条目不参与淘汰。
    static func enforceTotalBytes() {
        let root = cacheRoot()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }

        var entries: [(key: String, url: URL, size: Int64, updated: Date)] = []
        var total: Int64 = 0

        for name in names where !name.hasPrefix(".") {
            // 有播放器正在用的条目一律跳过：删掉它 = 正在播的这条断流
            if isActive(vid: name) { continue }
            let dir = root.appendingPathComponent(name, isDirectory: true)
            let store = cachedStore(name) ?? YUPrefixStore.open(dir: dir)
            guard let store else { continue }
            let size = store.diskUsage
            entries.append((name, dir, size, store.snapshot().updatedAt))
            total += size
        }

        guard total > maxTotalBytes else { return }

        // 最旧的先删，直到回到上限以内
        entries.sort { $0.updated < $1.updated }
        var removed = 0
        var freed: Int64 = 0
        for entry in entries {
            if total <= maxTotalBytes { break }
            try? FileManager.default.removeItem(at: entry.url)
            forgetStore(entry.key)
            total -= entry.size
            removed += 1
            freed += entry.size
        }

        if removed > 0 {
            YULog.log("[淘汰] 删除 \(removed) 条，腾出 \(YULog.mb(freed))，"
                      + "剩余 \(YULog.mb(total))/\(YULog.mb(maxTotalBytes))")
        }
    }

    // MARK: - 清理

    /// 删除某条缓存。正在播放的条目删掉后不会崩：loader 的 `read` 拿不到数据，
    /// 会自动退回网络，只是这一轮不再走缓存。
    static func clear(vid: String) {
        YULog.log("[清理] vid=\(sanitize(vid))")
        forgetStore(sanitize(vid))
        YUPrefixStore.open(dir: directory(vid: vid))?.remove()
        try? FileManager.default.removeItem(at: directory(vid: vid))
    }

    static func clearAll() {
        storeLock.lock()
        let count = stores.count
        stores.removeAll()
        storeLock.unlock()

        YULog.log("[清理] 全部缓存（内存中 \(count) 份 store）")
        try? FileManager.default.removeItem(at: cacheRoot())
    }
}
