-- Explicit, short e-ink confirmations for SEC-owned files. No deletion on menu opening.
local Lifecycle = require('sec_lifecycle')
local UIManager = require('ui/uimanager')
local ConfirmBox = require('ui/widget/confirmbox')
local _ = require('gettext')
local StorageUI = {}
local function size(n) return string.format('%.1f MiB', (n or 0)/1048576) end
function StorageUI:newLifecycle()
    local opts=self:translationOptions()
    opts.is_busy=function() return self.sec_busy end
    -- Never delete while ReaderUI holds a document, even if its path has changed.
    opts.is_open=function() return self.ui and self.ui.document~=nil end
    return Lifecycle:new(opts)
end
function StorageUI:getLocalFilingActions(entry)
    local id=entry.cik..':'..entry.accn
    return {
        {text=_("生成 / 续译中文版"),enabled=entry.original_present,
            callback=function() self:prepareTranslation(entry.cik,entry.accn) end},
        {text=_("删除整份资料及本地阅读记录…"),
            callback=function() self:prepareCleanup({id},{remove_books=true,remove_reading_data=true}) end},
        {text=_("存储与清理（检查移动及残留）"),
            sub_item_table_func=function() return self:getStorageItems() end},
    }
end
function StorageUI:prepareCleanup(ids, opts)
    if self.sec_busy then self:showMessage(_("已有 SEC 任务正在运行。")); return end
    local lc=self:newLifecycle()
    local plan,err=lc:preview(ids,opts)
    if not plan then self:showMessage(err); return end
    local text=string.format('清理 %d 项 / %d 文件，约 %s\n将删除 %d 个 EPUB。\n%s\n%s\n不可撤销。设置、关注列表、搜索索引不变。',
        plan.count,plan.files,size(plan.bytes),plan.books,
        plan.remove_reading_data and '包含对应的本地阅读记录。' or '保留阅读记录。',
        opts and opts.remove_shared_cache and '旧翻译缓存将清空，之后重译可能收费。'
            or '若书已移动，确认表示不再需要原位置的附属资料。')
    local used=false
    UIManager:show(ConfirmBox:new{text=text,ok_text=_("确认删除"),ok_callback=function()
        if used or self.sec_busy then return end
        used=true; self.sec_busy=true
        lc.is_busy=function() return false end -- this synchronous operation owns the UI busy lock
        -- Lifecycle never yields. pcall is only for filesystem exceptions, not Trapper/network work.
        local ran,ok,message,report=pcall(lc.execute,lc,plan)
        self.sec_busy=false
        if not ran then self:showMessage(_("清理中断。请重新检查残留；未继续删除。")); return end
        if ok then self:showMessage(string.format('已清理 %d 个文件，释放约 %s。',report.removed,size(report.bytes)))
        elseif report and report.removed>0 then
            self:showMessage(string.format('已删除 %d 个文件，未全部完成。请重新检查后重试。',report.removed))
        else self:showMessage(message) end
    end})
end
function StorageUI:getStorageItems()
    local scan=self:newLifecycle():scan()
    if not scan.complete then
        return {{text=_("目录未就绪或检查未完成"),callback=function() self:showMessage(scan.error) end}}
    end
    local items={
        {text='书籍成品：'..size(scan.bytes.books),enabled=false},
        {text='原文快照与工作资料：'..size(scan.bytes.work),enabled=false},
        {text='单份翻译缓存：'..size(scan.bytes.cache),enabled=false},
        {text='旧共享翻译缓存：'..size(scan.bytes.legacy_cache),enabled=false},
        {text=_("公司搜索索引：独立保留"),sub_item_table_func=function()
            return {{text=_("清空公司搜索缓存…"),callback=function()
                UIManager:show(ConfirmBox:new{text=_("只清空公司搜索索引；下次搜索需要重新联网下载。书籍和翻译缓存不变。"),
                    ok_text=_("清空"),ok_callback=function()
                        if not self.sec_busy then self:clearSearchCache() end
                    end})
            end}}
        end},
    }
    local missing={}
    for i,row in ipairs(scan.rows) do if row.status=='missing' then missing[#missing+1]=row.id end end
    if #missing>0 then
        items[#items+1]={text=string.format('检查到 %d 项文件移除后的资料…',#missing),
            help_text=_("只在确认后清理。文件移出书库或改名也可能被列出，请先核对。"),
            sub_item_table_func=function()
                return {{text=_("批量清理（包含对应本地阅读记录）…"),
                    callback=function() self:prepareCleanup(missing,{remove_reading_data=true}) end}}
            end}
    end
    if scan.shared_cache_id then
        items[#items+1]={text=_("清空旧共享翻译缓存…"),callback=function()
            self:prepareCleanup({scan.shared_cache_id},{remove_shared_cache=true})
        end}
    end
    local labels={present='仍在书库',partial='原文/译文仅一份在原位置',missing='文件位置待确认',
        unknown='归属待核对',recoverable='发布待恢复'}
    for i,row in ipairs(scan.rows) do
        local current=row
        items[#items+1]={text=current.name..' · '..(current.date or '旧合集')..' · '..(labels[current.status] or current.status),
            sub_item_table_func=function()
                local actions={}
                if current.blocked then
                    actions[#actions+1]={text=_("查看保留原因"),callback=function() self:showMessage(current.blocked) end}
                elseif current.status=='missing' then
                    if current.kind=='filing' then
                        actions[#actions+1]={text=_("清理附属资料，保留阅读记录…"),
                            callback=function() self:prepareCleanup({current.id},{}) end}
                    end
                    actions[#actions+1]={text=_("清理附属资料与本地阅读记录…"),
                        callback=function() self:prepareCleanup({current.id},{remove_reading_data=true}) end}
                elseif current.kind=='filing' then
                    actions[#actions+1]={text=_("删除整份资料及本地阅读记录…"),
                        callback=function() self:prepareCleanup({current.id},{remove_books=true,remove_reading_data=true}) end}
                else actions[#actions+1]={text=_("请先在书库处理仍存在的旧合集"),enabled=false} end
                return actions
            end}
    end
    if #scan.rows==0 then items[#items+1]={text=_("没有待管理的 SEC 资料"),enabled=false} end
    return items
end
return StorageUI
