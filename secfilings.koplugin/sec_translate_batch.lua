-- Bounded, serial JSON batches. Original v2 fragment boundaries/validation stay
-- authoritative. First pass streams to durable fragment caches; second pass is
-- cache-only assembly. Never retain a whole book's pending text/token maps.
local Batch = {}
local T = require('sec_translate')
local P = T._batch
local json = require('json')
local FORMAT_ERROR = '批量翻译响应结构错误；未自动重试'

local function fragment(self, text)
    if type(text)~='string' or #text>self.max_chars then return nil,'翻译块超过大小上限' end
    local leading,core,trailing=text:match('^(%s*)(.-)(%s*)$')
    local protected,tokens=P.protect(core)
    if not tokens.requires_language then return {plain=text} end
    local protocol=setmetatable({prompt_version='batch-1'}, {__index=self})
    local path,key=P.cachePath(protocol,text)
    if not path then return nil,key or '批量翻译需要本地缓存目录' end
    local item={path=path,key=key,text=protected,tokens=tokens,leading=leading,trailing=trailing}
    local cached=P.readCache(self,path,key)
    local restored=cached and P.validate(cached,tokens)
    if restored then item.cached=leading..restored..trailing;return item end
    -- Old v2 caches are read-only, independently validated and bound to the
    -- original model/thinking/source identity. No migration or deletion needed.
    local dirs={self.cache_dir,self.legacy_cache_dir}
    for _,dir in ipairs(dirs) do
        local legacy=setmetatable({cache_dir=dir,prompt_version=2},{__index=self})
        local oldpath,oldkey=P.cachePath(legacy,text)
        if not oldpath then return nil,oldkey end
        local old=P.readCache(self,oldpath,oldkey)
        restored=old and P.validate(old,tokens)
        if restored then item.cached=leading..restored..trailing;return item end
    end
    return item
end

local function decode(response, pending)
    if type(response)~='string' or #response>262044 then return nil,FORMAT_ERROR end
    -- Require the array envelope as well as a dense Lua table (JSON objects
    -- with numeric-looking keys must not be mistaken for arrays).
    if not response:match('^%s*%[') or not response:match('%]%s*$') then return nil,FORMAT_ERROR end
    local ok,rows=pcall(json.decode,response)
    if not ok or type(rows)~='table' or #rows~=#pending then return nil,FORMAT_ERROR end
    local keys=0
    for key in pairs(rows) do
        if type(key)~='number' or key<1 or key>#pending or key%1~=0 then return nil,FORMAT_ERROR end
        keys=keys+1
    end
    if keys~=#pending then return nil,FORMAT_ERROR end
    for i,item in ipairs(pending) do
        local row=rows[i]
        if type(row)~='table' or row.id~=i or type(row.text)~='string' then return nil,FORMAT_ERROR end
        local fields=0
        for k in pairs(row) do if k~='id' and k~='text' then return nil,FORMAT_ERROR end;fields=fields+1 end
        if fields~=2 then return nil,FORMAT_ERROR end
        local valid,err=P.validate(row.text,item.tokens)
        if not valid then return nil,err end
    end
    return rows
end

function Batch.html(self, html, progress_cb)
    local planning=self.estimate_seen~=nil
    local pending,pending_keys,bytes={},{},0
    local function stop(err) if not planning then self.stopped=err end;return nil,err end
    local function flush()
        if #pending==0 then return true end
        if progress_cb and progress_cb(self.request_count)==false then return stop('已取消') end
        local request={}
        for i,item in ipairs(pending) do request[i]={id=i,text=item.text} end
        local text=json.encode(request)
        local body=self:_body(text)
        if #body>16384 then return stop('完整请求体超过大小上限；未发送') end
        if planning then
            self.request_count=self.request_count+1
            self.input_bytes=self.input_bytes+bytes
            self.wire_bytes=self.wire_bytes+#body
        else
            local response,err=self:_dispatch(text,bytes,body)
            if not response then return stop(err) end
            local rows;rows,err=decode(response,pending)
            if not rows then return stop(err) end
            -- All items validate before ANY fragment from this response is saved.
            for i,item in ipairs(pending) do
                local saved; saved,err=P.writeCache(item.path,item.key,rows[i].text)
                if not saved then return stop(err) end
                self.completed_blocks=self.completed_blocks+1
            end
        end
        pending,pending_keys,bytes={},{},0
        return true
    end
    local scanner=setmetatable({batch_scanning=true,scan_only=true},{__index=self})
    scanner.translateText=function(_,text)
        if progress_cb and progress_cb(self.request_count)==false then return stop('已取消') end
        if self.stopped and not planning then return nil,self.stopped end
        local item,err=fragment(self,text);if not item then return stop(err) end
        if item.plain then return '' end
        if item.cached then self.cache_hits=self.cache_hits+1;return '' end
        if pending_keys[item.key] or planning and self.estimate_seen[item.key] then return '' end
        -- Legacy raw blocks can expand when digits become placeholders (the
        -- real Apple fixture contains a 2472-byte protected block). Keep that
        -- cache boundary, isolate the item, and enforce the serialized body
        -- hard cap in flush/_dispatch instead of rejecting a valid old block.
        if #pending>0 and (#pending>=8 or bytes+#item.text>1200) then
            local ok;ok,err=flush();if not ok then return nil,err end
        end
        if planning then self.estimate_seen[item.key]=true end
        pending[#pending+1]=item;pending_keys[item.key]=true;bytes=bytes+#item.text
        self.blocks=self.blocks+1
        return ''
    end
    local scanned,err=T.translateHtml(scanner,html,progress_cb)
    if not scanned then return stop(err) end
    local ok;ok,err=flush();if not ok then return nil,err end
    if planning then return '' end
    -- Re-read and validate the durable result. No API calls possible here, even
    -- if a cache is removed between the two passes.
    local assembler=setmetatable({batch_scanning=true},{__index=self})
    assembler.translateText=function(_,text)
        if progress_cb and progress_cb(self.request_count)==false then return nil,'已取消' end
        local item,e=fragment(self,text);if not item then return nil,e end
        return item.plain or item.cached, '仅缓存模式：此翻译块尚无有效缓存'
    end
    return T.translateHtml(assembler,html,progress_cb)
end

return Batch
