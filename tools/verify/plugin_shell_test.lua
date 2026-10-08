--[[
插件外壳（main.lua）的无头测试。

为什么要做这个
  上一轮交付失败的根本原因就是「外壳没被真正执行过」：菜单能点开、但一跑就炸，
  而且是在真机上炸。sec_job.lua 抽出来之后纯逻辑能无头测了，外壳还差一层。
  这里用 package.preload 把几个依赖真实屏幕/事件循环的 UI 模块换成桩，
  于是真实的 main.lua 能在 headless luajit 里被 require、实例化、
  构建菜单树、跑完整轮下载 —— 唯一没被覆盖的只有「widget 真的画出来」。

覆盖到的（正是容易出错的地方）
  * main.lua 顶层 require 是否都能解析（含新增的 sec_job）
  * getSubMenuItems()：菜单树构建，里面所有 gettext 调用
    （上一轮 `for _, x` 遮蔽 `_` 的 bug 就长在这一类地方）
  * runJob()：Trapper 接线、progress_cb 传递、SecJob.run 调用、
    Trapper:reset、reportResult 的结果汇报与截断
  * Trapper 不包 pcall 这一点：桩故意不 yield，但真实运行时 yield 也走同一条路径

用法（在设备上）：
  cd /mnt/us/koreader
  LD_LIBRARY_PATH=/mnt/us/koreader/libs:/mnt/us/koreader \
    ./luajit <这个文件> [下载家数]
]]

dofile("setupkoenv.lua")

local PLUGIN_DIR = "/mnt/us/koreader/plugins/secfilings.koplugin"
package.path = PLUGIN_DIR .. "/?.lua;" .. package.path

local shown_messages = {}

-- ── 桩：把需要真实屏幕/事件循环的模块替换掉 ────────────────────────────
package.preload["ui/trapper"] = function()
    return {
        info = function(self, msg)
            if msg then print("[Trapper:info] " .. msg) end
            return true   -- 没点取消
        end,
        wrap = function(self, f) return f() end,
        reset = function() return true end,
    }
end

package.preload["ui/uimanager"] = function()
    return {
        show = function(self, w)
            if w and w.text then
                shown_messages[#shown_messages + 1] = w.text
                print("── [UIManager:show InfoMessage] 内容如下 ──")
                for line in tostring(w.text):gmatch("[^\n]+") do print("      " .. line) end
                print("   （文本长度 " .. #tostring(w.text) .. " 字符）")
            end
            return true
        end,
    }
end

package.preload["ui/widget/infomessage"] = function()
    return { new = function(self, o) return o end }
end

-- 波次二新增：main.lua 现在要 require inputdialog（搜索框、邮箱输入框）。
-- 它的真实实现会拉 textinput -> keyboard -> device -> gesturedetector，
-- 而那个链路会读 G_reader_settings（本测试进程里不存在）。
-- 真机上没这个问题（KOReader 已经把它设好了）；这里是测试环境的桩。
package.preload["ui/widget/inputdialog"] = function()
    local ID = {}
    ID.__index = ID
    function ID:new(o)
        o = o or {}
        return setmetatable(o, ID)
    end
    function ID:getInputText() return "" end
    function ID:onShowKeyboard() return true end
    return ID
end

package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(self, f) return f() end }
end

package.preload["ui/widget/container/widgetcontainer"] = function()
    local WC = {}
    function WC:extend(o)
        o = o or {}
        o.__index = o
        return setmetatable(o, { __index = self })
    end
    return WC
end

-- ── 加载真实 main.lua ──────────────────────────────────────────────────
local here = arg[0]:match("^(.*)/[^/]+$") or "."
print("插件目录：" .. PLUGIN_DIR)

local ok, SecFilings = pcall(require, "main")
if not ok then
    print("✗ require(\"main\") 失败：" .. tostring(SecFilings))
    os.exit(1)
end
print("✓ require(\"main\") 成功，返回 " .. type(SecFilings))

local instance = setmetatable({}, { __index = SecFilings })
instance.ui = { menu = { registerToMainMenu = function() end }, document = nil }

local ok_init, err_init = pcall(function() return instance:init() end)
print(ok_init and "✓ init() 成功（settings 打开 + 注册菜单）"
    or ("✗ init() 失败：" .. tostring(err_init)))

-- ── 菜单树 ────────────────────────────────────────────────────────────
local ok_menu, menu_err = pcall(function()
    local items = instance:getSubMenuItems()
    print(string.format("✓ 顶层菜单项 %d 个：", #items))
    for mi = 1, #items do
        local it = items[mi]
        print(string.format("    [%d] %s  (子项 %s)", mi, it.text,
            it.sub_item_table and (#it.sub_item_table .. " 项")
            or (it.sub_item_table_func and "动态" or "-")))
        if it.sub_item_table_func then
            local sub = it.sub_item_table_func()
            for si = 1, #sub do
                print(string.format("           · %s", sub[si].text))
                -- 设置项里的「下载份数」再下一层
                if sub[si].sub_item_table_func then
                    local sub2 = sub[si].sub_item_table_func()
                    local texts = {}
                    for ti = 1, #sub2 do texts[#texts + 1] = tostring(sub2[ti].text) end
                    print(string.format("                → %s", table.concat(texts, ", ")))
                end
            end
        end
    end
end)
if not ok_menu then
    print("✗ getSubMenuItems() 失败：" .. tostring(menu_err))
    os.exit(1)
end

-- ── 设置读写 ──────────────────────────────────────────────────────────
print(string.format("✓ 设置：limit=%s include_reports=%s fetch_images=%s 表格宽度=%s(%s em) 邮箱=%s",
    tostring(instance:getLimit()), tostring(instance:includeReports()),
    tostring(instance:downloadImages()), tostring(instance:getTableWidth()),
    tostring(instance:tableAvailEm()),
    instance:hasEmail() and instance:getEmail() or "（未填，将用占位 UA）"))

-- 插件目录与封面素材（封面是波次二新接的，路径拼错就会静默没封面）
local pdir = instance:getPluginDir()
local cdir = instance:getCoverDir()
print(string.format("✓ 插件目录：%s", tostring(pdir)))
print(string.format("✓ 封面目录：%s", tostring(cdir)))
local lfs = require("libs/libkoreader-lfs")
print(string.format("    封面目录是目录: %s    generic.jpg 存在: %s",
    tostring(lfs.attributes(cdir, "mode") == "directory"),
    tostring(lfs.attributes(cdir .. "/generic.jpg", "mode") == "file")))

-- ── 真的跑一轮（走 startDownload 的路径，只是桩不会 yield） ────────────
-- 默认跑第 7 家（微软）：它最近的 8-K 是带 22 张图的幻灯片 exhibit，
-- 能一次把「图片进包 + 指标章 + 封面」三条波次二新路径全走一遍。
-- 换一家：luajit <本文件> <序号 1-7>
local idx = tonumber(arg[1]) or 7
local SecSource = require("sec_source")
local company = SecSource.companies[idx]
assert(company, "序号超出范围: " .. tostring(idx))
local companies = { company }

print()
print("── 通过外壳跑 " .. #companies .. " 家公司（走 NetworkMgr/Trapper 桩）──")
local ok_run, run_err = pcall(function()
    -- startDownload 的第一个参数是**数组**（波次二改的）：传单个 company 表的话，
    -- SecJob.run 会当成空数组，一家也不下，而且不会报错。
    instance:startDownload(companies)
end)
print(ok_run and "✓ 外壳 runJob 全程没有抛异常"
    or ("✗ 外壳抛异常：" .. tostring(run_err)))

print()
print(string.format("── UIManager:show 次数 %d ──", #shown_messages))

-- 产物核对：文件在不在、多大
local out = string.format("/mnt/us/documents/SEC 财报/%s SEC 财报.epub", company.name)
local size = lfs.attributes(out, "size")
print(string.format("产物：%s", out))
print(string.format("      %s 字节%s", tostring(size or 0),
    size and string.format("（%.1f MB）", size / 1048576) or "（**不存在**）"))

print("")
print("#### PLUGIN SHELL TEST DONE ####")
