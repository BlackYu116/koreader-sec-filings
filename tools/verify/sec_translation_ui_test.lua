-- Executes the REAL main.lua + translation UI/library in an offline UI/event-loop harness.
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
package.loaded["ui/uimanager"]={show=function(self,w) shown[#shown+1]=w end,close=function() end}
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
local n=0
local function check(ok,label) n=n+1; assert(ok,label); print("PASS " .. label) end
local function find(items,text)
    for i=1,#items do if items[i].text:find(text,1,true) then return items[i] end end
end
check(settings.sec_watchlist==legacy and legacy.entries[1].first_run_done and #legacy.entries[1].seen==1,"upgrade leaves old watchlist and baseline untouched")
check(settings.sec_watchlist_filings and not plugin.watchlist.entries[1].first_run_done and #plugin.watchlist.entries[1].seen==0,"new format gets independent empty download baseline")
check(plugin.watchlist.entries[1].forms[1]=="10-Q" and plugin.watchlist.entries[1].enabled==false,"migration preserves subscription choices and disabled state")
plugin.watchlist.entries[1].first_run_done=true
plugin:saveWatchlist(); plugin:loadWatchlist()
check(plugin.watchlist.entries[1].first_run_done,"second load does not reset migrated baseline")
check(not plugin:jobOpts({}).metrics_chapter,"per-filing defaults do not mix latest company metrics into original")
plugin:deepSeekKeyDialog()
check(shown[#shown].input=="" and shown[#shown].text_type=="password" and settings.deepseek_api_key=="offline-only","key editor never preloads stored secret")
local menu=plugin:getSubMenuItems()
check(find(menu,"已有原文") and not find(menu,"原文 + 中文"),"real main exposes local translation rather than implicit paid download")
local config=plugin:getTranslationItems()
local budget=find(config,"每轮最多请求")
budget.sub_item_table_func()[1].callback()
check(plugin:translationOptions().translation_max_requests==5 and plugin:translationOptions().translation_max_input_bytes==12000,"budget menu updates bounded job options")
local only=find(config,"仅使用已有缓存")
only.callback(); check(plugin:translationOptions().translation_cache_only,"offline switch connected")
check(find(plugin:getLocalTranslationItems(),"暂无新版原文"),"empty-library explanation")
local co={cik=320193,name="苹果"}; local filing={accn="0000320193-26-000001",form="10-Q",date="2026-10-01"}
assert(Files.ensureDir(plugin.sec_out_dir .. "/" .. Filing.companyDir(co)))
local f=assert(io.open(Filing.outputPath(plugin.sec_out_dir,co,filing,"en"),"wb")); f:write("original"); f:close()
local lib=Lib:new(plugin:translationOptions())
local r=assert(lib:register(co,filing,{title="Quarter",chapters={{id="one",heading="Results",html="<p>Revenue 10.</p>"}}}))
settings.deepseek_api_key=""
plugin:getLocalTranslationItems()[1].sub_item_table_func()[1].callback()
check(shown[#shown].kind=="confirmbox" and calls==0 and network==0,"cache-only preflight shows confirmation without key/network")
local confirmation=shown[#shown]
confirmation.ok_callback()
check(calls==0 and network==0 and shown[#shown].text:find("仅缓存",1,true) and not plugin.sec_busy,"offline cache miss reports without network")
only.callback(); plugin:prepareTranslation(co.cik,filing.accn)
check(shown[#shown].kind=="infomessage" and shown[#shown].text:find("API Key",1,true) and calls==0,"missing key blocks paid path")
settings.deepseek_api_key="offline-only"
local before_saves=saves
plugin:prepareTranslation(co.cik,filing.accn)
confirmation=shown[#shown]
check(confirmation.kind=="confirmbox" and confirmation.text:find("不是金额预算",1,true) and calls==0 and network==0,"paid action is inert until explicit confirmation")
check(confirmation.text:find("5 请求 / 12000",1,true) and not confirmation.text:find("offline-only",1,true),"confirmation shows limits, never key")
-- Changing settings after confirmation must not silently change the approved translator.
settings.deepseek_model="changed-after-confirm"
confirmation.ok_callback()
check(calls==1 and network==1 and shown[#shown].text:find("已生成",1,true) and not plugin.sec_busy,"confirmed paid path runs once and resets busy flag")
confirmation.ok_callback()
check(calls==1 and network==1,"duplicate confirmation cannot dispatch twice")
check(saves==before_saves,"translation does not touch watchlist/settings persistence")
settings.deepseek_model=nil; settings.deepseek_api_key=""
plugin:prepareTranslation(co.cik,filing.accn); shown[#shown].ok_callback()
check(calls==1 and network==1 and shown[#shown].text:find("已完成",1,true),"completed cached book needs no key or network and is not overwritten")
check(yields>0,"real UI wiring tolerates yielding progress callbacks")
plugin.sec_busy=true; local before=#shown
plugin:prepareTranslation(co.cik,filing.accn)
check(#shown==before+1 and shown[#shown].text:find("正在运行",1,true),"busy action is blocked")
plugin.sec_busy=false
local downloads=0; plugin.runJob=function() downloads=downloads+1 end
plugin:startDownload({co},{translate=true})
check(downloads==0,"old download entry cannot bypass translation confirmation")
plugin:startDownload({co})
check(downloads==1 and not plugin.sec_busy,"normal download wrapper still works")
plugin:showMessage(string.rep("中",100))
check(not shown[#shown].text:find("\239\191\189",1,true) and #shown[#shown].text % 3==0,"long result truncation keeps UTF-8 boundaries")
local selected_opts
plugin.startDownload=function(self,companies,opts) selected_opts=opts end
local prior=saves
plugin:startFilingDownload(co,filing)
check(selected_opts.selected_filing.accn==filing.accn and selected_opts.include_reports and saves==prior,"selecting a filing neither changes subscriptions nor downloads other filings")
selected_opts=nil
plugin:startFilingDownload(co,{accession_number=filing.accn,filing_date=filing.date,primary_document="report.htm",form="10-Q"})
check(selected_opts and selected_opts.selected_filing.accn==filing.accn and selected_opts.selected_filing.primary=="report.htm","real sec_search result field names reach exact-filing download")
local saved_estimate, saved_time = Lib.estimate, os.time
local before_yields=yields
os.time=function() return 1234567890 end
Lib.estimate=function(self,cik,accn,translator,progress)
    for i=1,1000 do assert(progress()) end
    return nil,"offline progress probe"
end
plugin:prepareTranslation(co.cik,filing.accn)
Lib.estimate,os.time=saved_estimate,saved_time
check(yields-before_yields==1 and not plugin.sec_busy,"one thousand local checks do not incur one thousand 100ms UI waits")
check(find(plugin:getSubMenuItems(),"存储与清理"),"main menu exposes explicit storage management")
assert(os.remove(r.original_path)); assert(os.remove(r.chinese_path))
-- New local repair actions never consult network or mutate account settings.
local missing_actions=plugin:getLocalTranslationItems()[1].sub_item_table_func()
check(find(missing_actions,"恢复原文") and find(missing_actions,"重新关联原文"),"missing original offers explicit recovery and relink")
plugin:prepareOriginalRecovery(co.cik,filing.accn)
local repair=shown[#shown]
check(repair.kind=="confirmbox" and not Files.fileExists(r.original_path),"recovery preview does not recreate a deleted original")
plugin.ui.document={file="open.epub"}; repair.ok_callback(); plugin.ui.document=nil
check(not Files.fileExists(r.original_path) and not plugin.sec_busy,"reader opening after confirmation blocks recovery")
local oldcalls,oldnetwork,oldsaves=calls,network,saves
plugin:prepareOriginalRecovery(co.cik,filing.accn); repair=shown[#shown]
repair.ok_callback(); repair.ok_callback()
check(Files.fileExists(r.original_path) and not plugin.sec_busy and calls==oldcalls and network==oldnetwork and saves==oldsaves,"confirmed offline repair runs once without settings or API writes")
local moved=plugin.sec_out_dir.."/moved.epub"; assert(os.rename(r.original_path,moved))
plugin:prepareRelink(co.cik,filing.accn,"en")
local chooser=shown[#shown]
check(chooser.kind=="menu" and #chooser.item_table==1,"relink exposes verified candidate chooser")
chooser.onMenuSelect(chooser,chooser.item_table[1]); local bind=shown[#shown]
check(bind.kind=="confirmbox" and assert(lib:load(co.cik,filing.accn)).original_path~=moved,"candidate selection still requires explicit confirmation")
bind.ok_callback(); bind.ok_callback()
check(assert(lib:load(co.cik,filing.accn)).original_path==moved and calls==oldcalls and network==oldnetwork and saves==oldsaves,"confirmed relink changes only local binding metadata")
assert(os.remove(moved))
local storage=plugin:getStorageItems()
check(find(storage,"检查到") and find(plugin:getLocalTranslationItems(),"文件位置待核对"),"external removal is discovered without displaying phantom pending translation")
local identity=r.paths.cik .. ":" .. r.paths.accn
local settings_before=saves; local requests_before=calls
plugin:prepareCleanup({identity},{remove_reading_data=true})
local cleanup=shown[#shown]
check(cleanup.kind=="confirmbox" and cleanup.text:find("不可撤销",1,true) and Files.fileExists(r.paths.source),"cleanup confirmation is inert and clearly names destructive action")
plugin.ui.document={file="another-open-book.epub"}
cleanup.ok_callback()
check(Files.fileExists(r.paths.source) and not plugin.sec_busy,"opening a book after confirmation blocks removal and releases busy flag")
plugin.ui.document=nil
plugin:prepareCleanup({identity},{remove_reading_data=true}); cleanup=shown[#shown]
cleanup.ok_callback(); cleanup.ok_callback()
check(not Files.fileExists(r.paths.source) and not plugin.sec_busy and saves==settings_before and calls==requests_before,"confirmed cleanup runs once, without API, settings or watchlist writes")
print(string.format("real main/translation UI: %d checks passed; widgets/network are offline adapters",n))
