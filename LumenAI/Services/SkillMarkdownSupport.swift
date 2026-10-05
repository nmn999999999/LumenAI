import Foundation

// MARK: - 通用 SKILL.md 格式支持
//
// SKILL.md 格式是 Claude Code / Agent Skills 使用的标准格式
// 是一种基于 Markdown 的技能定义规范
//
// 标准格式：
// # Skill Name
//
// 技能描述...
//
// ## Usage
// 使用方法...
//
// ## Examples
// 示例...
//
// ## Author
// 作者信息

/// SKILL.md 解析器
struct SkillMarkdownParser {
    
    /// 解析 SKILL.md 文件内容
    static func parse(from markdown: String) -> SkillManifest? {
        let lines = markdown.components(separatedBy: .newlines)
        
        var title: String?
        var description = ""
        var usage = ""
        var examples = ""
        var author: String?
        var category = SkillCategory.productivity
        var tags: [String] = []
        
        var currentSection = ""
        var contentBuffer: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // 标题
            if line.hasPrefix("# ") && title == nil {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            
            // 章节
            if trimmed.hasPrefix("## ") {
                // 保存上一个章节的内容
                saveSectionContent(&description, &usage, &examples, &author, currentSection, contentBuffer)
                contentBuffer.removeAll()
                
                let sectionTitle = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                currentSection = sectionTitle
                continue
            }
            
            // 作者信息特殊处理
            if currentSection.contains("author") || currentSection.contains("作者") {
                if trimmed.hasPrefix("**") && trimmed.contains("**:") {
                    let parts = trimmed.components(separatedBy: ":")
                    if parts.count >= 2 {
                        let key = parts[0].replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
                        let value = parts[1...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
                        if key.lowercased().contains("author") || key.contains("作者") {
                            author = value
                        }
                    }
                }
            }
            
            contentBuffer.append(line)
        }
        
        // 保存最后一个章节
        saveSectionContent(&description, &usage, &examples, &author, currentSection, contentBuffer)
        
        guard let skillTitle = title else { return nil }
        
        // 从 markdown 生成提示词模板
        var promptTemplate = generatePromptTemplate(
            title: skillTitle,
            description: description,
            usage: usage,
            examples: examples
        )
        
        // 自动提取类别和标签
        extractCategoryAndTags(from: markdown, category: &category, tags: &tags)
        
        // 生成 ID
        let id = skillTitle.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        
        return SkillManifest(
            id: id,
            name: skillTitle,
            version: "1.0.0",
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            author: author,
            category: category,
            tags: tags,
            icon: "wand.and.stars",
            promptTemplate: promptTemplate,
            parameters: extractParameters(from: usage),
            isBuiltIn: false,
            isEnabled: true
        )
    }
    
    private static func saveSectionContent(
        _ description: inout String,
        _ usage: inout String,
        _ examples: inout String,
        _ author: inout String?,
        _ section: String,
        _ content: [String]
    ) {
        let text = content.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        
        switch section.lowercased() {
        case "description", "概述", "summary":
            description = text
        case "usage", "使用", "how to use", "用法":
            usage = text
        case "examples", "示例", "example":
            examples = text
        case "author", "作者":
            if author == nil {
                author = text
            }
        default:
            break
        }
    }
    
    private static func generatePromptTemplate(title: String, description: String, usage: String, examples: String) -> String {
        var template = "你是一个专门的 \(title) 专家。"
        
        if !description.isEmpty {
            template += "\n\n任务说明：\n\(description)"
        }
        
        if !usage.isEmpty {
            template += "\n\n使用方法：\n\(usage)"
        }
        
        if !examples.isEmpty {
            template += "\n\n示例参考：\n\(examples)"
        }
        
        template += "\n\n请根据用户的具体需求提供专业帮助。"
        
        return template
    }
    
    private static func extractCategoryAndTags(from markdown: String, category: inout SkillCategory, tags: inout [String]) {
        let lowercased = markdown.lowercased()
        
        // 根据内容关键词自动分类
        if lowercased.contains("code") || lowercased.contains("编程") || lowercased.contains("swift") || lowercased.contains("python") {
            category = .coding
            tags.append("编程")
        } else if lowercased.contains("write") || lowercased.contains("写作") || lowercased.contains("文章") {
            category = .writing
            tags.append("写作")
        } else if lowercased.contains("analysis") || lowercased.contains("分析") || lowercased.contains("数据") {
            category = .analysis
            tags.append("分析")
        } else if lowercased.contains("create") || lowercased.contains("创意") || lowercased.contains("design") {
            category = .creative
            tags.append("创意")
        }
        
        // 提取可能的标签（从标题和内容中）
        let words = lowercased.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let commonWords = ["the", "and", "a", "to", "of", "in", "for", "with", "on", "at", "is", "are"]
        for word in words where word.count > 3 && !commonWords.contains(word) {
            if !tags.contains(word) && tags.count < 5 {
                tags.append(word)
            }
        }
    }
    
    private static func extractParameters(from usage: String) -> [SkillParameter] {
        var parameters: [SkillParameter] = []
        
        // 简单的参数提取：查找常见的参数模式
        // 例如：{{parameter}} 或 **参数名**：描述
        
        let lines = usage.components(separatedBy: .newlines)
        for line in lines {
            // 查找 {{param}} 格式的参数
            let pattern = "\\{\\{([^}]+)\\}\\}"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(location: 0, length: line.utf16.count)
                let matches = regex.matches(in: line, range: range)
                
                for match in matches {
                    if let paramRange = Range(match.range(at: 1), in: line) {
                        let paramName = String(line[paramRange])
                        if !parameters.contains(where: { $0.name == paramName }) {
                            parameters.append(SkillParameter(
                                name: paramName,
                                label: paramName.capitalized,
                                type: .string,
                                description: "自动提取的参数",
                                isRequired: true
                            ))
                        }
                    }
                }
            }
        }
        
        return parameters
    }
    
    /// 将 SkillManifest 导出为 SKILL.md 格式
    static func exportToMarkdown(_ skill: SkillManifest) -> String {
        var markdown = "# \(skill.name)\n\n"
        
        markdown += "## 描述\n"
        markdown += "\(skill.description)\n\n"
        
        if let author = skill.author {
            markdown += "## 作者\n"
            markdown += "**作者**: \(author)\n\n"
        }
        
        markdown += "## 分类\n"
        markdown += "- 分类: \(skill.category.displayName)\n"
        if !skill.tags.isEmpty {
            markdown += "- 标签: \(skill.tags.joined(separator: ", "))\n"
        }
        markdown += "\n"
        
        markdown += "## 使用方法\n\n"
        markdown += "该技能提供以下功能：\n"
        markdown += "- \(skill.description)\n\n"
        
        if !skill.parameters.isEmpty {
            markdown += "### 参数\n\n"
            for param in skill.parameters {
                markdown += "- **\(param.label)** (\(param.name)): \(param.description)"
                if param.isRequired {
                    markdown += " [必填]"
                }
                markdown += "\n"
            }
            markdown += "\n"
        }
        
        markdown += "## 提示词模板\n\n"
        markdown += "```\n\(skill.promptTemplate)\n```\n\n"
        
        markdown += "## 示例\n\n"
        markdown += "用户输入技能相关请求后，AI 将使用上述模板生成专业回复。\n\n"
        
        markdown += "---\n"
        markdown += "*导出自 LumenAI v0.3.77*\n"
        
        return markdown
    }
}

// MARK: - 技能格式转换器

extension SkillStore {
    /// 从 SKILL.md 导入技能
    func importFromMarkdown(_ markdown: String) throws -> SkillManifest {
        guard let manifest = SkillMarkdownParser.parse(from: markdown) else {
            throw NSError(domain: "Skill", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法解析 SKILL.md 文件格式"
            ])
        }
        try save(manifest)
        return manifest
    }
    
    /// 导出技能为 SKILL.md
    func exportToMarkdown(_ skill: InstalledSkill) -> String {
        return SkillMarkdownParser.exportToMarkdown(skill.manifest)
    }
    
    /// 批量导入 SKILL.md 文件（从目录）
    func importFromDirectory(_ directory: URL) throws -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        
        var count = 0
        for file in files where file.pathExtension.lowercased() == "md" {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            try? importFromMarkdown(content)
            count += 1
        }
        
        return count
    }
}
