-- Persistent per-filing originals and independent translation. JSON data, no UI or SEC fetches.
-- All paths are derived; no saved absolute paths, keys, responses or executable Lua.
local Filing = require("sec_filing")
local Translate = require("sec_translate")
local Files = require("sec_watchlist")
local lfs = require("libs/libkoreader-lfs")
local json = require("json")
local sha256 = require("ffi/sha2").sha256
local Library = {}
Library.default_work_dir = "/mnt/us/secfilings-work"
Library.default_out_dir = "/mnt/us/documents/SEC 财报"
local MAX_SOURCE = 32 * 1024 * 1024
local statuses = {pending=true, translating=true, paused=true, failed=true, publishing=true, complete=true}

local function safePath(path)
    if type(path) ~= "string" or path:find("[%c\\]") then return nil end
    local allowed = path:match("^/mnt/us/[^/]+")
    if require("ffi").os == "OSX" then allowed = allowed or path:match("^/Users/[^/]+/[^/]+") end
    if not allowed or not lfs.symlinkattributes then return nil end
    local prefix = ""
    for part in path:gmatch("[^/]+") do
        if part == "." or part == ".." then return nil end
        prefix = prefix .. "/" .. part
        if lfs.symlinkattributes(prefix, "mode") == "link" then return nil end
    end
    return path
end
local function identity(cik, accn)
    local n = tonumber(cik)
    if not n or n < 1 or n > 9999999999 or n % 1 ~= 0 then return nil end
    if type(accn) ~= "string" or not accn:match("^%d%d%d%d%d%d%d%d%d%d%-%d%d%-%d%d%d%d%d%d$") then return nil end
    return string.format("%010d", n), accn
end
-- Native lfs traversal only; reject unexpected links before archiver can traverse them.
local function safeTree(dir, allowed)
    if not safePath(dir) then return nil end
    if not lfs.symlinkattributes(dir) then return true end
    local count = 0
    local function walk(path, relative, depth)
        if depth > 16 then return nil end
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                count = count + 1
                if count > 10000 then return nil end
                local child = path .. "/" .. name
                local rel = relative .. name
                local mode = lfs.symlinkattributes(child, "mode")
                if mode == "directory" then
                    if not walk(child, rel .. "/", depth + 1) then return nil end
                elseif mode ~= "file" or allowed and not allowed[rel] then return nil end
            end
        end
        return true
    end
    local ok, result = pcall(walk, dir, "", 0) -- filesystem only; never yield
    return ok and result
end
local function read(path, max)
    if not safePath(path) then return nil, "本地资料路径无效或包含符号链接" end
    if lfs.symlinkattributes(path, "mode") ~= "file" then return nil, "本地资料不是普通文件" end
    local f = io.open(path, "rb")
    if not f then return nil, "本地资料缺失或不可读" end
    local text = f:read(max + 1); f:close()
    if not text or #text > max then return nil, "本地资料超过大小上限" end
    return text
end
local function decode(text)
    local ok, data = pcall(json.decode, text) -- pure parsing; cannot yield
    if not ok or type(data) ~= "table" then return nil, "本地 JSON 资料损坏；未覆盖" end
    return data
end
local function atomic(path, data)
    if not safePath(path) or not safePath(path .. ".tmp") then return nil, "保存路径无效" end
    for i, file in ipairs({path, path .. ".tmp"}) do
        local mode = lfs.symlinkattributes(file, "mode")
        if mode and mode ~= "file" then return nil, "本地资料目标不是普通文件" end
    end
    local f = io.open(path .. ".tmp", "wb")
    if not f then return nil, "无法写入本地资料" end
    local written = f:write(data)
    local closed = f:close()
    if not written or not closed or not os.rename(path .. ".tmp", path) then
        return nil, "本地资料保存失败；已停止后续操作"
    end
    return true
end
local function hashFile(path)
    if not safePath(path) or lfs.symlinkattributes(path, "mode") ~= "file" then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local hash = sha256()
    while true do
        local chunk, err = f:read(65536)
        if err then f:close(); return nil end
        if not chunk then break end
        hash(chunk)
    end
    f:close()
    return hash()
end
local function copyFields(from, keys)
    if type(from) ~= "table" then return nil end
    local out = {}
    for i = 1, #keys do
        local key = keys[i]
        if from[key] ~= nil then
            if type(from[key]) ~= "string" then return nil end
            out[key] = from[key]
        end
    end
    return out
end
local function normalizedBook(book)
    local out = copyFields(book, {"title", "description", "language", "identifier"})
    if not out or not out.title or type(book.chapters) ~= "table" or #book.chapters < 1
            or #book.chapters > 20 then return nil end
    out.chapters, out.images = {}, {}
    for ci = 1, #book.chapters do
        local c = copyFields(book.chapters[ci], {"id", "company", "company_id", "heading", "meta", "note", "html"})
        if not c or not c.html then return nil end
        out.chapters[ci] = c
    end
    local function image(entry)
        local e = copyFields(entry, {"href", "mediaType", "id"})
        if not e or not e.href or not e.href:match("^images/[A-Za-z0-9_./%-]+$")
                or e.href:find("..", 1, true) or e.href:find("//", 1, true) then return nil end
        return e
    end
    if book.images ~= nil and type(book.images) ~= "table" then return nil end
    if #(book.images or {}) > 5000 then return nil end
    for i = 1, #(book.images or {}) do
        out.images[i] = image(book.images[i]); if not out.images[i] then return nil end
    end
    if book.cover then out.cover = image(book.cover); if not out.cover then return nil end end
    return out
end

function Library:new(opts)
    opts = opts or {}
    return setmetatable({work_dir=opts.work_dir or self.default_work_dir,
        out_dir=opts.out_dir or self.default_out_dir}, {__index=self})
end
function Library:paths(cik, accn)
    cik, accn = identity(cik, accn)
    if not cik or not safePath(self.work_dir) or not safePath(self.out_dir) then
        return nil, "CIK、登记号或用户目录无效"
    end
    local work = self.work_dir .. "/" .. cik .. "/" .. accn
    if not safePath(work) then return nil, "资料目录无效" end
    return {dir=work, source=work .. "/source.json", state=work .. "/translation.json", cik=cik, accn=accn}
end
function Library:validateTargets(company, filing)
    local p, err = self:paths(company.cik, filing.accn); if not p then return nil, err end
    for i, language in ipairs({"en", "zh"}) do
        local path = Filing.outputPath(self.out_dir, company, filing, language)
        for j, suffix in ipairs({"", ".tmp", ".building.epub", ".building.epub.tmp",
                ".building.epub.sdr", ".building.sdr"}) do
            if not safePath(path .. suffix) then return nil, "成品或临时路径包含符号链接" end
        end
    end
    if not safeTree(p.dir) then return nil, "工作资料包含链接、特殊文件或过深目录" end
    return p
end
function Library:validateRoots()
    if not safePath(self.work_dir) or not safePath(self.out_dir) then return nil, "用户目录无效" end
    return true
end
-- Each uncommitted download owns a fresh asset set. Never reuse or delete interrupted assets.
function Library:beginOriginal(company, filing)
    local p, err = self:validateTargets(company, filing); if not p then return nil, err end
    local ok; ok, err = Files.ensureDir(p.dir); if not ok then return nil, err end
    for attempt = 1, 1000 do
        local dir = p.dir .. "/attempt-" .. os.time() .. "-" .. attempt
        if not lfs.symlinkattributes(dir) and lfs.mkdir(dir) then return dir end
    end
    return nil, "无法创建本轮素材目录"
end
local function assetDirectory(p, source)
    local set = source.asset_set or ""
    if type(set) ~= "string" or set ~= "" and not set:match("^attempt%-%d+%-%d+$") then return nil end
    return p.dir .. (set ~= "" and "/" .. set or "") .. "/images"
end
function Library:translator(opts)
    opts = opts or {}
    return Translate:new{api_key=opts.deepseek_api_key, endpoint=opts.deepseek_endpoint,
        model=opts.deepseek_model, thinking=opts.deepseek_thinking, max_chars=opts.deepseek_chunk_chars,
        timeout=opts.deepseek_timeout, cache_dir=self.work_dir .. "/translation-cache",
        cache_only=opts.translation_cache_only, max_requests=opts.translation_max_requests,
        max_input_bytes=opts.translation_max_input_bytes}
end
local function validSource(s, p)
    if type(s) ~= "table" or s.schema ~= 1 or type(s.company) ~= "table" or type(s.filing) ~= "table"
            or type(s.company.name) ~= "string" or #s.company.name > 240
            or type(s.filing.form) ~= "string" or #s.filing.form > 80
            or not Files.isValidDate(s.filing.date) or type(s.assets) ~= "table"
            or type(s.original_hash) ~= "string" or #s.original_hash ~= 64 then return nil end
    local cik, accn = identity(s.company.cik, s.filing.accn)
    return cik == p.cik and accn == p.accn and assetDirectory(p, s) and normalizedBook(s.book)
end
function Library:saveState(p, state)
    return atomic(p.state, json.encode(state))
end
function Library:load(cik, accn)
    local p, err = self:paths(cik, accn); if not p then return nil, err end
    local raw; raw, err = read(p.source, MAX_SOURCE); if not raw then return nil, err end
    local source; source, err = decode(raw); if not source then return nil, err end
    local book = validSource(source, p)
    if not book then return nil, "原文快照字段无效；未覆盖" end
    local state = {schema=1, status="pending", source_hash=sha256(raw),
        company=source.company, filing=source.filing}
    if lfs.symlinkattributes(p.state) then
        local saved; saved, err = read(p.state, 65536); if not saved then return nil, err end
        saved, err = decode(saved); if not saved then return nil, err end
        if saved.schema ~= 1 or not statuses[saved.status] or saved.source_hash ~= state.source_hash then
            return nil, "翻译状态与原文快照不一致；未覆盖"
        end
        state = saved
        state.company, state.filing = source.company, source.filing
    end -- A power interruption after source.json but before state commit is recoverable.
    book.images_dir = assetDirectory(p, source)
    return {paths=p, source=source, state=state, book=book,
        original_path=Filing.outputPath(self.out_dir, source.company, source.filing, "en"),
        chinese_path=Filing.outputPath(self.out_dir, source.company, source.filing, "zh")}
end

function Library:existing(cik, accn)
    local p, err = self:paths(cik, accn); if not p then return nil, err end
    if not lfs.symlinkattributes(p.source) then return nil end
    return self:load(cik, accn)
end

function Library:register(company, filing, book, staged)
    local p, err = self:validateTargets(company, filing); if not p then return nil, err end
    if lfs.symlinkattributes(p.source) then return self:load(company.cik, filing.accn) end
    local clean = normalizedBook(book)
    if not clean then return nil, "原文快照结构无效" end
    local asset_set = ""
    if book.images_dir and book.images_dir ~= p.dir .. "/images" then
        if book.images_dir:sub(1, #p.dir + 1) ~= p.dir .. "/" then return nil, "图片目录不属于此 filing" end
        asset_set = book.images_dir:sub(#p.dir + 2):match("^(attempt%-%d+%-%d+)/images$")
        if not asset_set then return nil, "图片素材批次无效" end
    end
    local source = {schema=1, company={cik=p.cik, name=company.name},
        filing={accn=p.accn, form=filing.form, date=filing.date}, book=clean, assets={}, asset_set=asset_set}
    local original = Filing.outputPath(self.out_dir, source.company, source.filing, "en")
    source.original_hash = hashFile(staged and original .. ".building.epub" or original)
    if not validSource(source, p) then return nil, "原文未完成或元数据无效，未登记续译" end
    local images = {}; for i = 1, #clean.images do images[#images+1] = clean.images[i] end
    if clean.cover then images[#images+1] = clean.cover end
    for i = 1, #images do
        local href = images[i].href
        local hash = hashFile(assetDirectory(p, source) .. "/" .. href:sub(8))
        if not hash then return nil, "图片素材缺失，未登记续译" end
        source.assets[href] = hash
    end
    local raw = json.encode(source)
    if #raw > MAX_SOURCE then return nil, "原文快照超过 32 MiB 上限" end
    local ok; ok, err = Files.ensureDir(p.dir); if not ok then return nil, err end
    ok, err = atomic(p.source, raw); if not ok then return nil, err end
    local record; record, err = self:load(p.cik, p.accn); if not record then return nil, err end
    ok, err = self:saveState(p, record.state); if not ok then return nil, err end
    return record
end

-- Publish source snapshot BEFORE the original EPUB. No committed original without a snapshot.
function Library:publishOriginal(company, filing, book)
    local p, err = self:validateTargets(company, filing); if not p then return nil, err end
    local path = Filing.outputPath(self.out_dir, company, filing, "en")
    if lfs.symlinkattributes(path) then return nil, "已有原文，未覆盖" end
    local clean = normalizedBook(book)
    if not clean then return nil, "原文结构无效" end
    local expected = {}
    for i = 1, #clean.images do expected[clean.images[i].href:sub(8)] = true end
    if clean.cover then expected[clean.cover.href:sub(8)] = true end
    if not safeTree(book.images_dir or p.dir .. "/images", expected) then return nil, "图片目录含未登记素材或链接" end
    local ok; ok, err = Files.ensureDir(path:match("^(.*)/[^/]+$")); if not ok then return nil, err end
    local warnings
    ok, err, warnings = require("sec_epub"):write(path .. ".building.epub", book)
    if not ok then return nil, err, warnings end
    local r; r, err = self:register(company, filing, book, true); if not r then return nil, err, warnings end
    ok, err = self:recoverOriginal(r); if not ok then return nil, err, warnings end
    return r, nil, warnings
end
function Library:recoverOriginal(r)
    local p, err = self:validateTargets(r.source.company, r.source.filing)
    if not p then return nil, err end
    if lfs.symlinkattributes(r.original_path) then return self:verify(r) end
    local staged = r.original_path .. ".building.epub"
    if hashFile(staged) ~= r.source.original_hash then return nil, "原文缺失，且没有可恢复的已校验暂存文件" end
    if not os.rename(staged, r.original_path) then return nil, "原文发布未完成；再次下载可恢复，快照已保留" end
    return self:verify(r)
end

function Library:verify(record)
    if hashFile(record.original_path) ~= record.source.original_hash then
        return nil, "原文 EPUB 缺失或已变化；未发送翻译请求"
    end
    local assets = record.source.assets
    local images = {}; for i = 1, #record.book.images do images[#images+1] = record.book.images[i] end
    if record.book.cover then images[#images+1] = record.book.cover end
    for i = 1, #images do
        local href = images[i].href
        if type(assets[href]) ~= "string" or hashFile(record.book.images_dir .. "/" .. href:sub(8)) ~= assets[href] then
            return nil, "图片素材缺失或已变化；未发送翻译请求"
        end
    end
    local expected = {}
    for i = 1, #images do expected[images[i].href:sub(8)] = true end
    if not safeTree(record.book.images_dir, expected) then
        return nil, "图片目录包含未登记素材或链接；未发送翻译请求"
    end
    return true
end
function Library:estimate(cik, accn, translator, progress_cb)
    local record, err = self:load(cik, accn); if not record then return nil, err end
    local ok; ok, err = self:verify(record); if not ok then return nil, err end
    local stats; stats, err = translator:estimate(record.book.chapters, progress_cb)
    if not stats then return nil, err end
    stats.status = record.state.status
    return stats, record
end

function Library:translate(cik, accn, translator, progress_cb)
    local r, err = self:load(cik, accn); if not r then return nil, err end
    local ok; ok, err = self:validateTargets(r.source.company, r.source.filing); if not ok then return nil, err end
    ok, err = self:verify(r); if not ok then return nil, err end
    if translator.expected_source_hash and translator.expected_source_hash ~= r.state.source_hash then
        return nil, "原文快照已变化，请重新确认翻译"
    end
    local fingerprint = translator:fingerprint()
    local state = r.state
    -- Recovery also covers a crash after rename but before the final state commit.
    if lfs.symlinkattributes(r.chinese_path) then
        if (state.status == "complete" or state.status == "publishing") and state.fingerprint == fingerprint
                and state.output_hash and hashFile(r.chinese_path) == state.output_hash then
            state.status = "complete"
            ok, err = self:saveState(r.paths, state); if not ok then return nil, err end
            return r.chinese_path, nil, "reused"
        end
        return nil, "已有中文版与当前任务不一致；为保留阅读进度，未覆盖"
    end
    if progress_cb and progress_cb("正在翻译 " .. r.source.filing.form .. " " .. r.source.filing.date) == false then
        return nil, "已取消"
    end
    local cache = self.work_dir .. "/translation-cache"
    if not safePath(cache) or translator.cache_dir ~= cache then return nil, "翻译缓存目录无效" end
    ok, err = Files.ensureDir(cache); if not ok then return nil, err end
    state.status, state.fingerprint = "translating", fingerprint
    state.output_hash = nil
    ok, err = self:saveState(r.paths, state); if not ok then return nil, err end
    local function finishFailure(message)
        if message == "已取消" or message:find("上限",1,true) or message:find("仅缓存",1,true) then
            state.status = "paused"
        else state.status = "failed" end
        state.requests, state.input_bytes = translator.request_count, translator.input_bytes
        local saved, save_err = self:saveState(r.paths, state)
        return nil, saved and message or save_err
    end
    for ci = 1, #r.book.chapters do
        local translated; translated, err = translator:translateHtml(r.book.chapters[ci].html, function()
            return not progress_cb or progress_cb("正在翻译 " .. r.source.filing.form .. " " .. r.source.filing.date) ~= false
        end)
        if not translated then return finishFailure(err) end
        r.book.chapters[ci].html = translated
    end
    if progress_cb and progress_cb("正在打包中文版…") == false then return finishFailure("已取消") end
    r.book.title = r.book.title .. " · 中文"
    r.book.language = "zh-CN"
    r.book.identifier = "urn:sec:" .. r.paths.cik .. ":" .. r.paths.accn .. ":zh-CN:" .. fingerprint:sub(1, 16)
    local staging = r.chinese_path .. ".building.epub"
    if not safePath(staging) or not safePath(staging .. ".tmp") then return finishFailure("输出路径无效") end
    ok, err = require("sec_epub"):write(staging, r.book)
    if not ok then return finishFailure("中文 EPUB 打包失败") end
    state.output_hash = hashFile(staging)
    if not state.output_hash then return finishFailure("中文 EPUB 无法校验") end
    state.status = "publishing"
    ok, err = self:saveState(r.paths, state); if not ok then return nil, err end
    if lfs.symlinkattributes(r.chinese_path) or not safePath(r.chinese_path)
            or not os.rename(staging, r.chinese_path) then return nil, "中文版发布失败；已保留缓存和暂存文件" end
    state.status = "complete"
    state.requests, state.input_bytes = translator.request_count, translator.input_bytes
    ok, err = self:saveState(r.paths, state); if not ok then return nil, err end
    return r.chinese_path
end

function Library:list()
    local out, damaged = {}, 0
    if not safePath(self.work_dir) then return nil, "本地资料目录无效" end
    if not lfs.attributes(self.work_dir) then return out, 0 end
    -- Directory reads do not yield. Keep errors local, never execute record contents.
    local function names(dir)
        local ok, entries = pcall(function()
            local result = {}; for name in lfs.dir(dir) do result[#result+1] = name end
            return result
        end)
        return ok and entries or {}
    end
    for ci, cik in ipairs(names(self.work_dir)) do
        if cik:match("^%d%d%d%d%d%d%d%d%d%d$") and safePath(self.work_dir .. "/" .. cik) then
            for fi, accn in ipairs(names(self.work_dir .. "/" .. cik)) do
                if identity(cik, accn) then
                    local p = self:paths(cik, accn)
                    if p and lfs.symlinkattributes(p.source) then
                        local raw = read(p.state, 65536)
                        local summary = raw and decode(raw)
                        if not raw and not lfs.symlinkattributes(p.state) then
                            local r = self:load(cik, accn); summary = r and r.state
                        end
                        local company = type(summary) == "table" and summary.company
                        local filing = type(summary) == "table" and summary.filing
                        local valid = type(company) == "table" and type(filing) == "table"
                            and summary.schema == 1 and statuses[summary.status]
                            and type(company.name) == "string" and #company.name <= 240
                            and type(filing.form) == "string" and Files.isValidDate(filing.date)
                            and identity(company.cik, filing.accn) == cik and filing.accn == accn
                        if valid then
                            out[#out+1] = {cik=cik, accn=accn, name=company.name,
                                form=filing.form, date=filing.date, status=summary.status}
                        else damaged = damaged + 1 end
                        if #out + damaged >= 1000 then return out, damaged, true end
                    end
                end
            end
        end
    end
    table.sort(out, function(a,b) if a.date ~= b.date then return a.date > b.date end
        return a.cik .. a.accn < b.cik .. b.accn end)
    return out, damaged
end
return Library
