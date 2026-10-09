-- Offline filesystem regression. All deletion targets are fresh host fixtures.
package.path = './secfilings.koplugin/?.lua;' .. package.path
local root = assert(arg[1], 'fresh sandbox required')
local Files = require('sec_watchlist')
local Library = require('sec_library')
local Filing = require('sec_filing')
local Lifecycle = require('sec_lifecycle')
local lfs = require('libs/libkoreader-lfs')
local n = 0
local function check(ok, name) n=n+1; assert(ok, name); print('PASS ' .. name) end
local function write(p,s) local f=assert(io.open(p,'wb')); assert(f:write(s)); assert(f:close()) end
local function exists(p) return lfs.symlinkattributes(p) ~= nil end
local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function fixture(tag,image)
    local opts={work_dir=root..'/'..tag..'/work',out_dir=root..'/'..tag..'/books'}
    local lib=Library:new(opts)
    local co={cik=320193,name='苹果'}
    local filing={accn='0000320193-26-000001',date='2026-10-01',form='10-Q'}
    assert(Files.ensureDir(opts.out_dir..'/'..Filing.companyDir(co)))
    write(Filing.outputPath(opts.out_dir,co,filing,'en'),'original')
    local book={title='Quarter',chapters={{id='one',html='<p>Revenue 10.</p>'}}}
    if image then
        local path=Filing.workPath(opts.work_dir,co,filing)..'/images'
        assert(Files.ensureDir(path)); write(path..'/chart.png','registered image')
        book.images={{href='images/chart.png',mediaType='image/png'}}
    end
    local r=assert(lib:register(co,filing,book))
    return Lifecycle:new(opts),r,opts
end
local function row(lc) local s=lc:scan(); assert(s.complete,s.error); return s.rows[1],s end
local function preview(lc,r,opts) return lc:preview({r.paths.cik..':'..r.paths.accn},opts) end
local lc,r=fixture('present')
local item=row(lc)
check(item.status=='partial' and item.original_present,'present original is not garbage')
check(not preview(lc,r), 'residual cleanup refuses a surviving book')
assert(os.remove(r.original_path)); write(r.chinese_path,'Chinese')
item=row(lc)
check(item.chinese_present and item.status=='partial' and not preview(lc,r),'Chinese-only record protects common data')
assert(os.remove(r.chinese_path)); item=row(lc)
check(item.status=='missing','both missing are pending user decision, not silently deleted')
local plan=assert(preview(lc,r))
check(exists(r.paths.source) and exists(r.paths.state) and plan.bytes>0,'preview is read-only and counts exact files')
write(r.original_path,'reappeared')
check(not lc:execute(plan) and exists(r.paths.source),'book reappearing after confirmation blocks cleanup')
assert(os.remove(r.original_path))
plan=assert(preview(lc,r)); assert(lc:execute(plan))
check(not exists(r.paths.dir),'confirmed orphan removes its snapshot, state and empty directory')
check(not lc:execute(plan),'a consumed confirmation cannot run twice')

lc,r=fixture('unknown'); assert(os.remove(r.original_path)); write(r.paths.dir..'/notes.txt','private')
check(not preview(lc,r) and exists(r.paths.dir..'/notes.txt'),'unknown user file blocks recursive cleanup')
lc,r=fixture('staging'); assert(os.rename(r.original_path,r.original_path..'.building.epub'))
check(row(lc).status=='recoverable' and not preview(lc,r),'interrupted publication is retained for recovery')
lc,r=fixture('alias'); local alias=lc.out_dir..'/Apple Inc. [CIK 0000320193]'
assert(Files.ensureDir(alias)); assert(os.rename(r.original_path,alias..'/'..r.original_path:match('[^/]+$')))
check(row(lc).status=='unknown' and not preview(lc,r),'company alias / move is not treated as deletion')
lc,r=fixture('corrupt'); write(r.paths.state,'error("must not execute")')
check(row(lc).status=='unknown' and not preview(lc,r),'corrupt metadata is never executed or erased')
lc,r=fixture('busy'); lc.is_busy=function() return true end
check(not preview(lc,r,{remove_books=true}),'busy task blocks destructive planning')
lc,r=fixture('changed'); assert(os.remove(r.original_path)); plan=assert(preview(lc,r))
write(r.paths.source,'changed')
check(not lc:execute(plan) and exists(r.paths.state),'changed snapshot invalidates confirmation')
lc,r=fixture('rootgone'); assert(os.remove(r.original_path)); plan=assert(preview(lc,r))
assert(os.rename(lc.out_dir,lc.out_dir..'-disconnected'))
check(not lc:scan().complete and not lc:execute(plan),'missing root is not an empty library')
lc,r=fixture('symbol'); assert(os.remove(r.original_path))
local sentinel=root..'/sentinel'; write(sentinel,'do not touch')
assert(os.execute('ln -s '..q(sentinel)..' '..q(r.paths.dir..'/outside'))==0)
check(not lc:scan().complete and not preview(lc,r) and exists(sentinel),'symlink is rejected without following its target')
lc,r=fixture('sidecar'); assert(os.remove(r.original_path))
assert(Files.ensureDir(r.original_path..'.sdr')); write(r.original_path..'.sdr/secfilings_progress.lua','return {}')
write(r.original_path..'.sdr/metadata.epub.lua','error("never execute")')
plan=assert(preview(lc,r)); assert(lc:execute(plan))
check(exists(r.original_path..'.sdr/metadata.epub.lua'),'reading metadata retained unless separately selected')
lc,r=fixture('sidecarremove'); assert(os.remove(r.original_path))
assert(Files.ensureDir(r.original_path..'.sdr')); write(r.original_path..'.sdr/metadata.epub.lua','error("never execute")')
plan=assert(preview(lc,r,{remove_reading_data=true})); assert(lc:execute(plan))
check(not exists(r.original_path..'.sdr'),'explicit reading-data cleanup removes only known local sidecar files')
lc,r=fixture('retry'); assert(os.remove(r.original_path)); plan=assert(preview(lc,r))
local remove=os.remove; os.remove=function(p) if p==r.paths.source then return nil,'injected' end; return remove(p) end
local ok,err,report=lc:execute(plan); os.remove=remove
check(not ok and report.removed>0 and exists(r.paths.source),'partial failure is reported and identity retained')
plan=assert(preview(lc,r)); assert(lc:execute(plan))
check(not exists(r.paths.dir),'retry after partial cleanup is idempotent')
lc,r=fixture('legacy'); assert(Files.ensureDir(lc.out_dir..'/苹果 SEC 财报.sdr'))
local old=lc.out_dir..'/苹果 SEC 财报.sdr/secfilings_progress.lua'; write(old,'error("never execute")')
local scan=lc:scan(); local legacy
for i=1,#scan.rows do if scan.rows[i].kind=='legacy' then legacy=scan.rows[i] end end
check(legacy and legacy.status=='missing','recognized legacy progress residue is visible')
plan=assert(lc:preview({legacy.id},{remove_reading_data=true})); assert(lc:execute(plan))
check(not exists(old) and exists(r.original_path),'legacy cleanup leaves current originals untouched')
lc,r=fixture('image-replaced',true); assert(os.remove(r.original_path)); write(r.book.images_dir..'/chart.png','user replacement')
check(not preview(lc,r) and exists(r.paths.source),'registered image replacement blocks cleanup before confirmation')
lc,r=fixture('empty-unknown'); assert(os.remove(r.original_path)); assert(Files.ensureDir(r.paths.dir..'/user-notes/keep'))
check(not preview(lc,r),'unknown empty directories are not assumed to be plugin garbage')
lc,r=fixture('bad-shape'); assert(os.remove(r.paths.state))
local json=require('json'); local raw=assert(Files.readFile(r.paths.source)); local data=json.decode(raw)
data.assets={123}; write(r.paths.source,json.encode(data))
check(row(lc).status=='unknown' and not preview(lc,r),'parseable source with invalid asset types blocks one row without throwing')
lc,r=fixture('dir-retry'); assert(os.remove(r.original_path)); plan=assert(preview(lc,r))
os.remove=function(p) if p==r.paths.dir then return nil,'directory failure' end; return remove(p) end
ok,err,report=lc:execute(plan); os.remove=remove
check(not ok and not exists(r.paths.source) and exists(r.paths.dir),'failure after source removal retains a directory-finishing checkpoint')
local reopened=Lifecycle:new{work_dir=lc.work_dir,out_dir=lc.out_dir}
check(row(reopened).kind=='remainder','restart recognizes empty-directory finishing without a source snapshot')
plan=assert(preview(reopened,r)); assert(reopened:execute(plan))
check(not exists(r.paths.dir),'freshly confirmed retry finishes directory removal')
lc,r=fixture('partial-journal'); assert(os.remove(r.original_path)); plan=assert(preview(lc,r))
local journal=lc.work_dir..'/.cleanup-'..r.paths.cik..'-'..r.paths.accn..'.json'
local open=io.open
io.open=function(path,mode)
    if path==journal..'.tmp' and mode=='wb' then
        local f=assert(open(path,mode)); return {write=function(self,s) f:write(s:sub(1,12)); return nil,'injected' end,close=function() return f:close() end}
    end
    return open(path,mode)
end
ok=lc:execute(plan); io.open=open
check(not ok and exists(r.paths.source) and exists(journal..'.tmp'),'partial journal write stops before deleting source')
plan=assert(preview(lc,r)); assert(lc:execute(plan))
check(not exists(r.paths.dir) and not exists(journal..'.tmp') and not exists(journal),'atomic journal retry safely consumes its reserved interrupted temporary file')
lc,r=fixture('hardlink'); assert(os.remove(r.original_path))
assert(os.execute('ln '..q(sentinel)..' '..q(r.paths.dir..'/source-copy'))==0)
check(not lc:scan().complete and exists(sentinel),'hard-linked files block cleanup')
lc,r=fixture('shared-cache'); assert(os.remove(r.original_path))
local key=string.rep('a',64); local shared=lc.work_dir..'/translation-cache'
assert(Files.ensureDir(shared)); write(shared..'/'..key..'.cache','SEC-TRANSLATION-2\n'..key..'\ncached')
plan=assert(preview(lc,r)); assert(lc:execute(plan))
check(exists(shared..'/'..key..'.cache'),'single-filing removal preserves shared translation cache')
check(not lc:preview({'shared-cache'},{}),'global cache cannot be cleared through ordinary residue action')
plan=assert(lc:preview({'shared-cache'},{remove_shared_cache=true})); assert(lc:execute(plan))
check(not exists(shared),'separately confirmed global cache cleanup removes only validated cache files')
lc,r=fixture('modified-output'); write(r.original_path,'external replacement')
check(not preview(lc,r,{remove_books=true}),'whole-filing deletion verifies original ownership hash')
lc,r=fixture('owned-output'); plan=assert(preview(lc,r,{remove_books=true})); assert(lc:execute(plan))
check(not exists(r.original_path) and not exists(r.paths.dir),'explicit whole-filing action removes verified original and its owned data')
lc,r=fixture('busy-after'); assert(os.remove(r.original_path)); plan=assert(preview(lc,r)); lc.is_busy=function() return true end
check(not lc:execute(plan) and exists(r.paths.source),'a task starting after preview invalidates cleanup')
lc,r=fixture('new-file-after'); assert(os.remove(r.original_path)); plan=assert(preview(lc,r)); write(r.paths.dir..'/notes','new')
check(not lc:execute(plan) and exists(r.paths.source),'file added after preview blocks the complete operation')
for i,target in ipairs({'company','accession'}) do
    lc,r=fixture('scan-change-'..target)
    local parent=target=='company' and lc.work_dir or r.paths.dir:match('^(.*)/[^/]+$')
    local created=parent..'/'..(target=='company' and '0000000001' or '0000320193-26-000999')
    local original_dir=lfs.dir; local reads=0
    lfs.dir=function(path)
        if path==parent then reads=reads+1; if reads==2 then assert(lfs.mkdir(created)) end end
        return original_dir(path)
    end
    local ran,result=pcall(lc.scan,lc); lfs.dir=original_dir
    check(ran and not result.complete and result.error:find('变化',1,true) and exists(r.paths.source),
        'new '..target..' during scan returns incomplete instead of throwing')
end
lc,r=fixture('oversized-journal'); assert(os.remove(r.original_path))
write(lc.work_dir..'/.cleanup-'..r.paths.cik..'-'..r.paths.accn..'.json',string.rep('x',1048577))
check(not preview(lc,r) and exists(r.paths.source),'oversized reserved journal is retained as unknown content')
lc,r=fixture('remainder-new-file'); assert(os.remove(r.original_path)); plan=assert(preview(lc,r))
os.remove=function(path) if path==r.paths.dir then return nil,'interruption' end; return remove(path) end
ok=lc:execute(plan); os.remove=remove
write(r.paths.dir..'/user-note','must survive')
check(not ok and not preview(lc,r) and exists(r.paths.dir..'/user-note'),'on-disk finishing journal cannot authorize deletion of a new user file')
print(string.format('lifecycle: %d checks passed; isolated host files only',n))
