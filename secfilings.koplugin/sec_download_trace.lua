-- Small synchronous stage markers. No timers, network, power renewal or GC.
-- Linux RSS/HWM includes native allocations; Lua heap alone does not.
local logger = require('logger')
local Trace = {}
local function safe(v) return tostring(v or '-'):gsub('[%c%s]','?') end
function Trace.mark(stage, edge, company, accession, bytes)
    local status = ''
    local f = io.open('/proc/self/status','r')
    if f then status=f:read('*a') or '';f:close() end
    local function field(name) return status:match('\n'..name..':%s*(%d+)') or 'na' end
    logger.info(string.format('secfilings: trace time=%d pid=%s cik=%s accession=%s stage=%s edge=%s lua_kib=%.1f rss_kib=%s hwm_kib=%s bytes=%s',
        os.time(),field('Pid'),safe(company and company.cik),safe(accession),safe(stage),safe(edge),
        collectgarbage('count'),field('VmRSS'),field('VmHWM'),tostring(tonumber(bytes) or 0)))
end
return Trace
