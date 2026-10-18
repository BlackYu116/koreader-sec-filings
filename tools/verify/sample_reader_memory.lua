-- Bounded Linux /proc sampler for a real production ReaderUI PID.
-- Run ONLY during the batch; stop and verify exit BEFORE any sleep test.
-- No network, powerd calls, timers in ReaderUI, smaps, or forced GC.
-- Usage (from KOReader): ./luajit /path/sample_reader_memory.lua PID /mnt/us/secfilings-test-<id>/rss.tsv [seconds]
local pid=assert(tonumber(arg[1]),'ReaderUI PID required')
assert(pid>1 and pid%1==0)
local output=assert(arg[2],'explicit test-stage output required')
assert(output:match('^/mnt/us/secfilings%-test%-[%w%-]+/') and not output:find('..',1,true),'unsafe output path')
local duration=tonumber(arg[3]) or 3600
assert(duration>=1 and duration<=7200,'duration must be 1..7200 seconds')
local ffi=require('ffi')
ffi.cdef([[
int usleep(unsigned int usec);
struct sec_sample_timespec { long tv_sec; long tv_nsec; };
int sec_sample_clock_gettime(int, struct sec_sample_timespec *) __asm__("clock_gettime");
]])
local clocklib=ffi.C
if not pcall(function() return clocklib.sec_sample_clock_gettime end) then clocklib=ffi.load('rt') end
local stamp=ffi.new('struct sec_sample_timespec[1]')
local function monotonic()
 assert(clocklib.sec_sample_clock_gettime(1,stamp)==0,'monotonic clock unavailable')
 return tonumber(stamp[0].tv_sec)+tonumber(stamp[0].tv_nsec)/1e9
end
local function read(path)
 local f=io.open(path,'r');if not f then return nil end
 local s=f:read('*a');f:close();return s
end
local prefix='/proc/'..pid..'/'
assert((read(prefix..'cmdline') or ''):find('reader.lua',1,true),'PID is not a reader.lua process')
local function identity()
 local s=read(prefix..'stat');if not s then return nil end
 local tail=s:match('^%d+ %b() (.*)');if not tail then return nil end
 local fields={};for v in tail:gmatch('%S+') do fields[#fields+1]=v end
 return fields[20],fields[1],fields[12],fields[13]
end
local start=assert(identity(),'process identity unavailable')
local existing=io.open(output,'rb');if existing then existing:close();error('refuse to overwrite sample log') end
local out=assert(io.open(output,'wx'))
out:write('# pid=',pid,' starttime=',start,' duration=',duration,' seconds\n')
out:write('time\tseq\trss_kib\thwm_kib\tvmsize_kib\tmemavailable_kib\tmemfree_kib\tcached_kib\tbuffers_kib\tswapfree_kib\tstate\tutime\tstime\n')
local began=monotonic();local seq=0;local reason='duration_limit'
while monotonic()-began<duration do
 local current,state,utime,stime=identity()
 if current~=start or state=='Z' then reason='process_exited_or_changed';break end
 local status=read(prefix..'status') or ''
 local memory=read('/proc/meminfo') or ''
 local function value(text,name) return ('\n'..text):match('\n'..name..':%s*(%d+)') or 'na' end
 out:write(table.concat({os.time(),seq,value(status,'VmRSS'),value(status,'VmHWM'),value(status,'VmSize'),
  value(memory,'MemAvailable'),value(memory,'MemFree'),value(memory,'Cached'),value(memory,'Buffers'),value(memory,'SwapFree'),state,utime,stime},'\t'),'\n')
 out:flush();seq=seq+1
 if read(output..'.stop') then reason='stop_requested';break end
 ffi.C.usleep(1000000)
end
out:write('# end time=',os.time(),' reason=',reason,' samples=',seq,'\n');out:close()
print('Sampler exited: '..reason..'; samples='..seq)
