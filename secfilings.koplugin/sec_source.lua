--[[
SEC 财报到可读 EPUB 的抓取与挑选逻辑。

为什么不能靠 RSS：
  SEC 的 Atom feed（browse-edgar?...&output=atom）**只有元数据** —— summary 里是
  "Filed: 日期 / AccNo / 大小 / Item 2.02 / Item 9.01" 这种条目名，没有正文。
  所以不管怎么打包，epub 里都没有东西可读。必须自己去抓正文文档。

数据来源（两个都是官方，都要求 UA 里带邮箱）：
  1) https://data.sec.gov/submissions/CIK##########.json
     一次请求拿到该公司最近 1000 条 filing，含 form / filingDate /
     accessionNumber / primaryDocument / items。
  2) https://www.sec.gov/Archives/edgar/data/<cik>/<accn>/index.json
     列出某份 filing 目录下的所有文件 —— 8-K 要靠它找 Exhibit 99.x。

挑选正文的规则（实测得出）：
  - R1.htm / R2.htm 这种是 XBRL 查看器的渲染页，不是原始文档，必须排除。
  - 8-K：优先 Exhibit 99.x，那才是新闻稿等实质内容；primaryDocument 只是封面页。
  - 10-K / 10-Q：primaryDocument 本身就是完整报告（特斯拉 10-Q 约 1.5MB）。

对外参数（都可以按实例覆盖，见 SecSource:new）：
  SecSource.user_agent       抓取请求的 User-Agent。**必须含联系邮箱**，否则 SEC 对
                             www.sec.gov 上的正文与 index.json 一律 403（实测 2026-10-07）。
                             默认是占位值，用户填了邮箱才换成真的。
  SecSource.table_avail_em   排版时可用的表格宽度，单位是「表格字号 em」。默认 15 ——
                             按「用户把字号调到菜单最大档 44」倒推出来的保守值，
                             推导过程见该字段处的注释。
  SecSource.table_max_cols   单张子表的列数上限（安全网），默认 6。
  SecSource.table_projection 按列投影拆表的总开关，默认 true。设 false 可整段退回旧行为。

实例化方式（推荐给调用方）：
  local src = SecSource:new{ user_agent = "某人的 Kindle 邮箱@example.com",
                             table_avail_em = SecSource.table_width_presets.loose }
  local filings = src:recentFilings(cik, 20)
  -- 直接用模块本身作实例（旧调用方式）也仍然可用，行为与旧版一致。
]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")

local SecSource = {}

-- 注意：本文件在所有循环里都不使用 `_` 作循环变量。
-- 这类插件顶部普遍有 `local _ = require("gettext")`，一旦某个循环写成
-- `for _, x in ipairs(...)`，循环体内再调 `_()` 就会变成「调用一个数字」
-- （实测报错：attempt to call local '_' (a number value)）。

-- ---- User-Agent（占位 + 可配） ----
--
-- SEC 要求所有请求的 User-Agent 里带「可联系的信息」（实操上就是邮箱）。
-- 这是**真的会拦**，而且两个域名表现不一样（2026-10-07 本机 curl 实测，
-- 原始输出见 evidence/f2/ua_probe.txt）：
--   UA = "Kindle SEC Reader <you@example.com>"      -> data 200 / www 200
--   UA = "koreader-sec-filings (联系邮箱未设置)"      -> data 200 / www 403
--   UA = "sec-filings-koreader"（有名字没邮箱）      -> data 200 / www 403
--   UA = ""（空）                                    -> data 403 / www 000（连接被拒）
-- 也就是：正文文档与 index.json 全在 www.sec.gov 上，没有邮箱就一份都取不回来。
-- data.sec.gov 当时没拦，但那是同一条政策下的宽松表现，不能拿它当依赖。
--
-- 所以默认值是一个**占位串**：用户没在设置里填邮箱时，请求会如实失败并把原因
-- 说清楚（见 httpErrorText），而不是让「什么都下不回来」变成一个看不出原因的谜。
SecSource.PLACEHOLDER_USER_AGENT = "koreader-sec-filings (联系邮箱未设置)"
SecSource.user_agent = SecSource.PLACEHOLDER_USER_AGENT

-- 超过这个大小的文档跳过。这个值是按实测定的：
--   微软 10-K（8.6MB）在设备上取回 4s、清理 57s、打包 1s，峰值内存 115MB，能跑通；
--   所以 12MB 能把真实的 10-K 收进来，同时拦住真正离谱的文件。
-- 代价要知道：碰到超大文档，那一家会卡住一分钟左右（进度框停在「正在取 …」不动），
-- 并且会短暂吃掉一百多 MB 内存。
SecSource.max_doc_bytes = 12 * 1024 * 1024

-- ---- 宽表格列拆分的三个参数（详见 splitWideTables 的注释） ----
--
-- 真机的版面几何（用用户自己那本书的 metadata.epub.lua 量出来的）：
--   屏宽 1236px，左右页边距 scaleBySize(10)=19px  ->  正文栏 1198px
--   设置里的字号 copt_font_size=22，但实际参与 crengine 排版的是约 47px
--   （用该书 doc_pages=471 反推得到）；表格字号是正文的 0.85 倍
--   =>  可用宽度 = 1198 / (0.85 * 47) ≈ 30 个「表格 em」
--
-- 单张子表的列数上限（含标签列）。只在「已经判定需要拆」时作为安全网上场：
-- 即使我的宽度估算偏乐观，压到 6 列以内，crengine 就算退化成
-- 「把可用宽度平均分给每个物理列」也分得够宽 —— 1198px / 6 = 200px，
-- 减去 padding 后内容宽约 163px，足以放下 "1,234,567" 这类最长数字。
SecSource.table_max_cols = 6
-- 单张子表允许的「最小内容宽度」预算，单位是表格字号 em。
--
-- ---- 这个默认值怎么来的（2026-10-07 重算，推导全在 FINDINGS「追加五」） ----
-- 可用宽度（em）= 正文栏像素 ÷ 表格字号像素，而表格字号 = 0.85 × 正文字号。
-- 正文栏像素是固定的（屏宽 1236 − 2×页边距），正文字号随用户的字号设置线性变化：
--   crengine.font.size = Screen:scaleBySize(设置值)（KOReader readerfont.lua:171，
--   线性 DPI 缩放；本机 KOReader 源码在 /private/tmp/ko，可复核）
-- 于是「可用宽度」与设置值成反比：
--   avail_em(s) = 30 × 22 / s = 660 / s
-- 其中 30 是上一轮实测出来的锚点（设置 22、页边距档位 10 → 正文栏 1198px、
-- 正文字号约 47px → 1198 / (0.85×47) ≈ 30 表格 em）。
-- 菜单里字号可选 {12,16,20,22,24,26,28,30,34,38,44}（KOReader defaults.lua:102，
-- 默认 22），最大档是 44：
--   s=12 -> 55.0 em | s=22 -> 30.0 em | s=30 -> 22.0 em | s=38 -> 17.4 em | s=44 -> 15.0 em
-- 上一轮的默认值 30 只在「字号 22」这一档成立；用户把字号拉到 44 时可用宽度只剩
-- 一半，5 列的子表会重新被挤压。默认值取保守的那一端：
--   默认 15  = 字号 44（最大档）下仍然放得下
--   22      = 字号 30 下放得下
--   30      = 字号 22（上一轮默认档）下放得下
-- 后两个放进 table_width_presets，供设置界面「宽松 / 标准 / 紧凑」直接映射。
-- 取保守值的代价只是子表更多、文档更长；取乐观值的代价是又变成「数字被逐字符折行」。
SecSource.table_avail_em = 15

-- 表格宽度预设：设置界面三个档位直接映射到这里（数值就是上面那张映射表）。
-- 名字按「对用户多宽松」排：loose 留给字号很小的人（子表少、文档短），
-- tight 是默认档 —— 字号拉到最大也还能读。
SecSource.table_width_presets = {
    loose  = 30,   -- 字号 ≤ 22（含默认档）时可用宽度约 30 em
    normal = 22,   -- 字号 ≤ 30 时可用宽度约 22 em
    tight  = 15,   -- 字号 ≤ 44（菜单最大档）时可用宽度约 15 em（默认）
}
-- 列拆分/投空列的总开关。设为 false 时这一段完全不作用（用于对比、排查，
-- 或万一线上出问题时立刻退回上一版行为，不必回滚代码）。
SecSource.table_projection = true

SecSource.companies = {
    { cik = 1318605, name = "特斯拉", legal = "Tesla, Inc." },
    { cik = 1045810, name = "英伟达", legal = "NVIDIA CORP" },
    { cik = 320193,  name = "苹果",   legal = "Apple Inc." },
    { cik = 1018724, name = "亚马逊", legal = "Amazon.com, Inc." },
    { cik = 1326801, name = "Meta",   legal = "Meta Platforms, Inc." },
    { cik = 1652044, name = "谷歌",   legal = "Alphabet Inc." },
    { cik = 789019,  name = "微软",   legal = "Microsoft Corp." },
}

function SecSource:padCik(cik)
    return string.format("%010d", cik)
end

--- 建一个带私有参数的实例。
---
--- 为什么需要它：两个参数从「模块常量」变成了「跟用户设置走」的东西 ——
--- 邮箱是用户填的，可用表格宽度随用户字号变。如果它们是全局的，两个用户/两本书
--- 之间就会互相覆盖，再往后（比如一本书记着 7 家公司）也根本没法按书取值。
---@param opts table|nil 要覆盖的字段，例如
---   { user_agent = "...", table_avail_em = 22, table_max_cols = 6 }
---   另外支持 email / agent_name 两个便捷写法：给了 email 就自动拼 UA。
function SecSource:new(opts)
    opts = opts or {}
    -- 只把 opts 里的键放到实例上，其余全部通过 __index 兜到模块。
    -- 这样「默认值只有一份」，改模块常量就同时改了所有未覆盖的实例。
    local inst = setmetatable({}, { __index = self })
    for k, v in pairs(opts) do inst[k] = v end
    if opts.email ~= nil and opts.user_agent == nil then
        inst.user_agent = self:makeUserAgent(opts.agent_name, opts.email)
    end
    return inst
end

--- 从 User-Agent 里取出邮箱。SEC 的判据就是「有没有可联系的邮箱」。
--- 只要求「像邮箱」，不校验可投递性 —— 那个只能在 SEC 那边验。
---@return string|nil
local function emailIn(ua)
    if not ua or ua == "" then return nil end
    return ua:match("[%w%._%%%+%-]+@[%w%.%-]+%.%a%a+")
end
SecSource.emailIn = emailIn

--- 按「名字 + 邮箱」拼一个合规的 User-Agent；邮箱为空时退回占位值。
--- 拼法只该有一份实现（设置界面与 sec_job 都用它），免得两边漂。
function SecSource:makeUserAgent(name, email)
    if not email or email == "" then return self.PLACEHOLDER_USER_AGENT end
    if not name or name == "" then name = "koreader-sec-filings" end
    return name .. " " .. email
end

--- 这个 User-Agent 会不会被 SEC 拒绝？
---
--- 为什么要单独有这么一个函数：它让调用方（设置界面、任务开始前）能**立刻**
--- 发现问题并提示用户去填邮箱，而不是等二三十个请求跑完、在某一章的失败原因里
--- 才看到一句 HTTP 403。
---@return boolean ok, string|nil 人可读的说明（ok 为 false 时）
function SecSource:checkUserAgent(ua)
    ua = ua or self.user_agent
    if not ua or ua == "" then
        return false, "User-Agent 是空的：SEC 会直接拒绝请求（HTTP 403）。"
    end
    if not emailIn(ua) then
        return false, string.format(
            "User-Agent 里没有联系邮箱（当前是「%s」）。SEC 要求 UA 带可联系的邮箱，" ..
            "否则 www.sec.gov 上的正文与 index.json 会返回 403。" ..
            "请到「设置 → SEC 财报」里填邮箱。", ua)
    end
    return true
end

--- 把 HTTP 结果翻成「能照着做」的说明。
---
--- 403 是 SEC 最常给的那个错，而且原因几乎总是 UA：没有邮箱、邮箱被 SEC 认为不可用、
--- 或短时间发得太密。只报一句「HTTP 403」等于把排查工作全丢给用户。
--- 注意：这里只把已知事实说清楚，不替 SEC 做判断 —— 没填邮箱时说的就是
--- 「SEC 拒绝了，因为没邮箱」，而不是断言「SEC 一定会拒」
--- （data.sec.gov 实测当时就放行了，见文件顶部）。
local function httpErrorText(code, nbytes, ua)
    local base = string.format("HTTP %s%s", tostring(code),
        (nbytes and nbytes > 0) and string.format("（收到 %d 字节后中断）", nbytes) or "")
    local n = tonumber(code)
    if n == 403 then
        if not emailIn(ua) then
            return base .. string.format(
                " —— SEC 拒绝了这个请求：User-Agent 里没有联系邮箱（当前是「%s」）。" ..
                "请到「设置 → SEC 财报」里填邮箱后重试。", tostring(ua))
        end
        return base .. " —— SEC 拒绝了请求。UA 已带邮箱，常见原因：" ..
            "该邮箱被 SEC 认为不可用，或请求过于频繁（上限约 10 次/秒）。"
    end
    return base
end

-- 同一轮里没必要为每个请求都刷一条日志，所以只提醒一次
local warned_no_email = false

--- 取一个 URL，返回 body；失败返回 nil, 错误说明。
---
--- 为什么要重试：8.6MB 的 10-K 这类大文件在慢网络上会碰到 "HTTP closed"
--- （连接中途断开）。实测真的出现了一次，后果是微软那一章整份 10-K 被跳过 ——
--- 对用户来说就是「微软的年报不见了」。重试能盖掉绝大多数瞬时故障。
---
--- 另外把超时改成显式值：LuaSocket 默认 60 秒，慢网上下 8MB 不够用。
--- 这里不用 KOReader 的 socketutil，因为它会连带 require 设备层，
--- 一 require 就没法脱离 UI 做无头测试了。
---
--- UA 的取值顺序：本次显式传入的 > 实例上的 user_agent > 模块默认（占位值）。
---@param user_agent string|nil 本次请求专用的 UA（不传就用实例上的）
function SecSource:fetch(url, attempts, user_agent)
    attempts = attempts or 3
    local ua = user_agent or self.user_agent
    if not emailIn(ua) and not warned_no_email then
        warned_no_email = true
        logger.warn("secfilings: User-Agent 里没有联系邮箱（" .. tostring(ua) ..
            "），SEC 对 www.sec.gov 的请求会返回 403")
    end
    local last_err

    for try = 1, attempts do
        local chunks = {}
        local old_timeout = http.TIMEOUT
        http.TIMEOUT = 120
        local ok, code = http.request{
            url = url,
            headers = { ["user-agent"] = ua },
            sink = ltn12.sink.table(chunks),
        }
        http.TIMEOUT = old_timeout

        local body = table.concat(chunks)
        if ok and (tonumber(code) or 0) < 400 and #body > 0 then
            return body
        end

        last_err = httpErrorText(code, #body, ua)

        -- 4xx 是「这个请求本身不对」，重试无意义；5xx 与网络错误才值得重试
        local n = tonumber(code)
        if n and n >= 400 and n < 500 then break end

        if try < attempts then
            -- 给网络一点恢复时间（LuaSocket 的 sleep 是阻塞的，最多几秒）
            pcall(function() require("socket").sleep(try * 2) end)
        end
    end

    return nil, last_err
end

--- filing 的归档目录
function SecSource:archiveDir(cik, accn)
    return string.format("https://www.sec.gov/Archives/edgar/data/%d/%s/",
        cik, accn:gsub("%-", ""))
end

--- 最近若干条 8-K / 10-K / 10-Q
---@param user_agent string|nil 本次专用的 UA（不传就用实例上的 self.user_agent）
---@return table|nil, string|nil  { {form,date,accn,primary,items}, ... }
function SecSource:recentFilings(cik, limit, user_agent)
    local body, err = self:fetch(
        "https://data.sec.gov/submissions/CIK" .. self:padCik(cik) .. ".json",
        nil, user_agent)
    if not body then return nil, "submissions: " .. tostring(err) end

    local ok, data = pcall(json.decode, body)
    if not ok or not data or not data.filings then return nil, "submissions 解析失败" end

    local r = data.filings.recent
    if not r or not r.form then return nil, "submissions 里没有 recent" end

    local out = {}
    for i = 1, #r.form do
        local form = r.form[i] or ""
        -- 只要这三大类，/A 修正版也一并收（名字上会体现）
        if form:match("^8%-K") or form:match("^10%-K") or form:match("^10%-Q") then
            out[#out + 1] = {
                form    = form,
                date    = r.filingDate[i] or "",
                accn    = r.accessionNumber[i] or "",
                primary = r.primaryDocument[i] or "",
                items   = r.items[i] or "",
            }
            if #out >= limit then break end
        end
    end
    return out
end

--- 在 filing 目录里挑出「人读的正文」文件名
---@return string|nil, string|nil 文件名, 选择理由
function SecSource:pickDocument(files, form, primary)
    local candidates = {}
    for _fi, it in ipairs(files) do
        local n = it.name or ""
        local lower = n:lower()
        -- R1.htm..Rn.htm 是 XBRL 查看器渲染出来的页面，不是原始提交文档
        if lower:match("%.html?$") and not lower:match("^r%d+%.htm") then
            candidates[#candidates + 1] = {
                name = n,
                size = tonumber(it.size) or 0,
            }
        end
    end
    table.sort(candidates, function(a, b) return a.size > b.size end)

    -- 8-K：Exhibit 99.x 才有实质内容
    if form:match("^8%-K") then
        for _ci, c in ipairs(candidates) do
            local l = c.name:lower()
            if l:match("exhibit999") or l:match("ex%-?99") or l:match("ex99")
                or l:match("exhibit") and l:match("99") then
                return c.name, "Exhibit 99.x"
            end
        end
    end

    -- 10-K / 10-Q：primaryDocument 就是完整报告
    if primary and primary ~= "" then
        for _ci, c in ipairs(candidates) do
            if c.name:lower() == primary:lower() then
                return c.name, "primaryDocument"
            end
        end
    end

    if candidates[1] then return candidates[1].name, "最大正文 htm" end
    return nil, nil
end

--- 取某份 filing 的可读正文
---@param user_agent string|nil 本次专用的 UA（不传就用实例上的 self.user_agent）
---@return table|nil, string|nil  { html=..., url=..., why=..., bytes=... }
function SecSource:filingContent(cik, filing, user_agent)
    local dir = self:archiveDir(cik, filing.accn)

    local chosen, why
    if filing.form:match("^8%-K") then
        -- 需要 index.json 才能找到 Exhibit 99.x
        local idx, err = self:fetch(dir .. "index.json", nil, user_agent)
        if idx then
            local ok, d = pcall(json.decode, idx)
            local files = ok and d and d.directory and d.directory.item or nil
            if files then
                chosen, why = self:pickDocument(files, filing.form, filing.primary)
            end
        else
            logger.warn("secfilings: index.json 取不到:", err)
        end
    end
    if not chosen then
        -- 非 8-K，或 index.json 不可用：直接用 primaryDocument
        chosen, why = filing.primary, "primaryDocument"
    end
    if not chosen or chosen == "" then return nil, "挑不出正文文档" end

    local url = dir .. chosen
    local body, err = self:fetch(url, nil, user_agent)
    if not body then return nil, "取文档失败: " .. tostring(err) end

    if #body > self.max_doc_bytes then
        return nil, string.format("文档过大（%.1f MB），已跳过", #body / 1048576)
    end

    return {
        html  = body,
        url   = url,
        why   = why,
        file  = chosen,
        bytes = #body,
    }
end

--- 把名字展开成「大小写不敏感」的 Lua 模式片段。
--- EDGAR 的 .htm 里这些标签时而小写、时而是 <DOCUMENT>/<TYPE> 这种大写形态，
--- 而 Lua 模式没有 i 修饰符，只能自己展开。
local function ci(name)
    local out = {}
    for i = 1, #name do
        local c = name:sub(i, i)
        if c:match("%a") then
            out[#out + 1] = "[" .. c:lower() .. c:upper() .. "]"
        else
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end

--- 去掉某个标签本身（含属性），内容留着。
--- 要求标签名后面紧跟 > 或空白，所以 <header> 不会被当成 <head> 误删。
--- 第三种写法 <font/> 必须单独处理：标签名后面直接跟斜杠，既不匹配第一种
--- （要求名字后就是 >）、也不匹配第二种（要求名字后有空白）。
--- 实测微软 10-K 的原文里留了一个空的 <font/>，于是 content.html 里长期存在
--- 一个 font 标签 —— 「表现层残留为 0」这条验收因此一直没真正达标。
local function dropTag(s, name)
    local p = ci(name)
    s = s:gsub("<%s*/?%s*" .. p .. "%s*>", "")
    s = s:gsub("<%s*/?%s*" .. p .. "%s[^>]*>", "")
    s = s:gsub("<%s*" .. p .. "%s*/>", "")
    return s
end

--- 整块删掉标签及其内容
local function dropBlock(s, name)
    return s:gsub("<" .. ci(name) .. "[%s>].-</" .. ci(name) .. "%s*>", "")
end

--- XHTML 要求空元素自闭合，而 SEC 的正文里 <br> 是裸的（实测特斯拉 exhibit
--- 里 12 个 <br> 全部没斜杠）。不补这一手，嵌进 content.html 就不良构：
--- <br> 会和后面的 </font> / </div> 对上，报 mismatched tag。
local VOID_TAGS = { "br", "hr", "col", "area", "base", "embed", "source",
                    "track", "wbr", "input", "meta", "link" }
local function selfCloseVoid(s)
    for _vi, void in ipairs(VOID_TAGS) do
        local p = ci(void)
        -- 先抹掉原有斜杠，否则 <br /> 会被后面两遍变成 <br //>
        s = s:gsub("(<%s*" .. p .. "%s[^>]-)/%s*>", "%1>")
        s = s:gsub("<%s*" .. p .. "%s*>", "<" .. void .. "/>")
        s = s:gsub("(<%s*" .. p .. "%s[^>]-)>", "%1/>")
    end
    return s
end

--- 把 HTML 的「无值属性」补成合法 XHTML：<hr noshade/> → <hr noshade="noshade"/>
--- XML 要求每个属性都必须带值，而 SEC 的 HTML 里 <hr noshade>、<td nowrap> 这种
--- 布尔属性是裸的。严格解析器（ElementTree / expat）会直接判
--- "not well-formed (invalid token)"，epub 就不合规了。
--- crengine 会把 <br> 补成 <br/>，但不会给无值属性补值，只能自己做。
--- 这里写的是真的属性小扫描器，而不是拿属性名列表去 gsub —— 后者会把
--- style="a nowrap b" 这种属性值里的词也误改。
local function fixBareAttributes(s)
    return (s:gsub("<([%a][%w_%-]*)(%s[^>]-)>", function(tag, attrs)
        local out = { "<", tag }
        -- 属性之间统一隔一个空格；原文档里可能有换行和多余缩进，顺手收干净
        local function sep()
            if out[#out] ~= " " then out[#out + 1] = " " end
        end
        local function put(tok)
            sep()
            out[#out + 1] = tok
        end
        local i, n = 1, #attrs
        while i <= n do
            local c = attrs:sub(i, i)
            if c:match("%s") then
                sep()
                i = i + 1
            else
                local name = attrs:match("^[^%s=/>]+", i)
                if not name or name == "" then
                    -- 孤立字符（比如自闭合标签末尾的 '/'），原样留着
                    out[#out + 1] = c
                    i = i + 1
                else
                    i = i + #name
                    local ws, eq = attrs:match("^(%s*)(=?)", i)
                    i = i + #ws + #eq
                    if eq == "=" then
                        local q = attrs:sub(i, i)
                        if q == '"' or q == "'" then
                            local close = attrs:find(q, i + 1, true)
                            if close then
                                put(string.format("%s=%s", name, attrs:sub(i, close)))
                                i = close + 1
                            else
                                -- 引号没合上：当成无值属性处理，至少结果是合法的
                                put(string.format('%s="%s"', name, name))
                            end
                        else
                            local val = attrs:match("^[^%s>]*", i) or ""
                            put(string.format('%s="%s"', name, val))
                            i = i + #val
                        end
                    else
                        put(string.format('%s="%s"', name, name))
                    end
                end
            end
        end
        out[#out + 1] = ">"
        return table.concat(out)
    end))
end

--- 语义 class 的唯一放行者。
---
--- 为什么需要它：stripPresentation 会把每个标签重建一遍，而验收标准是
--- 「输出里的 class 只允许 secsum 一个值」。所以重建时**不能照抄原文的 class**，
--- 只能放行我们自己在 markSubtotalLines 里加的那一个 —— 实测 SEC 原文里确实有
--- class 属性（微软 10-K 236 处），照抄就会把未知 class 带进 content.html。
--- 这样「输出 class ⊆ {secsum}」就是构造性成立的，不依赖输入干净。
local CLASS_ALLOWED = { secsum = true }

local function hasClassToken(val, tok)
    if not val then return false end
    for one in val:gmatch("[^%s]+") do
        if one:lower() == tok then return true end
    end
    return false
end

local function keepSemanticClasses(cls)
    if not cls then return nil end
    local out, seen = {}, {}
    for one in cls:gmatch("[^%s]+") do
        local low = one:lower()
        if CLASS_ALLOWED[low] and not seen[low] then
            seen[low] = true
            out[#out + 1] = low
        end
    end
    if #out == 0 then return nil end
    return table.concat(out, " ")
end

--- 给一个开标签加上 class="secsum"；已有 class 就追加，不覆盖。
---
--- 为什么要认三种引号写法（双引号 / 单引号 / 无引号）：认漏一种就会在同一个标签里
--- 再插一个 class 属性，XHTML 里同名属性重复 -> 直接不良构，整本书拒开。
--- 除了 class 那一小段，标签其余部分逐字节原样保留 —— 改动面越小，回归比对越干净。
local function mergeSecsumClass(tagtext, name)
    -- name 必须是**原文里的大小写**（调用方保证）：标签名大小写在 XHTML 里是有意义的，
    -- 把 <DIV> 改写成 <div> 会让配对的 </DIV> 变成不匹配的结束标签。
    local cases = {
        { '[Cc][Ll][Aa][Ss][Ss]%s*=%s*"([^"]*)"' },       -- 双引号
        { "[Cc][Ll][Aa][Ss][Ss]%s*=%s*'([^']*)'" },         -- 单引号
        { '[Cc][Ll][Aa][Ss][Ss]%s*=%s*([^%s>/]+)' },      -- 无引号（引号写法已在上两条排除）
    }
    for ci = 1, #cases do
        local s1, e1, v = tagtext:find(cases[ci][1])
        if s1 then
            if hasClassToken(v, "secsum") then return tagtext end
            local merged = v:match("%S") and (v .. " secsum") or "secsum"
            return tagtext:sub(1, s1 - 1) .. 'class="' .. merged .. '"' .. tagtext:sub(e1 + 1)
        end
    end
    -- 没有 class 属性：插在标签名之后，其余部分逐字节保留
    return "<" .. name .. ' class="secsum"' .. tagtext:sub(#name + 2)
end

--- 摘掉「把文字藏起来」的内联样式声明。
---
--- 为什么需要：SEC 的幻灯片类 exhibit 是用**图片**承载视觉内容的，文字层只是
--- 无障碍替代文本，被刻意写成「1pt、纯白、行高 0」。不摘掉这层样式的话，
--- 那些文字在白色纸面上完全不可见 —— 整章看起来就是空白。
--- （图片本身由 sec_images.lua 抓取，插件从波次二起会把图一起嵌进 epub。）
--- 实测微软 2026-09-02 那份 8-K 的 exhibit（d291965dex991.htm）：
---   color:#FFFFFF 22 处、font-size:1pt 44 处、line-height:0pt 22 处。
--- 去掉它们之后能读出 24965 字符，含完整的分部营收表：
---   Revenue $61,672 $64,441 $67,438 $74,576 $268,127 …
--- 也就是说替代文本层本身是完整的，只是被藏起来了。
---
--- 只摘「致盲」的声明，其余排版（对齐、字重、表格边框）原样保留。
--- 注意 Lua 模式没有大小写修饰符，所以属性名用字符类展开、属性值则取出来转小写再比。
function SecSource:unhideTextStyles(s)
    -- 白色文字：白纸上看不见。值可能写成 #FFFFFF / #fff / white / rgb(255,255,255)
    s = s:gsub("([Cc][Oo][Ll][Oo][Rr]%s*:%s*)([^;\"'>]*)", function(pre, val)
        local v = val:gsub("%s", ""):lower()
        if v == "#ffffff" or v == "#fff" or v == "white" or v == "rgb(255,255,255)" then
            return ""
        end
        return pre .. val
    end)

    -- 极小字号：低于 6pt 的一律当作隐藏层
    s = s:gsub("([Ff][Oo][Nn][Tt]%-[Ss][Ii][Zz][Ee]%s*:%s*)([^;\"'>]*)", function(pre, val)
        local n = tonumber(val:match("([%d%.]+)"))
        if n and n < 6 then return "" end
        return pre .. val
    end)

    -- 行高 0：把整段压成一条线
    s = s:gsub("([Ll][Ii][Nn][Ee]%-[Hh][Ee][Ii][Gg][Hh][Tt]%s*:%s*)([^;\"'>]*)", function(pre, val)
        local n = tonumber(val:match("^%s*([%d%.]+)"))
        if n == 0 then return "" end
        return pre .. val
    end)

    -- display:none / visibility:hidden
    s = s:gsub("[Dd][Ii][Ss][Pp][Ll][Aa][Yy]%s*:%s*[Nn][Oo][Nn][Ee]%s*;?", "")
    s = s:gsub("[Vv][Ii][Ss][Ii][Bb][Ii][Ll][Ii][Tt][Yy]%s*:%s*[Hh][Ii][Dd][Dd][Ee][Nn]%s*;?", "")

    -- 传统写法 <font color="#FFFFFF">（属性形态；不是 style 里的 color:）
    -- 先做属性形态，避免与上面的 style 声明混淆：#/white 两种拼法各来一次
    s = s:gsub("([Cc][Oo][Ll][Oo][Rr]%s*=%s*[\"']?)#?[Ff][Ff][Ff][Ff][Ff][Ff][\"']?", "")
    s = s:gsub("([Cc][Oo][Ll][Oo][Rr]%s*=%s*[\"']?)[Ww][Hh][Ii][Tt][Ee][\"']?", "")

    -- 摘完可能留下空的 style="" 或 style=";"，也一并清掉
    s = s:gsub("%s+[Ss][Tt][Yy][Ll][Ee]%s*=%s*[\"']%s*;?%s*[\"']", "")

    return s
end

--- 只保留「结构与语义」属性，其余表现层属性一律摘掉。
---
--- 为什么需要：实测微软 10-K 生成的 content.html 里有 **72106 个 style 属性**，
--- 其中 font-family 46838 次、font-size 17125 次。**内联样式优先级高于阅读器的
--- 设置**，所以用户在 KOReader 里选的字体、字号对 SEC 内容完全失效——
--- 一律按原文的 Times New Roman + 固定像素尺寸渲染；再叠加 min-width、
--- padding-left、white-space:nowrap 和大量居中（text-align 38925 次），
--- 在 6 寸屏上就会溢出、挤成一团。
---
--- 摘掉之后，字体/字号/行距/页边距全部交回阅读器控制，这才是电子书上
--- 「正确」的排版方式：读者调一下全局设置，所有书一起变。
---
--- 保留：colspan/rowspan（表格语义）、href（链接）、id（锚点）、src/alt（图片）、
--- 以及自闭合斜杠（XHTML 硬要求，丢了就不良构）。
---
--- 另外保留 class="secsum"（小计线标记，见 markSubtotalLines）：它是**语义**，
--- 不是表现层 —— 文字/结构一个字不能改的前提下，这是我们能告诉阅读器
--- 「这一行是小计」的唯一通道。但只放行白名单里的值（keepSemanticClasses），
--- 原文自带的未知 class 一律不留，否则验收的「class 白名单」立刻失效。
---
--- 特例：表格元素额外保留横向对齐。财报的会计表格靠列对齐才有可读性，
--- 而原文的 text-align 大多是给段落做居中用的，那种一律摘掉。
---
--- 另外 <font> / <span> / <center> 是纯表现层容器，摘掉标签、保留里面的文字。
function SecSource:stripPresentation(s)
    local TABLE_TAGS = {
        table = true, thead = true, tbody = true, tfoot = true,
        tr = true, td = true, th = true, caption = true, col = true, colgroup = true,
    }

    s = s:gsub("<%s*(/?)%s*([%a][%w_%-]*)([^>]*)>", function(closing, tag, attrs)
        if closing == "/" then return "</" .. tag .. ">" end

        local keep = {}

        -- 自闭合斜杠必须先认出来并保留
        local self_closed = attrs:match("/%s*$") ~= nil

        -- 表格语义
        for _ai, a in ipairs({ "colspan", "rowspan" }) do
            local v = attrs:match("[%s\"']" .. a .. "%s*=%s*[\"']?([%w_%-]+)")
            if v then keep[#keep + 1] = a .. '="' .. v .. '"' end
        end
        -- 语义 class（小计线）。必须放在「只留白名单值」的闸门后面：
        -- 原文里 class 是存在的（实测），照抄就会把未知 class 带出去。
        local cls = attrs:match("[%s\"'][Cc][Ll][Aa][Ss][Ss]%s*=%s*\"([^\"]*)\"")
            or attrs:match("[%s\"'][Cc][Ll][Aa][Ss][Ss]%s*=%s*'([^']*)'")
        local kept_cls = keepSemanticClasses(cls)
        if kept_cls then keep[#keep + 1] = 'class="' .. kept_cls .. '"' end
        -- 链接 / 锚点 / 图片
        local href = attrs:match("href%s*=%s*[\"']([^\"']*)[\"']")
        if href then keep[#keep + 1] = 'href="' .. href .. '"' end
        local id = attrs:match("id%s*=%s*[\"']([^\"']*)[\"']")
        if id then keep[#keep + 1] = 'id="' .. id .. '"' end
        for _ai, a in ipairs({ "src", "alt" }) do
            local v = attrs:match("[%s\"']" .. a .. "%s*=%s*[\"']([^\"']*)[\"']")
            if v then keep[#keep + 1] = a .. '="' .. v .. '"' end
        end

        -- 表格元素：从 style 或 align 里抽出横向对齐
        if TABLE_TAGS[tag:lower()] then
            local ta = attrs:match("text%-align%s*:%s*([%a%-]+)")
                or attrs:match("align%s*=%s*[\"']?([%a%-]+)")
            if ta and ta ~= "left" then
                keep[#keep + 1] = 'style="text-align:' .. ta .. '"'
            end
        end

        local out = "<" .. tag
        if #keep > 0 then out = out .. " " .. table.concat(keep, " ") end
        if self_closed then out = out .. "/" end
        return out .. ">"
    end)

    -- 纯表现层标签：去标签、留文字
    for _ti, t in ipairs({ "font", "span", "center" }) do
        s = dropTag(s, t)
    end

    return s
end

--------------------------------------------------------------------------
-- 宽表格列拆分：让 20 多列的 SEC 报表在 6 寸屏上排得下
--------------------------------------------------------------------------
--
-- 为什么必须做这件事
--   SEC 的财务报表在 HTML 里是 20 多列的网格（实测特斯拉 10-Q 单张表最多 57 个物理列，
--   苹果 93 张表合计 1567 列）。crengine 的表格不会横向滚动：一旦表格所需宽度超过
--   页面宽度，它就把可用宽度**平均分给每一个物理列**。用真机参数算一遍（Paperwhite 5
--   屏宽 1236px、正文栏约 1152px、字号 34、表格字号 0.85 倍）：
--       24 列 → 每列 48px，减掉单元格 padding 后内容宽只剩 19px
--   而一个「20,006」这样的数字需要约 87px。于是数字被逐字符折行，列对齐彻底丧失 ——
--   这正是用户说的「每列只剩十几像素、数字变成一堆文本」。
--   横屏也救不了：这台 Paperwhite 5 没有重力感应（/proc/bus/input/devices 只有电源键
--   与触摸屏），而且横过来正文栏只宽约 1.3 倍，而表格需要 2–4 倍。
--   删掉全空列也救不了：特斯拉 1413 个物理列里只有 318 列全空，典型大表 15 列 → 12 列，
--   只能省 7–20%。
--
-- 采用的做法：按列把一个宽表**投影**成若干张窄表，纵向堆叠
--   「投影」是这段代码的全部设计要点：对每个列块，把原表的**每一行**投影到
--   （行标签列 ∪ 本列块）上，colspan/rowspan 按投影结果重新计算。带来的三个性质：
--     1) 无损是结构性的。列块的并集覆盖了「所有出现过文字的列」，每张子表都带上全部
--        标签列，所以没有任何单元格文字会丢；也没有任何文字会被搬到错的列上。
--     2) 不需要判断「哪些行是表头」。表头行就是普通行，投影之后它自然会在每张子表里
--        重复出现，跨列的表头 colspan 也会被正确收窄（例如原来跨 9 列的表头，
--        投影到本列块的 4 列上就变成 colspan=4，文字不变）。
--     3) 语义单元不被切开：列块边界落在「表头覆盖签名」相同的列之间，也就是同一个期间
--        （例如 “Three Months Ended June 30, / 2026”）的列总在一起。
--
-- 没有选的两条路
--   · 把每一行改写成「标签: 值」的线性格式：能读，但财报的核心价值是横向比期间
--     （本季度 / 去年同期 / 半年），线性化以后这个对比关系就没了。列拆分保留了矩阵结构。
--   · 把原表缩到整页宽：那正是用户现在看到的结果，缩不动。
--
-- 作用范围与两条动作
--   · 拆列：只拆「排不下」的表。判定用表格的最小内容宽度（em）而不是列数，
--     因为 8 列窄表（都是 Yes/No）本来就能排下，拆了只会让文档变长。
--   · 投空列：即使不需要拆，只要表里存在「整列没有任何文字」的物理列，也走一遍投影
--     把它投掉。那些空列各自吃掉 1em 的单元格 padding，更要命的是表头单元格的 colspan
--     会跨在空列上 —— 空列几乎没有可用宽度，表头就会被挤成 "Thr/ee/Mon/ths" 这种
--     逐段折行。投掉之后表头才落回真正的数据列上。

--- 极小的 HTML 标签扫描器。
--- 为什么不用 gsub 一次替换：属性值里可能出现 '>'（SEC 的 style 里就有），
--- 用模式匹配会在这里切错位置，进而把整张表的结构解析歪。所以老实扫描引号状态。
---@return number|nil lt  '<' 的位置
---@return number|nil gt  '>' 的位置
local function nextTag(s, from)
    local lt = s:find("<", from, true)
    if not lt then return nil, nil end
    local i = lt + 1
    local quote
    while i <= #s do
        local ch = s:sub(i, i)
        if quote then
            if ch == quote then quote = nil end
        elseif ch == '"' or ch == "'" then
            quote = ch
        elseif ch == ">" then
            return lt, i
        end
        i = i + 1
    end
    return nil, nil
end

--- 解析一个标签文本，返回 <closing, name, attrs, selfclose>
local function parseTag(text)
    local closing = text:sub(2, 2) == "/"
    local body = closing and text:sub(3, -2) or text:sub(2, -2)
    local selfclose = body:match("/%s*$") ~= nil
    local name = body:match("^%s*([%a][%w_:%-%.]*)")
    if not name then return nil end
    local attrs = body:sub(#name + 1)
    return closing, name:lower(), attrs, selfclose
end

--- 找与 name 配对的结束标签。
--- 关键细节：找 </td> 时**必须跳过中间的嵌套 <table>…</table>**，因为嵌套表格里
--- 也有自己的 </td>，否则会提前收尾、把整张表解析歪。
---@return number|nil 结束标签之后的位置
---@return number|nil 结束标签 '<' 的位置
local function findEnd(s, name, from)
    local depth = 1
    local pos = from
    while true do
        local lt, gt = nextTag(s, pos)
        if not lt then return nil, nil end
        local closing, tname, _attrs, selfclose = parseTag(s:sub(lt, gt))
        local skip_to
        if tname and not selfclose then
            if tname == name then
                if closing then
                    depth = depth - 1
                    if depth == 0 then return gt + 1, lt end
                else
                    depth = depth + 1
                end
            elseif tname == "table" and name ~= "table" then
                skip_to = findEnd(s, "table", gt + 1)
                if not skip_to then return nil, nil end
            end
        end
        pos = skip_to or (gt + 1)
    end
end

--- 取属性值（单双引号都认，也认无引号写法）
local function attrOf(attrs, key)
    if not attrs then return nil end
    local v = attrs:match("[%s\"']" .. key .. "%s*=%s*[\"']([^\"']*)[\"']")
    if v then return v end
    return attrs:match("[%s\"']" .. key .. "%s*=%s*([^%s\"'>]+)")
end

--- 把 Unicode 码点编成 UTF-8 字节（不依赖 utf8 库：设备上的 LuaJIT 没有它）
local function utf8Char(n)
    if n < 0x80 then
        return string.char(n)
    elseif n < 0x800 then
        return string.char(0xC0 + math.floor(n / 0x40), 0x80 + (n % 0x40))
    elseif n < 0x10000 then
        return string.char(0xE0 + math.floor(n / 0x1000),
                           0x80 + (math.floor(n / 0x40) % 0x40),
                           0x80 + (n % 0x40))
    end
    return string.char(0xF0 + math.floor(n / 0x40000),
                       0x80 + (math.floor(n / 0x1000) % 0x40),
                       0x80 + (math.floor(n / 0x40) % 0x40),
                       0x80 + (n % 0x40))
end

--- 解掉数字字符引用（&#160; / &#x2014;）。
--- 设备上 crengine 通常已经解过了，但这是廉价保险：不解的话，
--- 像 &#8212;（破折号占位，特斯拉 10-Q 里有 267 处）这种会被 isNumeric 判成「文字」，
--- 于是整列数字被误判成标签列，在每张子表里重复一遍。
local function decodeNumericEntities(s)
    s = s:gsub("&#(%d+);", function(d)
        local n = tonumber(d)
        if not n or n < 32 or n > 0x10FFFF then return "" end
        return utf8Char(n)
    end)
    s = s:gsub("&#[xX](%x+);", function(h)
        local n = tonumber(h, 16)
        if not n or n < 32 or n > 0x10FFFF then return "" end
        return utf8Char(n)
    end)
    return s
end

--- 去掉标签、解掉常见实体、折叠空白 —— 用于宽度估算与数字判定
---
--- **必须把 Unicode 空白也归一化**：crengine 的 getBalancedHTML 会把 &#160; 这类
--- 实体规范化成真正的 UTF-8 字符，于是单元格文字变成 "146\194\160"。
--- Lua 的 %s 是字节类，认不出它，结果是：
---   · isNumeric("146\194\160") 判 false —— 整列数字被误判成「文字列」，
---     进而被当成行标签列，在每张子表里重复一遍（实测让 '—' 重复 111 次、'$' 重复 76 次）；
---   · 列宽估算也跟着错。
--- 所以这里按字节把常见 Unicode 空白全部换成普通空格。
local UNICODE_SPACES = {
    "\194\160", "\226\128\175", "\226\128\137", "\226\128\138",
    "\226\128\130", "\226\128\131", "\226\128\139",
}
local NAMED_ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
    nbsp = " ", mdash = "\226\128\148", ndash = "\226\128\147",
    minus = "\226\136\146", times = "\195\151", hellip = "\226\128\166",
    rsquo = "\226\128\153", lsquo = "\226\128\152",
    rdquo = "\226\128\157", ldquo = "\226\128\156",
}
local function plainText(html)
    local t = html:gsub("<[^>]*>", " ")
    t = decodeNumericEntities(t)
    for si = 1, #UNICODE_SPACES do
        t = t:gsub(UNICODE_SPACES[si], " ")
    end
    t = t:gsub("&(%a+);", function(name)
        local v = NAMED_ENTITIES[name:lower()]
        if v then return v end
        return ""
    end)
    t = t:gsub("%s+", " ")
    return t:match("^%s*(.-)%s*$")
end

--- 估算一段文字占多少 em。粗系数即可：它只用来决定「一张子表放几列」，
--- 而参数取值刻意偏保守（宁可多拆几张，也不要排不下）。
local function textEm(t)
    local em = 0
    local i, n = 1, #t
    while i <= n do
        local b = t:byte(i)
        if b < 0x80 then
            local ch = t:sub(i, i)
            if ch:match("%d") then em = em + 0.50
            elseif ch == " " then em = em + 0.28
            elseif ch == "," or ch == "." or ch == "'" then em = em + 0.25
            elseif ch:match("[A-Z]") then em = em + 0.66
            elseif ch:match("[a-z]") then em = em + 0.50
            else em = em + 0.50 end
        elseif b >= 0xF0 then em = em + 1.00; i = i + 3
        elseif b >= 0xE0 then em = em + 1.00; i = i + 2
        elseif b >= 0xC0 then em = em + 0.60; i = i + 1
        else em = em + 0.30 end
        i = i + 1
    end
    return em
end

--- 单元格的最小宽度（em）= 最长的一段「不可断开文字」。
--- 数字（含千分位、括号负数）crengine 不会在中间折行，所以它决定列的最小宽度。
local function minEm(t)
    if t == "" then return 0 end
    local best = 0
    for tok in t:gmatch("[^%s]+") do
        local e = textEm(tok)
        if e > best then best = e end
    end
    return best
end

--- 是不是数字类单元格（含货币符号、千分位、括号负数、百分号、破折号占位）
local function isNumeric(t)
    if t == "" then return false end
    local x = t:gsub("[%$%s%%]", "")
    if x == "" then return false end
    if x == "—" or x == "–" or x == "-" then return true end
    x = x:gsub("^%(", ""):gsub("%)$", "")
    x = x:gsub("^[%-–—]", "")
    if x == "" then return false end
    return x:match("^[%d,%.]+$") ~= nil
end

--- 像不像「金额」：数字位数 > 4。
--- 为什么要跟 isNumeric 分开：表头里的年份（2026 / 2025）也是数字，用「有没有数字」
--- 判断「这一行是不是数据行」会把表头行误判成数据行，于是表头签名只用到了更上面那一行 ——
--- 而那一行常常是跨全表的横幅标题（colspan=12），结果每一列的签名都一样，
--- 整张表被当成一个不可分割的组，永远拆不开（微软分部业绩表就是这样）。
local function isAmount(t)
    if not isNumeric(t) then return false end
    local digits = t:gsub("[^%d]", "")
    return #digits > 4
end

--- 把一个 <table>…</table> 解析成物理列网格。
---@param frag string            整张表的文本（含 <table> 自身）
---@param tbl_gt number          <table …> 的 '>' 在 frag 中的下标
---@return table grid { rows=, starts=, cover=, ncols= }
---   rows[r]   本行「起始」的单元格数组（按列升序）
---   starts[r][c]  r 行 c 列上有单元格起始
---   cover[r][c]   r 行 c 列被某个单元格覆盖（含跨行延伸下来的）
---   rowattrs[r]   <tr> 自己的属性串（只为了把 class="secsum" 搬过去，见 renderChunk）
local function parseTableGrid(frag, tbl_gt)
    local rows, starts, cover, rowattrs = {}, {}, {}, {}
    local ncols = 0
    local row_idx = 0
    local pos = tbl_gt + 1

    local function ensureRow(r)
        rows[r] = rows[r] or {}
        starts[r] = starts[r] or {}
        cover[r] = cover[r] or {}
    end

    while true do
        local lt, gt = nextTag(frag, pos)
        if not lt then break end
        local closing, name, attrs, selfclose = parseTag(frag:sub(lt, gt))
        pos = gt + 1
        if name == "table" then
            if closing then break end
            -- 直接挂在表体里的嵌套表格（不合规但可能出现）：整块跳过
            local after = findEnd(frag, "table", pos)
            if not after then break end
            pos = after
        elseif name == "tr" then
            if not closing then
                row_idx = row_idx + 1
                ensureRow(row_idx)
                -- 行自身的属性只留一份，给 renderChunk 搬 secsum 用（实测真实文件里
                -- <tr> 带 border-top 的情况是 0/16,517，但留这一手免得以后换公司就漏）
                rowattrs[row_idx] = attrs
            end
        elseif name == "td" or name == "th" then
            local cs = tonumber(attrOf(attrs, "colspan") or "1") or 1
            local rs = tonumber(attrOf(attrs, "rowspan") or "1") or 1
            if cs < 1 then cs = 1 end
            if rs < 1 then rs = 1 end
            local inner = ""
            if not selfclose then
                local after, endlt = findEnd(frag, name, pos)
                if after then
                    inner = frag:sub(pos, endlt - 1)
                    pos = after
                end
            end
            if row_idx == 0 then row_idx = 1 end
            ensureRow(row_idx)
            local r = row_idx
            local c = 1
            while cover[r][c] do c = c + 1 end
            local cell = {
                cs = cs, rs = rs, col = c,
                tag = (name == "th") and "th" or "td",
                attrs = attrs, inner = inner, text = plainText(inner),
            }
            rows[r][#rows[r] + 1] = cell
            starts[r][c] = cell
            for dr = 0, rs - 1 do
                local rr = r + dr
                ensureRow(rr)
                for dc = 0, cs - 1 do
                    cover[rr][c + dc] = cell
                end
            end
            if c + cs - 1 > ncols then ncols = c + cs - 1 end
        end
    end
    return { rows = rows, starts = starts, cover = cover, ncols = ncols,
             rowattrs = rowattrs }
end

--- 有文字的列（只认「起始列」）。
--- 为什么不把被 colspan 覆盖的列也算上：那样跨 3 列的标签单元格会挡住 2 个空列，
--- 让子表白白多出 2 列的宽度。只认起始列之后，标签单元格的 colspan 会被收窄成 1，
--- 文字仍然在，列数更省。
local function liveColumns(grid, nrows, ncols)
    local live = {}
    for r = 1, nrows do
        for ci = 1, #(grid.rows[r] or {}) do
            local cell = grid.rows[r][ci]
            if cell.text ~= "" then live[cell.col] = true end
        end
    end
    local out = {}
    for c = 1, ncols do
        if live[c] then out[#out + 1] = c end
    end
    return out
end

--- 是不是「像文字」的内容：必须含字母或非 ASCII 字符。
--- 为什么需要这一条：只按「不是数字」判断的话，**纯符号列**（"$"、"%"、"—"）
--- 会被当成标签列。而标签列会出现在每一张子表里，于是每张子表左边都多出一列
--- 孤零零的 $ —— 那些 $ 本来是各自紧挨着右边那个数字的，拆开就没有意义了。
local function looksLikeText(t)
    return t:match("[%a]") ~= nil or t:match("[\128-\255]") ~= nil
end

--- 行标签列：最前面那一串「像文字」的列（最多 3 列）。
--- 不硬编码成第 1 列，因为有的表前两列都是标签（科目 + 附注号）。
--- 若第一列本身就是数字（例如「年份 | 营收 | 成本」），就把第 1 列当行键，
--- 它在每张子表里重复出现 —— 不能读数字时缺了行键。
local function labelColumns(grid, nrows, live)
    local label = {}
    for ki = 1, #live do
        local c = live[ki]
        local numeric, texty, total = 0, 0, 0
        for r = 1, nrows do
            local cell = grid.starts[r] and grid.starts[r][c]
            if cell and cell.text ~= "" then
                total = total + 1
                if isNumeric(cell.text) then numeric = numeric + 1 end
                if looksLikeText(cell.text) then texty = texty + 1 end
            end
        end
        if total > 0 and numeric * 2 < total and texty * 2 >= total and #label < 3 then
            label[#label + 1] = c
        else
            break
        end
    end
    if #label == 0 and #live > 0 then label[1] = live[1] end
    return label
end

--- 相邻 live 列之间，哪些「必须留在一起」。
--- 判据：存在某一行，有一个单元格同时跨住这两列（例如 "$" 与它右边那个数字
--- 被同一行的一个 colspan=2 单元格跨住）。拆表时如果从这种缝里切下去，
--- 就会出现「一张子表里只剩 $、另一张只剩数字」的碎片。
---@return table bound[left_col] = true 表示 left_col 与它的下一个 live 列不可分
local BOUND_MAX_LIVE_COLS = 4

local function boundPairs(grid, nrows, live)
    local bound = {}
    for r = 1, nrows do
        local cells = grid.rows[r] or {}
        for ci = 1, #cells do
            local cell = cells[ci]
            if cell.cs > 1 then
                local last = cell.col + cell.cs - 1
                -- 只统计这个跨列单元格「跨住了几个 live 列」。
                -- 跨很多列的（例如跨 12 列的横幅标题 “Three Months Ended June 30,”）
                -- 不算绑定：那种横幅本来就该在每张子表里各出现一次，
                -- 把它当绑定会让整张表永远拆不开。
                local nlive = 0
                for ki = 1, #live do
                    if live[ki] >= cell.col and live[ki] <= last then nlive = nlive + 1 end
                end
                if nlive <= BOUND_MAX_LIVE_COLS then
                    for ki = 1, #live - 1 do
                        local a, b = live[ki], live[ki + 1]
                        if a >= cell.col and b <= last then bound[a] = true end
                    end
                end
            end
        end
    end
    return bound
end

--- 一组列的最小宽度（em，以表格字号为单位）。
--- 单元格左右 padding 各 0.5em，所以每列加 1.0em。
local function groupMinEm(grid, cols, nrows)
    local total = 0
    for ci = 1, #cols do
        local c = cols[ci]
        local best = 0
        for r = 1, nrows do
            local cell = grid.starts[r] and grid.starts[r][c]
            if cell then
                local e = minEm(cell.text)
                if e > best then best = e end
            end
        end
        total = total + best + 1.0
    end
    return total
end

--- 表头覆盖签名：每列在「表头行」上被哪些单元格覆盖（记它们的文字 + 起始列）。
--- 相邻列签名相同 => 属于同一个期间块，拆表时不切开。
--- 注意：签名只影响「拆得好看不好看」，不影响正确性 —— 拆在哪里都不丢数据。
local function columnSignatures(grid, nrows)
    -- 表头行 = 第一个「数字单元格 ≥ 2」的行之前的所有行。
    -- 用「数字单元格数」而不是「有没有数字」：表头里的年份（2026）本身也是数字。
    local header_last = 0
    for r = 1, nrows do
        local amounts = 0
        local row = grid.rows[r] or {}
        for ci = 1, #row do
            if isAmount(row[ci].text) then amounts = amounts + 1 end
        end
        if amounts >= 2 then
            header_last = r - 1
            break
        end
    end
    if header_last == 0 then return nil end    -- 没有独立表头行：按列逐个拆
    local sigs = {}
    for c = 1, grid.ncols do
        local parts = {}
        for r = 1, header_last do
            local cell = grid.cover[r] and grid.cover[r][c]
            if cell and cell.text ~= "" then
                parts[#parts + 1] = cell.text .. "@" .. tostring(cell.col)
            end
        end
        sigs[c] = table.concat(parts, "|")
    end
    return sigs
end

--- 把一张表规划成若干列块（每块都含全部标签列）。
---
--- 装箱的两条规则，都是为了「拆得有意义」：
---   1) 期间块（表头签名相同的相邻列）作为一个整体参与装箱，不切开。
---      例如 “Three Months Ended June 30, / 2026” 的两列必须同进同出。
---   2) 组本身放不下时才切片，而且只从「没有任何单元格同时跨住」的缝里切 ——
---      否则会把 $ 和它右边的数字拆到两张表里去。
---@return table { {cols={物理列号…}}, … }
local function planChunks(grid, nrows, live, label, opts)
    local label_set = {}
    for li = 1, #label do label_set[label[li]] = true end
    local data_cols = {}
    for ki = 1, #live do
        if not label_set[live[ki]] then data_cols[#data_cols + 1] = live[ki] end
    end
    local label_em = groupMinEm(grid, label, nrows)
    local sigs = columnSignatures(grid, nrows)
    local bound = boundPairs(grid, nrows, live)
    local max_cols, budget = opts.max_cols, opts.budget_em

    -- 期间块
    local groups = {}
    local cur = nil
    for di = 1, #data_cols do
        local c = data_cols[di]
        local sig = sigs and sigs[c] or ""
        if cur and sig ~= "" and cur.sig == sig then
            cur.cols[#cur.cols + 1] = c
        else
            cur = { sig = sig, cols = { c } }
            groups[#groups + 1] = cur
        end
    end

    local chunks, cur_cols, cur_em = {}, nil, 0
    local function flush()
        if cur_cols and #cur_cols > 0 then chunks[#chunks + 1] = { cols = cur_cols } end
        cur_cols, cur_em = nil, 0
    end
    local function place(cols, em)
        local would = ((cur_cols and #cur_cols) or 0) + #label + #cols
        if cur_cols and (cur_em + em + label_em > budget or would > max_cols) then
            flush()
        end
        if not cur_cols then cur_cols, cur_em = {}, 0 end
        for ci = 1, #cols do cur_cols[#cur_cols + 1] = cols[ci] end
        cur_em = cur_em + em
    end

    for gi = 1, #groups do
        local g = groups[gi]
        local g_em = groupMinEm(grid, g.cols, nrows)
        if label_em + g_em <= budget and #g.cols + #label <= max_cols then
            place(g.cols, g_em)
        else
            -- 整组放不下：先收掉当前块，再把组按「不可分的缝」切片逐片放。
            -- 必须按缝切，否则会出现「一张子表里只有 $、另一张只有数字」的碎片。
            flush()
            local piece = nil
            local function flushPiece()
                if piece then
                    place(piece, groupMinEm(grid, piece, nrows))
                    piece = nil
                end
            end
            for ci = 1, #g.cols do
                local c = g.cols[ci]
                local prev = piece and piece[#piece]
                if prev and bound[prev] then
                    piece[#piece + 1] = c
                else
                    flushPiece()
                    piece = { c }
                end
            end
            flushPiece()
        end
    end
    flush()

    for ci = 1, #chunks do
        local cols = {}
        for li = 1, #label do cols[#cols + 1] = label[li] end
        for di = 1, #(chunks[ci].cols) do cols[#cols + 1] = chunks[ci].cols[di] end
        table.sort(cols)
        chunks[ci].cols = cols
    end
    return chunks
end

--- 把网格按列块渲染成一张子表的 HTML。
--- 这里是「投影」真正落地的地方：逐行把单元格与列块求交，colspan 取交集的列数，
--- rowspan 重新计算成「它覆盖到的、且在本子表里保留下来的行数」。
local function renderChunk(grid, nrows, chunk)
    local keep = chunk.cols
    local keepset = {}
    for ki = 1, #keep do keepset[keep[ki]] = true end

    -- 第一遍：本行里起始于 keep 的单元格，以及它与 keep 的交集列数
    local proj, kept = {}, {}
    for r = 1, nrows do
        local cells = {}
        local has_text = false
        for ki = 1, #keep do
            local c = keep[ki]
            local cell = grid.starts[r] and grid.starts[r][c]
            if cell then
                local len = 0
                for dc = 0, cell.cs - 1 do
                    if keepset[c + dc] then len = len + 1 end
                end
                if len > 0 then
                    cells[#cells + 1] = { cell = cell, cs = len }
                    if cell.text ~= "" then has_text = true end
                end
            end
        end
        proj[r] = cells
        -- 整行投影后没有任何文字的行丢掉（原文里那种只用来定列宽的「全空定义行」）
        if #cells > 0 and has_text then kept[r] = true end
    end

    -- 第二遍：跨行单元格的输出 rowspan
    local rowspan_out = {}
    for r = 1, nrows do
        if kept[r] then
            for ci = 1, #proj[r] do
                local cell = proj[r][ci].cell
                if cell.rs > 1 and rowspan_out[cell] == nil then
                    local n = 0
                    for rr = r, math.min(r + cell.rs - 1, nrows) do
                        if kept[rr] then
                            local still = false
                            for kj = 1, #keep do
                                if grid.cover[rr] and grid.cover[rr][keep[kj]] == cell then
                                    still = true
                                    break
                                end
                            end
                            if still then n = n + 1 end
                        end
                    end
                    rowspan_out[cell] = math.max(1, n)
                end
            end
        end
    end

    local parts = { "<table>" }
    for r = 1, nrows do
        if kept[r] then
            -- <tr> 自己带的语义 class 也要搬：markSubtotalLines 在拆表**之前**跑，
            -- 它可能把标记放在 <tr> 上（实测 21 份真实文件里没出现过，但盖住这一手）。
            local tr_cls = keepSemanticClasses(
                attrOf(grid.rowattrs and grid.rowattrs[r] or "", "class"))
            parts[#parts + 1] = tr_cls and ('<tr class="' .. tr_cls .. '">') or "<tr>"
            for ci = 1, #proj[r] do
                local cell = proj[r][ci].cell
                local attrs = {}
                if proj[r][ci].cs > 1 then
                    attrs[#attrs + 1] = 'colspan="' .. proj[r][ci].cs .. '"'
                end
                if cell.rs > 1 then
                    local rs = rowspan_out[cell] or 1
                    if rs > 1 then attrs[#attrs + 1] = 'rowspan="' .. rs .. '"' end
                end
                -- 只搬「stripPresentation 会保留」的东西：锚点/链接、横向对齐，
                -- 以及语义 class（小计线）。
                -- 其余表现层属性稍后本来就会被摘掉，不必在这里重复搬运。
                -- 小计线为什么必须在这里搬：宽表正是「最需要看小计线」的那些表，
                -- 不搬的话，恰恰是它们的小计标记会全掉 —— 标记了等于没标记。
                local id = attrOf(cell.attrs, "id")
                if id then attrs[#attrs + 1] = 'id="' .. id .. '"' end
                local cell_cls = keepSemanticClasses(attrOf(cell.attrs, "class"))
                if cell_cls then attrs[#attrs + 1] = 'class="' .. cell_cls .. '"' end
                local ta = cell.attrs and cell.attrs:match("text%-align%s*:%s*([%a%-]+)")
                if not ta then ta = attrOf(cell.attrs, "align") end
                if ta and ta ~= "left" then
                    attrs[#attrs + 1] = 'style="text-align:' .. ta .. '"'
                end
                local attr_s = (#attrs > 0) and (" " .. table.concat(attrs, " ")) or ""
                parts[#parts + 1] = "<" .. cell.tag .. attr_s .. ">" .. cell.inner ..
                    "</" .. cell.tag .. ">"
            end
            parts[#parts + 1] = "</tr>"
        end
    end
    parts[#parts + 1] = "</table>"
    return table.concat(parts)
end

--- 数一张表片段里出现了几个 <table（大小写不敏感，含所有嵌套层）
local function countTables(s)
    local _, n = s:gsub("<[Tt][Aa][Bb][Ll][Ee][%s>]", "")
    return n
end

--- 处理一段 HTML 里的所有表格：排不下的拆成若干张窄表，排得下的原样保留。
--- 会递归处理 <td> 里的嵌套表格（深度上限 3，避免病态输入把耗时打爆）。
---@return string 处理后的 HTML
---@return table  统计
function SecSource:splitWideTables(s, stats, depth)
    -- 逐项补默认值：调用方传进来的是一个空表，不能指望它带齐字段
    stats = stats or {}
    stats.tables = stats.tables or 0
    stats.split = stats.split or 0
    stats.subtables = stats.subtables or 0
    stats.untouched = stats.untouched or 0
    stats.collapsed = stats.collapsed or 0
    depth = depth or 0
    if not self.table_projection then return s, stats end
    local max_cols = self.table_max_cols
    local budget = self.table_avail_em

    local out = {}
    local pos = 1
    while true do
        local lt, gt = nextTag(s, pos)
        if not lt then
            out[#out + 1] = s:sub(pos)
            break
        end
        local closing, name, _attrs, selfclose = parseTag(s:sub(lt, gt))
        out[#out + 1] = s:sub(pos, lt - 1)
        if name == "table" and not closing and not selfclose then
            local after = findEnd(s, "table", gt + 1)
            if not after then
                out[#out + 1] = s:sub(lt)
                break
            end
            local frag = s:sub(lt, after - 1)
            stats.tables = stats.tables + 1

            local grid = parseTableGrid(frag, gt - lt + 1)
            local nrows = #grid.rows
            local live = liveColumns(grid, nrows, grid.ncols)
            local label = labelColumns(grid, nrows, live)
            local total_em = groupMinEm(grid, live, nrows)
            local data_em = total_em - groupMinEm(grid, label, nrows)

            -- 需要拆吗？判据是「最小内容宽度超过了可用宽度」，不是列数本身。
            -- 8 列窄表（内容都是 Yes/No）本来就能排下，拆了只会让文档变长。
            local need = (total_em > budget)
            -- 安全闸：如果表体里存在「不属于任何单元格」的嵌套表格，
            -- 投影会把它丢掉（parseTableGrid 会整块跳过它）。这种情况下宁可不投影，
            -- 也不能丢内容。
            local nested_ok = true
            if countTables(frag) ~= 1 then
                local inner_tables = 0
                for r = 1, nrows do
                    local row = grid.rows[r] or {}
                    for ci = 1, #row do
                        inner_tables = inner_tables + countTables(row[ci].inner)
                    end
                end
                if inner_tables ~= countTables(frag) - 1 then nested_ok = false end
            end

            local fits = (total_em <= budget)
            local chunks = nil
            if #live > 0 and nested_ok then
                -- 放得下时不再受「单表列数上限」约束 —— 那个上限只是给「必须拆」的
                -- 情况兜底的安全网。否则会出现「明明放得下，却因为列数超过 6 而被
                -- 规划成 2 块」的情形，而下面的兜底分支只输出第一块，第二块的内容
                -- 就整块丢了（微软 10-K 目录页的页码就是这么消失的）。
                chunks = planChunks(grid, nrows, live, label,
                    { max_cols = fits and 1000000 or max_cols, budget_em = budget })
                -- planChunks 在「所有 live 列都被当成标签列」时会返回空表
                -- （没有数据列可分）。这时用一个覆盖全部 live 列的列块兜底，
                -- 否则下面 chunks[1] 会取到 nil。
                if #chunks == 0 then chunks = { { cols = live } } end
            end
            -- 判定只用一条：这张表的「最小内容宽度」是否超过了可用宽度。
            -- 超了就必须拆（planChunks 会给出若干列块，必须**全部**输出 ——
            --  曾经写成「need 为真才逐块输出，否则只输出第一块」，结果把第二块
            --  整块丢掉：特斯拉 10-Q 的 INDEX TO EXHIBITS 表就是这么消失的）。
            -- 没超就保留原表，但如果存在「整列没有任何文字」的物理列，仍然走一遍投影：
            --  那些空列各自吃掉 1em 的单元格 padding，更要命的是表头单元格的 colspan
            --  会跨在空列上 —— 空列几乎没有可用宽度，表头就被挤成 "Thr/ee/Mon/ths"
            --  这种逐段折行。投掉之后表头才落回真正的数据列上。
            -- 只要 planChunks 给出多于一块，就必须**逐块全部输出**；
            -- 它是按预算/列数上限算出来的，多于一块就意味着确实需要拆。
            -- 注意不要在这里再加「fits 才算需要拆」的条件 —— 那会让
            -- 兜底分支只输出第一块，把其余块整块丢掉。
            local do_split = chunks ~= nil and #chunks > 1
            local do_collapse = (not do_split) and chunks ~= nil and (grid.ncols > #live)
            need = do_split

            if do_split or do_collapse then
                -- 先递归处理单元格里的嵌套表格，再投影
                if depth < 3 then
                    for r = 1, nrows do
                        local row = grid.rows[r] or {}
                        for ci = 1, #row do
                            local cell = row[ci]
                            if countTables(cell.inner) > 0 then
                                cell.inner = self:splitWideTables(cell.inner, stats, depth + 1)
                                cell.text = plainText(cell.inner)
                            end
                        end
                    end
                end
                if do_split then
                    for chi = 1, #chunks do
                        out[#out + 1] = renderChunk(grid, nrows, chunks[chi])
                    end
                    stats.split = stats.split + 1
                    stats.subtables = stats.subtables + #chunks
                else
                    out[#out + 1] = renderChunk(grid, nrows, chunks[1])
                    stats.collapsed = stats.collapsed + 1
                end
            else
                if depth < 3 then
                    out[#out + 1] = self:splitWideTables(frag, stats, depth + 1)
                else
                    out[#out + 1] = frag
                end
                stats.untouched = stats.untouched + 1
            end
            pos = after
        else
            out[#out + 1] = s:sub(lt, gt)
            pos = gt + 1
        end
    end
    return table.concat(out), stats
end

--------------------------------------------------------------------------
-- 小计线语义标记：给原文里带 border-top 的元素加 class="secsum"
--------------------------------------------------------------------------
--
-- 为什么必须做
--   财报靠横线区分「明细」与「小计 / 合计」。原文用内联 style 的 border-top 画这些线，
--   而 stripPresentation 会把所有表现层样式摘掉（那一步是为了让用户在阅读器里
--   选的字体/字号对 SEC 内容生效）。于是子表能读了，但读者看不出哪一行是小计 ——
--   数值对不对全靠自己逐行加。文字一个字不能改的前提下，唯一还能传递这个信息的
--   通道就是 class。
--
-- 判定范围是量出来的（21 份真实文件，7 家公司 × 10-K/10-Q/8-K，见 FINDINGS「追加五」）
--   · 携带标签：<td> 16,483 次 / <div> 20 次 / <p> 14 次 / <tr> 0 次（合计 16,517）
--   · 全部出现在 style 属性里，一次也没出现在 <style> 块里
--     （<style> 块本来在第 2 步就被整块删掉了）；注释里 0 次
--   · 语义上 border-top 是「会计横线」的统称：表顶线、表头线、小计/合计线、
--     签名栏横线。契约要求按「元素自身含 border-top」判定，这里照办
--
-- 为什么认「含 border-top 子串」而不解析线宽/线型
--   契约要求覆盖各种写法（border-top: / border-top-width: / border-top-style: …），
--   而子串判定对它们一律成立。而且像微软那两处 border-top:0.5pt solid #ffffff03
--   （8 位色，alpha=3/255）在原文里本来就看不见，多标一个 class 的代价是 0。
--
-- 位置（cleanHtml 的第 9.1 步：「剥壳之后、拆表之前」）
--   · 必须在 9.2 拆表**之前**：拆表会把 <td>/<tr> 重新渲染（renderChunk），只有在
--     这之前把标记落到元素上，它才能随投影进到每一张子表里。宽表恰恰是最需要
--     小计线的那些表，先拆后标等于把标记全丢在宽表上。
--   · 必须在 9.5 stripPresentation **之前**：那一步会把 style 属性整个摘掉，
--     之后就再也认不出谁有小计线了。
--   · 与第 9 步（剥壳）的先后无所谓，放在它后面只是为了让标签扫描看到的外壳已经
--     定形。
--
-- 只加 class，不动任何文字与结构。回归证据：把预算强行设回旧默认 30 时，
-- 新旧两份代码在同一输入上的输出、去掉 class="secsum" 之后**逐字节相同**
-- （work/f2_diff.sh，见 FINDINGS「追加五」）。
--
-- 已知边界（已实测，如实记录）：
--   <font> / <span> / <center> 会被 stripPresentation 整个去标签，所以这三类元素上的
--   标记会随之消失。实测 21 份真实文件里它们一次也没携带 border-top（0/16,517）。
--
-- @return string 处理后的 HTML
-- @return number 被标记的元素个数
function SecSource:markSubtotalLines(s)
    local out, pos, n = {}, 1, 0
    while true do
        local lt, gt = nextTag(s, pos)
        if not lt then
            out[#out + 1] = s:sub(pos)
            break
        end
        out[#out + 1] = s:sub(pos, lt - 1)
        local tagtext = s:sub(lt, gt)
        local closing, name, attrs = parseTag(tagtext)
        local style
        if not closing and name then
            -- 这里不直接用 attrOf：它是大小写**敏感**的，而 SEC 里真有
            -- <DIV STYLE="...border-top...">（亚马逊 8-K 出现 20 次）。
            -- attrOf 被拆表逻辑共用（colspan/rowspan/id 一直是小写），不去改它。
            style = attrs:match("[%s\"'][Ss][Tt][Yy][Ll][Ee]%s*=%s*\"([^\"]*)\"")
                 or attrs:match("[%s\"'][Ss][Tt][Yy][Ll][Ee]%s*=%s*'([^']*)'")
        end
        -- 判定只看「style 属性里有没有 border-top 这个子串」（大小写不敏感）。
        -- 注意：标记时**必须用标签名在原文里的大小写**（parseTag 返回的是小写版）。
        -- 亚马逊 8-K 里就是 <DIV STYLE="…border-top…">，若拿小写名重建，
        -- 会得到 <div …>…</DIV> —— XHTML 标签名大小写敏感，整本书直接不良构。
        -- 这个 bug 是被新旧逐字节比对抓出来的（work/f2_diff.sh）。
        local raw_name
        if not closing and name then
            raw_name = tagtext:match("^<([%a][%w_:%-%.]*)")
            if raw_name and #raw_name ~= #name then raw_name = nil end
        end
        if style and style:lower():find("border-top", 1, true) and raw_name then
            out[#out + 1] = mergeSecsumClass(tagtext, raw_name)
            n = n + 1
        else
            out[#out + 1] = tagtext
        end
        pos = gt + 1
    end
    return table.concat(out), n
end

--- 把 SEC 那种杂乱 HTML 清理成能塞进 epub 的 XHTML 片段。
--- 顺序是有讲究的，逐条记下为什么：
---   1) BOM / <?xml ?> / <!DOCTYPE>
---   2) script / style（含内容）
---   2.5) **摘掉「致盲」样式**（1pt 白色文字、行高 0、display:none 等）。
---        SEC 的幻灯片类 exhibit 的视觉内容在图片里，文字层是无障碍替代文本，
---        被写成白字小字号；不摘掉这些样式整章就是空白。
---        见 unhideTextStyles() 的注释。
---   3) **EDGAR 信封** <document>…<text> 连值一起删（见下方注释）
---   4) **整块**删掉 XBRL 的头部与上下文（ix:header / ix:hidden /
---      xbrli:context ×357 / xbrli:unit ×15）。必须先删块、再去标签：
---      只把 ix:hidden 的标签去掉、留下文字，那就把 XBRL 隐藏元数据
---      变成脏字串摆在正文开头了（"FALSE0001318605..."）。
---   5) 剩下的带命名空间标签（ix:nonfraction ×1115、ix:nonnumeric）去掉标签、
---      保留里面的数字和文字 —— 那才是真正的报表数据。
---   6) 图片：插件不下载图片，所以直接删掉（见注释）
---   7) 空元素自闭合：XHTML 硬要求
---   8) 交给 crengine 的 getBalancedHTML 修补未闭合标签
---   9) **外壳清理必须放在 cre 之后**：实测 cre.getBalancedHTML 在输入不含
---      <html>/<body> 时会「成功返回 nil」（pcall 为 true、结果却是 nil），
---      一旦提前把外壳剥了，cre 就静默不干活，<br> 这类问题全部暴露出来。
---      而且 cre 自己还会再补一层外壳，所以剥壳只能放在它后面。
---   9.2) **宽表格按列拆分**（见 splitWideTables）：crengine 的表格排不下时会把
---      可用宽度平均分给每个物理列，24 列的报表每列只剩十几像素，数字被逐字符折行。
---      拆成若干张窄表纵向堆叠后每列都放得下。
---   9.1) **小计线语义标记**（见 markSubtotalLines）：把原文里带 border-top 的元素
---      加 class="secsum"。必须夹在 9.2 与 9.5 之间：早于 9.2 才能随投影进子表，
---      早于 9.5（剥样式）才能认出哪些元素有小计线；晚于任何一步都会丢标记。
---   9.5) **摘掉表现层属性与纯表现层标签**（见 stripPresentation）。这一步是
---      「在 Kindle 上排版正常」的关键：不摘，阅读器的字体/字号设置对 SEC
---      内容完全失效。
---  10) 无值属性补值（<hr noshade/> → noshade="noshade"）：XML 硬要求属性带值，
---      而 crengine 不会补这个，只能自己做。这一步放在最后，
---      保证交出去的字符串就是校验器看到的那一份。
---  11) 块级标签之间的残留空白收一下
-- 仅供单元测试使用的只读入口（暴露内部纯文本归一化，便于单独验证实体处理）
SecSource._plainTextForTest = nil

function SecSource:cleanHtml(raw)
    local s = raw
    local info = { images = 0 }

    -- 1) BOM / XML 声明 / DOCTYPE
    s = s:gsub("^\239\187\191", "")
    s = s:gsub("<%?.-%?>", "")
    s = s:gsub("<!DOCTYPE.->", "")

    -- 2) 脚本与样式（含内容）
    s = dropBlock(s, "script")
    s = dropBlock(s, "style")

    -- 2.5) 摘掉「致盲」样式。必须做在下一步之前，让后面所有环节看到的都是
    -- 已经显出原形的文字。这是用户反馈「微软最新 8-K 不可读」的根因。
    s = self:unhideTextStyles(s)

    -- 3) EDGAR 信封：一部分 8-K exhibit 的 .htm 不是「单个文档」，而是「整份
    -- 提交文件」的形态，外层套着
    --   <document><type>EX-99.1 <sequence>2 <filename>xx.htm <description>EX-99.1
    --   <text><html><head><title>Document</title></head><body>…真正的正文…
    -- 这些标签都无属性、值直接跟在标签后面，光去标签会把
    -- "EX-99.1 2 xx.htm EX-99.1" 留成正文开头的元数据垃圾；而里面那套
    -- <html><body> 会嵌进我们自己的 <html><body>，XHTML 直接不合法。
    s = s:gsub("<" .. ci("document") .. "%s*>.-<" .. ci("text") .. "%s*>", "")
    s = s:gsub("</" .. ci("text") .. "%s*>.-</" .. ci("document") .. "%s*>", "")

    -- 4) XBRL 头部/隐藏区/上下文/单位：整块删除。
    -- 顺序上先删外层（ix:header 可能包住 ix:hidden）
    for _bi, blk in ipairs({ "ix:header", "ix:hidden", "xbrli:context", "xbrli:unit" }) do
        s = s:gsub("<" .. blk .. "[%s>].-</" .. blk .. "%s*>", "")
    end

    -- 5) 带命名空间的标签只去标签，保留内部文字（即真实数据）
    s = s:gsub("<%s*/?%s*[%w_%.%-]+:[%w_%.%-]+[^>]*>", "")

    -- 6) 图片**保留**，只数一下有多少张。
    --
    -- 波次二**改了这里的默认行为**：插件现在会把图片抓下来嵌进 epub
    -- （sec_images.lua 负责抓、sec_epub.lua 负责打包），所以不能再无条件删掉。
    -- 删掉等于把幻灯片类 exhibit 的可见内容整块丢掉 —— 实测微软 2026-09-02
    -- 那份 8-K（22 张图）与英伟达 2026-09-03 那份都是这类文件。
    --
    -- 数量仍然要回报，有两个用途：章节说明要写「本份含 N 张图」，
    -- 以及 sec_job 的哨兵 —— 清理后 HTML 里没有 <img 却报出 images > 0，
    -- 就说明这一步被改回「删除」了，不静默出一本没图的书。
    --
    -- 删除能力保留：实例设 drop_images = true 就退回旧行为（给只想要文字的调用方）。
    -- 属性不动：src / alt 由 9.5 的 stripPresentation 保留，
    -- sec_images 要靠原始 src 去拼图片 URL，删了就没法抓。
    do
        local _, n_bare = s:gsub("<%s*[Ii][Mm][Gg]%s*>", "")
        local _, n_attr = s:gsub("<%s*[Ii][Mm][Gg][%s][^>]*>", "")
        if self.drop_images then
            s = s:gsub("<%s*[Ii][Mm][Gg]%s*>", "")
            s = s:gsub("<%s*[Ii][Mm][Gg][%s][^>]*>", "")
        end
        info.images = n_bare + n_attr
    end

    -- 7) 空元素自闭合
    s = selfCloseVoid(s)

    -- 8) 用 crengine 修补成平衡的 XHTML。
    -- 注意：必须同时看 res，不能只看 pcall 成功 —— 输入没有 <html>/<body>
    -- 时它「成功返回 nil」，那时 balanced 会静默退回未修补的原文。
    local ok, cre = pcall(require, "libs/libkoreader-cre")
    if ok and cre and cre.getBalancedHTML then
        local ok2, res = pcall(cre.getBalancedHTML, s, 0x0)
        if ok2 and res then s = res end
    end

    -- 9) 剥壳：放在 cre 之后（原因见上面第 9 条）
    s = dropBlock(s, "head")
    s = dropBlock(s, "title")
    s = s:gsub("<!DOCTYPE.->", "")
    -- html/body 外壳标签本身也要去掉，否则会嵌套
    for _ti, tag in ipairs({ "html", "head", "body" }) do
        s = dropTag(s, tag)
    end

    -- 9.2) **宽表格按列拆成若干张窄表，纵向堆叠**。
    -- 必须放在 cre 之后：cre 会把 HTML 修补成成对标签，扫描器才能可靠地解析
    --   td/tr 的嵌套关系。必须放在 markSubtotalLines（9.1）之后、stripPresentation
    --   （9.5）之前：9.1 已把语义 class 落到元素上，拆表时 renderChunk 会把它搬进
    --   每一张子表；而 9.5 之后原文的 style 就没了，再标就没依据。
    -- 为什么必须有这一步：crengine 的表格不会横向滚动，排不下就把可用宽度
    --   平均分给每个物理列。实测 24 列的表现在每列只剩 19px 内容宽，而一个
    --   数字要 87px —— 于是数字被逐字符折行，就是用户看到的「一堆文本」。
    -- 两个 do 块的先后不能写反：先 9.1 标小计线，再 9.2 拆表。写反了不会报错，
    --   但拆过的表会全部丢掉小计线标记 —— 而宽表恰恰是最需要它的那些表。

    do
        local nmarks
        s, nmarks = self:markSubtotalLines(s)
        info.subtotal_marks = nmarks
    end

    do
        local tstats = {}
        s, tstats = self:splitWideTables(s, tstats)
        info.tables     = tstats.tables or 0
        info.tables_split = tstats.split or 0
        info.subtables  = tstats.subtables or 0
        info.tables_kept = tstats.untouched or 0
        info.tables_collapsed = tstats.collapsed or 0
    end

    -- 9.5) 摘掉表现层属性，把字体/字号/行距/边距的控制权交回阅读器。
    -- 这一步必须放在 cre 之后：cre 会把 <br> 补成 <br/>，而本函数会重写
    -- 每个标签，得先让 cre 把标签形态定型（自闭合斜杠会原样保留）。
    -- 也必须放在 fixBareAttributes 之前，保证交出去的字符串就是最终结果。
    s = self:stripPresentation(s)

    -- 10) 无值属性补值。必须放在最后一步之前（cre 之后、剥壳之后），
    -- 保证交给硬校验器的就是最终字符串。
    s = fixBareAttributes(s)

    -- 11) 清掉块级元素之间残留的空白。
    -- 曾担心这会吃掉行内标签之间的空格、把单词粘连，于是在原始文档里实测过：
    -- 特斯拉 10-Q（1.57MB）里「行内闭合标签 + 空白 + 行内开标签」出现 0 次，
    -- 「行内闭合标签 + 空白 + 普通文本」也是 0 次，所以这条折叠是安全的。
    s = s:gsub(">%s+<", "><")

    return s, info
end

SecSource._plainTextForTest = plainText

return SecSource
