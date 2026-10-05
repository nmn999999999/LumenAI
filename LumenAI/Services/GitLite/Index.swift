import Foundation

/// `.git/index` 的一条记录（git index 格式版本 2；读兼容 v2/v3，写恒为 v2）。
///
/// index 是"暂存区"的真相：`git add` 写它、`git status` 读它、`git commit` 按它建 tree。
/// 格式任何一处对不上，真实 `git status` 就会说 "index file corrupt"，
/// 所以字段顺序/补齐规则全部照 git 的 `cache.h` 实现。
struct GitIndexEntry {

    var path: String
    /// 八进制字面量的十进制值（100644 → 33188），与 git 一样按整数存。
    var mode: UInt32
    var sha: String

    var ctimeSec: UInt32 = 0
    var ctimeNsec: UInt32 = 0
    var mtimeSec: UInt32 = 0
    var mtimeNsec: UInt32 = 0
    var dev: UInt32 = 0
    var ino: UInt32 = 0
    var uid: UInt32 = 0
    var gid: UInt32 = 0
    var size: UInt32 = 0

    /// flags：bit15 assume-valid、bit14 extended、bit13-12 stage、bit11-0 nameLength。
    var flags: UInt16 = 0

    var stage: Int { Int((flags >> 12) & 0b11) }

    /// 用工作区文件的 stat 填充索引头（git 靠这些判断"内容没变就别重算哈希"）。
    static func entry(path: String, mode: UInt32, sha: String, attrs: [FileAttributeKey: Any]) -> GitIndexEntry {
        var e = GitIndexEntry(path: path, mode: mode, sha: sha)
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let ctime = (attrs[.creationDate] as? Date) ?? mtime
        e.mtimeSec = UInt32(mtime.timeIntervalSince1970)
        e.mtimeNsec = UInt32((mtime.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)) * 1_000_000_000)
        e.ctimeSec = UInt32(ctime.timeIntervalSince1970)
        e.ctimeNsec = UInt32((ctime.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)) * 1_000_000_000)
        e.size = UInt32((attrs[.size] as? NSNumber)?.uint32Value ?? 0)
        e.ino = UInt32(truncatingIfNeeded: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        e.dev = UInt32(truncatingIfNeeded: (attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0)
        e.uid = UInt32(truncatingIfNeeded: (attrs[.ownerAccountID] as? NSNumber)?.uint32Value ?? 0)
        e.gid = UInt32(truncatingIfNeeded: (attrs[.groupOwnerAccountID] as? NSNumber)?.uint32Value ?? 0)
        return e
    }

    /// stat 看起来一致（size + mtime + mode）→ 可以不读文件内容直接认为没变。
    /// 故意不比较 ino/dev：iOS 的文件被 iCloud/备份动过会换 ino，
    /// 那种情况我们宁可多算一次哈希（正确性优先于速度）。
    func statMatches(_ attrs: [FileAttributeKey: Any]) -> Bool {
        guard let mtime = attrs[.modificationDate] as? Date else { return false }
        let m = UInt32(mtime.timeIntervalSince1970)
        let s = UInt32((attrs[.size] as? NSNumber)?.uint32Value ?? 0)
        return m == mtimeSec && s == size
    }
}

/// `.git/index` 的读写。
enum GitIndexCodec {

    static let signature = Data("DIRC".utf8)
    static let version: UInt32 = 2

    /// 读 index。文件不存在 = 空暂存区（首次 `git add` 前的正常状态）。
    static func read(at file: String) throws -> [GitIndexEntry] {
        guard let data = FileManager.default.contents(atPath: file) else { return [] }
        guard data.count > 32 else { throw GitError.corrupt("index 文件过短") }

        // 尾部 20 字节是**前段内容**的 SHA-1，先验它：能挡住截断与错位写入。
        let body = data.prefix(data.count - 20)
        let stored = data.suffix(20).map { String(format: "%02x", $0) }.joined()
        if ObjectStore.sha1Hex(body) != stored {
            throw GitError.corrupt("index 校验和不匹配")
        }
        guard body.startIndex + 12 <= body.endIndex,
              body.prefix(4).elementsEqual(signature) else {
            throw GitError.corrupt("index 缺少 DIRC 签名")
        }
        let version = readU32(body, at: 4)
        guard version == 2 || version == 3 else {
            throw GitError.unsupported("git index 版本 v\(version)（只读 v2/v3）")
        }
        let count = Int(readU32(body, at: 8))
        var offset = 12
        var entries = [GitIndexEntry]()
        entries.reserveCapacity(min(count, 4096))

        for _ in 0..<count {
            guard offset + 62 <= body.count else { throw GitError.corrupt("index 条目被截断") }
            var e = GitIndexEntry(path: "", mode: 0, sha: "")
            e.ctimeSec = readU32(body, at: offset)
            e.ctimeNsec = readU32(body, at: offset + 4)
            e.mtimeSec = readU32(body, at: offset + 8)
            e.mtimeNsec = readU32(body, at: offset + 12)
            e.dev = readU32(body, at: offset + 16)
            e.ino = readU32(body, at: offset + 20)
            e.mode = readU32(body, at: offset + 24)
            e.uid = readU32(body, at: offset + 28)
            e.gid = readU32(body, at: offset + 32)
            e.size = readU32(body, at: offset + 36)
            let shaStart = offset + 40
            e.sha = (shaStart..<shaStart + 20).map { String(format: "%02x", body[$0]) }.joined()
            e.flags = readU16(body, at: offset + 60)
            let nameLen = Int(e.flags & 0x0FFF)
            var cursor = offset + 62
            // v3 且置了 extended 位 → 再读 2 字节扩展 flags（我们不解释它，跳过即可）。
            if version >= 3, (e.flags & 0x4000) != 0 {
                guard cursor + 2 <= body.count else { throw GitError.corrupt("index v3 扩展段被截断") }
                cursor += 2
            }
            let nameBytes: Data
            if nameLen == 0x0FFF {
                // 超长名字：flags 里存不下，读到下一个 0 为止。
                guard let end = body[cursor...].firstIndex(of: 0) else {
                    throw GitError.corrupt("index 条目名字缺少终止符")
                }
                nameBytes = body[cursor..<end]
                cursor = end + 1
            } else {
                guard cursor + nameLen <= body.count else {
                    throw GitError.corrupt("index 条目名字被截断")
                }
                nameBytes = body[cursor..<cursor + nameLen]
                cursor += nameLen
            }
            e.path = String(decoding: nameBytes, as: UTF8.self)
            // 条目总长 = align8(62 + 名字长度 + 1)：名字后**至少 1 个 NUL**，
            // 再补 NUL 到 8 字节边界。注意对齐是**相对条目起点**算的（index 头是 12 字节，
            // 不是 8 的倍数，按绝对偏移算会整表错位）。
            let actualLen = cursor - (offset + 62)
            let entryTotal = ((62 + actualLen + 1) + 7) & ~7
            cursor = offset + entryTotal
            guard cursor <= body.count else { throw GitError.corrupt("index 条目补齐越界") }
            entries.append(e)
            offset = cursor
        }
        return entries
    }

    /// 写 index（版本 2：不写扩展段，只写条目 + 校验和）。
    static func write(_ entries: [GitIndexEntry], to file: String) throws {
        // git 要求 index 按路径排序（NUL 结尾语义 = 前缀更短者在前，与逐字节比较一致）。
        let sorted = entries.sorted { lhs, rhs in
            let l = Array(lhs.path.utf8), r = Array(rhs.path.utf8)
            let n = min(l.count, r.count)
            if n > 0 {
                for i in 0..<n where l[i] != r[i] { return l[i] < r[i] }
            }
            return l.count < r.count
        }

        var out = Data()
        out.append(signature)
        out.append(be32(version))
        out.append(be32(UInt32(sorted.count)))

        for e in sorted {
            var flags = e.flags & 0xF000  // 保留 stage/extended 位，名字长度按实际重算
            let nameBytes = Array(e.path.utf8)
            if nameBytes.count >= 0x0FFF {
                flags |= 0x0FFF
            } else {
                flags |= UInt16(nameBytes.count)
            }
            out.append(be32(e.ctimeSec))
            out.append(be32(e.ctimeNsec))
            out.append(be32(e.mtimeSec))
            out.append(be32(e.mtimeNsec))
            out.append(be32(e.dev))
            out.append(be32(e.ino))
            out.append(be32(e.mode))
            out.append(be32(e.uid))
            out.append(be32(e.gid))
            out.append(be32(e.size))
            out.append(contentsOf: GitTreeEntry.hexToBytes(e.sha))
            out.append(be16(flags))
            out.append(contentsOf: nameBytes)
            // 与读取端同一条规则：条目总长 align8(62 + 名字长度 + 1)，
            // 所以名字后先补 1 个 NUL，再补到 8 字节边界。
            let entryLen = 62 + nameBytes.count
            let entryTotal = ((entryLen + 1) + 7) & ~7
            out.append(contentsOf: repeatElement(UInt8(0), count: entryTotal - entryLen))
        }
        let checksum = ObjectStore.sha1Hex(out)
        out.append(contentsOf: GitTreeEntry.hexToBytes(checksum))

        let dir = (file as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // 原子写：index 半截损坏 = 整个暂存区报废。
        let tmp = file + ".tmp-\(UUID().uuidString.prefix(8))"
        try out.write(to: URL(fileURLWithPath: tmp), options: .atomic)
        if FileManager.default.fileExists(atPath: file) {
            try FileManager.default.removeItem(atPath: file)
        }
        try FileManager.default.moveItem(atPath: tmp, toPath: file)
    }

    // MARK: - 字节序小工具（git 全部是 big-endian）

    private static func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }

    private static func be16(_ v: UInt16) -> Data {
        Data([UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }

    private static func readU32(_ d: Data, at: Int) -> UInt32 {
        let i = d.startIndex + at
        return (UInt32(d[i]) << 24) | (UInt32(d[d.index(i, offsetBy: 1)]) << 16)
            | (UInt32(d[d.index(i, offsetBy: 2)]) << 8) | UInt32(d[d.index(i, offsetBy: 3)])
    }

    private static func readU16(_ d: Data, at: Int) -> UInt16 {
        let i = d.startIndex + at
        return (UInt16(d[i]) << 8) | UInt16(d[d.index(i, offsetBy: 1)])
    }
}
