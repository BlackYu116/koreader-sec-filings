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
-- Existing lexical hyphens are not invented accounting minus signs.
check(new({transport=function(text) return text end}):translateText('us-gaap')=='us-gaap',
    'explicit taxonomy identifier is preserved without translation')
for _,word in ipairs({"non-GAAP", "year-over-year"}) do
    check(new({transport=function(text) return '中文 ' .. text end}):translateText(word)=='中文 ' .. word,
        "original lexical hyphen accepted alongside translated prose: "..word)
    check(not new({transport=function(text) return text end}):translateText(word),
        "English-only lexical response is not a completed translation: "..word)
end
check(new({transport=function() return "同比" end}):translateText("year-over-year")=="同比",
    "lexical hyphen may disappear when word is translated")
check(new({transport=function(text) return text end}):translateText("已取到 8 / 8 个指标 ｜ 数据来源 us-gaap（USD） ｜ 单位见各表表头")
    =="已取到 8 / 8 个指标 ｜ 数据来源 us-gaap（USD） ｜ 单位见各表表头", "actual Apple metrics blocker round-trips")
rejected("Revenue 10 us-gaap", "营收 -SECX1X us-gaap", "lexical exemption cannot hide new negative value")
rejected("Revenue 10 us-gaap", "营收 SECX1X loss-making", "new hyphenated word not exempted")
rejected("Revenue 10 us-gaap", "营收 SECX1X us-gaap-", "new trailing minus not exempted")
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

local month_source='For the quarterly period ended June 28 2026'
local month_bad=new{transport=function()return '截至6月 SECX1X 日（SECX2X）的季度期间' end}
check(not month_bad:translateText(month_source),'real month-name conversion cannot introduce numeric 6')
local month_good=new{transport=function()return '截至六月 SECX1X SECX2X 的季度期间' end}
check(month_good:translateText(month_source)=='截至六月 28 2026 的季度期间','spelled-out month preserves numeric placeholder order')
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
local long = "<p>Revenue 71 Revenue 72 Revenue 73</p>"
check(partial:translateHtml(long) == nil and partial.request_count == 1, "interrupted document caches completed block")
local continued = new({cache_dir=cache_dir,max_chars=12})
check(continued:translateHtml(long) == long:gsub("Revenue","营收") and continued.cache_hits == 1, "resumed document uses completed block")

-- Legacy read-through remains free and read-only until an explicit execution.
local owned=cache_dir .. "/owned-not-created"
local migration=new({cache_dir=owned,legacy_cache_dir=cache_dir,cache_only=true,api_key=""})
local estimate=assert(migration:estimate({{html="<p>Revenue 10</p>"}}))
check(estimate.requests==0 and estimate.cache_hits==1 and not require("libs/libkoreader-lfs").attributes(owned), "legacy estimate never creates the filing cache")
local moved,migration_error=migration:translateText("Revenue 10")
check(not moved and migration.request_count==0 and migration_error:find("缓存",1,true), "legacy promotion disk failure makes no paid request")
local changed=new({cache_dir=owned,legacy_cache_dir=cache_dir,cache_only=true,model="different"})
check(changed:translateText("Revenue 10")==nil and changed.request_count==0, "legacy cache remains separated by model")
assert(require("sec_watchlist").ensureDir(owned))
check(migration:translateText("Revenue 10")=="营收 10" and migration.request_count==0, "legacy promotion retries into an existing filing directory without a key")

local metrics={id="metrics_0000320193",company_id="co_0000320193",heading="公司最新指标快照（非本份申报）",html="<p>中文说明 us-gaap Revenue 10</p>"}
local skip=new({transport=function() error("generated metrics must not be sent") end})
check(skip:translateChapter(metrics)==metrics.html and skip.request_count==0, "generated Chinese metrics preserved without billing")
check(skip:estimate({metrics}).requests==0, "preflight matches generated chapter execution")
check(skip:translateChapter(metrics,function() return false end)==nil, "preserved chapter still supports cancellation")
local ordinary={id="metrics_0000320193",company_id="co_0000320193",heading="Ordinary filing",html="<p>Revenue 10</p>"}
check(new():translateChapter(ordinary)=="<p>营收 10</p>", "metrics-like id alone does not suppress translation")
check(T.failureSummary("DeepSeek 请求失败（HTTP 429）；未自动重试"):find("429",1,true)~=nil, "controlled HTTP status may be persisted")
check(not T.failureSummary("token=SECRET https://private.invalid"):find("SECRET",1,true), "untrusted transport details never persisted")
check(T.failureSummary("译文修改、遗漏、重排或新增了受保护数字/标记")=="译文修改、遗漏、重排或新增了受保护数字/标记", "validation failure remains actionable")

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
local truncated_out,truncated_err=wireRun()
check(truncated_out==nil and truncated_err:find('4096',1,true) and truncated_err:find('未自动重试',1,true), "truncated completion rejected with actionable limit")
local thinking=T:new{api_key='offline-test-key',thinking=true}
local thinking_out,thinking_err=thinking:translateText('Revenue')
check(not thinking_out and thinking_err:find('16384',1,true) and payload.max_tokens==16384, 'thinking gets bounded shared reasoning/output budget')
check(T:new{thinking=true,max_output_tokens=256}.max_output_tokens==256 and T:new{thinking=true,max_output_tokens=999999}.max_output_tokens==16384, 'explicit output budget respected and clamped')
check(T.failureSummary(thinking_err)==thinking_err,'controlled output-limit detail survives persistence and UI')
check(not T.failureSummary(thinking_err..' secret-provider-body'):find('secret',1,true),'output-limit whitelist cannot reflect appended provider data')
check(payload.messages[1].content:find('六月',1,true) and payload.messages[1].content:find('opaque',1,true), 'prompt spells out months and opaque placeholder contract')
response={choices={{finish_reason="stop",message={content="营收"}}}}
http.request=function(req) req.sink(string.rep("x",262145)); return nil,"sink error" end
check(wireRun() == nil and http.TIMEOUT == 17, "response byte cap and timeout restoration")
http.request=function() error('secret-provider-response') end
local thrown=T:new({api_key='offline-test-key'})
local ok,result,err=pcall(function() return thrown:translateText('Revenue') end)
check(ok and not result and http.TIMEOUT==17,'thrown HTTP restores timeout and becomes safe error')
check(err and not err:find('secret-provider',1,true) and thrown.request_count==1,'exception counts one attempt without provider disclosure')
check(thrown:translateText('Revenue again')==nil and thrown.request_count==1,'HTTP exception stops later attempts')
local oversized=new({transport=function() return string.rep('x',262100) end})
check(oversized:translateText('Revenue')==nil and oversized.stopped~=nil,'oversize response is sticky stopped')
http.request=function(req) wire=req;req.sink('response-body');return 1,200 end
response={choices={{finish_reason='stop',message={content='营收'}}}}
check(T:new({api_key='offline-test-key',thinking=true}):translateText('Revenue')=='营收' and payload.thinking.type=='enabled' and payload.reasoning_effort=='high','thinking preferences preserved on wire without live API')
local marks=T:new{transport=function() error('trademark must not dispatch') end}
for _,mark in ipairs({'iPhone','Mac','iPad','iPhone®','Mac®','iPad®','Brand™','Mac&reg;','Mac&#174;','Mac&#xAE;','Brand&trade;','Brand&#8482;','Brand&#x2122;'}) do
    check(marks:translateText(mark)==mark and marks.request_count==0,'standalone marked trademark stays literal: '..mark)
end
local _,inline_tokens=T._batch.protect('iPhone® Revenue $100')
check(inline_tokens.requires_language and #inline_tokens==1 and inline_tokens[1]=='$100','trademark prose keeps language validation and existing numeric token identity')
local echo_mark=T:new{transport=function(text) return text end}
check(echo_mark:translateText('iPhone® revenue increased')==nil,'trademark in a sentence cannot bypass untranslated-echo rejection')
for _,prose in ipairs({'iPhone revenue increased','Mac net sales decreased','iPad $100','MAC','IPHONE','IPAD','Revenue','iPhones'}) do
    local _,tokens=T._batch.protect(prose)
    check(tokens.requires_language,'unmarked brand exemption is exact, not prose: '..prose)
end
-- Transport failure classes: presend failures retry safely, others never retry.
response={choices={{finish_reason='stop',message={content='营收'}}}}
local call_count,script_rows
http.request=function(req)
    call_count=call_count+1
    local row=script_rows[call_count]
    if row then return nil,row end
    req.sink('response-body'); return 1,200
end
local function scriptedTransport(rows)
    call_count=0; script_rows=rows
    return T:new({api_key='offline-test-key'})
end
local dns_inst=scriptedTransport({'Host not found: api.deepseek.com key=sk-MOCK','DNS resolver step 2','dns lookup failed'})
local dns_out,dns_err=dns_inst:translateText('Revenue')
check(dns_out==nil and call_count==3 and dns_err:find('域名解析失败',1,true) and dns_err:find('已尝试 3 次连接',1,true),'dns failures retried exactly 3 times then classified')
check(not dns_err:find('MOCK',1,true) and not dns_err:find('resolver',1,true),'transport error text never reflected to caller')
check(http.TIMEOUT==17,'timeout restored after dns retries')
check(T.failureSummary(dns_err)==dns_err,'dns classification survives persistence whitelist')
local refused_inst=scriptedTransport({'Socket connect failed: connection refused'})
check(refused_inst:translateText('Revenue')=='营收' and call_count==2,'presend connect failure recovers on retry without double dispatch')
local timeout_inst=scriptedTransport({'timeout'})
local timeout_out,timeout_err=timeout_inst:translateText('Revenue')
check(timeout_out==nil and call_count==1 and timeout_err:find('传输超时',1,true) and timeout_err:find('未自动重试',1,true),'response timeout never retried')
check(T.failureSummary(timeout_err)==timeout_err,'timeout classification whitelisted')
check(T.failureSummary('DeepSeek 传输超时（上限 45 秒）；未自动重试')~='DeepSeek 传输超时（上限 45 秒）；未自动重试','out-of-range timeout text cannot smuggle through whitelist')
local reset_inst=scriptedTransport({'connection reset by peer'})
check(reset_inst:translateText('Revenue')==nil and call_count==1,'connection reset never retried')
check(T.failureSummary('DeepSeek 连接被重置；未自动重试')=='DeepSeek 连接被重置；未自动重试','reset classification whitelisted')
local tls_inst=scriptedTransport({'SSL certificate verify failed'})
check(tls_inst:translateText('Revenue')==nil and call_count==1,'tls failure never retried')
local closed_inst=scriptedTransport({'closed'})
check(closed_inst:translateText('Revenue')==nil and call_count==1,'closed connection never retried')
check(T:new{thinking=true}.timeout==120 and T:new{}.timeout==90,'thinking sessions default to 120s receive timeout')
print(string.format("translation regression: %d checks passed; no network requests",count))
