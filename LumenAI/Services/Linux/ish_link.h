#ifndef LUMEN_ISH_LINK_H
#define LUMEN_ISH_LINK_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// iSH「Linux 模式」引擎的链接锚点。
///
/// 为什么需要它：`third_party/ish` 的那几套静态库只出现在 `OTHER_LDFLAGS` 里时，
/// 静态库是**惰性**链接 —— 没有任何代码引用它们，实测最终二进制里 iSH 符号数为 0，
/// 等于"链了但没进去"。这个 shim 取一次内核入口的地址，让链接器必须把内核真正拉进来，
/// 并把模拟器（asbestos）等传递依赖一起解析出来。
///
/// 这里只**声明**而不引入 iSH 的 `kernel/init.h`（或把 iSH 根目录加进
/// HEADER_SEARCH_PATHS —— 那会让 `kernel/time.h` 遮蔽系统头，踩过）。符号名由 `nm` 核对。
///
/// `used` 是必须的：Release 开了 `-dead_strip`，这个函数若没有调用点会被整段剥掉，
/// 它对内核入口的引用也随之消失 —— 那就退回"链了但没进去"了。

/// 返回 Linux 内核入口（`run_kernel`）的地址；非 0 表示内核确实在本二进制里。
__attribute__((used)) uintptr_t lumen_linux_kernel_entry(void);

/// 返回模拟器入口（`asbestos_new`）的地址，用于确认传递依赖也被解析进二进制。
__attribute__((used)) uintptr_t lumen_linux_emu_marker(void);

#ifdef __cplusplus
}
#endif

#endif
