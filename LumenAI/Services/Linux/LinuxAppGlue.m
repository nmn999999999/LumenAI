//
//  LinuxAppGlue.m — iSH「Linux 模式」在 App 这一侧的实现（内核要的那 15 个符号 + 驱动）。
//
//  上游对照（third_party/ish/app/）：
//    async_do_in_ios / ConsoleLog / objc_get / objc_put / UIPasteboard_* / NSData_*
//                                    → IOSCalls.m
//    sync_do_in_workqueue            → IOSCalls.m（libiSHLinux.a 里没有这个符号，必须我们自己给）
//    ReportPanic                     → AppDelegate.m:64
//    DefaultRootPath                 → AppDelegate.m:151
//    FsInitialize                    → CurrentRoot.m:48（Linux 模式下由 LinuxRoot.c:39 在内核里调）
//    Terminal_*                      → Terminal.m:347（上游是 VT100 状态机，我们这里是原始字节 sink）
//
//  两件事必须和上游不一样，且都是刻意的：
//  1) **不做 iSH 的 App 壳**：不碰 Roots / AppGroup / AppDelegate（那会牵出 entitlement 和 `T _main`）。
//  2) **终端先只做「原始字节」**：上游 Terminal.m 会把 tty 输出喂给 VT100 状态机再画到 UIKit；
//     我们这一版先把字节透出来（ShellTranscript 里按 ANSI 清洗后显示），VT100 屏幕语义
//     （光标寻址、全屏程序）留给下一步。所以这里不假装是"真终端"。
//
#import "LinuxAppGlue.h"
#import "LinuxInterop.h"

#import <UIKit/UIKit.h>
#import <Block.h>
#import <mach/mach.h>
#import <mach/task_info.h>
#import <netdb.h>
#import <resolv.h>
#import <os/log.h>
#import <pthread.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

/// 会话的 pty 终端对象（内核侧 `Terminal_terminalWithType_number` 创建）。
@interface LumenLinuxTerminal : NSObject
@property (nonatomic) int type;
@property (nonatomic) int number;
@property (nonatomic) struct linux_tty *tty;
@end

@implementation LumenLinuxTerminal
@end

// 链接锚点（ish_link.c）：取内核/模拟器入口的地址，判据=非 0。
extern uintptr_t lumen_linux_kernel_entry(void);
extern uintptr_t lumen_linux_emu_marker(void);

// ── rootfs 导入器（tools/fakefs.c）─────────────────────────────────────────
// 这里**本地声明**而不 include "tools/fakefs.h"：把 iSH 根目录加进 HEADER_SEARCH_PATHS
// 会让 kernel/time.h 遮蔽系统的 time.h（踩过）。签名与 tools/fakefs.h 逐字对应。
typedef struct {
    int line;
    int type;   // 0=ERR_ARCHIVE 1=ERR_SQLITE 2=ERR_POSIX 3=ERR_CANCELLED（见 tools/fakefs.h）
    int code;
    char *message;
} lumen_fakefsify_error;
typedef struct {
    void *cookie;
    void (*callback)(void *cookie, double progress, const char *message, bool *cancel_out);
} lumen_progress;
extern bool fakefs_import(const char *archive_path, const char *fs,
                          lumen_fakefsify_error *err_out, lumen_progress progress);

static os_log_t LOG(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.lumenai.app", "linux"); });
    return log;
}

// ── 状态 ───────────────────────────────────────────────────────────────────
static char g_root_path[4096];
static volatile int g_boot_state = 0;   // 0 未启动 / 1 启动中 / 2 已启动 / 3 失败

// 一次性回调（内核 → App）。全部在主线程回调，UI 侧不用自己再跳。
static void (*g_console_sink)(const char *, unsigned, void *);
static void *g_console_ctx;
static void (*g_session_sink)(const char *, unsigned, void *);
static void *g_session_ctx;
static void (*g_panic_sink)(const char *, void *);
static void *g_panic_ctx;
static void (*g_session_end_sink)(void *);
static void *g_session_end_ctx;

// sink 注册**之前**就产生的输出不能丢（内核在启动早期就开始 printk，
// 而 Swift 侧要等 LinuxBoot 初始化完才注册）——先攒着，注册时补发。
static NSMutableData *g_pending_console;
static NSMutableData *g_pending_session;

static void hop(void (^block)(void)) {
    dispatch_async(dispatch_get_main_queue(), block);
}

static void deliver_console(NSData *chunk) {
    if (g_console_sink)
        g_console_sink((const char *)chunk.bytes, (unsigned)chunk.length, g_console_ctx);
    else
        [g_pending_console appendData:chunk];
}

static void deliver_session(NSData *chunk) {
    if (g_session_sink)
        g_session_sink((const char *)chunk.bytes, (unsigned)chunk.length, g_session_ctx);
    else
        [g_pending_session appendData:chunk];
}

// ── 引擎状态 ───────────────────────────────────────────────────────────────

bool lumen_linux_kernel_linked(void) { return lumen_linux_kernel_entry() != 0; }
bool lumen_linux_emu_available(void) { return lumen_linux_emu_marker() != 0; }

bool lumen_linux_booted(void) { return g_boot_state == 2; }

// ── rootfs ─────────────────────────────────────────────────────────────────

void lumen_linux_set_root(const char *path) {
    if (path == NULL) { g_root_path[0] = '\0'; return; }
    strlcpy(g_root_path, path, sizeof(g_root_path));
}

bool lumen_linux_rootfs_ready(const char *path) {
    if (path == NULL || path[0] == '\0') return false;
    char db[4096];
    snprintf(db, sizeof(db), "%s/meta.db", path);
    return access(db, F_OK) == 0;
}

bool lumen_linux_import_rootfs(const char *tarball, const char *root, char *errbuf, size_t errlen) {
    lumen_fakefsify_error err;
    memset(&err, 0, sizeof(err));
    lumen_progress progress;
    memset(&progress, 0, sizeof(progress));
    if (fakefs_import(tarball, root, &err, progress))
        return true;
    if (errbuf && errlen) {
        snprintf(errbuf, errlen, "fakefs_import 失败（line=%d type=%d code=%d）：%s",
                 err.line, err.type, err.code, err.message ? err.message : "?");
    }
    free(err.message);
    return false;
}

// ── 启动内核 ───────────────────────────────────────────────────────────────
//
// 为什么开专用 pthread 而不是直接在主线程调：
// `actuate_kernel` = strcpy(boot_command_line) + run_kernel()，而 run_kernel() 内部是
// setup_current + start_cpu_thread(start_main) + wait_for_startup() —— 它**会返回**
// （模拟 CPU 跑在它自己起的宿主线程上，见 arch/ish/kernel/setup.c:49）。上游在
// willFinishLaunching 里直接调（主线程），代价是启动期 UI 卡住；我们放到专用线程上，
// 主线程留着跑 runloop（`async_do_in_ios` 的回调要靠它落地）。
//
// 线程**不退出**：setup_current 把 `current`（内核的 per-thread 状态）挂在这个线程上，
// 线程一退出那段状态就成了悬着的。上游的调用线程（主线程）本来就长活，harness 也是
// 让主线程继续 CFRunLoopRun，所以这里 park 住它。
static pthread_t g_boot_thread;
static pthread_cond_t g_page_keep_alive = PTHREAD_COND_INITIALIZER;
static pthread_mutex_t g_page_keep_alive_mutex = PTHREAD_MUTEX_INITIALIZER;

static void *lumen_boot_thread_main(void *arg) {
    char *cmdline = arg;
    actuate_kernel(cmdline);      // 内部 run_kernel()：返回即 startup 已到
    free(cmdline);
    g_boot_state = 2;
    hop(^{ os_log_debug(LOG(), "linux kernel startup reached"); });
    // 永不自旋、永不醒：见上面注释（这个线程要活着）。
    pthread_mutex_lock(&g_page_keep_alive_mutex);
    pthread_cond_wait(&g_page_keep_alive, &g_page_keep_alive_mutex);
    pthread_mutex_unlock(&g_page_keep_alive_mutex);
    return NULL;
}

int lumen_linux_boot(const char *cmdline) {
    if (g_boot_state == 2) return 0;
    if (g_boot_state == 1) return -2;                       // 已经在启动
    if (g_root_path[0] == '\0') return -3;                  // 没设 rootfs：不能瞎起（会 panic）
    if (!lumen_linux_rootfs_ready(g_root_path)) return -4;  // rootfs 还没导入
    g_boot_state = 1;
    char *copy = strdup(cmdline ? cmdline : "");
    if (pthread_create(&g_boot_thread, NULL, lumen_boot_thread_main, copy) != 0) {
        free(copy);
        g_boot_state = 3;
        return -5;
    }
    return 0;
}

// ── 会话 ───────────────────────────────────────────────────────────────────

/// 会话的 pty 终端对象。**不**接手 ios_pty_open 给的那份 +1：
/// 那个 +1 由内核侧 `ios_pty_cleanup` 的 objc_put 释放（LinuxPTY.c:76-77），
/// 这里只是自己 retain 一份来发输入/转输出，避免上游那套「谁持有」的歧义。
static LumenLinuxTerminal *g_session_terminal;

int lumen_linux_start_session(const char *exe, const char *const *argv,
                              const char *const *envp, int *out_pid) {
    if (g_boot_state != 2) return -1;
    __block int rc = -1;
    __block int pid = 0;
    __block nsobj_t term = NULL;
    // linux_start_session 必须跑在 iSH 的 workqueue 上下文里（上游 TerminalViewController.m:213
    // 也是 sync_do_in_workqueue 包起来的），主线程直接调会踩 current 上下文。
    sync_do_in_workqueue(^(void (^done)(void)) {
        linux_start_session(exe, argv, envp, ^(int retval, int pid_, nsobj_t terminal) {
            rc = retval;
            pid = pid_;
            term = terminal;
            done();
        });
    });
    if (rc < 0) return rc;
    if (term) {
        g_session_terminal = (__bridge LumenLinuxTerminal *)term;
    }
    if (out_pid) *out_pid = pid;
    return 0;
}

bool lumen_linux_session_active(void) {
    return g_session_terminal != nil && g_session_terminal.tty != NULL;
}

int lumen_linux_session_write(const char *bytes, unsigned len) {
    struct linux_tty *tty = g_session_terminal.tty;
    if (tty == NULL || tty->ops == NULL || tty->ops->send_input == NULL) return -1;
    // ⚠️ 必须在**内核上下文**里调：ios_pty_cb_send_input → kernel_write 要用内核的 `current`，
    // 而 App 主线程（或任何普通宿主线程）没有 current —— 直接调就是跳 0 崩。
    // 这个坑是在 harness 上真踩出来的（SIGSEGV 在 kernel_write，backtrace 见 STATUS.md）：
    // 上游能直接调是因为它 App 的主线程**就是**内核线程；我们把内核放在专用 pthread 上，
    // 主线程不再是内核线程，所以统一走 workqueue（内核线程执行）。
    char *copy = malloc(len);
    if (copy == NULL) return -2;
    memcpy(copy, bytes, len);
    async_do_in_workqueue(^{
        // 会话可能在排队期间就结束了（pty 被清理、tty 已失效）——再检查一次再写。
        if (tty != g_session_terminal.tty) { free(copy); return; }
        tty->ops->send_input(tty, copy, len);
        free(copy);
    });
    return 0;
}

void lumen_linux_session_resize(int cols, int rows) {
    struct linux_tty *tty = g_session_terminal.tty;
    if (tty == NULL || tty->ops == NULL || tty->ops->resize == NULL) return;
    async_do_in_workqueue(^{                      // 同上：resize 也要内核上下文
        if (tty != g_session_terminal.tty) return;
        tty->ops->resize(tty, cols, rows);
    });
}

static void session_ended(void) {
    g_session_terminal = nil;
    if (g_session_end_sink) {
        void (*sink)(void *) = g_session_end_sink;
        void *ctx = g_session_end_ctx;
        hop(^{ sink(ctx); });
    }
}

// ── 取数：客户机内存 / 网卡 / 宿主内存 ─────────────────────────────────────

// 内核侧实现（LumenAI/Services/Linux/lumen_kernel_addon.c，随 liblumen-linux.a 一起链进来）。
// 本地声明而不 include：那个文件是**内核**编译单元（要 __KERNEL__ 与内核头），
// 在这里 include 会把内核头拖进 ObjC 编译单元，直接编不过。
extern void lumen_meminfo(unsigned long long *total, unsigned long long *free_,
                          unsigned long long *shared, unsigned long long *buffers);
extern int lumen_net_info(char *name, size_t namelen, int *ifindex, int *up, int *running,
                          unsigned int *ipv4, unsigned long long *rx_bytes,
                          unsigned long long *tx_bytes);
extern int lumen_kill_user_processes(void);
extern int lumen_write_guest_file(const char *path, const char *buf, unsigned len);

/// 内核上下文里取一次客户机内存账。
///
/// ⚠️ 阻塞：`sync_do_in_workqueue` 会等内核线程把 block 跑完。这条路径**不**经过主队列
/// （async_do_in_workqueue → IRQ → CPU0 线程 → schedule_work → workqueue 线程），
/// 所以在主线程上调不会自锁；但取数本身要等内核，UI 侧仍然放后台队列调。
bool lumen_linux_guest_meminfo(unsigned long long *total, unsigned long long *free_,
                               unsigned long long *buffers, unsigned long long *shared) {
    if (g_boot_state != 2 && g_boot_state != 4) return false;
    __block unsigned long long t = 0, f = 0, s = 0, b = 0;
    sync_do_in_workqueue(^(void (^done)(void)) {
        lumen_meminfo(&t, &f, &s, &b);
        done();
    });
    if (t == 0) return false;             // 内核还没把这些结构建起来
    if (total)   *total   = t;
    if (free_)   *free_   = f;
    if (buffers) *buffers = b;
    if (shared)  *shared  = s;
    return true;
}

bool lumen_linux_host_memory(unsigned long long *phys_footprint, unsigned long long *resident) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) return false;
    if (phys_footprint) *phys_footprint = (unsigned long long)info.phys_footprint;
    if (resident)       *resident      = (unsigned long long)info.resident_size;
    return true;
}

bool lumen_linux_net_info(char *name, size_t namelen, int *ifindex, int *up, unsigned int *ipv4) {
    if (g_boot_state != 2 ) return false;   // 内核没起来 / 已停止时没得问
    __block int found = -2;
    __block int idx = 0, isup = 0, running = 0;
    __block unsigned int addr = 0;
    static char scratch[64];
    memset(scratch, 0, sizeof(scratch));
    sync_do_in_workqueue(^(void (^done)(void)) {
        found = lumen_net_info(scratch, sizeof(scratch), &idx, &isup, &running,
                               &addr, NULL, NULL);
        done();
    });
    if (found != 0) return false;
    if (name && namelen) {
        strlcpy(name, scratch, namelen);
    }
    if (ifindex) *ifindex = idx;
    if (up)      *up      = isup;
    if (ipv4)    *ipv4    = addr;
    return true;
}

// ── 关闭 ───────────────────────────────────────────────────────────────────
//
// 一句话：iSH 没有「卸载内核」，而客户机里的 halt/poweroff 走的是
// arch/ish/kernel/reboot.c 的 machine_halt() = exit(0) —— 那是**整个 App 退出**。
// 所以「关闭 Linux」在这里 = 把客户机里所有用户进程收掉（内核侧 lumen_kill_user_processes，
// 只杀 pid>1 且 mm!=0 的，不碰内核线程、也不碰内层 init）+ 摘掉会话句柄。
// 之后 g_boot_state 停在 4（已停止），UI 如实说明"要重新启动得重启 App"。
int lumen_linux_shutdown(void) {
    if (g_boot_state != 2) return -1;
    // 先摘句柄再杀：杀完 pty 会被内核清理（Terminal_setLinuxTTY(NULL)），
    // 那时 g_session_terminal 里的 tty 已经是野指针，不能再写。
    g_session_terminal = nil;
    g_boot_state = 4;
    __block int killed = 0;
    sync_do_in_workqueue(^(void (^done)(void)) {
        killed = lumen_kill_user_processes();
        done();
    });
    session_ended();     // 复用同一个结束回调：UI 那边表现成"会话结束了"
    return killed;
}

bool lumen_linux_stopped(void) { return g_boot_state == 4; }

int lumen_linux_write_resolv_conf(void) {
    if (g_boot_state != 2) return -1;

    // 宿主侧取 DNS：与上游 NotLinux 模式的 configureDns（app/AppDelegate.m:167）同一套，
    // 只是那边 `#if !ISH_LINUX` —— Linux 模式下没人做，所以这里补上。
    struct __res_state res;
    memset(&res, 0, sizeof(res));
    if (res_ninit(&res) != 0) return -2;
    NSMutableString *conf = [NSMutableString string];
    union res_sockaddr_union servers[NI_MAXSERV];
    int count = res_getservers(&res, servers, NI_MAXSERV);
    char address[NI_MAXHOST];
    for (int i = 0; i < count; i++) {
        union res_sockaddr_union s = servers[i];
        if (s.sin.sin_len == 0) continue;
        if (getnameinfo((struct sockaddr *)&s.sin, s.sin.sin_len,
                        address, sizeof(address), NULL, 0, NI_NUMERICHOST) != 0)
            continue;
        [conf appendFormat:@"nameserver %s\n", address];
    }
    res_ndestroy(&res);
    // 一条都没读到就退回公共解析器：写个错的总比让客户机完全没 DNS 强。
    if (conf.length == 0) [conf appendString:@"nameserver 1.1.1.1\n"];

    const char *bytes = conf.UTF8String;      // conf 是本函数里的强引用，block 执行时还活着
    unsigned len = (unsigned)strlen(bytes);
    __block int rc = -999;
    sync_do_in_workqueue(^(void (^done)(void)) {
        rc = lumen_write_guest_file("/etc/resolv.conf", bytes, len);
        done();
    });
    os_log_debug(LOG(), "linux: resolv.conf -> guest rc=%d\n%{public}s", rc, bytes);
    return rc;
}

// ── 回调注册 ───────────────────────────────────────────────────────────────

void lumen_linux_set_console_sink(void (*sink)(const char *, unsigned, void *), void *ctx) {
    g_console_sink = sink;
    g_console_ctx = ctx;
    if (g_pending_console.length && sink) {
        NSData *pending = [g_pending_console copy];
        [g_pending_console setLength:0];
        hop(^{ deliver_console(pending); });
    }
}

void lumen_linux_set_session_sink(void (*sink)(const char *, unsigned, void *), void *ctx) {
    g_session_sink = sink;
    g_session_ctx = ctx;
    if (g_pending_session.length && sink) {
        NSData *pending = [g_pending_session copy];
        [g_pending_session setLength:0];
        hop(^{ deliver_session(pending); });
    }
}

void lumen_linux_set_panic_sink(void (*sink)(const char *, void *), void *ctx) {
    g_panic_sink = sink;
    g_panic_ctx = ctx;
}

void lumen_linux_set_session_end_sink(void (*sink)(void *), void *ctx) {
    g_session_end_sink = sink;
    g_session_end_ctx = ctx;
}

// ── 内核要的符号（逐个照上游语义实现）────────────────────────────────────

/// 内核 console 的输出口。上游是 NSLog（会吞掉换行位置、还带前缀），
/// 这里原样转给 Swift（内核自己加 \r），并记一份到 os_log 便于 Console.app 取证。
void ConsoleLog(const char *data, unsigned len) {
    if (data == NULL || len == 0) return;
    // 用 alloc/init 而不是 dataWithBytes：console 输出可能来自内核线程，
    // 那些线程没有 autorelease pool，autoreleased 的临时对象会白留着。
    NSData *chunk = [[NSData alloc] initWithBytes:data length:len];
    hop(^{ deliver_console(chunk); });
}

void ReportPanic(const char *message) {
    os_log_error(LOG(), "kernel panic: %{public}s", message ? message : "(null)");
    void (*sink)(const char *, void *) = g_panic_sink;
    void *ctx = g_panic_ctx;
    NSString *text = message ? [NSString stringWithUTF8String:message] : nil;
    hop(^{ if (sink) sink(text.UTF8String, ctx); });
}

/// 内核里的 `/root` 对应的宿主目录。由 LinuxBoot 在 boot 前设好（set_root）。
const char *DefaultRootPath(void) {
    return g_root_path;
}

/// 上游在这里读 `/ish/version` 决定要不要做文件系统迁移。我们**不做迁移**：
/// 这一版导入的是 iSH 官方 appstore rootfs，一次导入后续复用；迁移属于"以后再说"，
/// 与其半做不如照实留空（harness 用同样的空实现，已经真实 boot 通过）。
void FsInitialize(void) {}

/// 内核线程回到主线程的唯一通道（上游 IOSCalls.m:15）。
/// ⚠️ 派发到**主队列** —— 主线程必须跑 runloop，否则 panic 通知 / pty 输出永远不落地。
void async_do_in_ios(void (^block)(void)) {
    if (block) dispatch_async(dispatch_get_main_queue(), block);
}

/// libiSHLinux.a 里没有这个符号（它上游属于 IOSCalls.m，而那个文件没进那个库），
/// 而 `linux_start_session` 必须在 workqueue 上跑 —— 照上游 IOSCalls.m:31 的语义实现。
void sync_do_in_workqueue(void (^block)(void (^done)(void))) {
    __block pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    __block pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
    __block bool flag = false;
    async_do_in_workqueue(^{
        block(^{
            pthread_mutex_lock(&mutex);
            flag = true;
            pthread_mutex_unlock(&mutex);
            pthread_cond_broadcast(&cond);
        });
    });
    pthread_mutex_lock(&mutex);
    while (!flag)
        pthread_cond_wait(&cond, &mutex);
    pthread_mutex_unlock(&mutex);
}

nsobj_t objc_get(nsobj_t object) { return CFBridgingRetain((__bridge id)object); }
void objc_put(nsobj_t object) { CFBridgingRelease(object); }

// 剪贴板 / NSData 桥：只在 `/dev/clipboard` 被打开时才会用到，照上游 IOSCalls.m:53+ 实现。
long UIPasteboard_changeCount(void) { return UIPasteboard.generalPasteboard.changeCount; }
nsobj_t UIPasteboard_get(void) {
    return (__bridge nsobj_t)[UIPasteboard.generalPasteboard.string dataUsingEncoding:NSUTF8StringEncoding];
}
void UIPasteboard_set(const char *data, size_t len) {
    UIPasteboard.generalPasteboard.string = [[NSString alloc] initWithBytes:data length:len encoding:NSUTF8StringEncoding];
}
size_t NSData_length(nsobj_t data) { return [(__bridge NSData *)data length]; }
const void *NSData_bytes(nsobj_t data) { return [(__bridge NSData *)data bytes]; }

// ── 终端（原始字节 sink；VT100 留给下一步）───────────────────────────────

nsobj_t Terminal_terminalWithType_number(int type, int number) {
    LumenLinuxTerminal *terminal = [LumenLinuxTerminal new];
    terminal.type = type;
    terminal.number = number;
    return CFBridgingRetain(terminal);   // 与上游 Terminal.m:348 一致：交出一份 +1
}

void Terminal_setLinuxTTY(nsobj_t _self, struct linux_tty *tty) {
    LumenLinuxTerminal *terminal = (__bridge LumenLinuxTerminal *)_self;
    terminal.tty = tty;
    // tty 置空 = 内核侧 ios_pty_cleanup（会话结束）。这是唯一可靠的结束信号：
    // 上游 LinuxPTY.c:76 就是这么做的。
    if (tty == NULL) session_ended();
}

int Terminal_sendOutput_length(nsobj_t _self, const char *data, int size) {
    (void)_self;
    if (data == NULL || size <= 0) return 0;
    NSData *chunk = [[NSData alloc] initWithBytes:data length:(NSUInteger)size];
    hop(^{ deliver_session(chunk); });
    return size;   // ⚠️ 必须返回"全部写出"：返回小于 size 会被内核记成 dropped bytes
}

int Terminal_roomForOutput(nsobj_t _self) {
    (void)_self;
    return 1024 * 1024;   // 我们只做缓冲，不背压（返回 0 会让 pty 写侧停住）
}
