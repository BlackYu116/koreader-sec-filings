-- Offline orchestration test: real sec_job/sec_translate/sec_watchlist/sec_filing.
-- SEC transport and EPUB packer are spies, NOT device/EPUB validation.
package.path = "./secfilings.koplugin/?.lua;" .. package.path
local root = assert(arg[1], "usage: luajit sec_translation_job_test.lua <fresh-test-dir>")
local source = {}
local filings = {
    {form="8-K", date="2026-10-01", accn="0001318605-26-000001"},
    {form="8-K", date="2026-10-02", accn="0001318605-26-000002"},
}
function source:recentFilings() return filings end
function source:filingContent(cik, filing)
    return { html="<p>" .. string.rep("Revenue 10 rose. ",20) .. "</p>",
        why="offline fixture", url="https://www.sec.gov/fixture" }
end
function source:cleanHtml(html) return html,{images=0} end
package.loaded["sec_source"] = source
package.loaded["sec_images"] = {}
package.loaded["sec_metrics"] = {}
package.loaded["logger"] = {info=function() end,warn=function() end}
local books = {}
package.loaded["sec_epub"] = {write=function(self,path,book)
    books[#books+1] = {path=path,book=book}
    -- Deliberately no zip substitute. Only record the orchestration result.
    local file=assert(io.open(path,"wb")); file:write("offline-packer-spy"); file:close()
    return true,nil,{}
end}
local T=require("sec_translate")
local calls=0
T._request=function(self,text) calls=calls+1; return text:gsub("Revenue","营收"):gsub("rose","增长") end
local Job=require("sec_job")
local count=0
local function check(ok,label) count=count+1; assert(ok,label); print("PASS " .. label) end
local function options(name)
    return {single_filing=true,limit=2,out_dir=root .. "/" .. name,work_dir=root .. "/" .. name .. "-work",
        source=source,fetch_images=false,metrics_chapter=false,user_email="test@example.invalid",
        translate=true,deepseek_api_key="offline-test-key",translation_max_files=1}
end
local companies={{cik=1318605,name="特斯拉"}}
local r,e,info=Job.run(companies,options("first"))
check(#r==2 and #e==0,"two original filings complete")
check(r[1].chinese_path and not r[2].chinese_path and #books==3,"default one translated filing cap")
check(#r[2].warnings==1,"file cap is visible in warnings")
check(calls==1,"one real translator dispatch through fake wire")
check(books[1].book.chapters[1].html:find("Revenue",1,true) and books[2].book.chapters[1].html:find("营收",1,true),"translation never mutates original book")
check(r[1].path~=r[2].path and r[1].path:find("特斯拉 [CIK 0001318605]",1,true),"per-accession output and company directory")
local second=options("first"); second.translation_cache_only=true; second.deepseek_api_key=""
local rr,ee=Job.run(companies,second)
check(rr[1].chinese_path and #ee==0 and calls==1,"completed book reused through job without key or original rewrite")
local cancelled=options("cancelled")
local cr,ce,ci=Job.run(companies,cancelled,function(msg) return not msg:find("正在翻译",1,true) end)
check(ci.cancelled and #cr==1 and not cr[1].chinese_path and calls==1,"cancel ends batch while retaining first original")
local capped=options("capped"); capped.work_dir=root .. "/uncached"; capped.translation_max_requests=0
local br,be=Job.run(companies,capped)
check(#br==2 and #be==1 and calls==1 and not br[1].chinese_path,"zero request budget preserves originals and incurs no call")
local Files=require("sec_watchlist")
local wl=Files.new({seed_defaults=false})
assert(Files.add(wl,{cik=1318605,name="特斯拉",forms={"8-K"}}))
local baseline=options("baseline"); baseline.translate=false; baseline.limit=1; baseline.first_run_new=1; baseline.watchlist=wl
local base_results,base_errors=Job.run(companies,baseline)
local entry=Files.find(wl,1318605)
check(#base_results==1 and #base_errors==0 and entry.seen_upto_date=="2026-10-02" and entry.first_run_done,"successful first-run originals commit date baseline")
local repeat_results,repeat_errors=Job.run(companies,baseline)
check(#repeat_results==0 and #repeat_errors==0,"second run does not backfill older history")
local broken_source=source.recentFilings
source.recentFilings=function() return nil,"offline metadata failure" end
local failed_results,failed_errors=Job.run(companies,options("metadata-failure"))
check(#failed_results==0 and #failed_errors==1 and failed_errors[1]:find("metadata failure",1,true),"metadata plan failure is not silently reported as empty success")
source.recentFilings=broken_source
local partial=Files.new({seed_defaults=false}); assert(Files.add(partial,{cik=1318605,name="特斯拉",forms={"8-K"}}))
local partial_opts=options("partial"); partial_opts.translate=false; partial_opts.watchlist=partial
local content=source.filingContent
source.filingContent=function(self,cik,filing)
    if filing.accn==filings[1].accn then return nil,"forced body failure" end
    return content(self,cik,filing)
end
local pr,pe=Job.run(companies,partial_opts)
local partial_entry=Files.find(partial,1318605)
check(#pr==1 and #pe==1 and not partial_entry.seen_upto_date and #partial_entry.seen==1,"partial download only marks completed original, without advancing baseline")
source.filingContent=content
local recovered_results,recovered_errors=Job.run(companies,partial_opts)
check(#recovered_results==1 and #recovered_errors==0,"partial download retries missing original")
local stale=options("stale-assets"); stale.translate=false
local Filing=require("sec_filing")
local old_dir=Filing.workPath(stale.work_dir,companies[1],filings[1]) .. "/images"
assert(Files.ensureDir(old_dir)); local old_file=assert(io.open(old_dir .. "/interrupted.png","wb")); old_file:write("preserved"); old_file:close()
local stale_results,stale_errors=Job.run(companies,stale)
check(#stale_results==2 and #stale_errors==0 and Files.fileExists(old_dir .. "/interrupted.png"),"images left by interrupted download do not block retry with images disabled")
local stored=assert(require("sec_library"):new(stale):existing(companies[1].cik,filings[1].accn))
check(stored.book.images_dir~=old_dir and #stored.book.images==0,"new original snapshot uses isolated attempt assets")
local explicit=options("explicit"); explicit.translate=false; explicit.watchlist=wl; explicit.selected_filing=filings[1]
local saved_recent=source.recentFilings
source.recentFilings=function() error("explicit selection must not fetch recent metadata") end
local one,one_errors=Job.run(companies,explicit)
source.recentFilings=saved_recent
check(#one==1 and #one_errors==0 and one[1].accession==filings[1].accn,"explicit search download selects exactly one accession even before baseline")
check(Files.find(wl,1318605).seen_upto_date=="2026-10-02","explicit historical download never changes incremental baseline")
check(books[#books].book.identifier:find(filings[1].accn,1,true),"original EPUB gets stable filing identifier")
print(string.format("translation job: %d checks passed; packer/SEC transport are spies",count))
