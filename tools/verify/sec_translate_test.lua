-- Offline regression tests. No HTTP or real credentials are used.
-- Run from source/repository root. Supply an EXISTING empty temp directory as arg[1].
-- Requires KOReader ffi/sha2.lua on LUA_PATH (pure Lua; no device substitute).
package.path = "./secfilings.koplugin/?.lua;" .. package.path
local T = require("sec_translate")
local cache_dir = assert(arg[1], "usage: luajit sec_translate_test.lua <empty-cache-dir>")
local count = 0
local function check(condition, label)
    count = count + 1
    assert(condition, "FAIL " .. label)
    print("PASS " .. label)
end
local function new(opts)
    opts = opts or {}
    if opts.api_key == nil then opts.api_key = "offline-test-key" end
    if opts.transport == nil then
        opts.transport = function(text) return (text:gsub("Revenue", "营收"):gsub("rose", "增长")) end
    end
    return T:new(opts)
end
local function rejected(text, response, label)
    local tr = new({ transport = function() return response end })
    local out = tr:translateText(text)
    check(out == nil and tr.request_count == 1, label)
end
local no_key = new({api_key=""})
check(no_key:translateText("Revenue 12.5%") == nil and no_key.request_count == 0, "missing key blocks dispatch")
local captured
local tr = new({transport=function(text) captured=text; return text:gsub("Revenue", "营收") end})
local source = "Revenue $1,234.50 12.5% 2026-09-30 TSLA 0001318605-26-000123 https://sec.gov/a1 &amp;"
local out = tr:translateText(source)
check(out == source:gsub("Revenue", "营收"), "financial tokens round-trip through real protection")
check(not captured:find("PROTECTED",1,true) and not captured:find("1,234",1,true), "inserted placeholders are never protected recursively")
rejected("Revenue 10 20", "营收 SECX1X SECX1X", "duplicate marker rejected")
rejected("Revenue 10 20", "营收 SECX1X", "missing marker rejected")
rejected("Revenue 10 20", "营收 SECX2X SECX1X", "reordered values rejected")
rejected("Revenue 10", "营收 SECX1X 999", "new numeric value rejected")
rejected("Revenue 10", "营收 SECX01X", "noncanonical marker rejected")
rejected("Revenue 10", "营收 -SECX1X", "invented negative sign rejected")
rejected("Revenue (10)", "营收 SECX2X", "accounting parentheses cannot disappear")
check(new():translateText("Revenue € 10 £ 20 ¥ 30 −40") == "营收 € 10 £ 20 ¥ 30 −40", "currency and Unicode minus preserved")
check(new({transport=function() return "营收" end}):translateText(" Revenue \n") == " 营收 \n", "node boundary whitespace preserved")
rejected("Revenue 10", "<b>营收 SECX1X</b>", "model markup rejected")
rejected("Revenue", "```text\n营收\n```", "code fences rejected")
rejected("Revenue", "营收\1", "XML control characters rejected")
local literal = "Revenue SECX1X"
check(new():translateText(literal) == "营收 SECX1X", "source resembling marker remains literal")
check(new():translateText("Revenue &amp; A&amp;B") == "营收 &amp; A&amp;B", "original entities preserved")
check(new({transport=function() return "营收 & 利润" end}):translateText("Revenue") == "营收 &amp; 利润", "model ampersand escaped")
local numeric = new()
check(numeric:translateHtml("<td>$1,234.50</td><td>中文</td><td>TSLA</td>") == "<td>$1,234.50</td><td>中文</td><td>TSLA</td>" and numeric.request_count == 0, "numeric and Chinese cells need no requests")
check(new():translateHtml("<p>Revenue</p>Revenue") == "<p>营收</p>营收", "trailing text is translated")
local html = '<p title="a > b">Revenue <b>12.5%</b> rose.</p><!-- Revenue > -->'
check(new():translateHtml(html) == '<p title="a > b">营收 <b>12.5%</b> 增长.</p><!-- Revenue > -->', "quoted delimiters and comments preserved")
check(new():translateHtml('<p title="broken>Revenue') == nil, "unterminated tag rejected")
check(new():translateHtml('<script>Revenue</script>') == nil, "active content rejected")
local unicode = "<p>Revenue 中文甲乙 Revenue 中文丙丁 Revenue</p>"
check(new({max_chars=12}):translateHtml(unicode) == unicode:gsub("Revenue","营收"), "UTF-8 boundaries and spaces preserved")
check(new({max_chars=8}):translateHtml("<p>https://example.org/verylong</p>") == nil, "oversize indivisible token fails closed")
local cancelled = new()
check(cancelled:translateHtml("<p>Revenue</p>", function() return false end) == nil and cancelled.request_count == 0, "cancel checked before request")
local bounded = new({max_requests=1})
check(bounded:translateText("Revenue") == "营收", "first allowed request succeeds")
check(bounded:translateText("Revenue again") == nil and bounded.request_count == 1, "request cap prevents next dispatch")
local bytes = new({max_input_bytes=1})
check(bytes:translateText("Revenue") == nil and bytes.request_count == 0, "input byte cap blocks dispatch")
local failure = new({transport=function() return nil, "offline failure" end})
check(failure:translateText("Revenue") == nil and failure.request_count == 1, "failed attempt counted")
check(failure:translateText("Revenue again") == nil and failure.request_count == 1, "failed session stops further charges")
check(new({endpoint="http://api.deepseek.com/chat/completions"}):translateText("Revenue") == nil, "plaintext endpoint rejected")
check(new({endpoint="https://unrelated.example/api"}):translateText("Revenue") == nil, "unapproved key destination rejected")
check(new({api_key="bad\nkey"}):translateText("Revenue") == nil, "header injection rejected")

local cold = new({cache_dir=cache_dir})
check(cold:translateText("Revenue 10") == "营收 10" and cold.request_count == 1, "cold cache writes validated block")
check(cold:translateText("Revenue 10") == "营收 10" and cold.cache_hits == 1 and cold.request_count == 1, "same block not billed twice")
local resume = new({cache_dir=cache_dir,api_key="",cache_only=true})
check(resume:translateText("Revenue 10") == "营收 10" and resume.request_count == 0, "new process object resumes without key")
check(resume:translateText("Revenue 11") == nil, "changed source misses cache")
check(new({cache_dir=cache_dir,cache_only=true,model="other-model"}):translateText("Revenue 10") == nil, "model invalidates cache")
check(new({cache_dir=cache_dir,cache_only=true,thinking=true}):translateText("Revenue 10") == nil, "thinking config invalidates cache")
local version = new({cache_dir=cache_dir,cache_only=true}); version.prompt_version=999
check(version:translateText("Revenue 10") == nil, "prompt version invalidates cache")
-- Corrupt a known entry; cache data must be revalidated, never executed.
local fields={"2",T.default_endpoint,T.default_model,"no-thinking","zh-CN","Revenue 10"}
for i=1,#fields do fields[i]=#fields[i] .. ":" .. fields[i] end
local key=require("ffi/sha2").sha256(table.concat(fields))
local cachefile=cache_dir .. "/" .. key .. ".cache"
local f=assert(io.open(cachefile,"wb")); f:write("SEC-TRANSLATION-2\n",key,"\n营收 999"); f:close()
check(resume:translateText("Revenue 10") == nil and resume.request_count == 0, "corrupt cached numeric data rejected")
local temp=assert(io.open(cachefile .. ".tmp","wb")); temp:write("incomplete"); temp:close()
check(new({cache_dir=cache_dir}):translateText("Revenue 10") == "营收 10", "interrupted temporary cache is ignored and replaced")
local broken = new({cache_dir=cache_dir .. "/not-created"})
check(broken:translateText("Revenue") == nil and broken.request_count == 1, "cache write failure surfaced")
check(broken:translateText("Revenue again") == nil and broken.request_count == 1, "disk failure stops subsequent requests")
local system = new({cache_dir="/usr/cache"})
check(system:translateText("Revenue") == nil and system.request_count == 0, "rootfs cache path refused")
check(new({cache_dir="/mnt/us/../../etc"}):translateText("Revenue") == nil, "cache traversal refused")
-- An interrupted two-block run must reuse the first block on resume.
local partial = new({cache_dir=cache_dir,max_chars=12,max_requests=1})
local long = "<p>Revenue one Revenue two Revenue three</p>"
check(partial:translateHtml(long) == nil and partial.request_count == 1, "interrupted document caches completed block")
local continued = new({cache_dir=cache_dir,max_chars=12})
check(continued:translateHtml(long) == long:gsub("Revenue","营收") and continued.cache_hits == 1, "resumed document uses completed block")

-- Exercise production _request with fake wire I/O, not a substitute translation engine.
local payload, wire, response, status, bad_json
local http = {TIMEOUT=17}
package.loaded["json"] = {
    encode=function(value) payload=value; return "request-body" end,
    decode=function() if bad_json then error("malformed") end; return response end,
}
package.loaded["ltn12"] = {source={string=function(body) return body end}}
http.request=function(req)
    wire=req
    req.sink("response-body")
    return 1,status
end
package.loaded["socket.http"] = http
local function wireRun()
    return T:new({api_key="offline-test-key"}):translateText("Revenue")
end
status=200; response={choices={{finish_reason="stop",message={content="营收"}}}}
check(wireRun() == "营收", "production adapter decodes successful response")
check(payload.thinking.type == "disabled" and payload.max_tokens == 4096 and payload.temperature == nil, "bounded non-thinking payload")
check(wire.redirect == false and http.TIMEOUT == 17, "redirect disabled and timeout restored")
status=401
check(wireRun() == nil, "authentication failure not accepted")
status=302
check(wireRun() == nil, "redirect response not accepted")
status=200; bad_json=true
check(wireRun() == nil, "invalid JSON becomes error return")
bad_json=false; response={choices={{finish_reason="length",message={content="营收"}}}}
check(wireRun() == nil, "truncated completion rejected")
response={choices={{finish_reason="stop",message={content="营收"}}}}
http.request=function(req) req.sink(string.rep("x",262145)); return nil,"sink error" end
check(wireRun() == nil and http.TIMEOUT == 17, "response byte cap and timeout restoration")
print(string.format("translation regression: %d checks passed; no network requests",count))
