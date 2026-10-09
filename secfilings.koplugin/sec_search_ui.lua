-- Search presentation/state only. Public Menu API; no private main-menu stack manipulation.
local UIManager=require('ui/uimanager')
local NetworkMgr=require('ui/network/manager')
local Trapper=require('ui/trapper')
local Search=require('sec_search')
local _=require('gettext')
local T=require('ffi/util').template
local SearchUI={search_years=3,search_max_total=5000}
local function active(self,token) return token and self.search_pending==token end
local function begin(self)
    if self.sec_busy then self:showMessage(_('已有 SEC 任务正在运行。')); return nil end
    self:closeSearchPanel()
    local token={}; self.search_pending=token; return token
end
local function finish(self,token,message)
    if not active(self,token) then return end
    self.search_pending=nil; Trapper:reset()
    if self.search_state then self:showSearchResults() end
    if message then self:showMessage(message) end
end
local function dispatch(self,token,fn)
    NetworkMgr:runWhenOnline(function()
        if not active(self,token) then return end
        if self.sec_busy then
            self.search_pending=nil; self:showMessage(_('已有 SEC 任务正在运行。')); return
        end
        Trapper:wrap(fn) -- never pcall a potentially yielding request/progress chain
    end)
end
local function complete(list)
    return list and not list.truncated and not list.form_summary_partial
        and list.form_summary_scope~='partial'
        and (not list.stats or (list.stats.sources_failed or 0)==0)
end
local function formKey(forms) return forms and table.concat(forms,',') or '*' end
local function saveView(st)
    st.views=st.views or {}
    st.views[st.form_key or '*']={list=st.list,form=st.form,form_key=st.form_key,page=st.page}
end
function SearchUI:closeSearchPanel()
    local menu=self._search_window
    if not menu then return end
    self._search_window=nil
    if menu.save_search_position then menu.save_search_position() end
    UIManager:close(menu)
end
function SearchUI:showSearchPanel(rows,title,is_filter)
    self:closeSearchPanel()
    local Menu=require('ui/widget/menu')
    local st=self.search_state
    local key=(st and st.form_key or '*')..':'..tostring(st and st.page or 1)
    local items={}
    for i,row in ipairs(rows) do
        local enabled=row.enabled~=false and (not row.enabled_func or row.enabled_func())
        local checked=row.checked_func and row.checked_func()
        items[#items+1]={text=(checked and '✓ ' or '')..(row.text or ''),
            dim=not enabled,select_enabled=enabled,source=row}
    end
    local menu=Menu:new{title=title,item_table=items}
    menu.save_search_position=function()
        if st and not is_filter then
            st.menu_pages=st.menu_pages or {}; st.menu_pages[key]=menu.page or 1
        end
    end
    menu.close_callback=function()
        if self._search_window~=menu then return end
        menu.save_search_position(); self._search_window=nil
        if is_filter and self.search_state==st then self:showSearchResults() end
    end
    menu.onMenuSelect=function(widget,item)
        if self._search_window~=menu or self.search_state~=st or item.select_enabled==false then return true end
        local row=item.source
        if row.enabled_func and not row.enabled_func() then return true end
        if row.sub_item_table_func or row.sub_item_table then
            self:showSearchPanel(row.sub_item_table_func and row.sub_item_table_func() or row.sub_item_table,row.text,true)
        elseif row.callback then
            if row.close_search then self:closeSearchPanel() end
            row.callback()
        end
        return true
    end
    if not is_filter and st and st.menu_pages and st.menu_pages[key] then
        menu.page=st.menu_pages[key]
        if menu.updateItems then menu:updateItems() end
    end
    self._search_window=menu; UIManager:show(menu)
end
function SearchUI:showSearchResults()
    local rows=self:getSearchItems()
    local st=self.search_state
    if st and st.candidates and self.search_last_results then
        table.insert(rows,1,{text=_('返回上一份查询结果'),callback=function()
            self.search_state=self.search_last_results; self:showSearchResults()
        end})
    elseif st and st.list and not complete(st.list) then
        table.insert(rows,1,{text=_('结果不完整：达到上限或部分历史未取得'),enabled=false})
    end
    self:showSearchPanel(rows,self:searchStateLabel(),false)
end
function SearchUI:startSearch(query)
    local token=begin(self); if not token then return end
    dispatch(self,token,function() self:runSearch(query,token) end)
end
function SearchUI:runSearch(query,token)
    token=token or begin(self); if not token or not active(self,token) then return end
    if Trapper:info(T(_('正在查找「%1」…'),query))==false then finish(self,token); return end
    if not active(self,token) then return end
    local ok,res,kind=Search:resolve(query,self:searchOpts())
    if not active(self,token) then return end
    if not ok then finish(self,token,T(_('查找失败：%1'),self:explainError(res,kind))); return end
    local aliases=res.aliases or {res}
    if #aliases>1 and (res.ambiguous or res.tie) then
        self.search_state={query=query,candidates=aliases}
        finish(self,token); return
    end
    self:loadFilings(res,query,nil,token)
end
function SearchUI:filingSearchOptions(forms)
    local opts=self:searchOpts()
    opts.since=self:sinceDate(self.search_years); opts.max_total=self.search_max_total; opts.forms=forms
    return opts
end
function SearchUI:loadFilings(res,query,form,token)
    token=token or begin(self); if not token or not active(self,token) then return end
    if Trapper:info(T(_('正在列出 %1 的文件…'),tostring(res.name or res.cik)))==false then finish(self,token); return end
    if not active(self,token) then return end
    local ok,list,kind=Search:listFilings(res.cik_num or res.cik,self:filingSearchOptions(form and {form}))
    if not active(self,token) then return end
    if not ok then finish(self,token,T(_('列出文件失败：%1'),self:explainError(list,kind))); return end
    local st={query=query,company={cik=list.cik_num or res.cik_num or tonumber(list.cik or res.cik),
        cik_pad=list.cik or res.cik,name=list.name or res.name or tostring(res.cik),
        ticker=(res.tickers and res.tickers[1]) or res.ticker},
        list=list,form=form,form_key=form,page=1,views={},menu_pages={},
        summary=list.form_summary_all or list.form_summary}
    if not form then st.full_list=list end
    self.search_state=st; self.search_last_results=st
    finish(self,token)
end
function SearchUI:pickCandidate(candidate,query)
    local token=begin(self); if not token then return end
    dispatch(self,token,function() self:loadFilings(candidate,query,nil,token) end)
end
function SearchUI:setSearchForms(forms)
    local st=self.search_state
    if not st or not st.company then return end
    local token=begin(self); if not token then return end
    saveView(st)
    local cached=st.views[formKey(forms)]
    if cached then
        st.list,st.form,st.form_key,st.page=cached.list,cached.form,cached.form_key,cached.page
        self.search_pending=nil; self:showSearchResults(); return
    end
    if complete(st.full_list) then
        local list={}; for k,v in pairs(st.full_list) do list[k]=v end
        list.entries={}; list.local_filter=true
        for i,entry in ipairs(st.full_list.entries) do
            local matched=not forms
            for j,form in ipairs(forms or {}) do if Search.matchesForm(entry.form,form) then matched=true; break end end
            if matched then list.entries[#list.entries+1]=entry end
        end
        list.matched=#list.entries
        st.list,st.form,st.form_key,st.page=list,forms and table.concat(forms,'/'),forms and table.concat(forms,','),1
        self.search_pending=nil; self:showSearchResults(); return
    end
    dispatch(self,token,function() self:refilterSearch(forms,token,st) end)
end
function SearchUI:refilterSearch(forms,token,st)
    st=st or self.search_state
    if not st or not st.company then return end
    token=token or begin(self); if not token or not active(self,token) then return end
    if Trapper:info(T(_('正在筛出「%1」…'),forms and table.concat(forms,'/') or _('全部')))==false then finish(self,token); return end
    if not active(self,token) then return end
    local ok,list,kind=Search:listFilings(st.company.cik,self:filingSearchOptions(forms))
    if not active(self,token) or self.search_state~=st then return end
    if not ok then finish(self,token,T(_('筛选失败：%1'),self:explainError(list,kind))); return end
    st.list,st.form,st.form_key,st.page=list,forms and table.concat(forms,'/'),forms and table.concat(forms,','),1
    if not forms then st.full_list=list; st.summary=list.form_summary_all or list.form_summary end
    finish(self,token)
end
return SearchUI
