--[[
把 SEC 文件里的图片抓下来并嵌进 EPUB。

## 为什么需要这个模块

幻灯片类的 exhibit（微软 FY27 Segments deck、特斯拉季度 update）的**可见内容全在图片里**，
HTML 里那一层文字被 SEC 的生成工具刻意设成「1pt、纯白、行高 0」的隐藏替代文本。
`sec_source.lua:unhideTextStyles()` 已经能让那层文字显出来，但图片不补上，
用户拿到的仍然是一份「有数字、没有图」的东西 —— 分部营收表能读，图看不了。

## 这个模块的边界（很重要）

- **纯逻辑**：不 require 任何 `ui/*`、不碰 `Device`/`Trapper`/`UIManager`，
  所以可以在 Mac 上用 luajit 无头跑通。UI 与进度由调用方通过 `opts.on_progress` 挂进来。
- **不做 zip**：只把图片写到 `opts.dir` 下的一个目录里，并给出条目清单 + OPF manifest 片段。
  打包由 `sec_epub.lua` 负责（它用的是 `ffi/archiver`）。
- **不改已有文件**：本模块是新增件，接线由主会话做。

## 三条硬约束（违反会真机崩溃，逐条说明为什么）

1. **不用 pcall 包住可能 yield 的代码。**
   KOReader 的 `Trapper:info()` 内部 `coroutine.yield()`，LuaJIT 禁止跨 pcall 边界 yield。
   本模块里唯一用到 pcall 的地方是「解码 / 缩放 / 重新编码」这一段纯 C 调用
   （`ffi/pic` 与 `ffi/jpeg` 在失败时用 `error()` 抛错，不 pcall 就会打断整轮）。
   进度回调 `opts.on_progress` **永远在 pcall 之外**调用 —— 它就是要能 yield 的。
2. **错误一律靠返回值传**，不用 `error()` 往上抛。单张图失败只跳过它，
   正文照常生成（要求原文：失败不能影响正文）。
3. **图片边下边写盘**，绝不整批留在内存里。
   微软 10-K 单份解析峰值已经 115MB，再堆几十 MB 图片就是拿设备内存赌博。
   实现方式：`ltn12.sink.file(io.open(path,"wb"))`，LuaSocket 把每个 TCP 分片直接写进文件。

## 关于内存还做了两件事

- 降采样（可选、默认开）一次只解码**一张**图，用完立刻 `:free()`，不批量持有。
- 解码时按设备能力给 `ffi/pic` 设色彩模式；本模块默认保持彩色解码（见 downscaleFile 的注释）。

## 对外 API（调用方只需要看这一节）

    local SecImages = require("sec_images")

    local res, err = SecImages:run(cleaned_html, base_url, {
        user_agent = "Proma Kindle Agent xxx@example.com",  -- 必填，SEC 不带邮箱一律 403
        dir        = work_dir,        -- 必填，图片写到 work_dir/images[/namespace]/
        namespace  = "msft_8k_20260902",  -- 多份 filing 打进同一个 epub 时**必须**给唯一值
        on_progress = function(done, total, name) end,  -- 可以 yield（在 pcall 之外调用）
    })
    -- res.html     重写后的 HTML（<img src> 指向 epub 内部相对路径，alt 保留）
    -- res.entries  可进 zip 的图片清单：{ {id, href, arcname, path, mediaType, bytes, ...}, ... }
    -- res.failed   抓失败的：{ {id, src, alt, err}, ... }（HTML 里已换成可见的 alt 文字）
    -- res.manifest 直接拼进 OPF <manifest> 的片段
    -- res.stats    计数与字节统计（含耗时、单张最大值、总字节）
    -- res.log      人类可读的说明行（可直接写进章节说明 / 日志）

接线三步（主会话要做的）：
  1) `res.manifest` 插进 `sec_epub.lua:buildContentOpf` 的 `<manifest>` 里（用 `book.manifest_extra`）。
  2) `epub:addPath("OEBPS/images", work_dir .. "/images", true, mtime)` —— `ffi/archiver` 没有
     `addFileFromFile`，只有 `addPath`（它按块流式读写、不整份读进内存），所以图片落盘目录
     直接喂给它。`recursive=true` 才能覆盖 `images/<namespace>/` 这种子目录。
  3) 章节说明那句「本份原文含 N 张图片」要改掉 —— 现在图片真的进来了。

## 用法最小示例（可复跑，见 work/images_e2e.lua）

    local res = SecImages:run(html, base_url, { user_agent = UA, dir = "/tmp/w" })
    print(res.stats.ok, res.stats.bytes, res.stats.total_ms)
]]

local SecImages = {}

-- 本文件在所有循环里都不使用 `_` 作循环变量。
-- 插件顶部普遍有 `local _ = require("gettext")`，一旦某个循环写成
-- `for _, x in ipairs(...)`，循环体内再调 `_()` 就会变成「调用一个数字」。
-- （实测报错过：attempt to call local '_' (a number value)。）

SecImages.version = "1.0.0"

SecImages.defaults = {
    -- 降采样目标宽度。1236 是 Paperwhite 5 的物理屏宽，正文栏约 1198px；
    -- 取 1200 的意思是「按 1:1 显示时不损失任何东西」，再多的像素只是白占体积和
    -- 解码内存 —— EPUB 里的行内图片在 KOReader 里没有放大查看的入口（不像封面那样
    -- 能进 ImageViewer），所以超出屏幕宽度的分辨率根本用不上。
    max_width = 1200,
    jpeg_quality = 85,
    attempts = 3,
    timeout = 120,          -- 秒。LuaSocket 默认 60，慢网下不一定够
    throttle_ms = 120,      -- 每张图之间的间隔。SEC 的公平访问上限约 10 请求/秒，
                            -- 图片小、回得快，不节流的话 22 张几秒内就能突到上限
    warn_total_bytes = 20 * 1024 * 1024,
    image_dir = "images",
    failed_marker_class = "secimg-missing",
}

--------------------------------------------------------------------------
-- 计时：优先 socket.gettime（挂钟），否则退到 os.clock（CPU 时间）
--------------------------------------------------------------------------
-- 为什么要做成可覆盖的公开函数：os.clock 量的是 CPU 时间，对「等网络」的耗时
-- 是没有意义的。无头测试里注入一个真实的挂钟实现，才不会得出错误结论。
local _socket_mod -- lazy
local function socketModule()
    if _socket_mod == nil then
        local ok, m = pcall(require, "socket")
        _socket_mod = (ok and m) or false
    end
    return _socket_mod or nil
end

SecImages.now_source = "unknown"
function SecImages.now()
    local s = socketModule()
    if s and s.gettime then
        SecImages.now_source = "socket.gettime"
        return s.gettime()
    end
    SecImages.now_source = "os.clock"
    return os.clock()
end

--------------------------------------------------------------------------
-- 文件工具（不依赖 lfs / ffiutil，保证无头可跑）
--------------------------------------------------------------------------

--- 文件字节数。用 seek 到末尾拿位置，不需要真的读进内存。
---@return number|nil
local function fileSize(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local sz = f:seek("end")
    f:close()
    return sz
end
SecImages.fileSize = fileSize

--- 读文件开头若干字节（用于魔数嗅探）
local function readHead(path, n)
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read(n)
    f:close()
    return head
end

--- 建目录（含逐级创建）。
--- 为什么用 lazy require：本模块要在没有 KOReader 库的机器上也能被 require，
--- 这样 URL 解析 / HTML 重写 / OPF 生成这些纯逻辑才能无头单测。
local function ensureDir(dir)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if not ok_lfs or not lfs or not lfs.attributes then
        -- 没有 lfs（只可能发生在脱离 KOReader 的环境里：设备上 libs/libkoreader-lfs
        -- 一定在）。此时不直接失败 —— 目录可能已经由调用方建好了，用一个探针
        -- 试写一下就知道能不能用。这样本模块在没有 lfs 的机器上也能完整跑通。
        local probe = dir .. "/.secimg-probe"
        local f = io.open(probe, "wb")
        if not f then return nil, "no-lfs 且目录不可写" end
        f:close()
        os.remove(probe)
        return true
    end
    if dir == "" or dir == "/" then return true end
    local acc = dir:sub(1, 1) == "/" and "" or nil
    for seg in dir:gmatch("[^/]+") do
        if acc == nil then acc = seg else acc = acc .. "/" .. seg end
        local a = lfs.attributes(acc)
        if not (a and a.mode == "directory") then
            lfs.mkdir(acc)
            a = lfs.attributes(acc)
            if not (a and a.mode == "directory") then
                return nil, "mkdir failed: " .. acc
            end
        end
    end
    return true
end
SecImages.ensureDir = ensureDir

--------------------------------------------------------------------------
-- URL 解析：自己实现，不 require socket.url
--------------------------------------------------------------------------
-- 为什么不复用 LuaSocket 的 url 模块：
--   1) 它是设备上的库，本机（Mac）没有装 LuaSocket，一 require 就没法无头测试；
--   2) 我们只需要「把 src 拼成绝对 URL」这一件事，自己写一遍反而能覆盖
--      SEC 里真实出现的畸形写法（见 resolveUrl 里逐个分支的注释）。

--- 剥掉 #fragment（fragment 对取文件没有意义，而且 SEC 里出现过 src="#"）
local function stripFragment(u)
    return (u:gsub("#.*$", ""))
end

--- 规范化路径：处理 . / .. 与重复的 /，保留 query。
local function normalizePath(p)
    local query = ""
    p = stripFragment(p)
    local q = p:match("%?(.*)$")
    if q then
        query = "?" .. q
        p = p:gsub("%?.*$", "")
    end
    local out = {}
    for seg in p:gmatch("[^/]+") do
        if seg == "." then
            -- 原地不动
        elseif seg == ".." then
            -- 不能越过站点根：多出来的 .. 直接丢弃（RFC 3986 的 remove_dot_segments 同理）
            if #out > 0 then out[#out] = nil end
        else
            out[#out + 1] = seg
        end
    end
    return "/" .. table.concat(out, "/") .. query
end
SecImages.normalizePath = normalizePath

--- 把基准 URL 拆成 scheme / host（含端口）/ path（不含 query、fragment）
local function splitBase(base)
    if type(base) ~= "string" then return nil end
    local scheme, rest = base:match("^(%a[%w+.-]*)://(.+)$")
    if not scheme then return nil end
    local host, path = rest:match("^([^/]*)(/.*)$")
    if not host then
        host, path = rest, "/"
    end
    path = path:gsub("[%?#].*$", "")
    if host == "" then return nil end
    return scheme, host, path
end
SecImages.splitBase = splitBase

--- 主机名是否属于 SEC（用于默认的「只抓同源图片」策略）
local function isSecHost(host)
    local h = host:gsub(":%d+$", ""):lower()
    return h == "sec.gov" or h:match("%.sec%.gov$") ~= nil
end

--- 把 src 解析成绝对 URL。
---@param base string  该文件的基准 URL（形如 https://www.sec.gov/Archives/.../doc.htm）
---@param src string   <img src> 的原始值
---@return string|nil, string|nil  绝对 URL 或「为什么不用它」的原因标记
function SecImages.resolveUrl(base, src)
    if type(src) ~= "string" then return nil, "no-src" end
    -- 先去掉两端空白（SEC 原文里出现过 src=" x.png "）
    src = src:gsub("^%s+", ""):gsub("%s+$", "")
    if src == "" then return nil, "empty" end
    -- 纯锚点：老文件里用来占位，拼出来会指向文档自己，毫无意义
    if src:sub(1, 1) == "#" then return nil, "fragment" end

    local low = src:lower()
    -- data: URI 是内嵌的，不是「要下载的文件」。它可以直接进 epub，但那要另做一步
    -- （解码 base64 并当文件写出去），本轮不做，如实记进 stats。
    if low:sub(1, 5) == "data:" then return nil, "data-uri" end
    if low:sub(1, 11) == "javascript:" then return nil, "javascript" end
    if low:sub(1, 5) == "blob:" then return nil, "blob" end
    if low:sub(1, 7) == "mailto:" then return nil, "mailto" end

    -- 1) 完整绝对 URL
    local scheme = src:match("^(%a[%w+.-]*)://")
    if scheme then
        return stripFragment(src)
    end

    -- 2) 协议相对：//host/x.png —— 继承基准 URL 的协议（不写死 https：
    --    这样如果调用方手上有 http 的基准 URL，也不会被我们悄悄改成 https）
    if src:sub(1, 2) == "//" then
        local bscheme = splitBase(base)
        return (bscheme or "https") .. ":" .. stripFragment(src)
    end

    local bscheme, bhost, bpath = splitBase(base)
    if not bscheme then return nil, "no-base" end

    -- 3) 站点根相对：/x.png
    if src:sub(1, 1) == "/" then
        return bscheme .. "://" .. bhost .. normalizePath(src)
    end

    -- 4) 文档相对：./x.png、../x.png、image1.gif
    --    以基准 URL 所在目录为基准（所以 base_url 必须是**文档本身的 URL**，
    --    而不是目录 URL —— 目录 URL 以 / 结尾时会多退一级）
    local dir = bpath:match("^(.*)/")
    if not dir or dir == "" then dir = "" end
    return bscheme .. "://" .. bhost .. normalizePath(dir .. "/" .. src)
end

--- 取 URL 的路径部分（去掉 query / fragment），并用小写
local function urlPathLower(u)
    local p = u:gsub("[%?#].*$", "")
    return p:lower()
end

--- 从 URL 猜扩展名（猜不准也没关系：下载后会按魔数复核并改名）
function SecImages.extensionFromUrl(u)
    local p = urlPathLower(u)
    local ext = p:match("%.([%w]+)$")
    if not ext then return nil end
    if #ext < 2 or #ext > 5 then return nil end
    return ext
end

--- 扩展名 -> media type（EPUB 用得到的几种）
local EXT_TO_MEDIA = {
    jpg = "image/jpeg", jpeg = "image/jpeg", jpe = "image/jpeg",
    png = "image/png",
    gif = "image/gif",
    webp = "image/webp",
    svg = "image/svg+xml",
    bmp = "image/bmp",
    tif = "image/tiff", tiff = "image/tiff",
}
local MEDIA_TO_EXT = {
    ["image/jpeg"] = "jpg",
    ["image/png"] = "png",
    ["image/gif"] = "gif",
    ["image/webp"] = "webp",
    ["image/svg+xml"] = "svg",
    ["image/bmp"] = "bmp",
    ["image/tiff"] = "tiff",
}

function SecImages.mediaTypeForExt(ext)
    if not ext then return nil end
    return EXT_TO_MEDIA[ext:lower()]
end

function SecImages.extensionFor(media_type)
    return MEDIA_TO_EXT[media_type]
end

--------------------------------------------------------------------------
-- 魔数嗅探：以文件内容为准判定格式，并顺手取回真实尺寸
--------------------------------------------------------------------------
-- 为什么必须做：SEC 上流传过来的文件名不可靠（历史上有过 .jpg 里装 PNG、
-- 无扩展名的图片端点）。manifest 里的 media-type 写错，阅读器就会拒绝渲染，
-- 用户看到的是破图 —— 这正是本模块存在的意义，不能在最后一步砸掉。

local function jpegSize(head)
    local i = 3 -- 跳过 SOI(FF D8)，Lua 字符串是 1-based
    local n = #head
    while i <= n - 9 do
        if head:byte(i) ~= 0xFF then
            i = i + 1
        else
            local m = head:byte(i + 1)
            if m == 0xD8 or m == 0x01 or (m >= 0xD0 and m <= 0xD7) then
                i = i + 2
            elseif m == 0xD9 or m == 0xDA then
                return nil -- 到了 SOS/EOI 还没见到 SOF，拿不到尺寸
            else
                local len = head:byte(i + 2) * 256 + head:byte(i + 3)
                -- SOF0..SOF15，排除 DHT(C4) / JPG(C8) / DAC(CC)
                if m >= 0xC0 and m <= 0xCF and m ~= 0xC4 and m ~= 0xC8 and m ~= 0xCC then
                    local h = head:byte(i + 5) * 256 + head:byte(i + 6)
                    local w = head:byte(i + 7) * 256 + head:byte(i + 8)
                    return w, h
                end
                i = i + 2 + len
            end
        end
    end
    return nil
end

local function be32(s, p1)
    return s:byte(p1) * 16777216 + s:byte(p1 + 1) * 65536 + s:byte(p1 + 2) * 256 + s:byte(p1 + 3)
end
local function le16(s, p1)
    return s:byte(p1) + s:byte(p1 + 1) * 256
end

--- 按文件内容嗅探格式。
---@return table|nil { mediaType=, ext=, width=, height= }
function SecImages.sniff(path)
    local head = readHead(path, 2048)
    if not head or #head < 8 then return nil, "too-short" end

    if head:sub(1, 3) == "\255\216\255" then
        local w, h = jpegSize(head)
        return { mediaType = "image/jpeg", ext = "jpg", width = w, height = h }
    end
    if head:sub(1, 8) == "\137PNG\r\n\26\n" then
        local w, h
        if #head >= 24 then w, h = be32(head, 17), be32(head, 21) end
        return { mediaType = "image/png", ext = "png", width = w, height = h }
    end
    local g6 = head:sub(1, 6)
    if g6 == "GIF87a" or g6 == "GIF89a" then
        local w, h
        if #head >= 10 then w, h = le16(head, 7), le16(head, 9) end
        return { mediaType = "image/gif", ext = "gif", width = w, height = h }
    end
    if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then
        -- 尺寸解析要分 VP8 / VP8L / VP8X 三种，为了这点收益不值得写三个分支；
        -- 尺寸拿不到就是「不降采样」，保持原样，安全。
        return { mediaType = "image/webp", ext = "webp" }
    end
    if head:sub(1, 2) == "BM" then
        local w, h
        if #head >= 26 then
            w = be32(head, 19)
            h = be32(head, 23)
        end
        return { mediaType = "image/bmp", ext = "bmp", width = w, height = h }
    end
    if head:sub(1, 4) == "II*\0" or head:sub(1, 4) == "MM\0*" then
        return { mediaType = "image/tiff", ext = "tiff" }
    end
    -- SVG 是文本，前面可能有 XML 声明 / 注释
    local low = head:lower()
    if low:sub(1, 4) == "<svg" or (low:sub(1, 5) == "<?xml" and low:find("<svg", 1, true)) then
        return { mediaType = "image/svg+xml", ext = "svg" }
    end
    return nil, "unknown-magic"
end

--------------------------------------------------------------------------
-- <img> 标签的属性解析与重写
--------------------------------------------------------------------------
-- Lua 模式没有「大小写不敏感」开关，所以属性名一律解析出来后 :lower() 再比。
-- SEC 的老文件里 SRc= / SRC= / Src= 都出现过。

--- 解析一个开始标签的属性表。
---@return table|nil  { {name=, lower=, value=, q=, raw=}, ... }  按出现顺序
function SecImages.parseAttrs(tag)
    local body = tag:match("^<%s*[%a][%w_%-:.]*([^>]*)>")
    if not body then return nil end
    -- 自闭合的斜杠不属于任何属性
    body = body:gsub("/%s*$", "")

    local list = {}
    local pos = 1
    local n = #body
    while pos <= n do
        -- 跳过空白（find 返回的是起止下标，必须取第二个才是「匹配到哪儿」）
        local _sp, spe = body:find("^%s+", pos)
        if spe then pos = spe + 1 end
        if pos > n then break end

        local a_s, a_e, aname = body:find("^([%a_][%w_%-:.]*)", pos)
        if not aname then
            -- 认不出来的字符（比如残缺的引号）：往前挪一格，避免死循环
            pos = pos + 1
        else
            local after = a_e + 1
            local eq = body:find("^%s*=", after)
            if not eq then
                -- 无值属性（如 noshade）
                list[#list + 1] = {
                    name = aname, lower = aname:lower(),
                    value = nil, raw = body:sub(a_s, a_e),
                }
                pos = a_e + 1
            else
                local vpos = body:find("^%s*", eq + 1)
                local qch = body:sub(vpos, vpos)
                local value, vend
                if qch == '"' or qch == "'" then
                    local close = body:find(qch, vpos + 1, true)
                    if close then
                        value = body:sub(vpos + 1, close - 1)
                        vend = close
                    else
                        -- 引号没闭合：容忍到标签末尾（SEC 里真的出现过）
                        value = body:sub(vpos + 1)
                        vend = n
                    end
                else
                    -- 无引号值：find 的第一个返回值是起点、第二个才是终点
                    local vs, ve = body:find("^[^%s]+", vpos)
                    if vs then
                        value = body:sub(vs, ve)
                        vend = ve
                    else
                        -- 声明了 = 却没有值
                        value = ""
                        vend = eq
                    end
                end
                list[#list + 1] = {
                    name = aname, lower = aname:lower(),
                    value = value, q = (qch == '"' or qch == "'") and qch or nil,
                    raw = body:sub(a_s, vend),
                }
                pos = vend + 1
            end
        end
    end
    return list
end

--- 取某个属性（大小写不敏感）
function SecImages.getAttr(list, lname)
    for _i, a in ipairs(list) do
        if a.lower == lname then return a end
    end
    return nil
end

--- 重建 img 标签：只换 src 的值，其余（含 alt）按原样保留。
--- 为什么按原样保留而不是重排：SEC 原文里的值已经做过 XML 转义，
--- 换一种引号风格可能反而破坏它（例如 alt='say "hi"' 用双引号包就会坏掉）。
local function rebuildImgTag(tagname, cols, drop_lower, src_placeholder, add_alt)
    local parts = {}
    local had_src = false
    for _i, a in ipairs(cols) do
        if a.lower == "src" then
            -- src 写在原来的位置上，输出看起来和原文一致（便于人工核对 diff）
            had_src = true
            parts[#parts + 1] = 'src="' .. src_placeholder .. '"'
        elseif not drop_lower[a.lower] then
            if a.value == nil then
                parts[#parts + 1] = a.raw
            else
                local q = a.q or '"'
                parts[#parts + 1] = a.name .. "=" .. q .. a.value .. q
            end
        end
    end
    if not had_src then
        parts[#parts + 1] = 'src="' .. src_placeholder .. '"'
    end
    if add_alt then
        parts[#parts + 1] = 'alt=""'
    end
    if #parts == 0 then
        return "<" .. tagname .. "/>"
    end
    return "<" .. tagname .. " " .. table.concat(parts, " ") .. "/>"
end

--------------------------------------------------------------------------
-- 阶段一：扫描 + 去重 + 把 <img> 换成占位标记
--------------------------------------------------------------------------

--- 扫描 HTML，产出「待抓图片清单」和「带占位标记的 HTML 模板」。
---
--- 为什么要留一个模板（而不是当场就写好 src）：内部路径的扩展名要靠下载后的
--- 魔数才能确定。先写死一个扩展名、之后再回头改 HTML，既会多一遍全文扫描，
--- 也可能把正文里恰好长得一样的字符串改错。用占位标记就没有这个问题：
--- 标记只可能由我们自己产生。
---@return table|nil plan, string|nil err
function SecImages:plan(html, base_url, opts)
    opts = opts or {}
    if type(html) ~= "string" then return nil, "html 不是字符串" end
    if type(base_url) ~= "string" or base_url == "" then return nil, "缺少 base_url" end

    local defaults = SecImages.defaults
    local image_dir = opts.dir_in_epub or defaults.image_dir
    local namespace = opts.namespace or ""
    local allow_external = opts.allow_external_images == true

    local drop_lower = { srcset = true, ["data-src"] = true, ["data-original"] = true }

    local stats = {
        img_tags = 0, unique = 0, refs = 0,
        skipped_empty = 0, skipped_fragment = 0, skipped_data_uri = 0,
        skipped_unknown_scheme = 0, skipped_external = 0,
        srcset_removed = 0, alt_added = 0, deduped = 0, external_hosts = {},
    }
    local log = {}

    local items = {}          -- 有序：按首次出现
    local by_url = {}         -- 绝对 URL -> item
    local out = {}            -- HTML 片段
    local last = 1
    local n = #html

    local pos = 1
    while true do
        -- 找下一个 <img（大小写不敏感）。不能用 `<!-` 之类的通用扫描，
        -- 必须确认标签名正好是 img，否则 <image> / <imgfoo> 会被误命中。
        local lt
        local search = pos
        while true do
            local cand = html:find("<", search, true)
            if not cand then break end
            local name = html:match("^<([%a][%w_%-:.]*)", cand)
            if name and name:lower() == "img" then
                lt = cand
                break
            end
            if name and name:lower():sub(1, 3) == "img" then
                -- 是 <img 开头的别的标签名，跳过整段名字，别逐字符挪
                search = cand + #name + 1
            else
                search = cand + 1
            end
        end
        if not lt then break end

        local gt = html:find(">", lt, true)
        if not gt then break end

        local tag = html:sub(lt, gt)
        stats.img_tags = stats.img_tags + 1

        local cols = SecImages.parseAttrs(tag)
        -- 标签名（保留原有大小写，重建时沿用）
        local tagname = tag:match("^<%s*([%a][%w_%-:.]*)") or "img"

        local src_attr = cols and SecImages.getAttr(cols, "src") or nil
        local src_raw = src_attr and src_attr.value or nil

        -- srcset：本模块不认它（SEC 文件里极罕见）。但**必须从输出里删掉** ——
        -- 留着就是一串指向外网的绝对 URL 躺在 epub 里，离线阅读器可能去访问它。
        if cols then
            for _i, a in ipairs(cols) do
                if drop_lower[a.lower] and a.value ~= nil then
                    stats.srcset_removed = stats.srcset_removed + 1
                end
            end
        end

        local abs, reason = SecImages.resolveUrl(base_url, src_raw or "")
        local host = abs and abs:match("^%a[%w+.-]*://([^/]+)") or nil
        local skip_external = (not allow_external) and host and not isSecHost(host)

        if not abs then
            if reason == "empty" or reason == "no-src" then
                stats.skipped_empty = stats.skipped_empty + 1
            elseif reason == "fragment" then
                stats.skipped_fragment = stats.skipped_fragment + 1
            elseif reason == "data-uri" then
                stats.skipped_data_uri = stats.skipped_data_uri + 1
            else
                stats.skipped_unknown_scheme = stats.skipped_unknown_scheme + 1
            end
            -- 拼不出 URL 就整块删掉：留一个指向 "#" 的 img 只会渲染成一个破图方框
            out[#out + 1] = html:sub(last, lt - 1)
            last = gt + 1
            pos = gt + 1
        elseif skip_external then
            -- 默认只抓 SEC 自家的图片。理由：src 来自第三方文档内容，
            -- 放行任意域名等于让 SEC 文档里的一个 URL 指挥我们去访问外部主机
            -- （跟踪像素、内网探测都属于这一类）。SEC 归档里的图片本来就都在
            -- sec.gov 下，真需要时调用方可以显式打开 allow_external_images。
            stats.skipped_external = stats.skipped_external + 1
            stats.external_hosts[host] = (stats.external_hosts[host] or 0) + 1
            out[#out + 1] = html:sub(last, lt - 1)
            last = gt + 1
            pos = gt + 1
        else
            local item = by_url[abs]
            if item then
                item.refs = item.refs + 1
                stats.deduped = stats.deduped + 1
            else
                local id = string.format("img%03d", #items + 1)
                local alt_attr = cols and SecImages.getAttr(cols, "alt") or nil
                local add_alt = false
                if not alt_attr or alt_attr.value == nil then
                    -- 无障碍要求 <img> 必须有 alt。原图没给就补空的
                    -- （空 alt 是「装饰性图片」的标准写法），并记数如实汇报。
                    add_alt = true
                    stats.alt_added = stats.alt_added + 1
                end
                item = {
                    id = id,
                    src = abs,
                    src_raw = src_raw,
                    alt = (alt_attr and alt_attr.value) or "",
                    refs = 1,
                    tag_template = rebuildImgTag(tagname, cols or {}, drop_lower,
                        "\1SRC\1", add_alt),
                    marker = "\1SECIMG:" .. id .. "\1",
                }
                items[#items + 1] = item
                by_url[abs] = item
                stats.unique = stats.unique + 1
            end
            stats.refs = stats.refs + 1
            out[#out + 1] = html:sub(last, lt - 1)
            out[#out + 1] = item.marker
            last = gt + 1
            pos = gt + 1
        end
    end
    out[#out + 1] = html:sub(last, n)

    -- 给每个 item 补上内部路径（扩展名先用 URL 上的猜一个，下载后按魔数复核）
    for _i, item in ipairs(items) do
        local ext = SecImages.extensionFromUrl(item.src)
        local mt = SecImages.mediaTypeForExt(ext)
        if not mt then
            ext = nil
            mt = nil
        end
        item.ext_guess = ext
        item.media_type_guess = mt
        item.namespace = namespace
    end

    if stats.srcset_removed > 0 then
        log[#log + 1] = string.format(
            "srcset/data-src 出现 %d 次：本模块不解析 srcset（SEC 文件里极罕见），已从输出中删除，避免 epub 里留下指向外网的死引用。",
            stats.srcset_removed)
    end
    if stats.deduped > 0 then
        log[#log + 1] = string.format("有 %d 处 <img> 与前面的图指向同一个 URL，只抓一次。", stats.deduped)
    end
    if stats.skipped_data_uri > 0 then
        log[#log + 1] = string.format(
            "有 %d 个 data: URI 内嵌图片被跳过（本轮不处理内嵌 base64）。", stats.skipped_data_uri)
    end
    if stats.skipped_external > 0 then
        local hosts = {}
        for h, _c in pairs(stats.external_hosts) do hosts[#hosts + 1] = h end
        table.sort(hosts)
        log[#log + 1] = string.format(
            "有 %d 个 <img> 指向 sec.gov 以外的域名（%s），按默认策略跳过（可在 opts 里打开 allow_external_images）。",
            stats.skipped_external, table.concat(hosts, ", "))
    end
    if stats.alt_added > 0 then
        log[#log + 1] = string.format("有 %d 张原图没有 alt，已补空 alt（无障碍与审核需要）。", stats.alt_added)
    end

    return {
        template = table.concat(out),
        items = items,
        base_url = base_url,
        namespace = namespace,
        image_dir = image_dir,
        stats = stats,
        log = log,
    }
end

--------------------------------------------------------------------------
-- 阶段二：下载（边下边写盘）
--------------------------------------------------------------------------

--- 默认下载实现：LuaSocket + ltn12，流式写盘。
---@param url string
---@param dst string 目标文件（调用方保证目录存在）
---@param opts table
---@return boolean|nil, string|number|nil  true 时第二个返回值是字节数
function SecImages.defaultFetch(url, dst, opts)
    local http = require("socket.http")
    local ltn12 = require("ltn12")

    local attempts = opts.attempts or SecImages.defaults.attempts
    local timeout = opts.timeout or SecImages.defaults.timeout
    local last_err

    for attempt = 1, attempts do
        local fh = io.open(dst, "wb")
        if not fh then return nil, "无法写入 " .. dst end

        -- ltn12.sink.file 会在收到 nil chunk（传输结束）时**自己**把句柄关掉。
        -- 这一点必须挡一下：Lua 的 file:close() 对已经关闭的文件是**抛错**
        -- （attempt to use a closed file），不是返回 nil。
        -- 实测证据：不加这个判断，本模块在下载第一张图时就会崩，
        -- 而设备上的表现会是「整个插件挂掉」。见 evidence/images_real/e2e.log。
        -- 触发路径：LuaSocket 的 receivebody 用 ltn12.pump.all，pump.step 在源读完时
        -- 会调 snk(nil, nil)，于是 sink.file 里的 handle:close() 被执行。
        local file_sink = ltn12.sink.file(fh)
        local sink_closed = false
        local nbytes = 0
        local sink = function(chunk, err)
            if not chunk then sink_closed = true end
            local ret, werr = file_sink(chunk, err)
            -- 只统计真的写下去了的字节
            if chunk and ret then nbytes = nbytes + #chunk end
            return ret, werr
        end

        local old_timeout = http.TIMEOUT
        http.TIMEOUT = timeout
        local ok, code = http.request{
            url = url,
            method = "GET",
            headers = {
                ["user-agent"] = opts.user_agent,
                ["accept"] = "*/*",
            },
            sink = sink,
        }
        http.TIMEOUT = old_timeout
        -- 只有 sink 没关过才由我们关（原因见上面 sink_closed 那段注释）
        if not sink_closed then fh:close() end

        local n = tonumber(code) or 0
        if ok and n < 400 and nbytes > 0 then
            return true, nbytes
        end

        -- 半截文件必须删掉：留着会被当成「下载成功」写进 zip，
        -- 在书里就是一张破图 —— 比直接跳过更难查。
        os.remove(dst)

        last_err = string.format("HTTP %s", tostring(code))
        -- 4xx 是「这个请求本身不对」，重试没有意义；5xx / 网络中断才值得重试
        if n >= 400 and n < 500 then break end
        if attempt < attempts then
            local s = socketModule()
            if s and s.sleep then s.sleep(attempt * 2) end
        end
    end
    return nil, last_err
end

--- 缩了以后反而更大是可能的（JPEG 重编码的量化表与原图不同）。不是错误，
--- 但值得记一笔：像素确实变少了（解码内存与显示浪费都少了），只是字节没省下来。
local _grow_notes = {}
SecImages._downscale_grow_notes = _grow_notes

--- 跑完所有下载。单张失败只记录，不中断。
---@return boolean ok
function SecImages:fetchAll(plan, opts)
    local defaults = SecImages.defaults
    local fetch = opts.fetch or SecImages.defaultFetch
    local throttle_ms = opts.throttle_ms
    if throttle_ms == nil then throttle_ms = defaults.throttle_ms end

    local items = plan.items
    local total = #items
    local stats = plan.stats
    stats.ok = 0
    stats.failed = 0
    stats.bytes = 0
    stats.max_bytes = 0
    stats.max_bytes_src = nil
    stats.downscaled = 0
    stats.downscale_skipped_small = 0
    stats.downscale_unsupported = 0
    stats.downscale_failed = 0
    local failures = {}

    local t0 = SecImages.now()

    for idx = 1, total do
        local item = items[idx]

        -- 进度回调放在所有 pcall 之外 —— 它内部可能会 yield（Trapper:info），
        -- 一旦被 pcall 包住，LuaJIT 会直接报 "attempt to yield across a C-call boundary"。
        if opts.on_progress then
            opts.on_progress(idx, total, item.src)
        end

        local dst = plan.dir_abs .. "/" .. item.id .. ".part"
        local ok, res = fetch(item.src, dst, {
            user_agent = opts.user_agent,
            attempts = opts.attempts,
            timeout = opts.timeout,
            item = item,
        })

        if not ok then
            item.failed = true
            item.err = tostring(res)
            stats.failed = stats.failed + 1
            failures[#failures + 1] = { id = item.id, src = item.src, alt = item.alt, err = item.err }
            plan.log[#plan.log + 1] = string.format("图片抓取失败 %s（%s）：%s", item.id, item.src, item.err)
            os.remove(dst)
        else
            -- 以文件内容为准定格式（不信 URL 上的扩展名）
            local sniff, reason = SecImages.sniff(dst)
            local ext, media
            if sniff and sniff.mediaType then
                ext, media = sniff.ext, sniff.mediaType
                item.mediaType = media
                item.ext = ext
                item.width, item.height = sniff.width, sniff.height
                if item.media_type_guess and item.media_type_guess ~= media then
                    plan.log[#plan.log + 1] = string.format(
                        "图片 %s 的扩展名与内容不符（URL 说 %s，文件头说 %s），以文件头为准。",
                        item.id, tostring(item.media_type_guess), media)
                end
            else
                ext, media = item.ext_guess, item.media_type_guess
                item.mediaType, item.ext = media, ext
                item.media_type_from_url = true
                plan.log[#plan.log + 1] = string.format(
                    "图片 %s 的文件头认不出来（%s），按 URL 扩展名当作 %s。原 URL：%s",
                    item.id, tostring(reason), tostring(media), item.src)
            end

            if not media then
                -- 既认不出内容、URL 上也没有可用扩展名：不猜。
                item.failed = true
                item.err = "无法判定图片格式"
                item.mediaType, item.ext = nil, nil
                stats.failed = stats.failed + 1
                failures[#failures + 1] = { id = item.id, src = item.src, alt = item.alt, err = item.err }
                plan.log[#plan.log + 1] = string.format("图片 %s 无法判定格式，已跳过：%s", item.id, item.src)
                os.remove(dst)
            end
        end

        if not item.failed then
            local final = plan.dir_abs .. "/" .. item.id .. "." .. item.ext
            os.remove(final)
            local mv_ok, mv_err = os.rename(dst, final)
            if not mv_ok then
                os.remove(dst)
                item.failed = true
                item.err = "重命名失败：" .. tostring(mv_err)
                stats.failed = stats.failed + 1
                failures[#failures + 1] = { id = item.id, src = item.src, alt = item.alt, err = item.err }
            else
                item.path = final
                item.bytes = fileSize(final) or 0

                -- 降采样（可选）。任何失败都保留原文件 —— 图不能因为「优化」而消失。
                if opts.downscale ~= false then
                    local dres, dreason = SecImages:downscaleFile(final, item, opts)
                    if dres then
                        item.downscaled = true
                        item.bytes = fileSize(final) or item.bytes
                        stats.downscaled = stats.downscaled + 1
                    elseif dreason == "already-small" then
                        stats.downscale_skipped_small = stats.downscale_skipped_small + 1
                    elseif dreason == "no-library" or dreason == "unsupported-format"
                        or dreason == "no-size" then
                        stats.downscale_unsupported = stats.downscale_unsupported + 1
                    else
                        stats.downscale_failed = stats.downscale_failed + 1
                        plan.log[#plan.log + 1] = string.format(
                            "图片 %s 降采样未生效（%s），已保留原图。", item.id, tostring(dreason))
                    end
                end

                item.href = plan.href_prefix .. item.id .. "." .. item.ext
                item.arcname = "OEBPS/" .. item.href
                stats.ok = stats.ok + 1
                stats.bytes = stats.bytes + (item.bytes or 0)
                if (item.bytes or 0) > stats.max_bytes then
                    stats.max_bytes = item.bytes
                    stats.max_bytes_src = item.src
                end
            end
        end

        -- 节流：SEC 的公平访问上限约 10 请求/秒。图片小、回得快，
        -- 一份 22 张的 deck 不节流会在两三秒内全部打完。留 120ms 间隔即约 8/秒。
        if throttle_ms > 0 and idx < total then
            local s = socketModule()
            if s and s.sleep then s.sleep(throttle_ms / 1000) end
        end
    end

    stats.total_ms = math.floor((SecImages.now() - t0) * 1000 + 0.5)
    stats.total_ms_source = SecImages.now_source

    if stats.bytes > (opts.warn_total_bytes or defaults.warn_total_bytes) then
        plan.log[#plan.log + 1] = string.format(
            "本份文件的图片合计 %.1f MB，超过提醒阈值 %.0f MB。这份体积会直接进 epub，请留意设备可用空间。",
            stats.bytes / 1048576, (opts.warn_total_bytes or defaults.warn_total_bytes) / 1048576)
    end

    plan.failed = failures
    return true
end

--------------------------------------------------------------------------
-- 降采样：解码 -> 缩放 -> 重新编码
--------------------------------------------------------------------------
-- 设备上可用（KOReader v2026.07.2，均不依赖 ui/*），三条腿都是现成 ffi：
--   解码：ffi/pic 的 Pic.openDocument(path)（按扩展名分派 jpg/png/gif/webp），
--         返回的 doc.image_bb 就是 BlitBuffer。底层是 turbojpeg / lodepng。
--   缩放：ffi/mupdf 的 Mupdf.scaleBlitBuffer(bb, w, h)（双线性）。KOReader 自己
--         在 renderimage.lua 里就是用它，注释写着 "Better quality scaling with MuPDF"；
--         退化路径是 BlitBuffer:scale()，它是**最近邻**，KOReader 只在用户显式
--         打开 legacy_image_scaling 时才用它。
--   编码：BlitBuffer:writeJPG(path, quality) / writePNG(path)。
--
-- 证据（不是猜的）：这条链路就是 KOReader 的生产路径 ——
-- frontend/ui/renderimage.lua:renderJpegImageDataWithTurboJpeg() 走的正是
-- 「Pic.openJPGDocumentFromData -> scaleBlitBuffer -> BlitBuffer」；
-- screenshoter / coverimage / thumbnail 也用同一套 ffi 接口把位图写成文件。
--
-- 安全性设计：整段包在 pcall 里是**安全且必要**的，因为这些 ffi 调用在失败时
-- 用 error() 抛错（Pic.openDocument 会 error("Unsupported image format")，
-- Jpeg.encodeToFile 里有 assert），而它们都是纯 C 调用、内部不会 coroutine.yield()，
-- 所以不违反「不得跨 pcall yield」这条死规矩。进度回调不在这里调用。
---
---@return boolean|nil ok, string|nil reason
function SecImages:downscaleFile(path, item, opts)
    local defaults = SecImages.defaults
    local max_width = opts.max_width or defaults.max_width
    local quality = opts.jpeg_quality or defaults.jpeg_quality

    local media = item.mediaType
    -- GIF/WebP 可能是动画，缩了会丢帧；SVG 是矢量，本来就没有「太大」的问题。
    if media ~= "image/jpeg" and media ~= "image/png" then
        return nil, "unsupported-format"
    end

    -- 尺寸已知且不超限：一步都不做。这一步很关键 —— 绝大多数 SEC 图片
    -- （实测微软 FY27 deck 的 22 张全是 1200x675）到这里就返回了，
    -- 既不动像素，也不白损失一次 JPEG 重编码的质量。
    if item.width and item.height and item.width <= max_width then
        return nil, "already-small"
    end
    if not item.width or not item.height then
        -- 尺寸未知（例如 webp）就不缩：不知道目标高度，也没法验证产出。
        return nil, "no-size"
    end

    local ok_pic, Pic = pcall(require, "ffi/pic")
    if not ok_pic or type(Pic) ~= "table" or not Pic.openDocument then
        return nil, "no-library"
    end

    -- Pic.color 是模块级开关（renderimage.lua 每次调用前也会设置它）。
    -- 我们默认按彩色解码：图片进的是 epub，用户以后可能在彩色设备上读，
    -- 也可能把 epub 导出来；e-ink 屏自己会做灰度映射，没必要在这就把颜色毁掉。
    -- 想省解码内存可以显式 opts.grayscale = true（1 字节/像素 vs 3 字节/像素）。
    local saved_color = Pic.color
    Pic.color = not opts.grayscale

    local tmp = path .. ".ds.tmp"
    os.remove(tmp)

    local already_small = false

    -- pcall 只包「纯 C、不 yield」的解码/缩放/编码（原因见本节标题下的注释）
    local ok_run, err_run = pcall(function()
        local doc = Pic.openDocument(path)
        if not doc or not doc.image_bb then error("解码没有返回位图") end
        local bb = doc.image_bb
        local w, h = bb:getWidth(), bb:getHeight()
        if w <= max_width then
            doc:close()
            already_small = true
            return
        end
        local nw = max_width
        local nh = math.max(1, math.floor(h * max_width / w + 0.5))

        local scaled
        local ok_m, Mupdf = pcall(require, "ffi/mupdf")
        if ok_m and type(Mupdf) == "table" and Mupdf.scaleBlitBuffer then
            local ok_s, res = pcall(Mupdf.scaleBlitBuffer, bb, nw, nh)
            if ok_s and res then scaled = res end
        end
        if not scaled then
            -- 退化到最近邻。质量明显更差（文字会有锯齿），但总比不缩好，
            -- 而且只在 MuPDF 不可用时才会走到这里。
            local ok_s, res = pcall(function() return bb:scale(nw, nh) end)
            if ok_s and res then scaled = res end
        end
        if not scaled then
            doc:close()
            error("缩放失败")
        end

        local ok_w, werr
        if media == "image/png" then
            ok_w, werr = scaled:writePNG(tmp)
        else
            ok_w, werr = scaled:writeJPG(tmp, quality)
        end
        scaled:free()
        doc:close()
        if not ok_w then error("编码失败：" .. tostring(werr)) end
    end)

    Pic.color = saved_color

    if not ok_run then
        os.remove(tmp)
        return nil, tostring(err_run)
    end
    if already_small then
        os.remove(tmp)
        return nil, "already-small"
    end

    -- 产出校验：必须是「认得出来的同格式图片」，且尺寸确实变小了。
    -- 这一步是本项目的习惯：凡是数据转换都要有可判定的验收条件，
    -- 否则编码器静默写坏文件时我们只会发现「书里图没了」。
    local sniff = SecImages.sniff(tmp)
    if not sniff or sniff.mediaType ~= media then
        os.remove(tmp)
        return nil, "产出格式不符"
    end
    if not sniff.width or sniff.width > max_width then
        os.remove(tmp)
        return nil, "产出尺寸不符"
    end
    local nsz = fileSize(tmp)
    if not nsz or nsz == 0 then
        os.remove(tmp)
        return nil, "产出为空"
    end

    local old_size = fileSize(path) or 0
    local old_w, old_h = item.width, item.height

    os.remove(path)
    if not os.rename(tmp, path) then
        os.remove(tmp)
        return nil, "替换失败"
    end

    item.width, item.height = sniff.width, sniff.height
    item.downscale_from = string.format("%sx%s", tostring(old_w), tostring(old_h))
    if nsz > old_size then
        _grow_notes[#_grow_notes + 1] = string.format("%s：%d -> %d 字节",
            item.id, old_size, nsz)
    end
    return true
end

--------------------------------------------------------------------------
-- 阶段三：把占位标记换成最终标签
--------------------------------------------------------------------------

---@return string html
function SecImages:finalize(plan, opts)
    local html = plan.template

    for _i, item in ipairs(plan.items) do
        local marker = item.marker
        local repl
        if item.failed or not item.href then
            -- 失败：留下 alt 文字，让读者知道「这里原本有一张图」，
            -- 而不是留一个指向不存在文件的破图方框。
            local text = item.alt
            if text == nil or text == "" then
                -- 原图没给 alt，就用文件名，至少有个线索
                text = item.src:match("([^/]+)$") or item.src
            end
            repl = string.format('<span class="%s">%s</span>',
                (opts and opts.failed_marker_class) or SecImages.defaults.failed_marker_class,
                text)
        else
            repl = item.tag_template:gsub("\1SRC\1", function() return item.href end)
        end
        -- 用函数式替换：替换串里的 % 不会被当成模式转义
        html = html:gsub(marker, function() return repl end)
    end

    return html
end

--------------------------------------------------------------------------
-- OPF manifest 片段
--------------------------------------------------------------------------

--- 生成可直接拼进 <manifest> 的 <item> 行。
--- 注意：现有 OPF 是 EPUB 2.0（package version="2.0"），所以**不能**加
--- `properties="svg"` 这类 EPUB 3 属性 —— 那会让 OPF 在校验器眼里不合法。
function SecImages.manifestXml(entries, indent)
    indent = indent or "    "
    local out = {}
    for _i, e in ipairs(entries) do
        out[#out + 1] = string.format('%s<item id="%s" href="%s" media-type="%s"/>',
            indent, e.id, e.href, e.mediaType)
    end
    return table.concat(out, "\n") .. (#out > 0 and "\n" or "")
end

--------------------------------------------------------------------------
-- 入口
--------------------------------------------------------------------------

--- namespace 会被拼进路径与 XML id，所以只留安全字符。
--- 为什么必须给 namespace：本插件把多家公司、多份 filing 打进**同一个** epub，
--- 全文只有一个 content.html 和一个 content.opf。如果每个 filing 都从 img001 开始，
--- 后面的图会把前面的覆盖掉，OPF 里还会出现重复 id（XML 不合法）。
local function safeNamespace(ns)
    if not ns or ns == "" then return "" end
    local s = tostring(ns):gsub("[^%w_%-]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    if s == "" then return "" end
    -- XML ID 必须是 NCName：不能以数字开头
    if s:match("^%d") then s = "n" .. s end
    return s
end
SecImages.safeNamespace = safeNamespace

--- 抓取并嵌入。
---@param html string 已清理的 HTML 片段
---@param base_url string 该文件的基准 URL（文档本身的 URL，不是目录）
---@param opts table 见文件头的 API 一节
---@return table|nil result, string|nil err
function SecImages:run(html, base_url, opts)
    opts = opts or {}
    if type(opts.user_agent) ~= "string" or opts.user_agent == "" then
        -- 不留默认值：SEC 要求 UA 里带可联系的邮箱，硬编码一个等于把别人的邮箱
        -- 写进开源仓库。调用方（插件设置）必须传入。
        return nil, "缺少 opts.user_agent（SEC 要求 User-Agent 里带邮箱，否则一律 403）"
    end
    if type(opts.dir) ~= "string" or opts.dir == "" then
        return nil, "缺少 opts.dir（图片落盘目录）"
    end

    local plan, err = self:plan(html, base_url, opts)
    if not plan then return nil, err end

    local ns = safeNamespace(opts.namespace)
    local image_dir = plan.image_dir
    plan.dir_abs = opts.dir .. "/" .. image_dir .. (ns ~= "" and ("/" .. ns) or "")
    plan.href_prefix = image_dir .. "/" .. (ns ~= "" and (ns .. "/") or "")

    local ok_dir, derr = ensureDir(plan.dir_abs)
    if not ok_dir then
        return nil, "无法准备图片目录 " .. plan.dir_abs .. "（" .. tostring(derr) ..
            "）—— 设备上请确认 lfs 可用，或由调用方先把目录建好"
    end

    for _i, item in ipairs(plan.items) do
        -- 文件名靠 namespace 子目录保证全局唯一；XML id 也要唯一。
        item.xml_id = (ns ~= "" and (ns .. "-") or "") .. item.id
    end

    self:fetchAll(plan, opts)

    local result = {
        html = self:finalize(plan, opts),
        entries = {},
        failed = plan.failed or {},
        stats = plan.stats,
        log = plan.log,
        dir = plan.dir_abs,
        href_prefix = plan.href_prefix,
        namespace = ns,
    }
    for _i, item in ipairs(plan.items) do
        if not item.failed and item.path then
            result.entries[#result.entries + 1] = {
                id = item.xml_id,
                href = item.href,
                arcname = item.arcname,
                path = item.path,
                mediaType = item.mediaType,
                bytes = item.bytes,
                width = item.width,
                height = item.height,
                src = item.src,
                alt = item.alt,
                refs = item.refs,
                downscaled = item.downscaled or false,
                downscale_from = item.downscale_from,
            }
        end
    end
    result.manifest = SecImages.manifestXml(result.entries)

    if #_grow_notes > 0 then
        result.log[#result.log + 1] = string.format(
            "有 %d 张降采样后字节数反而增加（像素确实变少了、解码内存与显示浪费都减少，只是字节没省）：%s",
            #_grow_notes, table.concat(_grow_notes, "；"))
        _grow_notes = {}
    end

    return result
end

return SecImages
