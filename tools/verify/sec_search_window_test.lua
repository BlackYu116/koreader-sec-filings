-- Real search engine, fixed JSON response; no network/native UI.
if not SEC_TEST_PLUGIN_DIR then package.path='./secfilings.koplugin/?.lua;'..package.path end
package.loaded['socket.http']={request=function() error('network forbidden') end}
package.loaded.ltn12={};package.loaded.socket={};package.loaded.logger={warn=function() end}
local fixture={name='Fixture',filings={recent={form={'10-Q','OLD-FORM','OLD-FORM'},filingDate={'2026-10-01','2020-01-01','2020-01-02'},accessionNumber={'0000320193-26-000001','0000320193-20-000001','0000320193-20-000002'},primaryDocument={'a.htm','b.htm','c.htm'}},files={}}}
package.loaded.json={decode=function() return fixture end}
local Search=require('sec_search');Search._get=function() return '{}' end
local count=0
local function check(v,label) assert(v,label);count=count+1 end
local ok,list=Search:listFilings(320193,{since='2023-10-11'})
check(ok and #list.entries==1,'window has one filing')
check(#list.form_summary_window==1 and list.form_summary_window[1].form=='10-Q','window excludes historical forms')
check(list.form_summary_all[1].count==2,'historical API statistics retained separately')
fixture.filings.recent.form={'10-Q','10-Q/A','8-K'}
fixture.filings.recent.filingDate={'2026-10-01','2026-10-02','2026-10-03'}
fixture.filings.recent.accessionNumber={'0000320193-26-000001','0000320193-26-000002','0000320193-26-000003'}
local success,filtered=Search:listFilings(320193,{since='2023-10-11',forms={'10-Q'}})
check(success and #filtered.entries==2,'boundary form filter includes amendments')
check(#filtered.form_summary_window==3,'window summary independent of selected form')
local matches=0
for _,row in ipairs(filtered.form_summary_window) do if Search.matchesForm(row.form,'10-Q') then matches=matches+row.count end end
check(matches==2,'summary can produce exact boundary-match count')
local _,without=Search:listFilings(320193,{since='2023-10-11',amendments=false})
check(#without.form_summary_window==2,'window summary obeys amendment policy')
local _,partial=Search:listFilings(320193,{since='2023-10-11',max_total=1})
check(partial.form_summary_partial==true,'bounded summary explicitly partial')
print(string.format('search window: %d checks passed; no network',count))
