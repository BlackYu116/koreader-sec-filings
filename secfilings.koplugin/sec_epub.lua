--[[
把一个或多个 filing 的 HTML 打包成合规的 EPUB。

用 KOReader 自带的 ffi/archiver（libarchive）写 zip，所以不需要外部命令。
文件结构与 KOReader 自己的 newsdownloader 一致（mimetype 必须是第一个条目
且不压缩），但目录做成「每份 filing 一个 navPoint」，可以直接跳转。

## 图片与封面（波次二新增）

幻灯片类 exhibit（微软 FY27 Segments、Meta 季报附图）的**可见内容全在图片里** ——
SEC 生成工具把那一层文字设成 1pt 纯白。所以 epub 里没有图，这些文件就等于没有内容。
图片由 sec_images.lua 抓下来、落在 book.images_dir 下，由本文件负责写进 zip 并在
OPF 里登记；封面走 OPF 2.0 的经典写法（<meta name="cover" content="cover-image"/>，
不是 OPF 3.0 的 properties="cover-image"）。

三个字段都是**可选**的：book.images / book.images_dir / book.cover 全为空时，
产出与波次一逐字节同构（只是时间戳不同）。

## 关于 ffi/archiver 的三条实测事实（都被真机行为坑过，不要凭直觉改）

1. **`addPath` 成功时也返回 `false`。** 它的收尾是 `return r == ARCHIVE_OK`，
   而遍历正常结束时的 `r` 是 `ARCHIVE_EOF`(=1)、`ARCHIVE_OK`(=0)，永远不相等。
   判成败只能看 `epub.err`（成功时为 nil）。见 FINDINGS「追加六」。
2. **`addPath(entry_root, root, ...)` 的路径映射是纯字符串**
   `entry_root .. "/" .. path:sub(#root + 2)`。所以 `root` 尾部多一个斜杠，
   每个子条目名字的第一个字符就会被吃掉（`nsA/img.jpg` → `sA/img.jpg`）。
   进包的目录一律先剥尾斜杠（`stripTrailingSlashes`）。
3. **zip 压缩方式是写 header 那一刻快照的**，所以可以在两次 `setZipCompression`
   之间切换：mimetype 与图片用 STORED、文本用 DEFLATE。
   图片本身已经是压缩过的 jpg/png，再 deflate 一遍白费 CPU 与电量（实测压缩率≈0）。
]]

local Archiver = require("ffi/archiver")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local ffiutil = require("ffi/util")

local SecEpub = {}

-- 本文件同样不用 `_` 作循环变量（原因见 sec_source.lua 顶部说明）。

local CONTAINER_XML = [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
]]

--- 图片在 content.html 里的 href 前缀，以及同一批文件在 zip 里的前缀。
--- 这两个必须严格对应：content.html 就在 OEBPS/ 下，所以 content.html 里写
--- `images/<ns>/img001.jpg`，zip 里就必须是 `OEBPS/images/<ns>/img001.jpg`。
--- 下面 imagePlan() 会按这条对应关系逐张核对，不一致的条目直接不写进 manifest
--- （宁可少一张图，也不能让 manifest 指向 zip 里不存在的文件 —— 那是读者眼里的破图，
--- 而且没有任何日志会提醒）。
local IMAGE_HREF_ROOT  = "images"
local IMAGE_ENTRY_ROOT = "OEBPS/images"

--- 扩展名 → MIME。只列 SEC 文件里真会出现的几种；调用方通常直接给 mediaType。
local MEDIA_TYPES = {
    jpg = "image/jpeg", jpeg = "image/jpeg", png = "image/png",
    gif = "image/gif", webp = "image/webp", svg = "image/svg+xml",
    bmp = "image/bmp", tif = "image/tiff", tiff = "image/tiff",
}

--- 封面 item 的固定 id；OPF 2.0 的 <meta name="cover"> 按这个名字引用它。
local COVER_ITEM_ID = "cover-image"

local STYLESHEET = [[
/*
 * 原文的表现层样式已被 sec_source.lua:stripPresentation() 摘掉，所以这里刻意
 * 不写 font-family / font-size 的基准值：字体、字号、行距、页边距全部由读者在
 * KOReader 里的设置决定，调一次全局设置所有书一起变。
 *
 * 只补三件丢了就不好读的事：
 *   1) 每份 filing 从新的一页开始（否则七八份文件连排，找不到分界）
 *   2) 表格单元格的左右留白。摘掉 padding-left/right 之后列会贴在一起；
 *      横向对齐没丢，它在 content.html 的内联 style 里（只给表格元素保留）。
 *   3) 小计线。SEC 财报用「1px 实线上边框」表示一行是上方数项的小计，这条线
 *      承担的是语义（哪几个数加起来），不是装饰 —— 都摘掉之后读者分不清
 *      「小计行」和「普通行」，会直接把小计当成又一个明细项。
 *      sec_source.lua:cleanHtml() 在摘样式**之前**认出来并留下 class="secsum"
 *      （它没法用别的办法表达：表现层一摘，线就没了）。两种写法都要有 ——
 *      F2 可能把 class 加在 <tr> 上（-> 由 `.secsum td` 命中），
 *      也可能加在 <td>/<th> 上（-> 由 `td.secsum` 命中）。
 */
h1.secfiling {
    page-break-before: always;
    font-size: 1.35em;
    font-weight: bold;
    line-height: 1.35;
    margin: 1.2em 0 0.3em 0;
}
h2.secfiling-company {
    page-break-before: always;
    font-size: 1.7em;
    font-weight: bold;
    margin: 1.5em 0 0.6em 0;
}
/* 题头信息与说明：略小一号，不与正文抢注意力 */
p.secmeta {
    font-size: 0.85em;
    line-height: 1.45;
    margin: 0.2em 0 0.3em 0;
}
p.secnote {
    font-size: 0.85em;
    line-height: 1.45;
    margin: 0 0 1em 0;
}
div.secbody { margin: 0; }

/* 财务报表靠列对齐才好读，所以单元格必须有左右留白 */
table {
    border-collapse: collapse;
    margin: 0.6em 0;
}
td, th {
    padding: 0.1em 0.5em;
    vertical-align: top;
}
/* 表格字号略小于正文：SEC 财报表格常有 20 多列，略小一号能让每列多容纳
 * 约 15% 的内容。这是唯一一处刻意指定字号的地方 —— 因为表格的宽度需求
 * 和正文完全不同，不能让两者共用同一个字号。 */
td, th {
    font-size: 0.85em;
}

/* 小计线（class 由 sec_source.lua:cleanHtml() 在摘样式前加上）。
 * 灰色而不是纯黑：它是结构提示，不该比数字本身更抢眼。 */
.secsum td, .secsum th { border-top: 1px solid #999999 }
td.secsum, th.secsum { border-top: 1px solid #999999 }

/* <hr> 在 SEC 原文里标记分页/分段。浏览器默认的立体横线在电子书上很老气，
 * 换成一条细线，保留分隔语义但不抢眼。 */
hr {
    border: 0;
    border-top: 1px solid #bbbbbb;
    height: 0;
    margin: 1em 0;
}

img { max-width: 100%; }

/* 图片抓失败时 sec_images.lua 会把 <img> 换成带这个 class 的可见占位
 * （它自己的 failed_marker_class = "secimg-missing"，可配置）。
 * 这里必须给出样式：不加的话它就是一块普通文字，读者不知道
 * 「这里本来有一张图、但是没拿到」而是会以为正文本来就长这样。
 * 白名单因此从 6 个 class 变成 7 个（契约 2 当时漏了这个值）。 */
.secimg-missing {
    border: 1px solid #bbbbbb;
    padding: 0.4em 0.6em;
    margin: 0.6em 0;
    font-size: 0.85em;
    color: #666666;
}
]]

--- xml 转义（只用于我们自己插进去的标题等文本，不动 filing 原文）
local function esc(s)
    if not s then return "" end
    return (tostring(s)
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

--- 剥掉尾斜杠。为什么必须剥：见文件头事实 2 —— addPath 会把子条目名的
--- 第一个字符吃掉，而这一步是静默的（zip 里文件名变了、OPF 里没变，读者看到破图）。
local function stripTrailingSlashes(p)
    while #p > 1 and p:sub(-1) == "/" do
        p = p:sub(1, -2)
    end
    return p
end

--- 把任意字符串收拾成合法的 XML ID（NCName）：不能有空格和冒号，
--- 不能以数字或点/横线开头。
local function safeId(s)
    s = tostring(s):gsub("[^%w_%.%-]+", "-"):gsub("^[%.%-]+", ""):gsub("[%.%-]+$", "")
    if s == "" then return "img" end
    if not s:match("^[%a_]") then s = "n" .. s end
    return s
end

--- 由图片在 zip 内的相对路径推 id：`<ns>/img001.jpg` → `<ns>-img001`。
--- 目录部分进 id 是**必须**的：7 家公司多份 filing 打进同一本书时，
--- 每份都从 img001 开始，不带 namespace 就会撞 id（OPF 直接不合法）。
local function idFromHref(rel)
    local base = rel:match("([^/]+)$") or rel
    base = base:gsub("%.[%w]+$", "")
    local ns = rel:match("^(.-)/[^/]+$")
    if ns and ns ~= "" then
        return ns:gsub("/", "-") .. "-" .. base
    end
    return base
end

--- 递归列出目录下所有文件的**相对路径**。
--- 用途只有一个：报告「images_dir 下有文件没被 manifest 引用但也会被 addPath 打进包」。
--- 因此它是尽力而为的：`lfs.dir` 万一不可用就返回 nil，绝不因此让打包失败。
local function listFilesRel(dir)
    if type(lfs.dir) ~= "function" then return nil end
    local out = {}
    local function walk(prefix)
        local abs = (prefix == "") and dir or (dir .. "/" .. prefix)
        -- lfs.dir 不会 yield，pcall 在这里是安全的；它失败说明目录读不了，
        -- 这只是一条体积提示，不值得中断打包。
        --
        -- **必须同时接住两个返回值**：lfs.dir 返回的是 (迭代器, 目录对象)，
        -- 而通用 for 会把第二个值当迭代器的状态参数传回去。只接第一个的话，
        -- 迭代器收到 nil，直接在真机上报
        --   bad argument #1 to '(for generator)' (directory metatable expected, got nil)
        -- 本机没露出来是因为那个 lfs 是替身（它的 dir 不吃状态参数）。
        local ok, iter, dirtable = pcall(lfs.dir, abs)
        if not ok or iter == nil then return end
        for name in iter, dirtable do
            if name ~= "." and name ~= ".." then
                local rel = (prefix == "") and name or (prefix .. "/" .. name)
                local mode = lfs.attributes(dir .. "/" .. rel, "mode")
                if mode == "directory" then
                    walk(rel)
                elseif mode == "file" then
                    out[#out + 1] = rel
                end
            end
        end
    end
    walk("")
    return out
end

--- 把 book.images / book.cover 整理成「OPF <manifest> 条目 + 要交给 addPath 的目录」。
---
--- 为什么 id 与 href 都在这里重新生成、不用 sec_images 给的 res.manifest 文本：
--- manifest 里的 href 必须与 zip 里文件的实际位置逐字一致，而 zip 里的位置是
--- addPath 按 images_dir 的目录结构铺出来的（纯字符串映射，见文件头事实 2）。
--- 两边分别生成，只要对 namespace 的处理有一点差异（一边补了 "n" 前缀、一边没补），
--- OPF 就会指向一个 zip 里不存在的文件，而且不会有任何报错 —— 正是波次一抓过两次的
--- 那类静默丢数据。所以这里只认 book.images 里的 href / path，manifest 与 zip 位置
--- 由同一份数据推出来。
---
---@param book table 见契约 1
---@return table|nil plan { items = manifest 条目, dir = 进包目录|nil, bytes = 图片总字节 },
---                      string|nil err, table warnings
---
--- 注意这是冒号方法（用 `self:imagePlan(book)` 调）。曾经写成点方法却用冒号调，
--- 于是 book 位置收到的是模块表本身，book.images 读成 nil、静默走「没有图片」
--- 那条分支 —— 一本没图的书也能「成功」写出来，正是本波要防的静默丢数据。
function SecEpub:imagePlan(book)
    local warnings = {}
    local function warn(fmt, ...)
        warnings[#warnings + 1] = string.format(fmt, ...)
    end

    local images = book.images
    local cover  = book.cover
    local has_images = type(images) == "table" and #images > 0

    if not has_images and cover == nil then
        -- 向后兼容：什么都没给 = 这本书没有图片，行为与波次一完全一致
        -- （连 OEBPS/images/ 这个空目录条目都不会出现）。
        return { items = {}, dir = nil, bytes = 0 }, nil, warnings
    end

    local dir = book.images_dir
    if type(dir) ~= "string" or dir == "" then
        return nil, "book.images / book.cover 非空，却没有给 book.images_dir：" ..
            "ffi/archiver 没有 addFileFromFile，图片只能靠 addPath 从磁盘目录进包"
    end
    dir = stripTrailingSlashes(dir)
    if lfs.attributes(dir, "mode") ~= "directory" then
        return nil, "book.images_dir 不是一个目录：" .. dir
    end

    local items, used, expected, bytes = {}, {}, {}, 0

    --- 登记一条图片/封面条目。返回 false 表示这张图没有可用的落盘文件，
    --- 已记警告、且**不会**写进 manifest。
    local function register(kind, href, media_type, wanted_id)
        if type(href) ~= "string" or href == "" then
            warn("%s 没有 href，已跳过", kind)
            return false
        end
        local rel = href:match("^" .. IMAGE_HREF_ROOT .. "/(.+)$")
        if not rel or rel == "" then
            warn("%s 的 href 不以 %s/ 开头，无法确定它在 zip 里的位置，已跳过：%s",
                kind, IMAGE_HREF_ROOT, href)
            return false
        end
        if rel:sub(1, 1) == "/" or rel:find("%.%.") then
            warn("%s 的 href 含绝对路径或越级路径，已跳过：%s", kind, href)
            return false
        end

        -- href 是唯一的落盘依据：addPath 就是按目录结构铺文件的，
        -- 所以「zip 里的位置」= IMAGE_ENTRY_ROOT .. "/" .. rel，
        -- 而「磁盘上的文件」必然是 dir .. "/" .. rel。两边由同一个 rel 决定。
        local disk = dir .. "/" .. rel
        if lfs.attributes(disk, "mode") ~= "file" then
            warn("%s 对应的文件不在磁盘上，已从 manifest 去掉（留着就是读者眼里的破图）：%s",
                kind, disk)
            return false
        end
        expected[rel] = true
        bytes = bytes + (lfs.attributes(disk, "size") or 0)

        local mt = media_type
        if type(mt) ~= "string" or mt == "" then
            local ext = rel:match("%.([%w]+)$")
            mt = (ext and MEDIA_TYPES[ext:lower()]) or "application/octet-stream"
            warn("%s 没有 mediaType，按扩展名推断为 %s：%s", kind, mt, href)
        end

        local id = safeId(wanted_id or idFromHref(rel))
        if used[id] then
            local n = 2
            while used[id .. "-" .. n] do n = n + 1 end
            warn("%s 的 id %q 已被占用，改用 %s（OPF 里 id 重复就不是合法 XML）",
                kind, id, id .. "-" .. n)
            id = id .. "-" .. n
        end
        used[id] = true
        items[#items + 1] = { id = id, href = href, mediaType = mt }
        return true
    end

    -- 封面先登记，这样它的 id 一定是契约要求的 "cover-image"（meta 按名字引用它）。
    local has_cover = false
    if type(cover) == "table" then
        has_cover = register("封面", cover.href, cover.mediaType, COVER_ITEM_ID)
    elseif cover ~= nil then
        warn("book.cover 不是表，已忽略")
    end

    local dropped = 0
    for idx, entry in ipairs(images or {}) do
        if not register(string.format("第 %d 张图", idx),
                        entry.href, entry.mediaType, entry.id) then
            dropped = dropped + 1
        end
    end

    -- addPath 会把 images_dir 下的**所有**文件都塞进 zip，不只是 manifest 登记的那些。
    -- 多余的图不会让书打不开，但会白占体积（图片是 STORED 的，一个字节都省不掉）。
    -- 这里只报告、不删文件：目录归 sec_job / 主会话管，本文件没有权限替它们清理。
    local listed = listFilesRel(dir)
    if listed then
        local extras = {}
        for _i, rel in ipairs(listed) do
            if not expected[rel] then extras[#extras + 1] = rel end
        end
        if #extras > 0 then
            table.sort(extras)
            warn("images_dir 下有 %d 个文件没被任何 manifest 条目引用，但 addPath 仍会把它们打进 zip：%s%s",
                #extras,
                table.concat(extras, ", ", 1, math.min(#extras, 5)),
                #extras > 5 and " …" or "")
        end
    end

    if dropped > 0 then
        warn("共 %d 张图没有可用的落盘文件，已从 manifest 去掉", dropped)
    end

    return {
        items    = items,
        -- 一条都没登记上时不给目录：这样连 OEBPS/images/ 空目录条目都不会出现，
        -- 产出结构与「本来就没有图」完全一样。
        dir      = (#items > 0) and dir or nil,
        bytes    = bytes,
        cover_id = has_cover and COVER_ITEM_ID or nil,
    }, nil, warnings
end

--- 组装 OEBPS/content.html
---@param book table { title=, chapters={ {id=,heading=,meta=,html=}, ... } }
function SecEpub:buildContentHtml(book)
    local parts = {}
    parts[#parts + 1] = [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <title>]] .. esc(book.title) .. [[</title>
  <link rel="stylesheet" type="text/css" href="stylesheet.css"/>
</head>
<body>
]]

    local last_company
    for _ci, ch in ipairs(book.chapters) do
        -- 换公司时插一个二级标题
        if ch.company and ch.company ~= last_company then
            last_company = ch.company
            parts[#parts + 1] = string.format(
                '<h2 class="secfiling-company" id="%s">%s</h2>\n',
                esc(ch.company_id or ("co_" .. ch.id)), esc(ch.company))
        end
        parts[#parts + 1] = string.format(
            '<h1 class="secfiling" id="%s">%s</h1>\n', esc(ch.id), esc(ch.heading))
        if ch.meta and ch.meta ~= "" then
            parts[#parts + 1] = string.format('<p class="secmeta">%s</p>\n', ch.meta)
        end
        if ch.note and ch.note ~= "" then
            parts[#parts + 1] = string.format('<p class="secnote">%s</p>\n', esc(ch.note))
        end
        parts[#parts + 1] = '<div class="secbody">\n'
        parts[#parts + 1] = ch.html or ""
        parts[#parts + 1] = "\n</div>\n"
    end

    parts[#parts + 1] = "</body>\n</html>\n"
    return table.concat(parts)
end

--- 组装 OEBPS/toc.ncx（每份 filing 一个可跳转条目）
function SecEpub:buildTocNcx(book, bookid)
    local parts = {}
    parts[#parts + 1] = string.format([[<?xml version='1.0' encoding='utf-8'?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="%s"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>%s</text></docTitle>
  <navMap>
]], esc(bookid), esc(book.title))

    local n = 0
    for _ci, ch in ipairs(book.chapters) do
        n = n + 1
        parts[#parts + 1] = string.format(
            '<navPoint id="navpoint-%d" playOrder="%d"><navLabel><text>%s</text></navLabel><content src="content.html#%s"/></navPoint>\n',
            n, n, esc(ch.heading), esc(ch.id))
    end

    parts[#parts + 1] = "  </navMap>\n</ncx>\n"
    return table.concat(parts)
end

--- 组装 OEBPS/content.opf
---@param plan table|nil SecEpub.imagePlan 的结果；nil 等价于「没有图片」
function SecEpub:buildContentOpf(book, bookid, plan)
    plan = plan or { items = {} }

    local manifest = {
        '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
        '<item id="content" href="content.html" media-type="application/xhtml+xml"/>',
        '<item id="css" href="stylesheet.css" media-type="text/css"/>',
    }
    for _i, it in ipairs(plan.items) do
        manifest[#manifest + 1] = string.format(
            '<item id="%s" href="%s" media-type="%s"/>',
            esc(it.id), esc(it.href), esc(it.mediaType))
    end

    -- 封面用 OPF 2.0 的经典写法。**不要**写成 OPF 3.0 的 properties="cover-image"：
    -- 本文件 <package version="2.0">，混进 3.0 属性就不是合法 2.0 包了。
    local cover_meta = plan.cover_id
        and string.format('\n    <meta name="cover" content="%s"/>', esc(plan.cover_id))
        or ""

    return string.format([[<?xml version='1.0' encoding='utf-8'?>
<package xmlns="http://www.idpf.org/2007/opf"
         xmlns:dc="http://purl.org/dc/elements/1.1/"
         unique-identifier="bookid" version="2.0">
  <metadata>
    <dc:title>%s</dc:title>
    <dc:identifier id="bookid">%s</dc:identifier>
    <dc:language>%s</dc:language>
    <dc:creator>SEC EDGAR</dc:creator>
    <dc:publisher>KOReader secfilings</dc:publisher>
    <dc:description>%s</dc:description>%s
  </metadata>
  <manifest>
    %s
  </manifest>
  <spine toc="ncx">
    <itemref idref="content"/>
  </spine>
</package>
]], esc(book.title), esc(bookid), esc(book.language or "zh"), esc(book.description or book.title), cover_meta,
    table.concat(manifest, "\n    "))
end

--- 写出 epub。
--- 先写 .tmp，成功后替换 —— 避免 KOReader 正持有原文件时把它写坏。
---@return boolean ok, string|nil err, table|nil warnings
function SecEpub:write(epub_path, book)
    local bookid = book.identifier or ("secfilings_" .. tostring(os.time()))
    book.description = book.description or ""

    local plan, plan_err, warnings = self:imagePlan(book)
    if not plan then
        return false, plan_err
    end
    for _i, w in ipairs(warnings) do
        -- 不静默：这些都说明「书里的图和预期不一样」，出问题时要能从日志里查到原因。
        logger.warn("[sec_epub] " .. w)
    end

    local html = self:buildContentHtml(book)
    local opf  = self:buildContentOpf(book, bookid, plan)
    local ncx  = self:buildTocNcx(book, bookid)

    local tmp = epub_path .. ".tmp"
    os.remove(tmp)

    local epub = Archiver.Writer:new{}
    if not epub:open(tmp, "epub") then
        return false, "无法创建 " .. tmp
    end

    local mtime = os.time()

    -- mimetype 必须是第一个条目，且不压缩
    epub:setZipCompression("store")
    epub:addFileFromMemory("mimetype", "application/epub+zip", mtime)

    -- 图片紧跟在 mimetype 之后写，有两个理由：
    --   1) 图片已经是压缩过的 jpg/png，再 deflate 一次几乎不减小体积，纯浪费
    --      CPU 与电量（图片占整本书体积的绝大部分），所以继续用 STORED。
    --   2) 放在前面，万一图片目录有问题，能在写完几 MB 的 content.html 之前就退出。
    if plan.dir then
        epub:addPath(IMAGE_ENTRY_ROOT, plan.dir, true, mtime)
        -- 返回值的坑见文件头事实 1：**成功时也是 false**，只能看 epub.err。
        -- （曾经写成 `if not wrote then ...`，结果每本带图的书都被判成失败。）
        if epub.err then
            epub:close()
            os.remove(tmp)
            return false, "写入图片失败：" .. tostring(epub.err)
        end
    end

    epub:setZipCompression("deflate")
    epub:addFileFromMemory("META-INF/container.xml", CONTAINER_XML, mtime)
    epub:addFileFromMemory("OEBPS/content.opf", opf, mtime)
    epub:addFileFromMemory("OEBPS/toc.ncx", ncx, mtime)
    epub:addFileFromMemory("OEBPS/stylesheet.css", STYLESHEET, mtime)
    epub:addFileFromMemory("OEBPS/content.html", html, mtime)

    -- 注意：Archiver.Writer:close() **不返回状态值**（总是 nil），所以不能拿它判成败。
    -- 用产出的文件本身验证：大小、以及能不能当 zip 再打开。
    local archive_error = epub.err
    epub:close()
    if archive_error or epub.err then return false, "写入 EPUB 条目失败" end

    local attr = lfs.attributes(tmp)
    if not attr or (attr.size or 0) < 500 then
        os.remove(tmp)
        return false, "写入 zip 失败（产出文件缺失或过小）"
    end

    -- 图片是 STORED 存的，所以 zip 体积必然**大于**图片字节总和（还要装 5 个文本文件）。
    -- 这一步是 addPath 那个「成功也返回 false」的返回值唯一的替代品：
    -- 万一它静默什么都没装（目录权限、路径拼错），zip 会明显偏小，这里能抓住，
    -- 而不是等用户翻到那一页才发现是空白。
    if plan.bytes > 0 and (attr.size or 0) <= plan.bytes then
        os.remove(tmp)
        return false, string.format(
            "图片似乎没有进包：zip 只有 %d 字节，而图片本身合计 %d 字节",
            attr.size, plan.bytes)
    end

    -- 替换旧文件，并清掉它的阅读缓存目录。
    -- 设备上实测（KOReader v2026.07.2 / Paperwhite 5）：边车目录叫
    -- 「<完整文件名>.sdr」，也就是 "xxx.epub.sdr"，而不是 "xxx.sdr"。
    -- 内容换了而边车还在，翻页进度和排版缓存就会指向旧内容。
    -- 两种命名都试一下（旧版本有去掉扩展名的写法），purgeDir 碰到不存在的
    -- 路径只是返回 nil、不会报错。注意必须用 purgeDir：边车是个目录，
    -- os.remove 删不掉。
    os.remove(epub_path)
    ffiutil.purgeDir(epub_path .. ".sdr")
    ffiutil.purgeDir(epub_path:gsub("%.epub$", "") .. ".sdr")
    local ok2, err2 = os.rename(tmp, epub_path)
    if not ok2 then
        -- 跨文件系统等情况，退化为复制
        local fin = io.open(tmp, "rb")
        if not fin then return false, "重命名失败且无法读取临时文件" end
        local data = fin:read("*a")
        fin:close()
        local fout = io.open(epub_path, "wb")
        if not fout then return false, "无法写入 " .. epub_path end
        fout:write(data)
        fout:close()
        os.remove(tmp)
    end

    return true, nil, warnings
end

return SecEpub
