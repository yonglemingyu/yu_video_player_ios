import Foundation

/// 前缀缓存的文件存储。
///
/// 目录结构：
/// ```
/// Library/Caches/MediaCache/{vid}/
/// ├── prefix.dat   从 0 开始连续的一段字节
/// └── meta.json    总长、已下载字节、比例
/// ```
///
/// 只支持顺序追加，因为单文件方案无法表达空洞。
/// 这也是"边播边写"能成立的前提：播放总是从某一位置连续往后读。
final class YUPrefixStore {

    private let dir: URL
    private let lock = NSLock()
    private(set) var meta: YUPrefixMeta

    var dataURL: URL { dir.appendingPathComponent("prefix.dat") }
    private var metaURL: URL { dir.appendingPathComponent("meta.json") }

    /// 在锁内取出的一份只读视图。
    ///
    /// 为什么要这个：`meta` 是含 `String` / `Date` 的 struct，直接读 `store.meta`
    /// 会复制整个结构体 —— 复制过程要 retain 那些引用类型字段，若此刻另一个线程
    /// 正在改它，就是一次无保护的并发读写。以前一个 loader 一个 store 几乎碰不到，
    /// 现在多个播放器共享同一个 store，这是常态路径，必须走锁。
    struct Snapshot {
        let totalLength: Int64
        let downloaded: Int64
        let limit: Int64
        let contentType: String
        let updatedAt: Date

        /// 前缀是否已下载完整
        var isComplete: Bool { limit > 0 && downloaded >= limit }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(totalLength: meta.totalLength,
                        downloaded: meta.downloaded,
                        limit: meta.limit,
                        contentType: meta.contentType,
                        updatedAt: meta.updatedAt)
    }

    private init(dir: URL, meta: YUPrefixMeta) throws {
        self.dir = dir
        self.meta = meta
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - 打开与校验

    /// 从磁盘加载。文件与 meta 不一致时自动重置，避免读到残缺数据。
    static func open(dir: URL) -> YUPrefixStore? {
        let metaURL = dir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(YUPrefixMeta.self, from: data),
              let store = try? YUPrefixStore(dir: dir, meta: meta) else { return nil }
        store.validate()
        return store
    }

    /// 新建（覆盖旧的）
    static func create(dir: URL,
                       totalLength: Int64,
                       limitBytes: Int64,
                       etag: String?) -> YUPrefixStore? {
        let meta = YUPrefixMeta(totalLength: totalLength,
                              limitBytes: limitBytes,
                              etag: etag)
        guard let store = try? YUPrefixStore(dir: dir, meta: meta) else { return nil }
        try? FileManager.default.removeItem(at: store.dataURL)
        store.meta.downloaded = 0
        store.persistMeta()
        return store
    }

    private func validate() {
        lock.lock(); defer { lock.unlock() }
        let attrs = try? FileManager.default.attributesOfItem(atPath: dataURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard size != meta.downloaded else { return }
        meta.downloaded = 0
        try? FileManager.default.removeItem(at: dataURL)
        persistMetaLocked()
    }

    // MARK: - 读

    /// 只有整个区间都落在已下载范围内才返回数据，否则返回 nil（调用方转网络）。
    func read(offset: Int64, length: Int64) -> Data? {
        guard offset >= 0, length > 0 else { return nil }

        lock.lock(); defer { lock.unlock() }

        let end = offset + length
        guard end <= meta.downloaded, end <= meta.limit else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: dataURL) else { return nil }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: Int(length))
        } catch {
            return nil
        }
    }

    // MARK: - 写

    /// 只接受从 downloaded 开始的顺序写入；跳跃或越过 limit 的写入直接丢弃。
    func append(_ data: Data, at offset: Int64) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        appendLocked(data, at: offset)
    }

    /// 顺序追加：偏移自动取当前 downloaded。播放中由 loader 调用，预取续传也用它。
    func appendSequentially(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        appendLocked(data, at: meta.downloaded)
    }

    private func appendLocked(_ data: Data, at offset: Int64) {
        guard offset == meta.downloaded,
              offset + Int64(data.count) <= meta.limit else { return }

        if !FileManager.default.fileExists(atPath: dataURL.path) {
            FileManager.default.createFile(atPath: dataURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: dataURL) else { return }
        defer { try? handle.close() }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            meta.downloaded += Int64(data.count)
            meta.updatedAt = Date()
            persistMetaLocked()
        } catch {
            return
        }
    }

    /// 把一批顺序数据文件追加进来（预取续传用），完成后删除临时文件。
    func appendFile(at url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }

        while true {
            guard let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            appendSequentially(chunk)
        }
    }

    /// 首次预取完成后整体替换：把下载好的临时文件搬成 prefix.dat。
    func install(fileAt url: URL) {
        lock.lock(); defer { lock.unlock() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return }

        let final = min(size, meta.limit)
        try? FileManager.default.removeItem(at: dataURL)
        try? FileManager.default.moveItem(at: url, to: dataURL)

        // 服务端忽略 Range 时会返回整片，截断到 limit
        if size > final, let handle = try? FileHandle(forWritingTo: dataURL) {
            try? handle.truncate(atOffset: UInt64(final))
            try? handle.close()
        }

        meta.downloaded = final
        meta.updatedAt = Date()
        persistMetaLocked()
    }

    // MARK: - 维护

    func touch() {
        lock.lock(); defer { lock.unlock() }
        meta.updatedAt = Date()
        persistMetaLocked()
    }

    func remove() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: dir)
    }

    var diskUsage: Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: dataURL.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - 持久化

    private func persistMeta() {
        meta.updatedAt = Date()
        persistMetaLocked()
    }

    private func persistMetaLocked() {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }
}
