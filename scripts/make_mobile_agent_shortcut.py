#!/usr/bin/env python3
"""生成「手机协作」快捷指令（LumenAgent.shortcut）—— 云端 API 版 · 无文件。

架构：**独立的 agent 跑在快捷指令里**。
    App 用 `shortcuts://run-shortcut?name=LumenAgent&input=text&text=<configJSON>` 启动它，
    config = {"endpoint","model","apiKey","systemPrompt"}。快捷指令自循环：
        截屏 → 提取文本(OCR) → Get Contents of URL 调云端 LLM → 拿到「下一步做什么」
        → Show Result 展示给你 → 你照着操作 → Ask for Input 继续 → 下一轮
    全程不落任何文件。

⚠️ `.shortcut` 属性表无公开规范，且必须导入「快捷指令」App 验证。本脚本按常见
WFWorkflow 结构生成**已签名**的 XML plist；若导入后某个动作缺失/参数不符，请在
快捷指令 App 里按上面的动作与顺序手动校正（本脚本的价值是给出字段名与连接关系）。

用法：
    python3 scripts/make_mobile_agent_shortcut.py
产物：
    LumenAI/Resources/LumenAgent.shortcut（已签名）
"""
import os
import plistlib
import shutil
import subprocess
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "LumenAI", "Resources", "LumenAgent.shortcut")
LOOP_COUNT = 60  # 上限步数，防死循环


def u():
    return str(uuid.uuid4()).upper()


def text(s):
    return {"Value": {"string": s}, "WFSerializationType": "WFTextTokenString"}


def attach(action_uuid, name=""):
    return {
        "Value": {"OutputUUID": action_uuid, "OutputName": name, "Type": "ActionOutput"},
        "WFSerializationType": "WFTextTokenAttachment",
    }


def shortcut_input():
    """「快捷指令输入」魔法变量（由 run-shortcut 的 input 传入）。"""
    return {
        "Value": {"Type": "ExtensionInput", "OutputName": "Shortcut Input"},
        "WFSerializationType": "WFTextTokenAttachment",
    }


def dict_item(key, value, item_type=0):
    return {"WFItemType": item_type, "WFKey": text(key) if isinstance(key, str) else key,
            "WFValue": value}


def dict_value(items):
    return {"Value": {"WFDictionaryFieldValueItems": items},
            "WFSerializationType": "WFDictionaryFieldValue"}


def array_value(items):
    return {"WFItemType": 2,
            "WFValue": {"Value": items, "WFSerializationType": "WFArrayParameterState"}}


def action(identifier, params=None):
    return {"WFWorkflowActionIdentifier": identifier,
            "WFWorkflowActionParameters": params or {}}


def build_actions():
    a = []

    # 1) 解析配置：Get Dictionary from Input
    a_cfg = u()
    a.append(action("is.workflow.actions.detect.dictionary", {"UUID": a_cfg, "WFInput": shortcut_input()}))

    def get_key(key, source_uuid):
        aid = u()
        a.append(action("is.workflow.actions.getvalueforkey", {
            "UUID": aid,
            "WFGetDictionaryValueType": "Value",
            "WFDictionaryKey": text(key),
            "WFInput": attach(source_uuid),
        }))
        return aid

    a_endpoint = get_key("endpoint", a_cfg)
    a_model = get_key("model", a_cfg)
    a_key = get_key("apiKey", a_cfg)
    a_sys = get_key("systemPrompt", a_cfg)

    # 2) Repeat <LOOP_COUNT>（控制流：start=0 / end=2，同一 identifier）
    a_repeat = u()
    a.append(action("is.workflow.actions.repeat.count", {
        "UUID": a_repeat, "WFControlFlowMode": 0, "WFRepeatCount": LOOP_COUNT,
    }))

    # 2a) Take Screenshot
    a_shot = u()
    a.append(action("is.workflow.actions.takescreenshot", {"UUID": a_shot}))

    # 2b) Extract Text from Image（输入 = 截图）
    a_ocr = u()
    a.append(action("is.workflow.actions.gettextfromimage", {
        "UUID": a_ocr, "WFInput": attach(a_shot), "WFGetTextFromImageLanguage": "zh-Hans",
    }))

    # 2c) Get Contents of URL → 云端 LLM
    # Authorization 需要 "Bearer " + apiKey：用带附件的文本 token 拼接。
    headers = dict_value([
        dict_item("Content-Type", text("application/json")),
        dict_item("Authorization", {
            "Value": {"string": "Bearer ", "attachmentsByRange": {"{0, 0}": {"OutputUUID": a_key, "Type": "ActionOutput"}}},
            "WFSerializationType": "WFTextTokenString",
        }),
    ])
    body = dict_value([
        dict_item("model", attach(a_model)),
        dict_item("messages", array_value([
            {"WFItemType": 3, "WFValue": dict_value([
                dict_item("role", text("system")),
                dict_item("content", attach(a_sys)),
            ])},
            {"WFItemType": 3, "WFValue": dict_value([
                dict_item("role", text("user")),
                dict_item("content", attach(a_ocr)),
            ])},
        ])),
    ])
    a_llm = u()
    a.append(action("is.workflow.actions.downloadurl", {
        "UUID": a_llm,
        "WFURL": attach(a_endpoint),
        "WFHTTPMethod": "POST",
        "WFHTTPHeaders": headers,
        "WFHTTPBodyType": "Json",
        "WFJSONValues": body,
    }))

    # 2d) 从响应里取 choices[0].message.content
    a_choices = u()
    a.append(action("is.workflow.actions.getvalueforkey", {
        "UUID": a_choices, "WFGetDictionaryValueType": "Value",
        "WFDictionaryKey": text("choices"), "WFInput": attach(a_llm),
    }))
    a_first = u()
    a.append(action("is.workflow.actions.getitemfromlist", {
        "UUID": a_first, "WFItemSpecifier": "First Item", "WFInput": attach(a_choices),
    }))
    a_msg = u()
    a.append(action("is.workflow.actions.getvalueforkey", {
        "UUID": a_msg, "WFGetDictionaryValueType": "Value",
        "WFDictionaryKey": text("message"), "WFInput": attach(a_first),
    }))
    a_content = u()
    a.append(action("is.workflow.actions.getvalueforkey", {
        "UUID": a_content, "WFGetDictionaryValueType": "Value",
        "WFDictionaryKey": text("content"), "WFInput": attach(a_msg),
    }))

    # 2e) 展示「下一步做什么」
    a.append(action("is.workflow.actions.showresult", {
        "Text": attach(a_content),
    }))

    # 2f) 等用户操作完成后继续
    a.append(action("is.workflow.actions.ask", {
        "WFAskActionPrompt": "照着上面的指引操作，完成后点这里继续。",
        "WFInputType": "Text",
        "WFAskActionDefaultAnswer": "继续",
    }))

    # 关闭 Repeat
    a.append(action("is.workflow.actions.repeat.count", {
        "UUID": a_repeat, "WFControlFlowMode": 2,
    }))

    return a


def main():
    workflow = {
        "WFWorkflowClientVersion": "1200",
        "WFWorkflowClientRelease": "3.0",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983,
                           "WFWorkflowIconGlyphNumber": 59413},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowTypes": [],
        "WFWorkflowHasShortcutInputVariables": True,
        "WFWorkflowActions": build_actions(),
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)

    # iOS 15+ 拒绝导入未签名的 .shortcut；用 macOS 自带 `shortcuts sign` 签名。
    # ⚠️ 输入扩展名必须是 .shortcut，否则报「格式不正确」。
    unsigned = OUT + ".unsigned.shortcut"
    with open(unsigned, "wb") as f:
        plistlib.dump(workflow, f)

    if shutil.which("shortcuts"):
        try:
            subprocess.run(["shortcuts", "sign", "--mode", "people-who-know-me",
                            "--input", unsigned, "--output", OUT], check=True)
            os.remove(unsigned)
            print(f"signed  {OUT}")
            return
        except subprocess.CalledProcessError as e:
            print(f"⚠️ 签名失败（{e}），退回未签名文件 —— iOS 可能拒绝导入。")
    shutil.move(unsigned, OUT)
    print(f"wrote   {OUT}（未签名）")


if __name__ == "__main__":
    main()
