import Foundation

/// iSH「Linux 模式」的**生命周期驱动**：rootfs → 启动内核 → 开会话 → 收发字节。
///
/// 分工（别把两层搞混）：
/// · `LinuxMode` 只**读**状态（链接没链接、启动没启动）；这里负责**动作**。
/// · 真正贴着内核的那层在 `LinuxAppGlue.m`（15 个内核要的符号 + 专用 pthread 启动 +
///   pty 输入输出），本类只是它的 Swift 门面 + UI 状态。
///
/// 三条如实说明：
/// 1. **内核只能启动一次**：iSH 没有"关掉内核"的接口，启动是单向的。所以在真机上
///    点「启动 Linux」之前，rootfs 必须先导入好（否则内核起来就 panic，`-4` 会拦住你）。
/// 2. **终端是原始字节**：这一版把 tty 输出原样透出来 + 做 ANSI 清洗，
///    还没有 VT100 屏幕语义（光标寻址 / 全屏程序）。全屏程序（vim/top）显示会不对。
/// 3. **rootfs 要 3MB 左右**：不随包发（仓库不该塞二进制）。要么从 iSH 官方
///    release 下载（和 iSH 自己用的是同一个 tarball），要么从「文件」里导入。
@MainActor
final class LinuxBoot: ObservableObject {

    static let shared = LinuxBoot()

    enum Phase: Equatable {
        case unlinked            // 引擎没进包（构建配置错了）
        case needsRootfs         // 引擎在，但 rootfs 还没导入
        case ready               // rootfs 就绪，可以启动
        case booting             // 内核启动中
        case running             // 会话可交互
        case stopped             // 已关闭（客户机用户进程全收掉了）
        case failed(String)

        var label: String {
            switch self {
            case .unlinked: return "Linux 内核未链接进本包"
            case .needsRootfs: return "需要先导入 rootfs（约 3 MB）"
            case .ready: return "rootfs 就绪，可以启动内核"
            case .booting: return "内核启动中…"
            case .running: return "Linux 会话进行中"
            case .stopped: return "Linux 已停止（内核卸不掉，再启动需重启 App）"
            case .failed(let why): return "失败：\(why)"
            }
        }

        var isBusy: Bool { self == .booting }
    }

    /// 一次取数的内存快照。**客户机**和**宿主**是两个数，别混：
    /// 客户机 RAM 固定 256 MB（`ish_phys_size = 0x10000000`），那块是保留的地址空间；
    /// 真正吃掉宿主物理内存的是被触碰过的页 —— 就是下面 host 那两项。
    struct MemSnapshot: Equatable {
        /// 客户机自报的总 RAM（固定 256 MB）。
        var guestTotal: UInt64 = 0
        var guestFree: UInt64 = 0
        var guestBuffers: UInt64 = 0
        var guestShared: UInt64 = 0
        /// 宿主进程（这个 App）：phys_footprint 与 resident。
        var hostFootprint: UInt64 = 0
        var hostResident: UInt64 = 0
        /// 取数时刻；`.distantPast` = 还没取过。
        var takenAt: Date = .distantPast

        /// 客户机已用 = total - free - buffers（free 里不含可回收的 buffer）。
        var guestUsed: UInt64 {
            let reclaimable = guestFree + guestBuffers
            return guestTotal > reclaimable ? guestTotal - reclaimable : 0
        }
        var hasGuest: Bool { guestTotal > 0 }
    }

    /// 客户机网卡（golp）状态 —— 「桥接联网」到底接上没有的判据。
    struct NetSnapshot: Equatable {
        var name = ""
        var ifindex: Int32 = 0
        var up = false
        var ipv4 = ""
        var available = false

        var summary: String {
            guard available else { return "内核里没有网卡（golp 未注册）" }
            return "\(name) \(ipv4)\(up ? " up" : " down")"
        }
    }

    // MARK: - 对外状态

    @Published private(set) var phase: Phase
    /// 内核 console（启动日志 / panic）。上限 64 KB，超了从头部丢。
    @Published private(set) var consoleText = ""
    /// 会话 tty 输出（已做 ANSI 清洗）。上限 256 KB。
    @Published private(set) var sessionText = ""
    @Published private(set) var sessionPid: Int32 = 0
    /// 导入进度（0…1）；导入时才有意义。
    @Published private(set) var importProgress: Double = 0
    /// 最近一次取到的内存快照（客户机 + 宿主）。
    @Published private(set) var mem = MemSnapshot()
    /// 最近一次取到的网卡状态。
    @Published private(set) var net = NetSnapshot()
    /// 诊断取数中（面板上给个转圈）。
    @Published private(set) var readingDiagnostics = false
    /// 宿主 DNS 注入客户机 /etc/resolv.conf 的结果（0 = 成功；-999 = 还没做过）。
    @Published private(set) var dnsRC: Int32 = -999

    /// DNS 注入结果的一句话（给面板显示，别含糊）。
    var dnsSummary: String {
        switch dnsRC {
        case -999: return "还没注入"
        case 0:    return "已写入 /etc/resolv.conf"
        case -1:   return "未注入（内核没起来）"
        case -2:   return "读不到宿主 DNS 状态（res_ninit 失败）"
        default:   return "写入失败（rc \(dnsRC)）"
        }
    }

    /// 网卡那条**该怎么说**。别把"没得问"说成"没有网卡"：
    /// golp 只存在于内核里，内核没起来 / 已停止时它当然问不到 —— 那不是"没注册"。
    var netSummary: String {
        if LinuxMode.isStopped { return "已停止（内核不再回答）" }
        if !LinuxMode.isBooted { return "内核未启动" }
        return net.summary
    }

    /// 网卡那条该亮绿灯吗：内核活着 **且** 网卡 up。
    var netOK: Bool { LinuxMode.isBooted && net.available && net.up }

    /// 会话输出的清洗器（跨 chunk 的 ANSI 状态机，见 LinuxTerminalText）。
    private var stripper = LinuxTerminalText.Stripper()
    private static let consoleLimit = 64 * 1024
    private static let sessionLimit = 256 * 1024

    // MARK: - 路径

    /// 官方 rootfs：与 iSH 自己用的是同一个 tarball（third_party/ish/app/iSH.xcconfig 的 ROOTFS_URL）。
    static let officialRootfsURL = URL(string:
        "https://github.com/ish-app/roots/releases/download/g00712ff0a54b2839c5aa1a8ed758003ca65357dc/appstore-apk.tar.gz")!

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ish", isDirectory: true)
    }
    /// fakefs 根目录：里面是 `data/` + `meta.db`（内核把它挂成 `/root`）。
    static var rootDirectory: URL { supportDirectory.appendingPathComponent("roots/default", isDirectory: true) }
    /// 下载/导入进来的 rootfs tarball 的落点。
    static var tarballURL: URL { supportDirectory.appendingPathComponent("rootfs.tar.gz") }

    // MARK: - 初始化

    private init() {
        phase = LinuxMode.isLinked ? .needsRootfs : .unlinked
        registerSinks()
        refresh()
    }

    private func registerSinks() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        lumen_linux_set_console_sink({ bytes, len, ctx in
            guard let bytes, let ctx, len > 0 else { return }
            let data = Data(bytes: bytes, count: Int(len))
            // C 侧已经 hop 到主队列了，这里只是把"我在主线程"这个事实告诉编译器。
            MainActor.assumeIsolated {
                Unmanaged<LinuxBoot>.fromOpaque(ctx).takeUnretainedValue().appendConsole(data)
            }
        }, ctx)

        lumen_linux_set_session_sink({ bytes, len, ctx in
            guard let bytes, let ctx, len > 0 else { return }
            let data = Data(bytes: bytes, count: Int(len))
            MainActor.assumeIsolated {
                Unmanaged<LinuxBoot>.fromOpaque(ctx).takeUnretainedValue().appendSession(data)
            }
        }, ctx)

        lumen_linux_set_panic_sink({ message, ctx in
            guard let ctx else { return }
            let text = message.map { String(cString: $0) } ?? "(unknown)"
            MainActor.assumeIsolated {
                let boot = Unmanaged<LinuxBoot>.fromOpaque(ctx).takeUnretainedValue()
                boot.consoleText += "\n[kernel panic] \(text)\n"
                boot.phase = .failed("内核 panic：\(text)")
            }
        }, ctx)

        lumen_linux_set_session_end_sink({ ctx in
            guard let ctx else { return }
            MainActor.assumeIsolated {
                let boot = Unmanaged<LinuxBoot>.fromOpaque(ctx).takeUnretainedValue()
                boot.sessionPid = 0
                boot.sessionText += "\n[session] 会话已结束\n"
                boot.refresh()
            }
        }, ctx)
    }

    // MARK: - 状态刷新

    /// 用 C 侧的真值重算一次 phase（链接/rootfs/启动/会话）。
    func refresh() {
        guard LinuxMode.isLinked else { phase = .unlinked; return }
        if case .failed = phase { return }              // 失败信息保留，别被覆盖
        if LinuxMode.isStopped { phase = .stopped; return }
        if LinuxMode.isSessionActive { phase = .running; return }
        if LinuxMode.isBooted { phase = .ready; return }
        phase = lumen_linux_rootfs_ready(Self.rootDirectory.path) ? .ready : .needsRootfs
    }

    // MARK: - 诊断取数（内存 / 网卡）

    /// 取一次客户机内存、宿主内存、客户机网卡状态。
    ///
    /// 为什么要离开主线程：前两条在 C 侧是**阻塞**的 —— 数在内核里取
    /// （宿主看不到客户机的页表，也看不到 golp 那块网卡），要等内核线程把值送回来。
    /// 宿主内存那条不阻塞（就是一次 task_info），但没必要为它单开一条路。
    func refreshDiagnostics() async {
        guard !readingDiagnostics else { return }
        readingDiagnostics = true
        defer { readingDiagnostics = false }

        let snapshot: (MemSnapshot, NetSnapshot) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var mem = MemSnapshot()
                var total: UInt64 = 0, free: UInt64 = 0, buffers: UInt64 = 0, shared: UInt64 = 0
                if lumen_linux_guest_meminfo(&total, &free, &buffers, &shared) {
                    mem.guestTotal = total
                    mem.guestFree = free
                    mem.guestBuffers = buffers
                    mem.guestShared = shared
                }
                var footprint: UInt64 = 0, resident: UInt64 = 0
                if lumen_linux_host_memory(&footprint, &resident) {
                    mem.hostFootprint = footprint
                    mem.hostResident = resident
                }
                mem.takenAt = Date()

                var net = NetSnapshot()
                var rawName = [CChar](repeating: 0, count: 64)
                var ifindex: Int32 = 0, up: Int32 = 0
                var ipv4: UInt32 = 0
                if lumen_linux_net_info(&rawName, 64, &ifindex, &up, &ipv4) {
                    let bytes = rawName.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    net.name = String(decoding: bytes, as: UTF8.self)
                    net.ifindex = ifindex
                    net.up = up != 0
                    net.ipv4 = "\((ipv4 >> 24) & 0xff).\((ipv4 >> 16) & 0xff)"
                        + ".\((ipv4 >> 8) & 0xff).\(ipv4 & 0xff)"
                    net.available = true
                }
                continuation.resume(returning: (mem, net))
            }
        }
        mem = snapshot.0
        net = snapshot.1
    }

    // MARK: - 关闭

    /// 关闭 Linux：把客户机里所有用户进程 SIGKILL 掉，会话随之结束。
    ///
    /// 三条如实说明（UI 里也照着写，别让用户以为这是"关机再开机"）：
    /// 1. 客户机里敲 `halt` / `poweroff` **不能**用来关这个 —— 它走
    ///    `arch/ish/kernel/reboot.c` 的 `machine_halt()` = `exit(0)`，会把整个 App 结束掉。
    /// 2. 内核本身**卸不掉**（iSH 没有这个接口）。关闭只是把客户机用户进程收干净、
    ///    把终端页恢复成可用状态。
    /// 3. 所以关掉之后**不能再启动**（内核只支持启动一次），要重新来只能重启 App。
    func shutdown() async -> Bool {
        guard LinuxMode.isLinked else { phase = .unlinked; return false }
        guard LinuxMode.isBooted, !LinuxMode.isStopped else {
            phase = .failed("Linux 没在运行，没什么可关的")
            return false
        }
        let killed: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: lumen_linux_shutdown())
            }
        }
        sessionPid = 0
        guard killed >= 0 else {
            phase = .failed("关闭失败（内核状态不对）")
            return false
        }
        sessionText += "[session] 已关闭 Linux：杀掉 \(killed) 个客户机用户进程。\n"
        phase = .stopped
        return true
    }

    // MARK: - rootfs

    /// 把 rootfs 导入到 `rootDirectory`（tar.gz → fakefs 的 data/ + meta.db）。
    /// 阻塞、耗时（实测导入 ~3 MB 解包，秒级），所以放到后台线程。
    func importRootfs(from tarball: URL) async -> Bool {
        guard LinuxMode.isLinked else { phase = .unlinked; return false }
        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: Self.rootDirectory, withIntermediateDirectories: true)
            if tarball.standardizedFileURL != Self.tarballURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: Self.tarballURL)
                try FileManager.default.copyItem(at: tarball, to: Self.tarballURL)
            }
        } catch {
            phase = .failed("准备目录失败：\(error.localizedDescription)")
            return false
        }

        let tar = Self.tarballURL.path
        let root = Self.rootDirectory.path
        phase = .needsRootfs
        importProgress = 0

        let result: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var errbuf = [CChar](repeating: 0, count: 1024)
                let ok = lumen_linux_import_rootfs(tar, root, &errbuf, 1024)
                // String(cString:) 已废弃（要自己截到 NUL）；这里照它的语义手工截。
                let bytes = errbuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                continuation.resume(returning: ok ? nil : String(decoding: bytes, as: UTF8.self))
            }
        }

        if let message = result {
            phase = .failed(message)
            return false
        }
        importProgress = 1
        phase = .ready
        return true
    }

    /// 从 iSH 官方 release 下载 rootfs 并导入（和 iSH 自己用的是同一个 tarball）。
    func downloadOfficialRootfs() async -> Bool {
        do {
            let (tmp, _) = try await URLSession.shared.download(from: Self.officialRootfsURL)
            return await importRootfs(from: tmp)
        } catch {
            phase = .failed("下载 rootfs 失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 启动

    /// 启动 Linux 内核。rootfs 没导入会被 C 侧拦住（返回 -4），不会盲起一个必 panic 的内核。
    func boot() async -> Bool {
        guard LinuxMode.isLinked else { phase = .unlinked; return false }
        guard lumen_linux_rootfs_ready(Self.rootDirectory.path) else {
            phase = .needsRootfs
            return false
        }
        lumen_linux_set_root(Self.rootDirectory.path)
        phase = .booting

        // maxcpus=0：只起 CPU0。内核的 arch/ish/kernel/smp.c 会给每个 secondary CPU 起宿主线程，
        // 而 iSH 是单 CPU 模拟器，第 2 个 CPU 一进 idle 就 SIGSEGV（上游这条路径没跑过）。
        // 这是内核自己的早期参数（smp.c:1063 parse_early_param），不用重编内核。
        let rc = lumen_linux_boot("maxcpus=0")
        guard rc == 0 else {
            phase = .failed(Self.bootErrorText(rc))
            return false
        }

        // run_kernel() 在专用 pthread 上跑，返回即 startup；轮询给个上限，别无限等。
        for _ in 0..<240 {                              // 240 × 250ms = 60s
            if LinuxMode.isBooted {
                // 内核起来了：先把**宿主 DNS** 注入客户机的 /etc/resolv.conf，再算 boot 完成。
                // 官方 rootfs 里没有这个文件（实测），缺了它客户机的 musl 解析器退回 127.0.0.1，
                // 表现是"网卡 up 着、地址也有、域名一个都解析不了"。必须排在开会话之前。
                dnsRC = await Self.injectResolvConf()
                phase = .ready
                return true
            }
            if case .failed = phase { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        phase = .failed("内核启动超时（60s 内没到 startup）")
        return false
    }

    private static func bootErrorText(_ rc: Int32) -> String {
        switch rc {
        case -2: return "已经在启动中"
        case -3: return "没设置 rootfs 目录"
        case -4: return "rootfs 还没导入（内核会直接 panic，已拦下）"
        case -5: return "启动线程创建失败"
        default: return "启动失败（\(rc)）"
        }
    }

    /// 注入客户机 DNS（阻塞的 C 调用，所以放后台队列上等）。
    private static func injectResolvConf() async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: lumen_linux_write_resolv_conf())
            }
        }
    }

    // MARK: - 会话

    /// 起一个 login shell 会话（`/bin/sh -l`，Alpine 的 sh = busybox ash）。
    func startShell() -> Bool {
        guard LinuxMode.isBooted else { phase = .failed("内核还没启动"); return false }
        var pid: Int32 = 0
        let env = [
            "TERM=xterm-256color",
            "HOME=/root",
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "LANG=C.UTF-8",
        ]
        let rc: Int32 = Self.withCStringArray(["/bin/sh", "-l"]) { argv in
            Self.withCStringArray(env) { envp in
                lumen_linux_start_session("/bin/sh", argv, envp, &pid)
            }
        }
        guard rc == 0 else {
            phase = .failed("会话启动失败（\(rc)）")
            return false
        }
        sessionPid = pid
        sessionText += "[session] /bin/sh -l 已启动（pid \(pid)）\n"
        phase = .running
        return true
    }

    /// 把用户敲的一行（会补尾随换行）写进会话 tty。
    func send(_ line: String) {
        guard LinuxMode.isSessionActive else { return }
        let text = line.hasSuffix("\n") ? line : line + "\n"
        sessionText += text                          // 本地回显：真 tty 的回显要等内核绕一圈
        text.withCString { ptr in
            _ = lumen_linux_session_write(ptr, UInt32(strlen(ptr)))
        }
    }

    /// 清空会话输出（不影响会话本身）。
    func clearSessionOutput() {
        sessionText = ""
        stripper = LinuxTerminalText.Stripper()
    }

    // MARK: - 内部

    private func appendConsole(_ data: Data) {
        // console 不做 ANSI 清洗：内核 printk 本来就不带转义序列，动了反而丢信息。
        consoleText += String(decoding: data, as: UTF8.self)
        if consoleText.utf8.count > Self.consoleLimit {
            consoleText = String(consoleText.suffix(Self.consoleLimit / 2))
        }
    }

    private func appendSession(_ data: Data) {
        sessionText += stripper.strip(String(decoding: data, as: UTF8.self))
        if sessionText.utf8.count > Self.sessionLimit {
            sessionText = String(sessionText.suffix(Self.sessionLimit / 2))
        }
    }

    /// 把 Swift 字符串数组变成 C 的 `const char *const *`。
    /// 内存布局上 `UnsafeMutablePointer<CChar>?` 与 `UnsafePointer<CChar>?` 相同，
    /// 内核只读它，所以用 assumingMemoryBound 重新绑定成只读视图交给它。
    private static func withCStringArray<T>(_ strings: [String],
                                           _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> T) -> T {
        let copies = strings.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        let pointers: [UnsafeMutablePointer<CChar>?] = copies + [nil]
        return pointers.withUnsafeBufferPointer { buffer in
            let base = UnsafeRawPointer(buffer.baseAddress!)
                .assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            return body(base)
        }
    }
}

/// 会话输出的显示清洗：**不假装**是 VT100，只做"把控制序列丢掉、把字节变成人能读的行"。
///
/// 为什么需要状态机：tty 输出的 chunk 边界是任意的，一个 `ESC [ 3 2 m` 可能被切成两半。
/// 每来一个 chunk 就丢掉"半个转义序列"会把后面的正常文本一起吃掉，所以状态要跨 chunk 保留。
enum LinuxTerminalText {

    struct Stripper {
        private enum State { case normal, escape, csi, osc, oscEscape }
        private var state: State = .normal

        /// 去掉 CSI / OSC / 单字符转义与 \r、\b（保留换行；\r\n 不会变成两行）。
        mutating func strip(_ input: String) -> String {
            var out = String()
            out.reserveCapacity(input.count)
            for scalar in input.unicodeScalars {
                switch state {
                case .normal:
                    switch scalar {
                    case "\u{1B}": state = .escape
                    case "\r", "\u{08}": break          // 回车/退格直接丢：我们不做光标移动
                    default: out.unicodeScalars.append(scalar)
                    }
                case .escape:
                    switch scalar {
                    case "[": state = .csi
                    case "]": state = .osc
                    case "\u{1B}": state = .escape
                    default: state = .normal             // 两字符转义（如 ESC ( B）：吃掉整条
                    }
                case .csi:
                    // CSI 的参数是 0x20…0x3F，最终字节是 0x40…0x7E。
                    if scalar.value >= 0x40 && scalar.value <= 0x7E { state = .normal }
                case .osc:
                    if scalar == "\u{07}" { state = .normal }            // BEL 结尾
                    else if scalar == "\u{1B}" { state = .oscEscape }    // ESC \ 结尾
                case .oscEscape:
                    state = scalar == "\\" ? .normal : .osc
                }
            }
            return out
        }
    }
}
