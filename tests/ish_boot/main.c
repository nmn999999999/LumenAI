//
//  main.c — LumenAI 的 iSH「Linux 模式」boot 验证 harness。
//
//  目的：在**没有 iOS 真机**的情况下，回答一个此前无法回答的问题 ——
//  「把 Alpine/iSH 的 rootfs 导进 fakefs，再 actuate_kernel，内核到底起不起来」。
//  跑在 iOS 模拟器里（`xcrun simctl spawn`），不进 LumenAI 的 App 包，
//  所以验证不过也不会影响现有能跑的构建。
//
//  用法：
//      ish_boot <rootfs.tar.gz> <root目录> [等待秒数，默认20]
//
//  退出码：
//      0  内核起来了（actuate_kernel 返回 + 没有 panic + 有 console 输出）
//      2  参数不对
//      3  rootfs 导入失败
//      4  内核 panic
//      5  内核没输出（不确定 —— 单独看日志）
//      6  actuate_kernel 没返回（卡在早期启动）
//
//  关键事实（读代码确认，不是猜的）：
//  · actuate_kernel(cmdline) = strcpy(boot_command_line) + run_kernel()   [LinuxInterop.c:30]
//  · run_kernel() = setup_current + start_cpu_thread(start_main) + wait_for_startup()
//                   → **会返回**，返回即表示启动到了 late_initcall(notify_startup)，
//                     而 rootfs_initcall(ish_rootfs) 更早就跑完了。[arch/ish/kernel/setup.c:49]
//  · 内核 console → ConsoleLog（shims.c），panic → ReportPanic（同上）。
//  · async_do_in_ios 派发到主队列 → 主线程必须跑 runloop，否则通知永远不落地。
//

#include "LinuxInterop.h"
#include "tools/fakefs.h"

#include <dispatch/dispatch.h>
#include <execinfo.h>
#include <libgen.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

// 内核/模拟器崩溃时把 C 栈打出来（SIGTRAP/SIGBUS/SIGSEGV 常见于 JIT 或越界）。
// 没有这个的话只能看到 "Trace/BPT trap"，完全不知道在哪。
static void crash_handler(int sig) {
    void *frames[64];
    int n = backtrace(frames, 64);
    fprintf(stderr, "\n[lumen] SIGNAL %d (%s), %d frames:\n", sig, strsignal(sig), n);
    backtrace_symbols_fd(frames, n, STDERR_FILENO);
    fflush(stderr);
    _exit(99);
}

static void install_crash_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = crash_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESETHAND | SA_NODEFER;
    sigaction(SIGTRAP, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
}

void lumen_set_root(const char *path);
extern volatile unsigned long lumen_console_bytes;
extern volatile int lumen_panicked;
// 会话（PTY）探针：见 shims.c。App 侧走的是同一套 tty 回调，只是字节进了 Swift。
struct linux_tty;
struct linux_tty *lumen_tty_for(nsobj_t self);
extern nsobj_t lumen_pty_terminal;
extern volatile int lumen_pty_bytes;
extern char lumen_pty_text[65536];
extern volatile int lumen_pty_pid;
extern volatile int lumen_pty_rc;
extern void sync_do_in_workqueue(void (^block)(void (^done)(void)));
extern void async_do_in_workqueue(void (^block)(void));
extern void linux_start_session(const char *exe, const char *const *argv,
                               const char *const *envp, void (^done)(int, int, nsobj_t));

static const char *kProbe = "echo lumen-pty-ok";
// 联网探针：apk update 走 DNS + TCP + TLS。
// 之所以用 apk 而不是 wget/nc：这个 rootfs 是 appstore 精简版，busybox 里没有 wget/nc，
// 但 apk 一定在。末尾的 echo 是给 harness 的完成标记。
// ⚠️ resolv.conf 现在由**宿主侧**注入（见 inject_resolv_conf）—— 官方 rootfs 里
// 根本没有这个文件，客户机自己没有 DNS 可指。App 走的是同一条路。
static const char *kNetProbe =
    "cat /etc/resolv.conf; cat /proc/net/dev; apk update; echo LUMEN_NET_'DONE'";
static int g_net_probe = 0;
// 关闭探针：起会话 → 敲一条命令拿到回显 → 从宿主侧把客户机用户进程全杀掉 →
// 断言 pty 真的被清理（Terminal_setLinuxTTY(NULL)）。App 的「关闭 Linux」走同一条路。
static int g_shutdown_probe = 0;
static int g_shutdown_state = 0;     // 0=等回显 1=已 kill，等会话结束
static volatile int g_killed = -1;
// 块里不能引用"数组类型的自动变量"，所以这两个放文件作用域。
static const char *kSessionArgv[] = {"sh", "-i", NULL};
static const char *kSessionEnvp[] = {"TERM=xterm-256color", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL};

/// 起一个真会话（/bin/sh），往里敲一条命令，看能不能拿到回显。
///
/// 这是 App 里「终端页」那条路的最小复刻：`linux_start_session` 必须在 iSH 的 workqueue 上跑
/// （上游 TerminalViewController.m:213 也是这么做的），拿到 tty 之后输入走
/// `tty->ops->send_input`、输出走 `Terminal_sendOutput_length`。
///
/// ⚠️ 放在**后台队列**：`sync_do_in_workqueue` 是阻塞等待，而 `linux_start_session` 完成的
/// 回调可能经主队列回来 —— 在主线程上等它就是自己等自己（死锁）。
extern void lumen_meminfo(unsigned long long *, unsigned long long *,
                          unsigned long long *, unsigned long long *);
extern int lumen_net_info(char *name, size_t namelen, int *ifindex, int *up, int *running,
                          unsigned int *ipv4, unsigned long long *rx_bytes,
                          unsigned long long *tx_bytes);
extern int lumen_kill_user_processes(void);
extern int lumen_write_guest_file(const char *path, const char *buf, unsigned len);

// 同一时刻只可能有一次取数在飞，所以这些出参放文件作用域，省得 __block 抓数组。
static char g_net_name[32];
static int g_net_ifindex, g_net_up, g_net_running;
static unsigned int g_net_ipv4;
static unsigned long long g_net_rx, g_net_tx;
static volatile int g_net_found = -2;   // -2=还没跑 -1=没找到 0=找到了

/// 内核侧取一次内存账（必须内核上下文 → 包在 workqueue 里）。
static void print_meminfo(const char *tag) {
    __block unsigned long long total = 0, free_ = 0, shared = 0, buffers = 0;
    async_do_in_workqueue(^{
        lumen_meminfo(&total, &free_, &shared, &buffers);
    });
    for (int i = 0; i < 200 && total == 0; i++) usleep(10 * 1000);
    fprintf(stderr, "[lumen] meminfo(%s): total=%llu MB free=%llu MB shared=%llu MB buffers=%llu MB\n",
            tag, total >> 20, free_ >> 20, shared >> 20, buffers >> 20);
    fflush(stderr);
}

/// 内核侧取一次网卡状态（同样必须内核上下文 → 包在 workqueue 里）。
///
/// 这一条是「桥接联网」的硬判据：golp 这块网卡注册在**内核**里，宿主侧看不到它；
/// 只有内核自己知道它叫什么、ifindex 多少、up 没 up、拿到哪个 IPv4。
static void print_netinfo(const char *tag) {
    g_net_found = -2;
    async_do_in_workqueue(^{
        g_net_found = lumen_net_info(g_net_name, sizeof(g_net_name), &g_net_ifindex,
                                     &g_net_up, &g_net_running, &g_net_ipv4,
                                     &g_net_rx, &g_net_tx);
    });
    for (int i = 0; i < 200 && g_net_found == -2; i++) usleep(10 * 1000);
    if (g_net_found == 0) {
        fprintf(stderr, "[lumen] netinfo(%s): %s ifindex=%d up=%d running=%d "
                        "ipv4=%u.%u.%u.%u rx=%llu tx=%llu\n",
                tag, g_net_name, g_net_ifindex, g_net_up, g_net_running,
                (g_net_ipv4 >> 24) & 0xff, (g_net_ipv4 >> 16) & 0xff,
                (g_net_ipv4 >> 8) & 0xff, g_net_ipv4 & 0xff, g_net_rx, g_net_tx);
    } else {
        fprintf(stderr, "[lumen] netinfo(%s): 没有找到网卡（golp 没注册）\n", tag);
    }
    fflush(stderr);
}

/// 宿主侧往客户机写 /etc/resolv.conf。
///
/// 官方 rootfs 里没有这个文件（实测 tar 里只有 /etc/hosts、/etc/nsswitch.conf），
/// 缺了它 musl 的解析器退回 127.0.0.1，客户机里所有域名解析都会失败。
/// App 走的是同一条路（LinuxAppGlue.m 的 lumen_linux_write_resolv_conf）。
/// 这里故意用 9.9.9.9 + 一行注释标记：`cat /etc/resolv.conf` 里能看到标记，才说明
/// 这份文件**是宿主写的**（而不是上一次跑留下的）；域名能解析则说明整条路真的通。
/// App 那边读的是宿主真实 DNS（res_getservers），不是写死值。
static void inject_resolv_conf(void) {
    static const char *conf = "# lumen-host-injected\nnameserver 9.9.9.9\n";
    __block int rc = -999;
    async_do_in_workqueue(^{
        rc = lumen_write_guest_file("/etc/resolv.conf", conf, (unsigned)strlen(conf));
    });
    for (int i = 0; i < 200 && rc == -999; i++) usleep(10 * 1000);
    fprintf(stderr, "[lumen] resolv.conf 宿主注入: rc=%d\n", rc);
    fflush(stderr);
}

static void start_session_probe(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (g_net_probe) inject_resolv_conf();
        sync_do_in_workqueue(^(void (^done)(void)) {
            linux_start_session("/bin/sh", kSessionArgv, kSessionEnvp, ^(int retval, int pid, nsobj_t term) {
                (void)term;
                lumen_pty_rc = retval;
                lumen_pty_pid = pid;
                lumen_pty_terminal = term;
                done();
            });
        });
        fprintf(stderr, "[lumen] session rc=%d pid=%d\n", (int)lumen_pty_rc, (int)lumen_pty_pid);
        // 只认 `linux_start_session` 回调里给的**那个**终端（= 这个会话的 pty）。
        // 别去猜"最近设置过的 tty"：控制台 tty 也在同一套接口上（踩过，见 shims.c 注释）。
        struct linux_tty *tty = NULL;
        for (int i = 0; i < 200; i++) {
            tty = lumen_tty_for(lumen_pty_terminal);
            if (tty != NULL) break;
            usleep(50 * 1000);                       // 最多等 10s，等 tty 挂上
        }
        if (tty == NULL) {
            fprintf(stderr, "[lumen] session: 没拿到 tty（会话没起来）\n");
            return;
        }
        fprintf(stderr, "[lumen] session: pty tty 已就绪，敲入 %s\n", kProbe);
        print_meminfo("第 1 个会话起来后");
        print_netinfo("第 1 个会话起来后");
        // 堆上的副本：块里不能引用"数组类型的自动变量"。
        char *line = malloc(strlen(kProbe) + 2);
        sprintf(line, "%s\n", kProbe);
        // ⚠️ send_input 必须在**内核上下文**里调：ios_pty_cb_send_input → kernel_write 要用
        // `current`，随便一个宿主线程（GCD worker / App 主线程）都是 NULL → 直接跳 0 崩。
        // 走 workqueue 就是在内核线程上执行（实测：不包这一层必 SIGSEGV 在 kernel_write）。
        // App 侧同理（LinuxAppGlue.m 的 lumen_linux_session_write 也是这么做的）。
        size_t len = strlen(line);
        async_do_in_workqueue(^{
            tty->ops->send_input(tty, line, len);
            free(line);
        });
        if (g_net_probe) {
            size_t nlen = strlen(kNetProbe);
            char *netline = malloc(nlen + 2);
            sprintf(netline, "%s\n", kNetProbe);
            usleep(500 * 1000);
            fprintf(stderr, "[lumen] session: 联网探针 %s\n", kNetProbe);
            // ⚠️ 必须把结尾的 '\n' 也发出去：少这一次 Enter，shell 会一直等在提示符上
            //（实测：漏了它整条命令都不执行，pty 上只能看到回显）。
            size_t nsend = strlen(netline);
            async_do_in_workqueue(^{
                tty->ops->send_input(tty, netline, nsend);
                free(netline);
            });
        }
    });
}

static struct timeval g_boot_start;

static double since_boot(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (tv.tv_sec - g_boot_start.tv_sec) + (tv.tv_usec - g_boot_start.tv_usec) / 1e6;
}

static void result(const char *code, int status, const char *why, double secs) {
    fprintf(stderr, "[lumen] RESULT %s (exit=%d, %.1fs, console=%lu bytes, panic=%d): %s\n",
            code, status, secs, lumen_console_bytes, lumen_panicked, why);
    fflush(stderr);
    exit(status);
}

static int file_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

int main(int argc, char **argv) {
    const char *tarball = argc > 1 ? argv[1] : getenv("LUMEN_ROOTFS_TARBALL");
    const char *root = argc > 2 ? argv[2] : getenv("LUMEN_ROOTFS");
    int wait_seconds = argc > 3 ? atoi(argv[3]) : 20;

    if (tarball == NULL || root == NULL) {
        fprintf(stderr, "usage: %s <rootfs.tar.gz> <root目录> [等待秒数]\n", argv[0]);
        return 2;
    }
    if (wait_seconds <= 0) wait_seconds = 20;

    install_crash_handlers();
    lumen_set_root(root);
    g_net_probe = getenv("LUMEN_NET_PROBE") != NULL;
    g_shutdown_probe = getenv("LUMEN_SHUTDOWN_PROBE") != NULL;
    setvbuf(stderr, NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IONBF, 0);

    // ── 1) rootfs：没有就导一次（fakefs = data/ + meta.db）──────────────
    // 上游语义见 tools/fakefs.c:80 —— mkdir(fs) → mkdir(fs/data) → 建 meta.db → 解 tar。
    char db_path[4096];
    snprintf(db_path, sizeof(db_path), "%s/meta.db", root);
    if (!file_exists(db_path)) {
        fprintf(stderr, "[lumen] importing rootfs: %s -> %s\n", tarball, root);
        struct fakefsify_error err;
        memset(&err, 0, sizeof(err));
        struct progress p = {0};
        if (!fakefs_import(tarball, root, &err, p)) {
            fprintf(stderr, "[lumen] fakefs_import FAILED (line=%d type=%d code=%d): %s\n",
                    err.line, err.type, err.code, err.message ? err.message : "?");
            free(err.message);
            return 3;
        }
        free(err.message);
        fprintf(stderr, "[lumen] rootfs imported\n");
    } else {
        fprintf(stderr, "[lumen] rootfs already present: %s\n", root);
    }

    // ── 2) 启动内核 ────────────────────────────────────────────────────
    gettimeofday(&g_boot_start, NULL);
    // maxcpus=0：只起 CPU0。
    // arch/ish/kernel/smp.c 的 start_secondary 会给每个 secondary CPU 起宿主线程，
    // 实测第 2 个 CPU 一进 cpu_startup_entry→do_idle 就 SIGSEGV（iSH 是单 CPU 模拟器，
    // 上游这条路径根本没跑过）。smp.c:1063 的 maxcpus= 是内核自己的早期参数，
    // ish 的 setup_arch 会 parse_early_param()，所以命令行就能关掉，不用重编内核。
    // 注：CONFIG_NR_CPUS 在 arch/ish/Kconfig 里是 `range 2 32`，改成 1 会被拒。
    fprintf(stderr, "[lumen] actuate_kernel(\"maxcpus=0\") …\n");
    actuate_kernel("maxcpus=0");
    double boot_secs = since_boot();
    fprintf(stderr, "[lumen] actuate_kernel returned in %.2fs (console=%lu bytes)\n",
            boot_secs, lumen_console_bytes);

    // actuate_kernel 返回 = 已经过了 late_initcall(notify_startup)，
    // 其中 rootfs_initcall(ish_rootfs) 早就跑完（成功 or 已经 pr_emerg 过）。
    if (lumen_panicked) result("EARLY_PANIC", 4, "内核在启动阶段就 panic 了", boot_secs);

    // ── 2.5) 会话探针：起 /bin/sh 并敲一条命令（App 的终端页走的就是这条链路）──
    start_session_probe();

    // ── 3) 让它跑一会儿：内核线程 + 主队列（async_do_in_ios）──────────
    // dispatch_main() 不返回，所以用主队列上的定时器收口。
    // 这段时间里 userspace init 会往 console 写，panic 也会经主队列回来。
    struct timeval t_boot;
    gettimeofday(&t_boot, NULL);
    __block int ticks_left = wait_seconds * 10; // 每 100ms 一次

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              100 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        if (lumen_panicked) {
            dispatch_source_cancel(timer);
            result("PANIC", 4, "运行期收到内核 panic", since_boot());
        }
        if (g_shutdown_probe) {
            // ① 先等会话真跑起来（拿到回显），再动手杀。
            if (g_shutdown_state == 0) {
                if (strstr(lumen_pty_text, "lumen-pty-ok") != NULL) {
                    g_shutdown_state = 1;
                    fprintf(stderr, "[lumen] shutdown: 会话已回显，开始杀客户机用户进程\n");
                    async_do_in_workqueue(^{
                        g_killed = lumen_kill_user_processes();
                    });
                    fflush(stderr);
                }
            } else if (g_killed >= 0 && lumen_tty_for(lumen_pty_terminal) == NULL) {
                // ② 杀完等 pty 被清理：内核侧 ios_pty_cleanup → Terminal_setLinuxTTY(NULL)。
                dispatch_source_cancel(timer);
                char why[160];
                snprintf(why, sizeof(why),
                         "杀掉 %d 个客户机用户进程后 pty 被清理（会话确实结束了）", g_killed);
                result("SHUTDOWN_OK", 0, why, since_boot());
            }
        } else if (g_net_probe && strstr(lumen_pty_text, "LUMEN_NET_DONE") != NULL) {
            dispatch_source_cancel(timer);
            // 注意：tty 会把**输入**也回显出来，所以标记串不能原样出现在命令里
            // （探针里写的是 LUMEN_NET_'DONE'，拼起来才是 LUMEN_NET_DONE）。
            int ok = strstr(lumen_pty_text, "distinct packages available") != NULL
                     || strstr(lumen_pty_text, "\nOK:") != NULL;
            result(ok ? "NET_OK" : "NET_FAIL", ok ? 0 : 7,
                   ok ? "客户机内的 apk update 成功（DNS+TCP+TLS 都通）"
                      : "apk update 没拿到包索引（看上面 pty 输出里的报错）",
                   since_boot());
        }
        if (!g_net_probe && !g_shutdown_probe && lumen_pty_bytes > 0 &&
            strstr(lumen_pty_text, "lumen-pty-ok") != NULL) {
            dispatch_source_cancel(timer);
            result("PTY_OK", 0, "内核起来了，而且真会话能跑命令拿到回显", since_boot());
        }
        if (--ticks_left <= 0) {
            dispatch_source_cancel(timer);
            if (g_shutdown_probe) {
                char why[160];
                snprintf(why, sizeof(why), "关闭没走完（state=%d killed=%d tty=%p）",
                         g_shutdown_state, g_killed, lumen_tty_for(lumen_pty_terminal));
                result("SHUTDOWN_FAIL", 8, why, since_boot());
            }
            if (lumen_console_bytes > 0)
                result("BOOTED", 0, "内核启动且有 console 输出（会话探针没拿到回显）", since_boot());
            result("NO_OUTPUT", 5, "内核线程活着但没有任何 console 输出", since_boot());
        }
    });
    dispatch_resume(timer);
    dispatch_main();
    return 0;
}
