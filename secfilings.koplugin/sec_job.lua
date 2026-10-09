--[[
SEC 财报「抓取 → 清洗 → 图片落地 → 关键指标 → 打包」的编排层（波次二接线版）。

这个文件为什么单独存在
  整段活是在 Trapper 的协程里跑的，而 KOReader 的进度提示 Trapper:info()
  内部会 coroutine.yield()（见 frontend/ui/trapper.lua）。LuaJIT 不允许跨
  pcall 边界 yield，一旦把它包进 pcall，就会立刻得到
  "attempt to yield across a C-call boundary"。
  所以这里定下两条死规矩：
    1) 不用 pcall 包住任何可能 yield 的调用；
    2) 不用 error() 往上抛异常 —— 错误一律靠返回值传。某一环失败只记一条
       说明、跳过那个单元（那份 filing / 那家公司），不中断整轮。
  唯一的例外是 json.decode / cre.getBalancedHTML 这类纯 C 调用：它们不会
  yield，本身又会抛错，包 pcall 是安全且必要的。

  同时它不 require 任何 ui/*，不碰 Trapper / UIManager，
  因此可以脱开界面、用 luajit 直接无头跑通。这正是上一轮交付翻车的根因：
  逻辑和界面糊在一起，结果只能靠手点菜单验证。

  进度提示通过 progress_cb 回调交给调用方（界面外壳传的是 Trapper:info），
  本文件只负责调用它；progress_cb 返回 false 表示用户点了取消。
  注意「可能 yield 的回调必须在 pcall 之外调用」这一条同样适用于下挂的回调：
    · SecImages 的 opts.on_progress（它自己在 pcall 之外调，见 sec_images.lua）
    · SecMetrics.collectConcepts 的 progress_cb
    · SecWatchlist 的进度类函数不回调

波次二把四个纯逻辑模块接成了完整链路：
  · sec_images.lua     每份 filing 清洗完的 HTML → 真图下载 → 重写后的 HTML + 条目清单
  · sec_metrics.lua    每本书的**第一章**「关键指标」（SEC 官方 XBRL）
  · sec_watchlist.lua  增量判定（基线按 filing_date 比）+ 阅读进度保留
  · _meta/设置          User-Agent（含邮箱）由调用方从设置拼好传进来

对外只有一个入口：
  SecJob.run(companies, opts, progress_cb) -> results, errors, info

  companies = { { cik = 数字, name = "微软", legal = "Microsoft Corp." }, ... }
  opts      = 见下面「opts 一览」
  results   = { { name, cik, path, chapters, bytes, images, images_bytes,
                  images_failed, metrics, metrics_ok, new_count,
                  skipped = {...}, warnings = {...} }, ... }
  errors    = { "人类可读的失败说明", ... }   -- 只有整家失败才进这里
  info      = 整轮汇总（旧调用方忽略第三个返回值也能照常工作）

opts 一览
  ── 波次一就在用的 ────────────────────────────────────────────────────
  limit            number  每家公司最多几份（默认 5）
  include_reports  bool    是否含 10-K/10-Q（默认 false，即只要 8-K）
  out_dir          string  成品目录（默认 SecJob.default_out_dir）

  ── User-Agent（契约 4）────────────────────────────────────────────────
  user_agent       string  调用方从设置拼好的完整 UA，**必须含邮箱**
  user_name        string  只给邮箱时用来拼 "<名字> <邮箱>"
  user_email       string  SEC 要求的联系邮箱
  三者都没给或没邮箱时：用 SecJob.user_agent_placeholder 占位，
  并把 SecJob.USER_AGENT_HINT 放进 errors / info.warnings ——
  「没填邮箱」这个原因必须让用户看见（SEC 会回 403，不说清就是静默失败）。

  ── 本波新增的开关 ─────────────────────────────────────────────────────
  fetch_images     bool    是否抓正文里的图片（默认 true）
  metrics_chapter  bool    是否在书首生成「关键指标」章（默认 true）
  table_avail_em   number  单张表可用宽度（表格 em）→ 透传给 sec_source
  table_max_cols   number  单张表列数上限                → sec_source
  table_projection bool    宽表按列拆分总开关            → sec_source
  work_dir         string  图片等工作文件的落地目录（默认 SecJob.default_work_dir）
  keep_images      bool    打完包是否保留 work 目录（默认 false：设备空间紧张）
  keep_progress    bool    是否保留阅读进度（默认 true，契约 5）
  progress_policy  string  keepProgress/restoreProgress 的策略（默认 "reset"）
  watchlist        table   sec_watchlist 的列表对象；**给了才做增量过滤**
  save_watchlist   string|LuaSettings|true  给了就代写回关注列表（不给自己写）
  cover_dir        string  封面素材目录（<cik>.jpg，回退 generic.jpg）。
                          给了才给书加封面；加了就会被拷进 images_dir 下，
                          文件名固定 cover.jpg（sec_epub 只认 href，而 zip 里的位置
                          由 addPath 的目录结构决定，所以必须真的拷进去）
  scan_limit       number  增量计划时每家公司往下翻多少条元数据（默认 60）
  first_run_new    number  首次运行最多取几份（默认 10，planUpdates 的同名参数）
  since_date       string  "YYYY-MM-DD"，早于此日期的不要
  image_max_width / image_jpeg_quality / image_throttle_ms / image_attempts /
  image_timeout    图片参数（透传给 sec_images，不给就用它的默认值）
  metrics_tags     只取这些 tag（传给 sec_metrics，默认全部候选）
  source           注入另一个 sec_source 兼容对象（测试用）
  images_fetch     注入图片传输层 function(url, dst, opts)（本机没有 LuaSocket 时用）
  metrics_fetch    注入指标传输层 function(url, opts)（同上）
  metrics_on_tag_loaded  取样钩子，跑内存实测用（原样传给 sec_metrics）

  ── 契约 1 的数据出口 ─────────────────────────────────────────────────
  book.images      = sec_images 的 res.entries 原样累加（每本书一份）
  book.images_dir  = 图片文件所在目录（交给 sec_epub 的 epub:addPath 用）
  本文件只负责把这两个字段填对；生成 OPF 的 <item> 由 sec_epub.lua 做。
]]

local logger = require("logger")

local SecSource = require("sec_source")
local SecEpub = require("sec_epub")
local SecImages = require("sec_images")
local SecMetrics = require("sec_metrics")
local SecWatchlist = require("sec_watchlist")
local Filing = require("sec_filing")
local Library = require("sec_library")

local SecJob = {}

-- 本文件同样不用 `_` 作循环变量（原因见 sec_source.lua 顶部说明）。

SecJob.default_out_dir = "/mnt/us/documents/SEC 财报"

--- 图片等工作文件的落地目录。
--- 为什么不放在插件数据目录（DataStorage:getDataDir()，也就是 /mnt/us/koreader）：
--- 设备 rootfs 只剩约 11.7MB，而一本书的图片就有一两 MB 起，写在那儿等于把系统盘写满。
--- /mnt/us 是用户分区、空间充足，目录名也一眼能看出是插件的临时文件。
SecJob.default_work_dir = "/mnt/us/secfilings-work"

--- 邮箱没设置时的占位 UA。
--- 为什么不硬编码一个邮箱：这是要开源出去的东西，写谁的邮箱都不对
--- （上一版就是硬编码的 "Kindle SEC Reader <you@example.com>"）。
SecJob.user_agent_placeholder = "koreader-sec-filings (联系邮箱未设置)"

--- 没填邮箱时必须让用户看到的一句话（界面把它显示出来，不要静默失败）。
SecJob.USER_AGENT_HINT = "未设置联系邮箱：SEC 要求 User-Agent 里带可联系的邮箱，" ..
    "否则所有请求都会返回 403。请到「工具 → SEC 研习室 → 设置 → SEC 联系邮箱」" ..
    "里填一个地址再重试。（这一条不是某一家公司的失败，是设置缺失。）"

--- 打包前后保留阅读进度时用的默认策略。
--- "reset"：保留读者的字号/行距/页边距等设置，把「翻到第几页」清零 ——
--- 内容换了以后旧位置本来就指不到同一处，清零比乱跳好。
SecJob.default_progress_policy = "reset"

--- 增量计划时每家公司往下翻多少条元数据。
--- 60 条三大类 filing 对这几家公司大约覆盖两年，足以回答「有没有新东西」；
--- 再往前翻只是白花流量（首次运行也只会取最近若干份，见 sec_watchlist 的基线语义）。
SecJob.default_scan_limit = 60

--- 把输出/工作目录准备好（多级目录也认）。
---@return boolean|nil, string|nil
function SecJob.ensureDir(dir)
    -- 交给 sec_watchlist 的实现：它会找第一个已存在的祖先再逐级 mkdir，
    -- 拿不到 lfs 时退化成 shell —— 这三种情况在本文件里都要处理，没必要再抄一遍。
    return SecWatchlist.ensureDir(dir)
end

--- 调一次进度回调。返回 false 表示用户取消了整轮。
--- 注意：这里故意不包 pcall —— progress_cb 内部会 yield。
---@return boolean
local function tick(progress_cb, msg)
    if not progress_cb then return true end
    return progress_cb(msg) ~= false
end

--- 我们自己插进 HTML 的文本（例如章节说明）要转义；
--- 原文一个字都不动（那是 sec_source 的活）。
local function esc(s)
    if s == nil then return "" end
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

--------------------------------------------------------------------------
-- 一、User-Agent（契约 4）
--------------------------------------------------------------------------

--- UA 里有没有一个长得像邮箱的东西。
--- 只做形状判断，不去猜「这个邮箱是不是真的能用」——那是 SEC 的事。
local function hasEmail(ua)
    return type(ua) == "string" and ua:match("[%w%.%-_%+]+@[%w%.%-]+%.%a%a+") ~= nil
end
SecJob.hasEmail = hasEmail

--- 决定这一轮用哪个 UA。返回 ua, 是否含邮箱。
--- 优先级：opts.user_agent > opts.user_name + opts.user_email > SecSource.user_agent
---         （调用方可能直接设了模块字段） > 占位值。
local function resolveUserAgent(opts)
    local ua = opts.user_agent
    if (type(ua) ~= "string" or ua == "")
        and type(opts.user_email) == "string" and opts.user_email ~= "" then
        ua = string.format("%s %s", opts.user_name or "KOReader SEC filings", opts.user_email)
    end
    if type(ua) ~= "string" or ua == "" then
        ua = SecSource.user_agent
    end
    if type(ua) ~= "string" or ua == "" then
        ua = SecJob.user_agent_placeholder
    end
    if not hasEmail(ua) then
        -- 没邮箱就换成占位值：请求会 403，但至少不会把某个人的邮箱带进仓库，
        -- 而且调用方会拿到 USER_AGENT_HINT 明确知道该去设置里填什么。
        ua = SecJob.user_agent_placeholder
        return ua, false
    end
    return ua, true
end

--------------------------------------------------------------------------
-- 二、把配置交给 sec_source（表格宽度参数 + UA）
--------------------------------------------------------------------------

--- 表格宽度参数的键名。这几个常量在 sec_source.lua 顶部是模块级字段
--- （契约 3 明确写了它们的名字），所以这里直接写模块字段。
local SOURCE_TUNABLES = { "table_avail_em", "table_max_cols", "table_projection" }

---@return table src, table warnings
local function configureSource(opts, ua, warnings)
    local src = opts.source or SecSource
    local cfg = {}
    if opts.table_avail_em ~= nil then cfg.table_avail_em = tonumber(opts.table_avail_em) end
    if opts.table_max_cols ~= nil then cfg.table_max_cols = tonumber(opts.table_max_cols) end
    if opts.table_projection ~= nil then cfg.table_projection = opts.table_projection and true or false end

    for _ti = 1, #SOURCE_TUNABLES do
        local key = SOURCE_TUNABLES[_ti]
        local value = cfg[key]
        if value ~= nil then
            if src[key] ~= nil then
                src[key] = value
            else
                -- 参数名对不上就说出来。悄悄忽略是最坏的结果：用户在设置里
                -- 改了「表格宽度」，书里一点变化都没有，还找不到原因。
                warnings[#warnings + 1] = string.format(
                    "sec_source 上没有 %s 这个参数，该项设置本次不生效（可能版本不匹配）", key)
            end
        end
    end

    -- 取数路径读的是 self.user_agent（sec_source.lua:fetch），所以写模块字段最稳；
    -- 实例也要设一次，万一 F2 之后改成实例构造也不会漏。
    src.user_agent = ua

    if type(src.new) == "function" then
        -- 契约 3 写的是 `SecSource:new{...}` 形态，所以按冒号调用。
        -- 这里用 pcall **是安全的**：构造函数是纯计算，不会 yield，
        -- 而它万一签名对不上，我们宁可退回模块字段，也不要让整轮下载挂掉。
        local ok_new, inst = pcall(src.new, src, cfg)
        if ok_new and type(inst) == "table" and type(inst.cleanHtml) == "function" then
            if src.user_agent ~= nil or inst.user_agent == nil then inst.user_agent = ua end
            return inst
        end
    end

    return src
end

--------------------------------------------------------------------------
-- 三、增量计划（契约 5 的过滤部分）
--------------------------------------------------------------------------

--- 关注列表的**本轮视图**：把 include_reports 开关折进 forms，
--- 交给 SecWatchlist.planUpdates 去过滤。
--- 为什么要造视图而不是直接改 entries：关注列表是用户的数据（main.lua 负责存储），
--- sec_job 只该读它。视图是浅拷贝，seen / seen_upto_date 仍然是同一个引用（只读使用），
--- 落账时 commit 拿的是原列表，所以不会读到视图里的临时 forms。
---@return table view
local function planView(wl, opts)
    local view = {
        version = wl.version,
        keep_seen = wl.keep_seen,
        entries = {},
    }
    for _ei = 1, #wl.entries do
        local entry = wl.entries[_ei]
        local copy = {}
        for key, value in pairs(entry) do copy[key] = value end
        if not opts.include_reports then
            -- 与旧行为一致：关掉「完整报告」就只下 8-K
            copy.forms = { "8-K" }
        end
        view.entries[#view.entries + 1] = copy
    end
    return view
end

--- 取每家公司最近的文件元数据。
---@return table|nil fetched, table notes, boolean cancelled
local function fetchMetadata(src, companies, opts, progress_cb, notes)
    local fetched = {}
    for ci = 1, #companies do
        local company = companies[ci]
        if not tick(progress_cb, string.format("正在查 %s 有哪些文件（%d / %d）…",
                company.name, ci, #companies)) then
            return nil, notes, true
        end
        local filings, err = src:recentFilings(company.cik, opts.scan_limit)
        if not filings then
            notes[#notes + 1] = string.format("%s：取文件清单失败（%s）", company.name, tostring(err))
            filings = {}
        end
        fetched[#fetched + 1] = { cik = company.cik, name = company.name, filings = filings }
    end
    return fetched, notes, false
end

--- 旧行为（没有关注列表时）：取最近若干份候选，按开关过滤后截到 limit 份。
--- 保留它是因为 main.lua 的「下载某一家」以及既有测试脚本都走这条路，
--- 而且「某家不在关注列表里」时也要能正常下载（见 planRun）。
---@return table|nil picked, string|nil err
local function pickLegacy(filings, opts, want)
    if not filings or #filings == 0 then
        return nil, "SEC 上没找到近期的 8-K / 10-K / 10-Q"
    end
    local picked = {}
    for fi = 1, #filings do
        local f = filings[fi]
        local is_report = f.form:match("^10%-") and true or false
        if opts.include_reports or not is_report then
            picked[#picked + 1] = f
            if #picked >= want then break end
        end
    end
    if #picked == 0 then
        return nil, string.format("近 %d 份 filing 里没有 8-K（可到设置里打开 10-K/10-Q）", #filings)
    end
    return picked
end

--- 算出这一轮每家要下哪些文件。
---
--- 给了 watchlist 就走增量：planUpdates 只看「form 命中 + 没下过 + 不早于基线」的文件，
--- 基线是**日期**（filing_date），不是 accession —— 波次一已证明 accession 前缀是
--- 上报代理编号，按它排序会把 2016 年的文件排到 2026 年后面。
---
--- 不在关注列表里的公司（例如「只下某一家」而这家没被关注）退回旧行为，
--- 不静默跳过 —— 静默跳过会表现为「点了下载什么都没发生」。
---@return table|nil plan, string|nil err  plan = { {company=, filings={}, update=}, ... }
local function planRun(src, companies, opts, progress_cb, warnings)
    if opts.selected_filing then
        if #companies ~= 1 then return nil, "单份下载必须指定一家公司" end
        local filing, err = SecWatchlist.normalizeFiling(opts.selected_filing)
        if not filing or filing.form == "" or not SecWatchlist.isValidDate(filing.date) then
            return nil, err or "所选申报文件信息不完整"
        end
        return {items={{company=companies[1], filings={filing}, explicit=true}}, no_new={}}
    end
    local wl = opts.watchlist
    local worklist, index, no_new = {}, {}, {}
    local notes = {}

    local fetched
    if wl and wl.entries then
        local cancelled
        fetched, notes, cancelled = fetchMetadata(src, companies, opts, progress_cb, notes)
        if cancelled then return nil, "cancelled" end
    end

    local updates
    if fetched then
        local uerr
        updates, uerr = SecWatchlist.planUpdates(planView(wl, opts), fetched, {
            max_new_per_company = opts.limit,
            first_run_new       = opts.first_run_new,
            since_date          = opts.since_date,
            only_enabled        = opts.only_enabled,
        })
        if not updates then
            return nil, "增量判定失败：" .. tostring(uerr)
        end
        for ui = 1, #updates do
            index[SecWatchlist.normalizeCik(updates[ui].cik) or tostring(updates[ui].cik)] = updates[ui]
        end
    end

    for ci = 1, #companies do
        local company = companies[ci]
        local update = index[SecWatchlist.normalizeCik(company.cik) or ""]
        if update then
            -- planUpdates 自己报出的注意事项（元数据没取到、日期读不出来、重复 accession…）
            -- 必须带出去。它们正是「为什么这次什么都没下」的答案。
            local uw = update.warnings or {}
            for wi = 1, #uw do
                warnings[#warnings + 1] = string.format("%s：%s", company.name, uw[wi])
            end
            if update.new_count > 0 then
                worklist[#worklist + 1] = { company = company, filings = update.new_filings, update = update }
            else
                no_new[#no_new + 1] = company.name
                local line = string.format("%s：没有新文件（%s）", company.name,
                    #uw > 0 and uw[1] or string.format("已下过 %d 份%s", update.seen_before or 0,
                        update.baseline_date and ("，基线 " .. update.baseline_date) or "，还没有基线"))
                warnings[#warnings + 1] = line
                logger.info("secfilings: " .. line)
            end
        else
            -- 在关注列表里但被关掉了：这是用户的明确选择，报一句就跳过，
            -- 绝不能退回旧行为把它又下一遍（那会让「取消关注」看起来没生效）。
            local entry = wl and SecWatchlist.find(wl, company.cik)
            if entry and entry.enabled == false and opts.only_enabled ~= false then
                warnings[#warnings + 1] = string.format("%s：已关闭关注，本轮跳过", company.name)
            else
                -- 不在关注列表里：退回旧行为，不要静默跳过
                local filings, ferr = src:recentFilings(company.cik, opts.limit * 4 + 8)
                if not filings then
                    worklist[#worklist + 1] = { company = company, error = tostring(ferr) }
                else
                    local picked, perr = pickLegacy(filings, opts, opts.limit)
                    if not picked then
                        worklist[#worklist + 1] = { company = company, error = perr }
                    else
                        worklist[#worklist + 1] = { company = company, filings = picked, legacy = true }
                    end
                end
            end
        end
    end

    for ni = 1, #notes do warnings[#warnings + 1] = notes[ni] end
    return { items = worklist, no_new = no_new, updates = updates }
end

--------------------------------------------------------------------------
-- 四、图片（契约 1）
--------------------------------------------------------------------------

--- 一份 filing 的图片目录名（namespace）。
--- 为什么必须唯一：一本书里所有图片共用一个 OEBPS/images/，
--- 两幅图同名就会互相覆盖，而 OPF 里出现重复 id 就不再是合法 XML。
--- 同一家公司同一天可能有两份 8-K，光靠公司+日期还不够，所以把序号编进去。
local function imageNamespace(company, filing, index)
    return SecImages.safeNamespace(string.format("%s-%s-%s-%d",
        tostring(company.cik or "co"), tostring(filing.form or "form"),
        tostring(filing.date or "date"), index))
end

--- 一家公司一份工作目录。
--- 为什么按公司分目录：图片必须能“用完即清”，而 addPath 会把目录下**所有**文件
--- 都打进 zip（sec_epub 会把这个事实报出来）。共享一个 images/ 目录时，清理只能删
--- 单个 namespace 子目录，漏一点就会把上一家的图也带进下一本书。
local function bookWorkDir(run_opts, company)
    if run_opts.current_filing_work_dir then
        return run_opts.current_filing_work_dir
    end
    return string.format("%s/co_%s", run_opts.work_dir, tostring(company.cik))
end

--- 封面：把素材目录里的 <cik>.jpg 拷到 images_dir 下，返回 sec_epub 认的 cover 表。
---
--- 为什么必须“拷进 images 目录”而不是直接给个外部路径：sec_epub 只认 href，
--- 而 zip 里的位置是由 epub:addPath(images_dir) 按目录结构铺出来的（F1 的
--- imagePlan 就是按这个对应关系逐张核对的）。封面文件不在 images_dir 下时，
--- 它会被从 manifest 里去掉 —— 结果是 epub 里没有封面，而且**不会报错**。
--- href 写 "images/cover.jpg"，addPath 铺出来正好是 OEBPS/images/cover.jpg。
---
--- 素材缺失（目录不存在 / 这家公司没有专属封面 / 连 generic 也没有）时返回 nil，
--- 即回到“这本书没有封面”的旧行为，不影响成书。
---@return table|nil cover
local function prepareCover(run_opts, company, book_dir)
    local dir = run_opts.cover_dir
    if type(dir) ~= "string" or dir == "" then return nil end

    local src = string.format("%s/%s.jpg", dir, tostring(company.cik))
    if not SecWatchlist.fileExists(src) then
        src = dir .. "/generic.jpg"
        if not SecWatchlist.fileExists(src) then
            logger.info("secfilings: 封面素材不存在，本书不带封面：", dir)
            return nil
        end
    end

    local images_dir = book_dir .. "/images"
    SecWatchlist.ensureDir(images_dir, { recursive = true })
    local dst = images_dir .. "/cover.jpg"

    local fin = io.open(src, "rb")
    if not fin then
        logger.warn("secfilings: 封面读不到：", src)
        return nil
    end
    local data = fin:read("*a")
    fin:close()
    if type(data) ~= "string" or #data == 0 then
        logger.warn("secfilings: 封面是空的：", src)
        return nil
    end

    -- JPEG 是二进制，不能用 writeFileAtomic（那是给文本用的）。
    local fout = io.open(dst, "wb")
    if not fout then
        logger.warn("secfilings: 封面写不下去：", dst)
        return nil
    end
    fout:write(data)
    fout:close()

    return { href = "images/cover.jpg", mediaType = "image/jpeg" }
end

--- 抓一份 filing 的图片，把结果累加进 book。
--- 保留原样赋值：book.images 就是 sec_images 的 res.entries（形状不动），
--- book.images_dir 交给 sec_epub 的 addPath 用（契约 1）。
---@return string html, table|nil res, string|nil err, boolean cancelled
local function fetchImages(company, filing, fi, cleaned, base_url, run_opts, ctx, progress_cb)
    local ns = imageNamespace(company, filing, fi)
    local cancelled = false
    local res, err = SecImages:run(cleaned, base_url, {
        user_agent = run_opts.user_agent,
        -- 图片落在 <work_dir>/co_<cik>/images/<namespace>/，与 book.images_dir 逐字一致：
        -- sec_epub 用「dir .. "/" .. href 去掉 images/ 前缀」推出磁盘路径，
        -- 两边只要差一层目录就会静默把图从 manifest 里去掉。
        dir        = bookWorkDir(run_opts, company),
        namespace  = ns,
        fetch      = run_opts.images_fetch,
        max_width  = run_opts.image_max_width,
        jpeg_quality = run_opts.image_jpeg_quality,
        throttle_ms  = run_opts.image_throttle_ms,
        attempts     = run_opts.image_attempts,
        timeout      = run_opts.image_timeout,
        downscale    = run_opts.image_downscale,
        -- 这个回调会在每张图之前被调一次，而且必须能 yield（设备上是 Trapper:info）。
        -- sec_images 保证它在自己的 pcall 之外调用；我们这里也只用返回值传状态。
        on_progress = function(done, total)
            if not tick(progress_cb, string.format("%s：正在下载图片 %d / %d",
                    company.name, done, total)) then
                cancelled = true
            end
        end,
    })
    if not res then
        return cleaned, nil, tostring(err), cancelled
    end
    for ei = 1, #res.entries do
        ctx.images[#ctx.images + 1] = res.entries[ei]
        ctx.image_bytes = ctx.image_bytes + (tonumber(res.entries[ei].bytes) or 0)
    end
    ctx.image_failed = ctx.image_failed + ((res.stats and res.stats.failed) or 0)
    return res.html, res, nil, cancelled
end

--------------------------------------------------------------------------
-- 五、一份 filing → 一个章节
--------------------------------------------------------------------------

---@return table|nil chapter, boolean cancelled
local function gatherFiling(src, company, filing, fi, run_opts, progress_cb, ctx)
    local is_report = filing.form:match("^10%-") and true or false
    local items = filing.items or ""

    if not tick(progress_cb, string.format("%s：正在取 %s %s …",
            company.name, filing.form, filing.date)) then
        return nil, true
    end

    local content, cerr = src:filingContent(company.cik, filing)
    if not content then
        ctx.skipped[#ctx.skipped + 1] = string.format("%s %s（%s）",
            filing.form, filing.date, tostring(cerr))
        return nil, false
    end

    local cleaned, cinfo = src:cleanHtml(content.html)
    if not cleaned or #cleaned < 200 then
        -- 清理完短得不像正文，宁可不放，免得书里出现空白章节
        ctx.skipped[#ctx.skipped + 1] = string.format("%s %s（清理后正文过短，已弃用）",
            filing.form, filing.date)
        return nil, false
    end

    -- 章节说明要诚实告知缺失的部分，否则读者会以为内容本来就这么少
    local note_parts = {}
    if (not is_report) and items ~= "" then
        note_parts[#note_parts + 1] = "8-K 条目：" .. items
    end

    local raw_images = (cinfo and cinfo.images) or 0
    local html = cleaned
    local got_images, failed_images = 0, 0

    if raw_images > 0 then
        if not run_opts.fetch_images then
            note_parts[#note_parts + 1] = string.format(
                "幻灯片类文件（原文含 %d 张图片）：按你的设置没有抓取图片，"
                .. "此处为原文的文字层，数字与表格均在", raw_images)
        else
            local has_img_tag = cleaned:lower():find("<img", 1, true) ~= nil
            if not has_img_tag then
                -- 这一条是跨文件依赖的哨兵：cleanHtml 旧版第 6 步会把 <img> 整个删掉，
                -- 只回报数量。那时 sec_images 拿到的正文里一张图都没有，
                -- 用户看到的是「有图的书」变成「没图的书」，却没有任何报错。
                ctx.warnings[#ctx.warnings + 1] = string.format(
                    "%s %s：正文里原本有 %d 张图片，但清理管线把 <img> 标签丢掉了，"
                    .. "本轮一张图都没抓（需要 sec_source:cleanHtml 保留 <img>：只计数不删除）",
                    filing.form, filing.date, raw_images)
                note_parts[#note_parts + 1] = string.format(
                    "原文含 %d 张图片，但清理阶段没有保留图片标签，本轮图片未取到；"
                    .. "此处为原文的文字层，数字与表格均在", raw_images)
            else
                local new_html, res, ierr, cancelled = fetchImages(company, filing, fi,
                    cleaned, content.url, run_opts, ctx, progress_cb)
                if cancelled then return nil, true end
                if not res then
                    ctx.warnings[#ctx.warnings + 1] = string.format(
                        "%s %s：图片处理失败（%s）", filing.form, filing.date, tostring(ierr))
                    note_parts[#note_parts + 1] = string.format(
                        "原文含 %d 张图片，但图片处理失败（%s），此处为原文的文字层",
                        raw_images, tostring(ierr))
                else
                    html = new_html
                    got_images = (res.stats and res.stats.ok) or 0
                    failed_images = (res.stats and res.stats.failed) or 0
                    local part = string.format(
                        "幻灯片类文件（原文含 %d 张图片，已下载 %d 张嵌在正文里）",
                        raw_images, got_images)
                    if failed_images > 0 then
                        part = part .. string.format("；另有 %d 张取不到，正文里留下原图的 alt 文字",
                            failed_images)
                    end
                    note_parts[#note_parts + 1] = part
                    -- 抓失败的图会把原因写进 res.log，逐条带进日志便于排查
                    for li = 1, #(res.log or {}) do
                        if res.log[li]:find("失败", 1, true) then
                            ctx.warnings[#ctx.warnings + 1] = string.format("%s %s：%s",
                                filing.form, filing.date, res.log[li])
                        end
                    end
                end
            end
        end
    end

    local chapter = {
        id         = string.format("secf%d", ctx.chapter_index + 1),
        company    = company.name,
        company_id = "co_" .. tostring(company.cik),
        heading    = string.format("%s %s · %s", company.name, filing.form, filing.date),
        -- meta 是带 <a> 的 HTML 片段，会被原样插进 content.html，
        -- 所以 url 里的 & 必须自己转义
        meta       = string.format(
            "Form %s ｜ 提交日 %s ｜ 登记号 %s ｜ 来源 %s ｜ <a href=\"%s\">原始文件</a>",
            filing.form, filing.date, filing.accn, content.why, (content.url:gsub("&", "&amp;"))),
        note       = #note_parts > 0 and table.concat(note_parts, "；") or nil,
        html       = html,
        -- 下面几个字段 sec_epub 不读，留给落账与验收脚本用
        accn       = filing.accn,
        form       = filing.form,
        date       = filing.date,
        images     = got_images,
        images_failed = failed_images,
    }
    ctx.chapter_index = ctx.chapter_index + 1
    return chapter, false
end

--------------------------------------------------------------------------
-- 六、关键指标章节（每本书的第一章）
--------------------------------------------------------------------------

--- 生成「关键指标」章。
--- 取数失败**不返回错误给上一层**：关键指标是锦上添花，原始报表才是正文，
--- 不能因为 SEC 的 XBRL 接口抽风就让整本书失败。
---@return table|nil chapter, table|nil data, string|nil why, boolean disabled
local function metricsChapter(company, run_opts, progress_cb)
    if not run_opts.metrics_chapter then return nil, nil, "用户关掉了这一章", true end
    if not company.cik then return nil, nil, "这家公司没有 CIK，无法取结构化数据", false end

    local ok, data, err = SecMetrics.collectConcepts(company, {
        user_agent    = run_opts.user_agent,
        fetch         = run_opts.metrics_fetch,
        tags          = run_opts.metrics_tags,
        on_tag_loaded = run_opts.metrics_on_tag_loaded,
    }, function(msg) return tick(progress_cb, msg) end)
    if not ok then return nil, nil, tostring(err), false end

    local ok2, xhtml, err2 = SecMetrics.buildChapter(company, data,
        run_opts.metrics_chapter_opts or {})
    if not ok2 then return nil, data, tostring(err2), false end

    return {
        id         = string.format("metrics_%s", tostring(company.cik)),
        company    = company.name,
        company_id = "co_" .. tostring(company.cik),
        heading    = run_opts.single_filing and "公司最新指标快照（非本份申报）" or "关键指标",
        -- meta 会被原样插进 content.html，所以自己转义
        meta       = esc(string.format(
            "数据来源 SEC 官方 XBRL（data.sec.gov）｜ 取到 %d / %d 个指标 ｜ 数据截至 %s",
            data.ok_count or 0, #(data.metrics or {}), tostring(data.as_of or "—"))),
        note       = run_opts.single_filing and "以下为抓取时可获得的公司最新 XBRL 数据，不一定属于本份申报或本期财报；请以各指标标注期间和原文为准。" or nil,
        html       = xhtml,
        metrics    = true,
    }, data, nil, false
end

--------------------------------------------------------------------------
-- 七、落账（增量状态）
--------------------------------------------------------------------------

--- 把「这一轮真的下了哪些」记进关注列表。
--- 为什么不能无脑 commit：commit 会把 update.new_filings 里**全部** accession 标成
--- 见过。某一份因为网络断了没下成时，它就被永久标记成「下过」—— 那正是本项目
--- 反复踩过的静默丢数据。所以只有「选的都下成功」时才 commit，
--- 否则只标成功的那几份，并且不推进基线（下一轮还会再出现）。
---@param ok_accns table 真的取到正文并进了书的 accession
---@param packaged boolean 这本书到底有没有写成功（打包失败不算下成功）
local function recordSeen(wl, update, ok_accns, packaged, warnings)
    if not wl or not update then return end
    local total = #update.new_filings
    local marked = #ok_accns
    local full = (marked == total) and packaged

    if full then
        local ok, info = SecWatchlist.commit(wl, update, {})
        if not ok then
            warnings[#warnings + 1] = string.format("%s：增量状态落账失败（%s）",
                tostring(update.name), tostring(info))
        end
    else
        if marked > 0 and packaged then
            SecWatchlist.markSeen(wl, update.cik, ok_accns, {})
            -- 只有真下到了东西才标「首次运行已完成」：标了会让下一轮的取数上限
            -- 从 first_run_new 变成 max_new —— 全部失败时不该有这种副作用。
            local entry = SecWatchlist.find(wl, update.cik)
            if entry then entry.first_run_done = true end
        end
        warnings[#warnings + 1] = string.format(
            "%s：%d 份里只有 %d 份下了下来%s，剩下的下次会再试（没有标成已下过）",
            tostring(update.name), total, marked,
            packaged and "" or "（打包失败，本轮不算成功）")
    end
    SecWatchlist.markChecked(wl, update.cik, { latest_filing_date = update.latest_filing })
end

--------------------------------------------------------------------------
-- 八、跑一轮
--------------------------------------------------------------------------

local function runSingleFilings(companies, opts, progress_cb)
    local run_opts = {}
    for key, value in pairs(opts) do run_opts[key] = value end
    run_opts.limit = tonumber(opts.limit) or 5
    run_opts.single_filing = true
    run_opts.out_dir = opts.out_dir or SecJob.default_out_dir
    run_opts.work_dir = opts.work_dir or SecJob.default_work_dir
    run_opts.fetch_images = (opts.fetch_images ~= false)
    run_opts.metrics_chapter = opts.metrics_chapter and true or false
    run_opts.keep_progress = false
    run_opts.progress_policy = opts.progress_policy or SecJob.default_progress_policy
    run_opts.scan_limit = tonumber(opts.scan_limit) or SecJob.default_scan_limit
    run_opts.first_run_new = tonumber(opts.first_run_new)
    run_opts.only_enabled = opts.only_enabled
    run_opts.watchlist = opts.watchlist
    run_opts.save_watchlist = opts.save_watchlist
    run_opts.cover_dir = opts.cover_dir
    run_opts.table_avail_em = opts.table_avail_em
    run_opts.table_max_cols = opts.table_max_cols
    run_opts.table_projection = opts.table_projection
    run_opts.source = opts.source
    run_opts.images_fetch = opts.images_fetch
    run_opts.metrics_fetch = opts.metrics_fetch
    run_opts.metrics_tags = opts.metrics_tags
    run_opts.image_max_width = opts.image_max_width
    run_opts.image_jpeg_quality = opts.image_jpeg_quality
    run_opts.image_throttle_ms = opts.image_throttle_ms
    run_opts.image_attempts = opts.image_attempts
    run_opts.image_timeout = opts.image_timeout
    run_opts.image_downscale = opts.image_downscale

    local results, errors, warnings = {}, {}, {}
    local info = { companies = #companies, planned = 0, made = 0, files = 0,
        images = 0, images_failed = 0, image_bytes = 0,
        metrics_ok = 0, metrics_failed = 0, no_new = 0,
        cancelled = false, warnings = warnings, single_filing = true }
    local library = Library:new(run_opts)
    local translator = opts.translate and library:translator(opts)
    local ua, ua_ok = resolveUserAgent(opts)
    run_opts.user_agent = ua
    info.user_agent = ua
    info.user_agent_set = ua_ok
    if not ua_ok then
        errors[#errors + 1] = SecJob.USER_AGENT_HINT
        warnings[#warnings + 1] = SecJob.USER_AGENT_HINT
    end

    local valid_roots, roots_err = library:validateRoots()
    if not valid_roots then return results, {roots_err}, info end
    local ok_dir, dir_err = SecJob.ensureDir(run_opts.out_dir)
    if not ok_dir then return results, { dir_err }, info end
    if run_opts.fetch_images then SecJob.ensureDir(run_opts.work_dir) end
    -- Per-filing cache directories are created by Library:translate only after verification.
    local translation_files = 0
    local max_translation_files = math.max(0, math.min(10,
        math.floor(tonumber(opts.translation_max_files) or 1)))
    local src = configureSource(run_opts, ua, warnings)
    run_opts.source = src
    local plan, plan_err = planRun(src, companies, run_opts, progress_cb, warnings)
    if not plan then
        if plan_err == "cancelled" then info.cancelled = true end
        errors[#errors + 1] = tostring(plan_err)
        return results, errors, info
    end
    local total = 0
    for pi = 1, #plan.items do total = total + #(plan.items[pi].filings or {}) end
    info.planned = total
    info.no_new = #(plan.no_new or {})

    local function addWarning(ctx, text)
        ctx.warnings[#ctx.warnings + 1] = text
        warnings[#warnings + 1] = text
    end

    local function finishOne(result, record, item, ctx)
        results[#results + 1] = result
        info.made, info.files = info.made + 1, info.files + 1
        info.images = info.images + (result.images or 0)
        info.images_failed = info.images_failed + (result.images_failed or 0)
        info.image_bytes = info.image_bytes + (result.images_bytes or 0)
        if result.metrics then info.metrics_ok = info.metrics_ok + 1 end
        -- Seen means the original AND its resumable snapshot were committed.
        if item.update and record then
            item.ok_accns[#item.ok_accns+1] = record.source.filing.accn
            SecWatchlist.markSeen(run_opts.watchlist, item.company.cik, {record.source.filing.accn}, {})
        end
        if translator and record then
            if translation_files >= max_translation_files then
                addWarning(ctx, "已达到本轮最多翻译文件数；此份仅生成原文")
            else
                translation_files = translation_files + 1
                local path, err = library:translate(record.paths.cik, record.paths.accn, translator, progress_cb)
                result.chinese_path = path
                if not path then
                    errors[#errors + 1] = string.format("%s %s：中文翻译未完成（%s）",
                        result.form, result.date, tostring(err))
                    return result, err == "已取消"
                end
            end
        end
        return result, false
    end

    local function buildOne(item, filing, position)
        local company = item.company
        local ctx = { skipped = {}, warnings = {}, images = {}, image_bytes = 0,
            image_failed = 0, chapter_index = 0 }
        if not tick(progress_cb, string.format("正在处理 %s %s %s（%d / %d）…",
                company.name, filing.form, filing.date, position, total)) then
            return nil, true
        end
        local valid_paths, path_err = library:validateTargets(company, filing)
        if not valid_paths then errors[#errors+1] = path_err; return nil, false end
        local existing, load_err = library:existing(company.cik, filing.accn)
        if load_err then errors[#errors+1] = load_err; return nil, false end
        if existing then
            local valid, verify_err = library:recoverOriginal(existing)
            if not valid then errors[#errors+1] = verify_err; return nil, false end
            return finishOne({name=existing.source.company.name, cik=company.cik,
                accession=filing.accn, form=filing.form, date=filing.date,
                path=existing.original_path, language="en", chapters=#existing.book.chapters,
                bytes=SecWatchlist.fileSize(existing.original_path), images=#existing.book.images,
                images_bytes=0, images_failed=0, warnings=ctx.warnings, skipped=ctx.skipped,
                reused=true}, existing, item, ctx)
        end
        local target = Filing.outputPath(run_opts.out_dir, company, filing, "en")
        if SecWatchlist.fileExists(target) then
            errors[#errors+1] = "已有原文但缺少续译快照；未覆盖原文，请保留旧文件后重新下载"
            return nil, false
        end
        local chapters = {}
        local work_dir, work_err = library:beginOriginal(company, filing)
        if not work_dir then errors[#errors+1] = work_err; return nil, false end
        run_opts.current_filing_work_dir = work_dir
        local metrics_ch, metrics_data, metrics_why, metrics_off =
            metricsChapter(company, run_opts, progress_cb)
        if metrics_ch then chapters[#chapters + 1] = metrics_ch end
        local chapter, cancelled = gatherFiling(src, company, filing, 1,
            run_opts, progress_cb, ctx)
        if cancelled then
            run_opts.current_filing_work_dir = nil
            return nil, true
        end
        if not chapter then
            run_opts.current_filing_work_dir = nil
            errors[#errors + 1] = string.format("%s %s %s：正文不可用", company.name,
                filing.form, filing.date)
            return nil, false
        end
        chapters[#chapters + 1] = chapter
        local images_dir = work_dir .. "/images"
        local original_book = {
            language = "en",
            identifier = "urn:sec:" .. tostring(company.cik) .. ":" .. filing.accn .. ":en",
            title = string.format("%s · %s · %s", company.name, filing.form, filing.date),
            description = string.format("%s %s %s，来源 SEC EDGAR",
                company.name, filing.form, filing.date),
            chapters = chapters,
            images = ctx.images,
            images_dir = images_dir,
            cover = prepareCover(run_opts, company, work_dir),
        }
        local book = original_book
        local path = Filing.outputPath(run_opts.out_dir, company, filing, "en")
        local record, w_err, w_warn = library:publishOriginal(company, filing, book)
        if type(w_warn) == "table" then
            for wi = 1, #w_warn do addWarning(ctx, "打包层：" .. tostring(w_warn[wi])) end
        end
        if not record then
            run_opts.current_filing_work_dir = nil
            errors[#errors + 1] = string.format("%s %s %s：打包失败（%s）",
                company.name, filing.form, filing.date, tostring(w_err))
            return nil, false
        end
        local size = SecWatchlist.fileSize(path) or 0
        local result = { name = company.name, cik = company.cik, accession = filing.accn,
            form = filing.form, date = filing.date, path = path, language = "en",
            chinese_path = nil, chapters = #chapters, bytes = size, images = #ctx.images,
            images_bytes = ctx.image_bytes, images_failed = ctx.image_failed,
            metrics = metrics_ch ~= nil, metrics_ok = metrics_data and metrics_data.ok_count or 0,
            warnings = ctx.warnings, skipped = ctx.skipped }
        run_opts.current_filing_work_dir = nil
        return finishOne(result, record, item, ctx)
    end

    local position = 0
    for pi = 1, #plan.items do
        local item = plan.items[pi]
        item.ok_accns = {}
        if item.error then
            errors[#errors+1] = string.format("%s：%s", item.company.name, tostring(item.error))
        end
        for fi = 1, #(item.filings or {}) do
            position = position + 1
            local result, cancelled = buildOne(item, item.filings[fi], position)
            if cancelled then
                recordSeen(run_opts.watchlist, item.update, item.ok_accns, #item.ok_accns > 0, warnings)
                info.cancelled = true
                errors[#errors + 1] = "已取消，剩下的 filing 没有处理"
                if run_opts.save_watchlist and run_opts.watchlist then
                    local target = run_opts.save_watchlist
                    if target == true then target = nil end
                    SecWatchlist.save(run_opts.watchlist, target)
                end
                return results, errors, info
            end
        end
        recordSeen(run_opts.watchlist, item.update, item.ok_accns, #item.ok_accns > 0, warnings)
    end
    if run_opts.save_watchlist and run_opts.watchlist then
        local target = run_opts.save_watchlist
        if target == true then target = nil end
        SecWatchlist.save(run_opts.watchlist, target)
    end
    return results, errors, info
end

---@param companies table 要处理的公司数组
---@param opts table      见文件头
---@param progress_cb function|nil  进度回调，返回 false 表示取消
---@return table results, table errors, table info
function SecJob.run(companies, opts, progress_cb)
    opts = opts or {}
    if opts.single_filing then
        return runSingleFilings(companies, opts, progress_cb)
    end
    local run_opts = {
        limit           = tonumber(opts.limit) or 5,
        include_reports = opts.include_reports and true or false,
        out_dir         = opts.out_dir or SecJob.default_out_dir,
        work_dir        = opts.work_dir or SecJob.default_work_dir,
        fetch_images    = (opts.fetch_images ~= false),
        metrics_chapter = (opts.metrics_chapter ~= false),
        keep_images     = opts.keep_images and true or false,
        keep_progress   = (opts.keep_progress ~= false),
        progress_policy = opts.progress_policy or SecJob.default_progress_policy,
        scan_limit      = tonumber(opts.scan_limit) or SecJob.default_scan_limit,
        first_run_new   = tonumber(opts.first_run_new),
        since_date      = opts.since_date,
        only_enabled    = opts.only_enabled,
        watchlist       = opts.watchlist,
        save_watchlist  = opts.save_watchlist,
        cover_dir       = opts.cover_dir,
        table_avail_em  = opts.table_avail_em,
        table_max_cols  = opts.table_max_cols,
        table_projection = opts.table_projection,
        source          = opts.source,
        images_fetch    = opts.images_fetch,
        metrics_fetch   = opts.metrics_fetch,
        metrics_tags    = opts.metrics_tags,
        metrics_on_tag_loaded = opts.metrics_on_tag_loaded,
        metrics_chapter_opts = opts.metrics_chapter_opts,
        image_max_width = opts.image_max_width,
        image_jpeg_quality = opts.image_jpeg_quality,
        image_throttle_ms = opts.image_throttle_ms,
        image_attempts = opts.image_attempts,
        image_timeout = opts.image_timeout,
        image_downscale = opts.image_downscale,
    }

    local results, errors = {}, {}
    local warnings = {}
    local info = {
        companies = #companies, planned = 0, made = 0, no_new = {},
        images = 0, images_failed = 0, image_bytes = 0,
        metrics_ok = 0, metrics_failed = 0,
        cancelled = false, work_dir = run_opts.work_dir,
        user_agent_set = false, warnings = warnings,
    }

    local ua, ua_ok = resolveUserAgent(opts)
    run_opts.user_agent = ua
    info.user_agent = ua
    info.user_agent_set = ua_ok
    if not ua_ok then
        -- 放在 errors 的**最前面**：界面只显示前几条失败原因，
        -- 「没填邮箱」必须排在被它引起的 403 前面，否则用户看到的是七条 HTTP 403。
        errors[#errors + 1] = SecJob.USER_AGENT_HINT
        warnings[#warnings + 1] = SecJob.USER_AGENT_HINT
        logger.warn("secfilings: " .. SecJob.USER_AGENT_HINT)
    end

    local ok_dir, dir_err = SecJob.ensureDir(run_opts.out_dir)
    if not ok_dir then
        errors[#errors + 1] = dir_err
        return results, errors, info
    end
    if run_opts.fetch_images then
        local ok_work, work_err = SecJob.ensureDir(run_opts.work_dir)
        if not ok_work then
            -- 图片目录建不出来不该让整轮失败：自动关掉抓图并按降级路径继续做书
            warnings[#warnings + 1] = string.format(
                "图片工作目录不可用（%s），本轮不抓图片", tostring(work_err))
            logger.warn("secfilings: 图片工作目录不可用", tostring(work_err))
            run_opts.fetch_images = false
        end
    end

    -- 取数用的对象：默认就是 sec_source 模块本身（现有代码风格），
    -- 若 sec_source 提供了实例构造则用实例（配置只影响这一轮，不残留在模块表上）。
    local src = configureSource(run_opts, ua, warnings)
    run_opts.source = src
    info.source_instance = (src ~= SecSource)

    local plan, plan_err = planRun(src, companies, run_opts, progress_cb, warnings)
    if not plan then
        if plan_err == "cancelled" then
            errors[#errors + 1] = "已取消，剩下的公司没有处理"
            info.cancelled = true
        else
            errors[#errors + 1] = tostring(plan_err)
        end
        return results, errors, info
    end
    info.planned = #plan.items
    info.no_new = plan.no_new
    -- （「没有新文件」的说明已经由 planRun 写进 warnings，这里不再重复一遍）

    for ci = 1, #plan.items do
        local item = plan.items[ci]
        local company = item.company

        if not tick(progress_cb, string.format("正在处理 %s（%d / %d）…",
                company.name, ci, #plan.items)) then
            errors[#errors + 1] = "已取消，剩下的公司没有处理"
            info.cancelled = true
            return results, errors, info
        end

        if item.error then
            errors[#errors + 1] = string.format("%s：%s", company.name, tostring(item.error))
            logger.warn("secfilings:", company.name, tostring(item.error))
        else
            local ctx = {
                skipped = {}, warnings = {}, images = {}, image_bytes = 0,
                image_failed = 0, chapter_index = 0,
            }
            local chapters = {}
            local ok_accns = {}
            local cancelled = false
            local packaged = false

            -- ① 关键指标章：放在最前面（契约里就是「每本书的第一章」）
            local metrics_ch, metrics_data, metrics_why, metrics_off =
                metricsChapter(company, run_opts, progress_cb)
            if metrics_ch then
                chapters[#chapters + 1] = metrics_ch
                info.metrics_ok = info.metrics_ok + 1
            elseif metrics_off then
                -- 用户自己关掉的，不是失败，也不该报「注意」
                info.metrics_disabled = (info.metrics_disabled or 0) + 1
            else
                info.metrics_failed = info.metrics_failed + 1
                local line = string.format("%s：关键指标章节未生成（%s），其余的照常做",
                    company.name, tostring(metrics_why))
                ctx.warnings[#ctx.warnings + 1] = line
                logger.warn("secfilings: " .. line)
            end

            -- ② 正文各章
            for fi = 1, #item.filings do
                local filing = item.filings[fi]
                local chapter, was_cancelled = gatherFiling(src, company, filing, fi,
                    run_opts, progress_cb, ctx)
                if was_cancelled then cancelled = true break end
                if chapter then
                    chapters[#chapters + 1] = chapter
                    ok_accns[#ok_accns + 1] = filing.accn
                end
            end

            if cancelled then
                errors[#errors + 1] = "已取消，剩下的公司没有处理"
                info.cancelled = true
                return results, errors, info
            end

            if #chapters == 0 then
                local reason = string.format("%d 份 filing 都没取到可用正文", #item.filings)
                errors[#errors + 1] = string.format("%s：%s", company.name, reason)
                logger.warn("secfilings:", company.name, reason)
                -- 这一轮没成书，但「为什么」不能掉在地上
                for wi = 1, #ctx.warnings do
                    warnings[#warnings + 1] = string.format("%s：%s", company.name, ctx.warnings[wi])
                end
                for si = 1, #ctx.skipped do
                    logger.info("secfilings:         跳过 " .. ctx.skipped[si])
                end
            else
                local path = string.format("%s/%s SEC 财报.epub", run_opts.out_dir, company.name)
                local book_dir = bookWorkDir(run_opts, company)
                local book = {
                    title       = company.name .. " SEC 财报",
                    description = string.format(
                        "%s 最近 %d 份 SEC 文件（含 %d 张图）与关键指标，来源 EDGAR",
                        company.legal or company.name, #chapters, #ctx.images),
                    chapters    = chapters,
                    -- 契约 1：这三个字段是 sec_epub 的输入
                    images      = ctx.images,
                    images_dir  = book_dir .. "/images",
                    cover       = prepareCover(run_opts, company, book_dir),
                }

                -- ③ 阅读进度保留（契约 5）：三步顺序不能错。
                -- 忘掉第 3 步只是回到旧行为（进度归零），不会产生坏文件。
                local snap
                if run_opts.keep_progress then
                    snap = SecWatchlist.keepProgress(path)
                end

                local ok_w, w_err, w_warn = SecEpub:write(path, book)
                -- sec_epub 会把「图片目录里有没被 manifest 引用的文件」这类情况
                -- 用第三个返回值报出来。它们是「书里的图和预期不一样」的线索，
                -- 必须带进结果，不能掉在打包层里。
                if type(w_warn) == "table" then
                    for wi = 1, #w_warn do
                        ctx.warnings[#ctx.warnings + 1] = "打包层：" .. tostring(w_warn[wi])
                    end
                end

                if ok_w and snap then
                    local ok_r, report, r_err = SecWatchlist.restoreProgress(path, snap,
                        { policy = run_opts.progress_policy })
                    if not ok_r then
                        ctx.warnings[#ctx.warnings + 1] = string.format(
                            "阅读进度没有恢复（%s）：翻页位置会从第一页重新开始",
                            tostring(r_err))
                    end
                end

                -- 图片目录用完即清：设备上空间紧张，而图片已经进了 zip。
                local book_work = bookWorkDir(run_opts, company)
                if not run_opts.keep_images then
                    SecWatchlist.removeTree(book_work)
                end

                if not ok_w then
                    errors[#errors + 1] = string.format("%s：打包失败（%s）",
                        company.name, tostring(w_err))
                    logger.warn("secfilings:", company.name, "打包失败", tostring(w_err))
                else
                    packaged = true
                    local size = SecWatchlist.fileSize(path) or 0
                    if #ctx.images > 0 and size < ctx.image_bytes then
                        -- 图片进了 zip 就不可能比原图还小（JPEG/PNG 压不动），
                        -- 所以这一条只会在「打包层没读 book.images」时触发。
                        ctx.warnings[#ctx.warnings + 1] = string.format(
                            "成品 %d KB 小于图片总量 %d KB，图片疑似没有进包"
                            .. "（需要 sec_epub.lua 处理 book.images / book.images_dir）",
                            size / 1024, ctx.image_bytes / 1024)
                    end

                    local result = {
                        name          = company.name,
                        cik           = company.cik,
                        path          = path,
                        chapters      = #chapters,
                        bytes         = size,
                        images        = #ctx.images,
                        images_bytes  = ctx.image_bytes,
                        images_failed = ctx.image_failed,
                        metrics       = metrics_ch ~= nil,
                        metrics_ok    = metrics_data and (metrics_data.ok_count or 0) or 0,
                        new_count     = item.update and item.update.new_count or #item.filings,
                        skipped       = ctx.skipped,
                        warnings      = ctx.warnings,
                    }
                    results[#results + 1] = result
                    info.made = info.made + 1
                    info.images = info.images + #ctx.images
                    info.images_failed = info.images_failed + ctx.image_failed
                    info.image_bytes = info.image_bytes + ctx.image_bytes

                    -- 每个成功单元都写日志：界面万一出问题，真相还在 crash.log 里
                    logger.info(string.format(
                        "secfilings: [成功] %s  %d 章节（含指标 %s）  %d 张图 / %.0f KB  成品 %.0f KB  %s",
                        company.name, #chapters, metrics_ch and "是" or "否",
                        #ctx.images, ctx.image_bytes / 1024, size / 1024, path))
                    for si = 1, #ctx.skipped do
                        logger.info("secfilings:         跳过 " .. ctx.skipped[si])
                    end
                    for wi = 1, #ctx.warnings do
                        logger.warn("secfilings:         " .. ctx.warnings[wi])
                    end
                end
            end

            -- ④ 增量落账（只记真的下成功的；打包失败不算成功，下次还会再试）
            if item.update then
                recordSeen(run_opts.watchlist, item.update, ok_accns, packaged, ctx.warnings)
            end
        end
    end

    -- ⑤ 关注列表的存储由 main.lua 负责；调用方明确要求时才代写
    if run_opts.save_watchlist and run_opts.watchlist then
        local target = run_opts.save_watchlist
        if target == true then target = nil end
        local ok_s, s_err = SecWatchlist.save(run_opts.watchlist, target)
        if not ok_s then
            warnings[#warnings + 1] = "关注列表保存失败：" .. tostring(s_err)
        end
    end

    return results, errors, info
end

return SecJob
