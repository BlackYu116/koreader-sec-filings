-- Shared lifetime with explicit UI/power doubles; no device or network access.
package.path='./secfilings.koplugin/?.lua;'..package.path
local scheduled, pulses, resets, messages = {}, 0, 0, {}
local shared={}
local UI={scheduleIn=function(_,delay,cb) scheduled[cb]=delay end,
    unschedule=function(_,cb) scheduled[cb]=nil end}
package.loaded['ui/uimanager']=UI
package.loaded.pluginshare=shared
package.loaded.logger={warn=function() end}
package.loaded.device={}
package.loaded.pluginloader={getPluginInstance=function() return {onInputEvent=function() end} end}
local fail_power=false
package.loaded.sec_download_power={new=function() return {pulse=function()
    pulses=pulses+1;if fail_power then error('private power details') end;return true,'not-kindle'
end} end}
package.loaded['ui/trapper']={reset=function() resets=resets+1 end,wrap=function(_,f)
    local co=coroutine.create(f)
    while coroutine.status(co)~='dead' do local ok,err=coroutine.resume(co);assert(ok,err) end
end}
local Task=require('sec_task_guard')
local n=0
local function check(ok,label) n=n+1;assert(ok,label);print('PASS '..label) end
local owner={showMessage=function(_,text) messages[#messages+1]=text end}
for _,prior in ipairs({false,true}) do
 shared.pause_auto_suspend=prior
 Task.run(owner,'translation',function()
    check(owner.sec_busy and shared.pause_auto_suspend,'active translation holds task-only pause')
    coroutine.yield()
 end)
 check(not owner.sec_busy and not owner.sec_task and shared.pause_auto_suspend==prior and not next(scheduled),'success releases lock, timer, and prior pause')
end
shared.pause_auto_suspend=nil
local stale
Task.run(owner,'translation',function()
 for cb in pairs(scheduled) do stale=cb end
 Task.cancel(owner)
 check(Task.cancelled(owner),'manual suspend cancellation sticky')
 check(stale()==false,'cancelled heartbeat never renews or reschedules')
 coroutine.yield()
end)
local before=pulses
check(stale()==false and pulses==before and shared.pause_auto_suspend==nil,'stale heartbeat is inert after release; nil pause restored')
Task.run(owner,'translation',function() error('secret key in exception') end)
check(not owner.sec_busy and not next(scheduled) and not messages[#messages]:find('secret key',1,true),'exception cleans ownership and does not disclose raw error')
before=pulses
Task.run(owner,'preflight',function() coroutine.yield();error('preflight exception') end)
check(not owner.sec_busy and pulses==before and not next(scheduled),'preflight exception releases lock without power lease')
fail_power=true
local ran=false
Task.run(owner,'download',function() ran=true end)
check(not ran and not owner.sec_busy and not owner.sec_download_active and not next(scheduled),'initial power failure prevents job and cleans all state')
fail_power=false
owner.sec_busy=true;Task.run(owner,'translation',function() ran=true end)
check(not ran and owner.sec_busy,'busy rejection preserves existing task ownership')
owner.sec_busy=false
local original_wrap=package.loaded['ui/trapper'].wrap
package.loaded['ui/trapper'].wrap=function() error('cannot start wrapper') end
Task.run(owner,'translation',function() ran=true end)
check(not owner.sec_busy and not owner.sec_task and not next(scheduled),'wrapper startup exception also releases task')
package.loaded['ui/trapper'].wrap=original_wrap
print('task guard: '..n..' checks passed; UI and power are simulated')
