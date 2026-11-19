import Foundation

/// 生命周期日志：只做三件事 —— 打时间戳、记存活数量、报内存占用。
///
/// 排查泄漏时看三条线：
/// 1. `[创建]` 与 `[销毁]` 是否成对：只有创建没有销毁就是泄漏；
/// 2. 行尾 `xxx存活` 是否回到 0：回不到 0 说明还有对象没放；
/// 3. `内存` 是否随开关播放单调上涨。
///
/// 关掉：`YULog.enabled = false`。
public enum YULog {

    /// 总开关，默认开
    public static var enabled = true

    private static let lock = NSLock()
    private static var seq = 0
    private static var live: [String: Int] = [:]
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 每创建一个对象取一个号，销毁时用同一个号打印，方便配对
    public static func nextId() -> Int {
        lock.lock(); defer { lock.unlock() }
        seq += 1
        return seq
    }

    /// 当前存活数量
    public static func count(_ kind: String, _ delta: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let next = max(0, (live[kind] ?? 0) + delta)
        live[kind] = next
        return next
    }

    public static func log(_ text: @autoclosure () -> String) {
        guard enabled else { return }
        lock.lock()
        let now = formatter.string(from: Date())
        lock.unlock()
        // 用 print 而不是 NSLog：走 stdout，Xcode / flutter run 都能看到，也不进系统日志。
        // 前缀与 Android 的 Log TAG 同名（YUPlayer），三端共用一套过滤词。
        print("[YUPlayer][iOS] \(now) \(text())")
    }

    /// 创建打点：`[创建] 视图#1 vid=xx 视图存活=1 内存=128.4MB`
    public static func birth(_ kind: String, _ id: Int, _ detail: String) {
        guard enabled else { return }
        log("[创建] \(kind)#\(id) \(detail) \(kind)存活=\(count(kind, 1)) 内存=\(memText())")
    }

    /// 销毁打点：`[销毁] 视图#1 存活=4.32s 原因=xxx 视图存活=0 内存=131.2MB`
    public static func death(_ kind: String, _ id: Int, _ detail: String) {
        guard enabled else { return }
        log("[销毁] \(kind)#\(id) \(detail) \(kind)存活=\(count(kind, -1)) 内存=\(memText())")
    }

    /// 存活时长，形如 `存活=4.32s`
    public static func alive(since start: CFAbsoluteTime) -> String {
        String(format: "存活=%.2fs", CFAbsoluteTimeGetCurrent() - start)
    }

    /// 耗时长，形如 `耗时=1.23s`
    public static func cost(since start: CFAbsoluteTime) -> String {
        String(format: "耗时=%.2fs", CFAbsoluteTimeGetCurrent() - start)
    }

    /// 字节数转 MB，日志里比裸数字好读
    public static func mb(_ bytes: Int64) -> String {
        String(format: "%.1fMB", Double(bytes) / 1024 / 1024)
    }

    public static func memText() -> String {
        String(format: "%.1fMB", footprintMB())
    }

    /// 进程物理内存占用。
    ///
    /// 用 phys_footprint 而不是 resident_size：它跟 Instruments 显示的
    /// 「Memory Footprint」是同一个口径，不受干净页回收影响，更适合看泄漏趋势。
    public static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024 / 1024
    }
}
