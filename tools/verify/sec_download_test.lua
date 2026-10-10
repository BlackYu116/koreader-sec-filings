-- Offline regression: real source/table and image modules; no network or native UI.
package.path = './secfilings.koplugin/?.lua;' .. package.path
local root = assert(arg[1], 'fresh sandbox required')
package.loaded['socket.http'] = {request=function() error('network forbidden') end}
package.loaded['ltn12'] = {}
package.loaded['logger'] = {info=function() end, warn=function() end}
local Source = require('sec_source')
local Images = require('sec_images')
local count = 0
local function check(ok, label) count=count+1; assert(ok,label); print('PASS '..label) end
local narrow = '<table><tr><td>Revenue</td><td>10</td></tr></table>'
local src = Source:new{table_avail_em=100}
local output, stats = src:splitWideTables(narrow)
check(output==narrow and stats.tables==1, 'narrow table is preserved and parsed once')
local nested = '<table><tr><td><table><tr><td>Revenue</td><td>10</td></tr></table></td></tr></table>'
local result = src:splitWideTables(nested)
check(result==nested, 'nested narrow table bytes preserved')
local wide = '<table><tr><td>Long revenue heading</td><td>123456789</td><td>987654321</td><td>555555555</td></tr></table>'
local projected, pstats = Source:new{table_avail_em=10}:splitWideTables(wide)
check(pstats.split>0 and projected:find('123456789',1,true) and projected:find('987654321',1,true) and projected:find('555555555',1,true), 'wide table projection retains all numeric columns')
local fetched = 0
local function plan()
    return {items={{id='a',src='https://www.sec.gov/a.png'},{id='b',src='https://www.sec.gov/b.png'}},stats={},log={},dir_abs=root}
end
local ok, err = Images:fetchAll(plan(), {throttle_ms=0, on_progress=function() return false end,
    fetch=function() fetched=fetched+1; return false,'fixture' end})
check(not ok and err=='cancelled' and fetched==0, 'cancel before first image sends no request')
local p=plan()
ok,err=Images:fetchAll(p,{throttle_ms=0,on_progress=function(i) return i<2 end,
    fetch=function() fetched=fetched+1; return false,'fixture' end})
check(not ok and err=='cancelled' and fetched==1, 'cancel between images prevents later requests')
local finalized=false
local instance=setmetatable({finalize=function() finalized=true; return '' end},{__index=Images})
local r,e=instance:run('<img src="a.png"/>','https://www.sec.gov/report.htm',{
    user_agent='test@example.invalid',dir=root,throttle_ms=0,on_progress=function() return false end,
    fetch=function() error('cancelled image fetched') end})
check(not r and e=='cancelled' and not finalized, 'cancelled image run never finalizes a partial book')
print(string.format('download: %d checks passed; offline transports only',count))
