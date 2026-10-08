#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
epub 验收器 —— 对生成的 SEC epub 做结构与排版两类硬检查。

为什么不用「看起来对」判断：这本 epub 里 70% 的坑是**看不见的**——
  · mimetype 没有 STORED 或不是第一条 → 某些阅读器直接不认；
  · OPF 里声明了却不在 zip 里的 item → 封面/图片静默丢失；
  · 内联 style 残留 → 用户在设备上改字体/字号完全没反应（这是最坑的一条，
    因为在 Mac 预览时它长得一样）；
  · class 白名单外的类 → 我们自己的样式表管不到，等于没样式。

判据全部来自波次二冻结契约（INTEGRATION-WAVE2.md）与 sec_epub.lua 的 STYLESHEET。

用法:
    python3 epub_check.py <文件.epub> [更多.epub ...]
退出码: 0 = 全部通过（可以有 warning）；1 = 有 hard failure。
"""

import io
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

# ---------------------------------------------------------------- 判据

MIMETYPE = b"application/epub+zip"

# sec_epub.lua STYLESHEET 里定义过的 class。出现别的值说明有样式漏网的元素。
ALLOWED_CLASSES = {
    "secbody",           # body
    "secfiling",         # h1 每份文件
    "secfiling-company", # h2 公司
    "secmeta",           # p 元信息
    "secnote",           # p 说明
    "secsum",            # 小计线（波次二新增）
    "secimg-missing",    # 图片抓失败的可见占位
                          # （波次一 sec_images.lua 的 failed_marker_class，
                          #   契约 2 当时漏了这个值，是验收器先报出来的）
}

# 允许留在元素上的属性：结构/语义类。其余一律视为表现属性残留。
ALLOWED_ATTRS = {
    "class", "colspan", "rowspan", "href", "id", "src", "alt",
    "xmlns", "xmlns:epub", "epub:type", "name", "content",
    "style",   # 由下面 INLINE_STYLE_ALLOWED 再判断
    "text-align",  # 表格单元格保留的水平对齐（契约允许）
}

# 只允许出现在 <table>/<tr>/<td>/<th>/<col> 上的表现属性
TABLE_ONLY_ATTRS = {"text-align"}

# 允许保留 style="..." 的标签，以及 style 里唯一允许的声明。
# stripPresentation 刻意保留表格的水平对齐（数字列靠右才读得出来），
# 所以 td/th/tr 上的 text-align 是**设计**，不是残留。
STYLE_ALLOWED_TAGS = {"td", "th", "tr", "table", "col", "colgroup"}
STYLE_ALLOWED_DECL = re.compile(
    r"^(?:\s*text-align\s*:\s*(?:left|right|center|justify)\s*;?\s*)+$", re.I)

# <link rel="stylesheet" type="text/css"> 里的 rel/type 是合法结构属性
STRUCT_ATTR_ON = {"link": {"rel", "type"}, "meta": {"rel", "type"}}

CHAPTER_MIN_CHARS = 2048   # 每章正文的字符下限（波次二验收沿用的阈值）

FAIL = []
WARN = []


def fail(msg):
    FAIL.append(msg)


def warn(msg):
    WARN.append(msg)


# ---------------------------------------------------------------- 结构

def check_mimetype(zf, name):
    infos = zf.infolist()
    if not infos:
        fail(f"{name}: zip 是空的")
        return
    first = infos[0]
    if first.filename != "mimetype":
        fail(f"{name}: zip 第一条是 {first.filename!r}，必须是 'mimetype'")
    if first.compress_type != zipfile.ZIP_STORED:
        fail(f"{name}: mimetype 压缩方式是 {first.compress_type}，必须 STORED(=0)")
    if zf.read("mimetype") != MIMETYPE:
        fail(f"{name}: mimetype 内容不是 {MIMETYPE!r}")


def check_xml(zf, path, name):
    try:
        data = zf.read(path)
    except KeyError:
        fail(f"{name}: zip 里没有 {path}")
        return None
    try:
        return ET.fromstring(data)
    except ET.ParseError as e:
        fail(f"{name}: {path} 不是良构 XML: {e}")
        return None


def localname(tag):
    return tag.rsplit("}", 1)[-1]


# 属性残留：<img src="x" /> 这种自闭合、以及引号里带 style 的，都会被下面的正则捞到。
ATTR_RE = re.compile(rb"\s([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(['\"])")
CLASS_RE = re.compile(rb"\sclass\s*=\s*(['\"])(.*?)\1", re.S)
TAG_RE = re.compile(rb"<([a-zA-Z][-a-zA-Z0-9:]*)((?:\s[^<>]*?)?)(/?)>")


def attr_value(attrs, match):
    """从属性文本里取出 match 指示的那条属性的值（用于细看 style 的内容）。"""
    start = match.end()
    if start >= len(attrs):
        return ""
    quote = attrs[start - 1:start]
    end = attrs.find(quote, start)
    if end < 0:
        return ""
    return attrs[start:end].decode("utf-8", "replace")


def check_presentation(zf, path, name):
    """内联表现属性残留是用户最常见的抱怨来源，单独细查。"""
    data = zf.read(path)
    offenders = {}
    for m in TAG_RE.finditer(data):
        tag = m.group(1).decode("ascii", "replace").lower()
        attrs = m.group(2)
        for am in ATTR_RE.finditer(attrs):
            key = am.group(1).decode("ascii", "replace").lower()
            if key in ("class", "colspan", "rowspan", "href", "id", "src", "alt"):
                continue
            # 命名空间声明与 epub 扩展属性不是排版信息，放过
            if key == "xmlns" or key.startswith("xmlns:") or key.startswith("xml:"):
                continue
            if key.startswith("epub:"):
                continue
            if key in TABLE_ONLY_ATTRS and tag in ("td", "th", "tr", "table", "col"):
                continue
            if key in STRUCT_ATTR_ON.get(tag, ()):
                continue
            if key == "style":
                # 只在表格标签上、且只含 text-align 时放过
                if tag in STYLE_ALLOWED_TAGS and STYLE_ALLOWED_DECL.match(
                        attr_value(attrs, am) or ""):
                    continue
                offenders.setdefault("style", 0)
                offenders["style"] += 1
                continue
            offenders.setdefault(key, 0)
            offenders[key] += 1
    return offenders


def check_classes(zf, path, name):
    data = zf.read(path)
    seen = {}
    for m in CLASS_RE.finditer(data):
        for tok in m.group(2).decode("utf-8", "replace").split():
            seen[tok] = seen.get(tok, 0) + 1
    unknown = {k: v for k, v in seen.items() if k not in ALLOWED_CLASSES}
    return seen, unknown


def check_epub(path):
    name = os.path.basename(path)
    size = os.path.getsize(path)
    print(f"\n{'='*72}\n{name}  ({size:,} 字节)\n{'='*72}")
    with zipfile.ZipFile(path) as zf:
        check_mimetype(zf, name)

        # container.xml → OPF
        container = check_xml(zf, "META-INF/container.xml", name)
        opf_path = None
        if container is not None:
            for el in container.iter():
                if localname(el.tag) == "rootfile":
                    opf_path = el.get("full-path")
                    break
        if not opf_path:
            fail(f"{name}: container.xml 里没有 rootfile")
            return
        print(f"  OPF: {opf_path}")

        opf = check_xml(zf, opf_path, name)
        if opf is None:
            return
        base = os.path.dirname(opf_path)

        # manifest 声明的每个 item 都必须在 zip 里
        manifest_ids = {}
        manifest_hrefs = []
        for el in opf.iter():
            if localname(el.tag) == "item":
                iid = el.get("id")
                href = el.get("href")
                mt = el.get("media-type")
                manifest_ids[iid] = (href, mt)
                if not href:
                    fail(f"{name}: OPF item {iid!r} 没有 href")
                    continue
                full = os.path.normpath(os.path.join(base, href)) if base else href
                manifest_hrefs.append((iid, href, full, mt))
                try:
                    info = zf.getinfo(full)
                    if info.file_size == 0:
                        fail(f"{name}: OPF 声明的 {full} 在 zip 里是 0 字节")
                except KeyError:
                    fail(f"{name}: OPF 声明了 {href}，但 zip 里没有 {full}")

        images = [(i, h, f, m) for (i, h, f, m) in manifest_hrefs
                  if (m or "").startswith("image/")]
        print(f"  manifest: {len(manifest_ids)} 项，其中图片 {len(images)} 张")

        # 封面（OPF 2.0 写法：meta name="cover"）
        cover_id = None
        for el in opf.iter():
            if localname(el.tag) == "meta" and (el.get("name") or "") == "cover":
                cover_id = el.get("content")
        if cover_id:
            if cover_id not in manifest_ids:
                fail(f"{name}: meta cover 指向 {cover_id!r}，manifest 里没有这个 id")
            else:
                print(f"  封面: {cover_id} -> {manifest_ids[cover_id][0]}")
        else:
            warn(f"{name}: OPF 里没有 meta name=\"cover\"（睡眠屏用不了封面）")

        # TOC
        spine = [el.get("idref") for el in opf.iter() if localname(el.tag) == "itemref"]
        toc_id = None
        for el in opf.iter():
            if localname(el.tag) == "spine":
                toc_id = el.get("toc")
        if toc_id and toc_id in manifest_ids:
            ncx_href = manifest_ids[toc_id][0]
            ncx_full = os.path.normpath(os.path.join(base, ncx_href)) if base else ncx_href
            ncx = check_xml(zf, ncx_full, name)
            if ncx is not None:
                points = [el for el in ncx.iter() if localname(el.tag) == "navPoint"]
                print(f"  TOC: {len(points)} 个 navPoint")
                # 真正要验的是每个 navPoint 指向的文件存在（一本书只有 1 个 content.html，
                # 章节靠 #锚点区分，所以 navPoint 数≠spine 数是正常的）
                srcs = [el.get("src") for el in ncx.iter()
                        if localname(el.tag) == "content"]
                missing = 0
                for src in srcs:
                    if not src:
                        continue
                    frag = src.split("#", 1)[0]
                    if not frag:
                        continue
                    full = os.path.normpath(os.path.join(
                        os.path.dirname(ncx_full), frag))
                    if full not in zf.namelist():
                        missing += 1
                        fail(f"{name}: TOC 指向的 {frag} 不在 zip 里")
                if srcs and not missing:
                    print(f"      ✓ {len(srcs)} 个 navPoint 目标全部存在")
        else:
            warn(f"{name}: spine 没有 toc 属性")

        # 内容文档
        content_items = [(i, h, f, m) for (i, h, f, m) in manifest_hrefs
                         if (m or "") in ("application/xhtml+xml", "text/html")]
        if not content_items:
            fail(f"{name}: manifest 里没有 XHTML 内容文档")
            return

        all_offenders = {}
        all_unknown = {}
        total_chars = 0
        for (iid, href, full, mt) in content_items:
            if check_xml(zf, full, name) is None:
                continue
            raw = zf.read(full)
            text = raw.decode("utf-8", "replace")
            # 去标签后的可见文字量
            plain = re.sub(r"<[^>]+>", "", text)
            chars = len(re.sub(r"\s+", "", plain))
            total_chars += chars
            if chars < CHAPTER_MIN_CHARS:
                warn(f"{name}: {href} 可见文字只有 {chars} 字（低于 {CHAPTER_MIN_CHARS}）")
            off = check_presentation(zf, full, name)
            for k, v in off.items():
                all_offenders[k] = all_offenders.get(k, 0) + v
            seen, unknown = check_classes(zf, full, name)
            for k, v in unknown.items():
                all_unknown[k] = all_unknown.get(k, 0) + v
            print(f"    {href}: {chars:,} 字, 表格 {text.count('<table')} 张, "
                  f"图片引用 {text.count('<img')} 个")

        if all_offenders:
            fail(f"{name}: 残留表现属性 {all_offenders}  —— 这些会压过读者的字体设置")
        else:
            print("  ✓ 无内联表现属性残留")

        if all_unknown:
            warn(f"{name}: 白名单外的 class {all_unknown} —— 样式表管不到它们")
        else:
            print("  ✓ class 全部在样式表白名单内")

        print(f"  正文合计 {total_chars:,} 字")


def main(argv):
    files = argv[1:]
    if not files:
        print(__doc__)
        return 2
    for p in files:
        if not os.path.exists(p):
            fail(f"文件不存在: {p}")
            continue
        try:
            check_epub(p)
        except zipfile.BadZipFile as e:
            fail(f"{os.path.basename(p)}: 不是合法的 zip: {e}")

    print(f"\n{'='*72}")
    if WARN:
        print(f"警告 {len(WARN)} 条：")
        for w in WARN:
            print("  ! " + w)
    if FAIL:
        print(f"\n✗ 失败 {len(FAIL)} 条：")
        for f_ in FAIL:
            print("  × " + f_)
        print("\n结论：不通过")
        return 1
    print("\n✓ 结论：结构验收通过" + ("（有警告，见上）" if WARN else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
