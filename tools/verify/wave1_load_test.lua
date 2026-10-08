--[[
在真机上验证「4 个新模块能不能被 require 到、依赖齐不齐」。

为什么必须先单独验这一步：集成之后如果插件加载失败，界面不会给你任何提示，
KOReader 只会在 crash.log 里留一行。而「require 不到」和「逻辑写错了」的
表现一模一样（插件整个不出现），所以这两个问题必须分开验。

本脚本**不发任何网络请求**，只做模块解析与 API 形状检查。

用法（设备上）:
  cd /mnt/us/koreader
  LD_LIBRARY_PATH=/mnt/us/koreader/libs:/mnt/us/koreader \
    ./luajit /mnt/us/.context-backup/wave1_load_test.lua
]]

dofile("setupkoenv.lua")

-- pluginloader 给插件目录做的事：把插件目录塞进 package.path
package.path = "plugins/secfilings.koplugin/?.lua;" .. package.path

local MODULES = {
    -- 名字              期望存在的方法（点号调用用 "."，冒号调用用 ":"）
    { "sec_source",    { "fetch", "unhideTextStyles", "stripPresentation", "recentFilings",
                         "companies" } },
    -- 注意：gather 是 sec_job 内部的局部函数，**刻意不导出**（公开面只有 ensureDir + run）。
    -- 这一点是先在真机上跑出来才发现的：一开始把 gather 写进期望，结果报 nil，
    -- 差点误判成「模块导出有问题」。
    { "sec_job",       { "run", "default_out_dir", "ensureDir" } },
    { "sec_epub",      { "write", "buildContentHtml", "buildContentOpf", "buildTocNcx" } },
    -- 波次一交付的四个
    { "sec_images",    { "run" } },
    { "sec_search",    { "resolve", "listFilings", "isAmendment", "matchesForm" } },
    { "sec_watchlist", { "load", "save", "list", "add", "remove", "toggle",
                         "planUpdates", "keepProgress", "restoreProgress" } },
    { "sec_metrics",   { "collectConcepts", "buildChapter", "summary" } },
}

local fail_count = 0
local pass_count = 0

local function check(cond, msg)
    if cond then
        pass_count = pass_count + 1
        print(string.format("  ✓ %s", msg))
    else
        fail_count = fail_count + 1
        print(string.format("  × %s", msg))
    end
end

print("══ 模块解析与 API 形状 ══")
for mi = 1, #MODULES do
    local name = MODULES[mi][1]
    local want = MODULES[mi][2]
    local ok, mod = pcall(require, name)
    if not ok then
        fail_count = fail_count + 1
        print(string.format("  × require(\"%s\") 失败: %s", name, tostring(mod)))
    else
        pass_count = pass_count + 1
        local kind = type(mod)
        print(string.format("  ✓ require(\"%s\") -> %s", name, kind))
        if kind == "table" then
            for wi = 1, #want do
                local field = want[wi]
                check(mod[field] ~= nil,
                    string.format("    %s.%s 存在（%s）", name, field, type(mod[field])))
            end
        end
    end
end

print()
print(string.format("══ 结果：通过 %d 项，失败 %d 项 ══", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("WAVE1_LOAD_OK")
