-- Explicit local repair controls. No network or translation settings are consulted.
local Library=require('sec_library')
local UIManager=require('ui/uimanager')
local ConfirmBox=require('ui/widget/confirmbox')
local _=require('gettext')
local RepairUI={}
local function available(self)
    if self.sec_busy then self:showMessage(_('已有 SEC 任务正在运行。')); return false end
    if self.ui and self.ui.document then self:showMessage(_('请先关闭正在阅读的书籍，再恢复或关联。')); return false end
    return true
end
local function library(self)
    return Library:new{work_dir=self.sec_work_dir,out_dir=self.sec_out_dir}
end
local function execute(self,lib,plan,method,message)
    if not available(self) then return end
    self.sec_busy=true
    -- These methods are synchronous filesystem/archiver operations; no callbacks or yields.
    local ran,ok,err=pcall(lib[method],lib,plan)
    self.sec_busy=false
    if not ran then self:showMessage(_('本地操作中断；文件已保留，请重新检查。'))
    elseif not ok then self:showMessage(err)
    else self:showMessage(message) end
end
function RepairUI:prepareOriginalRecovery(cik,accn)
    if not available(self) then return end
    local lib=library(self)
    local plan,err=lib:previewOriginalRecovery(cik,accn)
    if not plan then self:showMessage(err); return end
    local used=false
    UIManager:show(ConfirmBox:new{
        text=_('从已保存的正文与素材恢复原文 EPUB。\n不联网、不翻译，不覆盖中文版或阅读记录。\n若书已移动，请先重新关联，避免产生副本。'),
        ok_text=_('确认恢复原文'),ok_callback=function()
            if used then return end; used=true
            execute(self,lib,plan,'restoreOriginal',_('原文已恢复。中文版、缓存和阅读记录保持不变。'))
        end})
end
function RepairUI:prepareRelink(cik,accn,language)
    if not available(self) then return end
    local lib=library(self)
    local candidates,err=lib:findRelinkCandidates(cik,accn,language)
    if not candidates then self:showMessage(err); return end
    if #candidates==0 then
        self:showMessage(_('SEC 书库内未找到内容一致的 EPUB。\n仅查找本插件书库，不扫描其他目录；改过内容的文件不能自动关联。'))
        return
    end
    local Menu=require('ui/widget/menu')
    local menu
    local items={}
    for i,path in ipairs(candidates) do
        local candidate=path
        items[#items+1]={text=candidate:sub(#lib.out_dir+2),callback=function()
            UIManager:close(menu)
            if not available(self) then return end
            local plan,why=lib:previewRelink(cik,accn,language,candidate)
            if not plan then self:showMessage(why); return end
            local used=false
            UIManager:show(ConfirmBox:new{
                text=(_('关联到 SEC 书库内：\n%1\n\n已按文件内容校验。只更新位置记录，不移动文件，也不迁移或修改阅读记录。')):gsub('%%1',function() return plan.relative end),
                ok_text=_('确认关联'),ok_callback=function()
                    if used then return end; used=true
                    execute(self,lib,plan,'relink',_('已更新文件位置。书籍和阅读记录未改动。'))
                end})
        end}
    end
    menu=Menu:new{title=language=='en' and _('选择原文的新位置') or _('选择中文版的新位置'),item_table=items}
    menu.onMenuSelect=function(widget,item) if item.callback then item.callback() end; return true end
    UIManager:show(menu)
end
return RepairUI
