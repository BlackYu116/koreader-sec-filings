-- Explicit local repair. No network, shell, book moves or executable metadata.
-- Source and translation state remain immutable during repair; receipts bind to source_hash.
local lfs=require('libs/libkoreader-lfs')
local json=require('json')
local sha=require('ffi/sha2').sha256
local Files=require('sec_watchlist')
local Repair={}
local issued=setmetatable({},{__mode='k'})
local H
local function hex(s) return type(s)=='string' and #s==64 and s:match('^[a-f0-9]+$') end
local function inside(p,root) return type(p)=='string' and p:sub(1,#root+1)==root..'/' end
local function relative(s)
    if type(s)~='string' or #s==0 or #s>1024 or s:sub(1,1)=='/' or s:find('[%c\\]')
            or s:find('//',1,true) or not s:lower():match('%.epub$')
            or s:find('.building.',1,true) then return nil end
    for part in s:gmatch('[^/]+') do if part=='.' or part=='..' or part:match('%.sdr$') then return nil end end
    return true
end
local function keys(t,allowed)
    for k in pairs(t) do if not allowed[k] then return nil end end
    return true
end
local function metadata(path)
    if not lfs.symlinkattributes(path) then return nil,nil end
    local raw,e=H.read(path,16384); if not raw then return nil,e end
    local t; t,e=H.decode(raw); if not t then return nil,e end
    return t,nil
end
local function atomic(path,t)
    local tmp=path..'.tmp'
    if not H.safePath(path) or not H.safePath(tmp) then return nil,'保存路径无效' end
    if lfs.symlinkattributes(tmp) then return nil,'存在未完成的资料保存文件；未覆盖' end
    local mode=lfs.symlinkattributes(path,'mode')
    if mode and mode~='file' then return nil,'保存目标不是普通文件' end
    local data=json.encode(t)
    local file=io.open(tmp,'wb'); if not file then return nil,'无法保存本地记录，请重试' end
    local owned=lfs.symlinkattributes(tmp)
    local wr,written=pcall(file.write,file,data) -- synchronous file operations only
    local cl,closed=pcall(file.close,file)
    if wr and written and cl and closed and os.rename(tmp,path) then return true end
    -- Only discard this call's unchanged inode and verified partial payload.
    -- Unknown/replaced files, including links, are retained for manual inspection.
    local current=lfs.symlinkattributes(tmp)
    if owned and owned.ino and owned.dev and current and current.ino==owned.ino and current.dev==owned.dev then
        local raw=H.read(tmp,16384)
        -- read(n) returns nil at EOF for an empty file. A successful SHA read
        -- distinguishes our empty inode from an unreadable file or I/O error.
        if not raw and current.size==0 and H.hashFile(tmp)==sha('') then raw='' end
        if raw and data:sub(1,#raw)==raw then os.remove(tmp) end
    end
    return nil,'本地记录保存失败；未继续操作，请重新检查'
end
function Repair.apply(lib,r)
    r.original_hash=r.source.original_hash
    r.chinese_hash=hex(r.state.output_hash) and r.state.output_hash or nil
    r.default_original_path,r.default_chinese_path=r.original_path,r.chinese_path
    r.paths.recovery=r.paths.dir..'/original-recovery.json'
    r.paths.locations=r.paths.dir..'/locations.json'
    r.paths.rebuild=r.paths.dir..'/original-rebuild.epub'
    local t,e=metadata(r.paths.recovery); if e then return nil,e end
    if t then
        if t.schema~=1 or t.source_hash~=r.state.source_hash or not hex(t.output_hash)
                or not keys(t,{schema=true,source_hash=true,output_hash=true}) then return nil,'原文恢复记录无效；未覆盖' end
        r.original_hash=t.output_hash
    end
    r.recovery=t
    t,e=metadata(r.paths.locations); if e then return nil,e end
    if t then
        if t.schema~=1 or t.source_hash~=r.state.source_hash or not (t.en or t.zh)
                or not keys(t,{schema=true,source_hash=true,en=true,zh=true,zh_hash=true})
                or t.zh_hash~=nil and not t.zh then return nil,'文件位置记录无效；未覆盖' end
        for _,lang in ipairs({'en','zh'}) do
            if t[lang]~=nil then
                local field=lang=='en' and 'original_path' or 'chinese_path'
                if not relative(t[lang]) then return nil,'关联路径无效' end
                local path=lib.out_dir..'/'..t[lang]
                if not H.safePath(path) then return nil,'关联路径超出书库或包含链接' end
                if path~=r[field] and lfs.symlinkattributes(r[field]) then return nil,'原位置重新出现文件，请核对后再关联' end
                if lang=='zh' then
                    if not hex(t.zh_hash) then return nil,'中文版缺少持久校验值' end
                    r.chinese_hash=r.chinese_hash or t.zh_hash
                end
                r[field]=path
            end
        end
        if r.original_path==r.chinese_path then return nil,'两种语言不能关联到同一文件' end
    end
    r.locations=t
    return r
end
local function roots(lib)
    if lib.out_dir==lib.work_dir or inside(lib.out_dir,lib.work_dir) or inside(lib.work_dir,lib.out_dir)
            or lib.out_dir=='/mnt/us/documents' or lib.out_dir=='/mnt/us/koreader'
            or inside(lib.out_dir,'/mnt/us/koreader') then return nil,'受管书库与工作目录必须独立' end
    for _,p in ipairs({lib.out_dir,lib.work_dir}) do
        if p=='/mnt/us/documents' or p=='/mnt/us/koreader' or inside(p,'/mnt/us/koreader') then
            return nil,'不能使用系统、设置或整个 documents 作为受管目录'
        end
        if not H.safePath(p) or lfs.symlinkattributes(p,'mode')~='directory' then return nil,'受管目录不可用，未恢复或关联' end
    end
    return true
end
local function fingerprint(r,without_rebuild)
    local out={r.state.source_hash,r.original_path,r.chinese_path,r.original_hash}
    for _,path in ipairs({r.paths.state,r.paths.locations,r.paths.recovery,r.paths.rebuild,
            r.original_path,r.chinese_path,r.original_path..'.building.epub'}) do
        local a=lfs.symlinkattributes(path)
        local h=a and H.hashFile(path)
        if a and not h then return nil,'相关文件不可校验' end
        if not without_rebuild or path~=r.paths.rebuild then
            out[#out+1]=path; out[#out+1]=h or 'missing'
        end
    end
    return sha(json.encode(out))
end
local function record(lib,cik,accn)
    local ok,e=roots(lib); if not ok then return nil,e end
    local r; r,e=lib:load(cik,accn); if not r then return nil,e end
    ok,e=lib:validateTargets(r.source.company,r.source.filing); if not ok then return nil,e end
    for _,p in ipairs({r.original_path,r.chinese_path,r.paths.rebuild,r.paths.recovery,r.paths.locations}) do
        if not H.safePath(p) or not H.safePath(p..'.tmp') then return nil,'目标路径无效或包含链接' end
        if lfs.symlinkattributes(p..'.tmp') then return nil,'存在未完成的临时文件，请先核对' end
    end
    return r
end
local function inspectRecovery(lib,cik,accn)
    local r,e=record(lib,cik,accn); if not r then return nil,e end
    if lfs.symlinkattributes(r.original_path) then return nil,'原文仍在原位置，未覆盖' end
    local ok; ok,e=lib:verifyAssets(r); if not ok then return nil,e end
    local staging=r.original_path..'.building.epub'
    local mode='build'
    if lfs.symlinkattributes(staging) then
        if H.hashFile(staging)~=r.original_hash then return nil,'已有未知原文暂存文件，未覆盖' end
        mode='publish'; r.repair_staging=staging
    elseif lfs.symlinkattributes(r.paths.rebuild) then
        if not r.recovery or H.hashFile(r.paths.rebuild)~=r.original_hash then return nil,'已有未登记的恢复成品，未覆盖' end
        mode='publish'; r.repair_staging=r.paths.rebuild
    end
    if lfs.symlinkattributes(r.paths.rebuild..'.tmp') then return nil,'原文打包中断，临时文件已保留' end
    local sig; sig,e=fingerprint(r); if not sig then return nil,e end
    return {record=r,signature=sig,guard=fingerprint(r,true),mode=mode}
end
local function consume(lib,plan,kind)
    local p=issued[plan]
    if not p or p.owner~=lib or p.kind~=kind then return nil,'请重新预览并确认操作' end
    issued[plan]=nil; return p
end
function Repair:previewOriginalRecovery(cik,accn)
    local info,e=inspectRecovery(self,cik,accn); if not info then return nil,e end
    local plan={kind='original-recovery',path=info.record.original_path,mode=info.mode}
    issued[plan]={owner=self,kind='recovery',cik=cik,accn=accn,signature=info.signature}
    return plan
end
function Repair:restoreOriginal(plan)
    local p,e=consume(self,plan,'recovery'); if not p then return nil,e end
    local info; info,e=inspectRecovery(self,p.cik,p.accn); if not info then return nil,e end
    if info.signature~=p.signature then return nil,'资料已变化，请重新确认恢复' end
    local r=info.record
    local ok; ok,e=Files.ensureDir(r.original_path:match('^(.*)/[^/]+$')); if not ok then return nil,e end
    if info.mode=='build' then
        -- EPUB writer and file operations are synchronous; this function never yields.
        ok,e=require('sec_epub'):write(r.paths.rebuild,r.book)
        if not ok then return nil,e or '原文打包失败，资料已保留' end
        local hash=H.hashFile(r.paths.rebuild); if not hash then return nil,'恢复成品无法校验，未发布' end
        -- Recheck after the writer; an external change must not become publication authority.
        local function stop(message)
            -- The stage was absent at confirmation and created by this call. On an
            -- ordinary error discard it only if its content and path are unchanged.
            if roots(self) and H.hashFile(r.paths.rebuild)==hash then os.remove(r.paths.rebuild) end
            return nil,message
        end
        local current; current,e=record(self,p.cik,p.accn); if not current then return stop(e) end
        if fingerprint(current,true)~=info.guard or current.original_path~=r.original_path
                or lfs.symlinkattributes(r.original_path) then return stop('资料或目标变化，未发布原文') end
        ok,e=self:verifyAssets(current); if not ok then return stop(e) end
        ok,e=atomic(r.paths.recovery,{schema=1,source_hash=r.state.source_hash,output_hash=hash})
        if not ok then return stop(e) end
        r.repair_staging=r.paths.rebuild
    end
    local fresh; fresh,e=self:load(p.cik,p.accn); if not fresh then return nil,e end
    if fresh.original_path~=r.original_path or not H.safePath(r.original_path)
            or lfs.symlinkattributes(r.original_path) then return nil,'目标已变化，未覆盖' end
    if H.hashFile(r.repair_staging)~=fresh.original_hash then return nil,'暂存成品校验失败，未发布' end
    if not os.rename(r.repair_staging,r.original_path) then return nil,'原文发布中断，请重新确认恢复；暂存已保留' end
    return self:verify(fresh)
end
local function aliases(a,b)
    if a:lower()==b:lower() then return true end -- conservative on case-sensitive volumes too
    local aa,bb=lfs.symlinkattributes(a),lfs.symlinkattributes(b)
    return aa and bb and aa.ino and aa.ino~=0 and aa.dev and aa.ino==bb.ino and aa.dev==bb.dev
end
local function inspectRelink(lib,cik,accn,lang,candidate)
    if lang~='en' and lang~='zh' then return nil,'语言无效' end
    local r,e=record(lib,cik,accn); if not r then return nil,e end
    if lfs.symlinkattributes(r.paths.rebuild) or lfs.symlinkattributes(r.original_path..'.building.epub')
            or lfs.symlinkattributes(r.chinese_path..'.building.epub') then return nil,'请先处理未完成的发布任务' end
    local old=lang=='en' and r.original_path or r.chinese_path
    local other=lang=='en' and r.chinese_path or r.original_path
    if lfs.symlinkattributes(old) then return nil,'当前关联文件仍存在，未改变位置' end
    if not inside(candidate,lib.out_dir) or not relative(candidate:sub(#lib.out_dir+2))
            or not H.safePath(candidate) or aliases(candidate,other) then return nil,'候选必须是 SEC 书库内独立的 EPUB' end
    local expected=lang=='en' and r.original_hash or r.chinese_hash
    if not hex(expected) or H.hashFile(candidate)~=expected then return nil,'文件内容与登记成品不一致，不能关联' end
    local entries,damaged,truncated=lib:list()
    if not entries or damaged~=0 or truncated then return nil,'资料列表不完整，无法确认候选归属' end
    for _,entry in ipairs(entries) do
        if entry.cik~=r.paths.cik or entry.accn~=r.paths.accn then
            local other_record=lib:load(entry.cik,entry.accn)
            if not other_record then return nil,'其他资料无法验证，未关联' end
            if aliases(candidate,other_record.original_path) or aliases(candidate,other_record.chinese_path) then return nil,'文件已属于其他资料' end
        end
    end
    local sig; sig,e=fingerprint(r); if not sig then return nil,e end
    return {record=r,signature=sha(sig..candidate..expected),relative=candidate:sub(#lib.out_dir+2)}
end
function Repair:previewRelink(cik,accn,lang,candidate)
    local info,e=inspectRelink(self,cik,accn,lang,candidate); if not info then return nil,e end
    local plan={kind='relink',candidate=candidate,relative=info.relative,language=lang}
    issued[plan]={owner=self,kind='relink',cik=cik,accn=accn,lang=lang,candidate=candidate,signature=info.signature}
    return plan
end
function Repair:relink(plan)
    local p,e=consume(self,plan,'relink'); if not p then return nil,e end
    local info; info,e=inspectRelink(self,p.cik,p.accn,p.lang,p.candidate); if not info then return nil,e end
    if info.signature~=p.signature then return nil,'资料已变化，请重新确认关联' end
    local r=info.record
    local t=r.locations or {schema=1,source_hash=r.state.source_hash}
    t[p.lang]=info.relative
    if p.lang=='zh' then t.zh_hash=r.chinese_hash end
    return atomic(r.paths.locations,t)
end
-- Retain the last known linked output identity before a new translation attempt
-- clears its transient output_hash. A cancelled/failed attempt must stay loadable.
function Repair:rememberChineseIdentity(r)
    if not r.locations or not r.locations.zh or not hex(r.state.output_hash)
            or r.locations.zh_hash==r.state.output_hash then return true end
    local t=r.locations; t.zh_hash=r.state.output_hash
    return atomic(r.paths.locations,t)
end
function Repair:findRelinkCandidates(cik,accn,lang)
    local r,e=record(self,cik,accn); if not r then return nil,e end
    if lang~='en' and lang~='zh' then return nil,'语言无效' end
    local old=lang=='en' and r.original_path or r.chinese_path
    if lfs.symlinkattributes(old) then return nil,'当前文件仍存在，不需要重新关联' end
    local expected=lang=='en' and r.original_hash or r.chinese_hash
    if not hex(expected) then return nil,'没有可信的成品校验值，无法自动寻找' end
    local found,count={},0
    local function walk(dir,depth)
        if depth>16 then return nil,'书库目录过深' end
        local ok,entries=pcall(function() local t={}; for name in lfs.dir(dir) do
            if name~='.' and name~='..' then t[#t+1]=name; if #t>10000 then error('limit') end end
        end; return t end) -- directory listing only, no yielding callback
        if not ok then return nil,'书库无法读取' end
        table.sort(entries)
        for _,name in ipairs(entries) do
            count=count+1; if count>10000 then return nil,'书库超过扫描上限' end
            local path=dir..'/'..name
            if not H.safePath(path) then return nil,'书库含链接或无效路径，已停止寻找' end
            local a=lfs.symlinkattributes(path)
            if not a then return nil,'书库在检查中变化' end
            if a.mode=='directory' and not name:match('%.sdr$') then
                local good,err=walk(path,depth+1); if not good then return nil,err end
            elseif a.mode=='file' and relative(path:sub(#self.out_dir+2)) and H.hashFile(path)==expected then
                found[#found+1]=path; if #found>20 then return nil,'相同文件过多，请先人工核对书库' end
            elseif a.mode~='directory' and a.mode~='file' then return nil,'书库含特殊文件，已停止寻找' end
        end
        return true
    end
    local ok; ok,e=walk(self.out_dir,0); if not ok then return nil,e end
    return found
end
function Repair.install(Library,helpers)
    H=helpers
    for _,name in ipairs({'previewOriginalRecovery','restoreOriginal','previewRelink','relink','findRelinkCandidates','rememberChineseIdentity'}) do
        Library[name]=Repair[name]
    end
end
return Repair
