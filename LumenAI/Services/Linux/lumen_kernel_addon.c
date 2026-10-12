//
//  lumen_kernel_addon.c — 内核侧补丁 + 给 App 的取数接口（编进 App，不只是 harness）。
//
//  ── 一、两个「上游缺口」补丁 ──────────────────────────────────────────────
//  这两个洞不是我们引入的 bug，是上游 Linux 模式本身还没填的：
//  在真机上点「启动 Linux」时会直接 panic，所以必须随 App 一起带上。
//
//  ① /root 目录：上游 ish_rootfs()（app/LinuxRoot.c）直接
//        do_mount(fakefs_path, "/root", "fakefs", MS_SILENT, NULL);
//     但此刻 rootfs 还是空 ramfs（CONFIG_BLK_DEV_INITRD=n，没有 initramfs 去造目录），
//     VFS 查不到 "/root" → do_mount 返回 -ENOENT → 后面 devtmpfs/proc 全被跳过。
//     → 这里用 pure_initcall（level 0，比 rootfs_initcall 的 level 6 早得多）先把目录建出来。
//
//  ② __percpu_first 的页对齐在 lumen_percpu_align.S 里（见该文件，那是链接期问题）。
//
//  ── 二、给 App 的取数接口（都在内核上下文里跑，不走 App 线程）──────────
//  为什么必须在内核侧取：客户机内存的占用只有内核自己知道（哪些页被分配/空闲），
//  宿主侧只看得见自己进程的 footprint —— 两者不是一回事，面板上要分开报。
//
// 先 fs/file：init_syscalls.h 里那三个 `struct file/kstat/timespec64` 的前向声明
// 要能看见完整类型，否则刷三条 -Wvisibility 警告（无害，但没必要留着）。
#include <linux/errno.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/file.h>
#include <linux/namei.h>
#include <linux/fcntl.h>
#include <linux/init_syscalls.h>
#include <linux/printk.h>
#include <linux/mm.h>            /* si_meminfo() 在这里声明 */
#include <linux/sysinfo.h>
#include <linux/sched.h>
#include <linux/sched/signal.h>  /* for_each_process / kill_pid / SIGKILL */
#include <linux/pid.h>
#include <linux/netdevice.h>
#include <linux/inetdevice.h>    /* in_dev_get / in_ifaddr（网卡上的 IPv4） */
#include <linux/if_link.h>
#include <net/net_namespace.h>

static __init int lumen_mkroot(void) {
    int err = init_mkdir("/root", 0755);
    if (err < 0)
        pr_err("lumen: mkdir /root failed: %d\n", err);
    else
        pr_info("lumen: created /root for the fakefs mount\n");
    return 0;
}
pure_initcall(lumen_mkroot);

/// 读一次客户机的内存账（total / free / shared / buffers，单位字节）。
///
/// 客户机 RAM 是**固定 256 MB**：`arch/ish/kernel/setup.c` 里
/// `ish_phys_size = 0x10000000`，再用 `host_mmap` 映射到宿主 `0x200000000`。
/// 那个映射只是保留地址空间，真正吃掉宿主物理内存的是**被触碰过的页** ——
/// 所以面板里"客户机已用"和"宿主 footprint"要分别显示，别混成一个数。
///
/// ⚠️ 必须在**内核上下文**里调（走 workqueue）；App 线程直接调没有 `current`。
void lumen_meminfo(unsigned long long *total, unsigned long long *free_,
                   unsigned long long *shared, unsigned long long *buffers) {
    struct sysinfo si;
    si_meminfo(&si);
    unsigned long long unit = si.mem_unit ? si.mem_unit : 1;
    if (total)   *total   = (unsigned long long)si.totalram * unit;
    if (free_)   *free_   = (unsigned long long)si.freeram  * unit;
    if (shared)  *shared  = (unsigned long long)si.sharedram * unit;
    if (buffers) *buffers = (unsigned long long)si.bufferram * unit;
}

/// 把客户机的**网卡**状态读出来（目前就是 golp）。
///
/// 为什么这一条要内核来答：网卡是 `arch/ish/net/golp.c` 注册进内核的
/// （CONFIG_GOLP + CONFIG_GOLP_AUTOCONFIG，见 arch/ish/Kconfig），
/// 它在宿主机上**没有**对应物 —— App 侧只能看到自己的 socket，看不到
/// "客户机里有没有一块 up 着的网卡、拿到什么地址"。这正是「桥接联网」是否
/// 真的接上了的判据。
///
/// 返回：0 = 找到名字匹配的网卡（其余出参已填）；-1 = 没有。
/// `ipv4` 用主机字节序存 ifa_local（golp 固定是 10.0.0.1，取自 autoconfig.c）。
int lumen_net_info(char *name, size_t namelen, int *ifindex, int *up, int *running,
                   unsigned int *ipv4, unsigned long long *rx_bytes,
                   unsigned long long *tx_bytes) {
    struct net_device *dev;
    int found = -1;

    rtnl_lock();
    for_each_netdev(&init_net, dev) {
        if (strcmp(dev->name, "golp") != 0)
            continue;
        if (name && namelen)
            strlcpy(name, dev->name, namelen);
        if (ifindex)  *ifindex  = dev->ifindex;
        if (up)       *up       = !!(dev->flags & IFF_UP);
        if (running)  *running  = !!(dev->flags & IFF_RUNNING);
        if (ipv4) {
            unsigned int addr = 0;
            struct in_device *in_dev = in_dev_get(dev);
            if (in_dev) {
                struct in_ifaddr *ifa;
                in_dev_for_each_ifa_rtnl(ifa, in_dev)
                    addr = ntohl(ifa->ifa_local);
                in_dev_put(in_dev);
            }
            *ipv4 = addr;
        }
        if (rx_bytes || tx_bytes) {
            struct rtnl_link_stats64 temp;
            const struct rtnl_link_stats64 *stats = dev_get_stats(dev, &temp);
            if (rx_bytes) *rx_bytes = stats ? stats->rx_bytes : 0;
            if (tx_bytes) *tx_bytes = stats ? stats->tx_bytes : 0;
        }
        found = 0;
        break;
    }
    rtnl_unlock();
    return found;
}

/// 把客户机里**所有用户进程** SIGKILL 掉（pid > 1 且 mm != 0），返回被杀的个数。
///
/// 用来实现 App 上的「关闭 Linux」：iSH 没有卸载内核 / 停机的接口，而且
/// `arch/ish/kernel/reboot.c` 的 machine_halt() 就是 `exit(0)` —— 走内核那条路
/// 会把**整个 App 一起杀掉**，所以只能从宿主侧按进程收。
///
/// 两条刻意的不作为：
///  · **不碰 pid 1**：SIGKILL 对内层 init 本来就被忽略；而更糟的是它若真被"终止"，
///    busybox init 会走 shutdown 序列 → machine_power_off → exit(0) → App 一起没。
///  · **不碰 mm == 0 的内核线程**：那是模拟器自己的线程，杀了内核就哑了。
int lumen_kill_user_processes(void) {
    int pids[128];
    int n = 0, killed = 0;
    struct task_struct *p;

    rcu_read_lock();
    for_each_process(p) {
        if (p->pid <= 1 || p->mm == NULL)
            continue;
        if (n < (int)ARRAY_SIZE(pids))
            pids[n++] = p->pid;
    }
    rcu_read_unlock();

    for (int i = 0; i < n; i++) {
        struct pid *pid = find_get_pid(pids[i]);
        if (pid == NULL)
            continue;
        if (kill_pid(pid, SIGKILL, 1) == 0)
            killed++;
        put_pid(pid);
    }
    return killed;
}

/// 往客户机里写一个文件（不存在就创建）。给 App 注入 /etc/resolv.conf 用。
///
/// 为什么必须由宿主写：iSH 官方 rootfs 里**根本没有** `/etc/resolv.conf`
/// （实测 tarball 里只有 /etc/hosts、/etc/nsswitch.conf）。缺了它客户机的 musl 解析器
/// 会退回 127.0.0.1 —— 而客户机的 127.0.0.1 上什么都没有，表现就是
/// "网卡 up 着、地址也有、但所有域名都解析不了"（apk / wget 全挂在 DNS 上）。
///
/// 为什么不用上游 LinuxInterop.c 里现成的 linux_write_file：那是
/// `filp_open(path, O_WRONLY, 0)`，**不带 O_CREAT**，对着一个不存在的文件必然 -ENOENT。
///
/// ⚠️ 必须在**内核上下文**里调（filp_open 要 current）。返回 0 = 写成功。
int lumen_write_guest_file(const char *path, const char *buf, unsigned len) {
    struct file *filp = filp_open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (IS_ERR(filp))
        return (int)PTR_ERR(filp);
    loff_t pos = 0;
    ssize_t n = kernel_write(filp, buf, len, &pos);
    filp_close(filp, NULL);
    if (n < 0)
        return (int)n;
    return n == (ssize_t)len ? 0 : -EIO;
}
