#!/usr/bin/env python3
"""生成「采集」快捷指令（LumenCapture.shortcut）—— 方案 B。

快捷指令只有两个动作：**截屏 → 从图像中提取文本**，输出即屏幕文字。
App 通过官方 x-callback-url 把它跑起来：
    shortcuts://x-callback-url/run-shortcut?name=LumenCapture&x-success=lumenai://agent
跑完，快捷指令的文本输出会作为 `result` 追加到 x-success，即回调
    lumenai://agent?result=<OCR 文本>
App 收到后再调云端 LLM 决定「下一步做什么」。全程不落文件、快捷指令里没有 HTTP/JSON。

⚠️ `.shortcut` 属性表无公开规范。本脚本生成**已签名**文件；若导入后动作缺失，
请在快捷指令 App 里手搭这两个动作即可（截屏 / 从图像中提取文本），一分钟搞定。

用法：
    python3 scripts/make_capture_shortcut.py
产物：
    LumenAI/Resources/LumenCapture.shortcut（已签名）
"""
import os
import plistlib
import shutil
import subprocess
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "LumenAI", "Resources", "LumenCapture.shortcut")


def u():
    return str(uuid.uuid4()).upper()


def attach(action_uuid):
    return {
        "Value": {"OutputUUID": action_uuid, "OutputName": "", "Type": "ActionOutput"},
        "WFSerializationType": "WFTextTokenAttachment",
    }


def action(identifier, params=None):
    return {"WFWorkflowActionIdentifier": identifier, "WFWorkflowActionParameters": params or {}}


def build_actions():
    a = []
    a_shot = u()
    a.append(action("is.workflow.actions.takescreenshot", {"UUID": a_shot}))
    a_ocr = u()
    a.append(action("is.workflow.actions.gettextfromimage", {
        "UUID": a_ocr,
        "WFInput": attach(a_shot),
        "WFGetTextFromImageLanguage": "zh-Hans",
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
        "WFWorkflowHasShortcutInputVariables": False,
        "WFWorkflowActions": build_actions(),
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
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
            print(f"⚠️ 签名失败（{e}），退回未签名文件。")
    shutil.move(unsigned, OUT)
    print(f"wrote   {OUT}（未签名）")


if __name__ == "__main__":
    main()
