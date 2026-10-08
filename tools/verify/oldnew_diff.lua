--[[
独立复现「波次二改动没有丢数据」这个结论（不引用 F2 自己的自证）。

做法：把波次二**前**的 sec_source.lua（从设备上取回，63,621 字节）与波次二后的
版本放在同一个输入上跑，并把新版的可用宽度强制设回旧默认 30、并打开 drop_images，
使两个版本在「拆表预算」与「图片处理」上行为一致。于是两者的输出**除新增的
class="secsum" 外应当逐字节相同**；任何一格数据丢失都会在这里露出来。

顺带做一次与实现无关的交叉检查：把两边输出剥掉标签后，比较「数字 token 的多重集」。
这一条不依赖标签结构，只问「数字还在不在」。

用法：luajit work/oldnew_diff.lua <真实SEC原文.htm> [...]
]]
require("work.stub_env")

local function loadVersion(name, path)
    local chunk, err = loadfile(path)
    assert(chunk, err)
    local mod = chunk()
    return mod
end

local new = require("sec_source")
local old = loadVersion("old", "work/sec_source_old.lua")

-- 与旧版对齐：预算 30、删图
new.table_avail_em = 30
new.drop_images = true

local function stripTags(s)
    s = s:gsub("<[^>]*>", " ")
    s = s:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&#160;", " ")
    s = s:gsub("%s+", " ")
    return s:match("^%s*(.-)%s*$") or ""
end

local function numbers(s)
    local t = {}
    for n in s:gmatch("[%d][%d,%.%-]*%d") do t[#t + 1] = n end
    return t
end

local function multisetEqual(a, b)
    if #a ~= #b then return false, #a .. " vs " .. #b end
    table.sort(a); table.sort(b)
    for i = 1, #a do if a[i] ~= b[i] then return false, i .. ": " .. a[i] .. " vs " .. b[i] end end
    return true
end

local total_fail = 0
for ai = 1, #arg do
    local f = assert(io.open(arg[ai], "rb")); local raw = f:read("*a"); f:close()
    local o1 = old:cleanHtml(raw)
    local n1 = new:cleanHtml(raw)
    local t1, t2 = stripTags(o1), stripTags(n1)
    local ok_bytes = (o1 == n1)
    local ok_text  = (t1 == t2)
    local ok_nums, num_msg = multisetEqual(numbers(t1), numbers(t2))
    local name = arg[ai]:match("[^/]+$")
    print(string.format("%-30s 字节相同 %-5s 文本相同 %-5s 数字集相同 %-5s %s",
        name, tostring(ok_bytes), tostring(ok_text), tostring(ok_nums),
        ok_nums and "" or ("<< " .. tostring(num_msg))))
    if not ok_nums then total_fail = total_fail + 1 end
    if not ok_bytes then
        print(string.format("    （字节不同：旧 %d / 新 %d 字节，差 %+d）", #o1, #n1, #n1 - #o1))
    end
end
print(total_fail == 0 and "OLDNEW_OK" or ("OLDNEW_FAIL " .. total_fail))
