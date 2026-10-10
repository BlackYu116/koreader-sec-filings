-- Task-scoped Kindle idle-timer renewal; no persistent power configuration.
-- AutoSuspend:onInputEvent alone is insufficient when its timeout is disabled.
-- Never use preventScreenSaver=1: that suppresses deliberate power-button sleep
-- and can survive a KOReader crash. Mirror upstream's charging/KeepAlive guards,
-- additionally checking the real powerd inhibit flag before touching t1.
local Guard={}
Guard.__index=Guard

function Guard:new(device, shared, clock)
    return setmetatable({device=device,shared=shared,clock=clock},self)
end

-- Exceptions deliberately propagate to the owning UI heartbeat's pcall; that
-- boundary cancels the download and restores the shared pause flag and timer.
function Guard:pulse()
    local device=self.device
    if not device or not device.isKindle then return false,'device capability unavailable' end
    if not device:isKindle() then return true,'not-kindle' end
    if device.screen_saver_mode then return false,'device is entering screensaver' end
    local power=device.getPowerDevice and device:getPowerDevice()
    if not power or not power.getPowerdState or not power.resetT1Timeout
            or not power.isCharging or not power.isCharged then
        return false,'Kindle power capabilities unavailable'
    end
    if power:getPowerdState()~='active' then return false,'powerd is not active' end
    if self.shared.keepalive then return true,'keepalive' end
    local lipc=power.lipc_handle
    if not lipc or not lipc.get_int_property then return false,'powerd inhibit query unavailable' end
    local inhibit=tonumber(lipc:get_int_property('com.lab126.powerd','preventScreenSaver'))
    if not inhibit then return false,'powerd inhibit state unknown' end
    if inhibit~=0 then return true,'inhibited' end
    if power:isCharging() and not power:isCharged() then return true,'charging' end
    local now=self.clock()
    if self.last_reset and now-self.last_reset<240 then return true,'rate-limited' end
    power:resetT1Timeout()
    self.last_reset=now
    return true,'reset'
end

return Guard
