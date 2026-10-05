# LumenAI Skill System

LumenAI 技能系统支持通用 SKILL.md 格式，可以导入和导出与 Claude Code / Codex 兼容的技能文件。

## 功能特性

### 1. 通用 SKILL.md 支持
- 支持导入标准 SKILL.md 格式文件
- 自动解析标题、描述、参数、示例
- 智能分类和标签提取
- 兼容 Claude Code 生态

### 2. iOS 原生技能系统
- 参数化提示词模板
- 多步工作流支持
- 技能市场和灰度发布
- 使用统计和版本管理

### 3. 双向转换
- SKILL.md ↔ LumenAI Skill 互转
- 在不同 AI 环境间迁移技能
- 保留参数定义和模板

## 使用方法

### 导入 SKILL.md
1. 在 LumenAI App 中打开 服务 → 技能
2. 点击导入按钮
3. 选择 .md 文件
4. 技能自动解析并安装

### 导出 SKILL.md
1. 打开技能详情页
2. 点击导出
3. 选择导出格式 (LumenAI / SKILL.md)
4. 保存到文件

## SKILL.md 格式示例

```markdown
# 技能名称

## 描述
技能描述...

## 作者
**作者**: 作者名

## 使用方法
使用说明...

## 参数
- **参数1**: 说明
- **参数2**: 说明

## 示例
示例内容...
```

## 示例文件

查看 `examples/` 目录中包含的示例 SKILL.md 文件。

## 支持的平台

- ✅ LumenAI iOS App (原生支持)
- ✅ Claude Code (SKILL.md 导入)
- ✅ Codex (SKILL.md 导入)
- ✅ 其他兼容 Markdown 技能的 AI 工具

## 版本

v0.3.77+ - 完整技能系统支持
