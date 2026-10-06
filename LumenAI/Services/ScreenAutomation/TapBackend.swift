#if SIMULATE_TAP
import Foundation
import UIKit

/// 合成触摸后端 —— **只有 Tap 自签变体才编译这段代码**。
///
/// 合规版二进制里不含任何私有符号引用（整文件被 `#if SIMULATE_TAP` 包住），
/// 这是"两个版本"的前提：一个能过审，一个自己用。
///
/// ⚠️ 能力以 `probe()` 的**实测**为准：
///   · 符号在不在 ≠ 能调用：iOS 版本间这些私有函数的签名改过；
///   · 即便能派发，backboardd 也可能直接丢弃来自普通 App 的事件；
///   · 因此 tap() 只在**调用方显式要求**时才走派发路径（模型/用户明确点了），
///     探测阶段一律只做 dlopen/dlsym + 一个签名稳定的 client 创建调用。
/// 任何一条做不到，返回的都是失败原因，绝不编造"已点击"。
enum TapBackend {

    /// 候选机制。按"越可能用"排序，全部走动态查找：
    /// 静态链接私有框架会在**链接期**就暴露，动态查找只在调用时才知道有没有。
    private static let candidates: [(path: String, label: String, symbols: [String])] = [
        ("/System/Library/Frameworks/IOKit.framework/IOKIt", "IOKit/IOHIDEvent",
         ["IOHIDEventSystemClientCreate",
          "IOHIDEventSystemClientDispatchEvent",
          "IOHIDEventCreateDigitizerEvent",
          "IOHIDEventCreateTouchesEvent"]),
        ("/System/Library/Frameworks/GraphicsServices.framework/GraphicsServices",
         "GraphicsServices/GSEvent",
         ["GSEventSend", "GSSendEvent", "GSEventCreate"]),
        ("/usr/lib/system/libsystem_trace.dylib", "（占位：确认 dlopen 通路可用）", []),
    ]

    private static func handle(for path: String) -> UnsafeMutableRawPointer? {
        guard let h = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        return h
    }

    private static func symbol(_ name: String, in handle: UnsafeMutableRawPointer) -> Bool {
        dlsym(handle, name) != nil
    }

    // MARK: - 探测（只读，不派发）

    /// 逐条列出"机制 → 符号是否解析成功"，外加一次安全的 client 创建调用。
    static func probe() -> [String] {
        var out = ["合成触摸（SIMULATE_TAP 变体）："]
        var resolvedClient: UnsafeMutableRawPointer? = nil

        for cand in candidates {
            guard let h = handle(for: cand.path) else {
                out.append("· \(cand.label)：dlopen 失败（\(dlerror().map { String(cString: $0) } ?? "无错误信息")）")
                continue
            }
            if cand.symbols.isEmpty {
                out.append("· \(cand.label)：dlopen 成功（通路正常）")
                continue
            }
            let hits = cand.symbols.filter { symbol($0, in: h) }
            let miss = cand.symbols.filter { !symbol($0, in: h) }
            out.append("· \(cand.label)：命中 \(hits.count)/\(cand.symbols.count)"
                       + (hits.isEmpty ? "" : " → " + hits.joined(separator: ", "))
                       + (miss.isEmpty ? "" : "；缺失 " + miss.joined(separator: ", ")))
            if hits.contains("IOHIDEventSystemClientCreate") {
                resolvedClient = h
            }
        }

        // 安全的实时性验证：这个函数签名（CFAllocatorRef → client 指针）各版本稳定，
        // 且返回值只用来判断"能不能进这个框架"，不派发任何事件。
        if let h = resolvedClient,
           let fn = dlsym(h, "IOHIDEventSystemClientCreate") {
            typealias Create = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
            let create = unsafeBitCast(fn, to: Create.self)
            let client = create(kCFAllocatorDefault)
            if client != nil {
                out.append("· IOHIDEventSystemClientCreate 实调：成功（可进入 IOHID 事件系统）")
            } else {
                out.append("· IOHIDEventSystemClientCreate 实调：返回 nil"
                           + "（多半被系统策略拒绝 —— 非越狱设备上这通常是预期结果）")
            }
        } else {
            out.append("· IOHIDEventSystemClientCreate：未解析，无法实调")
        }

        out.append("· 结论：符号与实调结果如上；**派发是否生效要跑一次 `phone tap` 才知道**，"
                   + "本探测刻意不派发，避免在探测阶段就崩掉 App。")
        return out
    }

    // MARK: - 点击（显式调用才走）

    /// 归一化坐标 (0..1) → 真实点击。
    /// 走 IOHID 派发；签名不确定的地方**宁可不调**，返回"需要真机验证"的实话。
    static func tap(normalizedX nx: Double, normalizedY ny: Double) -> String {
        guard let h = handle(for: candidates[0].path) else {
            return "失败：IOKit 加载不了（\(dlerror().map { String(cString: $0) } ?? "")）"
        }
        guard let createFn = dlsym(h, "IOHIDEventSystemClientCreate") else {
            return "失败：系统没有 IOHIDEventSystemClientCreate（该版本 iOS 无此入口）"
        }
        guard let dispatchFn = dlsym(h, "IOHIDEventSystemClientDispatchEvent") else {
            return "失败：系统没有 IOHIDEventSystemClientDispatchEvent（无法派发）"
        }
        guard let eventFn = dlsym(h, "IOHIDEventCreateDigitizerEvent")
                ?? dlsym(h, "IOHIDEventCreateTouchesEvent") else {
            return "失败：系统没有可用的触摸事件构造函数（IOHIDEventCreateDigitizerEvent /"
                   + " IOHIDEventCreateTouchesEvent 均缺失）"
        }

        typealias Create = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
        typealias CreateEvent = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32,
                                                UInt32, UInt64, UInt64, Double, Double, Double,
                                                Double, Double, UInt8, UInt8, UInt32) -> UnsafeMutableRawPointer?
        typealias Dispatch = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

        let client = unsafeBitCast(createFn, to: Create.self)(kCFAllocatorDefault)
        guard let client else { return "失败：IOHIDEventSystemClientCreate 返回 nil（被系统拒绝）" }

        let bounds = UIScreen.main.bounds
        let point = CGPoint(x: bounds.minX + CGFloat(nx) * bounds.width,
                            y: bounds.minY + CGFloat(ny) * bounds.height)
        // 事件坐标按 0..1 归一化传入（IOHID digitizer 的 x/y 是屏幕比例，不是像素）。
        let makeEvent = unsafeBitCast(eventFn, to: CreateEvent.self)
        let now = mach_absolute_time()
        guard let event = makeEvent(kCFAllocatorDefault, now,
                                    4 /* kIOHIDDigitizerTransducerTypeHand */,
                                    0, 0,
                                    0xF /* begin+peak+end+range 组合掩码 */,
                                    1 /* buttonMask：按下 */,
                                    Double(nx), Double(ny), 0,
                                    1 /* tipPressure：接触 */,
                                    0,
                                    0 /* range */,
                                    1 /* touch */,
                                    0 /* options */) else {
            return "失败：事件构造函数返回 nil（坐标 \(Int(point.x))×\(Int(point.y))，"
                   + "签名可能与本版本不符）"
        }
        unsafeBitCast(dispatchFn, to: Dispatch.self)(client, event)
        // 事件对象的释放函数没解析就让系统持有它：多泄漏一个事件对象，
        // 远好过调错 CFRelease 崩掉 —— 这是一次性的点击路径。
        return "已派发 IOHID 触摸事件 @ 归一化(\(String(format: "%.2f", nx)), \(String(format: "%.2f", ny)))"
               + " → 屏幕(\(Int(point.x)), \(Int(point.y)))。"
               + "⚠️ 派发≠生效：backboardd 可能丢弃普通 App 的事件，屏幕有没有反应请当面确认。"
    }

    /// 合规版没有输入注入；Tap 版同样依赖 IOHID 键盘事件，签名未验证。
    static func typeText(_ text: String) -> String {
        "Tap 版暂未接线：键盘事件构造（IOHIDEventCreateKeyboardEvent）签名各版本不一致，"
        + "盲调会崩。请改用快捷指令的「输入文本」动作（run 执行）。收到 \(text.count) 个字符。"
    }
}
#endif
