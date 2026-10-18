-- Real main/search UI with deterministic SEC replies and yielding event-loop stubs.
-- Does not validate pixels, physical touch, Kindle networking or native settings persistence.
if not SEC_TEST_PLUGIN_DIR then package.path="./secfilings.koplugin/?.lua;" .. package.path end
local root=assert(arg[1],"fresh sandbox required")
local shown,network,calls,yields,saves={},0,0,0,0
local settings={email="test@example.invalid",deepseek_api_key="offline-only"}
local store={data=settings,readSetting=function(self,k) return settings[k] end,
    saveSetting=function(self,k,v) settings[k]=v end,
    flush=function() saves=saves+1 end,
    nilOrTrue=function(self,k) return settings[k]~=false end,
    toggle=function(self,k) settings[k]=not settings[k] end}
package.loaded["datastorage"]={getSettingsDir=function() return root end}
package.loaded["luasettings"]={open=function() return store end}
package.loaded["gettext"]=function(s) return s end
package.loaded["ffi/util"]={template=function(s,...)
    local args={...}; return (s:gsub("%%(%d+)",function(n) return tostring(args[tonumber(n)]) end))
end}
package.loaded["logger"]={info=function() end,warn=function() end}
package.loaded["ui/uimanager"]={show=function(self,w) shown[#shown+1]=w end,close=function(self,w) w.closed=true end}
for i,name in ipairs({"infomessage","inputdialog","confirmbox","menu"}) do
    package.loaded["ui/widget/" .. name]={new=function(self,o) o.kind=name; o.onShowKeyboard=function() end; return o end}
end
package.loaded["ui/network/manager"]={runWhenOnline=function(self,f) network=network+1; f() end}
package.loaded["ui/trapper"]={info=function(self,msg) yields=yields+1; coroutine.yield(); return true end,
    reset=function() end,wrap=function(self,f)
        local co=coroutine.create(f)
        while coroutine.status(co)~="dead" do local ok,e=coroutine.resume(co); assert(ok,e) end
    end}
package.loaded["ui/widget/container/widgetcontainer"]={extend=function(self,t) return t end}
package.loaded["sec_source"]={companies={{cik=320193,name="苹果"}},table_width_presets={tight=15}}
package.loaded["sec_search"]={}
package.loaded["sec_images"]={}
package.loaded["sec_metrics"]={}
package.loaded["sec_epub"]={write=function(self,path,book)
    local f=assert(io.open(path,"wb")); f:write(book.chapters[1].html); f:close(); return true
end}
local Files=require("sec_watchlist")
local Lib=require("sec_library")
local Filing=require("sec_filing")
require("sec_translate")._request=function(self,text) calls=calls+1; return text:gsub("Revenue","收入") end
local Main=require("main")
local legacy={version=1,entries={{cik=320193,name="苹果",forms={"10-Q"},enabled=false,
    seen={"0000320193-26-000099"},seen_upto_date="2026-10-01",first_run_done=true}}}
settings.sec_watchlist=legacy
local plugin=setmetatable({ui={menu={registerToMainMenu=function() end}},
    sec_work_dir=root .. "/work",sec_out_dir=root .. "/books"},{__index=Main})
plugin:init()
local n,fetches,resolves=0,0,0
local function check(v,s) n=n+1; assert(v,s); print('PASS '..s) end
local function find(items,text) for _,item in ipairs(items) do if item.text:find(text,1,true) then return item end end end
local Search=package.loaded.sec_search
local mode='normal'
Search.resolve=function(self,q)
    resolves=resolves+1
    if q=='bad' then return nil,'offline failure','network' end
    if q=='late' then plugin:startSearch('fresh') end
    if q=='ambiguous' then return true,{ambiguous=true,candidates_total=50,candidates_truncated=true,aliases={{cik=1,name='A'},{cik=2,name='B'}}} end
    return true,{cik=320193,cik_num=320193,name=q,ticker='TEST'}
end
Search.listFilings=function(self,cik,opts)
    fetches=fetches+1
    if mode=='failure' then return nil,'offline failure','network' end
    local entries={}
    for i=1,45 do
        entries[i]={form=i%2==0 and '10-Q' or '4',filing_date='2026-10-01',
            accession_number=string.format('0000320193-26-%06d',i),primary_document='doc.htm'}
    end
    entries[2].form='10-Q/A'
    if mode=='empty' then entries={} end
    return true,{entries=entries,cik=tostring(cik),cik_num=tonumber(cik),name='公司',
        matched=#entries,truncated=mode=='truncated',form_summary_scope=mode=='truncated' and 'partial' or 'since_window',
        form_summary={{form='4',count=23},{form='10-Q',count=21},{form='10-Q/A',count=1}}}
end
Search.matchesForm=function(a,b) return a==b or a==b..'/A' end
plugin:startSearch('company')
check(plugin._search_window and plugin._search_window.kind=='menu','successful query opens results immediately')
local window=plugin._search_window
find(plugin:getSearchItems(),'下一页').callback()
check(plugin.search_state.page==2 and plugin._search_window~=window and window.closed,'logical pagination directly refreshes results without stacking')
window=plugin._search_window; window.page=2
plugin:closeSearchPanel(); plugin:showSearchResults()
check(plugin.search_state.page==2 and plugin._search_window.page==2,'reopening preserves logical and native menu page')
local before=fetches; local net=network
plugin:setSearchForms({'10-Q'})
check(fetches==before and network==net and #plugin.search_state.list.entries==22,'complete set filters locally with amendment semantics')
check(plugin.search_state.page==1 and plugin.search_state.form_key=='10-Q','new filter resets to its first page')
check(find(plugin:getFormFilterItems(),'10-Q（22 份）'),'form count includes amendments matched by the filter')
local summary=plugin.search_state.summary
plugin.search_state.summary={}
for i=1,30 do plugin.search_state.summary[i]={form='FORM'..i,count=1} end
check(find(plugin:getFormFilterItems(),'FORM30（1 份）')~=nil,'all thirty form filters are reachable through native pagination')
plugin.search_state.summary=summary
plugin:setSearchForms(nil)
check(plugin.search_state.page==2 and #plugin.search_state.list.entries==45,'return to all forms preserves previous page')
window=plugin._search_window
local filter=find(window.item_table,'按类型筛选')
window.onMenuSelect(window,filter)
check(window.closed and plugin._search_window.title:find('按类型',1,true),'form options open directly in a dedicated panel')
local submenu=plugin._search_window; submenu.close_callback()
check(plugin._search_window~=submenu and plugin.search_state.page==2,'closing filter options returns to results')
local saved=plugin.search_state
plugin:startSearch('bad')
check(plugin.search_state==saved and plugin._search_window,'failed resolution retains previous results')
mode='failure'; plugin:startSearch('other')
check(plugin.search_state==saved,'failed filings fetch retains previous results')
mode='normal'; plugin:startSearch('ambiguous')
check(plugin.search_state.candidates and plugin._search_window,'ambiguous companies open choice panel directly')
check(plugin.search_state.candidates_total==50 and find(plugin._search_window.item_table,'仅显示前 2 家'),'candidate truncation is visible')
local chooser=plugin._search_window
chooser.onMenuSelect(chooser,find(chooser.item_table,"A"))
check(plugin.search_state.company and not plugin.search_state.candidates and plugin._search_window,'company selection fetches and displays filings')
mode='truncated'; plugin:startSearch('large')
check(find(plugin._search_window.item_table,'不完整'),'truncation warning visible without opening a separate message')
before=fetches; plugin:setSearchForms({'10-Q'})
check(fetches==before+1,'truncated base cannot be treated as a complete local filter')
saved=plugin.search_state; mode='failure'; plugin:setSearchForms({'8-K'})
check(plugin.search_state==saved and plugin.search_state.form_key=='10-Q','failed filter keeps previous conditions and results')
mode='empty'; plugin:startSearch('empty')
check(#plugin.search_state.list.entries==0 and find(plugin._search_window.item_table,'没有符合条件'),'empty result remains navigable and explicit')
mode='normal'; plugin:startSearch('late')
check(plugin.search_state.query=='fresh','late response cannot overwrite a newer query')
local info=package.loaded['ui/trapper'].info
package.loaded['ui/trapper'].info=function() return false end
saved=plugin.search_state; before=resolves
plugin:startSearch('cancelled')
check(resolves==before and plugin.search_state==saved and not plugin.search_pending,'cancel before request preserves previous results')
package.loaded['ui/trapper'].info=info
local nm=package.loaded['ui/network/manager']; local run=nm.runWhenOnline; local queue={}
nm.runWhenOnline=function(self,f) queue[#queue+1]=f end
before=resolves; plugin:startSearch('old-queued'); plugin:startSearch('new-queued')
queue[1](); queue[2](); nm.runWhenOnline=run
check(resolves==before+1 and plugin.search_state.query=='new-queued','obsolete deferred network callback never dispatches')
window=plugin._search_window; local selected
plugin.startFilingDownload=function(self,company,filing) selected=filing end
local row=find(window.item_table,'2026-10-01')
window.onMenuSelect(window,row)
check(selected and not window.closed and plugin._search_window==window and plugin.search_state.query=='new-queued','exact filing keeps a return path beneath download prompts and summary')
plugin:showSearchResults(); before=fetches
window.onMenuSelect(window,row)
check(fetches==before,'closed stale result window is inert')
plugin.sec_busy=true; before=resolves; plugin:startSearch('busy'); plugin.sec_busy=false
check(resolves==before,'active SEC job blocks new search')
local date=os.date; os.date=function() return {year=2028,month=2,day=29} end
check(plugin:sinceDate(3)=='2025-02-28','leap-day search window produces a valid date')
os.date=date
-- Subscription persistence errors must not leave optimistic live state.
plugin.sec_busy=false
local original_save=Files.save
local snapshot=Files.serialize(plugin.watchlist)
local count_shown=#shown
Files.save=function() return nil,'disk full' end
plugin:watchCompany({cik=987654,name='New'})
check(Files.serialize(plugin.watchlist)==snapshot,'failed add rolls live watchlist back')
check(not shown[#shown].text:find('已把',1,true),'failed add never reports success')
plugin:toggleWatch(320193)
check(Files.serialize(plugin.watchlist)==snapshot,'failed toggle rolls live watchlist back')
plugin:setAllWatched(false)
check(Files.serialize(plugin.watchlist)==snapshot,'failed set-all rolls live watchlist back')
Files.save=function() error('test exception') end
local changed=pcall(function() plugin:watchCompany({cik=987654,name='New'}) end)
check(changed and Files.serialize(plugin.watchlist)==snapshot,'thrown save restores state without escaping UI')
Files.save=function() return nil,'disk full' end
check(plugin:watchForm({cik=320193,name='Apple'},'NEW-FORM')==nil and Files.serialize(plugin.watchlist)==snapshot,'failed per-form subscription edit is one atomic rollback')
Files.save=original_save
plugin.search_state={company={cik=320193,name='Apple'},list={entries={},form_summary_scope='partial'},page=1}
check(not find(plugin:getSearchItems(),'没有符合条件'),'partial empty never claims proven absence')
check(find(plugin:getSearchItems(),'部分结果'),'partial empty explains incomplete retrieval')
local recent=find(plugin:getSearchItems(),'下载这家最近')
local old_start=plugin.startDownload
plugin.startDownload=function(self,companies) check(companies[1].ad_hoc==true,'search recent-N explicitly bypasses subscriptions') end
recent.callback();plugin.startDownload=old_start
-- Product-state regressions: open menus must follow committed state, not snapshots.
local watch=plugin:getWatchlistItems()[1]
local was=watch.checked_func();watch.callback()
check(watch.checked_func()~=was,'open watch menu reflects successful toggle')
Files.save=function() return nil,'disk full' end
local live=watch.checked_func();watch.callback()
check(watch.checked_func()==live,'open watch menu reflects failed-save rollback')
Files.save=original_save
mode='truncated';plugin:startSearch('partial-refresh');plugin:setSearchForms({'10-Q'})
before=fetches
plugin:refreshSearch()
check(fetches==before+1 and plugin.search_state.form_key=='10-Q','explicit refresh bypasses partial cached filter')
local previous=plugin.search_state.list
mode='failure';plugin:refreshSearch()
check(plugin.search_state.list==previous and plugin._search_window,'failed refresh preserves prior visible result')
mode='normal';plugin:refreshSearch()
check(next(plugin.search_state.views)==nil,'successful refresh invalidates older filter views')
local list_filings=Search.listFilings
Search.listFilings=function(self,cik,opts)
    local ok,list=list_filings(self,cik,opts)
    list.form_summary_window={{form='10-Q',count=99},{form='NEW-FORM',count=1}}
    return ok,list
end
plugin.search_state.summary_partial=true
plugin:refreshSearch()
check(find(plugin:getFormFilterItems(),'10-Q（99 份）') and find(plugin:getFormFilterItems(),'NEW-FORM')
    and not plugin.search_state.summary_partial,'filtered refresh updates all-type counts and completeness')
Search.listFilings=list_filings
local queued
local online=package.loaded['ui/network/manager'].runWhenOnline
package.loaded['ui/network/manager'].runWhenOnline=function(self,fn) queued=fn end
plugin:startSearch('sleep-pending');before=resolves
plugin:onSuspend();queued()
check(resolves==before,'suspend revokes queued search')
package.loaded['ui/network/manager'].runWhenOnline=online
print('real main/search UI: '..n..' checks passed; deterministic SEC and widget adapters')
