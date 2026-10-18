-- Finite per-company retry batches. No I/O here: the caller checkpoints the
-- entire watchlist before fetching bodies and after each committed original.
local W = require('sec_watchlist')
local Q = {}

local function signature(entry, opts)
    return W.serialize({forms=entry.forms, include_reports=opts.include_reports == true,
        since_date=opts.since_date})
end
local function dense(t)
    if type(t) ~= 'table' then return false end
    local size=#t
    for k in pairs(t) do
        if type(k) ~= 'number' or k < 1 or k > size or k % 1 ~= 0 then return false end
    end
    for i=1,size do if t[i]==nil then return false end end
    return true
end

-- Detect accidental edits/truncation of otherwise syntactically valid state.
-- Adler-32 is not authentication against someone able to edit settings.
local function checksum(p)
    local text=W.serialize({version=p.version,update=p.update,completed=p.completed,signature=p.signature})
    local a,b=1,0
    for i=1,#text do a=(a+text:byte(i))%65521;b=(b+a)%65521 end
    return string.format('%08x',b*65536+a)
end

function Q.validate(entry)
    local p = entry.pending_batch
    if type(p) ~= 'table' or p.version ~= 1 or type(p.update) ~= 'table'
            or type(p.signature) ~= 'string' or not dense(p.completed) then
        return nil, '未完成批次格式或版本无效；请明确重置下载记录，不能自动重新选取'
    end
    local u = p.update
    if u.cik ~= entry.cik or not dense(u.new_filings) or #u.new_filings == 0
            or #u.new_filings > 512 or u.new_count ~= #u.new_filings
            or type(u.first_run) ~= 'boolean' or not W.isValidDate(u.latest_filing)
            or type(u.truncated) ~= 'number' or u.truncated < 0 or u.truncated % 1 ~= 0
            or (u.baseline_new_date ~= nil and not W.isValidDate(u.baseline_new_date))
            or not dense(u.closing_accns) then
        return nil, '未完成批次的身份、申报或提交边界无效'
    end
    if (u.truncated==0 and u.baseline_new_date~=u.latest_filing)
            or (u.truncated>0 and u.baseline_new_date~=nil)
            or u.baseline_date~=entry.seen_upto_date then
        return nil, '未完成批次的日期边界不一致'
    end
    if p.checksum ~= checksum(p) then
        return nil, '未完成批次校验失败；保留原记录，请明确重置而非静默更换目标'
    end
    local targets, completed = {}, {}
    for _, f in ipairs(u.new_filings) do
        local norm = W.normalizeFiling(f)
        if not norm or norm.form == '' or not W.isValidDate(norm.date)
                or norm.accn ~= f.accn or targets[f.accn]
                or (f.primary ~= nil and type(f.primary) ~= 'string') then
            return nil, '未完成批次包含无效或重复申报'
        end
        targets[f.accn] = true
    end
    for _, a in ipairs(u.closing_accns) do
        if type(a) ~= 'string' or a == '' then return nil, '未完成批次收盘清单无效' end
    end
    for _, a in ipairs(p.completed) do
        if not targets[a] or completed[a] then return nil, '批次完成项不属于目标或存在重复' end
        completed[a] = true
    end
    return p, completed
end

function Q.begin(entry, update, opts)
    if entry.pending_batch ~= nil then return nil, '已有未完成批次，不能覆盖' end
    local p = {version=1, update=W.copyValue(update), completed={}, signature=signature(entry,opts)}
    p.checksum=checksum(p)
    entry.pending_batch = p
    local valid, err = Q.validate(entry)
    if not valid then entry.pending_batch=nil; return nil,err end
    return true
end

function Q.resume(entry, opts)
    local p, completed = Q.validate(entry)
    if not p then return nil,completed end
    if entry.seen_upto_date ~= p.update.baseline_date then
        return nil, '日期基线与未完成批次不同；请确认重置下载记录，不能覆盖新的边界'
    end
    if p.signature ~= signature(entry,opts) then
        return nil, '筛选条件与未完成批次不同；请恢复原筛选或确认重置下载记录（份数设置下批生效）'
    end
    local filings = {}
    for _, f in ipairs(p.update.new_filings) do
        if not completed[f.accn] then filings[#filings+1]=W.copyValue(f) end
    end
    return {filings=filings, update=W.copyValue(p.update), queued=true}
end

function Q.complete(wl, cik, accession)
    local entry = W.find(wl,cik)
    if not entry then return nil,'关注项不存在' end
    local p, completed = Q.validate(entry)
    if not p then return nil,completed end
    local found=false
    for _,f in ipairs(p.update.new_filings) do if f.accn==accession then found=true end end
    if not found then return nil,'提交项不属于当前批次' end
    if not completed[accession] then p.completed[#p.completed+1]=accession end
    local ok,err = W.markSeen(wl,cik,{accession},{})
    if not ok then return nil,err end
    if #p.completed == #p.update.new_filings then
        ok,err = W.commit(wl,p.update,{})
        if not ok then return nil,err end
        entry.pending_batch=nil
    else
        p.checksum=checksum(p)
    end
    return true
end

function Q.snapshot(wl)
    return {entries=W.cloneList(wl.entries),updated_at=wl.updated_at,
        user_modified_at=wl.user_modified_at}
end
function Q.restore(wl,snapshot)
    wl.entries=W.cloneList(snapshot.entries)
    wl.updated_at=snapshot.updated_at
    wl.user_modified_at=snapshot.user_modified_at
end
return Q
