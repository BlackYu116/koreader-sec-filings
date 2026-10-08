--[[
SEC 研习室 —— 菜单外壳（薄）。

抓取 / 清理 / 打包 / 搜索 / 关注列表 / 关键指标全在其他文件里。本文件只做界面该做的事：
注册菜单、读写设置、等网络、把进度接到 Trapper、汇报结果。

外壳为什么必须保持这么薄（前两轮都栽在这里）
  1) 循环变量不能叫 `_`。文件顶部 `local _ = require("gettext")`；一旦写成
     `for _, f in ipairs(...)`，循环体里的 `_()` 就变成「调用一个数字」（设备实测报
     attempt to call local '_' (a number value)，7 家公司全部下载失败）。
     下面所有循环一律用 ci / fi / si / ei / wi / pi 这类明确变量名。
  2) 绝不能把 SecJob.run / SecSearch:resolve 包进 pcall。Trapper:info() 内部会
     coroutine.yield()，而 LuaJIT 不允许跨 pcall 边界 yield；一旦包了，上面那个遮蔽
     问题修好后会立刻变成 "attempt to yield across a C-call boundary"。
     错误一律靠返回值给出，外壳只负责展示。
  3) 结果不能只靠 InfoMessage。设备上 appearance.koplugin 给 InfoMessage:init 打的
     包装有无限递归缺陷（长消息必崩，见交付说明），所以完整结果另外写 logger
     （也就是 crash.log），界面消息自己做长度上限。

界面结构（都在 工具 🔧 → SEC 研习室 下面）
    下载全部关注的公司      —— 只带「关注列表」里勾上的
    下载某一家              —— 7 家固定公司，不受关注列表影响（想临时下一家用它）
    搜索公司…               —— ticker / CIK / 公司名，可看**任意**表格类型
                             （13F-HR、S-1、DEF 14A、4、SC 13D …，不再只有财报）
    搜索结果                —— 只在搜过一次之后出现
    我的关注列表            —— 逐家勾选；勾上的才会被「下载全部」带上
    打开下载目录
    设置                    —— 联系邮箱 / 份数 / 报表类型 / 图片 / 表格宽度 / 清缓存

输出：/mnt/us/documents/SEC 财报/<公司名> SEC 财报.epub
]]

local DataStorage = require("datastorage")
local FFIUtil = require("ffi/util")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local SecJob = require("sec_job")
local SecSearch = require("sec_search")
local SecSource = require("sec_source")
local SecWatchlist = require("sec_watchlist")

local T = FFIUtil.template

local OUT_DIR = SecJob.default_out_dir or "/mnt/us/documents/SEC 财报"

--- 界面消息最多列这么多条失败原因，其余只进 crash.log。
--- InfoMessage 的排版缺陷要求消息不能太高，所以这里必须有上限。
local MAX_UI_ERRORS = 3
--- 界面消息的字节上限（防止再撞上 appearance.koplugin 那个递归缺陷）。
local MAX_UI_MSG = 260

--- 搜索：往回看几年。任意表格类型的总量可以很大，所以必须有边界；
--- 被截断时 listFilings 会把 truncated 置位，界面上如实说明。
---
--- 「不设 limit」是**故意的**：limit 会让「边扫边筛」提前收工，类型分布就只能统计到
--- 被截断的那一段，筛选项会变成假的（实测 Apple 给 limit=12 时分布里只剩 Form 4）。
--- 真正的边界由 since（时间窗）和 max_total（内存上限）给。
local SEARCH_SINCE_YEARS = 3
local SEARCH_PAGE_SIZE = 20
local SEARCH_MAX_TOTAL = 5000
--- 类型筛选菜单里最多列几种类型（按份数从多到少；其余用「全部类型」看）。
local SEARCH_FORM_CHOICES = 12
--- 一眼能看出「这是财报」的三类。内部人交易（Form 4）一份就是几页，
--- 在任意类型清单里会把它们彻底淹没，所以给一个一键跳过的入口。
local REPORT_FORMS = { "10-K", "10-Q", "8-K" }

--- SEC 要求 User-Agent 里带一个可联系的邮箱，否则一律 403。
--- **代码里不硬编码任何私人邮箱**（开源后会被爬虫盯上），默认是占位串；
--- 真实邮箱由用户在「设置 → SEC 联系邮箱」里填，存进 secfilings.lua。
local DEFAULT_UA_NAME = "koreader-sec-filings"
local UA_PLACEHOLDER = DEFAULT_UA_NAME .. " (no contact email configured)"

--- 表格宽度：取值**不在这里写死**，直接用 sec_source 里那张实测预设表
--- （F2 的推导：avail_em = 660 / 阅读字号设置值；KOReader 菜单档位 12…44、
---  默认 22 → 30 em，最大档 44 → 15 em）。
--- 两边各写一份数字迟早会漂，所以这里只留档位名字。
local TABLE_WIDTH_DEFAULT = "tight"   -- 最保守那一档：字号拉到最大也还能读
--- 万一 sec_source 被换成旧版（没有预设表），至少还能跑。
local TABLE_WIDTH_FALLBACK = { loose = 30, normal = 22, tight = 15 }

--- 7 家固定公司（下载某一家时用）。cik 用数字，和 SecSource.companies 一致。
local TICKERS = {
    [1318605] = "TSLA",
    [1045810] = "NVDA",
    [320193]  = "AAPL",
    [1018724] = "AMZN",
    [1326801] = "META",
    [1652044] = "GOOGL",
    [789019]  = "MSFT",
}

local SecFilings = WidgetContainer:extend{
    name = "secfilings",
    is_doc_only = false,
    settings = nil,
    watchlist = nil,
    search_state = nil,
}

-- ---------------------------------------------------------------- 初始化

function SecFilings:init()
    self.settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/secfilings.lua")
    self.cache_dir = DataStorage:getSettingsDir() .. "/secfilings"
    self:loadWatchlist()
    self.ui.menu:registerToMainMenu(self)
end

--- 关注列表存进插件自己的设置文件（secfilings.lua 的 sec_watchlist 段），
--- 不另开一个文件：用户要手改的话只需改一个地方。
function SecFilings:loadWatchlist()
    local wl, err = SecWatchlist.load(self.settings, {
        key = "sec_watchlist",
        seed_defaults = true,
        companies = self:seedCompanies(),
    })
    if err then
        logger.warn("secfilings: 关注列表读取有问题: " .. tostring(err))
    end
    self.watchlist = wl
end

function SecFilings:saveWatchlist()
    local ok, err = SecWatchlist.save(self.watchlist, self.settings, {
        key = "sec_watchlist",
    })
    if not ok then
        logger.warn("secfilings: 关注列表保存失败: " .. tostring(err))
        self:showMessage(T(_("关注列表没能保存：%1"), tostring(err)))
    end
    return ok
end

--- 首次运行时给关注列表铺 7 家默认公司。
--- ticker 用内置映射补上（SecWatchlist 只要求 cik + name 一定在）。
function SecFilings:seedCompanies()
    local out = {}
    for ci = 1, #SecSource.companies do
        local co = SecSource.companies[ci]
        out[#out + 1] = {
            cik = co.cik,
            name = co.name,
            legal = co.legal,
            ticker = TICKERS[co.cik],
        }
    end
    return out
end

-- ---------------------------------------------------------------- 设置

function SecFilings:getLimit()
    return tonumber(self.settings:readSetting("limit")) or 5
end

function SecFilings:includeReports()
    return self.settings:nilOrTrue("include_reports")
end

function SecFilings:downloadImages()
    return self.settings:nilOrTrue("images")
end

function SecFilings:getEmail()
    return tostring(self.settings:readSetting("email") or "")
end

function SecFilings:hasEmail()
    local email = self:getEmail()
    return email ~= "" and email:find("@", 1, true) ~= nil
end

function SecFilings:getUaName()
    local name = tostring(self.settings:readSetting("ua_name") or "")
    if name == "" then return DEFAULT_UA_NAME end
    return name
end

--- User-Agent。邮箱没填时给占位串（**不要**编一个假邮箱，
--- 那样 SEC 会照收，问题就被藏起来了）。没填的后果会在结果里明说。
function SecFilings:userAgent()
    if not self:hasEmail() then return UA_PLACEHOLDER end
    return self:getUaName() .. " " .. self:getEmail()
end

function SecFilings:tableWidthPresets()
    return SecSource.table_width_presets or TABLE_WIDTH_FALLBACK
end

function SecFilings:getTableWidth()
    local w = tostring(self.settings:readSetting("table_width") or "")
    if self:tableWidthPresets()[w] then return w end
    return TABLE_WIDTH_DEFAULT
end

function SecFilings:tableAvailEm()
    return self:tableWidthPresets()[self:getTableWidth()]
end

function SecFilings:getCacheDir()
    return self.cache_dir
end

-- ---------------------------------------------------------------- 菜单

function SecFilings:addToMainMenu(menu_items)
    menu_items.sec_filings = {
        text = _("SEC 研习室"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:getSubMenuItems() end,
    }
end

function SecFilings:getSubMenuItems()
    local items = {}

    -- 搜过之后，「搜索结果」放最上面：这是用户最想接着点的东西。
    if self.search_state then
        items[#items + 1] = {
            text = self:searchStateLabel(),
            sub_item_table_func = function() return self:getSearchItems() end,
        }
    end

    local watched = self:watchedCompanies()
    items[#items + 1] = {
        text = T(_("下载全部关注的公司（%1 家 × 最近 %2 份）"), #watched, self:getLimit()),
        sub_item_table_func = function() return self:getBulkDownloadItems() end,
    }

    items[#items + 1] = {
        text = _("下载某一家"),
        sub_item_table_func = function()
            local sub = {}
            for ci = 1, #SecSource.companies do
                local co = SecSource.companies[ci]
                sub[#sub + 1] = {
                    text = co.name,
                    callback = function() self:startDownload({ self:adHocEntry(co) }) end,
                }
            end
            return sub
        end,
    }

    items[#items + 1] = {
        text = _("搜索公司…"),
        help_text = _("按股票代码、CIK 或公司名搜；可以看任意表格类型，不只是财报。"),
        callback = function() self:searchDialog() end,
    }

    items[#items + 1] = {
        text = T(_("我的关注列表（%1 家）"), #SecWatchlist.list(self.watchlist)),
        sub_item_table_func = function() return self:getWatchlistItems() end,
    }

    items[#items + 1] = {
        text = _("打开下载目录"),
        callback = function() self:openFolder() end,
    }

    items[#items + 1] = {
        text = _("设置"),
        sub_item_table_func = function() return self:getSettingItems() end,
    }

    return items
end

--- 「下载全部关注的公司」展开成逐家一项：这样某一家失败时其余的照样能做，
--- 也让用户能只重跑失败的那一家。
function SecFilings:getBulkDownloadItems()
    local sub = {}
    local watched = self:watchedCompanies()
    if #watched == 0 then
        sub[#sub + 1] = {
            text = _("关注列表里没有勾选任何公司"),
            callback = function()
                self:showMessage(_("先去「我的关注列表」里勾几家。"))
            end,
        }
        return sub
    end
    sub[#sub + 1] = {
        text = T(_("全部 %1 家一起做"), #watched),
        callback = function() self:startDownload(watched) end,
    }
    for wi = 1, #watched do
        local e = watched[wi]
        sub[#sub + 1] = {
            text = self:watchLabel(e),
            callback = function() self:startDownload({ e }) end,
        }
    end
    return sub
end

-- ---------------------------------------------------------------- 关注列表

--- 关注列表里 enabled 的条目，转成 SecJob 认的公司表。
function SecFilings:watchedCompanies()
    local out = {}
    local entries = SecWatchlist.list(self.watchlist, { enabled_only = true })
    for wi = 1, #entries do
        local e = entries[wi]
        out[#out + 1] = {
            cik = tonumber(e.cik) or e.cik,
            cik_pad = e.cik,
            name = e.name or e.cik,
            ticker = e.ticker,
        }
    end
    return out
end

--- 「下载某一家」用的临时条目：不走关注列表、不带增量过滤。
function SecFilings:adHocEntry(co)
    return {
        cik = co.cik,
        cik_pad = string.format("%010d", co.cik),
        name = co.name,
        ticker = TICKERS[co.cik],
        ad_hoc = true,
    }
end

function SecFilings:watchLabel(e)
    local label = e.name or e.cik
    if e.ticker and e.ticker ~= "" then label = label .. "（" .. e.ticker .. "）" end
    return label
end

function SecFilings:getWatchlistItems()
    local sub = {}
    local entries = SecWatchlist.list(self.watchlist)

    if #entries == 0 then
        sub[#sub + 1] = {
            text = _("列表是空的。用「搜索公司…」找到一家再勾上。"),
            callback = function() self:searchDialog() end,
        }
        return sub
    end

    for wi = 1, #entries do
        local e = entries[wi]
        local cik = e.cik
        sub[#sub + 1] = {
            text = self:watchLabel(e),
            help_text = _("勾上 = 以后会被「下载全部关注的公司」带上；取消勾选不会删除，只是暂时不自动下。"),
            -- keep_menu_open：关注列表一般要连着勾好几家，每勾一下就关菜单会很难用。
            keep_menu_open = true,
            checked_func = function() return e.enabled ~= false end,
            callback = function() self:toggleWatch(cik) end,
        }
    end

    sub[#sub + 1] = {
        text = _("全部勾上 / 全部取消"),
        sub_item_table = {
            {
                text = _("全部勾上"),
                callback = function() self:setAllWatched(true) end,
            },
            {
                text = _("全部取消"),
                callback = function() self:setAllWatched(false) end,
            },
        },
    }

    return sub
end

function SecFilings:toggleWatch(cik)
    local ok, info = SecWatchlist.toggle(self.watchlist, cik)
    if not ok then
        self:showMessage(T(_("没能改动关注列表：%1"), tostring(info)))
        return
    end
    self:saveWatchlist()
end

function SecFilings:setAllWatched(on)
    local entries = SecWatchlist.list(self.watchlist, { live = true })
    for wi = 1, #entries do
        entries[wi].enabled = on and true or false
    end
    if self.watchlist then
        self.watchlist.user_modified_at = os.time()
    end
    self:saveWatchlist()
end

--- 把搜索到的公司加进关注列表（已在列表里就打开它）。
function SecFilings:watchCompany(company)
    if not company or not company.cik then return end
    local wl = self.watchlist
    local existing = SecWatchlist.find(wl, company.cik)
    if not existing then
        SecWatchlist.add(wl, {
            cik = company.cik,
            name = company.name,
            ticker = company.ticker,
        })
    end
    local e = SecWatchlist.find(wl, company.cik)
    if e then
        e.enabled = true
        if company.name and not e.name then e.name = company.name end
        if company.ticker and not e.ticker then e.ticker = company.ticker end
    end
    if wl then wl.user_modified_at = os.time() end
    self:saveWatchlist()
    self:showMessage(T(_("已把「%1」加进关注列表。"), tostring(company.name or company.cik)))
end

function SecFilings:isWatched(cik)
    local e = SecWatchlist.find(self.watchlist, cik)
    return e ~= nil and e.enabled ~= false
end

-- ---------------------------------------------------------------- 设置菜单

function SecFilings:getSettingItems()
    local items = {}

    items[#items + 1] = {
        text = self:hasEmail()
            and T(_("SEC 联系邮箱：%1"), self:getEmail())
            or _("SEC 联系邮箱：（还没填）"),
        help_text = _("SEC 要求每个请求的 User-Agent 里带一个能联系到你的邮箱，否则一律拒绝（403）。填你自己的邮箱即可。"),
        callback = function() self:emailDialog() end,
    }

    items[#items + 1] = {
        text = T(_("每家公司下载份数：%1"), self:getLimit()),
        sub_item_table_func = function()
            local sub = {}
            local choices = { 10, 5, 3, 1 }
            for si = 1, #choices do
                local n = choices[si]
                sub[#sub + 1] = {
                    text = tostring(n),
                    keep_menu_open = true,
                    checked_func = function() return self:getLimit() == n end,
                    callback = function()
                        self.settings:saveSetting("limit", n)
                        self.settings:flush()
                    end,
                }
            end
            return sub
        end,
    }

    items[#items + 1] = {
        text = _("包含 10-K / 10-Q 完整报告"),
        help_text = _("关掉就只下 8-K。10-K/10-Q 是完整年报/季报，文件大、耗时长。"),
        keep_menu_open = true,
        checked_func = function() return self:includeReports() end,
        callback = function()
            self.settings:toggle("include_reports")
            self.settings:flush()
        end,
    }

    items[#items + 1] = {
        text = _("下载并嵌入图片"),
        help_text = _("幻灯片类文件（分部业绩、财报演示）可见内容全在图片里，关掉就只剩一层文字。"),
        keep_menu_open = true,
        checked_func = function() return self:downloadImages() end,
        callback = function()
            self.settings:toggle("images")
            self.settings:flush()
        end,
    }

    items[#items + 1] = {
        text = T(_("表格宽度：%1"), self:tableWidthLabel()),
        help_text = _("按你平时阅读用的字号选。字号调得越大，一行能放的字越少，宽表格就越需要多拆几张。选错只会让表格挤一点，不会丢数字。"),
        sub_item_table_func = function()
            local sub = {}
            local presets = self:tableWidthPresets()
            -- 档位名与取值都来自 sec_source 的实测推导（avail_em = 660 / 字号设置）：
            -- 字号 22（KOReader 默认档）→ 30 em；字号 44（菜单最大档）→ 15 em。
            local order = {
                { "loose",  _("字号偏小"), _("阅读字号 12 – 22 之间") },
                { "normal", _("字号中等"), _("阅读字号 24 – 30 之间") },
                { "tight",  _("字号偏大"), _("阅读字号 32 – 44 之间；不确定就选这个") },
            }
            for si = 1, #order do
                local key = order[si][1]
                local label = order[si][2]
                local hint = order[si][3]
                sub[#sub + 1] = {
                    text = label,
                    help_text = T(_("%1。这一档按可用宽度 %2 em 拆表。"),
                        hint, tostring(presets[key])),
                    keep_menu_open = true,
                    checked_func = function() return self:getTableWidth() == key end,
                    callback = function()
                        self.settings:saveSetting("table_width", key)
                        self.settings:flush()
                    end,
                }
            end
            return sub
        end,
    }

    items[#items + 1] = {
        text = _("清空搜索引擎缓存"),
        help_text = _("缓存的是 SEC 的股票代码总表（一周内不会重取）。搜索找不到公司时可以清一下再试。"),
        callback = function() self:clearSearchCache() end,
    }

    return items
end

function SecFilings:tableWidthLabel()
    local w = self:getTableWidth()
    if w == "loose" then return _("字号偏小") end
    if w == "tight" then return _("字号偏大") end
    return _("字号中等")
end

function SecFilings:emailDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("SEC 联系邮箱"),
        description = _("填你自己的邮箱。SEC 只用它在请求量异常时联系你，不会拿来发广告。"),
        input = self:getEmail(),
        input_hint = "you@example.com",
        buttons = {
            {
                { text = _("取消"), callback = function() UIManager:close(dialog) end },
                { text = _("保存"), is_enter_default = true,
                  callback = function()
                      local text = dialog:getInputText() or ""
                      text = text:match("^%s*(.-)%s*$")
                      UIManager:close(dialog)
                      if text == "" then
                          self:showMessage(_("邮箱没填，SEC 会拒绝请求。"))
                          return
                      end
                      if not text:find("@", 1, true) then
                          self:showMessage(_("这不像一个邮箱地址，请检查后再填。"))
                          return
                      end
                      self.settings:saveSetting("email", text)
                      self.settings:flush()
                      self:showMessage(T(_("已保存：%1"), text))
                  end },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SecFilings:clearSearchCache()
    SecSearch.cache_dir = self:getCacheDir()
    local ok, removed = SecSearch:clearCache(self:getCacheDir())
    if ok then
        self:showMessage(T(_("缓存已清（%1 个文件）。"), tonumber(removed) or 0))
    else
        self:showMessage(T(_("清缓存失败：%1"), tostring(removed)))
    end
end

-- ---------------------------------------------------------------- 搜索

function SecFilings:searchDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("搜索公司"),
        description = _("输入股票代码、CIK 或公司名，例如：AAPL / 789019 / microsoft"),
        input = "",
        input_hint = "AAPL",
        buttons = {
            {
                { text = _("取消"), callback = function() UIManager:close(dialog) end },
                { text = _("搜索"), is_enter_default = true,
                  callback = function()
                      local text = dialog:getInputText() or ""
                      UIManager:close(dialog)
                      text = text:match("^%s*(.-)%s*$")
                      if text ~= "" then self:startSearch(text) end
                  end },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SecFilings:searchOpts()
    return {
        user_agent = self:userAgent(),
        cache_dir = self:getCacheDir(),
    }
end

function SecFilings:startSearch(query)
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function() self:runSearch(query) end)
    end)
end

--- 解析公司名。注意：这一步之后可能还需要用户再选一次（同分候选），
--- 所以把候选存进 search_state，由菜单渲染，而不是在这里弹窗硬选。
function SecFilings:runSearch(query)
    Trapper:info(T(_("正在查找「%1」…"), query))
    local ok, res, err, kind = SecSearch:resolve(query, self:searchOpts())
    if not ok then
        Trapper:reset()
        self.search_state = nil
        self:showMessage(T(_("查找失败：%1"), self:explainError(err, kind)))
        return
    end

    local aliases = res.aliases or { res }
    if #aliases > 1 and (res.ambiguous or res.tie) then
        Trapper:reset()
        self.search_state = { query = query, candidates = aliases }
        self:showMessage(T(_("「%1」匹配到 %2 家公司。请到 工具 → SEC 研习室 → 搜索结果 里挑一家。"),
            query, #aliases))
        return
    end

    self:loadFilings(res, query)
end

function SecFilings:sinceDate(years)
    local t = os.date("*t", os.time())
    return string.format("%04d-%02d-%02d", t.year - years, t.month, t.day)
end

function SecFilings:loadFilings(res, query, form)
    Trapper:info(T(_("正在列出 %1 的文件…"), tostring(res.name or res.cik)))
    local opts = self:searchOpts()
    opts.since = self:sinceDate(SEARCH_SINCE_YEARS)
    opts.max_total = SEARCH_MAX_TOTAL
    if form then opts.forms = { form } end
    local ok, list, err, kind = SecSearch:listFilings(res.cik_num or res.cik, opts)
    Trapper:reset()
    if not ok then
        self.search_state = nil
        self:showMessage(T(_("列出文件失败：%1"), self:explainError(err, kind)))
        return
    end

    local previous = self.search_state
    self.search_state = {
        query = query,
        company = {
            cik = list.cik_num or res.cik_num,
            cik_pad = list.cik or res.cik,
            name = list.name or res.name or tostring(res.cik),
            ticker = (res.tickers and res.tickers[1]) or res.ticker,
        },
        list = list,
        form = form,
        form_key = form,
        page = 1,
        -- 类型分布只有在「不筛类型」那一次才是完整的，筛过之后就只剩一种，
        -- 所以筛选项必须留着上一次的全量分布，否则菜单会塌成一个选项。
        summary = (not form) and list.form_summary
            or (previous and previous.summary) or nil,
    }

    local extra = ""
    if list.truncated then
        extra = _("（被上限截断，更早的没列出来）")
    end
    self:showMessage(T(_("找到 %1 份文件%2。请到 工具 → SEC 研习室 → 搜索结果 看清单。"),
        list.matched or #list.entries, extra))
end

function SecFilings:searchStateLabel()
    local st = self.search_state
    if not st then return _("搜索结果") end
    if st.candidates then
        return T(_("搜索结果：请选择公司（%1 家）"), #st.candidates)
    end
    local name = st.company and st.company.name or st.query or "?"
    local suffix = st.form and ("·" .. st.form) or ""
    return T(_("搜索结果：%1%2（%3 份）"), name, suffix, (st.list and st.list.matched) or 0)
end

--- 搜索结果子菜单。三种形态：候选公司列表 / 文件清单 / 空。
function SecFilings:getSearchItems()
    local st = self.search_state
    local sub = {}
    if not st then
        sub[#sub + 1] = {
            text = _("还没有搜索结果。回上一层点「搜索公司…」。"),
            callback = function() self:searchDialog() end,
        }
        return sub
    end

    if st.candidates then
        for ai = 1, #st.candidates do
            local cand = st.candidates[ai]
            sub[#sub + 1] = {
                text = self:candidateLabel(cand),
                callback = function() self:pickCandidate(cand, st.query) end,
            }
        end
        return sub
    end

    local list = st.list
    local entries = (list and list.entries) or {}
    local company = st.company or {}
    local total = #entries
    local pages = math.max(1, math.ceil(total / SEARCH_PAGE_SIZE))
    local page = math.min(math.max(1, tonumber(st.page) or 1), pages)

    sub[#sub + 1] = {
        text = st.form and T(_("共 %1 份「%2」（近 %3 年）"), total, st.form, SEARCH_SINCE_YEARS)
            or T(_("共 %1 份（近 %2 年）"), total, SEARCH_SINCE_YEARS),
        callback = function()
            local note = _("这是搜索结果汇总。下面每一条点一下就会把那一份做成书。")
            if list and list.truncated then
                note = note .. "\n" .. _("注意：结果被上限截断了，更早的文件没列出来。")
            end
            self:showMessage(note)
        end,
    }

    -- 类型筛选：这一步是必需功能，不是装饰。
    -- 实测苹果三年窗口 264 份里 Form 4 占 135 份（51%），不筛就是一堵内部人交易的墙。
    sub[#sub + 1] = {
        text = _("只看年报季报（10-K / 10-Q / 8-K）"),
        callback = function() self:setSearchForms(REPORT_FORMS) end,
    }
    sub[#sub + 1] = {
        text = st.form and T(_("按类型筛选（当前：%1）"), st.form)
            or _("按类型筛选（当前：全部）"),
        sub_item_table_func = function() return self:getFormFilterItems() end,
    }

    if company.cik and self:isWatched(company.cik) then
        sub[#sub + 1] = {
            text = T(_("「%1」已在关注列表里（点一下取消关注）"), tostring(company.name)),
            help_text = _("关注列表里的公司会被「下载全部关注的公司」带上。"),
            callback = function() self:toggleWatch(company.cik) end,
        }
    else
        sub[#sub + 1] = {
            text = T(_("关注「%1」（以后自动下载新文件）"), tostring(company.name)),
            help_text = _("关注之后不必每次自己搜；插件会按报表类型设置抓新的那几份。"),
            callback = function() self:watchCompany(company) end,
        }
    end

    sub[#sub + 1] = {
        text = T(_("下载这家最近 %1 份（照报表类型设置）"), self:getLimit()),
        callback = function()
            self:startDownload({ {
                cik = company.cik,
                cik_pad = company.cik_pad,
                name = company.name,
                ticker = company.ticker,
            } })
        end,
    }

    if total == 0 then
        sub[#sub + 1] = {
            text = _("这 %1 年里没有符合条件的文件。"),
            callback = function() self:showMessage(_("时间窗内没有文件。")) end,
        }
        return sub
    end

    local first = (page - 1) * SEARCH_PAGE_SIZE + 1
    local last = math.min(page * SEARCH_PAGE_SIZE, total)
    for fi = first, last do
        local f = entries[fi]
        sub[#sub + 1] = {
            text = self:filingLabel(f),
            callback = function() self:startFilingDownload(company, f) end,
        }
    end

    if pages > 1 then
        if page < pages then
            sub[#sub + 1] = {
                text = T(_("下一页（第 %1 / %2 页）"), page + 1, pages),
                callback = function() st.page = page + 1 end,
            }
        end
        if page > 1 then
            sub[#sub + 1] = {
                text = T(_("上一页（第 %1 / %2 页）"), page - 1, pages),
                callback = function() st.page = page - 1 end,
            }
        end
    end

    return sub
end

--- 类型筛选子菜单。选项来自「不筛类型」那一次拿到的分布（st.summary），
--- 否则筛过之后菜单会塌成只剩当前那一类。
function SecFilings:getFormFilterItems()
    local st = self.search_state
    local sub = {}
    if not st then return sub end

    sub[#sub + 1] = {
        text = _("全部类型"),
        checked_func = function() return st.form_key == nil end,
        callback = function() self:setSearchForms(nil) end,
    }

    local summary = st.summary or (st.list and st.list.form_summary) or {}
    local shown = math.min(#summary, SEARCH_FORM_CHOICES)
    for si = 1, shown do
        local row = summary[si]
        local form = row.form
        sub[#sub + 1] = {
            text = T(_("%1（%2 份）"), tostring(form), tonumber(row.count) or 0),
            checked_func = function() return st.form_key == form end,
            callback = function() self:setSearchForms({ form }) end,
        }
    end

    if #summary > shown then
        sub[#sub + 1] = {
            text = T(_("还有 %1 种类型没列出来"), #summary - shown),
            callback = function()
                self:showMessage(_("类型太多，只列了份数最多的几种。"))
            end,
        }
    end

    return sub
end

--- 按类型（一个或多个）重新筛。会联网重取，所以菜单会关掉，
--- 用户重新打开「搜索结果」时就是篘过的那一份。
function SecFilings:setSearchForms(forms)
    local st = self.search_state
    if not st or not st.company then return end
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function() self:refilterSearch(forms) end)
    end)
end

function SecFilings:refilterSearch(forms)
    local st = self.search_state
    if not st or not st.company then return end
    local label = forms and table.concat(forms, "/") or _("全部")
    Trapper:info(T(_("正在筛出「%1」…"), label))
    local opts = self:searchOpts()
    opts.since = self:sinceDate(SEARCH_SINCE_YEARS)
    opts.max_total = SEARCH_MAX_TOTAL
    opts.forms = forms
    local ok, list, err, kind = SecSearch:listFilings(st.company.cik, opts)
    Trapper:reset()
    if not ok then
        self:showMessage(T(_("筛选失败：%1"), self:explainError(err, kind)))
        return
    end
    st.list = list
    st.form = forms and table.concat(forms, "/") or nil
    st.form_key = forms and table.concat(forms, ",") or nil
    st.page = 1
    self:showMessage(T(_("筛出 %1 份。请重新打开 工具 → SEC 研习室 → 搜索结果。"),
        list.matched or #list.entries))
end

function SecFilings:candidateLabel(cand)
    local label = tostring(cand.name or cand.cik)
    if cand.ticker and cand.ticker ~= "" then
        label = cand.ticker .. " · " .. label
    end
    return label
end

function SecFilings:pickCandidate(cand, query)
    self:loadFilings({
        cik = cand.cik,
        cik_num = cand.cik_num or cand.cik,
        name = cand.name,
        ticker = cand.ticker,
        tickers = cand.ticker and { cand.ticker } or nil,
    }, query)
end

function SecFilings:filingLabel(f)
    local date = tostring(f.filing_date or "?")
    local form = tostring(f.form or "?")
    local desc = tostring(f.primary_doc_description or "")
    desc = utf8Trim(desc, 28)
    if desc ~= "" then
        return date .. "  " .. form .. "  " .. desc
    end
    return date .. "  " .. form
end

--- 按字节截断但不切碎 UTF-8 字符（菜单里显示用，切碎会出乱码方块）。
function utf8Trim(s, max_bytes)
    if s == nil then return "" end
    if #s <= max_bytes then return s end
    local cut = s:sub(1, max_bytes)
    while #cut > 0 do
        local b = cut:byte(#cut)
        if b < 0x80 or b >= 0xC0 then break end
        cut = cut:sub(1, #cut - 1)
    end
    return cut .. "…"
end

-- ---------------------------------------------------------------- 下载

--- 把某家公司的**某一类**文件加进关注范围（保留已有的类型不覆盖）。
--- 与 watchCompany 共用同一套「先补全名字/ticker，再打开 enabled」的逻辑，
--- 只是多一步把 form 并进 entry.forms。
function SecFilings:watchForm(company, form)
    if not company or not company.cik or not form or form == "" then return nil end
    self:watchCompany(company)
    local wl = self.watchlist
    local e = SecWatchlist.find(wl, company.cik)
    if not e then return nil end

    local forms = {}
    for fi = 1, #(e.forms or {}) do forms[#forms + 1] = e.forms[fi] end
    local found = false
    for fi = 1, #forms do
        if forms[fi] == form then found = true end
    end
    if not found then forms[#forms + 1] = form end
    e.forms = forms
    if wl then wl.user_modified_at = os.time() end
    self:saveWatchlist()
    return e
end

--- companies 为 nil 时用关注列表里勾上的那些。
--- override 用来临时盖掉某一两项设置（例如强制 include_reports=true，
--- 因为 sec_job 的 planView 在 include_reports=false 时会把所有条目的 forms
--- 改写成 {“8-K”}，那会把刚设好的单类型关注范围冲掉）。
function SecFilings:startDownload(companies, override)
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            self:runJob(companies, override)
        end)
    end)
end

--- 点搜索结果里的**某一份文件** → 把这家公司的**这一类**文件加进关注范围，
--- 并立即下载最近几份。
---
--- 为什么不「就下这一份」：sec_job 的整条链路是围着「关注列表 + 增量」转的
--- （planUpdates 过滤、基线推进、seen 落账、进度保留）。绕过它单独抓一份要另开
--- 一条打包路径 —— 书名、进度、落账都得再写一遍，而且那条路没有任何现成验证。
--- 用户点一份 13F 的真实意图也几乎总是「这类文件我以后要看」，
--- 折进关注范围既满足了这个意图，又复用了已经跑通的那条链路。
--- 「只下这一次」的入口仍然有：「下载这家最近 N 份」那一项在公司不在
--- 关注列表里时走 sec_job 的 pickLegacy 路径。
function SecFilings:startFilingDownload(company, filing)
    local form = tostring(filing.form or "")
    if form == "" then return end
    self:watchForm(company, form)
    self:startDownload({ {
        cik = company.cik,
        cik_pad = company.cik_pad,
        name = company.name,
        ticker = company.ticker,
    } }, { include_reports = true })
end

--- 封面素材目录：插件自己的 assets/covers/ 下，<cik>.jpg + generic.jpg。
--- 用 debug.getinfo 定位本文件所在目录 —— 开发时（仓库里）和装在设备上
--- （plugins/secfilings.koplugin/）两种布局都能找对，不必依赖加载器给的字段。
function SecFilings:getPluginDir()
    if self.plugin_dir then return self.plugin_dir end
    local src = ""
    local ok, info = pcall(debug.getinfo, 1, "S")
    if ok and type(info) == "table" and type(info.source) == "string" then
        src = info.source
    end
    local dir = src:match("^@(.*)/[^/]+$")
    self.plugin_dir = dir or "plugins/secfilings.koplugin"
    return self.plugin_dir
end

function SecFilings:getCoverDir()
    return self:getPluginDir() .. "/assets/covers"
end

--- 组装给 SecJob.run 的选项。**所有**新设置都只在这里落地，
--- 免得散在好几处（这一处也是与 sec_job.lua 的唯一接口面）。
--- 参数名必须与 sec_job.lua 头部注释里的表逐字一致（那里是权威）。
function SecFilings:jobOpts(companies, override)
    local opts = {
        limit           = self:getLimit(),
        include_reports = self:includeReports(),
        out_dir         = OUT_DIR,

        -- 身份。sec_job 的取值顺序：
        --   opts.user_agent > (opts.user_name + opts.user_email) > SecSource.user_agent > 占位串
        -- 两条路都给它，免得改了一边忘另一边。
        user_agent      = self:userAgent(),
        user_name       = self:getUaName(),
        user_email      = self:getEmail(),

        -- 图片（注意开关名是 fetch_images，不是 images）
        fetch_images    = self:downloadImages(),

        -- 关键指标章：取不到会跳过，不会让整本书失败
        metrics_chapter = true,

        -- 表格排版：可用宽度直接用 sec_source 那张实测预设表
        table_width     = self:getTableWidth(),
        table_avail_em  = self:tableAvailEm(),

        -- 关注列表：sec_job 用 planUpdates 做增量过滤并就地推进基线。
        -- **不传 save_watchlist**：它传 true 会退成 nil、不落盘。落账由本文件
        -- 在 runJob 里自己做，保持只有一个写入者。
        watchlist       = self.watchlist,

        -- 封面素材目录（<cik>.jpg + generic.jpg）
        cover_dir       = self:getCoverDir(),
    }

    if type(override) == "table" then
        for key, value in pairs(override) do opts[key] = value end
    end
    return opts
end

--- 真正跑一轮。注意：绝不能给它套 pcall（见文件头第 2 点）。
function SecFilings:runJob(companies, override)
    local list = companies or self:watchedCompanies()

    -- 邮箱没填时先把话说在前面：SEC 会回 403，结果里的错会很难看懂。
    if not self:hasEmail() then
        Trapper:info(_("还没填 SEC 联系邮箱，SEC 可能会拒绝这次请求。"))
    end

    -- Trapper:info 返回 false 表示用户把进度框点掉了。它就是那个 yield 点，
    -- 只能一路用返回值传出去。
    local progress_cb = function(msg) return Trapper:info(msg) end

    local results, errors, info = SecJob.run(list, self:jobOpts(list, override), progress_cb)

    Trapper:reset()
    self:reportResult(results, errors, info)

    -- 这轮跑过之后关注列表里的基线被推进了，写回磁盘。
    -- sec_job 不负责落盘（不传 save_watchlist），写入者只有这一处。
    self:saveWatchlist()
end

--- 把错误说明翻成用户能看懂的话。kind 由各模块统一给出。
function SecFilings:explainError(err, kind)
    local msg = tostring(err)
    if kind == "config" then
        return T(_("参数不对：%1"), msg)
    elseif kind == "no_match" then
        return _("没找到这家公司，换个写法试试（代码、CIK 或更完整的公司名）。")
    elseif kind == "notfound" then
        return _("SEC 那边没有这个 CIK。")
    elseif kind == "net" then
        return T(_("网络没通：%1"), msg)
    elseif kind == "ratelimit" or kind == "http" then
        if not self:hasEmail() then
            return _("SEC 拒绝了请求。最可能的原因是还没填「SEC 联系邮箱」。")
        end
        return T(_("SEC 拒绝了请求：%1"), msg)
    elseif kind == "json" then
        return T(_("SEC 返回的内容看不懂（可能改了格式）：%1"), msg)
    end
    return msg
end

--- 汇报结果。日志里留全量，界面上只留摘要。
function SecFilings:reportResult(results, errors, info)
    logger.info(string.format(
        "secfilings: ==== 本轮结束：成功 %d 家，失败 %d 家 ====", #results, #errors))
    for ei = 1, #errors do
        logger.warn(string.format("secfilings: [失败] %s", tostring(errors[ei])))
    end
    -- 第三返回值是 sec_job 新加的汇总（旧的两返回值写法也照样能用）。
    -- 全量只进日志；界面上只挑一两句能看懂的说。
    if type(info) == "table" then
        logger.info(string.format(
            "secfilings: 计划 %s / 成书 %s / 无新文件 %s / 图片 %s（失败 %s）/ 指标成功 %s 失败 %s",
            tostring(info.planned), tostring(info.made), tostring(info.no_new),
            tostring(info.images), tostring(info.images_failed),
            tostring(info.metrics_ok), tostring(info.metrics_failed)))
        if type(info.warnings) == "table" then
            for wi = 1, #info.warnings do
                logger.warn("secfilings: [警告] " .. tostring(info.warnings[wi]))
            end
        end
    end

    local lines = {
        T(_("完成：成功 %1 家，失败 %2 家。"), #results, #errors),
    }

    if type(info) == "table" then
        local bits = {}
        if (tonumber(info.images) or 0) > 0 then
            bits[#bits + 1] = T(_("图片 %1 张"), info.images)
        end
        if (tonumber(info.metrics_ok) or 0) > 0 then
            bits[#bits + 1] = T(_("关键指标 %1 家"), info.metrics_ok)
        end
        if (tonumber(info.no_new) or 0) > 0 then
            bits[#bits + 1] = T(_("%1 家没有新文件"), info.no_new)
        end
        if #bits > 0 then
            lines[#lines + 1] = table.concat(bits, "，")
        end
        -- 警告里可能有「图片疑似没进包」这类真问题，至少露一条出来
        if type(info.warnings) == "table" and #info.warnings > 0 then
            lines[#lines + 1] = tostring(info.warnings[1])
        end
    end

    local shown = math.min(#errors, MAX_UI_ERRORS)
    for ei = 1, shown do
        lines[#lines + 1] = tostring(errors[ei])
    end
    if #errors > shown then
        lines[#lines + 1] = T(_("……另有 %1 条，详见 crash.log"), #errors - shown)
    end
    if #results > 0 then
        lines[#lines + 1] = _("文件在书库的「SEC 财报」分类里。")
    end

    self:showMessage(table.concat(lines, "\n"))
end

function SecFilings:showMessage(text)
    local msg = tostring(text)
    if #msg > MAX_UI_MSG then
        msg = msg:sub(1, MAX_UI_MSG) .. "…"
    end
    UIManager:show(InfoMessage:new{
        text = msg,
        timeout = 15,
    })
end

function SecFilings:openFolder()
    local FileManager = require("apps/filemanager/filemanager")
    if self.ui.document then
        self.ui:onClose()
    end
    if FileManager.instance then
        FileManager.instance:reinit(OUT_DIR)
    else
        FileManager:showFiles(OUT_DIR)
    end
end

return SecFilings
