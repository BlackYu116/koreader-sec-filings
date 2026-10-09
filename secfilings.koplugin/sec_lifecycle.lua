-- SEC-owned file lifecycle. No shell, network, Lua metadata execution or background deletion.
-- scan/preview are read-only. execute accepts only an in-memory confirmation issued here.
local lfs = require('libs/libkoreader-lfs')
local json = require('json')
local sha = require('ffi/sha2').sha256
local Library = require('sec_library')
local Lifecycle = {}
local MAX_FILES, MAX_DEPTH, MAX_HASH_BYTES = 10000, 16, 256 * 1024 * 1024
local sidecar_files = {['secfilings_progress.lua']=true, ['metadata.epub.lua']=true,
    ['metadata.epub.lua.old']=true, ['cover.jpg']=true, ['cover.png']=true}
local legacy_names = {'苹果','微软','英伟达','特斯拉','亚马逊','Meta','谷歌'}
local function inside(p, root) return p:sub(1,#root+1)==root..'/' end
local function validPath(p)
    if type(p)~='string' or p:find('[%c\\]') or p:find('//',1,true) or p:sub(-1)=='/' then return false end
    local allowed=p:match('^/mnt/us/[^/]+')
    if require('ffi').os=='OSX' then allowed=allowed or p:match('^/Users/[^/]+/[^/]+/') end
    if not allowed then return false end
    for part in p:gmatch('[^/]+') do if part=='.' or part=='..' then return false end end
    return true
end
local function safeExisting(p)
    if not validPath(p) then return nil,'路径不在允许的用户目录' end
    local prefix=''
    for part in p:gmatch('[^/]+') do
        prefix=prefix..'/'..part
        local a=lfs.symlinkattributes(prefix)
        if not a or (a.mode~='directory' and prefix~=p) or a.mode=='link' then
            return nil,'路径不可读或含符号链接'
        end
    end
    local a=lfs.symlinkattributes(p)
    if not a or (a.mode~='file' and a.mode~='directory') or a.mode=='file' and (a.nlink or 1)~=1 then
        return nil,'特殊文件或硬链接不可清理'
    end
    return a
end
local function names(path)
    -- Filesystem only: no callbacks/yields inside pcall.
    local ok, result=pcall(function()
        local out={}
        for name in lfs.dir(path) do
            if name~='.' and name~='..' then
                if name:find('[%c/\\]') then error('invalid name') end
                out[#out+1]=name
                if #out>MAX_FILES then error('limit') end
            end
        end
        table.sort(out); return out
    end)
    if not ok then return nil,'目录读取失败或超过扫描上限' end
    return result
end
local function hashFile(path)
    local f=io.open(path,'rb'); if not f then return nil,'文件不可读' end
    local h,bytes=sha(),0
    while true do
        local s,e=f:read(65536)
        if e then f:close(); return nil,'文件读取失败' end
        if not s then break end
        bytes=bytes+#s
        if bytes>MAX_HASH_BYTES then f:close(); return nil,'单文件超过清理校验上限' end
        h(s)
    end
    f:close(); return h()
end
local function readJSON(path, max)
    local f=io.open(path,'rb'); if not f then return nil end
    local s=f:read(max+1); f:close()
    if not s or #s>max then return nil end
    local ok,t=pcall(json.decode,s)
    return ok and type(t)=='table' and t or nil
end
local function accession(s) return s:match('^%d%d%d%d%d%d%d%d%d%d%-%d%d%-%d%d%d%d%d%d$') end
local function journalPath(self,cik,accn)
    return self.work_dir..'/.cleanup-'..cik..'-'..accn..'.json'
end
-- A journal can describe only empty directory finishing, never authorize file deletion.
local function recoveryDirs(self,j,cik,accn)
    if type(j)~='table' or j.schema~=1 or j.kind~='sec-cleanup' or j.id~=cik..':'..accn
            or type(j.directories)~='table' or #j.directories>MAX_FILES then return nil end
    local out={}
    for i,entry in ipairs(j.directories) do
        if type(entry)~='table' or type(entry.relative)~='string' then return nil end
        local rel=entry.relative
        local root=entry.root=='work' and self.work_dir or entry.root=='out' and self.out_dir
        if not root or not validPath(root..'/'..rel) then return nil end
        local base=cik..'/'..accn
        if entry.root=='work' then
            local tail=rel:sub(#base+2)
            if rel~=base and (not inside(rel,base) or not (tail=='images' or tail:match('^images/')
                or tail=='translation-cache' or tail:match('^attempt%-%d+%-%d+$')
                or tail:match('^attempt%-%d+%-%d+/images$') or tail:match('^attempt%-%d+%-%d+/images/'))) then return nil end
        else
            local company,leaf=rel:match('^([^/]+)/([^/]+)$')
            if not company or not company:find('[CIK '..cik..']',1,true)
                    or not leaf:find(accn,1,true) or not leaf:match('%.sdr$') then return nil end
        end
        out[root..'/'..rel]=true
    end
    return out
end
local function subtree(map, dir)
    local out={}
    for p,a in pairs(map) do if p==dir or inside(p,dir) then out[#out+1]={path=p,attr=a} end end
    table.sort(out,function(a,b) return a.path<b.path end); return out
end
function Lifecycle:new(opts)
    opts=opts or {}
    return setmetatable({work_dir=opts.work_dir or Library.default_work_dir,
        out_dir=opts.out_dir or Library.default_out_dir,
        is_busy=opts.is_busy, is_open=opts.is_open,
        issued=setmetatable({},{__mode='k'})}, {__index=self})
end
function Lifecycle:roots()
    if self.work_dir==self.out_dir or inside(self.work_dir,self.out_dir) or inside(self.out_dir,self.work_dir) then
        return nil,'工作目录与书库必须独立'
    end
    for i,p in ipairs({self.work_dir,self.out_dir}) do
        if p=='/mnt/us/documents' or p=='/mnt/us/koreader' or inside(p,'/mnt/us/koreader') then
            return nil,'不能把系统、设置或整个 documents 当作清理根目录'
        end
        local a,e=safeExisting(p)
        if not a or a.mode~='directory' then return nil,e or '受管目录不可用；未进行清理' end
    end
    return true
end
function Lifecycle:scan()
    local s={complete=false,rows={},map={},bytes={books=0,work=0,cache=0,legacy_cache=0},error=nil}
    if self.is_busy and self.is_busy() then s.error='已有 SEC 任务正在运行'; return s end
    local ok,e=self:roots(); if not ok then s.error=e; return s end
    local count=0
    local function walk(p,depth)
        if depth>MAX_DEPTH then return nil,'目录过深，扫描未完成' end
        local a=lfs.symlinkattributes(p)
        if not a or (a.mode~='file' and a.mode~='directory') or a.mode=='file' and (a.nlink or 1)~=1 then
            return nil,'扫描遇到链接、特殊文件或不可读路径'
        end
        if a.permissions and (not a.permissions:find('r',1,true) or a.mode=='directory' and not a.permissions:find('x',1,true)) then
            return nil,'目录或文件无读取权限'
        end
        count=count+1; if count>MAX_FILES then return nil,'扫描超过 10000 项，未执行清理' end
        s.map[p]=a
        if a.mode=='directory' then
            local entries,err=names(p); if not entries then return nil,err end
            for i=1,#entries do local done,why=walk(p..'/'..entries[i],depth+1); if not done then return nil,why end end
        elseif inside(p,self.out_dir) and p:match('%.epub$') then s.bytes.books=s.bytes.books+(a.size or 0)
        elseif inside(p,self.work_dir..'/translation-cache') then s.bytes.legacy_cache=s.bytes.legacy_cache+(a.size or 0)
        elseif inside(p,self.work_dir) then
            if p:find('/translation-cache/',1,true) then s.bytes.cache=s.bytes.cache+(a.size or 0)
            else s.bytes.work=s.bytes.work+(a.size or 0) end
        end
        return true
    end
    ok,e=walk(self.work_dir,0); if ok then ok,e=walk(self.out_dir,0) end
    if not ok then s.error=e; return s end
    local lib=Library:new(self)
    local companies,read_err=names(self.work_dir)
    if not companies then s.error=read_err; return s end
    local known={}
    for i=1,#companies do
        local cik=companies[i]; local dir=self.work_dir..'/'..cik
        if not s.map[dir] then s.error='目录在检查中发生变化，请重试'; return s end
        if cik:match('^%d%d%d%d%d%d%d%d%d%d$') and s.map[dir].mode=='directory' then
            local filings,why=names(dir); if not filings then s.error=why; return s end
            for j=1,#filings do
                local accn=filings[j]; local work=dir..'/'..accn
                if not s.map[work] then s.error='目录在检查中发生变化，请重试'; return s end
                if accession(accn) and s.map[work].mode=='directory' then
                    local row={id=cik..':'..accn,kind='filing',cik=cik,accn=accn,dir=work,
                        name=cik,status='unknown',blocked='资料损坏或下载未完成'}
                    local r=lib:load(cik,accn)
                    if r then
                        row.name,row.form,row.date=r.source.company.name,r.source.filing.form,r.source.filing.date
                        row.state=r.state.status
                        row.original_path,row.chinese_path=r.original_path,r.chinese_path
                        row.source_hash=r.state.source_hash
                        row.original_hash,row.output_hash=r.source.original_hash,r.state.output_hash
                        row.assets={}
                        row.images_dir=r.book.images_dir
                        for href,h in pairs(r.source.assets) do
                            row.assets[r.book.images_dir..'/'..href:sub(8)]=h
                        end
                        row.original_present=s.map[r.original_path]~=nil
                        row.chinese_present=s.map[r.chinese_path]~=nil
                        row.status=row.original_present and row.chinese_present and 'present'
                            or (row.original_present or row.chinese_present) and 'partial' or 'missing'
                        row.blocked=nil
                        for p in pairs(s.map) do
                            if inside(p,self.out_dir) and p:find(accn,1,true) and p:match('%.epub$')
                                    and p~=r.original_path and p~=r.chinese_path then
                                row.status,row.blocked='unknown','发现同一申报的移动、别名或暂存文件；请先核对'
                            end
                        end
                        for k,path in ipairs({r.original_path,r.chinese_path}) do
                            for z,suffix in ipairs({'.building.epub','.building.epub.tmp','.tmp'}) do
                                if s.map[path..suffix] then row.status,row.blocked='recoverable','有未完成发布文件，请先恢复任务' end
                            end
                        end
                        if r.state.status=='publishing' then row.status,row.blocked='recoverable','发布状态待恢复' end
                    end
                    s.rows[#s.rows+1]=row; known[row.id]=row
                end
            end
        end
    end
    -- Source is kept until all its files are removed. An external journal survives the
    -- final source deletion and permits a fresh, empty-directories-only confirmation.
    for i,name in ipairs(companies) do
        local cik,accn=name:match('^%.cleanup%-(%d+)%-(%d+%-%d+%-%d+)%.json$')
        if cik and #cik==10 and accession(accn) then
            local work=self.work_dir..'/'..cik..'/'..accn
            if not s.map[work..'/source.json'] then
                local j=readJSON(self.work_dir..'/'..name,1048576)
                local dirs=recoveryDirs(self,j,cik,accn)
                if dirs then
                    local row=known[cik..':'..accn] or {id=cik..':'..accn,cik=cik,accn=accn,dir=work}
                    if not known[row.id] then s.rows[#s.rows+1]=row end
                    row.kind,row.name,row.status,row.blocked='remainder',cik..'（清理收尾）','missing',nil
                    row.recovery_dirs=dirs
                    row.source_hash=j.source_hash
                end
            end
        end
    end
    for i=1,#legacy_names do
        local stem=self.out_dir..'/'..legacy_names[i]..' SEC 财报'
        for j,suffix in ipairs({'.sdr','.epub.sdr'}) do
            local dir=stem..suffix
            if s.map[dir] and s.map[dir].mode=='directory' then
                local present=s.map[stem..'.epub']~=nil
                s.rows[#s.rows+1]={id='legacy:'..legacy_names[i]..suffix,kind='legacy',name=legacy_names[i]..'（旧合集）',
                    dir=dir,status=present and 'present' or 'missing',original_path=stem..'.epub',original_present=present}
            end
        end
    end
    table.sort(s.rows,function(a,b) return a.id<b.id end)
    if s.map[self.work_dir..'/translation-cache'] then s.shared_cache_id='shared-cache' end
    s.complete=true
    return s
end

-- Build an immutable, private authorization snapshot. Saved journals are NEVER deletion authority.
function Lifecycle:preview(ids, opts)
    opts=opts or {}
    local s=self:scan(); if not s.complete then return nil,s.error end
    if type(ids)~='table' or #ids==0 then return nil,'没有选择清理项目' end
    local chosen={}; for i=1,#ids do chosen[ids[i]]=true end
    local p={ids={},files={},dirs={},bytes=0,books=0,rows={},opts={remove_books=opts.remove_books==true,
        remove_reading_data=opts.remove_reading_data==true,remove_shared_cache=opts.remove_shared_cache==true},guard={}}
    local seen={}
    local function add(path)
        local a=s.map[path]; if not a or seen[path] then return true end
        if a.mode~='file' then return nil,'目标不是普通文件' end
        local h,e=hashFile(path); if not h then return nil,e end
        p.files[#p.files+1]={path=path,hash=h,size=a.size or 0}
        seen[path]=true; p.bytes=p.bytes+(a.size or 0); return true
    end
    local function addTree(dir, allowed, directories)
        directories=directories or {[dir]=true}
        for i,item in ipairs(subtree(s.map,dir)) do
            if item.attr.mode=='directory' then
                if not directories[item.path] then return nil,'含未登记的目录，已保留整项资料' end
                p.dirs[item.path]=true
            elseif not allowed(item.path) then return nil,'含未知或未完成文件，已保留整项资料'
            else local ok,e=add(item.path); if not ok then return nil,e end end
        end
        return true
    end
    local function sidecar(dir, required)
        if not s.map[dir] then return true end
        if not p.opts.remove_reading_data then return not required,required and '清理旧阅读记录须明确选择包含阅读记录' or nil end
        return addTree(dir,function(path)
            return path:match('^(.*)/[^/]+$')==dir and sidecar_files[path:match('[^/]+$')]
        end)
    end
    if chosen['shared-cache'] and s.shared_cache_id then
        s.rows[#s.rows+1]={id='shared-cache',kind='cache',dir=self.work_dir..'/translation-cache',status='missing'}
    end
    for i,row in ipairs(s.rows) do
        if chosen[row.id] then
            chosen[row.id]=nil
            if row.blocked then return nil,row.blocked end
            if row.status~='missing' and not p.opts.remove_books then return nil,'原文或中文版仍在；不能当残留清理' end
            if row.kind=='legacy' and row.status~='missing' then return nil,'旧合集仍在；请先在书库删除' end
            if self.is_open and (self.is_open(row.original_path) or row.chinese_path and self.is_open(row.chinese_path)) then
                return nil,'此书正在阅读，请先关闭书籍'
            end
            p.ids[#p.ids+1]=row.id
            p.rows[#p.rows+1]={id=row.id,kind=row.kind,dir=row.dir,source_hash=row.source_hash,cik=row.cik,accn=row.accn}
            if row.kind=='filing' or row.kind=='remainder' then
                for j,suffix in ipairs({'','.tmp'}) do
                    local journal=journalPath(self,row.cik,row.accn)..suffix
                    if s.map[journal] and (s.map[journal].size or 0)>1048576 then
                        return nil,'清理记录超过插件写入上限，已保留待核对'
                    end
                    local ok,e=add(journal); if not ok then return nil,e end
                end
            end
            if row.kind=='remainder' then
                for dir in pairs(row.recovery_dirs) do
                    if s.map[dir] then
                        local ok,e=addTree(dir,function() return false end,row.recovery_dirs)
                        if not ok then return nil,e end
                    end
                end
            elseif row.kind=='cache' then
                if not p.opts.remove_shared_cache then return nil,'共享翻译缓存须单独确认清空' end
                local ok,e=addTree(row.dir,function(path)
                    local key=path:match('/([a-f0-9]+)%.cache$')
                    if path:match('^(.*)/[^/]+$')~=row.dir or not key or #key~=64 then return false end
                    local f=io.open(path,'rb'); if not f then return false end
                    local prefix=f:read(83); f:close()
                    return prefix=='SEC-TRANSLATION-2\n'..key..'\n'
                end)
                if not ok then return nil,e end
            elseif row.kind=='legacy' then
                local ok,e=sidecar(row.dir,true); if not ok then return nil,e end
            else
                local source=row.dir..'/source.json'
                local allowed={[source]=true,[row.dir..'/translation.json']=true}
                local directories={[row.dir]=true,[row.dir..'/translation-cache']=true}
                local function ancestors(path)
                    while inside(path,row.dir) do directories[path]=true; path=path:match('^(.*)/[^/]+$') end
                end
                ancestors(row.images_dir)
                for path in pairs(row.assets) do allowed[path]=true; ancestors(path:match('^(.*)/[^/]+$')) end
                local ok,e=addTree(row.dir,function(path)
                    if allowed[path] then return not row.assets[path] or hashFile(path)==row.assets[path] end
                    local key=path:match('^'..row.dir:gsub('(%W)','%%%1')..'/translation%-cache/([a-f0-9]+)%.cache$')
                    if key and #key==64 then
                        local f=io.open(path,'rb'); if not f then return false end
                        local prefix=f:read(83); f:close()
                        return prefix==('SEC-TRANSLATION-2\n'..key..'\n')
                    end
                    return false
                end,directories)
                if not ok then return nil,e end
                for j,path in ipairs({row.original_path,row.chinese_path}) do
                    if s.map[path] then
                        if not p.opts.remove_books then return nil,'仍有成品，未清理' end
                        local expected=j==1 and row.original_hash or row.output_hash
                        if not expected or hashFile(path)~=expected then return nil,'成品已变化或归属无法校验，未删除' end
                        ok,e=add(path); if not ok then return nil,e end
                        p.books=p.books+1
                    end
                    ok,e=sidecar(path..'.sdr'); if not ok then return nil,e end
                    ok,e=sidecar(path:gsub('%.epub$','')..'.sdr'); if not ok then return nil,e end
                end
            end
        end
    end
    for id in pairs(chosen) do return nil,'所选资料已变化，请重新检查' end
    -- Empty directories count as cleanup, but source records are removed last.
    table.sort(p.files,function(a,b)
        local function rank(x)
            if x.path:match('/source%.json$') then return 3 end
            if x.path:match('/cleanup%.json$') then return 2 end
            if x.path:match('/translation%.json$') then return 1 end
            return 0
        end
        local ar,br=rank(a),rank(b); return ar==br and a.path<b.path or ar<br
    end)
    -- Guard the entire managed inventory against moves, new files and root replacement.
    local paths={}; for path in pairs(s.map) do paths[#paths+1]=path end; table.sort(paths)
    for i,path in ipairs(paths) do
        local a=s.map[path]
        p.guard[#p.guard+1]=table.concat({path,a.mode,tostring(a.mode=='file' and a.size or ''),
            tostring(a.ino or ''),tostring(a.dev or ''),tostring(a.mode=='file' and a.modification or '')},'\0')
    end
    local signs={table.concat(p.guard,'\n')}
    for i,f in ipairs(p.files) do signs[#signs+1]=f.path..'\0'..f.hash end
    p.signature=sha(table.concat(signs,'\n'))
    local public={bytes=p.bytes,count=#p.ids,files=#p.files,books=p.books,remove_reading_data=p.opts.remove_reading_data}
    self.issued[public]=p
    return public
end

function Lifecycle:execute(public)
    local p=self.issued[public]; if not p then return nil,'确认已失效，请重新预览' end
    self.issued[public]=nil -- even a failed attempt needs a fresh confirmation
    local fresh,e=self:preview(p.ids,p.opts); if not fresh then return nil,e end
    local current=self.issued[fresh]; self.issued[fresh]=nil
    if current.signature~=p.signature then return nil,'资料在确认后已变化，未删除；请重新预览' end
    local report={removed=0,bytes=0,remaining=#p.files}
    local function fail(message) return nil,message,report end
    local journals,reserved={},{}
    for i,row in ipairs(p.rows) do
        if row.kind=='filing' or row.kind=='remainder' then
            local path=journalPath(self,row.cik,row.accn)
            reserved[path],reserved[path..'.tmp']=true,true
            if row.kind=='filing' then
                local directories={}
                for dir in pairs(p.dirs) do
                    if dir==row.dir or inside(dir,row.dir) then
                        directories[#directories+1]={root='work',relative=dir:sub(#self.work_dir+2)}
                    elseif inside(dir,self.out_dir) and dir:find(row.accn,1,true) then
                        directories[#directories+1]={root='out',relative=dir:sub(#self.out_dir+2)}
                    end
                end
                local data=json.encode({schema=1,kind='sec-cleanup',id=row.id,source_hash=row.source_hash,
                    directories=directories,planned_files=#p.files,manifest_hash=p.signature})
                if #data>1048576 then return fail('清理记录超过上限，请减少本次选择') end
                local ok,err=self:roots(); if not ok then return fail(err) end
                for j,target in ipairs({path,path..'.tmp'}) do
                    if lfs.symlinkattributes(target) then
                        local a=safeExisting(target)
                        if not a or a.mode~='file' then return fail('清理记录路径不安全') end
                    end
                end
                local f=io.open(path..'.tmp','wb'); if not f then return fail('无法保存清理记录；未继续删除') end
                local written=f:write(data); local closed=f:close()
                if not written or not closed or not os.rename(path..'.tmp',path) then
                    return fail('清理记录写入失败；未继续删除，可重新预览重试')
                end
                journals[path]=sha(data)
            else
                journals[path]=hashFile(path)
            end
        end
    end
    for i,file in ipairs(p.files) do
        if not reserved[file.path] then
            local ok,err=self:roots(); if not ok then return fail(err) end
            local a; a,err=safeExisting(file.path); if not a then return fail(err) end
            if hashFile(file.path)~=file.hash then return fail('文件发生变化，已停止；请重新检查') end
            if not os.remove(file.path) then return fail('部分文件删除失败，请重新检查后重试') end
            report.removed=report.removed+1; report.bytes=report.bytes+file.size
            report.remaining=report.remaining-1
        end
    end
    local dirs={}; for path in pairs(p.dirs) do dirs[#dirs+1]=path end
    table.sort(dirs,function(a,b) return #a>#b end)
    for i,path in ipairs(dirs) do
        local a=safeExisting(path)
        if a and a.mode=='directory' then
            local children=names(path)
            if not children or #children>0 or not os.remove(path) then return fail('文件已处理，部分目录未移除；未递归强删') end
        end
    end
    -- Final journals outlive identity files AND directory removal. Never execute their paths.
    for path,expected in pairs(journals) do
        if not safeExisting(path) or hashFile(path)~=expected or not os.remove(path) then
            return fail('目录已处理，清理记录仍待移除；请重新检查')
        end
        local temp=path..'.tmp'
        if lfs.symlinkattributes(temp) then
            local original
            for i,file in ipairs(p.files) do if file.path==temp then original=file end end
            if not original or not safeExisting(temp) or hashFile(temp)~=original.hash or not os.remove(temp) then
                return fail('临时清理记录已变化，未删除')
            end
        end
    end
    for i,file in ipairs(p.files) do
        if reserved[file.path] then
            report.removed=report.removed+1; report.bytes=report.bytes+file.size; report.remaining=report.remaining-1
        end
    end
    -- Company directories are removed iff now empty; the two configured roots are never removed.
    for i,row in ipairs(p.rows) do
        if row.kind=='filing' or row.kind=='remainder' then
            for j,dir in ipairs({row.dir:match('^(.*)/[^/]+$')}) do
                if safeExisting(dir) then local children=names(dir); if children and #children==0 then os.remove(dir) end end
            end
        end
    end
    return true,nil,report
end
return Lifecycle
