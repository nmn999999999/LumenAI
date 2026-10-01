import Foundation

/// 出站请求的**目的地**校验（防 SSRF）。
///
/// 为什么需要单独一层：`http_get` 的 URL 是模型自己拼的，而模型的输入里混着网页正文、
/// 搜索结果和用户粘贴的内容 —— 也就是说 URL 属于"半可信"数据。只判断 `scheme == https`
/// 挡不住 `https://127.0.0.1:8080/admin` 这类请求：内网 Web 服务、路由器管理页、
/// 云元数据端点(169.254.169.254，能读到实例的临时凭据)全部是 https 可达的，
/// 而且返回内容会被当成"网页内容"回灌进上下文再总结给用户，等于把内网数据带出去了。
///
/// 实现约束：
/// - 纯 Foundation，手写 IP 字面量解析。Foundation 没有把字面量解析成字节的公开 API
///   （`getaddrinfo` 会真的走 DNS/NSS，既慢又不受沙盒控制），引第三方库也不划算。
/// - 这里校验的是 URL 里**字面写出来的**主机，不做 DNS 解析。已知残留风险：
///   `127.0.0.1.nip.io` 这种"域名解析到回环"的写法能过校验。之所以不做同步解析，
///   是因为 `validate` 要在重定向的每一跳被同步调用，在里面发阻塞 DNS 会把 UI 卡住；
///   真要堵这条路，应该在 URLSession 连接建立后比对对端 IP，而不是在这一层。
enum NetworkGuard {

    enum Decision: Equatable {
        case allow
        /// deny 时 String 是给用户/模型看的原因（会被拼在 "错误: " 后面）。
        case deny(String)
    }

    /// 校验一个出站 URL 是否允许访问。
    static func validate(_ url: URL) -> Decision {
        // ① 只放行 https。ATS 默认就禁止明文 http，这里提前拒绝能给出比
        //    "请求失败: ATS policy" 更可读的提示；file:// / ftp:// 之类的 scheme
        //    一旦漏过去就是本地文件读取，直接挡死。
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            let current = url.scheme?.lowercased() ?? ""
            return .deny("仅支持 https 出站请求（当前 scheme 是「\(current.isEmpty ? "空" : current)」）")
        }

        guard let rawHost = url.host, !rawHost.isEmpty else {
            return .deny("URL 里没有主机名，无法判断访问目标")
        }

        // ② 先归一化再比较：`LocalHost`、`localhost.`（尾部点在 DNS 里等价于根域，
        //    解析结果完全相同）都能绕过按字面量的比较，所以统一小写 + 去掉所有尾部点。
        var host = rawHost.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        // IPv6 的区域 id（`fe80::1%25en0`）只影响选哪个网卡，不影响地址本身，去掉再解析。
        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }
        if host.isEmpty { return .deny("URL 里没有主机名，无法判断访问目标") }

        // ③ 名字层面的"本机/局域网"别名。
        if host == "localhost" || host.hasSuffix(".localhost") {
            return .deny("「\(rawHost)」是 localhost（本机回环别名），不允许出站访问")
        }
        if host.hasSuffix(".local") {
            return .deny("「\(rawHost)」是以 .local 结尾的局域网 mDNS 主机名，不允许出站访问")
        }

        // ④ IPv6 字面量：URL 里的方括号已经被 URL 解析器去掉了（`[::1]` → `::1`）。
        //    域名里不可能出现冒号，所以带冒号就一定是 IP 字面量；解析不出来说明写法畸形，
        //    宁可拒绝也不要猜。
        if host.contains(":") {
            guard let bytes = parseIPv6(host) else {
                return .deny("无法解析的 IPv6 字面量「\(rawHost)」，已拒绝")
            }
            if let reason = denyReason(ipv6: bytes, hostText: rawHost) {
                return .deny(reason)
            }
            return .allow
        }

        // ⑤ IPv4 字面量（严格点分十进制）。
        if let v4 = parseIPv4(host) {
            if let reason = denyReason(ipv4: v4, hostText: rawHost) {
                return .deny(reason)
            }
            return .allow
        }

        // ⑥ 非标准数字写法（`0x7f.0.0.1`、`0177.0.0.1`、单段的 `2130706433`）。
        //    inet_aton 系的解析器会把它们折算成同一个地址，但严格点分十进制认不出来 ——
        //    这正是最经典的 SSRF 绕过手法。拒绝一个"奇怪写法"没有任何副作用，
        //    放过一个可能就是回环，所以整体拒绝。
        if looksLikeNumericHost(host) {
            return .deny("「\(rawHost)」是非标准的数字形式 IP（可能被解析成回环/内网地址），请改用域名或标准点分十进制")
        }

        // ⑦ 不含点的单标签主机名（router、nas、printer、my-server）：公网域名必然带点，
        //    单标签只能靠 mDNS / 搜索域解析，几乎总是指向局域网设备。
        guard host.contains(".") else {
            return .deny("「\(host)」是不含点的单标签主机名（一般是内网设备名），不允许出站访问")
        }

        // 其余放行。注意这里**故意没**扩展成"拒绝一切非公网地址"：
        // 组播(224/4)、保留段(240/4)、CGNAT(100.64/10) 都不在需求范围内，
        // 加进来会误伤正常的公网抓取，需要时再单列。
        return .allow
    }

    // MARK: - IPv4

    /// 严格点分十进制：必须 4 段、每段 0~255。
    /// 故意不实现 inet_aton 的简写形式（少段、十六进制、八进制前缀）——
    /// 那些形式是绕过黑名单的经典手法，认不出来就说"不是 IP 字面量"，
    /// 交给 `looksLikeNumericHost` 去拒绝。
    private static func parseIPv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            // isASCII 不能省：`isNumber` 对全角数字/阿拉伯-印度数字也为真，
            // 而 UInt32(...) 只认 ASCII，混在一起会出现"看起来是数字却转换失败"的诡异分支。
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = UInt32(part), n <= 255 else { return nil }
            value = (value << 8) | n
        }
        return value
    }

    /// IPv4 的"禁区归类"：返回 nil 表示是公网地址（允许）。
    /// 拆成归类而不是直接给整句，是因为 IPv6 的 IPv4-mapped / NAT64 也要复用同一份判断，
    /// 拼进句子时只需要一个名词短语。
    private static func ipv4DenyCategory(_ v4: UInt32) -> String? {
        let o1 = UInt8((v4 >> 24) & 0xFF)
        let o2 = UInt8((v4 >> 16) & 0xFF)

        // 0.0.0.0/8 是"本机/本网络"，0.0.0.0 在不少栈上直接被当作回环处理。
        if o1 == 0 { return "0.0.0.0/8 本机地址" }
        if o1 == 127 { return "127.0.0.0/8 回环地址（loopback，本机服务）" }
        if o1 == 10 { return "10.0.0.0/8 私网地址（内网）" }
        if o1 == 172, (16...31).contains(o2) { return "172.16.0.0/12 私网地址（内网）" }
        if o1 == 192, o2 == 168 { return "192.168.0.0/16 私网地址（内网）" }
        // 169.254/16 是 link-local：云厂商的元数据端点 169.254.169.254 就在这里，
        // 它能返回实例角色/临时凭据，是 SSRF 最值钱的目标，原因里写明以便排查。
        if o1 == 169, o2 == 254 {
            return "169.254.0.0/16 link-local 地址（云元数据端点 169.254.169.254 所在网段）"
        }
        return nil
    }

    /// 返回 nil 表示允许；否则返回拒绝原因。
    private static func denyReason(ipv4 v4: UInt32, hostText: String) -> String? {
        guard let category = ipv4DenyCategory(v4) else { return nil }
        return "「\(hostText)」属于 \(category)，不允许出站访问"
    }

    /// 主机名是不是"整段都是数字/0x 十六进制"的写法。用于识别 inet_aton 简写。
    /// 只看形如 `0x..` 或纯十进制的段，避免把 `abc.be`、`dead.be` 这类
    /// 由十六进制字符组成的真域名误判成数字地址。
    private static func looksLikeNumericHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty else { return false }
            let lower = label.lowercased()
            if lower.hasPrefix("0x") {
                let digits = lower.dropFirst(2)
                guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return false }
            } else {
                guard label.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            }
        }
        return true
    }

    // MARK: - IPv6

    /// 手写 IPv6 解析，返回 16 字节。要处理三件麻烦事：
    /// `::` 压缩、末尾内嵌 IPv4（`::ffff:127.0.0.1`）、区域 id（调用方已去掉）。
    /// 任何不认识的形式返回 nil，由调用方当"拒绝"处理 —— 这一层宁可错杀。
    private static func parseIPv6(_ s: String) -> [UInt8]? {
        let halves = s.components(separatedBy: "::")
        // "::" 最多出现一次，出现两次就是畸形写法
        guard halves.count == 1 || halves.count == 2 else { return nil }

        func parseGroups(_ part: String) -> [UInt8]? {
            if part.isEmpty { return [] }
            var bytes: [UInt8] = []
            let groups = part.split(separator: ":", omittingEmptySubsequences: false)
            for (i, group) in groups.enumerated() {
                guard !group.isEmpty else { return nil } // ":::" 或开头/结尾多一个冒号
                if group.contains(".") {
                    // 内嵌 IPv4 只能出现在最后一段
                    guard i == groups.count - 1, let v4 = parseIPv4(String(group)) else { return nil }
                    bytes.append(UInt8((v4 >> 24) & 0xFF))
                    bytes.append(UInt8((v4 >> 16) & 0xFF))
                    bytes.append(UInt8((v4 >> 8) & 0xFF))
                    bytes.append(UInt8(v4 & 0xFF))
                    continue
                }
                guard group.count <= 4,
                      group.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                      let v = UInt16(group, radix: 16) else { return nil }
                bytes.append(UInt8(v >> 8))
                bytes.append(UInt8(v & 0xFF))
            }
            return bytes
        }

        guard var head = parseGroups(halves[0]) else { return nil }
        if halves.count == 2 {
            guard let tail = parseGroups(halves[1]) else { return nil }
            // 被压缩掉的那一段至少要占 1 组（2 字节），否则 `1:2:3:4:5:6:7:8::` 这类
            // 长度刚好 16 字节的写法会被当成合法地址
            guard head.count + tail.count <= 14 else { return nil }
            head += [UInt8](repeating: 0, count: 16 - head.count - tail.count)
            head += tail
        }
        guard head.count == 16 else { return nil }
        return head
    }

    /// 返回 nil 表示允许；否则返回拒绝原因。
    private static func denyReason(ipv6 bytes: [UInt8], hostText: String) -> String? {
        guard bytes.count == 16 else { return "「\(hostText)」不是合法的 IPv6 地址，已拒绝" }

        // ::1 回环（IPv6 的本机地址）
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 {
            return "「\(hostText)」是 IPv6 回环地址 ::1（本机服务），不允许出站访问"
        }
        // :: 未指定地址，等价于 IPv4 的 0.0.0.0
        if bytes.allSatisfy({ $0 == 0 }) {
            return "「\(hostText)」是 IPv6 未指定地址 ::（等价于 0.0.0.0），不允许出站访问"
        }
        // fc00::/7 唯一本地地址（ULA）= IPv6 世界里的"私网"
        if bytes[0] & 0xFE == 0xFC {
            return "「\(hostText)」是 fc00::/7 唯一本地地址（IPv6 私网），不允许出站访问"
        }
        // fe80::/10 link-local（IPv6 里的 169.254/16 同类）
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 {
            return "「\(hostText)」是 fe80::/10 link-local 地址（仅限本地链路），不允许出站访问"
        }

        // IPv4-mapped（::ffff:a.b.c.d，前 10 字节为 0、接着两个 0xFF）
        // 为什么不"解出内嵌 IPv4 再判断"而要整类拒绝：这种写法在 URL 里没有任何正当用途，
        // 而且各栈对它的处理不一致（有的把 ::ffff:7f00:1 直接当回环），整类拒绝最省事也最安全。
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            let v4 = embeddedIPv4(bytes)
            let category = ipv4DenyCategory(v4)
            let inner = category.map { "内嵌 \(embeddedIPv4Text(v4))，属于 \($0)" } ?? "内嵌 \(embeddedIPv4Text(v4))"
            return "「\(hostText)」是 IPv4-mapped IPv6 地址（\(inner)），不允许出站访问"
        }

        // 已废弃的 IPv4-compatible（::a.b.c.d，前 12 字节为 0）：只在真被映射到内网时拒绝，
        // 因为 ::1 已经在上面被拦掉了，这里剩下的基本是同一条补丁路径。
        if bytes[0..<12].allSatisfy({ $0 == 0 }) {
            let v4 = embeddedIPv4(bytes)
            if let category = ipv4DenyCategory(v4) {
                return "「\(hostText)」内嵌的 IPv4 地址 \(embeddedIPv4Text(v4)) 属于 \(category)，不允许出站访问"
            }
        }

        // NAT64 well-known 前缀 64:ff9b::/96：在 IPv6-only 网络里它会被翻译成内嵌的 IPv4，
        // 所以真正决定连到哪的是那 4 个字节，必须按 IPv4 规则再判一次。
        if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xFF, bytes[3] == 0x9B,
           bytes[4..<12].allSatisfy({ $0 == 0 }) {
            let v4 = embeddedIPv4(bytes)
            if let category = ipv4DenyCategory(v4) {
                return "「\(hostText)」是 NAT64 地址，内嵌的 IPv4 地址 \(embeddedIPv4Text(v4)) 属于 \(category)，不允许出站访问"
            }
        }

        return nil
    }

    private static func embeddedIPv4(_ bytes: [UInt8]) -> UInt32 {
        (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16) | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
    }

    private static func embeddedIPv4Text(_ v4: UInt32) -> String {
        "\((v4 >> 24) & 0xFF).\((v4 >> 16) & 0xFF).\((v4 >> 8) & 0xFF).\(v4 & 0xFF)"
    }
}
