-- Real sec_epub + ffi/archiver; caller supplies KOReader environment or explicit host adapters.
-- API translation is deterministic fake text. Use a NEW isolated user-data directory.
package.path="./secfilings.koplugin/?.lua;" .. package.path
local root=assert(arg[1],"fresh isolated test directory required")
local Files=require("sec_watchlist")
local Filing=require("sec_filing")
local Library=require("sec_library")
local Epub=require("sec_epub")
local opts={work_dir=root .. "/work",out_dir=root .. "/books",deepseek_api_key="offline-fixture"}
local lib=Library:new(opts)
local co={cik=320193,name="Fixture Company"}
local filing={accn="0000320193-26-000001",form="10-Q",date="2026-10-01"}
local legacy=Filing.workPath(opts.work_dir,co,filing) .. "/images"
assert(Files.ensureDir(legacy))
local leftover=assert(io.open(legacy .. "/interrupted.png","wb")); leftover:write("do-not-package"); leftover:close()
local dir=assert(lib:beginOriginal(co,filing))
assert(Files.ensureDir(dir .. "/images"))
assert(Files.ensureDir(opts.out_dir .. "/" .. Filing.companyDir(co)))
-- A valid 1x1 PNG, only a manifest/byte-retention fixture, not a visual design image.
local png="\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\001\000\000\000\001\008\006\000\000\000\031\021\196\137\000\000\000\011\073\068\065\084\120\156\099\096\000\002\000\000\005\000\001\122\094\171\063\000\000\000\000\073\069\078\068\174\066\096\130"
local f=assert(io.open(dir .. "/images/chart.png","wb")); f:write(png); f:close()
local cover=assert(io.open(dir .. "/images/cover.png","wb")); cover:write(png); cover:close()
local paragraph='<p>Revenue was $1,234.50 &amp; Assets were 200 in 2026.</p>'
local html=string.rep(paragraph,80) .. '<table><tr><th>Revenue</th><th>2026</th></tr><tr><td>Profit</td><td style="text-align: right">(500)</td></tr></table><p><img src="images/chart.png" alt="Chart"/></p>'
local book={title="Quarterly Filing",language="en",identifier="urn:sec:fixture:en",chapters={{id="one",heading="Quarterly results",html=html}},
    images={{href="images/chart.png",mediaType="image/png"}},images_dir=dir .. "/images",
    cover={href="images/cover.png",mediaType="image/png"}}
local original=Filing.outputPath(opts.out_dir,co,filing,"en")
assert(Epub:write(original,book))
local record=assert(lib:register(co,filing,book))
local translator=lib:translator(opts)
local calls=0
translator.transport=function(text)
    calls=calls+1
    return text:gsub("Revenue","营收"):gsub("Assets","资产"):gsub("Profit","利润")
        :gsub("was","为"):gsub("were","为"):gsub("in","在")
end
local stats=assert(lib:estimate(co.cik,filing.accn,translator))
assert(stats.requests==3,"repeated paragraph estimated only once")
local path=assert(lib:translate(co.cik,filing.accn,translator))
assert(calls==3,"cached repeated paragraphs dispatch only once")
assert(Files.readFile(original)~=Files.readFile(path),"independent language files")
-- Reconstruct with the REAL archiver, not the unit-test writer. Preserve both sidecars.
local source_before=assert(Files.readFile(record.paths.source))
local state_before=assert(Files.readFile(record.paths.state))
local chinese_before=assert(Files.readFile(path))
local backup=assert(io.open(root.."/original-before-recovery.zip","wb"))
assert(backup:write(assert(Files.readFile(original)))); assert(backup:close())
for i,bookpath in ipairs({original,path}) do
    assert(Files.ensureDir(bookpath..".sdr"))
    local progress=assert(io.open(bookpath..".sdr/metadata.epub.lua","wb"))
    progress:write("return {page=8}"); progress:close()
end
assert(os.remove(original))
assert(lib:restoreOriginal(assert(lib:previewOriginalRecovery(co.cik,filing.accn))))
assert(lib:verify(assert(lib:load(co.cik,filing.accn))))
assert(Files.readFile(record.paths.source)==source_before)
assert(Files.readFile(record.paths.state)==state_before)
assert(Files.readFile(path)==chinese_before)
for i,bookpath in ipairs({original,path}) do
    assert(Files.readFile(bookpath..".sdr/metadata.epub.lua")=="return {page=8}")
end
print("PASS real EPUB original reconstruction; source/state/Chinese/reading records preserved")
print("ORIGINAL=" .. original)
print("CHINESE=" .. path)
print("PASS real EPUB pair generated; fixture API calls=3; host/device environment must be reported separately")
