# LumenAI ✨

> **玻璃质感的本地 AI 聊天 · 完全离线可用 · 插件化可扩展**
> 原生 SwiftUI + iOS 26 Liquid Glass 打造，GGUF 本地推理 + 多 Provider 云端对话，App 内即可更新功能模块。

[![GitHub release](https://img.shields.io/badge/release-v0.3.86-blue)](https://github.com/nmn999999999/LumenAI/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-green)](#license)
[![Platform](https://img.shields.io/badge/platform-iOS%2026+-black)]()

---

## 🚀 为什么是 LumenAI？

| | |
|---|---|
| 🧊 **液态玻璃 UI** | iOS 26 Liquid Glass 标签栏 / 卡片 / 输入栏，原生 SwiftUI，丝滑流畅 |
| 🔒 **本地推理** | llama.cpp + Metal GPU 加速，模型完全离线，数据不出设备 |
| ☁️ **云端随时切** | OpenAI / Gemini / Claude 多 Provider 流式对话，本地云端一键切换 |
| 🧩 **插件化** | **不换底包更新功能**：JS 插件 + 远程设置界面 + 模块市场，App 内一键装/更/卸 |
| 🤖 **Agent 模式** | 工具调用循环：计算 / 搜索 / 联网 / SSH / 沙盒 Shell / MCP，多轮思考自动执行 |
| 🌐 **多语言** | 中英双语界面，语音输入（ASR）+ 朗读（TTS） |
| 📦 **数据自由** | 备份 / 恢复 / S3 云备份 / QR 分享 / 灰度更新 |

---

## ✨ 功能总览

### 聊天
- 多轮对话 · 流式输出 · 思考块折叠（DeepSeek-R1 / Qwen3）
- Markdown 渲染（代码块 / 表格 / 公式样式）· 消息操作（重生成 / 编辑 / 删除 / 朗读）
- 图片输入（多模态模型）· AI 自动标题 · 全库/会话内搜索

### Agent 智能体
- 30+ 内置工具：计算器 / 时间 / 单位换算 / 进制 / 颜色 / 密码 / JSON / 网页搜索 / **SSH 远程执行** / **沙盒 Shell** / LZ4 / JWT 解码…
- MCP 协议接入外部工具服务器 · JS 插件扩展新工具
- 工具调用前**用户授权**（SSH / 网络 / MCP 默认需批准）

### 终端（Shell）
- 内置终端页：**设置 → 终端 / Linux 模式**，或文件页右上角终端按钮直接进入
- 命令 / 输出 / 退出码 / 当前 cwd 一处可见，支持命令历史上下翻阅、快捷命令、清空与复制输出
- 与 agent 的 `shell` 工具**共用同一个沙盒会话**（cwd / 环境变量 / 历史都是同一份）
- **agent 跑过的 shell 命令也会出现在同一处**（带 `agent` 标记），不用再翻聊天记录才知道它执行了什么
- 命令由内置解释器在 Swift 中执行，路径限定在 `~/Documents/shellbox` —— 这**不是** POSIX shell，
  iOS 没有 `/bin/sh` 可调用
- **真 Linux 会话**（iSH「Linux 模式」：真内核 + Alpine rootfs + pty）：终端页里点
  **下载官方 rootfs → 启动内核 → 开会话**，就能进 `/bin/sh` 敲真命令
  （`apk add` / `grep` / `wget`… 都是真的，不是内置解释器）
- 边界如实说：终端目前按**原始字节**显示（做了 ANSI 清洗），**没有 VT100 屏幕语义** ——
  全屏程序（vim / top）显示会不对；rootfs 约 3 MB，不随包发，要下载或从「文件」导入
- **客户机联网是真的通的**：iSH 的 `golp` 网卡（内核 `CONFIG_GOLP` + `GOLP_AUTOCONFIG`）
  把客户机的 TCP/UDP 直接桥到宿主 socket —— 客户机里 `apk update` 能真拉到索引
  （本机实测 `OK: 21917 distinct packages available`）。缺的一块是 DNS：官方 rootfs 里
  **没有** `/etc/resolv.conf`，所以内核起来后 App 会读宿主当前 DNS（`res_ninit`）写进客户机，
  再开会话（不写的话客户机 musl 会退回 127.0.0.1，表现是"网卡 up 着、域名一个都解析不了"）
- **可以关**：终端页有「关闭 Linux」—— 把客户机里所有用户进程 SIGKILL 掉，会话随之结束。
  如实说明：内核本身**卸不掉**（iSH 没这个接口；客户机里敲 `halt`/`poweroff` 走的是
  `machine_halt()` = `exit(0)`，会把整个 App 一起结束），所以关掉后要重新启动得重启 App
- **内存占用看得见**：开发者诊断里分开报两个数 —— 客户机（Linux 内核视角，固定 256 MB
  里用了多少）与宿主（这个 App 的 `phys_footprint` / `resident`）。两者不是一回事：
  客户机那 256 MB 在宿主上只是保留的地址空间，真吃物理内存的是被触碰过的页

> iSH 有两套引擎：`libish.a`（iSH 自写的系统调用模拟器，**已不用**）与 **Linux 模式**的
> `liblinux.a`（真正的 Linux 内核）+ `libiSHLinux.a`。两套内核不能共存（实测 201 个重复符号），
> 所以现在是**替换**链接：主工程 `-force_load` 的是
> `scripts/build-ish-libs.sh`（`ISH_BUILD_LINUX=1`）合成出来的 `liblumen-linux.a`
> —— 成员顺序 = initcall 顺序（内核必须在 app 层前面，否则挂 devpts 时会 panic）。

### 插件系统（不换包更新功能）
- 模块 = manifest.json + tools.js（JavaScriptCore 纯计算沙箱）
- **远程设置界面**：插件下发的配置卡片直接在设置页渲染，改配置不换包
- 模块市场：字符串 / 天气 / 汇率 / JSON / 颜色 / 随机 / 时间日期工具
- 灰度发布：按设备分桶小比例推送，稳定后全量

### 模型
- GGUF 目录下载（国内镜像）· 自定义 URL / 文件导入 · KV 缓存量化 · Metal 自动加速
- 小模型友好：Agent 模式限云端 / ≥3B 模型，自动适配提示词策略

---

## 📥 安装

1. 从 [Releases](https://github.com/nmn999999999/LumenAI/releases/latest) 下载 `LumenAI-*.ipa`
2. 用 **Sideloadly / AltStore / 全能签** 自签安装（免费 Apple ID 7 天有效）
3. 打开 App → 模型页下载 GGUF 模型 → 开始对话

> 或 [Fork 仓库](https://github.com/nmn999999999/LumenAI/fork) 走 GitHub Actions 云端打包

---

## 🏗️ 架构

```
LumenAI/
├── App/            # 入口 + 液态玻璃 TabView
├── Data/           # 模型 / 消息 / 工具定义 / 插件模型
├── Services/
│   ├── LLMService / LlamaSwiftEngine   # 推理引擎门面（本地 + 云端路由）
│   ├── Plugin/                          # JS 插件引擎 + 远程 UI + 模块市场
│   ├── MCP/                             # streamable HTTP MCP 客户端
│   ├── Cloud/                           # OpenAI / Gemini / Claude SSE 解码
│   └── …                               # ASR / TTS / S3 / 备份 / 搜索 / 更新
├── Views/          # 聊天 / 模型 / 服务 / 设置 / 插件
└── Utilities/      # 液态玻璃组件 / 本地化 / QR
```

**引擎隔离**：所有推理走 `LLMEngine` 协议，本地 GGUF 与云端 API 自动路由，互不干扰。

---

## 🔄 更新方式

- **App 本体**：设置页检查更新（GitHub Release + 灰度索引）
- **功能模块**：服务页 → 模块市场，App 内一键更新（不换包）
- **灰度发布**：`update/index.json` 配置比例，按设备稳定分桶

---

## 🧪 开发

```bash
brew install xcodegen
xcodegen generate   # 生成 LumenAI.xcodeproj
open LumenAI.xcodeproj
```

- 需要 Xcode 26+ / iOS 26 SDK / C++-ObjC 互操作
- 推理依赖 `llama.xcframework` 与 `ssh.xcframework`（由构建脚本产出）

---

## 📄 License

MIT
