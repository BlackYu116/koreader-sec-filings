-- Focused quality regression. Offline model/HTTP substitutes, no device rendering.
package.path='./secfilings.koplugin/?.lua;'..package.path
local T=require('sec_translate')
local root=assert(arg[1]); local n=0
local function check(ok,label) n=n+1;assert(ok,label);print('PASS '..label) end
local tr=T:new{api_key='offline',transport=function(s) return s:gsub('NET INCOME','净利润') end}
check(tr:translateText('NET INCOME')=='净利润' and tr.request_count==1,'uppercase financial heading is translated')
tr=T:new{api_key='offline',transport=function(s) return s end,cache_dir=root}
local value,err=tr:translateText('Revenue increased by 10 percent.')
check(not value and err:find('中文',1,true),'English echo rejected rather than cached')
local cached=T:new{cache_only=true,cache_dir=root}
check(not cached:translateText('Revenue increased by 10 percent.'),'rejected echo is not reused')
tr=T:new{api_key='offline',transport=function(s) return s end}
check(tr:translateText('TSLA USD GAAP us-gaap')=='TSLA USD GAAP us-gaap' and tr.request_count==0,'explicit codes need no paid request')
local P=T._batch
-- A v2 response must not bind an old uppercase placeholder to a new identifier.
local oldsource='REVENUE us-gaap 10'
local oldpath,oldkey=P.cachePath(T:new{cache_dir=root},oldsource)
local f=assert(io.open(oldpath,'wb'));f:write('SEC-TRANSLATION-2\n'..oldkey..'\nSECX1X 公认会计准则 SECX2X');f:close()
local oldreader=T:new{cache_dir=root,cache_only=true}
check(not oldreader:translateText(oldsource),'legacy placeholder mapping is not rebound to another source token')
local protected,tokens=P.protect('TOTAL REVENUE 10')
check(protected:find('TOTAL REVENUE',1,true) and P.validate('总营收 SECX1X',tokens)=='总营收 10','uppercase prose retains numeric protection')
check(not P.validate('TOTAL REVENUE SECX1X',tokens),'old English-only cache rejected by current validation')
local mixed=T:new{api_key='offline',transport=function(s) return s end}
check(not mixed:translateText('中文说明 Revenue 10'),'mixed-language verbatim echo is not accepted merely because it contains Chinese')
local json=require('json')
local batch=T:new{api_key='offline',batch_mode=true,cache_dir=root,transport=function(s)
    local rows=json.decode(s)
    for _,row in ipairs(rows) do row.text=row.text:gsub('NET INCOME','净利润') end
    return json.encode(rows)
end}
local plan=assert(batch:estimate({{html='<h2>NET INCOME</h2>'}}))
check(plan.blocks==1 and plan.requests==1,'batch preflight counts uppercase heading')
check(batch:translateHtml('<h2>NET INCOME</h2>')=='<h2>净利润</h2>','batch execution translates uppercase heading without changing markup')
local oldbatch=T:new{cache_dir=root,batch_mode=true,cache_only=true}
check(oldbatch:estimate({{html='<p>'..oldsource..'</p>'}}).blocks==1,'batch legacy read-through also rejects rebound placeholders')
local padded=T:new{api_key='offline',batch_mode=true,cache_dir=root,transport=function(s)
    local rows=json.decode(s)
    for _,row in ipairs(rows) do row.text='  '..row.text..'  ' end
    return json.encode(rows)
end}
check(not padded:translateHtml('<p>Revenue 中文</p>') and padded.completed_blocks==0,
    'batch echo with added boundary whitespace cannot be accepted')
check(not T:new{batch_mode=true,cache_dir=root,cache_only=true}:translateHtml('<p>Revenue 中文</p>'),
    'rejected padded batch echo leaves no reusable cache')
package.loaded['socket.http']={};package.loaded.ltn12={};package.loaded.logger={warn=function() end,info=function() end}
package.preload['libs/libkoreader-cre']=function() error('no native cre') end
local S=require('sec_source')
local html=S:cleanHtml('<p><b>10</b> <i>million</i></p>')
check(html:find('</b> <i>',1,true),'inline word and unit boundary preserved')
html=S:cleanHtml('<p><b>10</b> <i>20</i></p>')
check(html:find('</b> <i>',1,true),'adjacent numeric fragments remain separated')
print('quality: '..n..' checks passed; offline transport, no real cre')
