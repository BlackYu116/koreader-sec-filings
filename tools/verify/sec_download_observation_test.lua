-- Deterministic /proc and clock spies; no production sampling or power events.
package.path='./secfilings.koplugin/?.lua;'..package.path
local actual_io,actual_time,actual_ffi,actual_arg=io,os.time,package.loaded.ffi,arg
local count=0
local function check(ok,msg) count=count+1;assert(ok,msg);print('PASS '..msg) end
local function file(text) return {read=function() return text end,close=function() end} end
local logged
package.loaded.logger={info=function(text) logged=text end}
io={open=function(path)
 if path=='/proc/self/status' then return file('Name:\treader\nPid:\t123\nVmRSS:\t4096 kB\nVmHWM:\t8192 kB\n') end
end}
local Trace=require('sec_download_trace')
Trace.mark('clean','start',{cik='320193'},'fixture\nline',100)
check(logged:find('pid=123',1,true) and logged:find('rss_kib=4096',1,true) and logged:find('hwm_kib=8192',1,true),'trace reads process RSS/HWM with explicit units')
check(not logged:find('\n',1,true) and logged:find('bytes=100',1,true),'trace sanitizes identity fields without logging body or credentials')
io={open=function() return nil end};Trace.mark('batch','end')
check(logged:find('rss_kib=na',1,true),'non-Linux trace marks metrics unavailable, not zero')
io=actual_io
local function sample(mode)
 local clock,closed,writes=0,false,{}
 os.time=function() return mode=='backward' and -clock*1000 or clock end
 package.loaded.ffi={cdef=function() end,new=function() return {[0]={tv_sec=0,tv_nsec=0}} end,
  C={usleep=function() clock=clock+1 end,
   sec_sample_clock_gettime=function(id,stamp) assert(id==1);stamp[0].tv_sec=clock;return 0 end}}
 local output='/mnt/us/secfilings-test-fixture/rss.tsv'
 io={open=function(path,open_mode)
  if path==output and open_mode=='wx' then
   return {write=function(self,...) for i=1,select('#',...) do writes[#writes+1]=tostring(select(i,...)) end end,
    flush=function() end,close=function() closed=true end}
  elseif path==output..'.stop' and mode=='stop' and clock>=1 then return file('stop')
  elseif path=='/proc/123/cmdline' then return file('luajit\0reader.lua\0')
  elseif path=='/proc/123/stat' then
   local fields={};for i=1,22 do fields[i]='0' end
   fields[1]='S';fields[12]='11';fields[13]='12';fields[20]=(mode=='changed' and clock>=1) and '999' or '100'
   return file('123 (reader.lua) '..table.concat(fields,' '))
  elseif path=='/proc/123/status' then return file('VmRSS: 4096 kB\nVmHWM: 8192 kB\nVmSize: 16384 kB\n')
  elseif path=='/proc/meminfo' then return file('MemFree: 100 kB\nCached: 200 kB\n') end
 end}
 arg={'123',output,'3'}
 dofile((SEC_TEST_VERIFY_DIR or 'tools/verify')..'/sample_reader_memory.lua')
 io=actual_io;os.time=actual_time;package.loaded.ffi=actual_ffi;arg=actual_arg
 return table.concat(writes),clock,closed
end
local text,clock,closed=sample('duration')
check(closed and clock==3 and text:find('reason=duration_limit samples=3',1,true),'sampler has bounded duration and closes log')
text,clock,closed=sample('backward')
check(closed and clock==3 and text:find('samples=3',1,true),'wall-clock jumps cannot extend monotonic duration limit')
text,clock,closed=sample('stop')
check(closed and clock==1 and text:find('reason=stop_requested samples=2',1,true),'explicit stop file ends sampler without power calls')
text,clock,closed=sample('changed')
check(closed and clock==1 and text:find('reason=process_exited_or_changed samples=1',1,true),'PID starttime change terminates sampling before unrelated process')
print('download observation: '..count..' checks passed; proc/clock are spies')
