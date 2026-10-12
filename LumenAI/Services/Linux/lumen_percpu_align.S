//  强制 __DATA,__percpu_first 落在页边界。
//
//  背景（读代码确认的）：
//  · 上游用 arch/ish/kernel/sections.S 取代链接脚本（"Darwin doesn't do linker
//    scripts"），把 __per_cpu_start/__per_cpu_load 定义成 ld64 的
//    section$start$__DATA$__percpu_first。
//  · 但 sections.S 里那些 section 都是**空的**，对齐只有 section 自然对齐
//    （实测 __percpu_first 在最终二进制里 align=1，地址 …c6b0）。
//  · 内核在 pcpu_setup_first_chunk 的第一组断言里有
//    PCPU_SETUP_BUG_ON(offset_in_page(__per_cpu_start))  →  直接 panic("BUG!")
//    这就是 harness 第一次跑内核时崩掉的原因。
//
//  这里给同一个 section 贡献一段 4096 字节零数据并要求 2^12 对齐：
//  ld64 会取所有输入对象的 max(alignment)，于是整段 section 对齐到页边界，
//  __per_cpu_start 也随之页对齐。
//  代价是 static_size 多 4096（内核自己按符号差值算，不会错位）。
.section __DATA,__percpu_first
.p2align 12
.fill 4096,1,0
