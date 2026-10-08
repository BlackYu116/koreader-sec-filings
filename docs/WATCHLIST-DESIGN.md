# sec_watchlist.lua —— 关注列表、增量更新、阅读进度保留

本文是 `sec_watchlist.lua` 的用法与接线说明，面向**接下来要把它接进插件的人**（主会话）。
验证日志在 `evidence/watchlist_test.txt`、`evidence/sdr_test.txt`；
结论摘要以及「为什么这么设计」在 `FINDINGS.md` 的「关注列表 + 增量更新」小节。

一句话定位：这是**纯逻辑模块**，不 require 任何 `ui/*` 或设备模块，因此可以脱开 KOReader
用 LuaJIT 直接跑（`work/watchlist_test.lua`、`work/sdr_test.lua` 就是这么跑的）。

复跑验证：

```sh
cd .context/kindle/tools/sec_epub
sh work/run_sec_watchlist_checks.sh        # 两项测试，日志写进 evidence/
```

---

## 1. 数据模型

关注列表对象（下面叫 `wl`）在内存里长这样：

```lua
wl = {
    version        = 1,
    keep_seen      = 200,       -- 每家保留的 accession 条数上限（全局默认）
    entries        = { ... },   -- 关注的公司在数组里，顺序 = 界面上的顺序
    -- 下面这些是运行时附加信息，不写进文件：
    load_path      = "...",     -- load 时给的路径（save 不带参数就写回这里）
    load_container = "sec_watchlist",  -- 若数据是挂在某个键下的，要合写回去
    load_error     = nil,       -- 读失败时的说明；有值就默认拒绝保存
}
```

每个 `entries[i]`：

| 字段 | 含义 | 谁来写 |
| --- | --- | --- |
| `cik` | 10 位补零字符串，如 `"0000320193"` | `add` / 手工改 |
| `name` / `legal` / `ticker` | 显示用 | `add` / 手工改 |
| `forms` | 关注的表格类型，如 `{ "10-Q" }`；**空 = 默认三类** `10-K/10-Q/8-K` | `add` / 手工改 |
| `enabled` | `false` = 不再自动下载 | `toggle` |
| `seen_upto_date` | **基线**（`"YYYY-MM-DD"`）：`filing_date` 早于这一天的 filing 一律不补 | `markSeen` / `commit` |
| `seen` | 「已经下过」的 accession，新在前，上限 `keep_seen` | `markSeen` |
| `last_accession` | 上一次实际下到的最新一份（只用于显示） | `markSeen` |
| `last_checked_at` / `last_filing_date` | 上次去 SEC 查的时间 / SEC 上最新的 filing 日期 | `markChecked` |
| `first_run_done` | 是否已经建立过基线 | `commit` |
| `keep_seen` | 本家单独的 seen 上限（可选） | 手工改 |

## 2. API

```lua
local SecWatchlist = require("sec_watchlist")

-- ── 存储 ────────────────────────────────────────────────────────────────
local wl, err   = SecWatchlist.load(source, opts)      -- 永远返回可用的 wl，err 只是提示
local ok, err   = SecWatchlist.save(wl, target, opts)  -- 原子写（.tmp → rename，留一代 .old）
local entries   = SecWatchlist.list(wl, opts)          -- opts.live 取内部引用，默认深拷贝
local entry     = SecWatchlist.find(wl, cik)

-- source / target 可以是：字符串路径 | LuaSettings 实例（有 :flush()）| 带 .data 的表 | nil
-- opts: { seed_defaults = true|false, companies = SecSource.companies,
--         key = "sec_watchlist", force = true|false }

-- ── 增删 ────────────────────────────────────────────────────────────────
local ok, info  = SecWatchlist.add(wl, { cik = "0000320193", name = "苹果", ticker = "AAPL",
                                         forms = { "10-Q" } })        -- 已存在则只更新显式给的字段
local ok, info  = SecWatchlist.remove(wl, cik)      -- 不存在也不算错，info.removed = false
local ok, info  = SecWatchlist.toggle(wl, cik_or_entry)  -- 不在列表里 = 加入并打开
local ok, info  = SecWatchlist.resetBaseline(wl, cik, opts)  -- cik = nil → 全部；见 §5

-- ── 增量判定 ────────────────────────────────────────────────────────────
local updates, err = SecWatchlist.planUpdates(wl, fetched, opts)   -- 纯函数，不改状态
local ok, info     = SecWatchlist.commit(wl, updates, opts)        -- 整轮成功时一次落账
local ok, info     = SecWatchlist.markSeen(wl, cik, accns, opts)   -- 部分成功时逐条落账
local ok           = SecWatchlist.markChecked(wl, cik, opts)
local line         = SecWatchlist.summaryLine(updates[i])          -- 直接给界面显示
local ok           = SecWatchlist.isValidDate("2026-09-30")        -- 判断 YYYY-MM-DD

-- ── 阅读进度（.sdr）─────────────────────────────────────────────────────
local snapshot  = SecWatchlist.keepProgress(epub_path, opts)         -- 打包前
local ok, report = SecWatchlist.restoreProgress(epub_path, snapshot, { policy = "shift" })  -- 打包后
local ok, info   = SecWatchlist.forgetProgress(epub_path, opts)      -- 明确丢弃
local dirs       = SecWatchlist.sidecarDirs(epub_path, opts)
```

`planUpdates` 的 `opts`：`max_new_per_company`（默认 8）、`first_run_new`（默认 10）、
`since_date`（`"YYYY-MM-DD"`，字符串比较，不看时区）、`only_enabled`（默认 `true`）、
`exact_forms`（`true` 时 `10-Q` 不匹配 `10-Q/A`）。

`updates[i]`：

```lua
{
    cik, name, ticker, forms,
    new_filings  = { { accn, form, date, primary, items }, ... },  -- 新在前
    new_count    = 3,
    first_run    = false,      -- 本家是第一次跑（没有任何历史状态）
    total_known  = 47,         -- 本次拿到且通过 forms/since_date 过滤的条数
    truncated    = 5,          -- 因为 max_new_per_company 被截掉、**下次会继续**的条数
    history_skipped = 52,      -- 基线之前的日期，**不会**再补（除非 resetBaseline）
    since_skipped   = 12,      -- 被 since_date 跳过的条数
    baseline_date     = "2026-08-01",   -- 当前基线（日期）
    baseline_new_date = "2026-09-30",   -- 落账后基线要推到这一天（truncated > 0 时为 nil）
    closing_accns = { "0000320193-26-000099", ... },  -- 「收盘清单」，见 §5
    latest_filing = "2026-09-30",
    warnings     = { "有 3 条重复 accession，已合并…" },
}
```

`fetched` 的形状很宽容（另一个并行任务在写 `sec_search.lua`，字段名对不齐也不要紧）：
数组或按 cik 建索引都行，文档数组的键名认 `filings / recent / documents / docs /
docs_list / files`，单条 filing 的字段认 `accn / accession_number / accessionNumber`
与 `date / filing_date / filingDate` 等等（见 `normalizeFiling`）。

## 3. 接线一：设置界面（`main.lua`）

### 3.1 放哪儿、什么时候读

```lua
local DataStorage = require("datastorage")   -- main.lua 里已经有了
local SecWatchlist = require("sec_watchlist")

local WATCHLIST_PATH = DataStorage:getSettingsDir() .. "/sec_watchlist.lua"

function SecFilings:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/secfilings.lua")
    -- 只在这里读一次。菜单是随时会被重建的，别在 addToMainMenu 里读文件
    self.watchlist = SecWatchlist.load(WATCHLIST_PATH)
    self.ui.menu:registerToMainMenu(self)
end
```

`load` 永远返回一个能用的 `wl`：文件不存在时自动填默认 7 家（＝旧版本的行为，用户无感）。
第二返回值非 nil 表示「文件在，但读不出来」，此时 `wl.load_error` 有值，`save` 会**拒绝**
写入（怕覆盖用户手改坏的文件）——界面应当把这个 err 显示出来。

### 3.2 菜单项

```lua
local function label(entry)
    return entry.ticker and (entry.name .. " (" .. entry.ticker .. ")") or entry.name
end

items[#items + 1] = {
    text = _("关注列表"),
    sub_item_table_func = function()
        local sub = {}
        -- list 默认返回深拷贝：界面里改东西不会污染状态
        local entries = SecWatchlist.list(self.watchlist)
        for _i = 1, #entries do                 -- 注意：循环变量不能叫 `_`（会遮蔽 gettext）
            local entry = entries[_i]
            sub[#sub + 1] = {
                text = label(entry),
                -- 有 checked_func 的条目：KOReader 的 TouchMenu 会自动保持菜单打开并
                -- 重新求值勾选状态（frontend/ui/widget/touchmenu.lua:916-923 实测如此），
                -- 所以这里不需要自己 updateItems()
                checked_func = function()
                    local live = SecWatchlist.find(self.watchlist, entry.cik)
                    return live ~= nil and live.enabled ~= false
                end,
                callback = function()
                    SecWatchlist.toggle(self.watchlist, entry.cik)
                    SecWatchlist.save(self.watchlist)
                    -- 想过「这家只跟 10-Q」这类更细的开关，就把 forms 做成二级菜单：
                    -- SecWatchlist.add(self.watchlist, { cik = entry.cik, forms = { "10-Q" } })
                end,
            }
        end

        sub[#sub + 1] = {
            text = _("添加公司（输入 CIK）"),
            keep_menu_open = false,
            callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local dialog
                dialog = InputDialog:new{
                    title = _("输入 SEC CIK（1–10 位数字）"),
                    input = "",
                    buttons = { {
                        {
                            text = _("取消"),
                            callback = function() UIManager:close(dialog) end,
                        },
                        {
                            text = _("添加"),
                            callback = function()
                                local text = dialog:getInputText()
                                local cik, cerr = SecWatchlist.normalizeCik(text)
                                if not cik then
                                    UIManager:show(InfoMessage:new{ text = tostring(cerr) })
                                else
                                    -- name 先占位，等 sec_search 拿到公司名再更新
                                    SecWatchlist.add(self.watchlist, { cik = cik, name = cik })
                                    SecWatchlist.save(self.watchlist)
                                end
                                UIManager:close(dialog)
                            end,
                        },
                    } },
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
        }

        sub[#sub + 1] = {
            text = _("重新扫描最近的文件"),
            help_text = _("清空增量进度，下一次会把最近若干份重新下一遍（用于刚放宽表格类型时补历史）"),
            callback = function()
                SecWatchlist.resetBaseline(self.watchlist)
                SecWatchlist.save(self.watchlist)
                UIManager:show(InfoMessage:new{ text = _("已重置，下次下载会重新扫描") })
            end,
        }

        return sub
    end,
}
```

**保存时机**：每次增删/toggle 之后立刻 `save`。设备随时可能休眠断电，一次 4 KB 的原子写
代价可以忽略；「等退出再存」会让用户刚改的东西丢掉。

### 3.3 几个必须注意的坑（都是这个项目已经踩过的）

1. `SecWatchlist` 用的循环变量是 `_ci / _ei / _fi` 这类名字，**不要**在自己写的循环里用
   `for _, x in ipairs(...)` —— `main.lua` 顶部有 `local _ = require("gettext")`，
   写 `_` 会把它遮蔽掉，上一轮就是这么让 7 家公司全部下载失败的。
2. **不要**给任何会 yield 的调用套 `pcall`（`Trapper:info` 内部会 `coroutine.yield`）。
   本模块所有函数都走 `(ok, err)` 返回值，一个 pcall 都不需要。
3. 界面消息有长度上限（`MAX_UI_ERRORS` 那套）。`summaryLine` 只输出一行，适合直接拼。

## 4. 接线二：只下新文件

`SecJob` 现在的口径是「每家公司最近 N 份」。接上关注列表之后，口径要变成「本轮该下的那几份」，
也就是把 `planUpdates` 的结果当输入传给打包流程。模块本身不管打包，下面是它期望的调用形状：

```lua
function SecFilings:runWatchlist()
    -- 1) 取元数据（由 sec_search.lua 提供；旧代码里是 SecSource:recentFilings）
    local fetched, ferr = SecSearch:fetchAll(SecWatchlist.list(self.watchlist, { enabled_only = true }))
    if not fetched then
        return self:reportResult({}, { tostring(ferr) })
    end

    -- 2) 算出该下哪些（纯逻辑，不改状态）
    local updates = SecWatchlist.planUpdates(self.watchlist, fetched, {
        max_new_per_company = self:getMaxNew(),      -- 设置项，默认 8
        first_run_new       = self:getFirstRunNew(), -- 设置项，默认 10
        since_date          = self:getSinceDate(),   -- 设置项，默认 nil
    })

    -- 3) 逐家下载 + 打包。**只有真下成功的那些才 markSeen**
    --    注意 closing_accns 也要一起标：那是「最新那一天」的全部 accession，
    --    不标的话同日文件会永远卡在基线边界上被反复取。
    local results, errors, marked_any = {}, {}, false
    for _ui = 1, #updates do
        local u = updates[_ui]
        if u.new_count == 0 then
            SecWatchlist.markChecked(self.watchlist, u.cik)
        else
            local ok, done = self:buildCompany(u)    -- 你自己实现：抓正文 → 打包 epub
            if ok then
                SecWatchlist.markSeen(self.watchlist, u.cik,
                    (function()
                        local accns = {}
                        for _fi = 1, #u.new_filings do accns[#accns + 1] = u.new_filings[_fi].accn end
                        return accns
                    end)(),
                    { newest = u.latest_accession,
                      -- 只有「本轮该下的都下成了」才能推进基线，否则没下的那份会被跳过
                      upto_date = (u.truncated == 0 and done == u.new_count)
                          and u.baseline_new_date or nil })
                marked_any = true
            else
                errors[#errors + 1] = string.format("%s：%s", u.name, tostring(done))
            end
        end
        results[#results + 1] = SecWatchlist.summaryLine(u)
    end

    if marked_any then
        SecWatchlist.save(self.watchlist)   -- 一定要存，不然下次又把同样的文件下一遍
    end
    self:reportResult(results, errors)
end
```

想一把梭（全成功时才落账）可以用 `SecWatchlist.commit(self.watchlist, updates)`，
它会替你处理「truncated > 0 时不动基线」。**部分失败时不要用它。**

## 5. 增量语义：为什么需要「基线」，以及为什么它按**日期**比

只靠 `seen`（下过的 accession 清单）解释不了「SEC 上那几千份历史我要不要」。所以每家有一个
**基线** `seen_upto_date`（日期）：

- **首次运行**：只下最近的 `first_run_new` 份，其余算「历史」，在 `history_skipped` 里如实报出，
  **不补**。基线落在「本次看到的最新那一天」。
- **之后的运行**：`filing_date >= 基线` 且不在 `seen` 里的才算新文件。
- 基线**只在「本轮该下的都下完」时前进**。被 `max_new_per_company` 截掉的那些日期都不早于基线，
  下一轮接着下，不会丢（`truncated` 会告诉用户还有多少）。
- `since_date` 跳过的条数记在 `since_skipped` 里；日期读不出来的条目一律**当候选**
  （宁可多取也不静默丢），并在 `warnings` 里报出条数。
- **「收盘清单」`closing_accns`**：基线是个日期，光靠日期分不出「和基线同日、但这次没下」的文件，
  所以最新那一天里的全部 accession 会被单独列出来，落账时一并标记。集成方自己落账时
  **必须把 `closing_accns` 一起 `markSeen`**（`commit` 已经替你做了），否则同日的文件会卡在
  边界上反复出现。

### 5.1 为什么不用 accession 当基线（这条是真实数据教出来的）

第一版就是按 accession 比的：`accn > 基线` 就算新，理由是 accession 单调递增。**这个假设在真实
数据上当场就碎了。**

EDGAR 的 accession 形如 `NNNNNNNNNN-YY-NNNNNN`，前 10 位是**上报代理机构**的编号，**不是公司的
CIK**。苹果那 368 份 filing 里出现了 **42 个不同的前缀**，里面还有 EDGAR 自己的 `9999999997-*`
（`NO ACT` / `CERTNYS` 这类行政记录）。于是按字符串排序会出现：

```
9999999997-17-000809   2016-10-27   NO ACT     ← 字符串最大
0001140361-26-038674   2026-10-05   4          ← 字符串反而更小
```

后果实测：第一次运行结束后，第二次运行又冒出 **16 份「新文件」**，而它们全是几个月前的老文件。

**为什么本机合成数据发现不了**：合成数据里的 accession 是用 CIK 当前缀造的，天然单调递增。
是拿真实的 `sec_search.lua` 输出（`work/watchlist_realsearch_test.lua`，真的访问 data.sec.gov）
跑一遍才炸出来的。

所以基线改成按 `filing_date` 比：字典序就是时间序，`filingDate` 就是申报日，跟「新不新」直接对应。

### 5.2 一个必须知道的副作用

**被 `forms` 挡掉的文件也会被基线越过。** 比如用户只跟 `10-Q`，期间来了一份 8-K：它不进候选，
但下一次落账时基线照样按「最新日期」前进，于是这份 8-K 的日期落到基线之下，之后就算把 `forms`
放宽到包含 8-K，它也不会被补下。这是「基线之前不补」的直接推论，要补只能调 `resetBaseline`。
界面上建议这样措辞：「改了关注范围后，如果想把这段时间漏掉的文件补上，请点『重新扫描最近的文件』」。

## 6. 列表文件格式与迁移

### 6.1 格式

```lua
-- sec_watchlist.lua —— 关注列表（由 secfilings.koplugin 维护，也可以手改）
-- ……（见文件里的几行手改说明）
return {
    ["entries"] = {
        [1] = {
            ["cik"] = "0000320193",
            ["enabled"] = true,
            ["forms"] = { "10-K", "10-Q" },
            ["seen"] = { "0000320193-26-000045" },
            ["seen_upto_date"] = "2026-08-01",
            ["name"] = "苹果",
            ["ticker"] = "AAPL",
            ...
        },
    },
    ["keep_seen"] = 200,
    ["updated_at"] = 1791234567,
    ["version"] = 1,
}
```

- **可被 `LuaSettings` 读**：就是 `return { ... }`，而 `LuaSettings:open` 内部是 `pcall(dofile)`
  （`frontend/luasettings.lua:open`）。序列化格式与 KOReader 自己的 `dump.lua` 逐字节对齐
  （只在「字符串里的换行怎么写」和首行注释上有差别，已用 `evidence/sdr_test.txt` 第 4 节证明）。
- **可人工编辑**：键按字母序、4 空格缩进、UTF-8 原样保留、允许注释、允许 `cik` 写数字、
  允许 `forms` 写单个字符串、允许 `seen` 写成以 accession 为键的表。
- **原子写**：先写 `<path>.tmp`，再把旧的挪成 `<path>.old`，最后 rename 覆盖。
  读的时候读不出来会回退读 `.old`（和 `LuaSettings` 同一套策略）。

### 6.2 迁移策略

| 从什么状态来 | 怎么迁移 |
| --- | --- |
| 旧版本（没有关注列表文件） | 不用做任何事。`load` 发现文件不存在 → 自动填默认 7 家（= 现在的行为），第一次保存才落盘 |
| 想省一个文件，把列表塞进现有 `secfilings.lua` | 存成 `sec_watchlist` 键下的表即可。`load` 会认出来并记住位置，`save` 会**合写回去**，不会把 `limit` / `include_reports` 等其它设置冲掉（有测试盯着这件事） |
| 以后给 entry 加字段 | 直接加。`normalizeEntry` 对缺字段一律给默认值，旧文件读回来不会报错 |
| 以后改结构（比如每家一个份数上限） | 把 `version` 升到 2，在 `load` 里按 `version` 做升级；**不要**在 `load` 里删字段 |
| 用户手改坏了文件 | `load` 返回 err 且 `wl.load_error` 有值；`save` 默认拒绝写（除非 `force = true`）。主文件坏了会尝试读 `.old` |

## 7. 阅读进度（`.sdr`）保留

### 7.1 现状为什么要改

`SecEpub:write` 在换文件前 `purgeDir` 掉 `.sdr`。这个决定本身是对的：
KOReader **不会**在打开时校验 `partial_md5_checksum`（v2026.07.2 的
`frontend/apps/reader/readerui.lua:497` 只在它为空时写入，从不比较），所以内容换了而
`.sdr` 还在，旧位置会被照原样套用 —— 打开就跳到莫名其妙的地方。但有了关注列表之后用户会
**反复更新**，每次更新都把阅读设置和进度清零，副作用无法接受。

### 7.2 做法：抢救外观、重算位置

把 `.sdr` 里的东西分成两类：

| 类别 | 键 | 处理 |
| --- | --- | --- |
| 位置/缓存 | `last_xpointer`、`last_percent`、`percent_finished`、`doc_pages`、`pagemap_doc_pages`、`cache_file_path`、`cre_dom_version`、`stats` | **丢弃** |
| 标注 | `annotations`（书签/高亮，内含 xpointer） | 默认丢弃，条数在 `report.annotations_dropped` 报出；`keep_annotations = true` 可保留 |
| 外观/读者设置 | `copt_*`（字号、行距、页边距、字距…）、`style_tweaks`、`view_mode`、`visible_pages`、`text_lang`、`highlight_drawer`、`doc_props`、`summary`、`partial_md5_checksum` 等 | **原样保留** |

另外两件事必须一起做：

- `cre_dom_version` 一定要清。`readerrolling.lua:170` 的逻辑是「没有 `cre_dom_version` 但**有**
  `last_xpointer`」→ 按很久以前打开过的老书处理，主动请求**最老的 DOM 版本**。我们重建的是
  全新内容，这个组合会让 crengine 用错 DOM 版本；而只清 `last_xpointer` 又会触发上面那条分支。
  两个一起清才干净。
- `.sdr/cache/` 里的旧排版缓存要清掉（目录留着，KOReader 会重建）。

### 7.3 两种位置策略

```lua
-- ① 从头开始（默认，推荐）
SecWatchlist.restoreProgress(path, snap, { policy = "reset" })

-- ② 按内容增量平移
SecWatchlist.restoreProgress(path, snap, { policy = "shift",
    old_chars = old_total, new_chars = new_total })   -- 不传就用两份 epub 的字节数估算
```

`shift` 的算术：新文件是**前插**的，旧书里 0→1 的比例 `f` 对应新书里的
`(1 - old/new) + f × (old/new)`，结果写进 `last_percent`（KOReader v2026.07.2 的
`readerrolling.lua:204` 仍然读它：*"we read last_percent just for backward compatibility"*），
同时同步 `percent_finished` 让书库里的百分比也一致。

### 7.4 集成顺序（三步，缺第 ③ 步只是回到旧行为，不会产生坏文件）

```lua
local snap = SecWatchlist.keepProgress(epub_path)                    -- ① 打包前：读旧 .sdr
local ok, err = SecEpub:write(epub_path, book)                       -- ② 打包（内部会清 .sdr）
if ok then
    SecWatchlist.restoreProgress(epub_path, snap, { policy = self:getProgressPolicy() })  -- ③
end
```

`SecEpub:write` 里那句 `purgeDir` **可以原样留着**：保留策略是在打包之后重建一个干净的
`.sdr`，不需要去改 zip 打包方式（也不该改 —— 见下一条）。

### 7.5 代价（必须如实告诉用户）

- **`reset`**：下次打开落在书的开头。因为目录顺序是「最新的一份在最前面」，落点正好是用户
  最想看的那个文件，精确且无猜测。代价是丢掉了「上次读到哪儿」。
- **`shift`**：估算。误差来自两点 —— (a) 用 epub 字节数或正文字节数代理「页数」，而 crengine
  的分页还受表格/图片密度影响；(b) 基线只有一份（旧版本），多轮累积误差会叠加。实测一轮
  平移后进度从 41.28% → 43.47%（新书前插了 25866 字节 / 共 694413 字节，见
  `evidence/sdr_test.txt` 第 5 节）。**误差量级是「一份 filing」**，也就是可能会停在上一份或
  下一份文件里，不会指到书外。
- **两种策略都会丢标注**（高亮/书签的 xpointer 指向旧文字）。数量会报出来，界面应该提示。
- **阅读时长统计**按 `.sdr` 里的 `partial_md5_checksum` 找数据库里那一行
  （`plugins/statistics.koplugin/main.lua:829` 就是这么查的）。我们**保留**这个键，所以
  statistics 仍把这本书当成同一本，历史阅读时长不断档；**代价**是丢掉了 `stats`
  （它按旧页码记账）—— 也就是「上一次落库之后、还没写进数据库的那点阅读时长（一次会话的量级）」
  会丢。这个取舍是刻意的：相比「换个 md5 就多出一条新书记录、历史断成两截」，重算一次更符合预期。
- **完全不想保留**时用 `SecWatchlist.forgetProgress(path)`，它把候选目录都删掉。

### 7.6 为什么不用「改包不换文件」

有人会想到：只更新 zip 里的 `content.html`/`content.opf`、其余条目原样保留，这样
KOReader 就认得出是同一本书。**这条路走不通，而且不需要**：

1. `Archiver.Writer` 只能新写 zip，不能就地替换条目，实现「改包」得先把整包解出来再重写一遍，
   复杂度远高于收益。
2. 更关键的是，KOReader 判断「是不是同一本书」用的是 `util.partialMD5`：它在
   **256B / 1KB / 4KB / 16KB / 64KB / 256KB / 1MB / 4MB … 各取 1024 字节**做哈希
   （`frontend/util.lua:1094`，v2026.07.2 同）。采样点一直铺到 1GB 偏移，
   所以「在文件前面垫一段不变的字节让哈希不变」这种做法没用 —— 只要正文变了，哈希就会变。
3. 而且 KOReader 打开时**根本不比较**这个哈希（见 7.1），所以哈希变不变并不影响阅读位置
   会不会被套用 —— 决定因素是 `.sdr` 里那个 `last_xpointer`。

结论：老老实实「换包 + 重建一个干净的 `.sdr`」是正确且简单的做法。

## 8. 明确不做的事

- 本模块**不联网、不解析 SEC 响应**。`fetched` 由 `sec_search.lua` 提供。
- 本模块**不写 UI**，也不改 `main.lua` / `sec_job.lua` / `sec_epub.lua`。
- 不处理「同一 accession 下多个文档」的合并下载：`planUpdates` 会把它们去重成一条并在
  `warnings` 里报出条数。要不要把 exhibit 一起抓，是 `sec_search.lua` + `sec_job.lua` 的事。
- 不迁移 `readhistory` / statistics 数据库里的旧记录。
- 不实现「跟 8-K 的某个 item（比如 2.02 业绩发布）」这种更细的过滤；`items` 字段已经带出来了，
  留给下一轮。

## 9. 验证入口

```sh
sh work/run_sec_watchlist_checks.sh        # 需要联网；只跑离线三项用 SKIP_NETWORK=1
```

| 日志 | 覆盖内容 |
| --- | --- |
| `evidence/watchlist_test.txt` | 静态约束（无 `ui/*`、无 `for _,`、无 goto）、默认列表、首次运行、二次 0 份、注入 1 份、forms 过滤与 `exact_forms`、`resetBaseline`、每轮上限与「下次继续」、`since_date`、`seen` 上限、增删/toggle、原子写与幂等、人工编辑回读、坏文件与 `.old` 回退、`fetched` 形状兼容、LuaSettings 承载、合写不冲掉其它设置、性能（7×1000 份） |
| `evidence/sdr_test.txt` | 侧车目录名、`keepProgress` 逐键核对、重建后逐键核对、「前后对照表」、与 KOReader `dump.lua` 的逐字节比对、reset/shift 两种策略的真实数值、反复更新三轮、旧目录名兼容、坏元数据、无 `.sdr` 场景 |
| `evidence/lfs_test.txt` | 用假 lfs 强制走设备上真正会走的分支（目录创建、删除、`.sdr` 重建），因为 Mac 上那条分支平时跑不到 |
| `evidence/realsearch_test.txt` | **真实数据**对接：真的调用 `sec_search.lua` 访问 data.sec.gov，拿它的返回直接喂 `planUpdates`；真实 accession 前缀分布、真实日期、完整增量循环（首轮 8 份 → 二次 0 份 → 注入 1 份 → 恰好 1 份）。需要联网，`SKIP_NETWORK=1` 可跳过 |
