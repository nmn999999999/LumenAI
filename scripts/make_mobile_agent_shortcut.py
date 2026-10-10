#!/usr/bin/env python3
"""生成「手机协作」快捷指令（LumenAgent.shortcut）。

背景：本 App 不能合成点击，屏幕识别与交互由「快捷指令主导」的循环完成：
    截屏 → 从图像提取文本(OCR) → 写入共享目录 inbox.txt → 唤起 Lumen 决策
    → Lumen 把「下一步操作」写回 outbox.txt → 本指令读回并展示 → 用户照着点 → 循环

共享目录：文件 App → 我的 iPhone → LumenAI → LumenAgent
（由 App 的 UIFileSharingEnabled 暴露；App Group 对快捷指令不可见，故不用它。）

⚠️ 快捷指令的 `.shortcut` 属性表格式没有公开规范，且需在「快捷指令」App 里导入验证。
本脚本按常见 WFWorkflow 结构生成一个**未签名**的 XML plist；若导入后某个动作缺失或
参数不对，请按 README 的「搭建配方」手搭一次（动作与顺序一致即可），本脚本的价值是
给出字段名与连接关系的起点。

用法：
    python3 scripts/make_mobile_agent_shortcut.py
产物：
    LumenAI/Resources/LumenAgent.shortcut
"""
import os
import plistlib
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "LumenAI", "Resources", "LumenAgent.shortcut")

SHARED_DIR = "LumenAgent"
INBOX = f"{SHARED_DIR}/inbox.txt"
OUTBOX = f"{SHARED_DIR}/outbox.txt"
LOOP_COUNT = 50  # 上限步数，防死循环；用户可随时停止


def u():
    return str(uuid.uuid4()).upper()


def attachment(action_uuid):
    """把某个动作的输出作为输入引用。"""
    return {
        "Value": {"OutputUUID": action_uuid, "OutputName": "", "Type": "ActionOutput"},
        "WFSerializationType": "WFTextTokenAttachment",
    }


def literal_string(text):
    return {"Value": {"string": text}, "WFSerializationType": "WFTextTokenString"}


def action(identifier, params=None):
    return {
        "WFWorkflowActionIdentifier": identifier,
        "WFWorkflowActionParameters": params or {},
    }


def build_actions():
    actions = []

    # Repeat <LOOP_COUNT>
    a_repeat = u()
    actions.append(action("is.workflow.actions.repeat.count", {
        "UUID": a_repeat,
        "WFRepeatCount": LOOP_COUNT,
    }))

    # Take Screenshot
    a_shot = u()
    actions.append(action("is.workflow.actions.takescreenshot", {
        "UUID": a_shot,
    }))

    # Extract Text from Image（输入 = 上一步截图）
    a_ocr = u()
    actions.append(action("is.workflow.actions.gettextfromimage", {
        "UUID": a_ocr,
        "WFInput": attachment(a_shot),
        "WFGetTextFromImageLanguage": "zh-Hans",  # 中文优先；可按需改
    }))

    # Save File → LumenAgent/inbox.txt（供 App 轮询读取）
    a_save = u()
    actions.append(action("is.workflow.actions.documentpicker.save", {
        "UUID": a_save,
        "WFInput": attachment(a_ocr),
        "WFFileDestinationPath": INBOX,
        "WFAskWhereToSave": False,
        "WFFileOverwrite": True,
    }))

    # Open URLs → 通知 App「有新一屏」（App 也会轮询 inbox.txt，这里是双保险）
    a_open = u()
    actions.append(action("is.workflow.actions.openurl", {
        "UUID": a_open,
        "WFInput": literal_string("lumenai://agent?action=step"),
    }))

    # Wait 3s：给 Lumen 决策 + 写回 outbox 的时间
    actions.append(action("is.workflow.actions.wait", {
        "WFDelayTime": 3,
    }))

    # Get File → LumenAgent/outbox.txt（App 写回的下一步指引）
    a_get = u()
    actions.append(action("is.workflow.actions.documentpicker.open", {
        "UUID": a_get,
        "WFFileDestinationPath": OUTBOX,
        "WFGetFileShowPicker": False,
    }))

    # Show Result → 展示指引
    actions.append(action("is.workflow.actions.showresult", {
        "Text": attachment(a_get),
    }))

    # 等待用户操作完成再进入下一轮（用户点「完成」即继续）
    actions.append(action("is.workflow.actions.ask", {
        "WFAskActionPrompt": "照着上面的指引操作，完成后点这里继续。",
        "WFInputType": "Text",
        "WFAskActionDefaultAnswer": "继续",
    }))

    # End Repeat
    actions.append(action("is.workflow.actions.repeat.count.each", {
        "UUID": a_repeat,
    }))

    return actions


def main():
    workflow = {
        "WFWorkflowClientVersion": "1200",
        "WFWorkflowClientRelease": "3.0",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {
            "WFWorkflowIconStartColor": 4282601983,
            "WFWorkflowIconGlyphNumber": 59413,
        },
        "WFWorkflowImportQuestions": [],
        "WFWorkflowTypes": [],
        "WFWorkflowHasShortcutInputVariables": False,
        "WFWorkflowActions": build_actions(),
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        plistlib.dump(workflow, f)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
