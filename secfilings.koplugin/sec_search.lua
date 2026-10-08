--[[
sec_search.lua —— 「公司解析 + 任意表格类型的文件清单」（纯逻辑，无 UI）

它解决什么：
  1) SecSearch:resolve(query, opts)     把 ticker / CIK / 公司名片段解析成一家公司
  2) SecSearch:listFilings(cik, opts)   列出该公司**任意**表格类型的文件
                                        （13F-HR、S-1、DEF 14A、4、SC 13D …，
                                         不再只有 8-K/10-K/10-Q）
  （这两个要用冒号调用，与 sec_source.lua 的风格一致：SecSource:fetch(...)）

为什么单独一个文件、而不是塞进 sec_source.lua：
  sec_source 只认死写的 8-K/10-K/10-Q，而且把「有哪些文件」和「抓正文 HTML」混在一条
  调用链上。搜索是另一件事：它只要元数据、不要正文，所以可以完全离线测试，
  也不该把设备/界面模块拖进来（本文件不 require 任何 ui/*）。

数据来源（都是官方接口；UA 里必须带邮箱，否则一律 403）：
  A) https://www.sec.gov/files/company_tickers.json                ticker <-> CIK 全量映射
     （实测 798727 字节 / 10434 条，顶层的键是 "0","1",... 的**字典**而不是数组）
  B) https://data.sec.gov/submissions/CIK##########.json           某公司提交索引（主文件）
     https://data.sec.gov/submissions/<files[i].name>              历史分片（同一接口的续档）

—— 四个实测出来的坑（改动前先看这里，全都已经在代码里处理）——
  1) 历史分片和主文件的 JSON **结构不一样**：
       主文件  { filings = { recent = { form = {...}, filingDate = {...}, ... } } }
       分片    { form = {...}, filingDate = {...}, ... }   <- 顶层就是那张列字典，没有包装
     按同一种结构去解析分片，只会拿到 nil，然后**静默**少掉一大半历史文件。
     见 columnDict()。
  2) 分片的 URL 必须用 JSON 里给的 files[i].name 去拼，不能自己按序号拼：
     实测 https://data.sec.gov/submissions/CIK0000019617-submissions-000.json 是 404，
     编号从 001 开始。见 listFilings 里对 name 的格式校验。
  3) 巨头公司的清单非常大：JPMorgan 主文件 recent 有 26311 条、另有 70 个分片
     （合计约 16.9 万份）；BlackRock 22 个分片；Vanguard 14 个。所以必须有上限，
     而且**上限要按用户真正要的那些表格类型来花**，否则同期的 4 号表会把 10-K 挤掉。
     见 listFilings 的「边扫边筛」策略与 max_total / max_extra_files。
  4) 同一家公司会有多个 ticker（Alphabet 4 个、Berkshire 2 个、美国银行 17 个），
     所以「按 ticker 找公司」要能返回候选列表，而不能只挑一个。见 resolve 的 aliases。

关于 pcall：
  本文件只有一处 pcall，就是包 json.decode（decodeJson 里，附带原因说明）。
  项目的禁则是「不要用 pcall 包住会 yield 的代码」（FINDINGS「Bug 2」），
  而 json.decode 是不 yield 的纯 C 调用，FINDINGS 也把它明确列为例外。
  除它以外，所有可能出错的地方一律 (结果, 错误说明) 返回值。
]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local socket = require("socket")
local logger = require("logger")

local SecSearch = {}

-- 注意：本文件所有循环都不用 `_` 做循环变量。
-- 插件顶部普遍有 `local _ = require("gettext")`，一旦写成 `for _, x in ipairs(t)`，
-- 循环体里再调 `_()` 就变成「调用一个数字」（设备上实测报
-- attempt to call local '_' (a number value)，7 家公司全部下载失败）。

-- ===========================================================================
-- 1. 可调参数（每个值都注明依据，不要凭感觉改）
-- ===========================================================================

--- SEC 要求 User-Agent 里带可联系的邮箱，否则一律 403。
--- **刻意留空**：仓库不能硬编码私人邮箱（开源后会被爬虫/垃圾邮件盯上）。
--- 由插件设置读入后传进每个调用：opts.user_agent = "Kindle SEC Reader <you@example.com>"。
--- 本机测试脚本里用的是 "Kindle SEC Reader <you@example.com>"。
SecSearch.user_agent = nil

--- 缓存目录。**由调用方注入**，本文件刻意不 require datastorage 之类的设备模块。
--- 插件里建议这样给（设备上 datastorage:getDataDir() 通常是 /mnt/us/koreader/settings）：
---     local DataStorage = require("datastorage")
---     SecSearch.cache_dir = DataStorage:getDataDir() .. "/secfilings"
--- 落盘的三个文件见 cache_files。
SecSearch.cache_dir = nil

SecSearch.ticker_url = "https://www.sec.gov/files/company_tickers.json"
SecSearch.submissions_url = "https://data.sec.gov/submissions/"

--- ticker 映射缓存的有效期。取 7 天：这份文件只在公司上市/改名/退市时变，
--- 一周一次请求完全跟得上，又不会每次搜索都去拉 780KB。
SecSearch.ticker_ttl = 7 * 24 * 60 * 60

--- 两次请求之间的最小间隔（秒）。
--- listFilings 会在几秒内连发十几个请求，而 SEC 的硬上限约 10 次/秒，
--- 超了就用 403 限流回你。0.15s ≈ 6.7 次/秒，留了余量。
SecSearch.min_interval = 0.15

--- 单次 HTTP 超时（秒）。提交索引最大见过 4.6MB（JPMorgan），所以不能按小文件设。
SecSearch.timeout = 120

--- 表格类型匹配模式，见 matchesForm：boundary（默认）/ prefix / exact。
--- 默认必须是 boundary：用 prefix 的话，用户筛 "4"（内部人交易）会连
--- 40-F、424B2、425、497 一起捞出来 —— 而 "4" 恰好是最常见的表格类型之一。
SecSearch.form_match_mode = "boundary"

--- 合并后的文件条数上限。
--- 现实取值参考：JPMorgan 一次能给出 16.9 万条，苹果只有 2264 条。
SecSearch.max_total = 20000

--- 最多额外拉几个历史分片。
--- 依据（实测 2026-10-07）：普通经营公司 ≤ 2 个（微软 2、苹果 1、特斯拉/谷歌 1），
--- 8 已经能覆盖所有普通公司；重仓机构才多（Vanguard 14、BlackRock 22、JPMorgan 70），
--- 而那些每拉一个都要一次请求，用户不会愿意为了一份 1998 年的 13F 等 70 个请求。
--- 每少拉一个分片都会记进 stats.sources_skipped，并在结果里标 truncated。
SecSearch.max_extra_files = 8

--- 公司名模糊匹配最多返回几个候选。
SecSearch.max_candidates = 20

--- 公司映射解析出来少于这么多条就认为格式变了，拒绝写缓存。
--- 实测真实值是 10434 条，留一个很宽的余量。
SecSearch.min_index_entries = 1000

--- 落盘的三个文件（都在 cache_dir 下）。
---   company_tickers.json     SEC 原文（字节等于服务器返回，可直接 diff / 排障）
---   ticker_index.tsv         从原文派生的索引，resolve 实际读的是它
---   company_tickers.meta     元信息（取回时间、条数、校验和），"缓存是否新鲜"看它
--- 为什么把原文和索引都留着：原文用于「缓存到底对不对」的核验与排障，
--- 索引用于让每次搜索不必再解析 780KB JSON（Kindle 上纯 Lua 解析这份 JSON 很慢）。
SecSearch.cache_files = {
    raw   = "company_tickers.json",
    index = "ticker_index.tsv",
    meta  = "company_tickers.meta",
}

-- ===========================================================================
-- 2. 小工具
-- ===========================================================================

--- 供守卫用：写错调用方式时给一句能照做的报错，而不是让人去猜。
--- 为什么需要：本文件里需要模块状态的函数一律定义成方法（与 sec_source.lua 一致，
--- 所以要用冒号调用 SecSearch:resolve(...)）。若误写成点号，self 会变成第一个参数，
--- 报出来的错会变成「缺少 cache_dir」之类完全对不上的信息 —— 这里把它拦成明确的提示。
local function wrongCall(self, name)
    if self ~= SecSearch then
        return nil, string.format(
            "请用冒号调用：SecSearch:%s(...)。点号调用会让 self 错位（收到的第一个参数是 %s）",
            name, type(self)), "config"
    end
    return true
end

local function trim(s)
    return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function upperTrim(s)
    return trim(s):upper()
end

local function padCik(num)
    return string.format("%010d", num)
end

--- djb2 的变体，用来做「完整性检查」而不是加密。
--- 目的很窄：发现缓存被截断/写到一半。对不上就重取。
local function checksum(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + string.byte(s, i)) % 4294967296
    end
    return h
end

--- 去掉会破坏 TSV/逐行格式的字符（制表符、换行）。
--- 实测 company_tickers.json 的 10434 个 title 里没有这些字符，
--- 但这是「供应商数据格式一变就会静默错位」的地方，宁可先清干净。
local function sanitizeField(s)
    return (tostring(s or ""):gsub("[\r\n\t]", " "))
end

--- 给 shell 参数加引号（只用于 mkdir -p，见 makeDir）。
--- 单引号包裹 + 把内部单引号转义成 '\''，这是 POSIX shell 里唯一无歧义的做法。
local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- 把字符串归一化成「只留字母数字与空格」的形式，用于公司名模糊匹配。
--- 这里**不能**直接 gsub("[^%w]", " ")：Lua 的 %w 在 C locale 下只认 ASCII，
--- 中文/带音符的公司名会被整串打成空格，查询再也不可能匹配上。
--- 所以用 gsub + 函数，把字节 >= 128 的字符（UTF-8 里的非 ASCII）原样放行。
local function normalizeText(s)
    s = tostring(s or ""):lower()
    s = s:gsub("[^%w]", function(c)
        return (string.byte(c) >= 128) and c or " "
    end)
    s = s:gsub("%s+", " ")
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

--- ticker 归一化：用户会写 BRK.B / brk-b / BRK B，SEC 里是 BRK-B。
local function normalizeTicker(s)
    return (tostring(s or ""):lower():gsub("[%s%.%-_]", ""))
end

local function isDigits(s)
    return type(s) == "string" and s ~= "" and s:match("^%d+$") ~= nil
end

--- 读整个文件；失败返回 nil, 说明。
local function readFile(path)
    local fh, oerr = io.open(path, "rb")
    if not fh then return nil, tostring(oerr) end
    local data = fh:read("*a")
    fh:close()
    if not data then return nil, "读取为空：" .. path end
    return data
end

--- 原子写：先写 .tmp 再 rename。
--- 为什么：Kindle 的 /mnt/us 是 FAT，断电/拔线随时可能发生；
--- 直接覆盖写会留下半截文件，而半截的索引比没有索引更糟（会静默少公司）。
local function writeAtomic(path, data)
    local tmp = path .. ".tmp"
    local fh, oerr = io.open(tmp, "wb")
    if not fh then return nil, tostring(oerr) end
    local ok, werr = fh:write(data)
    fh:close()
    if not ok then return nil, tostring(werr) end
    local rok, rerr = os.rename(tmp, path)
    if not rok then
        os.remove(tmp)
        return nil, tostring(rerr)
    end
    return true
end

--- 系统分区的顶级目录名。
--- 这里的写法有讲究：Lua 模式**没有** `|` 交替运算符，`"^/(usr|proc|...)"`
--- 会被当成「字面量字符串 usr|proc|...」，永远匹配不上（这个错误已经踩过一次，
--- 是测试里「应当拒绝却没拒绝」抓出来的）。所以改成取顶级目录名再查表。
local SYSTEM_DIRS = {
    usr = true, proc = true, sys = true, dev = true, etc = true,
    var = true, bin = true, sbin = true, lib = true,
}

--- 缓存目录的准入检查。
--- 设备 rootfs 只剩约 11.7MB 且 Kindle 上基本是只读的，缓存必须落在用户可见的
--- /mnt/us 下；写进 /usr 之类既可能失败也可能把系统分区挤爆，所以直接拦掉。
local function safeCacheDir(dir)
    if type(dir) ~= "string" or dir == "" then return nil, "cache_dir 为空" end
    -- 用 plain find（第 4 个参数 true）逐字符找，不要写成模式：
    -- Lua 5.1 的模式里塞 NUL 字节会直接报 malformed pattern。
    if dir:find("\n", 1, true) or dir:find("\r", 1, true) or dir:find("\0", 1, true) then
        return nil, "cache_dir 含非法字符（换行或 NUL）"
    end
    if dir:gsub("/+$", "") == "" then return nil, "cache_dir 不能是根目录" end
    local top = dir:match("^/([%w_%-%.]+)")
    if top and SYSTEM_DIRS[top:lower()] then
        return nil, "cache_dir 不能放在系统分区（/" .. top .. "）：" .. dir
            .. "；设备 rootfs 只剩约 11.7MB，请用 /mnt/us 下的路径"
    end
    return true
end

--- 建目录。
--- 这个模块刻意不 require lfs/ffi（那样就没法脱离设备测试了），
--- 而纯 Lua 没有 mkdir，所以只能借 busybox 的 mkdir -p。
--- 若 os.execute 在这个运行时里被裁掉了，就如实报错让调用方自己建目录。
local function makeDir(dir)
    local ok, err = safeCacheDir(dir)
    if not ok then return nil, err end
    if type(os.execute) ~= "function" then
        return nil, "这个运行时没有 os.execute，请调用方先创建目录：" .. dir
    end
    os.execute("mkdir -p " .. shellQuote(dir))
    return true
end

--- 写缓存文件：目录不存在就先建，再写一次。
local function writeCacheFile(dir, path, data)
    local ok, err = writeAtomic(path, data)
    if ok then return true end
    local mok, merr = makeDir(dir)
    if not mok then return nil, err .. "；建目录也失败：" .. tostring(merr) end
    return writeAtomic(path, data)
end

--- 解析 "k=v" 逐行的元信息文件。
--- 用这种格式而不是 JSON：写的时候不必 json.encode 一个 780KB 的字符串，
--- 读的时候也不必为了知道「缓存多旧」而先解析 JSON。
local function parseMeta(text)
    local t = {}
    for line in tostring(text):gmatch("[^\r\n]+") do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k then t[k] = v end
    end
    return t
end

--- 唯一一处 pcall：json.decode 是不 yield 的纯 C 调用。
--- 不用它的话，SEC 在限流/出错时回的是 HTML 错误页，json.decode 会直接抛错，
--- 把调用栈一路打断 —— 而那正是最需要好好报错的时刻。
local function decodeJson(body)
    local first = tostring(body):match("^%s*(%S)")
    if first ~= "{" and first ~= "[" then
        return nil, "响应不是 JSON（开头是 " .. tostring(first)
            .. "，多半是 SEC 的错误页或限流提示）"
    end
    local ok, data = pcall(json.decode, body)
    if not ok then return nil, "JSON 解析失败：" .. tostring(data) end
    if data == nil then return nil, "JSON 解析失败（decode 返回 nil）" end
    return data
end

-- ===========================================================================
-- 3. HTTP：重试、退避、限速
-- ===========================================================================

local last_request_at = 0

local function nowSeconds()
    -- 用 socket.gettime()（带小数的墙钟）而不是 os.time()：后者只有 1 秒精度，
    -- 限速 0.15 秒的话等于没有限速。os.clock() 也不行（它量的是 CPU 时间，不进 sleep）。
    if socket and socket.gettime then return socket.gettime() end
    return os.time()
end

local function sleepSeconds(s)
    if s and s > 0 and socket and socket.sleep then
        socket.sleep(s)
    end
end

--- 按 min_interval 限速。
local function throttle(ctx)
    local interval = ctx.min_interval
    if not interval or interval <= 0 then return end
    local elapsed = nowSeconds() - last_request_at
    if elapsed < interval then sleepSeconds(interval - elapsed) end
end

--- 发一次请求（不重试）。返回 body, 错误说明, 错误类别, 状态码。
function SecSearch:_attempt(url, ctx)
    local injected = ctx.fetch
    if injected then
        -- 注入式取数：离线测试、或换成别的传输层。契约与内置实现一致。
        local body, err, kind, status = injected(url, ctx)
        if body then return body, nil, nil, status end
        return nil, err or "注入的 fetch 失败", kind or "net", status
    end

    local ua = ctx.user_agent
    if type(ua) ~= "string" or trim(ua) == "" then
        return nil, "缺少 user_agent：SEC 要求 User-Agent 里带邮箱，否则一律 403", "config"
    end
    if not ua:find("@", 1, true) then
        return nil, "user_agent 里没有邮箱，SEC 一定会回 403：" .. ua, "config"
    end

    throttle(ctx)

    local chunks = {}
    local old_timeout = http.TIMEOUT
    http.TIMEOUT = ctx.timeout
    local ok, code = http.request{
        url = url,
        headers = {
            ["user-agent"] = ua,
            ["accept"] = "application/json",
        },
        sink = ltn12.sink.table(chunks),
    }
    http.TIMEOUT = old_timeout
    last_request_at = nowSeconds()

    local status = tonumber(code) or 0
    local body = table.concat(chunks)
    local size = #body

    if ok and status >= 200 and status < 300 and size > 0 then
        return body, nil, nil, status
    end

    if status == 404 then
        -- 404 是「这个 CIK 不存在」，重试只是浪费用户时间
        return nil, "HTTP 404（服务器没有这个资源）", "notfound", status
    end
    if status == 403 or status == 429 then
        return nil, string.format("HTTP %d（多半是 SEC 限流：请求过快或 UA 不含邮箱）", status),
            "ratelimit", status
    end
    if status >= 400 and status < 500 then
        return nil, string.format("HTTP %d", status), "http", status
    end
    if status >= 500 then
        return nil, string.format("HTTP %d（服务器侧错误）", status), "http", status
    end
    if not ok then
        return nil, string.format("网络错误（%s）", tostring(code)), "net", status
    end
    return nil, "空响应（收到 0 字节）", "net", status
end

--- 带重试与退避的 GET。返回 body, 错误说明, 错误类别。
---
--- 重试策略与 sec_source:fetch 的两点不同：
---   · 403/429 也重试（SEC 的限流就是用 403 表达的，退避一下通常就好了）；
---   · 退避时间比 sec_source 长一点，因为这里会连发十几个请求，撞上限流的概率高得多。
--- 注入的 fetch 也走这套重试：它是「一次传输」，重试属于本模块的职责。
function SecSearch:_get(url, ctx)
    local attempts = ctx.attempts
    local last_err, last_kind

    for try = 1, attempts do
        local body, err, kind = self:_attempt(url, ctx)
        if body then return body end
        last_err, last_kind = err, kind

        -- 输入/配置类错误重试再多次也不会变好
        if kind == "config" or kind == "notfound" then break end

        if try < attempts then
            local wait = math.min(try * 1.5, 6)
            if kind == "ratelimit" then wait = math.min(try * 3, 10) end
            logger.warn(string.format("sec_search: %s 第 %d 次失败（%s），%.1fs 后重试",
                url, try, tostring(err), wait))
            sleepSeconds(wait)
        end
    end

    return nil, tostring(last_err), last_kind
end

--- 把 opts 收成一份请求上下文，顺便定死默认值。
function SecSearch:context(opts)
    return {
        user_agent   = opts.user_agent or self.user_agent,
        fetch        = opts.fetch,
        timeout      = opts.timeout or self.timeout,
        attempts     = opts.attempts or 3,
        min_interval = (opts.min_interval ~= nil) and opts.min_interval or self.min_interval,
    }
end

-- ===========================================================================
-- 4. ticker 映射：缓存 + 索引
-- ===========================================================================

function SecSearch:cachePaths(cache_dir)
    local ok_call, call_err, call_kind = wrongCall(self, "cachePaths")
    if not ok_call then return nil, call_err, call_kind end
    return {
        dir   = cache_dir,
        raw   = cache_dir .. "/" .. self.cache_files.raw,
        index = cache_dir .. "/" .. self.cache_files.index,
        meta  = cache_dir .. "/" .. self.cache_files.meta,
    }
end

--- 把 company_tickers.json 解析成条目数组。
--- 顶层是 {"0":{...},"1":{...},...} 的字典，键是字符串下标 —— 不是数组，
--- 而且 pairs 的顺序不保证，所以最后按 cik/ticker 排序，让索引文件内容稳定、
--- 可以和独立实现（Python）逐行比对。
local function parseCompanyTickers(data)
    local out = {}
    for _key, v in pairs(data) do
        if type(v) == "table" then
            local num = tonumber(v.cik_str)
            if num then
                out[#out + 1] = {
                    cik    = num,
                    ticker = tostring(v.ticker or ""),
                    title  = tostring(v.title or ""),
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.cik ~= b.cik then return a.cik < b.cik end
        return a.ticker < b.ticker
    end)
    return out
end

local function buildIndexText(entries)
    local buf = {}
    for _idx, e in ipairs(entries) do
        buf[#buf + 1] = string.format("%d\t%s\t%s\n",
            e.cik, sanitizeField(e.ticker), sanitizeField(e.title))
    end
    return table.concat(buf)
end

local function countLines(text)
    local n = 0
    for _nl in text:gmatch("\n") do n = n + 1 end
    if #text > 0 and text:sub(-1) ~= "\n" then n = n + 1 end
    return n
end

--- 索引是否看起来完好：行数对不上、或首/末行解析不出来就当作坏的。
--- 刻意不做全量校验和：那是 600KB 的逐字节循环，每次搜索都做太贵。
--- 需要更强保证时传 opts.verify_cache = true（会跑完整校验和）。
local function indexLooksSane(text, meta)
    if not text or text == "" then return nil, "索引为空" end
    local want = meta and tonumber(meta.count)
    local got = countLines(text)
    if want and want ~= got then
        return nil, string.format("索引行数 %d 与记录数 %d 不符", got, want)
    end
    local first = text:match("^(%d+)\t")
    if not first then return nil, "索引首行格式不对" end
    local tail = text:match("([^\n]+)\n?$")
    if not tail or not tail:match("^(%d+)\t") then return nil, "索引末行格式不对" end
    return true
end

--- 取 ticker 索引文本（resolve 的输入）。
--- 返回 index_text, info, err, err_kind。
function SecSearch:_tickerIndex(cache_dir, opts, ctx)
    local ok_call, call_err, call_kind = wrongCall(self, "_tickerIndex")
    if not ok_call then return nil, call_err, call_kind end
    local okd, derr = safeCacheDir(cache_dir)
    if not okd then return nil, nil, derr, "config" end

    local paths = self:cachePaths(cache_dir)
    local ttl = opts.cache_ttl or self.ticker_ttl
    local now = os.time()

    local meta
    local meta_raw = readFile(paths.meta)
    if meta_raw then meta = parseMeta(meta_raw) end

    local fetched_at = meta and tonumber(meta.fetched_at)
    local age = fetched_at and (now - fetched_at) or nil
    local fresh = (age ~= nil) and (age < ttl)

    local function tryDisk()
        local text, rerr = readFile(paths.index)
        if not text then return nil, rerr end
        if opts.verify_cache then
            local want = meta and meta.index_csum
            if want and tostring(checksum(text)) ~= tostring(want) then
                return nil, "索引校验和不符（文件被改过或写坏了）"
            end
        end
        local sane, serr = indexLooksSane(text, meta)
        if not sane then return nil, serr end
        return text
    end

    if fresh and not opts.refresh then
        local text, derr2 = tryDisk()
        if text then
            return text, {
                enabled = true, hit = true, stale = false, refreshed = false,
                age_seconds = age, entries = tonumber(meta.count),
                dir = cache_dir, index_path = paths.index,
                source = "磁盘索引（未过期）",
            }
        end
        logger.warn("sec_search: 缓存看起来有效但读不出来（" .. tostring(derr2) .. "），重新取")
    end

    -- 该联网了
    if not ctx then ctx = self:context(opts) end
    local body, gerr, gkind = self:_get(self.ticker_url, ctx)
    if not body then
        -- 配置类错误（比如 UA 里没有邮箱）**不能**用旧缓存兜底：
        -- 它不会自己变好，静默降级只会让用户以为是网络问题，然后每次搜索都取不到新数据。
        -- 网络类错误则相反：用一周前那份映射也比「什么都搜不了」强，降级并标 stale。
        if gkind == "config" then return nil, nil, tostring(gerr), gkind end
        local text = tryDisk()
        if text then
            return text, {
                enabled = true, hit = true, stale = true, refreshed = false,
                age_seconds = age,
                entries = (meta and tonumber(meta.count)) or countLines(text),
                dir = cache_dir, index_path = paths.index,
                source = "磁盘索引（已过期，联网重取失败，降级使用）",
                degraded = true, refresh_error = gerr, refresh_error_kind = gkind,
            }
        end
        return nil, nil, "公司映射下载失败：" .. tostring(gerr), gkind
    end

    local data, jerr = decodeJson(body)
    if not data then return nil, nil, "公司映射解析失败：" .. tostring(jerr), "json" end

    local entries = parseCompanyTickers(data)
    if #entries < self.min_index_entries then
        -- 宁可报错也不要拿一份解析残缺的数据覆盖掉好缓存
        return nil, nil, string.format(
            "公司映射只解析出 %d 条（少于 %d），疑似 SEC 改了格式，已保持原缓存不动",
            #entries, self.min_index_entries), "json"
    end

    local index_text = buildIndexText(entries)
    local meta_text = table.concat({
        "sec_search_cache=1\n",
        "url=" .. self.ticker_url .. "\n",
        "fetched_at=" .. now .. "\n",
        "bytes=" .. #body .. "\n",
        "csum=" .. checksum(body) .. "\n",
        "count=" .. #entries .. "\n",
        "index_bytes=" .. #index_text .. "\n",
        "index_csum=" .. checksum(index_text) .. "\n",
    })

    -- 写入顺序有讲究：先写两个大文件，meta 最后写。
    -- meta 是「缓存已就绪」的标志，最后落地才不会出现「meta 说新鲜、索引却是半截」。
    local write_error
    local rok, rerr = writeCacheFile(cache_dir, paths.raw, body)
    if not rok then write_error = paths.raw .. ": " .. tostring(rerr) end
    local iok, ierr = writeCacheFile(cache_dir, paths.index, index_text)
    if not iok then
        write_error = (write_error and (write_error .. "；") or "") .. paths.index .. ": " .. tostring(ierr)
    end
    if rok and iok then
        local mok, merr = writeCacheFile(cache_dir, paths.meta, meta_text)
        if not mok then write_error = paths.meta .. ": " .. tostring(merr) end
    end

    -- 缓存写不进去只是「下次还得重下」，不影响本次结果，所以只记警告。
    if write_error then
        logger.warn("sec_search: 缓存落盘失败（下次仍能工作，只是要重新下载）：" .. write_error)
    end

    return index_text, {
        enabled = true, hit = false, stale = false, refreshed = true,
        age_seconds = 0, entries = #entries, bytes = #body,
        dir = cache_dir, raw_path = paths.raw, index_path = paths.index,
        source = write_error and "刚下载（缓存落盘失败）" or "刚下载",
        write_error = write_error,
    }
end

--- 缓存现状，给插件设置页用（显示多旧、多大、是否健康）。不联网。
function SecSearch:cacheInfo(cache_dir, opts)
    local ok_call, call_err = wrongCall(self, "cacheInfo")
    if not ok_call then return nil, call_err, "config" end
    opts = opts or {}
    cache_dir = cache_dir or opts.cache_dir or self.cache_dir
    if not cache_dir then return nil, "没有指定 cache_dir", "config" end
    local okd, derr = safeCacheDir(cache_dir)
    if not okd then return nil, derr, "config" end

    local paths = self:cachePaths(cache_dir)
    local meta_raw = readFile(paths.meta)
    local meta = meta_raw and parseMeta(meta_raw) or {}
    local index_text = readFile(paths.index)

    local function sizeOf(path)
        local fh = io.open(path, "rb")
        if not fh then return nil end
        local n = fh:seek("end")
        fh:close()
        return n
    end

    local problems = {}
    if not index_text then
        problems[#problems + 1] = "索引文件不存在：" .. paths.index
    else
        local sane, serr = indexLooksSane(index_text, meta)
        if not sane then problems[#problems + 1] = serr end
    end
    if not meta.fetched_at then problems[#problems + 1] = "元信息缺失或没有 fetched_at" end

    local fetched_at = tonumber(meta.fetched_at)
    local age = fetched_at and (os.time() - fetched_at) or nil
    local ttl = opts.cache_ttl or self.ticker_ttl
    return true, {
        dir = cache_dir,
        paths = paths,
        exists = index_text ~= nil,
        healthy = (#problems == 0),
        problems = problems,
        url = meta.url,
        fetched_at = fetched_at,
        age_seconds = age,
        ttl = ttl,
        expired = age and (age >= ttl) or false,
        entries = tonumber(meta.count),
        raw_bytes = sizeOf(paths.raw),
        index_bytes = sizeOf(paths.index),
    }
end

--- 清缓存（给插件设置页用）。
--- 返回 ok, 已删除的文件名数组, err。文件本来就不在不算错误。
function SecSearch:clearCache(cache_dir, opts)
    local ok_call, call_err = wrongCall(self, "clearCache")
    if not ok_call then return nil, nil, call_err end
    opts = opts or {}
    cache_dir = cache_dir or opts.cache_dir or self.cache_dir
    if not cache_dir then return nil, nil, "没有指定 cache_dir" end
    local paths = self:cachePaths(cache_dir)
    local removed = {}
    local targets = { paths.raw, paths.index, paths.meta,
                      paths.raw .. ".tmp", paths.index .. ".tmp", paths.meta .. ".tmp" }
    for _ti, path in ipairs(targets) do
        local fh = io.open(path, "rb")
        if fh then
            fh:close()
            os.remove(path)
            removed[#removed + 1] = path
        end
    end
    return true, removed
end

-- ===========================================================================
-- 5. 表格类型匹配
-- ===========================================================================

--- 是不是修正件（10-K/A、4/A、SC 13D/A …）。
function SecSearch.isAmendment(form)
    return tostring(form or ""):match("/A%d*$") ~= nil
end

--- 表格类型匹配。三种模式：
---   exact     只认完全一样
---   prefix    前缀匹配（"4" 会连 40-F/424B2/425 一起捞，慎用）
---   boundary  默认。完全相等，或后面紧跟边界字符（/ 空格 -）才认。
---             "10-K" 命中 10-K 与 10-K/A；"4" 命中 4 与 4/A，但不会命中 40-F、424B2；
---             "13F-HR" 命中 13F-HR/A；"S-1" 命中 S-1/A，但不命中 S-11。
--- 已知取舍：boundary 下 "10-K" 不会命中古老的 10-K405 / 8-K12B 这类变体
--- （变体直接写全名即可）。用 prefix 模式能收进来，代价是 "4" 会失控。
function SecSearch.matchesForm(form, want, mode)
    form = upperTrim(form)
    want = upperTrim(want)
    if want == "" or want == "*" then return true end
    if form == want then return true end

    mode = mode or SecSearch.form_match_mode
    if mode == "exact" then return false end
    if form:sub(1, #want) ~= want then return false end
    if mode == "prefix" then return true end

    local following = form:sub(#want + 1, #want + 1)
    return following == "/" or following == " " or following == "-"
end

--- 表格类型分布：{ {form="4", count=231}, ... }，count 降序、同数按名字升序。
function SecSearch.formSummary(entries)
    local seen = {}
    local out = {}
    for _ei, e in ipairs(entries or {}) do
        local form = e.form or ""
        if not seen[form] then
            seen[form] = { form = form, count = 0 }
            out[#out + 1] = seen[form]
        end
        seen[form].count = seen[form].count + 1
    end
    table.sort(out, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.form < b.form
    end)
    return out
end

-- ===========================================================================
-- 6. resolve —— ticker / CIK / 公司名 -> 公司
-- ===========================================================================

--- 扫一遍索引文本，返回候选数组（已按分数排序）。
--- 只扫文本、不建 10434 条的常驻表：Kindle 上内存比 CPU 更紧张。
--- 分数是分层的，顺序也刻意稳定（同分时按名字长度 / ticker / cik），
--- 否则 gmatch 的顺序会让「同一次查询」在不同机器上给出不同的首选。
local function scanIndex(index_text, query)
    local q_norm = normalizeText(query)
    local q_ticker = normalizeTicker(query)
    local wanted_cik = isDigits(query) and tonumber(query) or nil

    local cands = {}

    for line in index_text:gmatch("[^\r\n]+") do
        local cik_s, ticker, title = line:match("^(%d+)\t([^\t]*)\t(.*)$")
        local cik = cik_s and tonumber(cik_s) or nil
        if cik then
            local score, how
            if wanted_cik then
                if cik == wanted_cik then score, how = 1000, "cik" end
            elseif q_ticker ~= "" and normalizeTicker(ticker) == q_ticker then
                score, how = 1000, "ticker"
            elseif q_norm ~= "" then
                local t_norm = normalizeText(title)
                if t_norm == q_norm then
                    score, how = 900, "name"
                elseif t_norm:sub(1, #q_norm) == q_norm
                    and (t_norm:sub(#q_norm + 1, #q_norm + 1) == " " or #t_norm == #q_norm) then
                    score, how = 800, "name"
                elseif (" " .. t_norm .. " "):find(" " .. q_norm .. " ", 1, true) then
                    score, how = 600, "name"
                elseif t_norm:find(q_norm, 1, true) then
                    score, how = 400, "name"
                end
            end

            if score then
                cands[#cands + 1] = {
                    cik = cik,
                    cik_num = cik,
                    name = title,
                    ticker = (ticker ~= "" and ticker or nil),
                    score = score,
                    matched_by = how,
                    _title_len = #title,
                }
            end
        end
    end

    table.sort(cands, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a._title_len ~= b._title_len then return a._title_len < b._title_len end
        local at, bt = a.ticker or "", b.ticker or ""
        if at ~= bt then return at < bt end
        return a.cik < b.cik
    end)

    return cands
end

--- 取某个 CIK 的全部 ticker。
--- 之所以要再扫一遍：多 ticker 的行不保证挨在一起，而候选是扫完才知道的。
local function tickersOfCik(index_text, cik)
    local out = {}
    local prefix = tostring(cik) .. "\t"
    for line in index_text:gmatch("[^\r\n]+") do
        if line:sub(1, #prefix) == prefix then
            local ticker = line:match("^%d+\t([^\t]*)\t")
            if ticker and ticker ~= "" then out[#out + 1] = ticker end
        end
    end
    table.sort(out)
    return out
end

--- 把 ticker / CIK / 公司名解析成一家公司。
---
--- @param query string  "MSFT" / "msft" / "789019" / "0000789019" / "CIK0000789019" / "microsoft"
--- @param opts  table   见文件末尾的用法说明
--- @return true, result | nil, err, err_kind
---
--- result 字段：
---   query       输入（去空白后原样）
---   cik         10 位补零字符串，如 "0000789019"
---   cik_num     数字形式，如 789019（listFilings 收这个）
---   name        公司名（来自官方映射；按 CIK 查询且映射里没有时为 nil）
---   ticker      代表 ticker（可能为 nil：按 CIK 查询、或该公司没在映射里）
---   tickers     同一 CIK 的全部 ticker（Alphabet 是 4 个，Berkshire 是 BRK-A/BRK-B）
---   aliases     候选列表（**含首选**，可直接拿去渲染选择列表）
---   ambiguous   候选多于 1 个
---   tie         首选与次选同分（用户必须自己选，不能替他猜）
---   matched_by  "ticker" | "cik" | "name"
---   name_source "index" | "submissions" | "unknown"
---   cache       缓存的命中情况（hit/stale/age_seconds/...）
---
--- 数字查询（含前导零、含 "CIK" 前缀）一律当 CIK 处理，不去猜是不是别的。
function SecSearch:resolve(query, opts)
    local ok_call, call_err, call_kind = wrongCall(self, "resolve")
    if not ok_call then return nil, call_err, call_kind end
    opts = opts or {}
    if type(query) ~= "string" then return nil, "查询必须是字符串", "config" end

    local q = trim(query)
    if q == "" then return nil, "查询为空", "config" end
    -- 允许用户从浏览器地址栏直接粘 "CIK0000789019"
    q = q:gsub("^[Cc][Ii][Kk]%s*", "")

    local cache_dir = opts.cache_dir or self.cache_dir
    if not cache_dir then
        return nil, "缺少 cache_dir：ticker 映射必须缓存到磁盘"
            .. "（公司映射约 780KB，每次搜索都重下既慢又会被 SEC 限流）", "config"
    end

    local ctx = self:context(opts)
    local index_text, info, err, kind = self:_tickerIndex(cache_dir, opts, ctx)
    if not index_text then return nil, err, kind end

    local cands = scanIndex(index_text, q)

    local max_c = opts.max_candidates or self.max_candidates
    local total_cands = #cands
    local kept = {}
    for i = 1, math.min(total_cands, max_c) do kept[i] = cands[i] end

    local primary = kept[1]
    local result = {
        query = q,
        cik = nil,
        cik_num = nil,
        name = nil,
        ticker = nil,
        tickers = {},
        aliases = kept,
        candidates_total = total_cands,
        candidates_truncated = total_cands > max_c,
        ambiguous = total_cands > 1,
        tie = (kept[1] and kept[2] and kept[1].score == kept[2].score) and true or false,
        matched_by = nil,
        name_source = "unknown",
        cache = info,
    }

    if primary then
        result.cik = padCik(primary.cik_num)
        result.cik_num = primary.cik_num
        result.name = primary.name
        result.ticker = primary.ticker
        result.matched_by = primary.matched_by
        result.name_source = "index"
        result.tickers = tickersOfCik(index_text, primary.cik_num)
    elseif isDigits(q) then
        -- 合法但不在映射里的 CIK。这是**正常**情况而不是错误：
        -- company_tickers.json 只收有股票代码的注册主体（实测 10434 家），
        -- 而 SEC 的申报主体有几十万家（基金、机构、子公司都不在里面）。
        -- 例：Vanguard Group(102909)、BlackRock(1364742) 都不在映射里。
        -- 所以这里返回 ok，名字留给 listFilings 从提交索引里取（那才是权威名称），
        -- 或者用 opts.name_lookup 当场去取。
        result.cik_num = tonumber(q)
        result.cik = padCik(result.cik_num)
        result.matched_by = "cik"
    else
        return nil, string.format("没有找到匹配的公司：%s（ticker、CIK 或公司名片段都可以）", q),
            "no_match"
    end

    -- 可选：当场用提交索引取权威名称（会多一次网络请求，默认关）
    if opts.name_lookup and result.name_source == "unknown" then
        local body, gerr, gkind = self:_get(
            self.submissions_url .. "CIK" .. result.cik .. ".json", ctx)
        if body then
            local data = decodeJson(body)
            if type(data) == "table" then
                if type(data.name) == "string" and data.name ~= "" then
                    result.name = data.name
                    result.name_source = "submissions"
                end
                if type(data.tickers) == "table" and #data.tickers > 0 then
                    result.tickers = data.tickers
                    result.ticker = result.tickers[1]
                end
            end
        else
            -- 取不到名字不影响「CIK 本身解析对了」这件事，只记下来
            result.name_lookup_error = tostring(gerr)
            result.name_lookup_error_kind = gkind
        end
    end

    return true, result
end

-- ===========================================================================
-- 7. listFilings —— 任意表格类型的文件清单
-- ===========================================================================

--- 解析 CIK 输入（数字或字符串，允许前导零与 "CIK" 前缀）。
local function parseCikInput(cik)
    if type(cik) == "number" then
        if cik < 1 or cik > 9999999999 or cik ~= math.floor(cik) then
            return nil, "CIK 数值超出范围：" .. tostring(cik)
        end
        return cik
    end
    if type(cik) ~= "string" then return nil, "CIK 必须是数字或数字字符串" end
    local s = trim(cik):gsub("^[Cc][Ii][Kk]%s*", "")
    if not isDigits(s) then return nil, "CIK 必须是纯数字（收到 " .. cik .. "）" end
    local num = tonumber(s)
    if not num or num < 1 or num > 9999999999 then
        return nil, "CIK 数值超出范围：" .. cik
    end
    return num
end

local ISO_DATE = "^%d%d%d%d%-%d%d%-%d%d$"

--- 把 opts 里的筛选条件整理好并校验。
local function buildFilter(opts)
    -- 修正件开关不能用 `(opts.amendments ~= nil) and opts.amendments or true` 那种写法：
    -- Lua 里 false 是「假」，于是 `true and false or true` 会变成 true，
    -- 用户传 amendments=false（排除 /A）会被**静默忽略**。
    -- 这个写法已经真踩过一次，是测试里「amendments=false 却仍然出现 10-K/A」抓出来的。
    local amendments = true
    if opts.amendments ~= nil then amendments = opts.amendments end

    local f = {
        forms = nil,
        forms_raw = opts.forms,
        since = opts.since,
        -- 注意：结束日期刻意叫 to 而不是 until ——
        -- `until` 是 Lua 保留字，opts.until 和 {until = ...} 都写不出来（语法错误）。
        -- （仍兼容调用方用方括号写法传的老名字 opts["until"]。）
        to = opts.to or opts["until"],
        limit = opts.limit,
        amendments = amendments,
        max_total = opts.max_total or SecSearch.max_total,
        max_extra_files = (opts.max_extra_files ~= nil) and opts.max_extra_files
            or SecSearch.max_extra_files,
        mode = opts.form_match_mode or SecSearch.form_match_mode,
    }

    if type(f.forms_raw) == "string" then
        f.forms = { f.forms_raw }
    elseif type(f.forms_raw) == "table" then
        f.forms = {}
        for _fi, v in ipairs(f.forms_raw) do
            if type(v) == "string" and trim(v) ~= "" then
                f.forms[#f.forms + 1] = upperTrim(v)
            end
        end
        if #f.forms == 0 then f.forms = nil end
    elseif f.forms_raw ~= nil then
        return nil, "opts.forms 必须是字符串或字符串数组"
    end

    if f.since ~= nil and (type(f.since) ~= "string" or not f.since:match(ISO_DATE)) then
        return nil, "opts.since 要写成 YYYY-MM-DD（收到 " .. tostring(f.since) .. "）"
    end
    if f.to ~= nil and (type(f.to) ~= "string" or not f.to:match(ISO_DATE)) then
        return nil, "opts.to 要写成 YYYY-MM-DD（收到 " .. tostring(f.to) .. "）"
    end
    if f.limit ~= nil and (type(f.limit) ~= "number" or f.limit < 1) then
        return nil, "opts.limit 必须是 >= 1 的数字"
    end
    if f.amendments ~= true and f.amendments ~= false and f.amendments ~= "only" then
        return nil, 'opts.amendments 只能是 true / false / "only"'
    end
    if type(f.max_total) ~= "number" or f.max_total < 1 then
        return nil, "max_total 必须是 >= 1 的数字"
    end
    if type(f.max_extra_files) ~= "number" or f.max_extra_files < 0 then
        return nil, "max_extra_files 必须是 >= 0 的数字"
    end
    return f
end

local function passesFormFilter(flt, form)
    if flt.forms then
        local hit = false
        for _wi, want in ipairs(flt.forms) do
            if SecSearch.matchesForm(form, want, flt.mode) then
                hit = true
                break
            end
        end
        if not hit then return false end
    end
    local is_amend = SecSearch.isAmendment(form)
    if flt.amendments == false and is_amend then return false end
    if flt.amendments == "only" and not is_amend then return false end
    return true
end

local function passesDateFilter(flt, date)
    if flt.since and (date == "" or date < flt.since) then return false end
    if flt.to and (date == "" or date > flt.to) then return false end
    return true
end

--- 取一列的值。
--- 分片里可能整个字段都缺（老文件的 items / primaryDocDescription 常常是空数组），
--- 也可能某个下标没有值，所以这里要整体判空、不能假定列一定存在。
local function col(cols, name, i)
    local arr = cols[name]
    if type(arr) ~= "table" then return nil end
    return arr[i]
end

--- 从 submissions 的「列字典」里吸收一批记录。
---
--- 这就是坑 1 的处理点：主文件和分片的 JSON 结构不同，但真正的负载是同一张
--- 「列名 -> 数组」的字典，两种形状都归一到这里再处理（归一在 columnDict 里）。
---
--- 「边扫边筛」而不是「先全收再过滤」是刻意的：JPMorgan 那种 recent 有 26311 条的
--- 公司，如果先全收，等于把两万多条记录连 8 个字段全建出来塞进内存，
--- 而用户可能只想要 10-K。所以 form/日期先过一遍，只有要留下的才建完整记录。
local function absorbColumns(cols, st, flt)
    local forms = cols and cols.form
    if type(forms) ~= "table" then return 0 end

    local added = 0
    for i = 1, #forms do
        local form = tostring(forms[i] or "")
        local date = tostring(col(cols, "filingDate", i) or "")
        local accn = tostring(col(cols, "accessionNumber", i) or "")

        -- 去重键用 accessionNumber：recent 与分片的日期窗口是相邻的，
        -- 边界处理论上可能重叠，重叠就会让同一份文件被数两次
        -- （form_summary 会因此虚高 —— 正是那类「不报错的错」）。
        local dupe = false
        if accn ~= "" then
            if st.seen[accn] then dupe = true else st.seen[accn] = true end
        end

        if dupe then
            st.duplicates = st.duplicates + 1
        else
            st.scanned = st.scanned + 1
            st.form_counts[form] = (st.form_counts[form] or 0) + 1

            if st.matched >= flt.max_total then
                st.budget_full = true
                return added
            end

            if passesFormFilter(flt, form) and passesDateFilter(flt, date) then
                st.entries[#st.entries + 1] = {
                    form = form,
                    filing_date = date,
                    report_date = tostring(col(cols, "reportDate", i) or ""),
                    accession_number = accn,
                    primary_document = tostring(col(cols, "primaryDocument", i) or ""),
                    primary_doc_description = tostring(col(cols, "primaryDocDescription", i) or ""),
                    items = tostring(col(cols, "items", i) or ""),
                    size = tonumber(col(cols, "size", i)) or 0,
                }
                st.matched = st.matched + 1
                added = added + 1
            end
        end
    end
    return added
end

--- 主文件/分片都可能是这两种形状之一，统一取出列字典。
local function columnDict(data)
    if type(data) ~= "table" then return nil end
    local f = data.filings
    if type(f) == "table" then
        if type(f.recent) == "table" and type(f.recent.form) == "table" then
            return f.recent            -- 主文件形状
        end
        if type(f.form) == "table" then
            return f                   -- 少见但合法：filings 本身就是列字典
        end
    end
    if type(data.form) == "table" then
        return data                    -- 分片形状（顶层就是列字典）
    end
    return nil
end

local function sortDesc(entries)
    table.sort(entries, function(a, b)
        if a.filing_date ~= b.filing_date then return a.filing_date > b.filing_date end
        -- 同一天有多份时，accession number 里含提交时间，用它做稳定的次级排序
        return a.accession_number > b.accession_number
    end)
end

--- 列出某公司**任意表格类型**的文件。
---
--- @param cik  number|string  789019 / "0000789019" / "CIK0000789019"
--- @param opts table           见文件末尾的用法说明
--- @return true, filings | nil, err, err_kind
---
--- filings 字段：
---   cik / cik_num / name / tickers   公司信息（name 来自提交索引，是权威名称）
---   entries      文件数组，按日期倒序；每项 8 个字段见 absorbColumns
---   total        扫到的记录条数（未按表格类型过滤）
---   matched      entries 的条数
---   truncated    是否被 max_total / max_extra_files / limit 截断（截断=会少文件，必须让用户知道）
---   form_summary 表格类型分布 { {form=, count=}, ... }，基于扫到的全部类型
---   form_summary_scope  "full"(全部历史都扫了) / "since_window"(只扫了 since 之后的窗
---                      口，因为用户只要这段) / "partial"(被上限截断或有分片取不到)
---   stats        计数细节（scanned/matched/duplicates/sources_*/budget_full/...）
---   source_errors 取不到的分片（不影响整体结果，只记下来）
---   filter       实际生效的筛选条件回显
function SecSearch:listFilings(cik, opts)
    local ok_call, call_err, call_kind = wrongCall(self, "listFilings")
    if not ok_call then return nil, call_err, call_kind end
    opts = opts or {}
    local cik_num, cerr = parseCikInput(cik)
    if not cik_num then return nil, cerr, "config" end

    local flt, ferr = buildFilter(opts)
    if not flt then return nil, ferr, "config" end

    local cik10 = padCik(cik_num)
    local ctx = self:context(opts)

    local url = self.submissions_url .. "CIK" .. cik10 .. ".json"
    local body, gerr, gkind = self:_get(url, ctx)
    if not body then
        if gkind == "notfound" then
            return nil, "SEC 没有 CIK " .. cik10 .. " 的提交索引（这个编号不存在）", "notfound"
        end
        return nil, "submissions: " .. tostring(gerr), gkind
    end

    local data, jerr = decodeJson(body)
    if not data then return nil, "submissions: " .. tostring(jerr), "json" end

    local main_cols = columnDict(data)
    if not main_cols then
        return nil, "submissions 里找不到文件列表（结构与预期不符）", "json"
    end

    local out = {
        cik = cik10,
        cik_num = cik_num,
        name = (type(data.name) == "string" and data.name ~= "") and data.name or nil,
        tickers = (type(data.tickers) == "table") and data.tickers or {},
        entries = {},
        total = 0,
        matched = 0,
        truncated = false,
        form_summary = {},
        form_summary_partial = false,
        source_errors = {},
        filter = {
            forms = flt.forms,
            forms_raw = flt.forms_raw,
            since = flt.since,
            to = flt.to,
            limit = flt.limit,
            amendments = flt.amendments,
            form_match_mode = flt.mode,
            max_total = flt.max_total,
            max_extra_files = flt.max_extra_files,
        },
    }

    local st = {
        entries = out.entries,
        seen = {},
        form_counts = {},
        scanned = 0,
        matched = 0,
        duplicates = 0,
        budget_full = false,
    }

    absorbColumns(main_cols, st, flt)

    -- ---- 历史分片 ----
    -- 分片按「新 -> 旧」排列（实测 JPMorgan 的 001 最新、070 最旧），
    -- 所以从头顺着拿就是在拿最近的那段历史。
    local files = (type(data.filings) == "table" and type(data.filings.files) == "table")
        and data.filings.files or {}
    local src = {
        sources_total = 1 + #files,
        sources_used = 1,
        sources_skipped = 0,
        sources_failed = 0,
        stopped_by_since = false,
    }

    for _fi, fdesc in ipairs(files) do
        if st.budget_full then
            out.truncated = true
            src.sources_skipped = #files - (_fi - 1)
            break
        end
        if (src.sources_used - 1) >= flt.max_extra_files then
            out.truncated = true
            src.sources_skipped = #files - (_fi - 1)
            break
        end
        -- 分片的覆盖区间是 [filingFrom, filingTo]。整段都比 since 旧的话，
        -- 后面的（更旧的）就更不必拉了 —— 这一步能把整轮请求省掉。
        local to_date = (type(fdesc) == "table") and fdesc.filingTo or nil
        if flt.since and type(to_date) == "string" and to_date < flt.since then
            src.stopped_by_since = true
            -- 这一批（以及更旧的）落在用户要的时间窗之外，不算「漏了东西」，
            -- 所以不置 truncated，只计入 skipped 并把原因说清楚（stopped_by_since）。
            src.sources_skipped = #files - (_fi - 1)
            break
        end

        local name = (type(fdesc) == "table") and fdesc.name or nil
        -- 只用 JSON 给的名字拼 URL，并且校验格式：
        -- 自己按序号拼是错的（实测 ...-submissions-000.json 是 404，编号从 001 起），
        -- 而名字来自远端数据，直接塞进 URL 也不放心。
        if type(name) == "string" and name:match("^CIK%d+%-submissions%-%d+%.json$") then
            local xbody, xerr, xkind = self:_get(self.submissions_url .. name, ctx)
            if xbody then
                local xdata, xjerr = decodeJson(xbody)
                local xcols = xdata and columnDict(xdata)
                if xcols then
                    absorbColumns(xcols, st, flt)
                    src.sources_used = src.sources_used + 1
                else
                    src.sources_failed = src.sources_failed + 1
                    out.source_errors[#out.source_errors + 1] = {
                        name = name, error = "解析失败：" .. tostring(xjerr),
                    }
                end
            else
                -- 单个分片失败不该让整张清单失败：记下来继续，
                -- 结果里的 truncated 会让用户知道这段历史缺了。
                src.sources_failed = src.sources_failed + 1
                out.truncated = true
                out.source_errors[#out.source_errors + 1] = {
                    name = name, error = tostring(xerr), err_kind = xkind,
                }
                logger.warn("sec_search: 分片取不到 " .. name .. "：" .. tostring(xerr))
            end
        else
            src.sources_failed = src.sources_failed + 1
            out.source_errors[#out.source_errors + 1] = {
                name = tostring(name), error = "分片名不符合预期格式，已跳过",
            }
        end
    end

    if st.budget_full then out.truncated = true end

    sortDesc(out.entries)

    local matched_before_limit = st.matched
    if flt.limit and #out.entries > flt.limit then
        local kept = {}
        for i = 1, flt.limit do kept[i] = out.entries[i] end
        out.entries = kept
        out.truncated = true
    end

    out.matched = #out.entries
    out.matched_before_limit = matched_before_limit
    out.total = st.scanned
    out.duplicates_dropped = st.duplicates
    out.form_summary = SecSearch.formSummary(out.entries)

    -- 扫到的全部表格类型（不受 forms 过滤影响）：用户最需要的那张「这家都申报些什么」的表
    local all = {}
    for form, n in pairs(st.form_counts) do all[#all + 1] = { form = form, count = n } end
    table.sort(all, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.form < b.form
    end)
    out.form_summary_all = all
    -- 分布是否完整：截断过或丢过分片，就说明用户要的东西可能缺；
    -- 因 since 提前收工不算缺（那些本来就在时间窗之外），但分布只覆盖时间窗，要说明。
    out.form_summary_partial = out.truncated or src.sources_failed > 0
    if out.form_summary_partial then
        out.form_summary_scope = "partial"
    elseif src.stopped_by_since then
        out.form_summary_scope = "since_window"
    else
        out.form_summary_scope = "full"
    end

    out.stats = {
        scanned = st.scanned,
        matched = st.matched,
        duplicates_dropped = st.duplicates,
        sources_total = src.sources_total,
        sources_used = src.sources_used,
        sources_skipped = src.sources_skipped,
        sources_failed = src.sources_failed,
        stopped_by_since = src.stopped_by_since,
        budget_full = st.budget_full,
    }
    return true, out
end

--- 便捷：某份文件的归档目录（与 sec_source:archiveDir 同一规则）
function SecSearch.archiveDir(cik, accession)
    local num = type(cik) == "number" and cik or tonumber(tostring(cik):gsub("%D", ""))
    if not num then return nil, "CIK 不合法" end
    return string.format("https://www.sec.gov/Archives/edgar/data/%d/%s/",
        num, tostring(accession):gsub("%-", ""))
end

--- 便捷：文件主文档的完整 URL（只算 URL，不下载 —— 抓正文是 sec_source 的职责）
function SecSearch.entryUrl(cik, entry)
    if type(entry) ~= "table" or not entry.accession_number or not entry.primary_document then
        return nil, "entry 缺少 accession_number / primary_document"
    end
    local dir, derr = SecSearch.archiveDir(cik, entry.accession_number)
    if not dir then return nil, derr end
    return dir .. tostring(entry.primary_document)
end

-- ===========================================================================
-- 8. 用法（返回值字段说明见各函数上方的注释）
-- ===========================================================================
--
--   local SecSearch = require("sec_search")
--   SecSearch.user_agent = "Kindle SEC Reader <you@example.com>"   -- 必填，带邮箱
--   SecSearch.cache_dir  = "/mnt/us/koreader/settings/secfilings"  -- 必填，可写目录
--
--   -- 1) 解析公司（缓存没过期就不联网）
--   local ok, res, err, kind = SecSearch:resolve("apple")
--   -- res.cik_num / res.name / res.ticker / res.tickers / res.aliases
--   if ok and res.ambiguous then          -- 渲染成选择列表，让用户自己挑
--       for _ci, cand in ipairs(res.aliases) do
--           print(cand.ticker, cand.name, cand.cik)
--       end
--   end
--
--   -- 2) 列文件（任意表格类型）
--   local ok2, list, err2 = SecSearch:listFilings(res.cik_num, {
--       forms = { "13F-HR", "S-1", "DEF 14A" },   -- nil = 全部类型
--       since = "2020-01-01",                     -- 可选
--       limit = 50,                               -- 可选（排序后截断）
--   })
--   if ok2 then
--       print(list.name, list.matched, list.truncated)
--       for _ei, e in ipairs(list.entries) do
--           print(e.filing_date, e.form, e.primary_document)
--       end
--   end
--
--   -- 3) 设置页：看缓存 / 清缓存
--   local ok3, info = SecSearch:cacheInfo()
--   local ok4, removed = SecSearch:clearCache()
--
-- 调用方式（两类别混用会得到明确的报错提示，不会静默出错）：
--   需要模块状态或会发请求的：冒号调用 —— SecSearch:resolve / :listFilings /
--                                              :cacheInfo / :clearCache / :cachePaths
--   纯函数（无状态、无 IO）：   点号调用 —— SecSearch.matchesForm / .isAmendment /
--                                              .formSummary / .archiveDir / .entryUrl
--
-- opts 汇总（resolve / listFilings 通用）：
--   user_agent       必填（有网络请求时）；SEC 要求 UA 里带邮箱
--   cache_dir        必填（resolve）；ticker 映射的缓存目录
--   refresh          true = 忽略过期时间，强制重取映射
--   cache_ttl        覆盖 SecSearch.ticker_ttl
--   verify_cache     true = 读索引时跑完整校验和（慢一点，用来排除静默损坏）
--   max_candidates   模糊匹配最多给几个候选
--   name_lookup      resolve 时是否用提交索引补权威名称（多一次请求，默认关）
--   fetch            function(url, ctx) -> body, err, kind, status
--                    注入式取数：离线测试、或换传输层。
--                    （重试仍由本模块负责，注入的函数只需发一次请求）
--   timeout / attempts / min_interval   覆盖默认的网络参数
--   forms            {"10-K","13F-HR"} 或 "10-K"；nil = 全部表格类型
--   since / to       "YYYY-MM-DD"（结束日期叫 to —— until 是 Lua 保留字，写不出来）
--   limit            最终截断条数（排序之后）
--   amendments       true(默认，含修正件) / false(排除 /A) / "only"(只要 /A)
--   form_match_mode  "boundary"(默认) / "prefix" / "exact"，见 matchesForm
--   max_total        合并后的条数上限（默认 20000）
--   max_extra_files  最多拉几个历史分片（默认 8）
--
-- 错误类别（第三个返回值，便于界面分类处理）：
--   "config"     输入/配置不对（空查询、CIK 不是数字、缺 UA、缺 cache_dir、日期格式…）
--   "no_match"   公司名没匹配到任何一家
--   "notfound"   SEC 没有这个 CIK
--   "net"        网络层失败（重试后仍失败）
--   "ratelimit"  SEC 限流（403/429，已退避重试过）
--   "http"       其他 HTTP 错误
--   "json"       响应不是预期的 JSON（SEC 换了格式，或在回错误页）
--
-- 缓存落盘（cache_dir 下三个文件，细节见 cache_files 上的注释）：
--   company_tickers.json    SEC 原文，字节等于服务器返回
--   ticker_index.tsv        "cik\tticker\ttitle\n" 逐行；resolve 实际读它
--   company_tickers.meta    k=v 逐行：url / fetched_at / bytes / csum / count /
--                           index_bytes / index_csum
--   写盘一律先写 .tmp 再 rename（FAT 上断电不会留下半截文件），
--   meta 最后写（它是「缓存已就绪」的标志）。

return SecSearch
