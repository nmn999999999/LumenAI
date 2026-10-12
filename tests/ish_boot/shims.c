//
//  shims.c — iSH「Linux 模式」链接所需的 15 个 app 层符号（自实现版）。
//
//  为什么是这 15 个：libiSHLinux.a / libfakefs.a 把「内核 ↔ iOS 世界」的接口留成了
//  未定义符号（链接探针实测的完整清单），上游的实现在 iSH 的 App 层
//  （app/IOSCalls.m、app/CurrentRoot.m、app/AppDelegate.m、app/Terminal.m…）。
//  但那层同时带着 iSH 自己的 AppDelegate / Roots / AppGroup（AppGroup 会牵出
//  AppGroup entitlement）和 `T _main`，整体 -force_load 会和 LumenAI 的 main 冲突。
//
//  所以这里按**上游语义**自己实现一遍，只保留接口、丢掉 iSH 的 App 依赖。
//  用途有两个，且是同一份代码：
//    1) tests/ish_boot 的 boot 验证 harness —— 在模拟器里真的把内核拉起来；
//    2) 将来 LumenAI 切到 Linux 模式时的链接补齐（那时再接 UI/PTY）。
//
//  上游语义对照（third_party/ish/app/）：
//    async_do_in_ios  = dispatch_async(dispatch_get_main_queue(), …)   [IOSCalls.m:15]
//    ConsoleLog       = NSLog                                          [IOSCalls.m:19]
//    objc_get/objc_put= retain / release                               [IOSCalls.m:23,28]
//    ReportPanic      = 发 KernelPanicNotification                     [AppDelegate.m:64]
//    DefaultRootPath  = <container>/roots/<default>                    [AppDelegate.m:151]
//    FsInitialize     = 读 /ish/version 做迁移（无 rootfs 时是空操作）     [CurrentRoot.m:48]
//

#include "LinuxInterop.h"

#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// ── rootfs 位置 ────────────────────────────────────────────────────────────
// 上游是「App 容器里的 roots/<name>」，harness 里换成显式传入的目录，
// 由 LUMEN_ROOTFS 环境变量或 lumen_set_root() 指定 —— 避免依赖 NSBundle。
static char g_root_path[4096];

/// 内核 console 一共吐了多少字节 —— harness 用它判断「内核真的跑起来了吗」。
/// （`actuate_kernel` 返回只说明过了 initcall；有输出才是活的。）
volatile unsigned long lumen_console_bytes = 0;
/// 收到过 KernelPanic 通知。
volatile int lumen_panicked = 0;

void lumen_set_root(const char *path) {
    snprintf(g_root_path, sizeof(g_root_path), "%s", path);
}

const char *DefaultRootPath(void) {
    return g_root_path;
}

// ── 内核 → 宿主 ────────────────────────────────────────────────────────────

// 内核 console（nslog_console）的输出口。harness 里直接落到 stderr，
// 这样 `simctl spawn` 能实时看到内核 printk。
void ConsoleLog(const char *data, unsigned len) {
    if (data == NULL || len == 0) return;
    lumen_console_bytes += len;
    fwrite(data, 1, len, stderr);
    fflush(stderr);
}

// 内核 panic 通知（LinuxInterop.c 的 panic_report 会经 async_do_in_ios 调它）。
void ReportPanic(const char *message) {
    lumen_panicked = 1;
    fprintf(stderr, "\n[lumen] KERNEL PANIC: %s\n", message ? message : "(null)");
    fflush(stderr);
}

// iSH 在这里做 /ish/version 迁移；harness 不做迁移（rootfs 是一次性导入的）。
void FsInitialize(void) {}

// 内核线程回到「主线程」的唯一通道（上游在 app/IOSCalls.m:15，是 ObjC 文件，
// harness 不编 ObjC，所以这里给等价的纯 C 实现）。
// ⚠️ 它派发到主队列 —— 所以 harness 的主线程必须在跑 runloop，
//    否则 panic 通知/pty 析构会永远留在队列里。
void async_do_in_ios(void (^block)(void)) {
    if (block) dispatch_async(dispatch_get_main_queue(), block);
}

// ARC 下这两个是 retain/release 的占位；harness 用 -fno-objc-arc 的纯 C 对象。
nsobj_t objc_get(nsobj_t object) { return object; }
void objc_put(nsobj_t object) { (void)object; }

// ── 终端 / TTY ─────────────────────────────────────────────────────────────
// boot 阶段内核 console 走 ConsoleLog；只有创建了 tty（/dev/console 或会话）
// 才会碰到这几个。harness 不开交互会话，但输出路径必须给足，
// 否则 `ios_tty_write_room` 返回 0 会让写入侧一直等。

// 会话（PTY）用的状态：内核把 tty 交过来时存住，之后就能往里写命令、收它的输出。
// App 侧（LinuxAppGlue.m）是同一套接口，只是把字节转给了 Swift 而不是 stdout。
volatile int lumen_pty_bytes = 0;
char lumen_pty_text[65536];
volatile int lumen_pty_pid = 0;
volatile int lumen_pty_rc = 1;
nsobj_t lumen_pty_terminal = NULL;

// ⚠️ 每个终端必须是**不同的句柄**：早先这里所有终端都返回同一个静态哨兵，
// 于是 `Terminal_setLinuxTTY` 分不清"这个 tty 是控制台还是会话 pty" —— 最终把控制台的
// tty 当成了会话的，`send_input` 走进 ios_tty_cb_send_input（LinuxTTY.c 的控制台路径），
// 直接 SIGSEGV 在 tty_insert_flip_string（实测 backtrace 见 STATUS.md）。
// App 侧（LinuxAppGlue.m）用的是每个终端一个 ObjC 对象，所以没有这个问题；
// 这里照同样的语义：句柄按 (type,number) 分配，tty 存在句柄上。
struct lumen_terminal_handle {
    int type;
    int number;
    struct linux_tty *tty;
};

static struct lumen_terminal_handle g_handles[64];
static int g_handle_count = 0;

static struct lumen_terminal_handle *handle_for(nsobj_t self) {
    for (int i = 0; i < g_handle_count; i++)
        if ((nsobj_t)&g_handles[i] == self) return &g_handles[i];
    return NULL;
}

/// 拿某个终端（`linux_start_session` 回调里给的 `term`）的 tty；还没挂上时返回 NULL。
struct linux_tty *lumen_tty_for(nsobj_t self) {
    struct lumen_terminal_handle *h = handle_for(self);
    return h ? h->tty : NULL;
}

// 返回一个非 NULL 的不透明句柄：调用方（ios_tty_port_activate）会把它存进
// port->client_data 再传回来，不判空。
nsobj_t Terminal_terminalWithType_number(int type, int number) {
    // 同一个 (type,number) 复用同一个句柄：内核可能对同一个设备多次取终端对象。
    for (int i = 0; i < g_handle_count; i++)
        if (g_handles[i].type == type && g_handles[i].number == number)
            return (nsobj_t)&g_handles[i];
    if (g_handle_count >= (int)(sizeof(g_handles) / sizeof(g_handles[0])))
        return NULL;
    struct lumen_terminal_handle *h = &g_handles[g_handle_count++];
    h->type = type;
    h->number = number;
    h->tty = NULL;
    return (nsobj_t)h;
}

void Terminal_setLinuxTTY(nsobj_t _self, struct linux_tty *tty) {
    struct lumen_terminal_handle *h = handle_for(_self);
    if (h) h->tty = tty;          // NULL = pty 清理（会话结束）
}

// tty 输出：同样落到 stdout，保留原始字节（内核自己会加 \r）。
int Terminal_sendOutput_length(nsobj_t _self, const char *data, int size) {
    (void)_self;
    if (data == NULL || size <= 0) return 0;
    fwrite(data, 1, (size_t)size, stdout);
    fflush(stdout);
    size_t used = (size_t)lumen_pty_bytes;
    if (used < sizeof(lumen_pty_text) - 1) {
        size_t room = sizeof(lumen_pty_text) - 1 - used;
        size_t copy = (size_t)size < room ? (size_t)size : room;
        memcpy(lumen_pty_text + used, data, copy);
        lumen_pty_bytes = (int)(used + copy);
        lumen_pty_text[lumen_pty_bytes] = '\0';
    }
    return size;
}

// 「还能写多少」：给一个足够大的值。返回 0 会让 tty 写入侧永远等下去。
int Terminal_roomForOutput(nsobj_t _self) {
    (void)_self;
    return 1024 * 1024;
}

// ── 会话启动需要的同步原语 ─────────────────────────────────────────────────
// libiSHLinux.a 里没有 sync_do_in_workqueue（上游它在 IOSCalls.m，而那个文件没进库），
// App 侧（LinuxAppGlue.m）和这里各自照上游语义实现一份。
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

// ── 剪贴板 / NSData 桥（只在 pasteboard 设备被打开时才会用到）────────────
nsobj_t UIPasteboard_get(void) { return NULL; }
long UIPasteboard_changeCount(void) { return 0; }
void UIPasteboard_set(const char *data, size_t len) { (void)data; (void)len; }
size_t NSData_length(nsobj_t data) { (void)data; return 0; }
const void *NSData_bytes(nsobj_t data) { (void)data; return NULL; }
