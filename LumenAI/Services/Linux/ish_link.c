#include "ish_link.h"

/* Linux 模式的两个入口：
   · run_kernel —— 真正的 Linux 内核入口（liblinux.a，arch/ish/kernel/setup.c:49）。
     这里只取地址、不调用：判据是「内核确实在这个二进制里」，也就是可断言。
   · asbestos_new —— 用户态模拟器（libish_emu.a）。只链了内核而落掉它的话，
     liblinux 的 _asbestos_* 未定义符号会直接链接失败；取地址是第二道保险。 */
extern void run_kernel(void);
extern void *asbestos_new(void *mmu);

uintptr_t lumen_linux_kernel_entry(void) {
    return (uintptr_t)&run_kernel;
}

uintptr_t lumen_linux_emu_marker(void) {
    return (uintptr_t)&asbestos_new;
}
