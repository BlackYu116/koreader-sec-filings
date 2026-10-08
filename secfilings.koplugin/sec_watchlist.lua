--[[
sec_watchlist.lua —— 关注列表 + 增量判定 + 阅读进度保留。

这个文件为什么单独存在
  插件原来一次只下「固定 7 家公司 × 固定份数」，用户既不能增删关注对象，也不能只抓
  新文件。把这两件事放进 UI 层会重犯上一轮的错（逻辑和界面糊在一起，只能靠手点菜单
  验证），所以这里做成一个**纯逻辑模块**：
    * 不 require 任何 `ui/*`、不 require 设备模块（`lfs` 是按需懒加载、拿不到就退化成
      shell，见 getLfs）；
    * 不用 `pcall` 包任何可能 yield 的代码（KOReader 的 Trapper:info 内部
      coroutine.yield，LuaJIT 禁止跨 pcall yield），错误一律用 `(ok, err)` 返回值传；
    * 循环变量绝不叫 `_`（本文件顶层没有 gettext，但调用方有；保持同一套纪律）。

它提供三块能力：
  1. 关注列表存储：load / save / list / add / remove / toggle。
     文件是**段落式 Lua 表**，KOReader 的 LuaSettings 能读，人也能直接改。
  2. 增量判定：planUpdates(watchlist, fetched, opts) 算出「这次该下哪些新文件」。
     去重按 accession_number（不是文件名、不是日期）。
  3. 阅读进度保留：keepProgress / restoreProgress。
     重新打包会把 `.sdr` 清掉，用户反复更新时阅读进度归零是不可接受的副作用；
     这里给出「保留外观设置 + 重置位置」和「按内容增量平移位置」两种策略。

=== 关于 `.sdr` 的三条硬事实（都核过源码/设备证据，不是猜的）===

  A) 侧车目录名。设备（KOReader v2026.07.2）上 `settings.reader.lua` 里是
     `["document_metadata_folder"] = "doc"`，而 v2026.07.2 的
     `frontend/docsettings.lua:getSidecarDir()` 在 "doc" 模式下会**去掉最后一个扩展名**：
         path = doc_path:match("(.*)%.")   -->  "/…/微软 SEC 财报"
         return path .. ".sdr"            -->  "/…/微软 SEC 财报.sdr"
     元数据文件名由 `getSidecarFilename()` 给出：`"metadata." .. 扩展名 .. ".lua"`
     → `metadata.epub.lua`。
     设备上的真实路径见 FINDINGS.md（`/mnt/us/documents/SEC 财报/微软 SEC 财报.sdr/
     metadata.epub.lua`）。注意 FINDINGS 另一处写的 `xxx.epub.sdr` 是**错的**，
     本文按 `<书>.sdr` 为主、`<书>.epub.sdr` 兼容旧写法，两处都处理。

  B) KOReader **不会**在打开时校验 `partial_md5_checksum`。v2026.07.2 的
     `frontend/apps/reader/readerui.lua:497` 只在它为空时写入，从不比较。所以内容
     换了而 `.sdr` 还在，旧位置会被**照原样套用**——这就是必须做处理的原因（现有
     `sec_epub.lua` 用 purgeDir 整个删掉，等于进度归零）。
     另外 `frontend/util.lua:partialMD5` 是对 256B/1KB/4KB/16KB/64KB/256KB/1MB… 处各取
     1024 字节做哈希，「在文件前面垫一段不变的字节让哈希不变」这条路**行不通**，
     不要尝试。

  C) 清位置时必须**连带清 `cre_dom_version`**。`readerrolling.lua:170` 的逻辑是：
     如果没有 `cre_dom_version` 但**有** `last_xpointer`，就按「很久以前打开过的老书」
     处理，主动请求**最老的 DOM 版本**。我们重建的是全新内容，留着旧的
     `cre_dom_version` 会让 crengine 用错 DOM 版本；而只清 `last_xpointer`
     又会触发上面那条老书分支。所以两个一起清。

=== 列表文件长什么样（可以手改）===

  -- sec_watchlist.lua —— 关注列表
  return {
      ["entries"] = {
          [1] = {
              ["cik"] = "0000320193",
              ["enabled"] = true,
              ["first_run_done"] = true,
              ["forms"] = { "10-K", "10-Q" },
              ["keep_seen"] = 200,
              ["last_accession"] = "0000320193-26-000045",
              ["last_checked_at"] = 1791234567,
              ["last_filing_date"] = "2026-08-01",
              ["name"] = "苹果",
              ["seen"] = { "0000320193-26-000045" },  -- 基线之上已下过的，新在前，上限 200
              ["seen_upto_date"] = "2026-09-15", -- 基线：早于这一天的历史一律不补
              ["ticker"] = "AAPL",
          },
      },
      ["keep_seen"] = 200,
      ["updated_at"] = 1791234567,
      ["user_modified_at"] = 1791234567,
      ["version"] = 1,
  }

  手工加一家：把上面那 `[1] = {...}` 整段复制一份，改 cik / name / ticker 就行。
  只关心某几类表：`["forms"] = { "10-Q" }`；想恢复默认三类：把 forms 整个删掉。
  不想再自动下这家：`["enabled"] = false`（或直接删掉这段）。
  想让它重新扫一遍最近的 filings：把 `seen_upto_date` 和 `seen` 两行都删掉。

  读回时会做兼容处理：`forms` 写成单个字符串 `"10-Q"` 也认；`cik` 写成数字也认；
  `seen` 写成以 accession 为键的表也认（见 normalizeSeen）。

=== 「新文件」到底怎么算（基线语义，接界面时请照这个口径说话）===

  `seen`（下载过的 accession 清单）只能回答「这份下过没有」，回答不了
  「SEC 历史上那几千份我要不要」。所以每家还有一个 **基线** `seen_upto_date`：

    * 首次运行：把现有窗口里最新的 `first_run_new` 份下下来，
      其余一概算「历史」——`history_skipped` 里报出条数，**不补**。
      基线落在「本次看到的最新那一天」。
    * 之后的运行：`filing_date >= 基线` 且没在 `seen` 里的，才算新文件。
    * 基线**只在「本轮该下的都下了」（truncated == 0）时才前进**；
      被 `max_new_per_company` 截掉的那些日期都不早于基线，下次接着下，不会丢。
    * 想重新扫一遍历史（比如刚放宽了 `forms`）：调 `resetBaseline`，
      它会清掉这一家的 `seen` / `seen_upto_date` / `first_run_done`。

  为什么非要基线不可：不设的话，「第一次跑只下最近 8 份」剩下的几百份会在之后每轮
  都被当成「新文件」继续下载，用户会看到自己明明什么都没做、书却在无限变长。

  === 基线为什么按**日期**比，而不是按 accession 比 ===

  第一版是按 accession 比的（「accn 比基线大就是新的」），想法是 accession 单调递增。
  这个想法**在真实数据上当场就错了**，而且错得很彻底：

      EDGAR 的 accession 是 `NNNNNNNNNN-YY-NNNNNN`，前 10 位是**上报代理机构**的编号，
      不是公司的 CIK。苹果那 368 份 filing 里出现了 **42 个不同的前缀** ——
      同一家公司、同一天的文件可能来自不同代理，而 2015 年的文件前缀可能是 9999999997。

  于是一按字符串排序，2016 年的 `9999999997-17-000809` 会排在 2026 年的
  `0001140361-26-038674` **后面**（即「更新」）。后果：第一次运行结束后，
  第二次运行又冒出 16 份「新文件」——它们全都是几个月前的老文件。

  所以基线改成按 **filing_date**（`YYYY-MM-DD`）比：字典序就是时间序，而且 SEC 的
  filingDate 是申报日，跟「新不新」直接对应。日期读不出来的条目一律**当候选**
  （宁可多取也不静默丢），并在 warnings 里报出条数。

  这条教训值得单独记：**合成数据里 accession 是用 CIK 当前缀造的，所以永远发现不了
  这个问题**。是拿真实的 sec_search.lua 输出跑一遍才炸出来的（
  `work/watchlist_realsearch_test.lua`）。
]]

local SecWatchlist = {}

-- ── 常量 ────────────────────────────────────────────────────────────────

SecWatchlist.VERSION = 1

--- 默认关注的表格类型。空 = 用这个。
--- 8-K 是业绩快报，10-Q/10-K 是完整季报/年报 —— 三类合起来才是「财报研习」需要的。
SecWatchlist.DEFAULT_FORMS = { "10-K", "10-Q", "8-K" }

--- 每家公司保留的 accession 条数上限。见 planUpdates 里关于「更早的丢弃」的说明。
SecWatchlist.DEFAULT_KEEP_SEEN = 200

--- 首次运行（没有任何历史状态）时最多取几份。
--- 不设这个会变成「第一次就把 SEC 给的 1000 份全下」，那是几 GB 和几个小时的下载。
SecWatchlist.DEFAULT_FIRST_RUN_NEW = 10

--- 每次运行每家公司最多新增几份，防止长期没更新后一次涌入几百份。
SecWatchlist.DEFAULT_MAX_NEW = 8

--- 新版 EPUB 打包后 `.sdr` 里要塞回去的元数据文件名（KOReader: getSidecarFilename）。
SecWatchlist.SIDECAR_METADATA = "metadata.epub.lua"

--- 我们自己留在 `.sdr` 里的进度台账（KOReader 只在自己那棵目录里找
--- metadata.<ext>.lua 和 cache/，多余的普通文件会被忽略）。
SecWatchlist.SIDECAR_LEDGER = "secfilings_progress.lua"

-- ── 基础小工具 ──────────────────────────────────────────────────────────

local function nowSeconds()
    return os.time()
end

local function isArray(t)
    if type(t) ~= "table" then return false end
    local n = 0
    for key in pairs(t) do
        if type(key) ~= "number" then return false end
        n = n + 1
    end
    if n == 0 then return false end -- 空表当作字典，避免歧义
    return true
end

--- CIK 一律存成 10 位字符串（SEC 的补零格式）。
--- 为什么不用数字：1 位和 10 位在排序、拼 URL、比对时全都不一样；字符串最省事，
--- 而且用户手改时「0000320193」这种前导零不会被吃掉。
---@return string|nil cik, string|nil err
function SecWatchlist.normalizeCik(cik)
    if cik == nil then return nil, "缺少 cik" end
    local s
    if type(cik) == "number" then
        if cik ~= math.floor(cik) or cik < 0 then
            return nil, "cik 必须是正整数：" .. tostring(cik)
        end
        s = string.format("%d", cik)
    else
        s = tostring(cik):gsub("%s", "")
        -- 允许 "CIK0000320193" / "cik 320193" 这类从 SEC 网页上抄下来的写法
        s = s:gsub("^[Cc][Ii][Kk]%s*", "")
    end
    if s == "" or s:find("%D") then
        return nil, "cik 里出现了非数字字符：" .. tostring(cik)
    end
    if #s > 10 then
        -- 超过 10 位基本都是抄错了（SEC 的 CIK 上限就在 10 位以内）
        return nil, "cik 超过 10 位：" .. s
    end
    return string.format("%010d", tonumber(s))
end

--- 判断一个字符串是不是 "YYYY-MM-DD"。增量判定只认这一种形状的日期 ——
--- SEC 的 filingDate 就是这个形状，直接比字符串等价于比日期，不用碰时区。
---@return boolean
function SecWatchlist.isValidDate(value)
    return type(value) == "string" and value:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

--- 表格类型规范化：SEC 的 form 里有 "10-K"、"10-K/A"、"8-K"、"8-K/A"、"10-Q"。
---@return string
function SecWatchlist.normalizeForm(form)
    if form == nil then return "" end
    return (tostring(form):gsub("^%s+", ""):gsub("%s+$", "")):upper()
end

--- "10-K/A" -> "10-K"。修正版（/A）算不算「这一类」，由调用方用 opts.exact_forms 决定。
---@return string
function SecWatchlist.baseForm(form)
    local f = SecWatchlist.normalizeForm(form)
    return (f:match("^([^/]+)") or f)
end

--- 取某个关注项的表格过滤集合。空 = 默认三类。
---@return table 形如 { ["10-K"]=true, ["10-Q"]=true, ["8-K"]=true }
function SecWatchlist.formsFor(entry)
    local set = {}
    local list = entry and entry.forms
    if type(list) == "string" then
        -- 手改文件时很容易写成 forms = "10-Q"
        list = { list }
    end
    if type(list) ~= "table" or (isArray(list) and #list == 0) then
        list = SecWatchlist.DEFAULT_FORMS
    end
    for _fi, form in ipairs(list) do
        local f = SecWatchlist.normalizeForm(form)
        if f ~= "" then set[f] = true end
    end
    if next(set) == nil then
        for _fi, form in ipairs(SecWatchlist.DEFAULT_FORMS) do
            set[form] = true
        end
    end
    return set
end

-- ── 文件工具（懒加载 lfs，拿不到就退化）────────────────────────────────

--- 为什么懒加载：本机（Mac）没有 koreader-lfs，测试就跑不起来；而设备上有。
--- 所以不能在模块顶层 require。`pcall(require, ...)` 是安全的 —— require 不会 yield。
local _lfs
local _lfs_probed = false
local function getLfs()
    if _lfs_probed then return _lfs end
    _lfs_probed = true
    local candidates = { "libs/libkoreader-lfs", "lfs" }
    for _ci, name in ipairs(candidates) do
        local ok, mod = pcall(require, name)
        if ok and type(mod) == "table" then
            _lfs = mod
            break
        end
    end
    return _lfs
end

--- 把路径安全地包进 shell 命令（路径可能带空格、中文、单引号）。
--- 为什么允许 shell 兜底：递归删除和多级建目录没有纯 Lua 的可移植写法，而 KOReader
--- 自己也这么干（frontend/document/credocument.lua:cacheInit 里就是 `rm -r`）。
local function shellQuote(path)
    return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

---@return boolean
function SecWatchlist.fileExists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    local lfs = getLfs()
    if lfs then return lfs.attributes(path) ~= nil end
    return false
end

---@return number|nil bytes
function SecWatchlist.fileSize(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size
end

---@return string|nil, string|nil
function SecWatchlist.readFile(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, tostring(err) end
    local data = f:read("*a")
    f:close()
    if data == nil then return nil, "读取失败：" .. tostring(path) end
    return data
end

---@return boolean
function SecWatchlist.isDir(path)
    local lfs = getLfs()
    if lfs then
        local attr = lfs.attributes(path)
        return (attr and attr.mode == "directory") or false
    end
    local ok = os.execute("test -d " .. shellQuote(path) .. " 2>/dev/null")
    return ok == true or ok == 0
end

--- 建多级目录。返回 true 表示目录可用。
---@return boolean ok, string|nil err
function SecWatchlist.ensureDir(dir, opts)
    opts = opts or {}
    if SecWatchlist.isDir(dir) then return true end
    if opts.create == false then return nil, "目录不存在：" .. tostring(dir) end

    local lfs = getLfs()
    if lfs then
        -- 从外往里找第一个已存在的祖先，再逐级 mkdir
        local missing = {}
        local cur = dir
        for _i = 1, 32 do
            if cur == "" or cur == "/" or cur == "." then break end
            if lfs.attributes(cur) then break end
            table.insert(missing, 1, cur)
            cur = cur:match("^(.-)[/\\][^/\\]*$") or ""
        end
        for _i, path in ipairs(missing) do
            lfs.mkdir(path)
        end
    else
        os.execute("mkdir -p " .. shellQuote(dir) .. " 2>/dev/null")
    end

    if SecWatchlist.isDir(dir) then return true end
    return nil, "无法创建目录：" .. tostring(dir)
end

--- 递归删除。
---@return boolean ok, string|nil err
function SecWatchlist.removeTree(path)
    if not SecWatchlist.fileExists(path) then return true end
    local lfs = getLfs()
    if lfs and lfs.attributes(path, "mode") == "file" then
        return os.remove(path) and true or nil, "无法删除文件：" .. tostring(path)
    end
    os.execute("rm -rf " .. shellQuote(path) .. " 2>/dev/null")
    if SecWatchlist.fileExists(path) then
        return nil, "无法删除：" .. tostring(path)
    end
    return true
end

--- 原子写：先写 `<path>.tmp`，再 rename 覆盖；覆盖前把旧的留一代 `.old`。
---
--- 为什么必须这样：设备会随时休眠/断电，直接 `io.open(path,"w")` 写到一半就是半个
--- 文件 —— 用户手改过的关注列表会整段消失。同目录内 rename 是原子的。
--- 留 `.old` 是学 LuaSettings：它的 load 读不出来时会回退到 `file..".old"`。
---@return boolean ok, string|nil err
function SecWatchlist.writeFileAtomic(path, text, opts)
    opts = opts or {}
    local tmp = path .. ".tmp"
    os.remove(tmp)
    local f, err = io.open(tmp, "wb")
    if not f then return nil, "无法写入临时文件：" .. tostring(err) end
    local okw, werr = f:write(text)
    -- 必须先 close 再 rename，否则某些文件系统上 rename 出来的仍是空文件
    f:close()
    if not okw then
        os.remove(tmp)
        return nil, "写临时文件失败：" .. tostring(werr)
    end

    if opts.keep_backup ~= false and SecWatchlist.fileExists(path) then
        os.remove(path .. ".old")
        os.rename(path, path .. ".old")
    end

    local okr, rerr = os.rename(tmp, path)
    if not okr then
        -- 某些文件系统上 rename 会失败，退化为复制走一遍
        local data, rerr2 = SecWatchlist.readFile(tmp)
        if not data then
            os.remove(tmp)
            return nil, "重命名失败且无法读取临时文件：" ..
                tostring(rerr) .. "/" .. tostring(rerr2)
        end
        local out = io.open(path, "wb")
        if not out then
            os.remove(tmp)
            return nil, "无法写入 " .. tostring(path)
        end
        out:write(data)
        out:close()
        os.remove(tmp)
    end
    return true
end

-- ── 序列化：KOReader dump 风格，但把 中文/UTF-8 原样留着 ────────────────

--- 字符串转义。刻意不用 `string.format("%q")`：LuaJIT 的 %q 会把换行写成
--- 「反斜杠 + 真换行」，手改的人一眼看不出边界；UTF-8 汉字虽然能原样输出，
--- 但控制字符走的是另一套规则。这里只转义必须转义的，中文原样保留。
local function quote(s)
    local out = s:gsub("[%z\1-\31\\\"]", function(c)
        if c == "\\" then return "\\\\" end
        if c == "\"" then return "\\\"" end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return string.format("\\%03d", string.byte(c))
    end)
    return "\"" .. out .. "\""
end

--- 键排序必须和 KOReader 的 ffi/util.orderedPairs 一致（同一套比较规则），
--- 否则「我们写的文件」和「KOReader 重写的文件」diff 会满屏，人工审阅失去意义。
local function compareKeys(a, b)
    if type(a) == type(b) then
        return a < b
    end
    return tostring(a) < tostring(b)
end

local function serializeInto(value, out, indent)
    local t = type(value)
    if t == "table" then
        local keys = {}
        for key in pairs(value) do
            if key ~= "__orderedIndex" then -- orderedPairs 的副作用键，不写出去
                keys[#keys + 1] = key
            end
        end
        if #keys == 0 then
            out[#out + 1] = "{}"
            return
        end
        table.sort(keys, compareKeys)
        out[#out + 1] = "{\n"
        local pad = string.rep("    ", indent + 1)
        for _ki = 1, #keys do
            local key = keys[_ki]
            out[#out + 1] = pad .. "["
            if type(key) == "string" then
                out[#out + 1] = quote(key)
            elseif type(key) == "number" then
                out[#out + 1] = tostring(key)
            else
                out[#out + 1] = quote(tostring(key))
            end
            out[#out + 1] = "] = "
            serializeInto(value[key], out, indent + 1)
            out[#out + 1] = ",\n"
        end
        out[#out + 1] = string.rep("    ", indent) .. "}"
    elseif t == "string" then
        out[#out + 1] = quote(value)
    elseif t == "number" then
        -- 整数写成整数：KOReader 的 dump 用 tostring，LuaJIT 下整数会变成 "1.0"，
        -- 手改时看着别扭，读回来还是数字（不影响 LuaSettings）。
        if value == math.floor(value) and math.abs(value) < 1e15 then
            out[#out + 1] = string.format("%d", value)
        else
            out[#out + 1] = string.format("%.14g", value)
        end
    elseif t == "boolean" then
        out[#out + 1] = tostring(value)
    else
        -- function/userdata/thread 不写出去：关注列表里不该有，写出去也读不回来
        out[#out + 1] = "nil"
    end
end

--- 把一个表序列化成可被 KOReader `LuaSettings` 读回的文本（`return { ... }`）。
---@return string
function SecWatchlist.serialize(data, header)
    local out = {}
    if header then
        out[#out + 1] = header
    end
    out[#out + 1] = "return "
    serializeInto(data, out, 0)
    out[#out + 1] = "\n"
    return table.concat(out)
end

--- 安全地读一个 Lua 数据文件。
--- 只给空环境（setfenv），这样手改文件里万一混进 `os.execute(...)` 也不会被执行。
--- 用 pcall 是安全的：loadfile + setfenv + 调用一个纯数据块都不会 yield。
---@return table|nil data, string|nil err
local function loadTableFile(path)
    if not SecWatchlist.fileExists(path) then
        return nil, "文件不存在：" .. tostring(path)
    end
    local chunk, lerr = loadfile(path)
    if not chunk then
        return nil, "语法错误：" .. tostring(lerr)
    end
    if setfenv then
        setfenv(chunk, {})
    end
    local ok, data = pcall(chunk)
    if not ok then
        return nil, "执行失败：" .. tostring(data)
    end
    if type(data) ~= "table" then
        return nil, "文件里不是一张表（返回 " .. type(data) .. "）"
    end
    return data
end

-- ── 关注列表：默认值、结构、查询 ────────────────────────────────────────

--- 默认关注的 7 家（与 sec_source.lua:companies 同源）。
--- 刻意不 require sec_source：那个文件顶层 require socket/http/json，会破坏本模块
--- 的「可无头测试」。调用方可以把 SecSource.companies 传进来，保持单一来源。
---@param companies table|nil { {cik=, name=, legal=}, ... }
---@return table entries
function SecWatchlist.defaults(companies)
    -- 用数字键：normalizeCik 出来的是 10 位补零字符串，拿它直接查数字键会查不到
    local tickers = {
        [1318605] = "TSLA",
        [1045810] = "NVDA",
        [320193]  = "AAPL",
        [1018724] = "AMZN",
        [1326801] = "META",
        [1652044] = "GOOGL",
        [789019]  = "MSFT",
    }
    local src = companies or {
        { cik = 1318605, name = "特斯拉", legal = "Tesla, Inc." },
        { cik = 1045810, name = "英伟达", legal = "NVIDIA CORP" },
        { cik = 320193,  name = "苹果",   legal = "Apple Inc." },
        { cik = 1018724, name = "亚马逊", legal = "Amazon.com, Inc." },
        { cik = 1326801, name = "Meta",   legal = "Meta Platforms, Inc." },
        { cik = 1652044, name = "谷歌",   legal = "Alphabet Inc." },
        { cik = 789019,  name = "微软",   legal = "Microsoft Corp." },
    }
    local out = {}
    for _ci = 1, #src do
        local c = src[_ci]
        local cik = SecWatchlist.normalizeCik(c.cik)
        if cik then
            out[#out + 1] = {
                cik     = cik,
                name    = c.name or cik,
                legal   = c.legal,
                ticker  = c.ticker or tickers[tonumber(cik)],
                enabled = true,
            }
        end
    end
    return out
end

--- 建一个空（或填默认）的列表对象。
---@param opts table|nil { seed_defaults = bool, companies = table, keep_seen = n }
---@return table
function SecWatchlist.new(opts)
    opts = opts or {}
    local wl = {
        version = SecWatchlist.VERSION,
        updated_at = nowSeconds(),
        keep_seen = opts.keep_seen or SecWatchlist.DEFAULT_KEEP_SEEN,
        entries = {},
    }
    if opts.seed_defaults then
        wl.entries = SecWatchlist.defaults(opts.companies)
    end
    return wl
end

---@return number|nil 下标
local function indexOf(wl, cik)
    for _ei = 1, #wl.entries do
        if wl.entries[_ei].cik == cik then return _ei end
    end
    return nil
end

SecWatchlist.indexOf = indexOf

---@return table|nil entry
function SecWatchlist.find(wl, cik)
    local c = SecWatchlist.normalizeCik(cik)
    if not c then return nil end
    local i = indexOf(wl, c)
    return i and wl.entries[i] or nil
end

--- 取列表内容。默认返回**深拷贝**：界面拿去渲染时误改不会污染状态。
---@param opts table|nil { live = true 取内部引用, enabled_only = 只要 enabled 的 }
---@return table array
function SecWatchlist.list(wl, opts)
    opts = opts or {}
    local picked = {}
    for _ei = 1, #wl.entries do
        local e = wl.entries[_ei]
        if (not opts.enabled_only) or e.enabled ~= false then
            picked[#picked + 1] = e
        end
    end
    if opts.live then return picked end
    return SecWatchlist.cloneList(picked)
end

--- 深拷贝一份 entry 数组（只拷已知字段，避免把界面塞进去的临时字段写回文件）。
---@return table
function SecWatchlist.cloneList(entries)
    local out = {}
    for _ei = 1, #entries do
        out[#out + 1] = SecWatchlist.cloneEntry(entries[_ei])
    end
    return out
end

local ENTRY_FIELDS = {
    "cik", "name", "legal", "ticker", "forms", "enabled",
    "last_accession", "last_filing_date", "last_checked_at", "last_success_at",
    "first_run_done", "keep_seen", "seen", "seen_upto_date", "content_chars", "note",
}

---@return table
function SecWatchlist.cloneEntry(entry)
    local out = {}
    for _fi = 1, #ENTRY_FIELDS do
        local key = ENTRY_FIELDS[_fi]
        local value = entry[key]
        if value ~= nil then
            if key == "forms" or key == "seen" then
                local copy = {}
                for _vi = 1, #value do copy[_vi] = value[_vi] end
                out[key] = copy
            else
                out[key] = value
            end
        end
    end
    return out
end

--- `seen` 的兼容读入。标准形式是「新的在前的字符串数组」，但手改的文件可能写成：
---   { ["0000320193-26-000045"] = 1791234567 }   -- 键是 accession
---   { {accn="…", at=1791234567}, … }            -- 条目是表
---@return table array
function SecWatchlist.normalizeSeen(seen)
    local out = {}
    if type(seen) ~= "table" then return out end
    if isArray(seen) then
        for _si = 1, #seen do
            local item = seen[_si]
            if type(item) == "string" then
                out[#out + 1] = item
            elseif type(item) == "table" then
                local accn = item.accn or item.accession_number or item.accessionNumber
                if accn then out[#out + 1] = tostring(accn) end
            end
        end
    else
        for key in pairs(seen) do
            if type(key) == "string" then out[#out + 1] = key end
        end
        -- accession 是定宽且单调递增的，降序排一次就等价于「新的在前」
        table.sort(out, function(a, b) return a > b end)
    end
    return out
end

--- 把外部给的 entry 规范化成内部形状。
---@return table|nil entry, string|nil err
function SecWatchlist.normalizeEntry(entry)
    if type(entry) ~= "table" then return nil, "关注项不是表" end
    local cik, cerr = SecWatchlist.normalizeCik(entry.cik)
    if not cik then return nil, tostring(cerr) end

    local forms
    if entry.forms ~= nil then
        local list = type(entry.forms) == "table" and entry.forms or { entry.forms }
        forms = {}
        for _fi = 1, #list do
            local f = SecWatchlist.normalizeForm(list[_fi])
            if f ~= "" then forms[#forms + 1] = f end
        end
        if #forms == 0 then forms = nil end
    end

    return {
        cik              = cik,
        name             = entry.name or cik,
        legal            = entry.legal,
        ticker           = entry.ticker,
        forms            = forms,
        enabled          = entry.enabled ~= false,
        last_accession   = entry.last_accession,
        last_filing_date = entry.last_filing_date,
        last_checked_at  = tonumber(entry.last_checked_at) or nil,
        last_success_at  = tonumber(entry.last_success_at) or nil,
        first_run_done   = entry.first_run_done and true or nil,
        keep_seen        = tonumber(entry.keep_seen) or nil,
        seen             = SecWatchlist.normalizeSeen(entry.seen),
        -- 基线：早于它的 filing 一律不补（"YYYY-MM-DD"）。手改时删掉它 = 重新扫历史。
        seen_upto_date   = (SecWatchlist.isValidDate(entry.seen_upto_date)
            and entry.seen_upto_date) or nil,
        content_chars    = tonumber(entry.content_chars) or nil,
        note             = entry.note,
    }
end

-- ── 关注列表：增删 ─────────────────────────────────────────────────────

--- 添加一个关注项。已经存在的按「更新」处理，绝不产生重复项。
---@param wl table
---@param entry table { cik=, name=, ticker=, forms=, enabled= }
---@return boolean ok, table|string info|err   info = { cik, added, updated = {字段...} }
function SecWatchlist.add(wl, entry)
    local norm, err = SecWatchlist.normalizeEntry(entry)
    if not norm then return nil, tostring(err) end

    wl.user_modified_at = nowSeconds()
    local i = indexOf(wl, norm.cik)
    if i then
        -- 只覆盖调用方**显式给了**的字段，其余保持原样 —— 否则界面「添加」一次
        -- 就会把用户手改的 forms、以及增量进度（seen / first_run_done）冲掉。
        local changed = {}
        local keys = { "name", "legal", "ticker", "forms", "enabled", "note" }
        for _ki = 1, #keys do
            local key = keys[_ki]
            if entry[key] ~= nil and norm[key] ~= nil then
                wl.entries[i][key] = norm[key]
                changed[#changed + 1] = key
            end
        end
        return true, { cik = norm.cik, added = false, updated = changed }
    end

    wl.entries[#wl.entries + 1] = norm
    return true, { cik = norm.cik, added = true, updated = {} }
end

--- 删除一个关注项。
---@return boolean ok, table|string info|err  info = { cik, removed = bool }
function SecWatchlist.remove(wl, cik)
    local c, err = SecWatchlist.normalizeCik(cik)
    if not c then return nil, tostring(err) end
    local i = indexOf(wl, c)
    if not i then
        -- 「删一个本来就没有的」不是错误：界面重复点了不该报错
        return true, { cik = c, removed = false }
    end
    table.remove(wl.entries, i)
    wl.user_modified_at = nowSeconds()
    return true, { cik = c, removed = true }
end

--- 切换关注开关。传 entry（表）或 cik 都行；不在列表里时等于「加入并打开」。
---@param what table|string entry 或 cik
---@return boolean ok, table|string info|err  info = { cik, enabled, added }
function SecWatchlist.toggle(wl, what)
    local cik, entry
    if type(what) == "table" then
        entry = what
        cik = SecWatchlist.normalizeCik(what.cik)
    else
        cik = SecWatchlist.normalizeCik(what)
    end
    if not cik then return nil, "toggle 需要 cik 或 entry" end

    local e = SecWatchlist.find(wl, cik)
    if not e then
        -- 「划上一个还不在列表里的公司」= 加进来并打开
        local ok, info = SecWatchlist.add(wl, entry or { cik = cik, name = cik })
        if not ok then return nil, tostring(info) end
        e = SecWatchlist.find(wl, cik)
        e.enabled = true
        wl.user_modified_at = nowSeconds()
        return true, { cik = cik, enabled = true, added = true }
    end

    e.enabled = not (e.enabled ~= false)
    if entry and entry.name and not e.name then e.name = entry.name end
    wl.user_modified_at = nowSeconds()
    return true, { cik = cik, enabled = e.enabled, added = false }
end

-- ── 关注列表：读写 ─────────────────────────────────────────────────────

local FILE_HEADER = [[
-- sec_watchlist.lua —— 关注列表（由 secfilings.koplugin 维护，也可以手改）
-- 手改注意：
--   * 整段 [n] = { ... } 复制一份就能多关注一家公司，改 cik / name / ticker 即可；
--   * forms = { "10-Q" } 表示只关心季报；把这个键整行删掉就恢复默认三类
--     （10-K / 10-Q / 8-K）；enabled = false 表示暂时不再自动下载；
--   * seen_upto_date 是「基线」（日期，YYYY-MM-DD）：早于这一天的 filing 不再补下
--     （含首次运行时的历史）。把这一行删掉 = 下一轮重新扫最近若干份；
--   * seen 是基线之上「已经下过的 accession」清单，删掉它那些会重下一遍；
--   * 改完存成 UTF-8 即可，注释和空格随便加，本文件只要求语法正确。
]]

--- 把读到的表搬进规范形状（丢弃不认识的垃圾字段，但保留 user_modified_at 等元信息）。
---@return table wl
function SecWatchlist.adopt(wl, data)
    wl.version = tonumber(data.version) or SecWatchlist.VERSION
    wl.updated_at = tonumber(data.updated_at) or nil
    wl.user_modified_at = tonumber(data.user_modified_at) or nil
    wl.keep_seen = tonumber(data.keep_seen) or SecWatchlist.DEFAULT_KEEP_SEEN
    wl.entries = {}
    local entries = data.entries
    if type(entries) == "table" then
        for _ei = 1, #entries do
            local norm = SecWatchlist.normalizeEntry(entries[_ei])
            -- 同一家写了两遍的时候只留第一条，避免后面「按 cik 找」拿到不确定的那条
            if norm and not indexOf(wl, norm.cik) then
                wl.entries[#wl.entries + 1] = norm
            end
        end
    end
    return wl
end

--- 读关注列表。
---
--- source 可以是：
---   * 字符串路径：文件里**直接**是关注列表，或挂在 `["sec_watchlist"]` 键下面
---     （后者让它能塞进插件现有的 secfilings.lua 设置文件）；
---   * 已打开的 LuaSettings / 任何带 `.data` 的表；
---   * nil（纯内存列表）。
---
--- 出错时**仍然返回一个可用的列表**，同时把 err 给出：语法坏了的时候宁可让调用方
--- 看到 err 并拒绝保存（save 会这么做），也不能悄悄用默认值把用户文件覆盖掉。
---@return table wl, string|nil err
function SecWatchlist.load(source, opts)
    opts = opts or {}
    local wl = SecWatchlist.new{ seed_defaults = false }
    local err
    local key = opts.key or "sec_watchlist"

    local function seedIfWanted()
        if opts.seed_defaults ~= false then
            wl.entries = SecWatchlist.defaults(opts.companies)
            wl.created_from_defaults = true
        end
    end

    if type(source) == "string" then
        local path = source
        wl.load_path = path
        local data, lerr = loadTableFile(path)
        if not data then
            local has_leftover = SecWatchlist.fileExists(path .. ".tmp")
            local has_backup = SecWatchlist.fileExists(path .. ".old")
            if has_backup then
                -- 学 LuaSettings：主文件坏了就读上一代备份，而不是直接认输
                data = loadTableFile(path .. ".old")
                if data then wl.load_from_backup = true end
            end
            if not data then
                -- 文件真不存在（第一次跑插件）不是错误；存在但读不出来才是
                if SecWatchlist.fileExists(path) or has_leftover then
                    err = lerr
                    wl.load_error = lerr
                end
                seedIfWanted()
                return wl, err
            end
        end
        local nested = data[key]
        if type(nested) == "table" and (nested.entries ~= nil or nested.version ~= nil) then
            SecWatchlist.adopt(wl, nested)
            wl.load_container = key
        elseif data.entries ~= nil or data.version ~= nil then
            SecWatchlist.adopt(wl, data)
        else
            -- 文件存在、语法也对，但没有 entries —— 可能是别的工具写的同名文件
            wl.load_error = "文件里没有 entries 字段，内容已忽略"
            err = wl.load_error
            seedIfWanted()
            return wl, err
        end
    elseif type(source) == "table" then
        wl.settings = source
        local data = source.data or source
        local nested = data[key]
        local holder = (type(nested) == "table") and nested or data
        if type(holder) == "table" and (holder.entries ~= nil or holder.version ~= nil) then
            SecWatchlist.adopt(wl, holder)
        else
            seedIfWanted()
        end
    else
        seedIfWanted()
    end

    -- 文件存在、条目为空、而且用户动过（user_modified_at 有值）→ 尊重「我就是不关注
    -- 任何家」，绝不静默塞回默认 7 家。只有「空且从没被人改过」才补默认。
    if #wl.entries == 0 and opts.seed_defaults ~= false and not wl.user_modified_at then
        seedIfWanted()
    end

    return wl, err
end

--- 保存关注列表。
---
--- target 可以是路径或 LuaSettings 实例（走 :flush()）。
--- 如果之前 load 出错（wl.load_error 有值），默认**拒绝**写入：手改坏了一个字就把
--- 整份列表覆盖掉，是最难挽回的一类事故。确实要覆盖请传 opts.force = true。
---@return boolean ok, string|nil err
function SecWatchlist.save(wl, target, opts)
    opts = opts or {}
    if wl.load_error and not opts.force then
        return nil, "上次读取有问题（" .. tostring(wl.load_error) ..
            "），为避免覆盖你手改的文件本次不保存；确认要覆盖请传 force = true"
    end
    wl.updated_at = nowSeconds()
    wl.version = SecWatchlist.VERSION

    local payload = {
        version = wl.version,
        updated_at = wl.updated_at,
        keep_seen = wl.keep_seen,
        entries = wl.entries,
    }
    if wl.user_modified_at then payload.user_modified_at = wl.user_modified_at end
    if wl.extra then
        for key, value in pairs(wl.extra) do payload[key] = value end
    end

    local path = wl.load_path
    local settings
    if type(target) == "string" then
        path = target
    elseif type(target) == "table" then
        settings = target
        if settings.data == nil then
            return nil, "save 收到的对象既不是路径也没有 .data"
        end
    elseif target ~= nil then
        return nil, "save 的 target 只能是路径或 LuaSettings"
    elseif wl.settings then
        -- load 时给的是 LuaSettings，save 又没给 target：写回那个实例
        settings = wl.settings
    end

    if settings then
        settings.data[opts.key or "sec_watchlist"] = payload
        if type(settings.flush) == "function" then
            settings:flush()
        end
        wl.load_path = nil
        wl.settings = settings
        return true
    end

    if not path then
        return nil, "没有保存路径（load 时用的是内存列表）"
    end

    -- 如果当初是从「整个文件里的一个键」读出来的（比如关注列表挂在现有的
    -- secfilings.lua 里），写回去必须**合进**那张表，不能把整份文件替换掉 ——
    -- 否则插件的其它设置（limit / include_reports…）会一次性消失。
    if wl.load_container then
        local existing = loadTableFile(path)
        if not existing then
            return nil, "无法读取 " .. tostring(path) .. "（读不出来就不能合写，否则会弄丢同文件里的其它设置）"
        end
        existing[wl.load_container] = payload
        local ok_c, cerr = SecWatchlist.writeFileAtomic(path,
            SecWatchlist.serialize(existing, FILE_HEADER), opts)
        if not ok_c then return nil, tostring(cerr) end
        wl.load_path = path
        return true
    end

    local text = SecWatchlist.serialize(payload, FILE_HEADER)
    local ok, werr = SecWatchlist.writeFileAtomic(path, text, opts)
    if not ok then return nil, tostring(werr) end
    wl.load_path = path
    return true
end

-- ── 增量判定 ───────────────────────────────────────────────────────────

--- 把一条 SEC filing 元数据规范化。
--- 字段名同时认三套写法，因为 SEC 原始 JSON 是 camelCase（filingDate /
--- accessionNumber），sec_source.lua 用的是简写（accn / date / primary），而任务书
--- 里写的是下划线（accession_number / filing_date / primary_document）。
--- 同一个模块要吃三种输入，否则接哪一边都要改代码。
---@return table|nil filing, string|nil err
function SecWatchlist.normalizeFiling(f)
    if type(f) ~= "table" then return nil, "filing 不是表" end
    local accn = f.accn or f.accession_number or f.accessionNumber or f.accession
    if not accn or tostring(accn) == "" then
        return nil, "filing 缺少 accession"
    end
    return {
        accn    = tostring(accn),
        form    = SecWatchlist.normalizeForm(f.form or f.form_type or f.formType),
        date    = tostring(f.date or f.filing_date or f.filingDate or ""),
        primary = tostring(f.primary or f.primary_document or f.primaryDocument or ""),
        items   = tostring(f.items or ""),
        cik     = f.cik,
    }
end

--- 把 `fetched` 统一成 { [cik] = { filings = {…} } }。
--- 接受两种形状：
---   { { cik = …, name = …, entries = {…} }, … }   -- 数组（sec_search.listFilings 的返回就是这种）
---   { ["0000320193"] = { {…}, {…} } }             -- 按 cik 建索引
--- company 级的文档数组键名认 entries / filings / recent / documents / docs / docs_list / files。
--- `entries` 放在第一位、且在测试里用真实的 sec_search.lua 输出验证过 —— 两边接起来
--- 不能靠「看起来应该对」。
---@return table|nil map, string|nil err
function SecWatchlist.normalizeFetched(fetched)
    if fetched == nil then return {}, nil end
    if type(fetched) ~= "table" then return nil, "fetched 不是表" end

    local map = {}
    local array_keys = { "entries", "filings", "recent", "documents", "docs", "docs_list", "files" }

    local function putCompany(cik, docs, name)
        local c = SecWatchlist.normalizeCik(cik)
        if not c then return end
        local list = {}
        for _di = 1, #docs do
            local nf = SecWatchlist.normalizeFiling(docs[_di])
            if nf then list[#list + 1] = nf end
        end
        map[c] = { filings = list, name = name }
    end

    if isArray(fetched) then
        for _fi = 1, #fetched do
            local company = fetched[_fi]
            if type(company) ~= "table" then
                return nil, "fetched[" .. _fi .. "] 不是表"
            end
            local docs
            for _ki = 1, #array_keys do
                local candidate = company[array_keys[_ki]]
                if type(candidate) == "table" then docs = candidate break end
            end
            if not docs then
                return nil, "fetched[" .. _fi .. "] 里找不到文件数组（filings/recent/…）"
            end
            putCompany(company.cik, docs, company.name)
        end
    else
        for key, value in pairs(fetched) do
            if type(value) == "table" then
                local docs, name, is_doc_list = value, value.name, false
                for _ki = 1, #array_keys do
                    if type(value[array_keys[_ki]]) == "table" then
                        docs = value[array_keys[_ki]]
                        is_doc_list = true
                        break
                    end
                end
                if not is_doc_list and isArray(value) then docs = value end
                if type(docs) == "table" and isArray(docs) then
                    putCompany(key, docs, name)
                end
            end
        end
    end
    return map, nil
end

--- 这条 filing 是否在关注项的 forms 里。默认「基表名匹配」：
--- 关注 10-Q 时 10-Q/A（修正版）也算，因为它就是季报的修正。
--- opts.exact_forms = true 时严格相等（10-Q 不吃 10-Q/A）。
local function formMatches(filing_form, form_set, exact)
    local f = SecWatchlist.normalizeForm(filing_form)
    if exact then return form_set[f] == true end
    return form_set[f] == true or form_set[SecWatchlist.baseForm(f)] == true
end

--- 计算每家公司需要下载的新文件。
---
--- 判定规则（三家条件都要满足才算「新」）：
---   1. form 在关注范围内；
---   2. 不在 `seen` 里；
---   3. 日期不早于基线 `seen_upto_date`（基线不存在时跳过这一条）—— 见文件头「基线语义」。
---
---@param wl table 关注列表
---@param fetched table 见 normalizeFetched
---@param opts table|nil {
---     max_new_per_company = 每次最多新增几份（默认 8）
---     first_run_new       = 首次运行最多几份（默认 10）
---     since_date          = "YYYY-MM-DD"，早于此日期的不要（字符串比较，不看时区）
---                          （被它跳过的条数会记在 updates[i].since_skipped 里，
---                            total_known 只统计过滤之后剩下的）
---     only_enabled        = 默认 true：enabled = false 的跳过
---     exact_forms         = 见 formMatches
---   }
---@return table updates, string|nil err
--- updates[i] = { cik, name, ticker, forms, new_filings = {…}（新在前）, new_count,
---                first_run, total_known, truncated, history_skipped, since_skipped,
---                baseline_date, baseline_new_date, closing_accns, seen_before,
---                latest_filing, latest_accession, warnings }
---   closing_accns 是给 commit 用的「收盘清单」（最新那一天的 accession），
---   集成方自己落账时应当把它一并 markSeen，否则同日的文件会卡在边界上反复出现。
function SecWatchlist.planUpdates(wl, fetched, opts)
    opts = opts or {}
    local map, ferr = SecWatchlist.normalizeFetched(fetched)
    if not map then return {}, tostring(ferr) end

    local max_new = tonumber(opts.max_new_per_company) or SecWatchlist.DEFAULT_MAX_NEW
    local first_run_new = tonumber(opts.first_run_new) or SecWatchlist.DEFAULT_FIRST_RUN_NEW
    local since = opts.since_date
    -- 日期格式不对就不敢拿它做过滤：宁可多取，也不静默丢（本项目就栽在静默丢上）
    local strict_since = (type(since) == "string" and since:match("^%d%d%d%d%-%d%d%-%d%d$")) and true or false
    local exact = opts.exact_forms and true or false

    local updates = {}
    for _ei = 1, #wl.entries do
        local entry = wl.entries[_ei]
        if opts.only_enabled == false or entry.enabled ~= false then
            local got = map[entry.cik]
            local form_set = SecWatchlist.formsFor(entry)

            -- seen 数组上限 200，但比对次数是「filing 数 × seen 数」，先建一次 set
            -- 把它换成 O(1)，设备上每家公司上千份 filing 时才不会卡
            local seen_set = {}
            local seen_list = entry.seen or {}
            for _si = 1, #seen_list do seen_set[seen_list[_si]] = true end
            -- 基线是**日期**（不是 accession）。为什么不能用 accession 见文件头
            -- 「基线为什么按日期比」那一节。
            local baseline = entry.seen_upto_date
            local has_history = (baseline ~= nil) or (#seen_list > 0)
                or (entry.first_run_done and true or false)

            local considered, dup = {}, {}
            local dup_count, bad_date, since_skipped = 0, 0, 0
            if got then
                for _fi = 1, #got.filings do
                    local f = got.filings[_fi]
                    if formMatches(f.form, form_set, exact) then
                        if dup[f.accn] then
                            -- 同一 accession 可能对应多个文档（8-K 本体 + exhibit），
                            -- 只算一条，否则同一份文件会下两次
                            dup_count = dup_count + 1
                        else
                            dup[f.accn] = true
                            local keep = true
                            if strict_since then
                                if SecWatchlist.isValidDate(f.date) then
                                    if f.date < since then keep = false end
                                else
                                    bad_date = bad_date + 1
                                end
                            end
                            if keep then
                                considered[#considered + 1] = f
                            else
                                since_skipped = since_skipped + 1
                            end
                        end
                    end
                end
            end

            -- SEC 返回的顺序就是新的在前，但接口不保证；显式按日期 + accession 排一遍，
            -- 让「只取最近 N 份」的语义稳定可复现。
            table.sort(considered, function(a, b)
                if a.date ~= b.date then return a.date > b.date end
                return a.accn > b.accn
            end)

            local unseen, history = {}, 0
            for _fi = 1, #considered do
                local f = considered[_fi]
                if seen_set[f.accn] then
                    -- 已经下过，跳过
                elseif baseline and SecWatchlist.isValidDate(f.date) and f.date < baseline then
                    -- 基线之前的历史：不补，但要把条数报出来，
                    -- 免得用户以为「SEC 上没有这些文件」
                    history = history + 1
                else
                    -- 日期读不出来的一律当候选（宁可多取），但记一笔
                    if not SecWatchlist.isValidDate(f.date) then bad_date = bad_date + 1 end
                    unseen[#unseen + 1] = f
                end
            end

            local first_run = (not has_history) and #unseen > 0
            local new_filings, truncated, history_skipped = {}, 0, history

            if first_run then
                -- 首次运行：只取最近若干份，其余当成「历史」一次性跳过（基线语义）。
                -- 这就是为什么第二轮不会再挖出剩下那几百份。
                local cap = math.min(first_run_new, max_new)
                if #unseen > cap then
                    history_skipped = history_skipped + (#unseen - cap)
                end
                for _fi = 1, math.min(cap, #unseen) do
                    new_filings[#new_filings + 1] = unseen[_fi]
                end
            else
                -- 已建立基线：被截断的那些仍然在基线之上（日期不早于基线），
                -- 下次还会出现，所以「有多少没取」单独用 truncated 报出来，
                -- 不能算进历史（算进历史就再也拿不到了）。
                if #unseen > max_new then
                    truncated = #unseen - max_new
                end
                for _fi = 1, math.min(max_new, #unseen) do
                    new_filings[#new_filings + 1] = unseen[_fi]
                end
            end

            local newest = considered[1]
            local newest_date = newest and SecWatchlist.isValidDate(newest.date)
                and newest.date or nil

            -- 「收盘」清单：最新那一天里的所有 accession。
            -- 基线是日期，所以「与基线同日但没下」的文件只靠日期分不出来；把它们一并
            -- 标成见过，才不会永远停在边界上被反复取（第一条日志里就是这么暴露的）。
            -- 注意只收盘**这次看到过**的那些：同一天稍后新来的文件不在里面，
            -- 仍然会被当成新文件（这是安全方向）。
            local closing = {}
            if newest_date and (first_run or truncated == 0) then
                for _fi = 1, #considered do
                    if considered[_fi].date == newest_date then
                        closing[#closing + 1] = considered[_fi].accn
                    end
                end
            end

            local warnings = {}
            if dup_count > 0 then
                warnings[#warnings + 1] = string.format(
                    "有 %d 条重复 accession，已合并（同一 accession 可能有多个文档）", dup_count)
            end
            if bad_date > 0 then
                warnings[#warnings + 1] = string.format(
                    "有 %d 条 filing 日期读不出来，未参与基线/日期过滤（按新文件处理）", bad_date)
            end
            if since_skipped > 0 then
                warnings[#warnings + 1] = string.format(
                    "有 %d 条早于 since_date(%s)，按你的设置跳过", since_skipped, tostring(since))
            end
            if not got then
                warnings[#warnings + 1] = "这次没拿到本公司的元数据"
            end

            updates[#updates + 1] = {
                cik              = entry.cik,
                name             = entry.name,
                ticker           = entry.ticker,
                forms            = entry.forms,
                new_filings      = new_filings,
                new_count        = #new_filings,
                first_run        = first_run and true or false,
                total_known      = #considered,
                truncated        = truncated,
                history_skipped  = history_skipped,
                since_skipped    = since_skipped,
                baseline_date    = baseline,
                baseline_new_date = (first_run or truncated == 0) and newest_date or nil,
                closing_accns    = closing,
                seen_before      = #seen_list,
                latest_filing    = newest and newest.date or nil,
                latest_accession = newest and newest.accn or nil,
                warnings         = warnings,
            }
        end
    end

    -- 输出顺序跟关注列表一致（用户在界面上看到的顺序就是这个顺序）
    return updates, nil
end

--- 标记「这些 accession 已处理」。**只在实际下载成功后调用**。
--- 为什么不能提前标：下载失败（网络断）时如果已经标成见过，这份文件就永远不会再被
--- 取到 —— 属于静默丢数据，是本项目反复踩过的那类坑。
---@param accns table|string 一个 accession 或它们的数组
---@param opts table|nil { when = 时间戳, newest = 最新一份（写进 last_accession）,
---                         upto_date = "YYYY-MM-DD"，推进基线
---                                     （只有「本轮该下的都下了」时才该传） }
---@return boolean ok, table|string info|err
---   info = { cik, added, total_seen, keep, baseline_date }
function SecWatchlist.markSeen(wl, cik, accns, opts)
    opts = opts or {}
    local c, cerr = SecWatchlist.normalizeCik(cik)
    if not c then return nil, tostring(cerr) end
    local entry = SecWatchlist.find(wl, c)
    if not entry then return nil, "关注列表里没有 " .. c end

    local list = accns
    if type(list) == "string" then list = { list } end
    if type(list) ~= "table" then return nil, "accns 必须是字符串或数组" end

    local when = tonumber(opts.when) or nowSeconds()
    local seen = entry.seen or {}
    local existing = {}
    for _si = 1, #seen do existing[seen[_si]] = true end

    local fresh = {}
    for _ai = 1, #list do
        local accn = tostring(list[_ai])
        if accn ~= "" and not existing[accn] then
            existing[accn] = true
            fresh[#fresh + 1] = accn
        end
    end

    -- 新放前面（seen 是「新在前」的数组），这样裁剪时丢掉的永远是最老的
    table.sort(fresh, function(a, b) return a > b end)
    local merged = {}
    for _fi = 1, #fresh do merged[#merged + 1] = fresh[_fi] end
    for _si = 1, #seen do merged[#merged + 1] = seen[_si] end

    -- 基线只前进、不后退。倒退会让已经跳过的历史重新冒出来。
    -- 基线是日期，所以这里比的是日期字符串（YYYY-MM-DD 的字典序就是时间序）。
    if opts.upto_date and SecWatchlist.isValidDate(opts.upto_date) then
        if not entry.seen_upto_date or opts.upto_date > entry.seen_upto_date then
            entry.seen_upto_date = opts.upto_date
        end
    end

    local keep = tonumber(entry.keep_seen) or tonumber(wl.keep_seen)
        or SecWatchlist.DEFAULT_KEEP_SEEN
    if #merged > keep then
        for _di = keep + 1, #merged do merged[_di] = nil end
    end

    entry.seen = merged
    if opts.newest then
        entry.last_accession = tostring(opts.newest)
        entry.last_success_at = when
    elseif #fresh > 0 then
        entry.last_success_at = when
    end
    return true, {
        cik = c, added = #fresh, total_seen = #merged,
        keep = keep, baseline_date = entry.seen_upto_date,
    }
end

--- 记录「这次确实去 SEC 查过了」。查不到公司（CIK 写错）时也记，否则界面会一直显示
--- 「从未检查」，用户看不出问题在哪。
---@return boolean ok, string|nil err
function SecWatchlist.markChecked(wl, cik, opts)
    opts = opts or {}
    local c, cerr = SecWatchlist.normalizeCik(cik)
    if not c then return nil, tostring(cerr) end
    local entry = SecWatchlist.find(wl, c)
    if not entry then return nil, "关注列表里没有 " .. c end
    entry.last_checked_at = tonumber(opts.when) or nowSeconds()
    if opts.latest_filing_date then
        entry.last_filing_date = tostring(opts.latest_filing_date)
    end
    return true
end

--- 把一轮 planUpdates 的结果整体落账（下载全部成功时的便捷写法）。
--- 部分失败时不要用它 —— 用 markSeen 逐条标记成功的那几份。
---
--- 基线只在一轮该下的都下完时前进（truncated == 0）：被 max_new_per_company
--- 截掉的那些仍然在旧基线之上，下次继续出现，不会因为落账就消失。
---@return boolean ok, table|string info|err  info = { marked, companies, baseline_advanced }
function SecWatchlist.commit(wl, updates, opts)
    opts = opts or {}
    updates = updates or {}
    -- 容错：调用方很容易把「单个 update」直接传进来。它长得就像一张表，
    -- 迭代它不会报错，只是什么都不标记，所以这里认一下形状。
    if updates.cik and updates.new_filings then
        updates = { updates }
    end
    local when = tonumber(opts.when) or nowSeconds()
    local marked, companies, advanced = 0, 0, 0
    for _ui = 1, #updates do
        local u = updates[_ui]
        local accns = {}
        for _fi = 1, #u.new_filings do
            accns[#accns + 1] = u.new_filings[_fi].accn
        end
        -- 收盘清单：最新那一天里的全部 accession（planUpdates 给的）。
        -- 它们必须一起标成见过，否则「与基线同日、这次没下」的文件会一直卡在边界上。
        if type(u.closing_accns) == "table" then
            for _ci = 1, #u.closing_accns do
                accns[#accns + 1] = u.closing_accns[_ci]
            end
        end

        -- 基线只在「本轮该下的都下完了」时前进。被 max_new_per_company 截掉的
        -- 那些仍然在基线之上，下次接着下，不会因为落账就消失。
        local upto_date
        if (u.truncated or 0) == 0 then
            upto_date = u.baseline_new_date or u.latest_filing
            if upto_date then advanced = advanced + 1 end
        end

        if #accns > 0 or upto_date then
            local ok, info = SecWatchlist.markSeen(wl, u.cik, accns, {
                when = when,
                newest = u.latest_accession,
                upto_date = upto_date,
            })
            if not ok then return nil, tostring(info) end
            marked = marked + info.added
            companies = companies + 1
        end
        SecWatchlist.markChecked(wl, u.cik, {
            when = when,
            latest_filing_date = u.latest_filing,
        })
        local entry = SecWatchlist.find(wl, u.cik)
        if entry then entry.first_run_done = true end
    end
    return true, { marked = marked, companies = companies, baseline_advanced = advanced }
end

--- 重置基线：把一家（或全部）公司的 `seen` / `seen_upto_date` / `first_run_done` 清掉，
--- 下一轮就会重新扫最近若干份。
--- 什么时候需要它：用户刚把 `forms` 放宽（比如原来只跟 10-Q，现在要看 8-K），
--- 而基线之前被过滤掉的那些不会自动补下 —— 界面上应该给一个「重新扫描」的开关。
---@param cik string|number|nil 给 nil 就是全部
---@return boolean ok, table info { cleared = n }
function SecWatchlist.resetBaseline(wl, cik, opts)
    opts = opts or {}
    local targets = {}
    if cik == nil then
        for _ei = 1, #wl.entries do targets[#targets + 1] = wl.entries[_ei] end
    else
        local c, cerr = SecWatchlist.normalizeCik(cik)
        if not c then return nil, tostring(cerr) end
        local entry = SecWatchlist.find(wl, c)
        if not entry then return nil, "关注列表里没有 " .. c end
        targets[1] = entry
    end
    for _ti = 1, #targets do
        local entry = targets[_ti]
        entry.seen = {}
        entry.seen_upto_date = nil
        entry.first_run_done = nil
        entry.last_accession = nil
        -- last_checked_at / last_filing_date 不动：它们只是展示信息
    end
    wl.user_modified_at = nowSeconds()
    return true, { cleared = #targets }
end

--- 一行人类可读的说明，给界面直接用（不含任何 UI 依赖）。
---@return string
function SecWatchlist.summaryLine(update)
    local parts = {}
    if update.new_count == 0 then
        parts[#parts + 1] = "没有新文件"
    else
        parts[#parts + 1] = string.format("新增 %d 份", update.new_count)
    end
    if update.first_run then
        parts[#parts + 1] = "（首次运行，只取最近若干份）"
    end
    if update.truncated > 0 then
        parts[#parts + 1] = string.format("（还有 %d 份未取，下次继续）", update.truncated)
    end
    if (update.history_skipped or 0) > 0 then
        parts[#parts + 1] = string.format("（基线之前的 %d 份历史未取）", update.history_skipped)
    end
    if (update.since_skipped or 0) > 0 then
        parts[#parts + 1] = string.format("（%d 份早于起始日期）", update.since_skipped)
    end
    if update.latest_filing then
        parts[#parts + 1] = "SEC 上最新：" .. update.latest_filing
    end
    return string.format("%s：%s", update.name or update.cik, table.concat(parts, " "))
end

-- ═══════════════════════════════════════════════════════════════════════
-- 阅读进度（.sdr）保留
-- ═══════════════════════════════════════════════════════════════════════
--
-- 问题：`SecEpub:write` 在换文件前 purgeDir 掉 `.sdr`（内容换了，旧位置会指错地方
-- —— 这是对的，见文件头事实 B）。但有了关注列表后用户会**反复更新**同一本书，
-- 每次更新都把阅读进度和排版设置清空，副作用变得无法忍受。
--
-- 方案：把 `.sdr` 拆成两类东西分开处理 ——
--   * **位置类**（last_xpointer / last_percent / percent_finished / doc_pages /
--     cache_file_path / cre_dom_version / annotations）：内容变了就失效，必须清或重算；
--   * **外观类**（copt_* 字号行距页边距、style_tweaks、view_mode、visible_pages …）：
--     和具体文字无关，跨版本照样有效，**应该保留**。
-- 所以不是「保留整个 .sdr」，而是「抢救出外观类，重建一个干净的 .sdr」。
--
-- 两种位置策略（restoreProgress 的 opts.policy）：
--   "reset"（默认）：不写任何位置信息 → 下次打开落在书的开头。因为目录顺序是
--          「最新的一份在最前面」，落点正好就是用户最想看的那份最新文件。精确、无猜测。
--   "shift"：按内容增量把旧百分比平移。新文件是**前插**的，所以原来读到 40% 的位置
--          在文中的绝对长度没变、只是总长度变长了。用「旧 epub 尺寸 / 新 epub 尺寸」
--           估出前插比例，把旧比例映射成新比例，写进 `last_percent`。
--           KOReader v2026.07.2 的 readerrolling 仍然读 `last_percent`
--           （源码注释："we read last_percent just for backward compatibility"）。

--- `.sdr` 目录的候选路径。
---
--- 会有多个候选是因为「元数据放哪」有三种模式（settings 里的
--- `document_metadata_folder`）：
---   doc（设备当前值）→ `<书>.sdr`；dir → `<koreader>/settings/<绝对路径>.sdr`；
---   hash → `<koreader>/settings/docsettings-hash/<前两位>/<md5>.sdr`
--- 后两种需要知道设备上的路径前缀，我们拿不到也不敢猜，所以这里只处理
--- 「与书同目录」的两种写法，但把「两种都试」写死 —— FINDINGS 对目录名的记录
--- 自相矛盾（`xxx.sdr` vs `xxx.epub.sdr`），两种都认最稳。
---@param epub_path string
---@param opts table|nil { extra_dirs = { paths... } }
---@return table array of string
function SecWatchlist.sidecarDirs(epub_path, opts)
    opts = opts or {}
    local dirs, seen = {}, {}
    local function push(p)
        if p and p ~= "" and not seen[p] then
            seen[p] = true
            dirs[#dirs + 1] = p
        end
    end
    -- 主写法：去掉 .epub 再拼 .sdr（设备实测路径 + v2026.07.2 源码都是这个）
    push(epub_path:gsub("%.[Ee][Pp][Uu][Bb]$", "") .. ".sdr")
    -- 兼容写法：整个文件名后面直接加 .sdr
    push(epub_path .. ".sdr")
    if type(opts.extra_dirs) == "table" then
        for _di = 1, #opts.extra_dirs do push(opts.extra_dirs[_di]) end
    end
    return dirs
end

--- 位置/缓存类键：内容一变就指错地方，必须清掉。
--- 判定标准很硬：**凡是编码了旧文档里「第几页 / DOM 里哪个位置」的键都算**。
--- 与位置无关的读者设置（copt_* 字号行距页边距、style_tweaks、view_mode、
--- visible_pages、text_lang、partial_md5_checksum …）一律保留。
SecWatchlist.DROP_KEYS = {
    "last_xpointer",     -- crengine DOM 路径，直接决定打开后跳到哪
    "last_percent",      -- 老版兜底位置（readerrolling 仍在读）
    "percent_finished",  -- 书库/页脚显示的百分比
    "doc_pages",         -- 旧总页数；KOReader 会在 ReaderReady 重算
    "pagemap_doc_pages", -- 页码映射缓存（readerpagemap 写的），跟着 doc_pages 走
    "cache_file_path",   -- 指向 crengine 的 .cr3 缓存文件
    "cre_dom_version",   -- 见文件头事实 C：留着会让 crengine 用错 DOM 版本
    "stats",             -- statistics 插件的 per-book 数据，键是旧页码（performance_in_pages）
}

--- 标注类键：里面的 pos0/pos1 是 xpointer，内容变了会静默指到别的句子。
--- 默认丢掉（数量会在 report 里报出来，界面可以提示用户），
--- opts.keep_annotations = true 时保留。
SecWatchlist.ANNOTATION_KEYS = { "annotations", "bookmarks", "page_bookmarks" }

--- 打包**之前**调用：把 `.sdr` 里值得留下的东西读出来。
---@param epub_path string
---@param opts table|nil { extra_dirs = {...}, keep_annotations = bool }
---@return table snapshot, string|nil err
---    snapshot = { epub_path, all_dirs, path, existed, metadata, dropped_keys,
---                 annotations_dropped, old_size, old_percent, ledger, raw_keys }
function SecWatchlist.keepProgress(epub_path, opts)
    opts = opts or {}
    local dirs = SecWatchlist.sidecarDirs(epub_path, opts)
    local snapshot = {
        epub_path = epub_path,
        all_dirs = dirs,
        existed = false,
        metadata = {},
        dropped_keys = {},
        annotations_dropped = 0,
        old_size = SecWatchlist.fileSize(epub_path),
    }
    local err

    local existing_dir, data
    for _di = 1, #dirs do
        local meta_path = dirs[_di] .. "/" .. SecWatchlist.SIDECAR_METADATA
        if SecWatchlist.fileExists(meta_path) then
            local loaded, lerr = loadTableFile(meta_path)
            if loaded then
                existing_dir, data = dirs[_di], loaded
                break
            end
            -- 元数据坏了不能当没有：记下来让调用方知道，不要静默覆盖
            err = "阅读记录读不出来（" .. tostring(lerr) .. "）"
            snapshot.load_error = err
        elseif SecWatchlist.isDir(dirs[_di]) then
            existing_dir = existing_dir or dirs[_di]
        end
    end
    snapshot.path = existing_dir
    snapshot.existed = existing_dir ~= nil

    -- 台账：上一次写这本书时的尺寸（shift 策略的参考点）
    if existing_dir then
        local ledger = loadTableFile(existing_dir .. "/" .. SecWatchlist.SIDECAR_LEDGER)
        if ledger then snapshot.ledger = ledger end
    end

    if data then
        local keep, dropped = {}, {}
        local drop_set, anno_set = {}, {}
        for _ki = 1, #SecWatchlist.DROP_KEYS do
            drop_set[SecWatchlist.DROP_KEYS[_ki]] = true
        end
        for _ki = 1, #SecWatchlist.ANNOTATION_KEYS do
            anno_set[SecWatchlist.ANNOTATION_KEYS[_ki]] = true
        end

        local raw_keys = 0
        for key, value in pairs(data) do
            raw_keys = raw_keys + 1
            if drop_set[key] then
                dropped[#dropped + 1] = key
                if key == "percent_finished" then
                    snapshot.old_percent = tonumber(value)
                elseif key == "last_percent" and snapshot.old_percent == nil then
                    snapshot.old_percent = tonumber(value)
                end
            elseif anno_set[key] then
                if opts.keep_annotations then
                    keep[key] = value
                else
                    if type(value) == "table" then
                        snapshot.annotations_dropped = snapshot.annotations_dropped + #value
                    end
                    dropped[#dropped + 1] = key
                end
            elseif key ~= "__orderedIndex" then
                -- orderedPairs 的临时键，不能写回文件
                keep[key] = value
            end
        end
        -- 老版 KOReader 把读者设置放在 ["config"] 子表里；顺手也清一遍，
        -- 免得位置信息从那儿绕过清理活下来
        if type(keep.config) == "table" then
            for _ki = 1, #SecWatchlist.DROP_KEYS do
                local key = SecWatchlist.DROP_KEYS[_ki]
                if keep.config[key] ~= nil then
                    keep.config[key] = nil
                    dropped[#dropped + 1] = "config." .. key
                end
            end
        end

        snapshot.raw_keys = raw_keys
        snapshot.metadata = keep
        snapshot.dropped_keys = dropped
    end

    return snapshot, err
end

--- 打包**之后**调用：重建 `.sdr`。
---
--- 集成方照拄这个顺序（不需要改 sec_epub.lua，它里面那句 purgeDir 可以原样留着）：
---     local keep = SecWatchlist.keepProgress(epub_path)         -- ① 打包前
---     local ok, err = SecEpub:write(epub_path, book)            -- ② 打包
---     SecWatchlist.restoreProgress(epub_path, keep, { policy = "shift" })  -- ③ 打包后
--- 忘掉 ③ 也不会有副作用：只是回到「进度归零」的老行为，不会产生坏文件。
---
---@param snapshot table keepProgress 的返回值
---@param opts table|nil { policy = "reset"|"shift", old_chars / new_chars 用真实字符数
---                      代替字节数估算（更准）, keep_annotations = bool }
---@return boolean ok, table report, string|nil err
function SecWatchlist.restoreProgress(epub_path, snapshot, opts)
    opts = opts or {}
    if type(snapshot) ~= "table" then return nil, {}, "restoreProgress 缺少 snapshot" end

    local dir = snapshot.path or SecWatchlist.sidecarDirs(epub_path, opts)[1]
    local report = {
        dir = dir,
        metadata = {},
        notes = {},
        dropped_keys = snapshot.dropped_keys or {},
        annotations_dropped = snapshot.annotations_dropped or 0,
    }
    if snapshot.load_error then
        report.notes[#report.notes + 1] = snapshot.load_error
    end

    local ok_dir, derr = SecWatchlist.ensureDir(dir)
    if not ok_dir then return nil, report, tostring(derr) end

    local metadata = {}
    for key, value in pairs(snapshot.metadata or {}) do
        metadata[key] = value
    end

    -- 位置策略
    local policy = opts.policy or "reset"
    if policy == "shift" then
        local old_percent = tonumber(snapshot.old_percent)
        -- 优先用真实字符数（调用方知道正文字符数时传进来），否则用 epub 字节数估算：
        -- 同一个打包器编出来的两份相似 HTML，deflate 压缩比相差很小，拿字节数当代理
        -- 比拿页数当代理准得多（页数还要受字号/行距影响）。
        local old_units = tonumber(opts.old_chars)
        if not old_units and snapshot.ledger then
            old_units = tonumber(snapshot.ledger.content_chars) or tonumber(snapshot.ledger.epub_size)
        end
        old_units = old_units or tonumber(snapshot.old_size)
        local new_units = tonumber(opts.new_chars) or SecWatchlist.fileSize(epub_path)
        if old_percent and old_percent > 0 and old_units and new_units and new_units > 0 then
            local ratio = old_units / new_units
            if ratio > 1 then ratio = 1 end -- 内容反而变短了：宁可不平移，也别算出越界比例
            -- 旧书里 0→1 的 f 对应新书里 (1-ratio) + f*ratio
            local shifted = (1 - ratio) + old_percent * ratio
            if shifted < 0 then shifted = 0 end
            if shifted > 1 then shifted = 1 end
            metadata.last_percent = shifted
            metadata.percent_finished = shifted
            report.shifted_percent = shifted
            report.old_percent = old_percent
            report.ratio = ratio
            report.notes[#report.notes + 1] = string.format(
                "按内容增量平移：旧 %.1f%% → 新 %.1f%%（估算，误差在一份 filing 的量级内）",
                old_percent * 100, shifted * 100)
        else
            report.notes[#report.notes + 1] =
                "缺少旧进度或旧尺寸，shift 退化为 reset（本次从头开始）"
            policy = "reset"
        end
    end
    if policy == "reset" then
        report.notes[#report.notes + 1] =
            "已清掉位置信息：下次打开从书的开头开始（最新一份 filing 在最前面）"
    end
    report.policy = policy

    -- 台账：记下这本书当前的尺寸，下一次 shift 不用再靠猜
    local ledger = {
        updated_at = nowSeconds(),
        content_chars = tonumber(opts.new_chars),
        epub_size = SecWatchlist.fileSize(epub_path),
        policy = policy,
    }
    SecWatchlist.writeFileAtomic(dir .. "/" .. SecWatchlist.SIDECAR_LEDGER,
        SecWatchlist.serialize(ledger,
            "-- secfilings 进度台账（插件自己用，KOReader 不读）\n"))

    -- 元数据最后写：前面两步任一失败都不会留下一个「看上去正常」的 .sdr
    local meta_path = dir .. "/" .. SecWatchlist.SIDECAR_METADATA
    local ok_w, werr = SecWatchlist.writeFileAtomic(meta_path,
        SecWatchlist.serialize(metadata,
            "-- 由 secfilings.koplugin 重建：保留外观设置，清掉失效的位置\n"))
    if not ok_w then
        return nil, report, "写入 " .. meta_path .. " 失败：" .. tostring(werr)
    end

    -- crengine 的磁盘缓存其实在 koreader/cache/cr3cache（不在 .sdr 里），但旧版
    -- KOReader 会在 `.sdr/cache/` 放缓存；内容换了必须清掉，否则可能读到旧排版。
    -- 目录留着（KOReader 会自己重建），里面的缓存文件删干净。
    local cache_dir = dir .. "/cache"
    if SecWatchlist.isDir(cache_dir) then
        local ok_rm = SecWatchlist.removeTree(cache_dir)
        if ok_rm then
            SecWatchlist.ensureDir(cache_dir)
            report.notes[#report.notes + 1] = "已清掉 .sdr/cache 里的旧排版缓存"
        end
    end

    report.kept_keys = 0
    for _key in pairs(metadata) do
        report.kept_keys = report.kept_keys + 1
    end
    return true, report
end

--- 丢掉 `.sdr`（不保留任何东西）。集成方如果暂时不想接保留逻辑，用它显式表达意图。
---@return boolean ok, table info { removed = n }
function SecWatchlist.forgetProgress(epub_path, opts)
    opts = opts or {}
    local dirs = SecWatchlist.sidecarDirs(epub_path, opts)
    local removed = 0
    for _di = 1, #dirs do
        if SecWatchlist.isDir(dirs[_di]) then
            local ok = SecWatchlist.removeTree(dirs[_di])
            if ok then removed = removed + 1 end
        end
    end
    return true, { removed = removed }
end

return SecWatchlist
