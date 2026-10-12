#ifndef LUMEN_LINUX_APP_GLUE_H
#define LUMEN_LINUX_APP_GLUE_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// iSH「Linux 模式」在 App 这一侧的全部胶水（15 个内核要的符号 + boot/session 驱动）。
///
/// 为什么需要这一层：内核那两套库（liblinux.a / libiSHLinux.a）把「内核 ↔ iOS 世界」的
/// 接口留成未定义符号，上游实现在 iSH 的 App 层（app/IOSCalls.m、app/CurrentRoot.m、
/// app/AppDelegate.m、app/Terminal.m）。但那一层同时带着 iSH 自己的 AppDelegate / Roots /
/// AppGroup（会牵出 AppGroup entitlement）和 `T _main` —— 不能整体链进来。
/// 所以这里按上游语义自己实现一遍，只保留接口，丢掉 iSH 的 App 壳。
///
/// 链接探针（`clang -force_load liblumen-linux.a`）实测需要补的符号**恰好**是这 15 个：
///   ConsoleLog / ReportPanic / DefaultRootPath / FsInitialize
///   Terminal_terminalWithType_number / Terminal_setLinuxTTY
///   Terminal_sendOutput_length / Terminal_roomForOutput
///   UIPasteboard_get / UIPasteboard_changeCount / UIPasteboard_set
///   NSData_length / NSData_bytes / async_do_in_ios / objc_get / objc_put
/// （另外 sync_do_in_workqueue 在上游属于 IOSCalls.m，而 libiSHLinux.a 里没有它，
///  所以也由这里提供。）

// ── 引擎状态（给设置页/ShellView 显示，判据来自符号地址，不是猜）────────────

/// 内核入口（`run_kernel`）是否真的在本二进制里。链接期保证 → 运行期恒 true；
/// 它存在的意义是**可断言**（CI 用 nm 复核同一件事）。
bool lumen_linux_kernel_linked(void);
/// 模拟器（asbestos）入口是否也在。只链了内核而落掉 emu 时这里是 false。
bool lumen_linux_emu_available(void);

// ── rootfs ──────────────────────────────────────────────────────────────

/// 设定 fakefs 根目录（内核里的 `/root` 就是它）。必须在 boot 之前设好。
void lumen_linux_set_root(const char *path);
/// 该目录是否已经导入过 rootfs（判据 = meta.db 存在，与 tools/fakefs.c 一致）。
bool lumen_linux_rootfs_ready(const char *path);
/// 导入 rootfs（tar.gz → fakefs 的 data/ + meta.db）。成功返回 true。
/// 失败时把原因写进 errbuf（导入器自己的错误结构比 errno 具体得多）。
bool lumen_linux_import_rootfs(const char *tarball, const char *root, char *errbuf, size_t errlen);

// ── 启动内核 ────────────────────────────────────────────────────────────

/// 启动内核（= 上游 `actuate_kernel`：strcpy(boot_command_line) + run_kernel）。
/// `run_kernel()` 会**返回**（起完模拟 CPU 线程就 return，见 arch/ish/kernel/setup.c），
/// 所以本函数在专用线程上调用它，不占主线程、不冻 UI。
/// 返回 0 表示已走到 startup；负值见 LinuxAppGlue.m 里的枚举。
int lumen_linux_boot(const char *cmdline);
/// 内核是否已经启动过（无论成功失败）。
bool lumen_linux_booted(void);

// ── 会话（真 Linux shell）───────────────────────────────────────────────

/// 起一个会话（`exe`，一般是 /bin/sh）。out_pid 返回 pid。需要内核已启动。
int lumen_linux_start_session(const char *exe, const char *const *argv, const char *const *envp, int *out_pid);
/// 会话的 tty 是否已经拿到（拿到之前 write 会失败）。
bool lumen_linux_session_active(void);
/// 往会话 tty 写输入（用户敲进去的字节）。
int lumen_linux_session_write(const char *bytes, unsigned len);

/// 会话 tty 的窗口大小变化（内核侧 tcgetwinsize 用）。
void lumen_linux_session_resize(int cols, int rows);

// ── 取数（给面板显示）：客户机内存 / 网卡 / 宿主内存 ──────────────────────
//
// 为什么要分「客户机」和「宿主」两个数：客户机 RAM 是**固定 256 MB**
// （arch/ish/kernel/setup.c: ish_phys_size = 0x10000000，host_mmap 到宿主 0x200000000），
// 那块映射只是保留地址空间，真正吃掉宿主物理内存的只是被触碰过的页。
// 所以「客户机里用了多少」和「这个 App 一共多大」不是一回事，两个都报。

/// 客户机（Linux）内存账，单位字节。返回 false = 内核还没起来 / 取不到。
///
/// ⚠️ **阻塞**：数在内核里取（宿主看不到客户机的页表），要等内核把值送回来。
/// 调用方放到**后台队列**，别在主线程上等。
bool lumen_linux_guest_meminfo(unsigned long long *total, unsigned long long *free_,
                               unsigned long long *buffers, unsigned long long *shared);

/// 宿主进程（= 这个 App）自己的物理内存占用：phys_footprint / resident，单位字节。
/// 非阻塞（就是一次 task_info）。
bool lumen_linux_host_memory(unsigned long long *phys_footprint, unsigned long long *resident);

/// 客户机网卡（golp）状态：名字 / ifindex / 是否 IFF_UP / IPv4（主机字节序）。
/// 返回 false = 内核里根本没有这块网卡（= 桥接联网没接上）。
///
/// ⚠️ **阻塞**（同样要内核上下文），调用方放后台队列。
///
/// 为什么这条值得显示：golp 是注册在**内核**里的（CONFIG_GOLP +
/// CONFIG_GOLP_AUTOCONFIG，见 arch/ish/Kconfig），宿主侧完全看不到它 ——
/// App 只能看到自己的 socket。所以「客户机里有没有一块 up 着、拿到 10.0.0.1 的网卡」
/// 是「联网到底通没通」唯一诚实的判据。
bool lumen_linux_net_info(char *name, size_t namelen, int *ifindex, int *up, unsigned int *ipv4);

/// 把**宿主当前的 DNS 服务器**写进客户机的 /etc/resolv.conf。返回 0 = 成功。
///
/// 为什么非做不可：iSH 官方 rootfs 里**没有** /etc/resolv.conf（实测 tarball 只有
/// /etc/hosts、/etc/nsswitch.conf）。缺了它，客户机的 musl 解析器会退回 127.0.0.1 ——
/// 而客户机的 127.0.0.1 上什么都没有，表现就是「网卡 up 着、地址也有、域名一个都解析不了」。
/// 上游 iSH 只在 NotLinux 模式做这件事（app/AppDelegate.m 的 configureDns 是 `#if !ISH_LINUX`），
/// Linux 模式这个洞得我们自己填。
///
/// 宿主 DNS 的取法照抄上游：res_ninit + res_getservers（iOS 上就是当前网络配置）；
/// 一条都读不到时退回 1.1.1.1（宁可给个公共解析器，也别让客户机完全没 DNS）。
/// ⚠️ **阻塞**（写文件要内核上下文），调用方放后台队列。建议在 boot 成功后、开会话之前调。
int lumen_linux_write_resolv_conf(void);

// ── 关闭 ────────────────────────────────────────────────────────────────

/// 关闭 Linux：把客户机里**所有用户进程** SIGKILL 掉，会话随之结束（pty 被内核清理）。
/// 返回被杀的进程数；-1 = 内核没在运行。
///
/// 为什么不走内核那条路：`arch/ish/kernel/reboot.c` 里 machine_halt() 就是 `exit(0)` ——
/// 客户机里敲 halt/poweroff 会把**整个 App 一起结束掉**。所以关闭只能从宿主侧按进程收。
/// 而且要如实说：**内核本身卸不掉**（iSH 没有这个接口，内核也只支持启动一次），
/// 关闭后想重新启动必须重启 App。
///
/// ⚠️ **阻塞**（要等内核把信号发完），调用方放后台队列。
int lumen_linux_shutdown(void);

/// 是否已经关闭过（关闭过就不能再启动 —— 内核只能启动一次）。
bool lumen_linux_stopped(void);

// ── 回host（内核 → App）的一次性回调注册 ────────────────────────────────

/// 内核 console 输出（`ConsoleLog`）。回调在**主线程**触发。
void lumen_linux_set_console_sink(void (*sink)(const char *bytes, unsigned len, void *ctx), void *ctx);
/// 会话 tty 输出（`Terminal_sendOutput_length`）。回调在**主线程**触发。
void lumen_linux_set_session_sink(void (*sink)(const char *bytes, unsigned len, void *ctx), void *ctx);
/// 内核 panic（`ReportPanic`）。回调在**主线程**触发。
void lumen_linux_set_panic_sink(void (*sink)(const char *message, void *ctx), void *ctx);
/// 会话结束（tty hangup，pid 已退出）。
void lumen_linux_set_session_end_sink(void (*sink)(void *ctx), void *ctx);

#ifdef __cplusplus
}
#endif

#endif
