-- Opt-in companion patch for Special Offers Kindle / KOReader 2026.07.2.
-- Special Offers Kindle only. Keep KOReader's own screensaver without changing
-- the Amazon account or firmware. Preserve the launcher's native-UI ownership.
local ok,Device=pcall(require,'device')
if not ok or type(Device)~='table' or type(Device.isKindle)~='function'
        or not Device:isKindle() or not Device.isSpecialOffers then return end
if Device._sec_ss_restore_patch then return end
local UIManager=require('ui/uimanager')
local logger=require('logger')
if type(Device.intoScreenSaver)~='function' or type(Device.outofScreenSaver)~='function'
        or not UIManager.scheduleIn or not UIManager.unschedule then return end
Device._sec_ss_restore_patch=true
local into,out,exiting=Device.intoScreenSaver,Device.outofScreenSaver,Device.exitingScreenSaver
local generation,pending,awaiting=0,nil,false
local function pack(...) return {n=select('#',...),...} end
local function invoke(self,fn,...)
    local saved=self.isSpecialOffers
    self.isSpecialOffers=false
    local result=pack(pcall(fn,self,...))
    self.isSpecialOffers=saved -- including exceptions and nil return slots
    if not result[1] then error(result[2],0) end
    return unpack(result,2,result.n)
end
local function cancelPending()
    if pending then UIManager:unschedule(pending);pending=nil end
    awaiting=false
end
local function refreshAfterNativeExit(token)
    if token~=generation or not awaiting then return end
    if Device.screen_saver_mode or Device.screen_saver_lock then return end
    local p=Device.getPowerDevice and Device:getPowerDevice()
    if not p or not p.getPowerdState or p:getPowerdState()~='active' then return end
    UIManager:setDirty('all','full')
    cancelPending()
end
local function safeRefresh(token)
    local success,err=pcall(refreshAfterNativeExit,token)
    if not success then cancelPending();logger.warn('screensaver restore: refresh failed',err) end
end
Device.intoScreenSaver=function(self,...)
    generation=generation+1
    cancelPending()
    return invoke(self,into,...)
end
Device.outofScreenSaver=function(self,...)
    local was_sleeping=self.screen_saver_mode
    local result=pack(invoke(self,out,...))
    if was_sleeping then
        cancelPending()
        -- Same ownership markers/commands as upstream's SO resume branch,
        -- which the previous wrapper bypassed. Never stop an unmarked process.
        if os.getenv('AWESOME_STOPPED')=='yes' then
            os.execute('killall -STOP awesome')
        elseif os.getenv('CVM_STOPPED')=='yes' then
            os.execute('killall -STOP cvm')
        end
        awaiting=true
        local token=generation
        pending=function() safeRefresh(token) end
        -- OutOfSS only requests dismissal. ExitingSS is the preferred signal;
        -- a bounded fallback covers firmware that does not deliver it.
        UIManager:scheduleIn(3,pending)
    end
    return unpack(result,1,result.n)
end
Device.exitingScreenSaver=function(self,...)
    local result=exiting and pack(exiting(self,...)) or {n=0}
    safeRefresh(generation)
    return unpack(result,1,result.n)
end
