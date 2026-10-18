-- Pure state-machine tests; no network, UI, filesystem or real EPUB validation.
package.path='./secfilings.koplugin/?.lua;'..package.path
local W=require('sec_watchlist')
local Q=require('sec_download_queue')
local n=0
local function check(ok,msg) n=n+1;assert(ok,msg);print('PASS '..msg) end
local function state()
 local w=W.new{seed_defaults=false};assert(W.add(w,{cik=1318605,name='Fixture',forms={'8-K'}}));return w
end
local opts={include_reports=true,limit=5}
local filings={}
for i=1,12 do filings[i]={accn=string.format('0001318605-26-%06d',13-i),date=string.format('2026-10-%02d',13-i),form='8-K',primary='fixture.htm',items='2.02'} end
local function plan(w,fs)
 return W.planUpdates(w,{{cik='0001318605',filings=fs or filings}},{max_new_per_company=5})[1]
end
local w=state();local entry=w.entries[1];local u=plan(w)
assert(Q.begin(entry,u,opts));check(#entry.pending_batch.update.new_filings==5,'freeze five, not all history')
local original=Q.snapshot(w)
assert(Q.complete(w,entry.cik,filings[1].accn))
local retry=assert(Q.resume(entry,opts));check(#retry.filings==4 and retry.filings[4].accn==filings[5].accn,'A success resumes B-E, never F')
check(entry.seen_upto_date==nil and entry.pending_batch~=nil,'partial batch retains queue and old baseline')
local loaded=W.load({entries=W.cloneList(w.entries)},{seed_defaults=false})
check(#assert(Q.resume(loaded.entries[1],opts)).filings==4,'load and clone preserve pending progress')
loaded.entries[1].pending_batch.update.new_filings[1].primary='changed'
check(entry.pending_batch.update.new_filings[1].primary=='fixture.htm','pending metadata deep-copied')
check(#assert(Q.resume(entry,{include_reports=true,limit=1})).filings==4,'limit change applies next batch')
local bad,err=Q.resume(entry,{include_reports=false});check(not bad and err,'filter conflict refuses replanning')
entry.keep_seen=1
for i=2,5 do assert(Q.complete(w,entry.cik,filings[i].accn)) end
check(entry.pending_batch==nil and entry.seen_upto_date==filings[1].date and entry.first_run_done,'last completion atomically closes queue and baseline')
check(plan(w).new_count==0,'completed initial batch never backfills F-J')
local fresh={accn='0001318605-26-999999',date=filings[1].date,form='8-K',primary='new.htm'}
local news={fresh};for _,f in ipairs(filings) do news[#news+1]=f end
check(plan(w,news).new_count==1,'unobserved same-day new filing is not frozen closing history')
Q.restore(w,original);entry=w.entries[1]
check(#assert(Q.resume(entry,opts)).filings==5 and #entry.seen==0,'failed persistence can restore exact pre-commit state')
entry.pending_batch.version=99
check(not Q.resume(entry,opts),'unknown queue version fails closed')
local raw=W.cloneList(w.entries);local corrupt=W.load({entries=raw},{seed_defaults=false})
check(corrupt.entries[1].pending_batch.version==99,'normalization never silently discards unknown queue')
W.resetBaseline(w);entry=w.entries[1]
check(entry.pending_batch==nil and #entry.seen==0 and entry.forms[1]=='8-K','explicit reset clears queue, preserves preferences')
assert(Q.begin(entry,plan(w),opts));entry.pending_batch.completed={'outside'}
check(not Q.resume(entry,opts),'completed must be subset of frozen target')
W.resetBaseline(w);entry.last_success_at=1;entry.content_chars=5;W.resetBaseline(w,nil,{clear_stats=true})
check(entry.last_success_at==nil and entry.content_chars==nil,'explicit full reset clears only requested stale statistics')
local base=state();base.entries[1].seen_upto_date='2026-09-01';base.entries[1].first_run_done=true
local backlog=plan(base);assert(backlog.truncated==7);assert(Q.begin(base.entries[1],backlog,opts))
for i=1,5 do assert(Q.complete(base,base.entries[1].cik,filings[i].accn)) end
check(base.entries[1].seen_upto_date=='2026-09-01' and plan(base).new_count==5,'incremental backlog retains old baseline between finite batches')
local corruptions={
 {'shortened target',function(p) p.update.new_filings[5]=nil end},
 {'future baseline',function(p) p.update.baseline_new_date='2027-10-12' end},
 {'sparse target',function(p) p.update.new_filings[3]=nil end},
 {'changed completed subset',function(p) p.completed={p.update.new_filings[1].accn} end},
 {'changed count and target together',function(p) p.update.new_filings[5]=nil;p.update.new_count=4 end},
 {'changed metadata',function(p) p.update.new_filings[5].primary='other.htm' end},
}
for _,case in ipairs(corruptions) do
 local cw=state();local ce=cw.entries[1];assert(Q.begin(ce,plan(cw),opts));case[2](ce.pending_batch)
 check(not Q.validate(ce),'reject accidental corruption: '..case[1])
end
local cw=state();assert(Q.begin(cw.entries[1],plan(cw),opts))
local serialized=W.serialize({entries=W.cloneList(cw.entries)})
local decode=assert(loadstring(serialized));setfenv(decode,{})
local restored=W.load(decode(),{seed_defaults=false})
check(#assert(Q.resume(restored.entries[1],opts)).filings==5,'checksum survives actual serialize/parse/load roundtrip')
restored.entries[1].seen_upto_date='2026-10-11'
check(not Q.resume(restored.entries[1],opts),'changed external baseline is not overwritten by a pending batch')
print('download queue: '..n..' checks passed; pure state transitions')
