import Foundation

/// 单条视频的前缀缓存元数据。
///
/// 完全按字节配置：单条上限由外部传入，写入 meta 后固定。
struct YUPrefixMeta: Codable {

    /// 单条默认上限：16MB
    static let defaultMaxBytesPerVideo: Int64 = 16 * 1024 * 1024

    /// 整片总字节数（由 Range 探测得到）
    var totalLength: Int64

    /// 前缀上限（字节）
    var limitBytes: Int64

    /// prefix.dat 中已写入的字节数，从 0 开始连续
    var downloaded: Int64

    /// 供 AVAssetResourceLoadingContentInformationRequest 使用
    var contentType: String

    /// 用于 LRU 与调试
    var updatedAt: Date

    /// 上游 ETag，内容变更时用于作废旧缓存
    var etag: String?

    init(totalLength: Int64,
         limitBytes: Int64,
         downloaded: Int64 = 0,
         contentType: String = "public.mp4",
         updatedAt: Date = Date(),
         etag: String? = nil) {
        self.totalLength = totalLength
        self.limitBytes = limitBytes
        self.downloaded = downloaded
        self.contentType = contentType
        self.updatedAt = updatedAt
        self.etag = etag
    }

    /// 实际生效的上限：不超过总长
    var limit: Int64 {
        guard totalLength > 0 else { return 0 }
        return min(max(limitBytes, 0), totalLength)
    }

    /// 前缀是否已下载完整
    var isComplete: Bool {
        limit > 0 && downloaded >= limit
    }
}
