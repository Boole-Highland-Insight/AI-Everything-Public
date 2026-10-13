#!/usr/bin/env python3
"""Generate the text, image, and PDF portions of the 100-instance reuse benchmark."""

from __future__ import annotations

import hashlib
import json
import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import A4
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas


ROOT = Path(__file__).resolve().parent
INSTANCES = ROOT / "instances"
MANIFEST = ROOT / ".build" / "manifest.non-pptx.jsonl"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def entry(
    instance_id: str,
    relative_path: str,
    media_type: str,
    label: str,
    cue: str,
    rationale: str,
    duplicate_group: str | None = None,
) -> dict[str, object]:
    path = ROOT / relative_path
    return {
        "id": instance_id,
        "relative_path": relative_path,
        "media_type": media_type,
        "extension": path.suffix.lower().lstrip("."),
        "label": label,
        "cue": cue,
        "rationale": rationale,
        "duplicate_group": duplicate_group,
        "sha256": sha256(path),
    }


def write_texts() -> list[dict[str, object]]:
    target = INSTANCES / "text"
    target.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, object]] = []

    completion = [
        ("周记_未写完.md", "explicit", "# 周记\n\n周一完成了访谈。周二整理资料。接下来我准备", "结尾在句中中断。"),
        ("季度计划_WIP.md", "explicit", "# 第四季度计划\n\n- 已确定目标\n- 待补：预算、负责人、验收标准", "文件名和正文都明确标记未完成。"),
        ("旅行清单_半成品.txt", "explicit", "证件\n充电器\n保暖衣物\n还需要补充：", "清单明确停在待补充位置。"),
        ("产品说明_未完成.txt", "explicit", "产品用于整理研究资料。主要功能包括搜索、引用和", "正文在并列项中中断。"),
        ("访谈纪要.md", "semantic", "# 访谈纪要\n\n用户最常使用搜索功能。主要问题是结果缺少来源。\n\n## 后续行动\n1. 补充来源展示\n2.", "编号列表存在空白行动项。"),
        ("会议记录.txt", "semantic", "会议确认了发布日期和负责人。风险包括接口延期。最终决定是", "最后一句没有闭合。"),
        ("研究笔记.md", "semantic", "# 假设\n缓存可降低重复计算。\n\n# 实验\n样本分为三组。第一组测试命中率，第二组测试延迟，第三组", "实验设计在第三组处中断。"),
        ("用户故事.txt", "semantic", "作为项目经理，我希望看到每条结论的来源，以便在评审时核对。\n\n验收条件：\n- 显示文件名\n- 显示页码\n-", "验收条件列表有未填写项目。"),
    ]
    optimization = [
        ("搜索方案草稿.md", "explicit", "# 搜索方案草稿\n\n系统先召回候选，再按相关度排序。当前文字重复较多，后续需要压缩。", "内容完整，但作者明确称为草稿。"),
        ("待改写_发布说明.txt", "explicit", "本次更新加入筛选、批量操作和错误恢复。功能已经可用，说明文字需要改得更清楚。", "作者明确要求改写。"),
        ("预算说明草稿.txt", "explicit", "预算包括模型费用、存储费用和测试设备。总额已核对，表达方式仍需整理。", "完整内容带明确草稿意图。"),
        ("活动回顾.md", "semantic", "活动很好，大家都觉得很好。流程总体很好，最后的交流也很好。所有议程均已完成。", "叙述完整但用词重复，适合优化。"),
        ("产品简介.txt", "semantic", "这个产品能搜索文件。它可以搜索很多文件。用户输入内容以后，它会把搜索到的文件显示出来。", "事实完整但表达重复、啰嗦。"),
        ("项目摘要.md", "semantic", "# 项目摘要\n\n团队完成了索引、检索和来源展示。系统当前能够稳定运行。本文档已经覆盖目标、结果和风险，但是段落组织松散。", "信息完整但结构可以打磨。"),
    ]
    normal = [
        ("发布检查清单.md", "# 发布检查清单\n\n- 构建通过\n- 回归测试通过\n- 版本号已更新\n- 回滚方案已确认"),
        ("客户会议纪要.md", "# 客户会议纪要\n\n会议确认 10 月 18 日交付。李明负责接口，王青负责验收。风险与行动项均已记录。"),
        ("报销流程.txt", "员工提交票据后，由直属负责人审批，再由财务复核。每月最后一个工作日完成付款。"),
        ("版本说明.md", "# 1.2.0\n\n新增批量筛选。修复扫描恢复问题。升级后无需迁移用户文件。"),
        ("研究结论.txt", "实验显示缓存将重复查询的中位延迟从 84 毫秒降至 21 毫秒。样本为 500 次本机查询。"),
        ("旅行计划.md", "# 杭州两日计划\n\n第一天游览西湖，第二天前往九溪。住宿、交通和雨天备选方案均已确认。"),
        ("合同要点.txt", "合同期限为一年，付款分三期，验收后支付尾款。双方的数据保密责任持续三年。"),
        ("值班安排.md", "# 值班安排\n\n周一：陈晓\n周二：李敏\n周三：王磊\n紧急联系人：周宁"),
        ("数据字典.md", "# 字段\n\n`user_id`：用户标识。\n`created_at`：创建时间。\n`status`：当前状态。"),
        ("操作手册.txt", "打开应用后选择资料夹。在搜索框输入关键词，点击结果即可预览原文件。设置页显示后台进度。"),
        ("风险登记.md", "# 风险登记\n\n接口延期：中等，负责人陈晓。\n数据缺失：低，负责人李敏。\n模型不可用：低，启用规则回退。"),
        ("年度目标.txt", "年度目标包括提升检索准确率、缩短响应时间和完善恢复机制。每个目标均配置季度指标。"),
    ]

    for index, (name, cue, body, rationale) in enumerate(completion, 1):
        path = target / name
        path.write_text(body, encoding="utf-8")
        rows.append(entry(f"txt-completion-{index:03d}", f"instances/text/{name}", "text", "completion", cue, rationale))
    for index, (name, cue, body, rationale) in enumerate(optimization, 1):
        path = target / name
        path.write_text(body, encoding="utf-8")
        rows.append(entry(f"txt-optimization-{index:03d}", f"instances/text/{name}", "text", "optimization", cue, rationale))
    for index, (name, body) in enumerate(normal, 1):
        path = target / name
        path.write_text(body, encoding="utf-8")
        rows.append(entry(f"txt-none-{index:03d}", f"instances/text/{name}", "text", "none", "semantic", "结构闭合且没有待补内容。"))

    duplicate_payloads = [
        ("项目状态_原件.txt", "项目状态_副本.txt", "dup-text-01", "项目已按计划完成，验收记录和负责人签字均已归档。"),
        ("检索规范_A.md", "检索规范_B.md", "dup-text-02", "# 检索规范\n\n所有事实必须显示来源。排序失败时保留原始召回顺序。"),
    ]
    serial = 1
    for first, second, group, body in duplicate_payloads:
        (target / first).write_text(body, encoding="utf-8")
        shutil.copyfile(target / first, target / second)
        for name in (first, second):
            rows.append(entry(f"txt-duplicate-{serial:03d}", f"instances/text/{name}", "text", "duplicate", "exact_hash", "与同组文件字节完全相同。", group))
            serial += 1
    return rows


def font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    ]
    for candidate in candidates:
        try:
            return ImageFont.truetype(candidate, size)
        except OSError:
            pass
    return ImageFont.load_default()


def draw_image(path: Path, label: str, index: int, explicit: bool = False) -> None:
    image = Image.new("RGB", (900, 600), "#F7F7F4")
    draw = ImageDraw.Draw(image)
    title_font = font(42)
    body_font = font(26)
    if label == "completion":
        draw.arc((160, 170, 520, 500), 190, 345, fill="#2D3748", width=9)
        draw.line((350, 390, 660, 235), fill="#2D3748", width=9)
        if index % 2 == 0:
            draw.line((660, 235, 735, 280), fill="#B8C1CC", width=3)
        text = "未完成速写" if explicit else "山谷构图"
        draw.text((70, 55), text, fill="#344054", font=title_font)
        draw.text((70, 520), "右侧主体与颜色仍为空白", fill="#7A8699", font=body_font)
    elif label == "optimization":
        draw.rounded_rectangle((80, 80, 820, 520), radius=28, fill="#E6ECE8", outline="#A9B5AE", width=3)
        draw.text((130, 145), "设计草稿" if explicit else "春季活动", fill="#7A8B82", font=title_font)
        draw.text((130, 245), "信息完整，但对比度和层级可以优化", fill="#88948D", font=body_font)
        draw.rectangle((130, 340, 470, 410), fill="#C4D0CA")
        draw.text((170, 356), "了解详情", fill="#F7F7F4", font=body_font)
    else:
        draw.ellipse((250, 120, 650, 520), fill="#DCEAF6", outline="#5C7C99", width=6)
        draw.ellipse((335, 245, 395, 305), fill="#243B53")
        draw.ellipse((505, 245, 565, 305), fill="#243B53")
        draw.arc((350, 275, 550, 415), 20, 160, fill="#243B53", width=8)
        draw.text((300, 45), "完整插画", fill="#344054", font=title_font)
    draw.text((790, 540), f"{index:02d}", fill="#667085", font=body_font)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=True)


def write_images() -> list[dict[str, object]]:
    target = INSTANCES / "image"
    target.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, object]] = []
    completion_names = [
        "海报_未完成.png", "角色线稿_WIP.png", "封面_没画完.png",
        "山谷构图.png", "产品插图.png", "流程示意.png", "白板布局.png",
    ]
    for index, name in enumerate(completion_names, 1):
        explicit = index <= 3
        draw_image(target / name, "completion", index, explicit)
        rows.append(entry(f"img-completion-{index:03d}", f"instances/image/{name}", "image", "completion", "explicit" if explicit else "semantic", "主体线稿存在，但画面保留明确未完成区域。"))
    optimization_names = ["活动海报草稿.png", "待优化_产品卡片.png", "封面设计草稿.png", "春季活动.png", "课程宣传.png"]
    for index, name in enumerate(optimization_names, 1):
        explicit = index <= 3
        draw_image(target / name, "optimization", index, explicit)
        rows.append(entry(f"img-optimization-{index:03d}", f"instances/image/{name}", "image", "optimization", "explicit" if explicit else "semantic", "画面信息完整，但视觉层级和对比度需要打磨。"))
    for index in range(1, 12):
        name = f"完整插画_{index:02d}.png"
        draw_image(target / name, "none", index)
        rows.append(entry(f"img-none-{index:03d}", f"instances/image/{name}", "image", "none", "semantic", "构图、主体和配色完整。"))
    first, second = target / "图标原件.png", target / "图标副本.png"
    draw_image(first, "none", 99)
    shutil.copyfile(first, second)
    for index, path in enumerate((first, second), 1):
        rows.append(entry(f"img-duplicate-{index:03d}", f"instances/image/{path.name}", "image", "duplicate", "exact_hash", "与同组图片字节完全相同。", "dup-image-01"))
    return rows


def pdf_lines(label: str, index: int, explicit: bool) -> tuple[str, list[str], str]:
    if label == "completion":
        title = "季度复盘 未完成" if explicit else f"季度复盘 {index}"
        lines = ["目标：复盘本季度交付情况", "已完成：索引、搜索和来源展示", "风险：后台扫描耗时较长", "下一步："]
        rationale = "文档停在空白的下一步部分。"
    elif label == "optimization":
        title = "市场分析草稿" if explicit else f"市场分析 {index}"
        lines = ["市场需求持续增长。", "用户最关心检索准确率与来源。", "当前内容完整，但多个段落重复表达同一结论。"]
        rationale = "结论完整，但结构和措辞需要优化。"
    else:
        title = f"项目报告 {index}"
        lines = ["目标：完成本机文件检索与来源展示。", "结果：核心流程通过测试。", "风险：模型不可用时启用规则回退。", "结论：项目达到本阶段验收标准。"]
        rationale = "目标、结果、风险和结论均完整。"
    return title, lines, rationale


def make_pdf(path: Path, title: str, lines: list[str]) -> None:
    if "AIE-CJK" not in pdfmetrics.getRegisteredFontNames():
        pdfmetrics.registerFont(TTFont("AIE-CJK", "/System/Library/Fonts/STHeiti Medium.ttc", subfontIndex=0))
    doc = canvas.Canvas(str(path), pagesize=A4)
    width, height = A4
    doc.setFillColor(HexColor("#263238"))
    doc.setFont("AIE-CJK", 22)
    doc.drawString(64, height - 78, title)
    doc.setFont("AIE-CJK", 12)
    y = height - 125
    for line in lines:
        doc.drawString(70, y, line)
        y -= 34
    doc.setStrokeColor(HexColor("#C9D2D8"))
    doc.line(64, 62, width - 64, 62)
    doc.setFont("AIE-CJK", 9)
    doc.drawString(64, 44, "咔哒分类评测夹具")
    doc.save()


def write_pdfs() -> list[dict[str, object]]:
    target = INSTANCES / "pdf"
    target.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, object]] = []
    for index in range(1, 6):
        explicit = index <= 2
        name = (f"复盘_未完成_{index}.pdf" if explicit else f"复盘记录_{index}.pdf")
        title, lines, rationale = pdf_lines("completion", index, explicit)
        make_pdf(target / name, title, lines)
        rows.append(entry(f"pdf-completion-{index:03d}", f"instances/pdf/{name}", "pdf", "completion", "explicit" if explicit else "semantic", rationale))
    for index in range(1, 6):
        explicit = index <= 2
        name = (f"市场分析草稿_{index}.pdf" if explicit else f"市场分析_{index}.pdf")
        title, lines, rationale = pdf_lines("optimization", index, explicit)
        make_pdf(target / name, title, lines)
        rows.append(entry(f"pdf-optimization-{index:03d}", f"instances/pdf/{name}", "pdf", "optimization", "explicit" if explicit else "semantic", rationale))
    for index in range(1, 14):
        name = f"完整项目报告_{index:02d}.pdf"
        title, lines, rationale = pdf_lines("none", index, False)
        make_pdf(target / name, title, lines)
        rows.append(entry(f"pdf-none-{index:03d}", f"instances/pdf/{name}", "pdf", "none", "semantic", rationale))
    first, second = target / "验收报告_原件.pdf", target / "验收报告_副本.pdf"
    make_pdf(first, "验收报告", ["范围：搜索与来源展示。", "结果：全部验收项通过。", "结论：同意验收。"])
    shutil.copyfile(first, second)
    for index, path in enumerate((first, second), 1):
        rows.append(entry(f"pdf-duplicate-{index:03d}", f"instances/pdf/{path.name}", "pdf", "duplicate", "exact_hash", "与同组 PDF 字节完全相同。", "dup-pdf-01"))
    return rows


def main() -> None:
    if INSTANCES.exists():
        shutil.rmtree(INSTANCES)
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    rows = write_texts() + write_images() + write_pdfs()
    assert len(rows) == 80, len(rows)
    with MANIFEST.open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    print(f"generated {len(rows)} non-PPTX instances")


if __name__ == "__main__":
    main()
