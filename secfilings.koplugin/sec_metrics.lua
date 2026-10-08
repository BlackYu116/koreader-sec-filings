--[[
「关键指标」章节：用 SEC 官方 XBRL 结构化数据，在每本书开头生成一章干净的指标对照。

为什么要有这一章
  原始报表已经能读了（sec_source.lua 的按列投影拆表），但读者仍要在几十张表里翻找数字，
  而且同一家公司的同一指标分散在 10-Q / 10-K 的好几张表里。SEC 自己就把这些数字做成了
  结构化数据（XBRL），直接取现成的即可 —— 这样「开头一章干净的指标对照 + 后面的原始报表
  留作查阅依据」这个结构才成立。原始报表一个字都不动。

取数用哪个接口（实测数据见 FINDINGS.md 对应小节）
  用 **按概念逐个取** 的 companyconcept 接口：
      https://data.sec.gov/api/xbrl/companyconcept/CIK##########/us-gaap/<TagName>.json
  8 个指标 × 全部候选 tag 一共 14 个请求，7 家公司实测合计 159–323 KB（单个最大 61 KB）；
  换成 companyfacts（一次给全部指标）单份 2.6–4.7 MB，解码峰值堆要多花约 6 MB，
  而且里面绝大多数标签我们不会用，所以不用它（实测数据见 evidence/metrics_memory.txt）。
  取到的 JSON 只保留「每个指标选中的那一个 tag」的解析结果，其余候选在选完就丢弃，
  全程 Lua 堆峰值 1.2–2.5 MB。

期间口径与「同一期间被申报多次」怎么取（实测得出的规则）
  · 期间按长度分类：约 3 个月 = 单季度、6 个月 = 半年累计、9 个月 = 前三季累计、
    12 个月 = 全年。**不同长度的期间绝不放在一起比较** —— 特斯拉 Q2 单季营收和
    上半年累计营收混在一列里没有任何意义。展示时按「单季度」「累计」分两张表。
  · 资产负债表类指标（总资产/总负债/现金）没有期间长度，是某个时点的余额，单独一张表。
  · 同一 (start, end) 期间在数据里会出现多次：被 10-Q 收录两次、被后续 10-K 再确认一次，
    或者被修正申报改写。取值规则：**一律取 filed（申报日）最新的一条**；filed 相同则取
    accession 号大的（确定性，不靠遍历顺序）。这条规则有实际后果，所以必须让读者看见：
    实测特斯拉 2024-01-01 ~ 2024-03-31 的 NetIncomeLoss 在 2024-04-24 的 10-Q 里是
    1,129,000,000，在 2025-04-23 的 10-Q 里被写成 1,390,000,000。本模块取后者并在
    该行标「*」、在表下写出两次的值与申报日。
  · 「取最新」同时顺带处理了拆股：英伟达 10:1 拆股前的 EPS 是 44.15 这种量级，
    最新申报里是拆股后调整过的，取最新才能让同一张表里的数字可比。

金额精度
  这些数值是整数美元（JSON 里的 val 也是整数），所以全程不经过浮点除法：
  格式化时把整数转成十进制字符串后按位切分、按位四舍五入。理由见 millionsString 的注释。

本模块是纯逻辑：不 require 任何 ui/*，也不 require sec_source（那会把整个抓取栈拖进来）。
它对外只做三件事：
  collectConcepts(company, opts, progress_cb) -> ok, concept_data | nil, err   -- 联网取数
  buildChapter(company, concept_data, opts)  -> ok, xhtml | nil, err          -- 生成 XHTML 片段
  summary(company, concept_data, opts)       -> table                          -- 机器可读报告

用法（集成时由 sec_job.lua 调用，本模块不自己接线）：

  local SecMetrics = require("sec_metrics")

  local company = { cik = 1318605, name = "特斯拉", legal = "Tesla, Inc." }
  local ok, data, err = SecMetrics.collectConcepts(company, {
      user_agent = SecSource.user_agent,   -- 必填：SEC 要求 UA 里带可联系的邮箱，否则 403
  }, function(msg) return true end)        -- progress_cb 返回 false 表示取消

  if ok then
      local ok2, xhtml = SecMetrics.buildChapter(company, data, {})
      -- xhtml 是不带 <html>/<body> 的片段，可直接放进章节的 html 字段
  end

集成要点（接线由 sec_job.lua 负责，本模块不碰设备也不碰界面）
  · opts.user_agent 必填，且必须是带邮箱的那一个（现在由 sec_source.lua 提供）。
  · collectConcepts 会发 14 个请求、合计 100–350 KB，本机实测约 12 秒（含 0.12s/请求的间隔）；
    接进「下载一本书」的流程时要给它一句进度提示（progress_cb），否则界面会长时间不动。
  · 取数失败（网络、UA 被拒）时返回 (false, nil, 原因)，调用方应当**跳过这一章继续做书**，
    不要把整本书搞失败 —— 关键指标是锦上添花，原始报表才是正文。
  · 个别指标取不到不是错误：章节里会写出「未取到」和试过的候选 tag，仍然正常返回。
  · 建议作为每本书的第一章，标题用「关键指标」，插到章节数组最前面即可（本模块不生成 <h1>）。
]]

local json = require("json")
local logger = require("logger")

local SecMetrics = {}

-- 注意：本文件同样不使用 `_` 作循环变量。插件顶部的 `local _ = require("gettext")`
-- 会被 `for _, x in ipairs(t)` 遮蔽，循环体内再调 `_()` 就变成「调用一个数字」，
-- 这个坑已经让 7 家公司全部下载失败过一次。

--------------------------------------------------------------------------
-- 一、指标集与标签回退表
--------------------------------------------------------------------------
--
-- 为什么每个指标要准备多个候选 tag：XBRL 里没有「统一字段」，同一件事各公司用的
-- 标签名不一样。实测这 7 家里就真的有取不到的（见 FINDINGS 实测小节），
-- 所以候选顺序必须显式写在代码里，取不到时也要能说出「试过哪些、为什么不行」。
--
-- kind 决定期间形态：
--   duration = 一段时间上的流量（营收、利润、现金流），有 start/end
--   instant  = 某个时点上的余额（资产、负债、现金），只有 end
--
-- unit_key 是期望的单位名。拿到了别的单位（例如某家用 EUR）时不会硬套，
-- 而会改用实际单位并把单位写进表头，避免把不同单位混在一张表里。
SecMetrics.METRICS = {
    {
        id = "revenue", label = "营收", kind = "duration", unit_key = "USD",
        tags = {
            { tag = "RevenueFromContractWithCustomerExcludingAssessedTax" },
            { tag = "Revenues" },
            { tag = "SalesRevenueNet" },
        },
    },
    {
        id = "operating_income", label = "营业利润", kind = "duration", unit_key = "USD",
        tags = {
            { tag = "OperatingIncomeLoss" },
        },
    },
    {
        id = "net_income", label = "净利润", kind = "duration", unit_key = "USD",
        tags = {
            { tag = "NetIncomeLoss" },
            { tag = "ProfitLoss", tag_note = "含少数股东权益，与「归属母公司净利润」口径不同" },
        },
    },
    {
        id = "eps_diluted", label = "稀释每股收益", kind = "duration", unit_key = "USD/shares",
        tags = {
            { tag = "EarningsPerShareDiluted" },
            { tag = "EarningsPerShareBasicAndDiluted", tag_note = "基本与稀释合并申报" },
        },
    },
    {
        id = "operating_cash_flow", label = "经营现金流", kind = "duration", unit_key = "USD",
        tags = {
            { tag = "NetCashProvidedByUsedInOperatingActivities" },
            { tag = "NetCashProvidedByUsedInOperatingActivitiesContinuingOperations",
              tag_note = "仅持续经营业务，剔除了已终止经营" },
        },
    },
    {
        id = "assets", label = "总资产", kind = "instant", unit_key = "USD",
        tags = {
            { tag = "Assets" },
        },
    },
    {
        id = "liabilities", label = "总负债", kind = "instant", unit_key = "USD",
        tags = {
            { tag = "Liabilities" },
        },
    },
    {
        id = "cash", label = "现金及等价物", kind = "instant", unit_key = "USD",
        tags = {
            { tag = "CashAndCashEquivalentsAtCarryingValue" },
            { tag = "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents",
              tag_note = "含受限现金，与「现金及等价物」口径不同" },
        },
    },
}

--- 所有候选 tag 的去重列表（collectConcepts 按这个顺序取数，长度即请求数）
function SecMetrics.allTags()
    local seen, out = {}, {}
    for _mi, metric in ipairs(SecMetrics.METRICS) do
        for _ti, cand in ipairs(metric.tags) do
            if not seen[cand.tag] then
                seen[cand.tag] = true
                out[#out + 1] = cand.tag
            end
        end
    end
    return out
end

function SecMetrics.conceptUrl(cik, tag)
    return string.format(
        "https://data.sec.gov/api/xbrl/companyconcept/CIK%010d/us-gaap/%s.json", cik, tag)
end

--- 某个申报记录对应的 EDGAR 归档目录（一致性抽查时用来回原始 filing 对数字）
function SecMetrics.filingUrl(cik, accn)
    if not accn or accn == "" then return nil end
    return string.format("https://www.sec.gov/Archives/edgar/data/%d/%s/",
        cik, tostring(accn):gsub("%-", ""))
end

--------------------------------------------------------------------------
-- 二、小工具：XML 转义、日期、数字格式化
--------------------------------------------------------------------------

local function esc(s)
    if s == nil then return "" end
    return (tostring(s)
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

--- "2026-06-30" -> 2026, 6, 30（格式不对返回 nil）
local function ymd(s)
    if type(s) ~= "string" then return nil end
    local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    return tonumber(y), tonumber(m), tonumber(d)
end

--- 公历日期 -> 天数序号（Howard Hinnant 的 days_from_civil）。
--- 为什么不直接用 os.time 相减：os.time 吃本地时区，跨夏令时那天会差 1 小时，
--- 于是「91 天」可能变成 90.96 或 91.04，再做月份取整就有翻车的余地。
--- 纯整数运算没有任何时区、闰年、夏令时的坑。
local function daysFromCivil(y, m, d)
    y = (m <= 2) and (y - 1) or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

--- 日期差（天数）。加 1 是因为期间是闭区间：1 月 1 日到 1 月 31 日是 31 天。
local function daysBetween(start_s, end_s)
    local y1, m1, d1 = ymd(start_s)
    local y2, m2, d2 = ymd(end_s)
    if not y1 or not y2 then return nil end
    return daysFromCivil(y2, m2, d2) - daysFromCivil(y1, m1, d1) + 1
end

--- 按长度给期间定性。月份取整用 30.44 天/月的历史平均值。
local CALIBERS = {
    Q    = { months = 3,  label = "单季" },
    H    = { months = 6,  label = "半年" },
    N9M  = { months = 9,  label = "前三季" },
    FY   = { months = 12, label = "全年" },
}

local function caliberOf(days)
    if not days or days <= 0 then return nil, nil end
    local months = math.floor(days / 30.44 + 0.5)
    if months == 3 then return "Q", CALIBERS.Q end
    if months == 6 then return "H", CALIBERS.H end
    if months == 9 then return "N9M", CALIBERS.N9M end
    if months == 12 then return "FY", CALIBERS.FY end
    -- 非标准长度（财年变更的过渡期等）不冒充标准口径，按实际天数标注
    return "X", { months = months, label = string.format("%d 天", days) }
end

--- 给整数插入千位分隔符。输入是纯数字字符串（可带前导 0）。
local function groupDigits(s)
    local n = #s
    local out = {}
    local first = n % 3
    if first == 0 then first = 3 end
    out[#out + 1] = s:sub(1, first)
    local i = first + 1
    while i <= n do
        out[#out + 1] = s:sub(i, i + 2)
        i = i + 3
    end
    return table.concat(out, ",")
end

--- 整数美元 -> 带千位分隔符的字符串。
--- 为什么用 "%.0f" 而不是 tostring：val 是 JSON 里的整数，经过 json.decode 是双精度，
--- tostring 对大数会退化成科学计数法（1e+12 这种），而 "%.0f" 在 |v| < 2^53 时精确。
local function absIntegerString(v)
    local a = v
    if a < 0 then a = -a end
    return string.format("%.0f", a)
end

--- 把整数美元显示成「百万美元」，保留 1 位小数。
---
--- 为什么不用 v / 1e6 再 math.floor：那会引入浮点除法，999,999,999 这类值会出现
--- 999.999999 这种结果，四舍五入方向就可能错。这里的做法是把十进制字符串按位切开：
--- 右 6 位是「不足百万的部分」，然后对第 5 位（十万位）做一次整数四舍五入。
--- 全程只做字符串切分和小整数运算，不存在舍入误差。
local function millionsString(v)
    local sign = (v < 0) and "-" or ""
    local s = absIntegerString(v)
    if #s < 7 then s = string.rep("0", 7 - #s) .. s end
    local q = s:sub(1, #s - 6)
    local frac = tonumber(s:sub(#s - 5)) or 0
    local tenths = math.floor(frac / 100000)
    if frac - tenths * 100000 >= 50000 then tenths = tenths + 1 end
    if tenths >= 10 then
        tenths = 0
        q = tostring((tonumber(q) or 0) + 1)
    end
    q = q:gsub("^0+(%d)", "%1")
    if q == "" then q = "0" end
    if tenths > 0 then
        return sign .. groupDigits(q) .. "." .. tenths
    end
    return sign .. groupDigits(q)
end

--- 每股收益：最多 4 位小数、至少 2 位（财务惯例）。
--- SEC 的 XBRL 里每股收益通常两位小数，但偶尔有 4 位，直接 %.2f 会把真值截掉。
local function perShareString(v)
    local s = string.format("%.4f", v)
    local whole, frac = s:match("^(%-?%d+)%.(%d+)$")
    if not whole then return s end
    frac = frac:gsub("0+$", "")
    if #frac < 2 then frac = frac .. string.rep("0", 2 - #frac) end
    return whole .. "." .. frac
end

--- 一张表里用什么单位：|值| 的峰值到百万级就换成「百万美元」，
--- 否则用精确美元（例如某个季度亏损只有几十万美元时，换成百万就没法读了）。
--- 判定按「整个指标的所有期间」做，不按单张表 —— 否则同一指标的两张表单位会不一致。
local function pickScale(max_abs)
    if max_abs >= 1000000 then return 1000000, "百万美元" end
    return 1, "美元"
end

local function fmtMoney(v, scale)
    if v == nil then return "" end
    if scale == 1000000 then return millionsString(v) end
    local sign = (v < 0) and "-" or ""
    return sign .. groupDigits(absIntegerString(v))
end

local function fmtValue(v, metric, scale)
    if metric.unit_key == "USD/shares" then return perShareString(v) end
    return fmtMoney(v, scale)
end

--------------------------------------------------------------------------
-- 三、把 JSON 变成「每个指标 -> 期间列表」
--------------------------------------------------------------------------

--- 从 unit 表里挑单位。优先用指标声明的期望单位，没有就用第一个可用的，
--- 并把实际用到的单位名返回给调用方写进表头（绝不硬套成 USD）。
local function pickUnit(units, want)
    if type(units) ~= "table" then return nil end
    if want and type(units[want]) == "table" and #units[want] > 0 then
        return want, units[want]
    end
    local names = {}
    for name, arr in pairs(units) do
        if type(arr) == "table" and #arr > 0 then names[#names + 1] = name end
    end
    table.sort(names)
    if #names == 0 then return nil end
    return names[1], units[names[1]]
end

--- 同一期间的多条申报里选一条：
---   1) filed 最新的一条（修正申报与被后续申报改写的值都取最新，理由见文件头）
---   2) filed 相同时取 accession 号大的（确定性）
--- 返回 选中的记录、被折叠掉的条数、以及「数值与选中项不同」的次新一条。
local function chooseEntry(entries)
    table.sort(entries, function(a, b)
        local fa, fb = tostring(a.filed or ""), tostring(b.filed or "")
        if fa ~= fb then return fa > fb end
        return tostring(a.accn or "") > tostring(b.accn or "")
    end)
    local chosen = entries[1]

    local prev = nil
    for _ei = 2, #entries do
        local e = entries[_ei]
        if e.val ~= chosen.val then
            -- 已经按 filed 倒序排过，第一条不同值的就是「早先那次申报」
            if not prev then prev = e end
        end
    end
    return chosen, #entries - 1, prev
end

--- 把某个 tag 的 payload 解析成期间列表。
---@return table|nil periods, string|nil err, table|nil info
local function periodsOf(payload, metric)
    if type(payload) ~= "table" then return nil, "payload 不是表" end
    local unit_name, arr = pickUnit(payload.units, metric.unit_key)
    if not unit_name then return nil, "没有任何单位的数据" end

    local groups, order = {}, {}
    local newest, oldest = nil, nil
    local skipped = 0

    for _ei = 1, #arr do
        local e = arr[_ei]
        if type(e) == "table" and e["end"] and e.val ~= nil then
            local start = e.start
            if metric.kind == "duration" and not start then
                -- 流量指标必须有起点。SEC 里偶尔会混进「没有 start 的同名 tag」，
                -- 那是另一种口径，宁可不要也不能当成期间值。
                skipped = skipped + 1
            else
                local key = metric.kind == "duration"
                    and (tostring(start) .. "|" .. tostring(e["end"]))
                    or tostring(e["end"])
                if not groups[key] then
                    groups[key] = {}
                    order[#order + 1] = key
                end
                local bucket = groups[key]
                bucket[#bucket + 1] = e
                local end_s = e["end"]
                if not newest or end_s > newest then newest = end_s end
                if not oldest or end_s < oldest then oldest = end_s end
            end
        else
            skipped = skipped + 1
        end
    end
    if #order == 0 then return nil, "没有可用的期间记录" end

    local periods = {}
    local dup_groups, revised = 0, 0
    for _gi = 1, #order do
        local entries = groups[order[_gi]]
        local chosen, folded, prev = chooseEntry(entries)
        if folded > 0 then dup_groups = dup_groups + 1 end

        local days, caliber, caliber_info
        if metric.kind == "duration" then
            days = daysBetween(chosen.start, chosen["end"])
            caliber, caliber_info = caliberOf(days)
        else
            caliber, caliber_info = "I", { months = 0, label = "时点" }
        end

        if prev then revised = revised + 1 end
        periods[#periods + 1] = {
            start        = chosen.start,
            end_date     = chosen["end"],
            val          = chosen.val,
            unit         = unit_name,
            days         = days,
            caliber      = caliber,
            caliber_label = caliber_info and caliber_info.label or "",
            form         = chosen.form,
            fy           = chosen.fy,
            fp           = chosen.fp,
            frame        = chosen.frame,
            filed        = chosen.filed,
            accn         = chosen.accn,
            folded       = folded,          -- 被折叠掉的重复申报条数
            revised      = prev ~= nil,     -- 该期间的值被后来的申报改写过
            prev_val     = prev and prev.val or nil,
            prev_filed   = prev and prev.filed or nil,
            prev_form    = prev and prev.form or nil,
        }
    end

    -- 展示顺序：报告期由近到远
    table.sort(periods, function(a, b)
        if a.end_date ~= b.end_date then return a.end_date > b.end_date end
        return tostring(a.start or "") > tostring(b.start or "")
    end)

    return periods, nil, {
        unit = unit_name,
        entries = #arr,
        skipped = skipped,
        periods = #periods,
        dup_groups = dup_groups,
        revised = revised,
        newest = newest,
        oldest = oldest,
        label = payload.label,
        entity_name = payload.entityName,
    }
end

--- 从「候选 tag -> payload」里给每个指标选定一个 tag。
--- 选定规则（可复现、且能说出理由）：
---   1) 候选按 METRICS 里声明的顺序；
---   2) 能解析出期间的才算可用；
---   3) 可用的候选中取「最新期间截止日」最晚的那个 —— 这条是为了避开
---      「某家公司历史上用过 A 标签、后来换成 B 标签」的情况（实测微软的
---      Revenues 只有 2009–2017 的数据），否则会拿到一份停在十年前的指标；
---   4) 最新期间相同时，声明顺序在前的优先。
---@param raw table { [tag] = payload }
---@param errors table { [tag] = {code=, err=} }
function SecMetrics.analyze(company, raw, errors, opts)
    opts = opts or {}
    raw = raw or {}
    errors = errors or {}

    local out = {
        cik = company and company.cik,
        name = company and company.name,
        metrics = {},
        request_tags = {},
    }

    for _mi = 1, #SecMetrics.METRICS do
        local metric = SecMetrics.METRICS[_mi]
        local rec = {
            id = metric.id, label = metric.label, kind = metric.kind,
            unit_key = metric.unit_key, candidates = {},
        }

        local best, best_newest, best_rank
        for _ti = 1, #metric.tags do
            local cand = metric.tags[_ti]
            local payload = raw[cand.tag]
            local err = errors[cand.tag]
            local cinfo = { tag = cand.tag, tag_note = cand.tag_note, rank = _ti }

            if payload then
                local periods, perr, info = periodsOf(payload, metric)
                cinfo.entries = info and info.entries or nil
                cinfo.oldest = info and info.oldest or nil
                cinfo.newest = info and info.newest or nil
                cinfo.unit = info and info.unit or nil
                if not periods then
                    cinfo.status = "解析不出期间（" .. tostring(perr) .. "）"
                else
                    cinfo.status = "OK"
                    if not best or (info.newest or "") > (best_newest or "") then
                        best, best_newest, best_rank = {
                            tag = cand.tag, tag_note = cand.tag_note,
                            periods = periods, info = info,
                        }, info.newest, _ti
                    end
                end
            else
                local code = err and err.code
                if code == 404 then
                    cinfo.status = "HTTP 404：该公司从未申报这个 tag"
                elseif code then
                    cinfo.status = string.format("HTTP %s：%s", tostring(code),
                        tostring(err and err.err or ""))
                else
                    cinfo.status = "没取到（" .. tostring(err and err.err or "未请求") .. "）"
                end
            end
            rec.candidates[#rec.candidates + 1] = cinfo
        end

        if best then
            rec.tag = best.tag
            rec.tag_note = best.tag_note
            rec.tag_rank = best_rank
            rec.periods = best.periods
            rec.unit = best.info.unit
            rec.dup_groups = best.info.dup_groups
            rec.revised = best.info.revised
            rec.oldest = best.info.oldest
            rec.newest = best.info.newest
            rec.available = true
        else
            rec.available = false
            local tried = {}
            for _ci = 1, #rec.candidates do
                tried[#tried + 1] = string.format("us-gaap:%s（%s）",
                    rec.candidates[_ci].tag, rec.candidates[_ci].status)
            end
            rec.why = "候选 tag 全部不可用：" .. table.concat(tried, "；")
        end

        out.metrics[#out.metrics + 1] = rec
    end

    -- 「数据截至」取所有已选指标里最新的一次申报日，比「今天」更诚实：
    -- 设备时钟可能不准，而申报日是数据自带的事实。
    local as_of
    for _mi = 1, #out.metrics do
        local rec = out.metrics[_mi]
        if rec.available then
            for _pi = 1, #rec.periods do
                local filed = rec.periods[_pi].filed
                if filed and (not as_of or filed > as_of) then as_of = filed end
            end
        end
    end
    out.as_of = as_of

    return out
end

--------------------------------------------------------------------------
-- 四、联网取数
--------------------------------------------------------------------------

--- 默认的 HTTP 取数。返回 body, nil, code（成功）或 nil, 说明, code（失败）。
---
--- 为什么不直接用 SecSource:fetch：那个函数只回「HTTP 404」这种字符串，
--- 而这里必须区分「该公司没申报这个 tag（404）」和「网络故障」—— 前者要放弃这个候选，
--- 后者应该重试。两者对回退决策的意义完全不同。
--- socket.http / ltn12 延迟 require：本模块要能在没有 luasocket 的环境里
--- 被 require 并做纯逻辑测试（测试时用 opts.fetch 注入取数函数）。
function SecMetrics.httpFetch(url, opts)
    local ok_req, http = pcall(require, "socket.http")
    local ok_sink, ltn12 = pcall(require, "ltn12")
    if not ok_req or not ok_sink then
        return nil, "本环境没有 luasocket（socket.http/ltn12）", nil
    end

    opts = opts or {}
    local chunks = {}
    local old_timeout = http.TIMEOUT
    http.TIMEOUT = opts.timeout or 30
    local ok, code = http.request{
        url = url,
        headers = { ["user-agent"] = opts.user_agent },
        sink = ltn12.sink.table(chunks),
    }
    http.TIMEOUT = old_timeout

    local body = table.concat(chunks)
    local n = tonumber(code)
    if ok and n and n >= 200 and n < 300 then
        return body, nil, n
    end
    if n == 404 then
        -- 404 的响应体是 SEC 的 JSON 错误说明，不用留着
        return nil, "该 tag 不存在或该公司未申报", 404
    end
    if not n then
        -- http.request 失败时第一个返回值是 nil、第二个是错误说明（不是状态码），
        -- 这时 tostring(code) 就是那段说明。区分开来，免得日志里出现「HTTP timeout」这种怪话。
        return nil, string.format("网络错误：%s（收到 %d 字节）", tostring(code), #body), nil
    end
    return nil, string.format("HTTP %d（收到 %d 字节）", n, #body), n
end

--- 取一个 tag 的 concept 数据（含重试）。
--- 404 不重试：那是「这家公司没有这个标签」，重试一百次也一样。
local function fetchConcept(cik, tag, opts, errors)
    local url = SecMetrics.conceptUrl(cik, tag)
    local attempts = opts.attempts or 2
    local fetch = opts.fetch or SecMetrics.httpFetch
    local last_err, last_code

    for try = 1, attempts do
        local body, err, code = fetch(url, opts)
        if body then
            if #body > (opts.max_concept_bytes or 4 * 1024 * 1024) then
                errors[tag] = { code = code, err = "响应过大，已拒绝" }
                return nil, #body
            end
            local ok_dec, payload = pcall(json.decode, body)
            if ok_dec and type(payload) == "table" and type(payload.units) == "table" then
                return payload, #body
            end
            last_err, last_code = "JSON 解析失败或结构不认识", code
            -- 解析失败通常是取到半截响应，值得重试
        else
            last_err, last_code = tostring(err), code
            if code == 404 then break end
        end
        if try < attempts then
            -- 等一会儿再试。socket.sleep 是阻塞的纯 C 调用；环境里没有 socket 就跳过。
            local ok_socket, socket = pcall(require, "socket")
            if ok_socket and socket.sleep then
                local ok_sleep = pcall(socket.sleep, try * 1.5)
            end
        end
    end

    errors[tag] = { code = last_code, err = last_err }
    return nil
end

--- 取数间隔控制：SEC 的软上限是每秒 10 次，十几个请求别一口气打过去。
local function paceGap(opts)
    local gap = opts.min_gap_ms
    if gap == nil then gap = 120 end
    if gap <= 0 then return end
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket.sleep then
        local ok_sleep = pcall(socket.sleep, gap / 1000)
    end
end

--- 取一家公司的全部候选 tag，解析成 concept_data。
---
--- 为什么把所有候选都取回来再挑，而不是「取到第一个能用的就停」：
---   实测存在「首选标签只有十年前的旧数据、回退标签才是当期数据」的情况，
---   「取到就停」会静默给出过期指标。全取回来的代价是每家公司 14 个小请求
---   （合计 180–340 KB），换来的是「选了哪个、为什么没选别的」都能如实报告。
---@param company table { cik=, name= }
---@param opts table { user_agent=必填, fetch=可选注入, company_facts=不用 }
---@param progress_cb function|nil 返回 false 表示取消
---@return boolean, table|nil, string|nil
function SecMetrics.collectConcepts(company, opts, progress_cb)
    opts = opts or {}
    if type(company) ~= "table" or not company.cik then
        return false, nil, "collectConcepts 需要 { cik = 数字 }"
    end
    if type(opts.user_agent) ~= "string" or opts.user_agent == "" then
        -- SEC 硬性要求 UA 里带可联系的邮箱，缺了会被 403；
        -- 这里提前拦住，避免变成「7 家公司全部取不到」还不明原因。
        return false, nil, "必须提供 opts.user_agent（SEC 要求 UA 里带联系邮箱）"
    end

    local tags = opts.tags or SecMetrics.allTags()
    local raw, errors = {}, {}
    local bytes, requests = 0, 0

    for _ti = 1, #tags do
        local tag = tags[_ti]
        if progress_cb and progress_cb(string.format("正在取 %s 的结构化数据（%d / %d）…",
                company.name or "", _ti, #tags)) == false then
            return false, nil, "cancelled"
        end
        local payload, nbytes = fetchConcept(company.cik, tag, opts, errors)
        requests = requests + 1
        bytes = bytes + (nbytes or 0)
        raw[tag] = payload
        -- 取样钩子：这里是整个流程里内存最高的时候（所有候选 tag 的解析结果都在 raw 里
        -- 还没被丢弃）。它只为跑内存实测而存在，不传就完全没有开销。
        if opts.on_tag_loaded then opts.on_tag_loaded(tag, payload) end
        paceGap(opts)
    end

    local data = SecMetrics.analyze(company, raw, errors, opts)
    data.requests = requests
    data.bytes = bytes
    data.user_agent = opts.user_agent
    data.tag_count = #tags
    data.fetched_at = os.time()

    -- 原始 payload 在这里就丢掉：解析结果已经拿到，留着只是白占内存。
    -- （设备内存紧张，这里是唯二的大对象。另一个是返回的 data 本身。）
    if not opts.keep_raw then raw = nil end
    if opts.keep_raw then data.raw = raw end

    local missing, ok_count = {}, 0
    for _mi = 1, #data.metrics do
        local rec = data.metrics[_mi]
        if rec.available then ok_count = ok_count + 1 else missing[#missing + 1] = rec.label end
    end
    data.ok_count = ok_count
    data.missing = missing

    logger.info(string.format(
        "secfilings: [指标] %s 取到 %d/%d 个指标，%d 个请求 / %.0f KB",
        tostring(company.name), ok_count, #data.metrics, requests, bytes / 1024))

    return true, data
end

--------------------------------------------------------------------------
-- 五、生成 XHTML 片段
--------------------------------------------------------------------------

--- 期间口径的短标签。
--- 季度按「报告期截止日所属的自然季度」标注，不按公司自己的财季编号：
--- 苹果的 FY2026 Q1 截止 2025-12-27，按自然季度是 2025 Q4。
--- 两种叫法都合理，但必须自洽且说明白，所以标签与「报告期」列写的是同一件事，
--- 章节开头也写明了这条换算规则。
local function periodLabel(p)
    if p.caliber == "I" then return p.end_date end
    local y, m = ymd(p.end_date)
    if not y then return p.end_date end
    if p.caliber == "Q" then
        return string.format("%d Q%d", y, math.floor((m - 1) / 3) + 1)
    end
    local cal = CALIBERS[p.caliber]
    if not cal then return string.format("%d 天（%s）", p.days or 0, tostring(p.start)) end
    -- 累计期间标「口径 + 期止年-月」而不是「口径 + 年」：实测亚马逊同一年里有不止一个
    -- 12 个月期间（年初起的财年值，加上公司自己申报的 12 个月滚动值），只写年份会出现
    -- 两个「2026 全年」，读者无法区分。期止年月在同类口径内唯一，且和「报告期」列对应。
    return string.format("%s（%04d-%02d）", cal.label, y, m)
end

local function rangeLabel(p)
    if p.caliber == "I" or not p.start then return p.end_date end
    return p.start .. " ~ " .. p.end_date
end

--- 一个指标的一张表。
local function renderTable(periods, metric, scale, opts)
    local parts = { "<table>" }
    if metric.kind == "instant" then
        parts[#parts + 1] = '<tr><td>时点</td>'
            .. '<td style="text-align:right">数值</td></tr>'
    else
        parts[#parts + 1] = '<tr><td>口径</td><td>报告期</td>'
            .. '<td style="text-align:right">数值</td></tr>'
    end
    for _pi = 1, #periods do
        local p = periods[_pi]
        local val = fmtValue(p.val, metric, scale)
        if p.revised then val = val .. " *" end
        if metric.kind == "instant" then
            parts[#parts + 1] = string.format(
                '<tr><td>%s</td><td style="text-align:right">%s</td></tr>',
                esc(periodLabel(p)), esc(val))
        else
            parts[#parts + 1] = string.format(
                '<tr><td>%s</td><td>%s</td><td style="text-align:right">%s</td></tr>',
                esc(periodLabel(p)), esc(rangeLabel(p)), esc(val))
        end
    end
    parts[#parts + 1] = "</table>"
    return table.concat(parts)
end

--- 长 tag 名的断行处理。
---
--- 为什么必须做：实测把样式表套上后在真机等价宽度（408px 正文栏）里量，
--- `us-gaap:CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents` 这种
--- 65 个字符、不含空格与连字符的 token 会把段落撑到 440px（正文栏只有 408px），
--- 于是内容溢出到屏幕外；浏览器不会自己拆一个超长的单词。
--- 处理办法：在驼峰处插 `<br/>`，把每个片段压到 40 字符以内。
--- 这里刻意不用空格断行 —— 空格会被当成标签名的一部分，破坏它作为标识符的可复制性。
--- 换行处不引入任何字符，读到的是同一个标识符，只是排成两行。
local function wrapTag(tag, limit)
    limit = limit or 40
    if #tag <= limit then return esc(tag) end
    local pieces, cur = {}, ""
    local i = 1
    while i <= #tag do
        local ch = tag:sub(i, i)
        -- 驼峰边界：小写/数字后面紧跟大写，就是一个可以断开的位置
        local boundary = (i > 1)
            and ch:match("%u")
            and tag:sub(i - 1, i - 1):match("[%l%d]")
        if boundary and #cur >= limit - 12 then
            pieces[#pieces + 1] = cur
            cur = ""
        end
        cur = cur .. ch
        i = i + 1
    end
    if cur ~= "" then pieces[#pieces + 1] = cur end
    return table.concat(pieces, "<br/>")
end

--- 指标的标题行：指标名 ｜ 口径 ｜ 单位 ｜ 数据来源 tag
local function caption(metric, rec, caliber_label, scale_label)
    local bits = { metric.label, caliber_label }
    if scale_label then bits[#bits + 1] = "单位：" .. scale_label end
    local head = esc(table.concat(bits, " ｜ "))
    -- 写成「us-gaap 标签 X」而不是「us-gaap:X」：后者里的连字符是一个断行点，
    -- 排出来会变成「来源 us-」/「gaap:…」两半，很难看；而且长标签本来就要靠
    -- wrapTag 插的换行点，前缀跟着凑在一起只会更挤。
    local tail = "数据来源 us-gaap 标签 " .. wrapTag(rec.tag)
    if rec.tag_note then tail = tail .. " ｜ 口径提示：" .. esc(rec.tag_note) end
    return string.format('<p class="secmeta">%s ｜ %s</p>', head, tail)
end

--- 被后续申报改写的行：必须给出两次的值与申报日，否则读者会以为数据错了。
local function revisionNote(metric, periods, scale)
    local lines = {}
    for _pi = 1, #periods do
        local p = periods[_pi]
        if p.revised then
            lines[#lines + 1] = string.format(
                "%s：本表取 %s 申报的最新值 %s，早先一次（%s%s）为 %s",
                rangeLabel(p), tostring(p.filed),
                fmtValue(p.val, metric, scale),
                tostring(p.prev_filed),
                p.prev_form and (" " .. p.prev_form) or "",
                fmtValue(p.prev_val, metric, scale))
        end
    end
    if #lines == 0 then return nil end
    return string.format(
        '<p class="secnote">* SEC 的结构化数据允许后续申报改写同一期间的值，本表一律取最新申报。%s。</p>',
        esc(table.concat(lines, "；")))
end

local function takeFirst(list, n)
    local out = {}
    for _i = 1, #list do
        if #out >= n then break end
        out[#out + 1] = list[_i]
    end
    return out
end

--- 只保留「离该指标最新报告期不太远」的期间。
--- 为什么要这条：有些指标的存量数据很长（特斯拉营收能追到 2018），如果只按条数截断，
--- 早期稀疏、近期密集时会截出一堆三年前的行，读者真正要看的最近几期反而被挤掉。
--- 窗口默认 1100 天（约三年），用一个指标的**最新报告期**而不是「今天」当基准，
--- 因为设备时钟不可信，而数据里自带的日期是事实。
local function withinWindow(list, newest, window_days)
    if not newest then return list end
    local y, m, d = ymd(newest)
    if not y then return list end
    local cutoff = daysFromCivil(y, m, d) - window_days
    local out = {}
    for _i = 1, #list do
        local ly, lm, ld = ymd(list[_i].end_date)
        if ly and daysFromCivil(ly, lm, ld) >= cutoff then out[#out + 1] = list[_i] end
    end
    return out
end

--- 这些季度行能不能当「单季度序列」展示。
---
--- 为什么需要这条判断：按年初至今列示的指标（现金流量表就是典型）在 SEC 数据里
--- **只有 Q1 才存在真正的单季值**（Q1 的年初至今恰好等于单季），其余季度的单季值根本
--- 不存在。这样几行 Q1 排在一张叫「单季度」的表里会被当成连续季度，所以宁可不列。
--- 判据：至少两行，且不止一种「年内季度」（全是 Q1 就说明它不是按季度报的）。
--- 注意不能要求相邻两期正好差一个季度：10-K 只报全年，所以每年缺 Q4 是常态
--- （实测特斯拉的营收季度序列就是 Q1/Q2/Q3，年年缺 Q4），那样会把正常数据也挡掉。
local function quarterSeriesOk(list)
    if #list < 2 then return false end
    local seen, distinct = {}, 0
    for _qi = 1, #list do
        local _y, m = ymd(list[_qi].end_date)
        local q = m and (math.floor((m - 1) / 3) + 1) or 0
        if not seen[q] then seen[q] = true distinct = distinct + 1 end
    end
    return distinct >= 2
end

--- 累计表里的 12 个月期间是不是「不同起点混在一起」。
--- 为什么需要：亚马逊这类公司在 10-Q 里另行申报「十二个月止于本季末」的滚动值，
--- 于是同一个口径下会出现「2025-01 ~ 2025-12」和「2025-07 ~ 2026-06」两条 12 个月记录。
--- 它们都是公司自己申报的真值，不能丢，但必须让读者知道要按「报告期」列区分。
local function mixedYearly(list)
    local starts = {}
    local n = 0
    for _yi = 1, #list do
        local p = list[_yi]
        if p.caliber == "FY" and p.start then
            local y, m = ymd(p.start)
            local key = y and string.format("%02d", m) or "?"
            if not starts[key] then starts[key] = true n = n + 1 end
        end
    end
    return n > 1
end

--- 划分：单季度 / 累计 / 时点 / 其他期间（非标准长度）。各取最近的若干条。
local function splitPeriods(periods, opts)
    opts = opts or {}
    local quarters, cumulative, instant, others = {}, {}, {}, {}
    for _pi = 1, #periods do
        local p = periods[_pi]
        if p.caliber == "Q" then
            quarters[#quarters + 1] = p
        elseif p.caliber == "I" then
            instant[#instant + 1] = p
        elseif p.caliber == "X" then
            others[#others + 1] = p
        else
            cumulative[#cumulative + 1] = p
        end
    end
    local window = opts.recent_window_days or 1100
    local newest = periods[1] and periods[1].end_date or nil
    quarters = withinWindow(quarters, newest, window)
    cumulative = withinWindow(cumulative, newest, window)
    instant = withinWindow(instant, newest, window)
    return {
        quarters = takeFirst(quarters, opts.quarters or 8),
        cumulative = takeFirst(cumulative, opts.cumulative or 6),
        instant = takeFirst(instant, opts.instant or 8),
        others = takeFirst(withinWindow(others, newest, window), opts.others or 4),
        -- 供调用方判断「季度表为什么没上」
        quarters_in_window = quarters,
    }
end

--- 生成整章。
---@param company table { cik=, name= }
---@param concept_data table collectConcepts 的产物；也可以只给
---       { raw = { [tag] = payload } }，函数会自己解析（方便离线测试）
---@param opts table { quarters=, cumulative=, min_metrics=, include_tags= }
---@return boolean, string|nil, string|nil
function SecMetrics.buildChapter(company, concept_data, opts)
    opts = opts or {}
    if type(concept_data) ~= "table" then
        return false, nil, "buildChapter 需要 collectConcepts/analyze 的产物"
    end
    local data = concept_data
    if not data.metrics then
        if type(concept_data.raw) == "table" then
            data = SecMetrics.analyze(company, concept_data.raw, concept_data.errors, opts)
        else
            return false, nil, "concept_data 里既没有 metrics 也没有 raw"
        end
    end

    -- 指标定义按 id 找，不靠数组下标对齐 —— 这样即使调用方只传了一部分指标，
    -- 或者以后调整了 METRICS 的顺序，也不会把「营收」的表头盖到「净利润」的数据上。
    local by_id = {}
    for _mi = 1, #SecMetrics.METRICS do by_id[SecMetrics.METRICS[_mi].id] = SecMetrics.METRICS[_mi] end

    -- 先算出每个指标要展示的期间，顺手统计「取到几个」
    local blocks, ok_count = {}, 0
    for _mi = 1, #data.metrics do
        local rec = data.metrics[_mi]
        local metric = by_id[rec.id]
        if not metric then
            return false, nil, "未知的指标 id：" .. tostring(rec.id)
        end
        if rec.available then
            local groups = splitPeriods(rec.periods, opts)

            -- 单季度表的两条硬条件：
            --   a) 至少 2 行（1 行不成系列）；
            --   b) 行与行之间必须是连续的季度。按年初至今列示的指标（现金流量表就是
            --      典型）在 SEC 数据里只有 Q1 才存在真正的单季值，散着几个 Q1 排在
            --      一张叫「单季度」的表里会被当成连续季度，所以宁可不列，改一句说明。
            local quarter_ok = quarterSeriesOk(groups.quarters)
            local quarter_note = nil
            if not quarter_ok and rec.kind ~= "instant" then
                local in_window = groups.quarters_in_window or {}
                if #in_window == 0 then
                    quarter_note = "SEC 的结构化数据里这个指标没有最近三年内的单季度值，请看下面的累计表。"
                else
                    local labels = {}
                    for _qi = 1, #in_window do labels[#labels + 1] = periodLabel(in_window[_qi]) end
                    quarter_note = string.format(
                        "SEC 的结构化数据里这个指标只有 %s 才有单季值 —— 它只在财报里按"
                        .. "「年初至今」列示（现金流量表就是典型），其余季度的单季值并不存在。"
                        .. "所以这里不列单季度表，请以累计表为准。",
                        table.concat(labels, "、"))
                end
            end

            -- 单位按该指标所有展示期间的最大绝对值决定（同指标的各张表统一，
            -- 否则「营收」的两张表会因为峰值不同而一个用美元、一个用百万美元）
            local max_abs = 0
            local function scan(list)
                for _i = 1, #list do
                    local a = list[_i].val
                    if a < 0 then a = -a end
                    if a > max_abs then max_abs = a end
                end
            end
            if quarter_ok then scan(groups.quarters) end
            scan(groups.cumulative); scan(groups.instant); scan(groups.others)

            if #groups.quarters + #groups.cumulative + #groups.instant + #groups.others > 0 then
                ok_count = ok_count + 1
                blocks[_mi] = {
                    rec = rec, metric = metric, groups = groups, max_abs = max_abs,
                    quarter_ok = quarter_ok, quarter_note = quarter_note,
                }
            end
        end
    end

    if ok_count < (opts.min_metrics or 1) then
        return false, nil, string.format(
            "只有 %d 个指标取到数据（少于要求的 %d 个），不生成关键指标章节",
            ok_count, opts.min_metrics or 1)
    end

    local parts = {}

    -- 章节开头的说明。这一段是「让读者不会误读」的关键，不是装饰：
    -- 数据来源、取值规则、期间口径的换算规则、单位都在这里说清楚。
    local as_of = data.as_of and ("截至 " .. data.as_of .. "（最后一次申报日）") or ""
    parts[#parts + 1] = string.format(
        '<p class="secnote">本节数字取自 SEC 官方 XBRL 结构化数据（data.sec.gov 的 companyconcept 接口），'
        .. '不是从后面的财报原文抄来的；原始报表仍完整保留在后面，可以逐条核对。'
        .. '取值规则：同一期间被多次申报时（修正申报，或被后续申报改写），一律取申报日最新的一次，'
        .. '被改写过的行标「*」并在表下写明两次的值与申报日。'
        .. '期间按长度分开列：单季度一张表，半年／前三季／全年累计另一张表，'
        .. '季度标签按报告期截止日所属的自然季度标注（与公司自己的财季编号可能不同）。'
        .. '很长的 XBRL 标签名在驼峰处换行排印，换行处不添加任何字符，标签名本身不变。%s</p>',
        esc(as_of))

    parts[#parts + 1] = string.format(
        '<p class="secmeta">已取到 %d / %d 个指标 ｜ 数据来源 us-gaap（XBRL） ｜ 单位见各表表头</p>',
        ok_count, #data.metrics)

    -- 取不到的指标集中在开头列一次，读者不用翻到后面才知道缺了什么
    local missing = {}
    for _mi = 1, #data.metrics do
        local rec = data.metrics[_mi]
        if not rec.available then missing[#missing + 1] = rec end
    end
    if #missing > 0 then
        local names = {}
        for _mi = 1, #missing do names[#names + 1] = missing[_mi].label end
        parts[#parts + 1] = string.format(
            '<p class="secnote">以下指标没有取到（SEC 的结构化数据里没有这家公司的这个口径）：%s。'
            .. '各处列出了试过的候选 tag 与失败原因，没有用别的指标顶替。</p>',
            esc(table.concat(names, "、")))
    end

    -- 按 METRICS 的顺序输出：取不到的指标在它自己的位置上写「未取到」并列出
    -- 试过的候选 tag —— 读者翻到「净利润」下面就该看到「总负债」缺了什么，
    -- 而不是要翻到章节末尾去猜。
    for _bi = 1, #data.metrics do
        local block = blocks[_bi]
        if not block then
            local rec = data.metrics[_bi]
            local tried = {}
            for _ci = 1, #rec.candidates do
                tried[#tried + 1] = string.format("%s（%s）",
                    wrapTag("us-gaap:" .. rec.candidates[_ci].tag, 34),
                    esc(rec.candidates[_ci].status))
            end
            parts[#parts + 1] = string.format(
                '<p class="secmeta">%s ｜ 未取到</p>', esc(rec.label))
            parts[#parts + 1] = string.format(
                '<p class="secnote">SEC 的结构化数据里没有这家公司的这个口径。'
                .. '用过的候选 tag：%s。没有用别的指标顶替。</p>',
                table.concat(tried, "；"))
        else
        local rec, metric = block.rec, block.metric
        local groups = block.groups
        -- 单位：金额用百万/美元二选一，每股收益固定用「美元/股」
        local scale, scale_label = pickScale(block.max_abs)
        if metric.unit_key == "USD/shares" then
            scale, scale_label = 1, "美元/股"
        end

        if #groups.quarters > 0 and block.quarter_ok then
            parts[#parts + 1] = caption(metric, rec, "单季度", scale_label)
            parts[#parts + 1] = renderTable(groups.quarters, metric, scale, opts)
            local note = revisionNote(metric, groups.quarters, scale)
            if note then parts[#parts + 1] = note end
        elseif block.quarter_note then
            parts[#parts + 1] = string.format('<p class="secnote">%s | %s</p>',
                esc(metric.label), esc(block.quarter_note))
        end

        if #groups.instant > 0 then
            parts[#parts + 1] = caption(metric, rec, "期末时点（资产负债表日）", scale_label)
            parts[#parts + 1] = renderTable(groups.instant, metric, scale, opts)
            local note = revisionNote(metric, groups.instant, scale)
            if note then parts[#parts + 1] = note end
        end

        if #groups.cumulative > 0 then
            parts[#parts + 1] = caption(metric, rec, "累计（半年／前三季／全年）", scale_label)
            parts[#parts + 1] = renderTable(groups.cumulative, metric, scale, opts)
            local note = revisionNote(metric, groups.cumulative, scale)
            if note then parts[#parts + 1] = note end
            if mixedYearly(groups.cumulative) then
                parts[#parts + 1] = '<p class="secnote">本表里有多个起点不同的 12 个月期间'
                    .. '（既有年初起的财年值，也有公司另行申报的 12 个月滚动值），'
                    .. '都是原文申报的数字，请按「报告期」列区分。</p>'
            end
        end

        if #groups.others > 0 then
            parts[#parts + 1] = caption(metric, rec, "其他期间（非标准长度）", scale_label)
            parts[#parts + 1] = renderTable(groups.others, metric, scale, opts)
            local note = revisionNote(metric, groups.others, scale)
            if note then parts[#parts + 1] = note end
        end
        end
    end

    return true, table.concat(parts, "\n")
end

--------------------------------------------------------------------------
-- 六、机器可读报告（给验收脚本用，也方便排查「为什么选了那个 tag」）
--------------------------------------------------------------------------

function SecMetrics.summary(company, concept_data, opts)
    opts = opts or {}
    local data = concept_data
    if not data.metrics and type(concept_data.raw) == "table" then
        data = SecMetrics.analyze(company, concept_data.raw, concept_data.errors, opts)
    end
    local out = {
        name = company and company.name,
        cik = company and company.cik,
        as_of = data.as_of,
        requests = data.requests,
        bytes = data.bytes,
        ok_count = data.ok_count,
        metric_count = #data.metrics,
        metrics = {},
        missing = {},
    }
    for _mi = 1, #data.metrics do
        local rec = data.metrics[_mi]
        local item = {
            id = rec.id, label = rec.label, kind = rec.kind,
            available = rec.available, tag = rec.tag,
            unit = rec.unit, newest = rec.newest, oldest = rec.oldest,
            dup_groups = rec.dup_groups, revised = rec.revised,
            candidates = {},
            shown = {},
        }
        for _ci = 1, #rec.candidates do
            local c = rec.candidates[_ci]
            item.candidates[#item.candidates + 1] = {
                tag = c.tag, status = c.status, entries = c.entries,
                oldest = c.oldest, newest = c.newest,
                chosen = (c.tag == rec.tag),
            }
        end
        if rec.available then
            local groups = splitPeriods(rec.periods, opts)
            local function dump(list, caliber)
                for _i = 1, #list do
                    local p = list[_i]
                    item.shown[#item.shown + 1] = {
                        group = caliber, caliber = p.caliber, label = periodLabel(p),
                        start = p.start, ["end"] = p.end_date, val = p.val,
                        filed = p.filed, form = p.form, accn = p.accn,
                        folded = p.folded, revised = p.revised,
                        prev_val = p.prev_val, prev_filed = p.prev_filed,
                        filing = SecMetrics.filingUrl(company.cik, p.accn),
                    }
                end
            end
            local quarter_ok = quarterSeriesOk(groups.quarters)
            if quarter_ok then dump(groups.quarters, "Q") end
            dump(groups.instant, "I")
            dump(groups.cumulative, "CUM")
            dump(groups.others, "OTHER")
            item.quarter_table_shown = quarter_ok
        else
            out.missing[#out.missing + 1] = { id = rec.id, label = rec.label, why = rec.why }
        end
        out.metrics[#out.metrics + 1] = item
    end
    return out
end

-- 暴露出去供单元测试直接调（纯函数，不影响行为）
SecMetrics._periodsOf = function(payload, metric) return periodsOf(payload, metric) end
SecMetrics._millionsString = millionsString
SecMetrics._perShareString = perShareString
SecMetrics._groupDigits = groupDigits
SecMetrics._caliberOf = caliberOf
SecMetrics._daysBetween = daysBetween

return SecMetrics
