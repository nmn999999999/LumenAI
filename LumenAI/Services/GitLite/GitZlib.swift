import Foundation
import zlib

/// git 对象文件的压缩层（RFC 1950 zlib 流）。
///
/// 为什么必须是 zlib 而不是系统 `Compression` 框架：`COMPRESSION_ZLIB` 产出的是
/// **裸 DEFLATE**（没有 zlib 头、没有 Adler-32 尾），而 git 的 loose object 是完整
/// 的 zlib 流 —— 差这 6+4 个字节，`git fsck` 就会报 `corrupt`。
/// 系统 libz 直接给出与 git/`zlib(3)` 逐位一致的实现，所以这里 `import zlib`。
enum GitZlib {

    /// 压缩。空输入同样走通用路径：`compress2` 会写出合法的空流（头 + Adler-32）。
    static func compress(_ input: Data) -> Data? {
        var destLen = compressBound(uLong(input.count))
        guard destLen > 0 else { return nil }
        var dest = Data(count: Int(destLen))
        let rc = dest.withUnsafeMutableBytes { db -> Int32 in
            input.withUnsafeBytes { ib -> Int32 in
                guard let dp = db.baseAddress, let ip = ib.baseAddress else { return Z_MEM_ERROR }
                return compress2(dp, &destLen, ip, uLong(input.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard rc == Z_OK else { return nil }
        return dest.prefix(Int(destLen))
    }

    /// 解压。用 `uncompress` + 逐步扩容，而不是手写 inflate 循环：
    /// 参数少、没有游标可错位；对象解压是冷路径（每次读对象一次），性能不敏感。
    /// 上限 256MB：防的是"损坏的流看起来解压无穷大"这种资源耗尽。
    static func decompress(_ input: Data, maxOutput: Int = 256 << 20) -> Data? {
        guard !input.isEmpty else { return nil }
        // 从 4 倍输入体积起步：git 对象（文本）典型压缩比 2~5 倍，一两次扩容就够。
        var capacity = max(64 * 1024, min(input.count * 4, maxOutput))
        while capacity <= maxOutput {
            var out = Data(count: capacity)
            var outLen = uLong(capacity)
            let rc = out.withUnsafeMutableBytes { ob -> Int32 in
                input.withUnsafeBytes { ib -> Int32 in
                    guard let op = ob.baseAddress, let ip = ib.baseAddress else { return Z_MEM_ERROR }
                    return uncompress(op, &outLen, ip, uLong(input.count))
                }
            }
            if rc == Z_OK { return out.prefix(Int(outLen)) }
            // 缓冲区不够：翻倍重来。数据损坏会返回 Z_DATA_ERROR，直接判定失败。
            if rc != Z_BUF_ERROR { return nil }
            capacity *= 2
        }
        return nil
    }
}
