#if SIMULATE_TAP
import Darwin
import Foundation
import MachO
import UIKit

/// 合成触摸后端 —— **只有 Tap 自签变体才编译这段代码**。
///
/// 合规版二进制里不含任何私有符号引用（整文件被 `#if SIMULATE_TAP` 包住），
/// 这是"两个版本"的前提：一个能过审，一个自己用。
///
/// 符号解析策略（v2，因为 v1 在真机上实测失败过）：
///
/// v1 的失败是两个独立原因叠在一起，都已定位：
///   1. 路径笔误 —— 候选里写的是 `/System/.../IOKIt.framework/IOKIt`（第三个字母大写），
///      dyld 按字符串逐字节匹配，大小写错一个字母就是 "no such file"。
///   2. 更根本的：现代 iOS 上系统框架**不一定以文件形式存在** —— 它们在 dyld 共享缓存里，
///      靠猜路径去 `dlopen` 本来就是碰运气。
///
/// 所以 v2 不再"猜路径"，按命中概率从高到低试四层：
///   a. `dlsym(RTLD_DEFAULT, …)` —— 符号如果已经在本进程可见（共享缓存导出 + 镜像已映射），
///      根本不需要任何 handle，也不需要知道路径；
///   b. `_dyld_get_image_*` 枚举**进程里真实加载的镜像**，拿到系统自己给出的路径（大小写绝对正确），
///      先用 `RTLD_NOLOAD` 取 handle（不引入新依赖），取不到再正常加载；
///   c. 显式候选路径（含 PrivateFrameworks），兜底用；
///   d. 裸名 `dlopen("IOKit", …)`。
///
/// ⚠️ 能力以 `probe()` 的**实测**为准，符号解析成功 ≠ 能合成点击：
///   · 这些私有函数的签名在 iOS 版本之间改过，`tap()` 里传的参数是按常见布局推的；
///   · 即便能派发，backboardd 也可能直接丢弃来自普通 App 的事件；
///   · 因此 `tap()` 只在**调用方显式要求**时才走派发路径，探测阶段一律只做解析 + 一次
///     签名稳定的 client 创建调用。
/// 任何一条做不到，返回的都是失败原因，绝不编造"已点击"。
enum TapBackend {

    /// 一个候选机制：怎么在进程里找到它 + 需要哪些符号。
    private struct Mechanism {
        let label: String
        /// `_dyld_get_image_name` 返回的路径里应该包含的子串（用来认出这个镜像）。
        let dyldNames: [String]
        /// 裸名兜底（`dlopen("IOKit", …)` 这种）。
        let bareName: String
        /// 兜底的显式路径（c 层用；大小写必须与系统一致）。
        let pathHints: [String]
        /// 想要的符号。
        let symbols: [String]
    }

    private static let mechanisms: [Mechanism] = [
        Mechanism(label: "IOKit/IOHIDEvent",
                  dyldNames: ["IOKit.framework"],
                  bareName: "IOKit",
                  pathHints: [
                    "/System/Library/Frameworks/IOKit.framework/IOKit",
                    "/System/Library/PrivateFrameworks/IOKit.framework/IOKit",
                    "/usr/lib/libIOKit.dylib",
                  ],
                  symbols: ["IOHIDEventSystemClientCreate",
                            "IOHIDEventSystemClientDispatchEvent",
                            "IOHIDEventCreateDigitizerEvent",
                            "IOHIDEventCreateDigitizerFingerEvent",
                            "IOHIDEventCreateTouchesEvent",
                            "IOHIDEventSetSenderID",
                            "IOHIDEventAppendEvent"]),
        Mechanism(label: "GraphicsServices/GSEvent",
                  dyldNames: ["GraphicsServices.framework"],
                  bareName: "GraphicsServices",
                  pathHints: [
                    "/System/Library/Frameworks/GraphicsServices.framework/GraphicsServices",
                    "/usr/lib/libGraphicsServices.dylib",
                  ],
                  symbols: ["GSEventSend", "GSSendEvent", "GSEventCreate"]),
    ]

    /// 进程里实际加载的镜像中，路径含任一子串的那些。
    ///
    /// 这一层是 v2 的关键：路径来自 dyld 自己，大小写与真实布局不可能对不上；
    /// 同时它还免费告诉我们"这个框架到底在不在本进程里"——这是 v1 报错里缺的信息。
    private static func imagePaths(matching substrings: [String]) -> [String] {
        var out: [String] = []
        let count = _dyld_image_count()
        for i in 0..<count {
            guard let cName = _dyld_get_image_name(i) else { continue }
            let path = String(cString: cName)
            if substrings.contains(where: { path.contains($0) }) {
                out.append(path)
            }
        }
        return out
    }

    /// 四层策略拿 handle。返回 handle + 命中来源（来源要原样报给用户，便于判断是哪一层通的）。
    private static func loadHandle(_ m: Mechanism) -> (handle: UnsafeMutableRawPointer, via: String)? {
        // b) 进程里已加载的镜像：先 NOLOAD（不新增依赖），失败再正常加载。
        let loaded = imagePaths(matching: m.dyldNames)
        for path in loaded {
            if let h = dlopen(path, RTLD_LAZY | RTLD_NOLOAD | RTLD_LOCAL) {
                return (h, "已加载镜像 \(path)（NOLOAD）")
            }
        }
        for path in loaded {
            if let h = dlopen(path, RTLD_LAZY | RTLD_LOCAL) {
                return (h, "镜像路径 \(path)")
            }
        }
        // c) 显式候选路径。
        for path in m.pathHints {
            if let h = dlopen(path, RTLD_LAZY | RTLD_LOCAL) {
                return (h, path)
            }
        }
        // d) 裸名。
        if let h = dlopen(m.bareName, RTLD_LAZY | RTLD_LOCAL) {
            return (h, "裸名 \(m.bareName)")
        }
        return nil
    }

    /// 解析一个符号：先看进程里是否直接可见（a 层），再落到机制 handle 上（b/c/d 层）。
    /// `RTLD_DEFAULT` = `(void *) -2`：在**已加载的镜像**里直接找符号。
    /// 不引用宏是因为它在 iOS SDK 的 Swift 导入下取不到（dlfcn.h 的对象宏导入问题），
    /// 而这个常量的值从 2003 年起就没变过。
    // 计算属性而不是 stored let：UnsafeMutableRawPointer? 不是 Sendable，
    // 存成静态常量会触发 Swift 6 的并发安全检查（这里本来也没有共享可变状态）。
    private static var rtldDefault: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: -2) }

    private static func symbol(_ name: String) -> (ptr: UnsafeMutableRawPointer, via: String)? {
        if let p = dlsym(rtldDefault, name) {
            return (p, "RTLD_DEFAULT（进程内直接可见）")
        }
        for m in mechanisms where m.symbols.contains(name) {
            guard let loaded = loadHandle(m) else { continue }
            if let p = dlsym(loaded.handle, name) {
                return (p, loaded.via)
            }
        }
        return nil
    }

    private static func dlErrorText() -> String {
        dlerror().map { String(cString: $0) } ?? "无错误信息"
    }

    /// 本机**是否具备**派发路径（只做符号解析，不创建 client、不派发）。
    ///
    /// 能力矩阵每次问能力都会调它，所以必须便宜：两次 dlsym，没有任何副作用。
    /// `probe()` 是给人看的完整报告（会实调一次 client），不该被能力查询反复触发。
    static func canDispatch() -> Bool {
        symbol("IOHIDEventSystemClientCreate") != nil
            && symbol("IOHIDEventSystemClientDispatchEvent") != nil
    }

    // MARK: - 探测（只读，不派发）

    /// 逐条列出「镜像在不在 → 符号解析到没有 → 由哪一层命中」，外加一次安全的 client 创建调用。
    static func probe() -> [String] {
        var out = ["合成触摸（SIMULATE_TAP 变体）· 符号解析策略 v2："]

        // 镜像层：进程里到底加载了哪些相关框架（这决定 b 层有没有机会）。
        for m in mechanisms {
            let images = imagePaths(matching: m.dyldNames)
            out.append("· \(m.label)："
                       + (images.isEmpty
                          ? "进程内**未加载**该镜像（只能靠路径/裸名兜底）"
                          : "已加载 " + images.joined(separator: ", ")))
        }

        // 符号层：逐个解析，标明命中来源。
        var resolvedClient: UnsafeMutableRawPointer?
        var resolvedDispatch: UnsafeMutableRawPointer?
        for m in mechanisms {
            var hits: [String] = []
            var miss: [String] = []
            var viaNotes: [String] = []
            for name in m.symbols {
                if let s = symbol(name) {
                    hits.append(name)
                    if !viaNotes.contains(s.via) { viaNotes.append(s.via) }
                    if name == "IOHIDEventSystemClientCreate" { resolvedClient = s.ptr }
                    if name == "IOHIDEventSystemClientDispatchEvent" { resolvedDispatch = s.ptr }
                } else {
                    miss.append(name)
                }
            }
            var line = "· \(m.label)：命中 \(hits.count)/\(m.symbols.count)"
            if !hits.isEmpty { line += " → " + hits.joined(separator: ", ") }
            if !miss.isEmpty { line += "；缺失 " + miss.joined(separator: ", ") }
            if !viaNotes.isEmpty { line += "（via " + viaNotes.joined(separator: " | ") + "）" }
            out.append(line)
        }

        if let client = resolvedClient {
            typealias Create = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
            let create = unsafeBitCast(client, to: Create.self)
            let handle = create(kCFAllocatorDefault)
            if handle != nil {
                out.append("· IOHIDEventSystemClientCreate 实调：成功（可进入 IOHID 事件系统）")
            } else {
                out.append("· IOHIDEventSystemClientCreate 实调：返回 nil"
                           + "（多半被系统策略拒绝 —— 非越狱设备上这通常是预期结果）")
            }
        } else {
            out.append("· IOHIDEventSystemClientCreate：未解析，无法实调（"
                       + dlErrorText() + "）")
        }

        out.append("· 结论：符号与实调结果如上；**派发是否生效要跑一次 `phone tap` 才知道**，"
                   + "本探测刻意不派发，避免在探测阶段就崩掉 App。")
        if resolvedDispatch == nil {
            out.append("· 本机没有 IOHIDEventSystemClientDispatchEvent —— tap 会直接返回失败，"
                       + "不会去碰不确定的签名。")
        }
        return out
    }

    // MARK: - 点击（显式调用才走）

    /// 归一化坐标 (0..1) → 真实点击。
    /// 走 IOHID 派发；签名不确定的地方**宁可不调**，返回"需要真机验证"的实话。
    static func tap(normalizedX nx: Double, normalizedY ny: Double) -> String {
        guard let createSym = symbol("IOHIDEventSystemClientCreate") else {
            return "失败：解析不到 IOHIDEventSystemClientCreate（"
                   + dlErrorText() + "）。先跑 op=probe 看哪一层都没通。"
        }
        guard let dispatchSym = symbol("IOHIDEventSystemClientDispatchEvent") else {
            return "失败：解析不到 IOHIDEventSystemClientDispatchEvent，无法派发。"
        }
        guard let eventSym = symbol("IOHIDEventCreateDigitizerEvent")
                ?? symbol("IOHIDEventCreateTouchesEvent") else {
            return "失败：解析不到触摸事件构造函数"
                   + "（IOHIDEventCreateDigitizerEvent / IOHIDEventCreateTouchesEvent 均缺失）"
        }

        typealias Create = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
        // 真实签名（IOHIDEventTypes.h / vphoned 实测调用）：
        //   (alloc, ts, transducerType, identifier, buttonMask, eventMask, buttonFlags,
        //    x, y, z, tipPressure, twist, range, touch, options)
        // 注意是 **5 个 double**（x/y/z/压力/扭转）。v1 写成 6 个 double + 2 个 UInt8，
        // 参数槽整体错位 —— 就算符号解析成功，传下去的也是错位的垃圾值。
        typealias CreateEvent = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32,
                                                UInt32, UInt32, UInt32,
                                                Double, Double, Double,
                                                Double, Double,
                                                UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
        typealias CreateFinger = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32,
                                                 Double, Double, Double,
                                                 Double, Double,
                                                 UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
        typealias SetSenderID = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
        typealias AppendEvent = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                                UInt32) -> Bool
        typealias Dispatch = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

        let client = unsafeBitCast(createSym.ptr, to: Create.self)(kCFAllocatorDefault)
        guard let client else { return "失败：IOHIDEventSystemClientCreate 返回 nil（被系统拒绝）" }

        let bounds = UIScreen.main.bounds
        let point = CGPoint(x: bounds.minX + CGFloat(nx) * bounds.width,
                            y: bounds.minY + CGFloat(ny) * bounds.height)
        // 事件坐标按 0..1 归一化传入（IOHID digitizer 的 x/y 是屏幕比例，不是像素）。
        let makeEvent = unsafeBitCast(eventSym.ptr, to: CreateEvent.self)
        let now = mach_absolute_time()
        // 事件掩码按 bit 位：begin(1) + peak(2) + touch(4) + range(8) —— 一次按下。
        let mask: UInt32 = 0xF
        guard let parent = makeEvent(kCFAllocatorDefault, now,
                                     0 /* transducerType: hand */,
                                     0 /* identifier */, 1 /* buttonMask */,
                                     mask /* eventMask */, 0 /* buttonFlags */,
                                     Double(nx), Double(ny), 0 /* z */,
                                     1 /* tipPressure：接触 */, 0 /* twist */,
                                     1 /* range */, 1 /* touch */, 0 /* options */) else {
            return "失败：事件构造函数返回 nil（坐标 \(Int(point.x))×\(Int(point.y))，"
                   + "签名可能与本版本不符）"
        }

        // 两层结构（GitHub 上 vphoned 的实测配方）：父事件 = 手(hand)，子事件 = 手指(finger)，
        // 再 AppendEvent 挂上去。只发一个父事件在多数版本上是**无声无效**的。
        var composed = false
        if let fingerFn = symbol("IOHIDEventCreateDigitizerFingerEvent"),
           let appendFn = symbol("IOHIDEventAppendEvent") {
            let makeFinger = unsafeBitCast(fingerFn.ptr, to: CreateFinger.self)
            if let child = makeFinger(kCFAllocatorDefault, now,
                                      1 /* identifier */, 2 /* finger */,
                                      mask, Double(nx), Double(ny),
                                      1 /* z */, 1 /* tipPressure */, 1 /* twist */,
                                      1 /* range */, 1 /* touch */, 1 /* options */) {
                composed = unsafeBitCast(appendFn.ptr, to: AppendEvent.self)(parent, child, 0)
            }
        }

        // senderID 决定 backboardd 认不认这个事件来源（配方里是常量
        // 0x8000000817419362）。没有它，派发出去也多半被丢弃 —— 所以它是
        // "能不能生效"的分水岭，解析不到就如实说明。
        var senderSet = false
        if let setSender = symbol("IOHIDEventSetSenderID") {
            unsafeBitCast(setSender.ptr, to: SetSenderID.self)(parent, 0x8000000817419362)
            senderSet = true
        }

        unsafeBitCast(dispatchSym.ptr, to: Dispatch.self)(client, parent)
        // 事件对象的释放函数没解析就让系统持有它：多泄漏一个事件对象，
        // 远好过调错 CFRelease 崩掉 —— 这是一次性的点击路径。
        var notes = ["符号来源：\(createSym.via)",
                     composed ? "两层事件（hand+finger）" : "单事件（缺 finger/append 符号）",
                     senderSet ? "已设 senderID" : "⚠️ 未设 senderID（解析不到 IOHIDEventSetSenderID），"
                        + "backboardd 很可能直接丢弃"]
        return "已派发 IOHID 触摸事件 @ 归一化(\(String(format: "%.2f", nx)), \(String(format: "%.2f", ny)))"
               + " → 屏幕(\(Int(point.x)), \(Int(point.y)))。"
               + notes.joined(separator: "；")
               + "。⚠️ 派发≠生效：屏幕有没有反应请当面确认。"
    }

    /// 合规版没有输入注入；Tap 版同样依赖 IOHID 键盘事件，签名未验证。
    static func typeText(_ text: String) -> String {
        "Tap 版暂未接线：键盘事件构造（IOHIDEventCreateKeyboardEvent）签名各版本不一致，"
        + "盲调会崩。请改用快捷指令的「输入文本」动作（run 执行）。收到 \(text.count) 个字符。"
    }
}
#endif
