-- Real Job/Watchlist/Queue with explicitly in-memory Library and I/O spies.
-- Tests restart/commit sequencing, NOT native files, network or EPUBs.
package.path='./secfilings.koplugin/?.lua;'..package.path
local W=require('sec_watchlist')
W.ensureDir=function() return true end;W.fileExists=function() return false end;W.fileSize=function() return 1 end
package.loaded.logger={info=function() end,warn=function() end}
package.loaded.sec_epub={};package.loaded.sec_images={};package.loaded.sec_metrics={}
local source={}
package.loaded.sec_source=source
local records,body_calls,metadata_calls,publishes,fail_body,fail_publish,metadata_error,metadata
local all={}
for i=1,12 do all[i]={accn=string.format('0001318605-26-%06d',13-i),form='8-K',date=string.format('2026-10-%02d',13-i),primary='f.htm'} end
function source:recentFilings() metadata_calls=metadata_calls+1;if metadata_error then return nil,'metadata offline' end;return metadata end
function source:filingContent(cik,f)
 body_calls=body_calls+1;if fail_body and fail_body[f.accn] then return nil,'body failed' end
 return {html='<p>'..string.rep('Revenue 10. ',30)..'</p>',url='https://www.sec.gov/fixture'}
end
function source:cleanHtml(html) return html,{images=0} end
local L={}
function L:new() return setmetatable({},{__index=self}) end
function L:validateRoots() return true end
function L:validateTargets() return true end
function L:existing(cik,a) return records[a] end
function L:recoverOriginal() return true end
function L:beginOriginal() return '/in-memory' end
function L:publishOriginal(c,f,book)
 if fail_publish then return nil,'publish failed' end
 publishes=publishes+1
 local r={source={company=c,filing=f},paths={cik=c.cik,accn=f.accn},original_path='/in-memory/'..f.accn,book=book}
 records[f.accn]=r;return r
end
package.loaded.sec_library=L
local Job=require('sec_job')
local companies={{cik=1318605,name='Fixture'}}
local n=0
local function check(ok,label) n=n+1;assert(ok,label);print('PASS '..label) end
local function fresh()
 records={};body_calls=0;metadata_calls=0;publishes=0;fail_body=nil;fail_publish=nil;metadata_error=false;metadata=all
 local w=W.new{seed_defaults=false};assert(W.add(w,{cik=1318605,name='Fixture',forms={'8-K'}}))
 local o={single_filing=true,watchlist=w,limit=5,include_reports=true,fetch_images=false,metrics_chapter=false,
  out_dir='/in-memory',work_dir='/in-memory/work',source=source,user_email='test@example.invalid'}
 local disk,phases
 phases={}
 o.on_watchlist_checkpoint=function(phase)
  phases[#phases+1]=phase
  disk=W.copyValue({entries=W.cloneList(o.watchlist.entries)})
  return true
 end
 return o,function() return W.load(disk,{seed_defaults=false}) end,phases
end
local o,reload,phases=fresh()
fail_body={};for i=2,5 do fail_body[all[i].accn]=true end
local r,e=Job.run(companies,o)
check(#r==1 and #e==4 and phases[1]=='plan','queue saved before bodies; partial batch explicit')
check(o.watchlist.entries[1].pending_batch~=nil,'partial progress remains pending')
o.watchlist=reload();metadata_error=true;fail_body=nil
local before=metadata_calls
r,e=Job.run(companies,o)
check(#r==4 and #e==0 and metadata_calls==before,'restarted pending batch works without metadata')
check(not records[all[6].accn] and o.watchlist.entries[1].seen_upto_date==all[1].date,'retry does not grow or lose frozen baseline')
metadata_error=false;r,e=Job.run(companies,o)
check(#r==0 and #e==0,'next run never backfills older initial history')
-- Kill-equivalent: callback sees committed original but refuses state save.
o,reload=fresh();local sink=o.on_watchlist_checkpoint
local calls=0
o.on_watchlist_checkpoint=function(phase)
 if phase=='filing' then calls=calls+1;if calls==5 then return false,'disk full' end end
 return sink(phase)
end
local info;r,e,info=Job.run(companies,o)
check(#r==5 and info.persistence_failed and not info.cancelled,'fifth checkpoint failure distinct from cancellation')
check(#o.watchlist.entries[1].pending_batch.completed==4 and not o.watchlist.entries[1].seen_upto_date,'failed final commit restores prior in-memory boundary')
o.watchlist=reload();o.on_watchlist_checkpoint=sink;local fetched=body_calls
r,e=Job.run(companies,o)
check(#r==1 and r[1].reused and body_calls==fetched,'published fifth original reused after restart, not fetched twice')
check(not o.watchlist.entries[1].pending_batch and o.watchlist.entries[1].seen_upto_date,'reused final original commits baseline in same checkpoint')
-- Plan persistence failures must cause zero body or publish side effects.
o=fresh();o.on_watchlist_checkpoint=function() return nil,'unwritable' end
r,e,info=Job.run(companies,o)
check(#r==0 and body_calls==0 and publishes==0 and info.persistence_failed,'plan flush failure stops before first body')
check(not o.watchlist.entries[1].pending_batch,'plan failure rolls back staged in-memory queues')
-- Metadata failure and valid empty responses are different.
o=fresh();metadata_error=true;r,e,info=Job.run(companies,o)
check(#e==1 and info.no_new==0 and not o.watchlist.entries[1].pending_batch,'metadata failure with watchlist is not no-new success')
o=fresh();metadata={};r,e,info=Job.run(companies,o)
check(#e==0 and info.no_new==1 and not o.watchlist.entries[1].first_run_done,'valid empty metadata does not invent baseline')
-- Freeze original membership despite new metadata and a changed limit.
o,reload=fresh();r,e,info=Job.run(companies,o,function(msg) return not msg:find('正在处理',1,true) end)
check(info.cancelled and o.watchlist.entries[1].pending_batch and body_calls==0,'cancel before first body preserves saved queue')
o.watchlist=reload();o.limit=1;metadata={{accn='0001318605-26-999999',date='2026-10-13',form='8-K',primary='new.htm'}}
r,e=Job.run(companies,o)
check(#r==5 and not records['0001318605-26-999999'],'pending ignores new filing and new limit until next batch')
r,e=Job.run(companies,o);check(#r==1 and r[1].accession=='0001318605-26-999999','next batch observes newly arrived filing')
-- Disabled companies and explicit historical fetches cannot consume pending.
o=fresh();Job.run(companies,o,function(msg) return not msg:find('正在处理',1,true) end)
local frozen=W.serialize(o.watchlist.entries[1].pending_batch);o.watchlist.entries[1].enabled=false
r,e=Job.run(companies,o);check(#r==0 and body_calls==0,'disabled company preserves pending without fetching')
o.selected_filing=all[9];r,e=Job.run(companies,o)
check(#r==1 and frozen==W.serialize(o.watchlist.entries[1].pending_batch),'explicit single filing never mutates automatic queue')
-- Old inconsistent progress is visible and requires explicit reset.
o=fresh();o.watchlist.entries[1].seen={all[1].accn};o.watchlist.entries[1].first_run_done=true
r,e=Job.run(companies,o);check(#e==1 and body_calls==0 and metadata_calls==0,'legacy no-baseline progress cannot silently backfill')
-- Publishing fails: queue remains wholly pending, no seen entries.
o=fresh();fail_publish=true;r,e=Job.run(companies,o)
check(#e==5 and #o.watchlist.entries[1].seen==0 and #o.watchlist.entries[1].pending_batch.completed==0,'publish errors never mark queue completed')
-- Same-process retry after a failed checkpoint uses the rolled-back queue.
o=fresh();sink=o.on_watchlist_checkpoint;calls=0
o.on_watchlist_checkpoint=function(phase)
 if phase=='filing' then return false,'transient' end;return sink(phase)
end
r,e=Job.run(companies,o);o.on_watchlist_checkpoint=sink;fetched=body_calls;r,e=Job.run(companies,o)
check(#r==5 and r[1].reused and body_calls-fetched==4,'same-process retry restores stable membership and reuses published first original')
-- Additional adversarial-review cases.
do
local Q=require('sec_download_queue')
-- Two companies: second has metadata failure; first keeps stable queue.
local o,reload=fresh()
assert(W.add(o.watchlist,{cik=320193,name='Second',forms={'8-K'}}))
local cs={companies[1],{cik=320193,name='Second'}}
local old_recent=source.recentFilings
source.recentFilings=function(self,cik,...)
 if tonumber(cik)==320193 then metadata_calls=metadata_calls+1;return nil,'second offline' end
 return old_recent(self,cik,...)
end
local r,e,info=Job.run(cs,o)
check(#r==5 and #e==1 and o.watchlist.entries[1].seen_upto_date and not o.watchlist.entries[2].pending_batch,'two companies metadata failure does not erase successful first baseline')
source.recentFilings=old_recent
-- Both success; company-scoped library keys avoid false shared accession reuse.
local old_existing,old_publish=L.existing,L.publishOriginal
L.existing=function(self,cik,a) return records[tostring(tonumber(cik))..':'..a] end
L.publishOriginal=function(self,c,f,b)
 local r,err=old_publish(self,c,f,b)
 if r then records[f.accn]=nil;records[tostring(tonumber(c.cik))..':'..f.accn]=r end
 return r,err
end
o,reload=fresh();assert(W.add(o.watchlist,{cik=320193,name='Second',forms={'8-K'}}))
local sink=o.on_watchlist_checkpoint
local count=0
o.on_watchlist_checkpoint=function(phase)
 if phase=='filing' then count=count+1;if count==6 then return nil,'disk full' end end
 return sink(phase)
end
r,e,info=Job.run(cs,o)
check(#r==6 and info.persistence_failed and o.watchlist.entries[1].seen_upto_date and #o.watchlist.entries[2].pending_batch.completed==0,'second company first checkpoint failure preserves first complete and second pending')
o.on_watchlist_checkpoint=sink;r,e,info=Job.run(cs,o)
check(#r==5 and r[1].reused and not o.watchlist.entries[2].pending_batch,'same-process retry completes second without redoing first')
L.existing,L.publishOriginal=old_existing,old_publish
-- Progress and persistence callbacks both yield.
o=fresh();sink=o.on_watchlist_checkpoint
local yields=0
o.on_watchlist_checkpoint=function(phase) coroutine.yield('save-'..phase);return sink(phase) end
local co=coroutine.create(function() return Job.run(companies,o,function() coroutine.yield('progress');return true end) end)
while coroutine.status(co)~='dead' do
 local ok,a,b,c=coroutine.resume(co);assert(ok,a)
 if coroutine.status(co)=='dead' then r,e,info=a,b,c else yields=yields+1 end
end
check(#r==5 and #e==0 and yields>7,'queue run accepts yielding progress and checkpoint callbacks')
-- Same-process LAST save failure, no reload.
o=fresh();sink=o.on_watchlist_checkpoint;count=0
o.on_watchlist_checkpoint=function(phase)
 if phase=='filing' then count=count+1;if count==5 then return false,'last save fail' end end
 return sink(phase)
end
r,e,info=Job.run(companies,o);o.on_watchlist_checkpoint=sink
local bodies=body_calls;r,e,info=Job.run(companies,o)
check(#r==1 and r[1].reused and body_calls==bodies and not o.watchlist.entries[1].pending_batch,'same-process final save failure retries only existing final original')
-- Real W.save, cloned settings payload and failure rollback, no filesystem.
o=fresh()
local store={data={email='unchanged',key='unchanged',sec_watchlist={legacy='unchanged'}},flush=function() return true end}
o.on_watchlist_checkpoint=function() return W.save(o.watchlist,store,{key='sec_watchlist_filings'}) end
Job.run(companies,o,function(m) return not m:find('正在处理',1,true) end)
local persisted=W.serialize(store.data.sec_watchlist_filings)
local before=Q.snapshot(o.watchlist)
assert(Q.complete(o.watchlist,companies[1].cik,all[1].accn))
check(W.serialize(store.data.sec_watchlist_filings)==persisted,'saved queue payload has no aliases to mutable live queue')
store.flush=function() error('flush threw') end
local ok,err=W.save(o.watchlist,store,{key='sec_watchlist_filings'})
check(not ok and err:find('flush threw',1,true) and W.serialize(store.data.sec_watchlist_filings)==persisted and store.data.email=='unchanged','thrown flush restores previous settings payload and unrelated keys')
end
do
local probe_opts=fresh();probe_opts.selected_filing=all[1]
fail_body={[all[1].accn]=true}
local r,e,info=Job.run(companies,probe_opts,function() return true end)
check(#r==0 and table.concat(e,'\n'):find('body failed',1,true),'selected filing preserves actual failure reason')
probe_opts=fresh();probe_opts.selected_filing=all[1]
local r2,e2,i2=Job.run(companies,probe_opts,function() return false end)
check(i2.cancelled and table.concat(e2):find('重新选择',1,true) and not probe_opts.watchlist.entries[1].pending_batch,'selected filing cancellation never promises an automatic queue')
end
-- Temporary recent-N must never inherit subscription state or fixed batches.
for _,state in ipairs({'enabled','disabled','baseline','pending'}) do
 local opts=fresh()
 if state=='disabled' then opts.watchlist.entries[1].enabled=false end
 if state=='baseline' then opts.watchlist.entries[1].seen_upto_date='2026-10-12';opts.watchlist.entries[1].first_run_done=true end
 if state=='pending' then Job.run(companies,opts,function(msg) return not msg:find('正在处理',1,true) end) end
 local before=W.serialize(opts.watchlist)
 local checkpoints=0;opts.on_watchlist_checkpoint=function() checkpoints=checkpoints+1;return true end
 local recent={{cik=1318605,name='Fixture',ad_hoc=true}}
 local rr,ee=Job.run(recent,opts)
 check(#rr==5 and #ee==0,'temporary recent-N works independently of '..state)
 check(W.serialize(opts.watchlist)==before and checkpoints==0,'temporary recent-N preserves full watchlist: '..state)
end
do
 local opts=fresh();opts.watchlist=W.new{seed_defaults=false}
 local rr,ee,ii=Job.run(companies,opts,function(msg) return not msg:find('正在处理',1,true) end)
 check(ii.cancelled and not table.concat(ee):find('固定批次',1,true),'nonqueued cancellation makes no frozen-membership promise')
end
print('download queue job: '..n..' checks passed; storage/network are in-memory spies')
