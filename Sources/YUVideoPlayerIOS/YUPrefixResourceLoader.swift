import AVFoundation
import Foundation

/// 拦截 AVPlayer 的数据请求：前缀命中走磁盘，其余回源，边界在同一个请求内拼接。
///
/// 关键点：
/// 1. 必须用自定义 scheme，否则 delegate 不会被调用。
/// 2. 必须回填 contentInformationRequest，尤其 isByteRangeAccessSupported。
/// 3. delegate 是弱引用，调用方必须强持有本对象。
final class YUPrefixResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {

    private struct Pending {
        let request: AVAssetResourceLoadingRequest
        let dataRequest: AVAssetResourceLoadingDataRequest
        var nextOffset: Int64
    }

    private let vid: String
    private let realURL: URL
    private let renew: (URL) -> URL
    private let store: YUPrefixStore

    /// loader 比 item 更容易漏：它被 URLSession 强引用着（delegate 自环），
    /// 只有 cancel 才能断开。日志里看 `[取消]` 有没有出现即可。
    private let logId = YULog.nextId()
    private let createdAt = CFAbsoluteTimeGetCurrent()
    private var cancelled = false

    /// 所有状态都在这个串行队列上访问，网络回调同样排到它里面。
    /// 必须把同一个队列传给 AVAssetResourceLoader.setDelegate，否则本地读取与网络回调会并发。
    let queue = DispatchQueue(label: "prefix.loader")
    private var pending: [Int: Pending] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        let created = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        sessionCreated = true
        return created
    }()

    /// session 是 lazy 的：没走过的纯本地播放不该为了打日志把它建出来
    private var sessionCreated = false

    init(vid: String, realURL: URL, store: YUPrefixStore, renew: @escaping (URL) -> URL) {
        self.vid = vid
        self.realURL = realURL
        self.store = store
        self.renew = renew
        super.init()
        // 登记为「这条 vid 的写者」：预取靠它判断要不要让路，
        // store 也靠它判断现在能不能从共享表里摘掉
        YUPrefixCache.beginWrite(vid: vid)
        YULog.birth("加载器", logId, "vid=\(vid)")
    }

    deinit {
        YULog.death("加载器", logId,
                    "\(YULog.alive(since: createdAt)) vid=\(vid) 已取消=\(cancelled)")
        // 兜底：holder 忘了 cancel 时也要把 URLSession 的自环断开、把写者名额还回去。
        // 只在 session 真的建过时才动它，否则会为了清理反而新建一个。
        if !cancelled {
            cancelled = true
            if sessionCreated { session.invalidateAndCancel() }
            YUPrefixCache.endWrite(vid: vid)
        }
    }

    func cancel() {
        if cancelled { return }
        cancelled = true
        YULog.log("[取消] 加载器#\(logId) \(YULog.alive(since: createdAt)) vid=\(vid)")
        // session 是 lazy 的：没发过网络请求时**不要**碰它。否则为了取消反而会
        // 现场建一个 delegate=self 的 session 再销毁它 —— 纯缓存播放每次结束都白建一个。
        if sessionCreated { session.invalidateAndCancel() }
        pending.removeAll()
        YUPrefixCache.endWrite(vid: vid)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {

        guard let dataRequest = req.dataRequest else { return false }

        // 一次请求只取一个一致视图，避免中途进度变化导致各字段来自不同时刻
        let snap = store.snapshot()
        let total = snap.totalLength
        let offset = dataRequest.requestedOffset

        guard total > 0, offset >= 0, offset < total else {
            req.finishLoading(with: NSError(domain: "YUPrefixCache", code: 416))
            return true
        }

        let want = dataRequest.requestedLength == 0 ? total - offset : Int64(dataRequest.requestedLength)
        let end = min(offset + want, total)

        fillContentInfo(req, snap: snap)

        // 1) 本地能覆盖到哪
        let downloaded = snap.downloaded
        let limit = snap.limit
        var localEnd = offset
        if offset < downloaded, offset < limit {
            localEnd = min(end, downloaded, limit)
        }

        // 2) 先把网络请求发出去，让它在喂本地数据的这段时间里就在飞
        if localEnd < end {
            startNetwork(request: req, dataRequest: dataRequest, from: localEnd, end: end)
        }

        // 3) 同步喂本地数据（本方法在串行队列上执行，网络回调一定排在其后）
        if localEnd > offset {
            feedLocal(dataRequest, from: offset, to: localEnd)
        }

        // 4) 完全由本地满足
        if localEnd >= end {
            req.finishLoading()
        }
        return true
    }

    // MARK: - 私有

    private func fillContentInfo(_ req: AVAssetResourceLoadingRequest,
                                 snap: YUPrefixStore.Snapshot) {
        guard let info = req.contentInformationRequest else { return }
        info.contentLength = snap.totalLength
        info.contentType = snap.contentType
        info.isByteRangeAccessSupported = true
    }

    private func feedLocal(_ dataRequest: AVAssetResourceLoadingDataRequest, from: Int64, to: Int64) {
        var cursor = from
        while cursor < to {
            let chunkSize = Int(min(Int64(256 * 1024), to - cursor))
            guard let chunk = store.read(offset: cursor, length: Int64(chunkSize)) else { return }
            dataRequest.respond(with: chunk)
            cursor += Int64(chunk.count)
        }
    }

    private func startNetwork(request: AVAssetResourceLoadingRequest,
                              dataRequest: AVAssetResourceLoadingDataRequest,
                              from: Int64,
                              end: Int64) {
        var urlRequest = URLRequest(url: renew(realURL))
        urlRequest.setValue("bytes=\(from)-\(end - 1)", forHTTPHeaderField: "Range")

        let task = session.dataTask(with: urlRequest)
        pending[task.taskIdentifier] = Pending(request: request,
                                               dataRequest: dataRequest,
                                               nextOffset: from)
        task.resume()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var item = pending[dataTask.taskIdentifier] else { return }

        if item.request.isCancelled {
            dataTask.cancel()
            pending[dataTask.taskIdentifier] = nil
            return
        }

        // 先吐给播放器，保证时序连续
        item.dataRequest.respond(with: data)

        // 只在前缀范围内、且顺序到达时落盘
        if item.nextOffset < store.snapshot().limit {
            store.append(data, at: item.nextOffset)
        }
        item.nextOffset += Int64(data.count)
        pending[dataTask.taskIdentifier] = item
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let item = pending.removeValue(forKey: task.taskIdentifier) else { return }
        if item.request.isCancelled { return }
        if let error {
            item.request.finishLoading(with: error)
        } else {
            item.request.finishLoading()
        }
    }
}
