-- Offline safety contract. Fake powerd only: never contacts a device or writes settings.
package.path='./secfilings.koplugin/?.lua;'..package.path
local Guard=require('sec_download_power')
local n=0
local function check(ok,label) n=n+1;assert(ok,label);print('PASS '..label) end
local function fixture()
    local x={now=0,resets=0,state='active',prevent=0,charging=false,charged=false,shared={}}
    local p={getPowerdState=function() return x.state end,
        isCharging=function() return x.charging end,isCharged=function() return x.charged end,
        resetT1Timeout=function() x.resets=x.resets+1 end,
        lipc_handle={get_int_property=function(_,service,name)
            assert(service=='com.lab126.powerd' and name=='preventScreenSaver')
            return x.prevent
        end}}
    x.power=p
    x.device={isKindle=function() return true end,getPowerDevice=function() return p end}
    x.guard=Guard:new(x.device,x.shared,function() return x.now end)
    return x
end
local x=fixture()
check(x.guard:pulse() and x.resets==1,'Kindle renews immediately without AutoSuspend dependency')
x.now=60;check(x.guard:pulse() and x.resets==1,'does not reset on every heartbeat')
x.now=240;check(x.guard:pulse() and x.resets==2,'renews after four minutes')
x.now=239;check(x.guard:pulse() and x.resets==2,'backward clock cannot cause a reset storm')
x=fixture();x.device.isKindle=function() return false end;x.device.getPowerDevice=function() error('native API on non-Kindle') end
check(x.guard:pulse() and x.resets==0,'non-Kindle needs no native power API')
x=fixture();x.shared.keepalive=true
check(x.guard:pulse() and x.resets==0,'KeepAlive suppresses unsafe t1 reset')
x=fixture();x.prevent=1
check(x.guard:pulse() and x.resets==0,'actual preventScreenSaver suppresses reset even without shared flag')
x.prevent=0;check(x.guard:pulse() and x.resets==1,'external inhibit release allows immediate renewal')
x=fixture();x.charging=true
check(x.guard:pulse() and x.resets==0,'charging before full suppresses unsafe reset')
x.charged=true;check(x.guard:pulse() and x.resets==1,'fully charged device can renew')
for _,state in ipairs({'screenSaver','suspended','readyToSuspend','unknown'}) do
 x=fixture();x.state=state;local ok,why=x.guard:pulse()
 check(not ok and why and x.resets==0,'non-active powerd state cancels: '..state)
end
x=fixture();x.device.screen_saver_mode=true
check(not x.guard:pulse() and x.resets==0,'pending UI screensaver prevents renewal')
x=fixture();x.power.lipc_handle=nil
check(not x.guard:pulse() and x.resets==0,'missing LIPC does not fall back to unchecked shell reset')
x=fixture();x.prevent=nil
check(not x.guard:pulse() and x.resets==0,'unknown inhibit value fails safely')
x=fixture();x.power.lipc_handle.get_int_property=function() error('LIPC unavailable') end
local ok=pcall(function() x.guard:pulse() end)
check(not ok and x.resets==0,'LIPC exception reaches caller cleanup boundary without reset')
x=fixture();x.power.resetT1Timeout=nil
check(not x.guard:pulse() and x.resets==0,'unsupported native reset capability fails safely')
x=fixture();x.state=nil
check(not x.guard:pulse() and x.resets==0,'unknown actual state cannot be treated as active')
x=fixture();assert(x.guard:pulse());x.now=30;x.state='screenSaver'
check(not x.guard:pulse() and x.resets==1,'state is checked even during reset rate-limit window')
print(string.format('download power: %d checks passed; simulated powerd only',n))
