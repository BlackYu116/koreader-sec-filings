-- Offline durable-state regression; real JSON/files/translation, fake EPUB writer and API.
package.path = "./secfilings.koplugin/?.lua;" .. package.path
local root = assert(arg[1], "fresh isolated test directory required")
local Files = require("sec_watchlist")
local Library = require("sec_library")
local Filing = require("sec_filing")
local json = require("json")
local sha = require("ffi/sha2").sha256
local count, calls, packed = 0, 0, 0
local function check(ok,label) count=count+1; assert(ok,label); print("PASS " .. label) end
local function write(path,text) local f=assert(io.open(path,"wb")); assert(f:write(text)); assert(f:close()) end
local function read(path) return assert(Files.readFile(path)) end
package.loaded["sec_epub"] = {write=function(self,path,book)
    packed=packed+1; write(path,book.title .. book.chapters[1].html); return true
end}
local function setup(id, image)
    local opts={work_dir=root .. "/work" .. id,out_dir=root .. "/books" .. id,deepseek_api_key="offline-key"}
    local lib=Library:new(opts)
    local co={cik=320193,name="苹果"}
    local filing={form="10-Q",date="2026-10-01",accn="0000320193-26-000001"}
    local book={title="Quarterly report",chapters={{id="one",heading="Results",
        html="<p>Revenue 10.</p><p>Assets 20.</p><p>Profit 30.</p>"}},images={}}
    assert(Files.ensureDir(opts.out_dir .. "/" .. Filing.companyDir(co)))
    local original=Filing.outputPath(opts.out_dir,co,filing,"en")
    write(original,"untouched-original-" .. id)
    assert(Files.ensureDir(original .. ".sdr")); write(original .. ".sdr/progress","page=37")
    if image then
        local work=Filing.workPath(opts.work_dir,co,filing)
        assert(Files.ensureDir(work .. "/images")); write(work .. "/images/chart.png","fixture-image")
        book.images={{href="images/chart.png",mediaType="image/png"}}
    end
    local record=assert(lib:register(co,filing,book))
    local function translator(extra)
        local options={}; for k,v in pairs(opts) do options[k]=v end
        for k,v in pairs(extra or {}) do options[k]=v end
        local t=lib:translator(options)
        t.transport=function(text)
            calls=calls+1
            return text:gsub("Revenue","营收"):gsub("Assets","资产"):gsub("Profit","利润")
        end
        return t
    end
    return lib,record,translator,opts
end
local lib,r,make=setup("resume")
local stats=assert(lib:estimate(r.paths.cik,r.paths.accn,make()))
check(stats.requests==3 and calls==0 and packed==0,"preflight counts without network or output writes")
check(not read(r.paths.source):find("offline-key",1,true),"snapshot has no credential")
local path,err=lib:translate(r.paths.cik,r.paths.accn,make{translation_max_requests=1})
check(not path and err:find("上限",1,true) and calls==1,"one-request budget pauses mid-document")
check(assert(lib:load(r.paths.cik,r.paths.accn)).state.status=="paused","paused state persisted")
local reopened=Library:new{work_dir=lib.work_dir,out_dir=lib.out_dir}
local entries=assert(reopened:list())
check(#entries==1 and entries[1].status=="paused","restart finds pending original independently of watchlist")
stats=assert(reopened:estimate(r.paths.cik,r.paths.accn,make()))
check(stats.requests==2 and stats.cache_hits==1 and calls==1,"preflight sees valid saved block after restart")
local before=calls
path,err=reopened:translate(r.paths.cik,r.paths.accn,make{translation_cache_only=true,deepseek_api_key=""})
check(not path and calls==before and err:find("仅缓存",1,true),"cache-only miss never charges")
path=assert(reopened:translate(r.paths.cik,r.paths.accn,make()))
check(calls==3 and packed==1,"resume dispatches only missing blocks")
check(assert(lib:load(r.paths.cik,r.paths.accn)).state.status=="complete","complete committed after output")
check(read(r.original_path)=="untouched-original-resume" and read(r.original_path .. ".sdr/progress")=="page=37","original bytes and reading progress unchanged")
assert(Files.ensureDir(path .. ".sdr")); write(path .. ".sdr/progress","page=8")
local completed=read(path)
local again,e,reason=reopened:translate(r.paths.cik,r.paths.accn,make())
check(again==path and reason=="reused" and calls==3 and packed==1 and read(path .. ".sdr/progress")=="page=8","complete output reuse preserves Chinese reading progress")
again,e=reopened:translate(r.paths.cik,r.paths.accn,make{deepseek_model="different"})
check(not again and e:find("未覆盖",1,true) and read(path)==completed and calls==3,"model change does not silently replace completed book")
local state=json.decode(read(r.paths.state)); state.status="publishing"; write(r.paths.state,json.encode(state))
again,e,reason=reopened:translate(r.paths.cik,r.paths.accn,make())
check(again and reason=="reused" and calls==3,"rename-before-state crash recovered without calls")
write(path,"modified externally")
again,e=reopened:translate(r.paths.cik,r.paths.accn,make())
check(not again and e:find("未覆盖",1,true) and read(path)=="modified externally","external output edits not overwritten")

local cancel,cr,cmake=setup("cancel")
local ticks=0; before=calls
path,err=cancel:translate(cr.paths.cik,cr.paths.accn,cmake(),function()
    ticks=ticks+1; return ticks<4
end)
check(not path and err=="已取消" and calls==before+1,"cancel after first successful block stops dispatch")
path=assert(cancel:translate(cr.paths.cik,cr.paths.accn,cmake()))
check(calls==before+3,"cancelled translation resumes with only missing blocks")

local img,ir,imake=setup("image",true)
write(ir.paths.dir .. "/images/chart.png","changed")
before=calls; path,err=img:translate(ir.paths.cik,ir.paths.accn,imake())
check(not path and calls==before and err:find("图片",1,true),"changed image rejected before API")
local original,orr,omake=setup("original")
write(orr.original_path,"changed")
path,err=original:translate(orr.paths.cik,orr.paths.accn,omake())
check(not path and calls==before and err:find("原文",1,true),"changed original rejected before API")
local corrupt,cor,comake=setup("corrupt")
write(cor.paths.state,'os.execute("unexpected")')
path,err=corrupt:translate(cor.paths.cik,cor.paths.accn,comake())
check(not path and err:find("JSON",1,true),"non-JSON state is never executed or overwritten")
local bad,damaged=corrupt:list()
check(#bad==0 and damaged==1,"damaged record count visible")
local orphan,orp,ormake=setup("orphan")
assert(os.rename(orp.paths.state,orp.paths.state .. ".fixture-backup"))
path=assert(orphan:translate(orp.paths.cik,orp.paths.accn,ormake()))
check(path and assert(orphan:load(orp.paths.cik,orp.paths.accn)).state.status=="complete","source committed before missing state recovers")
local stale,sr,smake=setup("stale")
local t=smake(); t.expected_source_hash=string.rep("a",64); before=calls
path,err=stale:translate(sr.paths.cik,sr.paths.accn,t)
check(not path and err:find("重新确认",1,true) and calls==before,"confirmation invalidated by different source fingerprint")
check(not lib:paths("../123",r.paths.accn) and not lib:paths(320193,"../../outside"),"identity traversal refused")
check(not Library:new{work_dir="/etc/sec",out_dir=root}:paths(320193,r.paths.accn),"rootfs refused")
local sym=root .. "/linked"
local function q(s) return "'" .. s:gsub("'","'\\''") .. "'" end
assert(os.execute("ln -s " .. q(lib.work_dir) .. " " .. q(sym))==0)
check(not Library:new{work_dir=sym,out_dir=lib.out_dir}:paths(320193,r.paths.accn),"symlink work root refused")
local fail,fr,fmake=setup("pack-fail")
local packer=package.loaded["sec_epub"].write
package.loaded["sec_epub"].write=function() return nil,"forced" end
path,err=fail:translate(fr.paths.cik,fr.paths.accn,fmake())
check(not path and assert(fail:load(fr.paths.cik,fr.paths.accn)).state.status=="failed" and not Files.fileExists(fr.chinese_path),"packer failure never marks complete or publishes")
package.loaded["sec_epub"].write=packer
before=calls; path=assert(fail:translate(fr.paths.cik,fr.paths.accn,fmake{translation_cache_only=true,deepseek_api_key=""}))
check(path and calls==before,"packaging retry uses caches without key")
-- Cache-file symlinks must be refused before dispatch or truncating the target.
local attack,ar,amake=setup("cache-link")
assert(attack:translate(ar.paths.cik,ar.paths.accn,amake()))
local cache_file
local lfs=require("libs/libkoreader-lfs")
for name in lfs.dir(ar.paths.dir .. "/translation-cache") do
    if name:match("%.cache$") then cache_file=ar.paths.dir .. "/translation-cache/" .. name; break end
end
local sentinel=root .. "/sentinel.txt"; write(sentinel,"must-not-change")
assert(os.rename(cache_file,cache_file .. ".backup"))
assert(os.execute("ln -s " .. q(sentinel) .. " " .. q(cache_file .. ".tmp"))==0)
before=calls
local estimated, estimate_error=attack:estimate(ar.paths.cik,ar.paths.accn,amake())
check(not estimated and estimate_error:find("链接",1,true) and calls==before and read(sentinel)=="must-not-change","cache temporary symlink blocked before request or truncation")

-- Original publication is now a recoverable transaction: snapshot first, rename second.
local pub=Library:new{work_dir=root .. "/publish-work",out_dir=root .. "/publish-books"}
local co={cik=320193,name="苹果"}; local filing={form="10-Q",date="2026-10-01",accn="0000320193-26-000002"}
local book={title="Prepared",chapters={{id="one",heading="Results",html="<p>Revenue 10.</p>"}}}
local output=Filing.outputPath(pub.out_dir,co,filing,"en")
local rename=os.rename
os.rename=function(from,to) if to==output then return nil,"simulated interruption" end; return rename(from,to) end
local pending,publish_error=pub:publishOriginal(co,filing,book)
os.rename=rename
check(not pending and not Files.fileExists(output) and Files.fileExists(output .. ".building.epub"),"publication interruption never leaves original without snapshot")
local recovered=assert(pub:existing(co.cik,filing.accn)); local pack_count=packed
assert(pub:recoverOriginal(recovered))
check(Files.fileExists(output) and packed==pack_count,"original publication resumes from committed snapshot without repacking")
assert(Files.ensureDir(output .. ".sdr")); write(output .. ".sdr/progress","page=9")
assert(pub:recoverOriginal(recovered))
check(read(output .. ".sdr/progress")=="page=9","recovery is idempotent and preserves original progress")
local linked=Library:new{work_dir=root .. "/safe-work",out_dir=root .. "/unsafe-books"}
assert(Files.ensureDir(linked.out_dir))
assert(os.execute("ln -s " .. q(pub.out_dir) .. " " .. q(linked.out_dir .. "/" .. Filing.companyDir(co)))==0)
check(not linked:validateTargets(co,filing),"company output symlink refused before file operations")
-- Upgrade: previous global cache is read-only during estimate and copied only at execution.
local migrated,mr,mmake=setup("legacy-cache")
assert(migrated:translate(mr.paths.cik,mr.paths.accn,mmake()))
assert(os.remove(mr.chinese_path))
local scoped=mr.paths.dir .. "/translation-cache"
local shared=migrated.work_dir .. "/translation-cache"
assert(os.rename(scoped,shared))
before=calls
stats=assert(migrated:estimate(mr.paths.cik,mr.paths.accn,mmake()))
check(stats.requests==0 and stats.cache_hits==3 and not Files.fileExists(scoped) and calls==before,"old shared cache preflight is read-only and free")
assert(migrated:translate(mr.paths.cik,mr.paths.accn,mmake{translation_cache_only=true,deepseek_api_key=""}))
check(Files.fileExists(shared) and Files.fileExists(scoped) and calls==before,"execution copies validated legacy hits into filing-owned cache without deleting global cache")
local co2={cik=320193,name="苹果"}
local fi2={form="10-Q",date="2026-10-02",accn="0000320193-26-000009"}
write(Filing.outputPath(migrated.out_dir,co2,fi2,"en"),"other original")
local second=assert(migrated:register(co2,fi2,{title="Other",chapters={{id="one",html="<p>Revenue 10.</p>"}}}))
local mt=mmake{translation_cache_only=true,deepseek_api_key=""}
assert(migrated:translate(second.paths.cik,second.paths.accn,mt))
check(mt.cache_dir==second.paths.dir .. "/translation-cache" and mt.cache_dir~=scoped and calls==before,"two filings independently own reused legacy blocks")
local lifecycle=require("sec_lifecycle"):new{work_dir=migrated.work_dir,out_dir=migrated.out_dir}
local deletion=assert(lifecycle:preview({mr.paths.cik .. ":" .. mr.paths.accn},{remove_books=true}))
assert(lifecycle:execute(deletion))
check(not Files.fileExists(scoped) and Files.fileExists(mt.cache_dir) and Files.fileExists(second.chinese_path)
    and Files.fileExists(shared) and calls==before,"deleting one completed filing leaves another filing and legacy shared cache intact")
print(string.format("library: %d checks passed; API and EPUB writer are offline spies",count))
