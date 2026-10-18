-- Bounded batches against real scanners/protection/caches; fake model transport only.
package.path='./secfilings.koplugin/?.lua;'..package.path
local root=assert(arg[1],'fresh sandbox required')
local T=require('sec_translate');local F=require('sec_watchlist');local json=require('json')
assert(F.ensureDir(root))
local calls,n=0,0
local function check(ok,label) n=n+1;assert(ok,label);print('PASS '..label) end
local function echo(text)
 calls=calls+1
 local rows=json.decode(text)
 for _,row in ipairs(rows) do row.text=row.text:gsub('Revenue','营收') end
 return json.encode(rows)
end
local function new(extra)
 local opts={batch_mode=true,api_key='offline',cache_dir=root,max_requests=1000,max_input_bytes=2000000,transport=echo}
 for k,v in pairs(extra or {}) do opts[k]=v end
 return T:new(opts)
end
local nodes={};for i=1,540 do nodes[i]='<p title="a > b">Revenue '..i..'</p>' end
local html=table.concat(nodes)
local tr=new();local plan=assert(tr:estimate({{html=html}}))
check(plan.requests==68 and plan.blocks==540 and calls==0,'540 distinct synthetic nodes plan 68 batches, zero calls')
local out=assert(tr:translateHtml(html))
check(out==html:gsub('Revenue','营收') and calls==68 and tr.request_count==plan.requests,'execution exactly follows plan and preserves markup/numbers')
check(tr.input_bytes==plan.input_bytes and tr.wire_bytes==plan.wire_bytes,'planned and attempted body/protected byte totals agree')
check(new():estimate({{html=html}}).requests==0,'new batch cache eliminates subsequent requests')
local legacydir=root..'/legacy';assert(F.ensureDir(legacydir))
local legacy=T:new{api_key='offline',cache_dir=legacydir,transport=function(s) return s:gsub('Revenue','营收') end}
assert(legacy:translateText('Revenue legacy 42'))
local migrated=new{cache_dir=legacydir,cache_only=true}
check(migrated:translateHtml('<p>Revenue legacy 42</p>')=='<p>营收 legacy 42</p>' and migrated.request_count==0,'validated v2 filing cache reused without fees')
local dup=new{cache_dir=root..'/dup'};assert(F.ensureDir(dup.cache_dir))
local duphtml='<p>Revenue unique 901</p><i>Revenue unique 901</i><b>Revenue other 902</b>'
local dp=assert(dup:estimate({{html=duphtml}}));assert(dup:translateHtml(duphtml))
check(dp.requests==1 and dp.blocks==2 and dup.request_count==1,'pending duplicate costs no extra item or request')
local function failure(label,transport)
 local dir=root..'/'..label;assert(F.ensureDir(dir))
 local t=new{cache_dir=dir,transport=transport};local before=calls
 local result=t:translateHtml('<p>Revenue first 73</p><p>Revenue second 74</p>')
 check(not result and t.request_count==1 and t.stopped,'invalid '..label..' stops entire batch')
 check(t:translateHtml('<p>Revenue third 75</p>')==nil and t.request_count==1,'invalid '..label..' never retries')
 check(new{cache_dir=dir}:estimate({{html='<p>Revenue first 73</p><p>Revenue second 74</p>'}}).blocks==2,'invalid '..label..' writes no partial cache')
end
failure('ids',function(s) local a=json.decode(s);a[1].id=2;return json.encode(a) end)
failure('count',function(s) local a=json.decode(s);a[2]=nil;return json.encode(a) end)
failure('number',function(s) local a=json.decode(s);a[2].text='invented 99';return json.encode(a) end)
failure('json',function() return 'not JSON' end)
failure('extra',function(s) local a=json.decode(s);a[1].extra=true;return json.encode(a) end)
local stopped=new{cache_dir=root..'/budget',max_requests=1};assert(F.ensureDir(stopped.cache_dir))
check(not stopped:translateHtml(html) and stopped.request_count==1,'limited run stops once without resetting budget')
local nocall=new{cache_dir=root..'/persist',on_attempt=function() return nil,'failed' end};assert(F.ensureDir(nocall.cache_dir))
local before=calls
check(not nocall:translateHtml('<p>Revenue ledger 77</p>') and calls==before,'failed durable attempt checkpoint prevents dispatch')
local cancelled=new{cache_dir=root..'/cancel'};assert(F.ensureDir(cancelled.cache_dir))
check(not cancelled:translateHtml(html,function() return false end) and cancelled.request_count==0,'cancel before first dispatch makes no paid attempt')
local sparse='<p>123</p><!-- untouched --><p>中文</p><p>Revenue 日本 88</p>'
local sparseT=new{cache_dir=root..'/utf'};assert(F.ensureDir(sparseT.cache_dir))
check(sparseT:translateHtml(sparse)==sparse:gsub('Revenue','营收'),'Chinese-only/numeric/comment/UTF8/table scanner bytes preserved')
local shared=new{cache_dir=root..'/shared-reader',legacy_cache_dir=legacydir,cache_only=true}
assert(F.ensureDir(shared.cache_dir))
check(shared:translateHtml('<p>Revenue legacy 42</p>')=='<p>营收 legacy 42</p>' and shared.request_count==0,'legacy shared v2 cache remains usable read-only')
check(new{cache_dir=legacydir,thinking=true}:estimate({{html='<p>Revenue legacy 42</p>'}}).blocks==1,'thinking mode never crosses cache identity')
check(new{cache_dir=legacydir,model='different'}:estimate({{html='<p>Revenue legacy 42</p>'}}).blocks==1,'model never crosses cache identity')
local longhtml='<table><tr><td>'..string.rep('Revenue text ',500)..'</td></tr></table>'
local long=new{cache_dir=root..'/long'};assert(F.ensureDir(long.cache_dir))
local lp=assert(long:estimate({{html=longhtml}}))
check(long:translateHtml(longhtml)==longhtml:gsub('Revenue','营收') and long.request_count==lp.requests,'legacy long-node boundaries and table markup survive batching')
local after=false
local suspend=new{cache_dir=root..'/suspend',transport=function(s) after=true;return echo(s) end};assert(F.ensureDir(suspend.cache_dir))
check(not suspend:translateHtml(html,function() return not after end) and suspend.request_count==1,'cancel after in-flight response saves validated batch but starts no second request')
local resumed=new{cache_dir=suspend.cache_dir}
check(resumed:estimate({{html=html}}).blocks==532,'suspend retains eight validated fragments for next explicit task')
local missing=new{cache_dir=root..'/missing-parent'}
local before=calls
check(not missing:translateHtml(html) and calls==before+1 and missing.stopped,'cache write failure stops after first response without fallback')
local tiny=new{cache_dir=root..'/tiny-body',max_wire_bytes=1};assert(F.ensureDir(tiny.cache_dir));before=calls
check(not tiny:translateHtml('<p>Revenue body 11</p>') and calls==before and tiny.request_count==0,'total HTTP body cap is enforced before any attempt')
local giant=new{cache_dir=root..'/giant-body',model=string.rep('m',17000)};assert(F.ensureDir(giant.cache_dir));before=calls
check(not giant:estimate({{html='<p>Revenue body 11</p>'}}) and not giant:translateHtml('<p>Revenue body 11</p>') and calls==before,'full serialized body hard cap includes model/prompt/JSON overhead')
local bytecap=new{cache_dir=root..'/bytecap',max_input_bytes=1};assert(F.ensureDir(bytecap.cache_dir));before=calls
check(not bytecap:translateHtml('<p>Revenue body 11</p>') and calls==before and bytecap.request_count==0,'protected body byte cap prevents dispatch')
local metrics={id='metrics_123',company_id='co_123',heading='关键指标',html='<p>Revenue taxonomy 99</p>'}
local mt=new();before=calls
check(mt:estimate({metrics}).requests==0 and mt:translateChapter(metrics)==metrics.html and calls==before,'structural Chinese metrics skip unchanged in batch mode')
failure('unicode-fullwidth',function(s) local a=json.decode(s);a[1].text=a[1].text..' １００';return json.encode(a) end)
failure('unicode-arabic',function(s) local a=json.decode(s);a[1].text=a[1].text..' ١٠٠';return json.encode(a) end)
failure('empty-language',function(s) local a=json.decode(s);a[1].text='SECX1X';return json.encode(a) end)
local uni=new{cache_dir=root..'/unicode-source'};assert(F.ensureDir(uni.cache_dir))
check(uni:translateHtml('<p>Revenue １００ and ١٠٠</p>')=='<p>营收 １００ and ١٠٠</p>','source Unicode decimals protected and restored unchanged')
-- A legacy raw block may expand past the packing target when numbers become
-- placeholders. Preserve its old cache boundary and send it alone, still
-- bounded by the complete serialized body cap and the same task ledger.
local expanded=new{cache_dir=root..'/expanded'};assert(F.ensureDir(expanded.cache_dir))
local expandedhtml='<p>Revenue '..string.rep('$1 ',700)..'</p><p>Revenue tail 23</p>'
local ep=assert(expanded:estimate({{html=expandedhtml}}))
check(ep.requests==2 and expanded:translateHtml(expandedhtml)==expandedhtml:gsub('Revenue','营收') and expanded.request_count==2,'placeholder-expanded legacy block remains isolated and follows exact planning')
check(expanded.wire_bytes==ep.wire_bytes and expanded.input_bytes==ep.input_bytes,'expanded singleton remains inside the planned cumulative byte ledger')
local excessive=new{cache_dir=root..'/excessive'};assert(F.ensureDir(excessive.cache_dir));before=calls
check(not excessive:estimate({{html='<p>Revenue '..string.rep('$',2390)..'</p>'}}) and calls==before,'expansion beyond the complete body hard cap still refuses without dispatch')
local marks=new{cache_dir=root..'/trademarks'};assert(F.ensureDir(marks.cache_dir))
local marked_html='<p>iPhone®</p><p>Mac®</p><p>iPad®</p><p>iPhone</p><p>Mac</p><p>iPad</p><p>Revenue 100</p>'
local marked_plan=assert(marks:estimate({{html=marked_html}}))
check(marked_plan.blocks==1 and marked_plan.requests==1,'marked products are excluded from batch preflight, not counted as translated prose')
check(marks:translateHtml(marked_html)==marked_html:gsub('Revenue','营收') and marks.completed_blocks==1,'batch retains literal product marks while translating financial text')
print('batch translation: '..n..' checks passed; no API, synthetic text')
