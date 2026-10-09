-- Offline restoration/relinking: real files/JSON/hashes, no network or paid models.
package.path='./secfilings.koplugin/?.lua;'..package.path
local root=assert(arg[1],'fresh sandbox required')
local Files=require('sec_watchlist')
local Library=require('sec_library')
local Filing=require('sec_filing')
local Lifecycle=require('sec_lifecycle')
local lfs=require('libs/libkoreader-lfs')
local json=require('json')
local sha=require('ffi/sha2').sha256
local n,packed=0,0
local function check(v,s) n=n+1; assert(v,s); print('PASS '..s) end
local function put(p,s) local f=assert(io.open(p,'wb')); assert(f:write(s)); assert(f:close()) end
local function get(p) return assert(Files.readFile(p)) end
package.loaded.sec_epub={write=function(self,p,b)
    packed=packed+1; put(p,'rebuilt:'..b.title..b.chapters[1].html); return true
end}
local function setup(id)
    local lib=Library:new{work_dir=root..'/w'..id,out_dir=root..'/o'..id}
    local co={cik=320193,name='苹果'}
    local fi={accn='0000320193-26-000001',form='10-Q',date='2026-10-01'}
    assert(Files.ensureDir(lib.out_dir..'/'..Filing.companyDir(co)))
    put(Filing.outputPath(lib.out_dir,co,fi,'en'),'original:'..id)
    local p=assert(lib:paths(co.cik,fi.accn)); assert(Files.ensureDir(p.dir..'/images'))
    put(p.dir..'/images/a.png','image')
    local r=assert(lib:register(co,fi,{title=id,language='en',identifier='urn:test:'..id,
        chapters={{html='<p>Revenue 10.</p>'}},images={{href='images/a.png',mediaType='image/png'}}}))
    put(r.chinese_path,'中文:'..id)
    r.state.status='complete'; r.state.output_hash=sha('中文:'..id)
    r.state.fingerprint=lib:translator{}:fingerprint(); assert(lib:saveState(p,r.state))
    for _,b in ipairs({r.original_path,r.chinese_path}) do
        assert(Files.ensureDir(b..'.sdr')); put(b..'.sdr/metadata.epub.lua','return {page=37}')
    end
    return lib,assert(lib:load(co.cik,fi.accn))
end
local lib,r=setup('restore')
local source,state,zh=get(r.paths.source),get(r.paths.state),get(r.chinese_path)
assert(os.remove(r.original_path))
local plan=assert(lib:previewOriginalRecovery(r.paths.cik,r.paths.accn))
check(packed==0 and not lfs.attributes(r.paths.dir..'/original-recovery.json'),'recovery preview is read-only')
check(not Library:new(lib):restoreOriginal(plan),'foreign instance cannot use confirmation')
assert(lib:restoreOriginal(plan))
check(not lib:restoreOriginal(plan),'confirmation is single-use')
r=assert(lib:load(r.paths.cik,r.paths.accn))
check(lib:verify(r) and r.original_hash~=r.source.original_hash,'rebuilt original has validated independent hash')
check(get(r.paths.source)==source and get(r.paths.state)==state and get(r.chinese_path)==zh,'source, translation state and Chinese bytes preserved')
check(get(r.original_path..'.sdr/metadata.epub.lua')=='return {page=37}' and get(r.chinese_path..'.sdr/metadata.epub.lua')=='return {page=37}','both reading sidecars preserved')
local t=lib:translator{}; t.transport=function() error('must not call network') end
local out,e,reason=lib:translate(r.paths.cik,r.paths.accn,t)
check(out==r.chinese_path and reason=='reused','restoration keeps completed translation reusable')
check(not lib:previewOriginalRecovery(r.paths.cik,r.paths.accn),'existing original never overwritten')
local cleanup=assert(Lifecycle:new(lib):preview({r.paths.cik..':'..r.paths.accn},{remove_books=true,remove_reading_data=true}))
check(cleanup.books==2,'cleanup recognizes rebuilt original and recovery metadata')

local moved,mr=setup('move')
local en=mr.original_path; local candidate=moved.out_dir..'/renamed.epub'
assert(os.rename(en,candidate))
local candidates=assert(moved:findRelinkCandidates(mr.paths.cik,mr.paths.accn,'en'))
check(#candidates==1 and candidates[1]==candidate,'bounded candidate scan finds fully renamed original by hash')
local before=get(candidate)
local link=assert(moved:previewRelink(mr.paths.cik,mr.paths.accn,'en',candidate))
link.candidate='/etc/passwd' -- public display data never authorizes a different target
assert(moved:relink(link))
mr=assert(moved:load(mr.paths.cik,mr.paths.accn))
check(mr.original_path==candidate and moved:verify(mr),'linked original used by load and verification')
check(get(candidate)==before and get(en..'.sdr/metadata.epub.lua')=='return {page=37}','relink changes no book or old reading record')
check(assert(moved:list())[1].original_present,'list follows linked path')
local cp=assert(Lifecycle:new(moved):preview({mr.paths.cik..':'..mr.paths.accn},{remove_books=true}))
check(cp.books==2,'cleanup follows linked path without claiming old sidecars')
local zhpath=moved.out_dir..'/中文改名.epub'; assert(os.rename(mr.chinese_path,zhpath))
assert(moved:relink(assert(moved:previewRelink(mr.paths.cik,mr.paths.accn,'zh',zhpath))))
mr=assert(moved:load(mr.paths.cik,mr.paths.accn))
check(mr.chinese_path==zhpath,'Chinese output can be explicitly relinked')
out,e,reason=moved:translate(mr.paths.cik,mr.paths.accn,moved:translator{})
check(out==zhpath and reason=='reused','linked Chinese output is reused without translation')
put(en,'unexpected replacement')
check(not moved:load(mr.paths.cik,mr.paths.accn),'reappearing canonical path blocks ambiguous binding')

local stale,sr=setup('stale'); assert(os.remove(sr.original_path))
plan=assert(stale:previewOriginalRecovery(sr.paths.cik,sr.paths.accn))
put(sr.book.images_dir..'/a.png','changed')
check(not stale:restoreOriginal(plan) and not lfs.attributes(sr.original_path),'changed assets invalidate recovery confirmation')
local conflict,cr=setup('conflict'); local dest=conflict.out_dir..'/other.epub'
put(dest,get(cr.original_path))
check(not conflict:previewRelink(cr.paths.cik,cr.paths.accn,'en',dest),'cannot redirect a still-present original')
assert(os.remove(cr.original_path)); local pp=assert(conflict:previewRelink(cr.paths.cik,cr.paths.accn,'en',dest))
put(dest,'changed')
check(not conflict:relink(pp),'changed relink candidate invalidates confirmation')
check(not conflict:previewRelink(cr.paths.cik,cr.paths.accn,'en',root..'/outside.epub'),'out-of-library candidate refused')
put(cr.paths.dir..'/locations.json',json.encode{schema=1,source_hash=cr.state.source_hash,en='../escape.epub'})
check(not conflict:load(cr.paths.cik,cr.paths.accn),'persisted traversal rejected')

local resume,rr=setup('resume'); assert(os.remove(rr.original_path))
local rename=os.rename
os.rename=function(a,b) if b==rr.original_path then return nil,'forced publish interruption' end; return rename(a,b) end
local failed,err=resume:restoreOriginal(assert(resume:previewOriginalRecovery(rr.paths.cik,rr.paths.accn)))
os.rename=rename
check(not failed and not lfs.attributes(rr.original_path),'interrupted publication retains no false success')
local was=packed
assert(resume:restoreOriginal(assert(resume:previewOriginalRecovery(rr.paths.cik,rr.paths.accn))))
check(packed==was and resume:verify(assert(resume:load(rr.paths.cik,rr.paths.accn))),'retry publishes validated staging without repacking')

local clean,clr=setup('linked-cleanup')
local linked=clean.out_dir..'/custom.epub'; assert(os.rename(clr.original_path,linked))
assert(clean:relink(assert(clean:previewRelink(clr.paths.cik,clr.paths.accn,'en',linked))))
assert(Files.ensureDir(linked..'.sdr')); put(linked..'.sdr/metadata.epub.lua','return {}')
local lc=Lifecycle:new(clean); local id=clr.paths.cik..':'..clr.paths.accn
local removal=assert(lc:preview({id},{remove_books=true,remove_reading_data=true}))
local remove=os.remove
os.remove=function(path) if path==linked..'.sdr' then return nil,'forced directory failure' end; return remove(path) end
local done=lc:execute(removal); os.remove=remove
check(not done and lfs.attributes(clr.paths.source) and lfs.attributes(clr.paths.locations),'sidecar directory failure retains source and location receipts')
assert(lc:execute(assert(lc:preview({id},{remove_books=true,remove_reading_data=true}))))
check(not lfs.attributes(linked..'.sdr') and not lfs.attributes(clr.paths.source),'renamed sidecar cleanup can be confirmed and resumed')

local cancelled,can=setup('linked-cancel')
local newzh=cancelled.out_dir..'/translated.epub'
assert(os.rename(can.chinese_path,newzh))
assert(cancelled:relink(assert(cancelled:previewRelink(can.paths.cik,can.paths.accn,'zh',newzh))))
local oldzh=get(newzh); assert(os.remove(newzh))
local ticks=0
local translator=cancelled:translator{translation_cache_only=true}
local translated,why=cancelled:translate(can.paths.cik,can.paths.accn,translator,function() ticks=ticks+1; return ticks<2 end)
local reopened=cancelled:load(can.paths.cik,can.paths.accn)
check(not translated and reopened and reopened.state.status=='paused','cancelled retry of a missing linked Chinese book remains loadable')
translated,why=cancelled:translate(can.paths.cik,can.paths.accn,cancelled:translator{translation_cache_only=true})
check(not translated and why:find('仅缓存',1,true),'failed retry remains resumable instead of rejecting location metadata')
local oldcopy=cancelled.out_dir..'/previous-chinese.epub'; put(oldcopy,oldzh)
assert(cancelled:relink(assert(cancelled:previewRelink(can.paths.cik,can.paths.accn,'zh',oldcopy))))
check(assert(cancelled:load(can.paths.cik,can.paths.accn)).chinese_path==oldcopy,'previous Chinese identity survives attempt-state changes')
check(Lifecycle:new(cancelled):preview({can.paths.cik..':'..can.paths.accn},{remove_books=true}),'cleanup verifies the preserved Chinese identity after cancelled translation')

for _,partial in ipairs({false,true,'empty'}) do
    local failedlib,failedr=setup(partial=='empty' and 'receipt-empty' or partial and 'receipt-partial' or 'receipt-fail')
    assert(os.remove(failedr.original_path))
    local open=io.open
    io.open=function(path,mode)
        if path==failedr.paths.recovery..'.tmp' and mode=='wb' then
            if not partial then return nil,'injected open failure' end
            local file=assert(open(path,mode))
            return {write=function(self,data) if partial~='empty' then file:write(data:sub(1,12)) end; return nil,'injected short write' end,
                close=function() return file:close() end}
        end
        return open(path,mode)
    end
    local done=failedlib:restoreOriginal(assert(failedlib:previewOriginalRecovery(failedr.paths.cik,failedr.paths.accn)))
    io.open=open
    check(not done and not lfs.attributes(failedr.paths.rebuild) and not lfs.attributes(failedr.paths.recovery..'.tmp'),
        partial=='empty' and 'zero-byte receipt failure removes only the owned empty inode' or partial and 'partial receipt failure discards only this attempt scratch' or 'receipt open failure releases verified attempt scratch')
    assert(failedlib:restoreOriginal(assert(failedlib:previewOriginalRecovery(failedr.paths.cik,failedr.paths.accn))))
    check(failedlib:verify(assert(failedlib:load(failedr.paths.cik,failedr.paths.accn))), 'receipt failure can be retried after fresh confirmation')
end

local function quote(s) return "'"..s:gsub("'","'\\''").."'" end
for _,kind in ipairs({'symbolic','hard'}) do
    local linkedlib,linkedr=setup('unsafe-'..kind)
    local keep=linkedlib.out_dir..'/keep.bin'; assert(os.rename(linkedr.original_path,keep))
    local evil=linkedlib.out_dir..'/bad.epub'
    assert(os.execute('ln '..(kind=='symbolic' and '-s ' or '')..quote(keep)..' '..quote(evil))==0)
    check(not linkedlib:previewRelink(linkedr.paths.cik,linkedr.paths.accn,'en',evil) and get(keep):find('original:',1,true),kind..' candidate cannot be associated')
end
local shape,shr=setup('shape'); assert(os.remove(shr.original_path))
put(shr.paths.locations,json.encode{schema=1,source_hash=shr.state.source_hash,en={path='unexpected'}})
local ran,loaded=pcall(shape.load,shape,shr.paths.cik,shr.paths.accn)
check(ran and not loaded,'non-string saved location returns an error without throwing')
local forged,forr=setup('forged'); assert(os.remove(forr.original_path))
local permission=assert(forged:previewOriginalRecovery(forr.paths.cik,forr.paths.accn))
permission.path=root..'/sentinel'; put(root..'/sentinel','do-not-touch')
assert(forged:restoreOriginal(permission))
check(get(root..'/sentinel')=='do-not-touch' and lfs.attributes(forr.original_path),'edited public recovery plan cannot redirect writes')
local unknown,ur=setup('unknown-stage'); assert(os.remove(ur.original_path))
put(ur.paths.rebuild,'unknown user data')
check(not unknown:previewOriginalRecovery(ur.paths.cik,ur.paths.accn) and get(ur.paths.rebuild)=='unknown user data','unregistered recovery staging is preserved rather than trusted or erased')
local changed,ch=setup('after-writer'); assert(os.remove(ch.original_path))
local writer=package.loaded.sec_epub.write
package.loaded.sec_epub.write=function(self,path,book)
    local ok=writer(self,path,book); put(ch.chinese_path,'externally changed'); return ok
end
local result=changed:restoreOriginal(assert(changed:previewOriginalRecovery(ch.paths.cik,ch.paths.accn)))
package.loaded.sec_epub.write=writer
check(not result and not lfs.attributes(ch.original_path) and not lfs.attributes(ch.paths.rebuild) and get(ch.chinese_path)=='externally changed','post-writer change stops publication and discards only owned staging')

local nested,nr=setup('nested')
local folder=nested.out_dir..'/custom'; assert(Files.ensureDir(folder))
local nestedzh=folder..'/zh.epub'; assert(os.rename(nr.chinese_path,nestedzh))
assert(nested:relink(assert(nested:previewRelink(nr.paths.cik,nr.paths.accn,'zh',nestedzh))))
assert(os.remove(nestedzh)); assert(os.remove(folder))
local nt=nested:translator{deepseek_api_key='offline-fixture'}; nt.transport=function(text) return text:gsub('Revenue','营收') end
local newbook=assert(nested:translate(nr.paths.cik,nr.paths.accn,nt))
check(newbook==nestedzh and lfs.attributes(folder,'mode')=='directory','retranslation recreates a missing linked output parent before model dispatch')
local latest=get(newbook); assert(os.remove(newbook))
local calls=0
nested:translate(nr.paths.cik,nr.paths.accn,nested:translator{translation_cache_only=true},function() calls=calls+1; return calls<2 end)
local current=assert(nested:load(nr.paths.cik,nr.paths.accn))
check(current.chinese_hash==sha(latest) and current.locations.zh_hash==sha(latest),'new attempt retains the most recent rebuilt Chinese identity')

local casing,caser=setup('case-change')
local upper=casing.out_dir..'/Renamed.epub'; local lower=casing.out_dir..'/renamed.epub'
assert(os.rename(caser.original_path,upper))
assert(casing:relink(assert(casing:previewRelink(caser.paths.cik,caser.paths.accn,'en',upper))))
assert(os.rename(upper,lower)); assert(os.remove(caser.chinese_path))
local symlinkattributes=lfs.symlinkattributes
lfs.symlinkattributes=function(path,key)
    if path==upper then return symlinkattributes(lower,key) end -- explicit case-insensitive lookup adapter
    return symlinkattributes(path,key)
end
-- Some fsp volumes report success for a case-only rename without changing
-- directory spelling. Explicitly adapt enumeration as well as lookup for this case.
local original_dir=lfs.dir
lfs.dir=function(path)
    if path~=casing.out_dir then return original_dir(path) end
    local names={}; for name in original_dir(path) do
        names[#names+1]=name=='Renamed.epub' and 'renamed.epub' or name
    end
    local index=0; return function() index=index+1; return names[index] end
end
local case_lc=Lifecycle:new(casing)
local case_scan=case_lc:scan()
local case_plan=case_lc:preview({caser.paths.cik..':'..caser.paths.accn},{})
lfs.symlinkattributes=symlinkattributes; lfs.dir=original_dir
check(case_scan.complete and case_scan.rows[1].blocked and not case_plan,'case alias outside exact inventory spelling cannot be classified as removable residue')
local owner,own=setup('case-owner')
local co={cik=320193,name='苹果'}
local otherfiling={accn='0000320193-26-000002',form='10-Q',date='2026-10-01'}
local otherpath=Filing.outputPath(owner.out_dir,co,otherfiling,'en')
put(otherpath,get(own.original_path))
local owner2=assert(owner:register(co,otherfiling,{title='Other',chapters={{html='<p>Other</p>'}}}))
assert(os.remove(own.original_path))
local casecandidate=otherpath:gsub('%.epub$','.EPUB'); put(casecandidate,get(otherpath))
check(not owner:previewRelink(own.paths.cik,own.paths.accn,'en',casecandidate),'case variants of another registered book cannot be claimed')

local broken,br=setup('broken'); assert(os.remove(br.original_path))
put(br.paths.dir..'/original-recovery.json','{"schema":1,"source_hash":"wrong"}')
check(not broken:load(br.paths.cik,br.paths.accn),'damaged recovery receipt fails closed')
print('recovery/relink: '..n..' checks passed; isolated files, fake EPUB writer, no network')
