import Foundation
import SwiftUI

/// 轻量本地化（的中英双语界面）
/// 语言由 设置 → 语言 控制（SettingsStorage.settings.language）
@MainActor
enum L10n {

    static var current: String {
        SettingsStorage.shared.settings.language
    }

    static func t(_ key: String) -> String {
        dict[key]?[current] ?? (current == "en" ? englishFallback(key) : key)
    }

    private static func englishFallback(_ key: String) -> String {
        dict[key]?["en"] ?? key
    }

    // MARK: - 词条表（zh / en）

    private static let dict: [String: [String: String]] = [
        // 服务页
        "服务": ["zh": "服务", "en": "Services"],
        "Provider 管理": ["zh": "Provider 管理", "en": "Providers"],
        "添加 Provider": ["zh": "添加 Provider", "en": "Add Provider"],
        "内置": ["zh": "内置", "en": "Built-in"],
        "未配置密钥": ["zh": "未配置密钥", "en": "No API key"],
        "已配置 N 个密钥": ["zh": "已配置 N 个密钥", "en": "N key(s) set"],
        "编辑": ["zh": "编辑", "en": "Edit"],
        "删除": ["zh": "删除", "en": "Delete"],
        "导出配置": ["zh": "导出配置", "en": "Export"],
        "重置内置": ["zh": "重置内置", "en": "Reset built-ins"],
        "测试连接": ["zh": "测试连接", "en": "Test"],
        "正在测试…": ["zh": "正在测试…", "en": "Testing…"],
        "连接成功": ["zh": "连接成功", "en": "Connected"],
        "连接失败": ["zh": "连接失败", "en": "Failed"],
        "API Key": ["zh": "API Key", "en": "API Key"],
        "名称": ["zh": "名称", "en": "Name"],
        "类型": ["zh": "类型", "en": "Type"],
        "Base URL": ["zh": "Base URL", "en": "Base URL"],
        "模型列表": ["zh": "模型列表", "en": "Models"],
        "模型名（逗号分隔）": ["zh": "模型名（逗号分隔）", "en": "Model names (comma-separated)"],
        "自定义请求头 (JSON)": ["zh": "自定义请求头 (JSON)", "en": "Custom headers (JSON)"],
        "自定义请求体 (JSON)": ["zh": "自定义请求体 (JSON)", "en": "Custom body (JSON)"],
        "多个 Key 用逗号分隔，自动轮换": ["zh": "多个 Key 用逗号分隔，自动轮换", "en": "Separate keys with commas; rotated automatically"],
        "保存": ["zh": "保存", "en": "Save"],
        "取消": ["zh": "取消", "en": "Cancel"],
        "启用": ["zh": "启用", "en": "Enabled"],
        "提供商名称": ["zh": "提供商名称", "en": "Provider name"],

        // 助手
        "自定义助手": ["zh": "自定义助手", "en": "Assistants"],
        "添加助手": ["zh": "添加助手", "en": "Add Assistant"],
        "助手名称": ["zh": "助手名称", "en": "Assistant name"],
        "头像 emoji": ["zh": "头像 emoji", "en": "Avatar emoji"],
        "系统提示词": ["zh": "系统提示词", "en": "System prompt"],
        "绑定 Provider（可选）": ["zh": "绑定 Provider（可选）", "en": "Bind provider (optional)"],
        "绑定模型（可选）": ["zh": "绑定模型（可选）", "en": "Bind model (optional)"],
        "跟随当前选择": ["zh": "跟随当前选择", "en": "Follow current selection"],
        "默认助手": ["zh": "默认助手", "en": "Default"],

        // 备份
        "数据备份": ["zh": "数据备份", "en": "Backup"],
        "导出备份": ["zh": "导出备份", "en": "Export Backup"],
        "恢复备份": ["zh": "恢复备份", "en": "Restore Backup"],
        "导出备份将包含全部会话、Provider 与助手配置": ["zh": "导出备份将包含全部会话、Provider 与助手配置", "en": "Backup includes all conversations, providers and assistants"],
        "恢复将覆盖当前数据，确认继续？": ["zh": "恢复将覆盖当前数据，确认继续？", "en": "Restore will overwrite current data. Continue?"],
        "确认恢复": ["zh": "确认恢复", "en": "Restore"],
        "恢复成功": ["zh": "恢复成功", "en": "Restored"],
        "恢复失败": ["zh": "恢复失败", "en": "Restore failed"],
        "备份文件已生成": ["zh": "备份文件已生成", "en": "Backup file created"],

        // QR
        "配置二维码": ["zh": "配置二维码", "en": "Config QR Code"],
        "扫码导入": ["zh": "扫码导入", "en": "Scan to Import"],
        "从相册选择二维码图片导入 Provider 配置": ["zh": "从相册选择二维码图片导入 Provider 配置", "en": "Pick a QR image from Photos to import provider config"],
        "导入成功": ["zh": "导入成功", "en": "Imported"],
        "未识别到二维码": ["zh": "未识别到二维码", "en": "No QR code found"],
        "分享 Provider 配置": ["zh": "分享 Provider 配置", "en": "Share provider config"],

        // 朗读
        "语音朗读": ["zh": "语音朗读", "en": "Text to Speech"],
        "朗读引擎": ["zh": "朗读引擎", "en": "TTS Engine"],
        "系统 TTS": ["zh": "系统 TTS", "en": "System TTS"],
        "网络 TTS": ["zh": "网络 TTS", "en": "Network TTS"],
        "系统语音": ["zh": "系统语音", "en": "System voice"],
        "网络音色": ["zh": "网络音色", "en": "Voice name"],

        // 聊天
        "选择模型": ["zh": "选择模型", "en": "Select model"],
        "本地模型": ["zh": "本地模型", "en": "Local models"],
        "云端模型": ["zh": "云端模型", "en": "Cloud models"],
        "选择助手": ["zh": "选择助手", "en": "Select assistant"],
        "没有可用模型": ["zh": "没有可用模型", "en": "No models available"],
        "输入消息…": ["zh": "输入消息…", "en": "Type a message…"],
        "搜索消息...": ["zh": "搜索消息...", "en": "Search messages…"],
        "重新生成": ["zh": "重新生成", "en": "Regenerate"],
        "编辑消息": ["zh": "编辑消息", "en": "Edit message"],
        "朗读": ["zh": "朗读", "en": "Speak"],
        "停止朗读": ["zh": "停止朗读", "en": "Stop"],
        "复制": ["zh": "复制", "en": "Copy"],
        "已复制": ["zh": "已复制", "en": "Copied"],
        "删除消息": ["zh": "删除消息", "en": "Delete"],
        "联网搜索": ["zh": "联网搜索", "en": "Web search"],
        "开始对话吧": ["zh": "开始对话吧", "en": "Start chatting"],
        "还没有加载模型": ["zh": "还没有加载模型", "en": "No model loaded"],
        "在下方输入消息，或开启 Agent 模式使用工具": ["zh": "在下方输入消息，或开启 Agent 模式使用工具", "en": "Type below, or enable Agent mode to use tools"],
        "前往「模型」页下载或导入 GGUF 模型": ["zh": "前往「模型」页下载或导入 GGUF 模型", "en": "Download or import a GGUF model on the Models tab"],

        // 设置
        "语言": ["zh": "语言", "en": "Language"],
        "中文": ["zh": "中文", "en": "中文"],
        "English": ["zh": "English", "en": "English"],
        "云端联网搜索": ["zh": "云端联网搜索", "en": "Cloud web search"],
        "发送消息时自动搜索互联网并注入上下文": ["zh": "发送消息时自动搜索互联网并注入上下文", "en": "Auto search the web and inject context when sending"],
        "提示词变量": ["zh": "提示词变量", "en": "Prompt variables"],
        "变量说明": ["zh": "变量说明", "en": "Variables help"],
        "更多功能": ["zh": "更多功能", "en": "More"],
        "关于": ["zh": "关于", "en": "About"],

        // 通用
        "出错了": ["zh": "出错了", "en": "Error"],
        "好的": ["zh": "好的", "en": "OK"],
        "新对话": ["zh": "新对话", "en": "New chat"],

        // 无障碍标签（icon-only 按钮的 VoiceOver 名称）
        "添加图片": ["zh": "添加图片", "en": "Add image"],
        "Agent 模式": ["zh": "Agent 模式", "en": "Agent mode"],
        "语音输入": ["zh": "语音输入", "en": "Voice input"],
        "展开工具": ["zh": "展开工具", "en": "More tools"],
        "收起工具": ["zh": "收起工具", "en": "Close tools"],
        "发送消息": ["zh": "发送消息", "en": "Send message"],
        "停止生成": ["zh": "停止生成", "en": "Stop generating"],
        "对话列表": ["zh": "对话列表", "en": "Conversations"],
        "搜索": ["zh": "搜索", "en": "Search"],
        "新建对话": ["zh": "新建对话", "en": "New conversation"],
        "更多": ["zh": "更多", "en": "More"],

        // 记忆自动提炼
        "对话后自动提炼记忆": ["zh": "对话后自动提炼记忆", "en": "Auto-extract memories after chat"],
        "从最近对话提炼": ["zh": "从最近对话提炼", "en": "Extract from chat"],
        "已提炼": ["zh": "已提炼", "en": "Extracted"],
        "条记忆": ["zh": "条记忆", "en": "memories"],
        "没有新的记忆可提炼": ["zh": "没有新的记忆可提炼", "en": "No new memories to extract"],

        // 云端生图（/draw）
        "生图模型（可选）": ["zh": "生图模型（可选）", "en": "Image model (optional)"],
        "仅 OpenAI/兼容 端点支持文生图。填写后聊天输入框可用 /draw <描述> 生成图片。": [
            "zh": "仅 OpenAI/兼容 端点支持文生图。填写后聊天输入框可用 /draw <描述> 生成图片。",
            "en": "Only OpenAI/Compatible endpoints support image generation. Fill it in to enable /draw <prompt> in chat."
        ],
        "保存到相册": ["zh": "保存到相册", "en": "Save to Photos"],
        "已保存到相册": ["zh": "已保存到相册", "en": "Saved to Photos"],
        "跟随 App 语言": ["zh": "跟随 App 语言", "en": "Follow App language"],
    ]
}

/// 便捷取词
@MainActor
func t(_ key: String) -> String { L10n.t(key) }
