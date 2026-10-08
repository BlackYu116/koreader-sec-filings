#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 SEC 研习室的书籍封面（2:3，1000×1500）。

为什么用代码合成而不是找一张图／用 AI 生图：
  · 每家公司一张、7 家都不一样，代码合成是唯一能让「换了公司名就重来一遍」
    这件事变成一次命令的办法；
  · 只用几何形状 + 文字，不含任何公司标识（logo / 商标），随仓库分发没有版权顾虑；
  · 输出确定性：同样的输入永远得到字节相同的文件，便于校验。

设计意图（不是随手画的）：
  · 深墨蓝底 + 左侧更深的一条书脊，凑近看有层次，缩略图里也能立住；
  · 顶部小字 SEC FILINGS 是品类标识，一眼知道这是申报文件而不是普通书；
  · 公司名用中文大字（用户的书库是中文分类），下方是英文法定名与代码；
  · 底部一组高度不等的竖条是财报的形状，不用文字解释也读得出「这是数字」；
  · 全程只有一种强调色（浅蓝），避免花。

用法:
    python3 make_covers.py <输出目录>
生成 <输出目录>/<cik>.jpg（7 家）与 <输出目录>/generic.jpg（兜底）。
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFont

W, H = 1000, 1500

BG      = (14, 27, 42)
BAND    = (18, 38, 58)
INK     = (246, 249, 252)
MUTED   = (148, 168, 190)
FAINT   = (52, 78, 102)
ACCENT  = (79, 163, 209)

CN_FONT = "/System/Library/Fonts/STHeiti Medium.ttc"
EN_FONT = "/System/Library/Fonts/Helvetica.ttc"

# CIK -> (中文名, 英文法定名, 代码)
COMPANIES = {
    1318605: ("特斯拉", "Tesla, Inc.", "TSLA"),
    1045810: ("英伟达", "NVIDIA CORP", "NVDA"),
    320193:  ("苹果", "Apple Inc.", "AAPL"),
    1018724: ("亚马逊", "Amazon.com, Inc.", "AMZN"),
    1326801: ("Meta", "Meta Platforms, Inc.", "META"),
    1652044: ("谷歌", "Alphabet Inc.", "GOOGL"),
    789019:  ("微软", "Microsoft Corp.", "MSFT"),
}

# 兜底封面：搜到任意一家公司、而它没有专属封面时用这张
GENERIC = ("财报原文", "U.S. SEC Filings", "EDGAR")


def font(path, size, index=0):
    try:
        return ImageFont.truetype(path, size, index=index)
    except Exception:
        return ImageFont.load_default()


def tracked_text(draw, xy, text, f, fill, tracking=8):
    """带字距的文本。PIL 没有 letter-spacing，只能逐字画。"""
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=f, fill=fill)
        x += draw.textlength(ch, font=f) + tracking


def wrap(draw, text, f, max_width):
    words = text.split(" ")
    lines, cur = [], ""
    for w in words:
        trial = (cur + " " + w).strip()
        if draw.textlength(trial, font=f) <= max_width:
            cur = trial
        else:
            if cur:
                lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def make_cover(cn, en, ticker):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    # 左书脊
    d.rectangle([0, 0, 54, H], fill=BAND)
    d.rectangle([54, 0, 57, H], fill=FAINT)

    f_label = font(EN_FONT, 38, index=1)
    f_cn    = font(CN_FONT, 112)
    f_en    = font(EN_FONT, 42)
    f_tk    = font(EN_FONT, 58, index=1)
    f_foot  = font(CN_FONT, 34)

    # 顶部品类标识
    tracked_text(d, (140, 148), "SEC FILINGS", f_label, MUTED, tracking=14)
    d.rectangle([140, 218, 246, 222], fill=ACCENT)

    # 公司名（顶到 1060 之间按名字长度调整起点，避免两行名字压到底部图形）
    cn_y = 540
    d.text((140, cn_y), cn, font=f_cn, fill=INK)

    en_lines = wrap(d, en, f_en, W - 140 - 140)
    en_y = cn_y + 190
    for i, line in enumerate(en_lines):
        d.text((140, en_y + i * 58), line, font=f_en, fill=MUTED)

    tk_y = en_y + len(en_lines) * 58 + 40
    d.text((140, tk_y), ticker, font=f_tk, fill=ACCENT)

    # 底部竖条：高度不等的一组，读作「财报里的数字」
    base_y = 1230
    heights = [70, 140, 100, 210, 165, 250, 120, 190]
    x = 140
    for i, h in enumerate(heights):
        shade = ACCENT if i % 3 == 1 else FAINT
        d.rectangle([x, base_y - h, x + 46, base_y], fill=shade)
        x += 74
    d.rectangle([140, base_y + 26, 140 + 8 * 74 - 28, base_y + 29], fill=FAINT)

    # 页脚
    d.text((140, 1352), "KOReader  ·  SEC 研习室", font=f_foot, fill=MUTED)
    d.text((W - 140 - int(d.textlength("EDGAR", font=f_label)), 1355),
           "EDGAR", font=f_label, fill=FAINT)

    return img


def main(argv):
    out = argv[1] if len(argv) > 1 else "."
    os.makedirs(out, exist_ok=True)

    made = []
    for cik in sorted(COMPANIES):
        cn, en, tk = COMPANIES[cik]
        img = make_cover(cn, en, tk)
        path = os.path.join(out, f"{cik}.jpg")
        img.save(path, "JPEG", quality=88, optimize=True, progressive=True)
        made.append((path, os.path.getsize(path)))

    img = make_cover(*GENERIC)
    path = os.path.join(out, "generic.jpg")
    img.save(path, "JPEG", quality=88, optimize=True, progressive=True)
    made.append((path, os.path.getsize(path)))

    for path, size in made:
        print(f"  {size:>7,} 字节  {os.path.basename(path)}")
    print(f"共 {len(made)} 张，合计 {sum(s for _, s in made):,} 字节")


if __name__ == "__main__":
    main(sys.argv)
