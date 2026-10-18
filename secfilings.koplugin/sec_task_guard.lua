-- Shared SEC task lifetime. No persistent wake lock, no automatic restart.
local Task = {}

function Task.cancel(owner)
    -- Also revoke confirmations / network callbacks that have not started yet.
    owner.sec_cancel_generation = (owner.sec_cancel_generation or 0) + 1
    if owner.sec_task then owner.sec_task.cancelled = true end
    if owner.sec_download_active then owner.sec_download_cancelled = true end
    if owner.sec_translation_active then owner.sec_translation_cancelled = true end
end

function Task.cancelled(owner)
    return owner.sec_download_cancelled or owner.sec_translation_cancelled
        or owner.sec_task and owner.sec_task.cancelled or false
end

function Task.run(owner, kind, work)
    if owner.sec_busy then owner:showMessage("已有 SEC 任务正在运行。"); return nil end
    local UI = require("ui/uimanager")
    local Trapper = require("ui/trapper")
    local shared = require("pluginshare")
    local previous_pause = shared.pause_auto_suspend
    local task = {kind=kind, cancelled=false}
    local protected = kind ~= "preflight"
    local active_key = kind == "download" and "sec_download_active" or "sec_translation_active"
    local cancel_key = kind == "download" and "sec_download_cancelled" or "sec_translation_cancelled"
    owner.sec_busy, owner.sec_task = true, task
    owner[active_key], owner[cancel_key] = true, false
    if protected then shared.pause_auto_suspend = true end
    local released, heartbeat, power = false, nil, nil
    local function release()
        if released then return end
        released = true
        if heartbeat and UI.unschedule then pcall(UI.unschedule, UI, heartbeat) end
        if protected then shared.pause_auto_suspend = previous_pause end
    end
    heartbeat = function()
        if released or owner.sec_task ~= task or Task.cancelled(owner) then return false end
        local ok = pcall(function()
            local autosuspend = require("pluginloader"):getPluginInstance("autosuspend")
            if autosuspend and autosuspend.onInputEvent then autosuspend:onInputEvent() end
            power = power or require("sec_download_power"):new(require("device"), shared, function()
                return require("ui/time").to_number(UI:getElapsedTimeSinceBoot())
            end)
            local awake, reason = power:pulse()
            if not awake then error("SEC power protection unavailable") end
            if reason == "reset" and autosuspend then autosuspend.last_t1_reset_time = UI:getElapsedTimeSinceBoot() end
            if UI.scheduleIn then UI:scheduleIn(60, heartbeat) end
        end)
        if not ok then Task.cancel(owner); release() end
        return ok
    end
    local finished = false
    local function finish(ok)
        if finished then return end
        finished = true
        release()
        -- Always release ownership before any error dialog can invoke UI callbacks.
        owner[active_key], owner[cancel_key] = nil, nil
        if owner.sec_task == task then owner.sec_task = nil; owner.sec_busy = false end
        Trapper:reset()
        if not ok then
            -- No raw exception: transport/library errors may contain credentials.
            require("logger").warn("secfilings: " .. kind .. " task interrupted by exception")
            owner:showMessage("SEC 任务异常中断；未自动重试。已保存的原文和翻译缓存保留，请重新打开入口预检。")
        end
    end
    local wrapped = pcall(function()
        Trapper:wrap(function()
            -- Native Trapper uses the same yieldable LuaJIT protected boundary.
            local ok = xpcall(function()
                if protected and not heartbeat() then error("SEC power guard failed") end
                work(task)
            end, function() return "SEC task exception" end)
            finish(ok)
        end)
    end)
    if not wrapped then finish(false) end
    return wrapped
end

return Task
