-- Thin translation UI. Business state and source validation live in sec_library.
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local Library = require("sec_library")
local _ = require("gettext")
local T = require("ffi/util").template
local TranslationUI = {}

-- Trapper:info yields for 100 ms on every update. A financial report can contain
-- thousands of text nodes; refreshing per node would turn a local check into minutes.
-- Yield about once per second, including while scanning cached/numeric content.
local function responsiveProgress()
    local last_second
    return function(message)
        local now = os.time()
        if now == last_second then return true end
        last_second = now
        return Trapper:info(message)
    end
end

function TranslationUI:getDeepSeekKey()
    return tostring(self.settings:readSetting("deepseek_api_key") or "")
end

function TranslationUI:deepSeekModel()
    return tostring(self.settings:readSetting("deepseek_model") or "deepseek-flash")
end

function TranslationUI:deepSeekThinking()
    return self.settings:readSetting("deepseek_thinking") == true
end

function TranslationUI:getTranslationItems()
    local items = {}
    items[#items + 1] = {
        text = self:getDeepSeekKey() ~= "" and _("DeepSeek API Key：已设置") or _("DeepSeek API Key：未设置"),
        help_text = _("仅保存在 Kindle 插件设置中，不会写入 EPUB、日志或源码；翻译可能产生 API 费用。"),
        callback = function() self:deepSeekKeyDialog() end,
    }
    items[#items + 1] = {
        text = T(_("翻译模型：%1"), self:deepSeekModel()),
        callback = function() self:deepSeekModelDialog() end,
    }
    items[#items + 1] = {
        text = self:deepSeekThinking() and _("翻译思考模式：开") or _("翻译思考模式：关"),
        help_text = _("默认关闭，以减少 Kindle 等待时间和 API 成本。"),
        keep_menu_open = true,
        callback = function()
            self.settings:saveSetting("deepseek_thinking", not self:deepSeekThinking())
            self.settings:flush()
        end,
    }
    local opts = self:translationOptions()
    items[#items+1] = {
        text = T(_("每轮最多请求：%1 次（1 份原文）"), opts.translation_max_requests),
        sub_item_table_func = function()
            local choices = {}
            for i, n in ipairs({5, 10, 20}) do
                choices[#choices+1] = {text=tostring(n), checked_func=function()
                    return self:translationOptions().translation_max_requests == n end,
                    callback=function()
                        self.settings:saveSetting("translation_max_requests", n); self.settings:flush()
                    end}
            end
            return choices
        end,
    }
    items[#items+1] = {
        text = _("仅使用已有缓存（不联网）"),
        checked_func = function() return self:translationOptions().translation_cache_only end,
        callback = function()
            self.settings:saveSetting("translation_cache_only", not self:translationOptions().translation_cache_only)
            self.settings:flush()
        end,
    }
    return items
end

function TranslationUI:deepSeekKeyDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("DeepSeek API Key"),
        description = _("填写新的 DeepSeek API Key；留空会清除。现有密钥不会显示。"),
        input = "", input_hint = "sk-…", text_type = "password", show_password_toggle = false,
        buttons = {
            { { text = _("取消"), callback = function() UIManager:close(dialog) end },
              { text = _("保存"), is_enter_default = true, callback = function()
                    local value = dialog:getInputText() or ""
                    value = value:match("^%s*(.-)%s*$")
                    UIManager:close(dialog)
                    self.settings:saveSetting("deepseek_api_key", value)
                    self.settings:flush()
                    self:showMessage(value == "" and _("已清除 API Key。") or _("已保存 API Key；插件不会在界面显示完整密钥。"))
              end } },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function TranslationUI:deepSeekModelDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("DeepSeek 翻译模型"), description = _("填写你的账户可用的模型名，默认 deepseek-flash。"),
        input = self:deepSeekModel(), input_hint = "deepseek-flash",
        buttons = {
            { { text = _("取消"), callback = function() UIManager:close(dialog) end },
              { text = _("保存"), is_enter_default = true, callback = function()
                    local value = dialog:getInputText() or "deepseek-flash"
                    value = value:match("^%s*(.-)%s*$")
                    if value == "" then value = "deepseek-flash" end
                    UIManager:close(dialog)
                    self.settings:saveSetting("deepseek_model", value)
                    self.settings:flush()
              end } },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Small presets, never a currency budget. Each action processes one local filing.
function TranslationUI:translationOptions()
    local max_requests = tonumber(self.settings:readSetting("translation_max_requests"))
    if max_requests ~= 5 and max_requests ~= 10 and max_requests ~= 20 then max_requests = 20 end
    return {work_dir=self.sec_work_dir or Library.default_work_dir,
        out_dir=self.sec_out_dir or Library.default_out_dir,
        deepseek_api_key=self:getDeepSeekKey(), deepseek_model=self:deepSeekModel(),
        deepseek_thinking=self:deepSeekThinking(), translation_max_requests=max_requests,
        translation_max_input_bytes=max_requests * 2400,
        translation_cache_only=self.settings:readSetting("translation_cache_only") == true}
end

function TranslationUI:getLocalTranslationItems(page)
    page = page or 1
    local library = Library:new(self:translationOptions())
    local entries, damaged, truncated = library:list()
    if not entries then
        return {{text=_("本地资料不可读"), callback=function() self:showMessage(damaged) end}}
    end
    local labels = {pending=_("待翻译"), translating=_("待续译"), paused=_("已暂停"),
        failed=_("上次未完成"), publishing=_("待确认成品"), complete=_("已完成")}
    local items = {}
    if #entries == 0 then items[#items+1] = {text=_("暂无新版原文，请先下载一份"), enabled=false} end
    if damaged > 0 or truncated then
        items[#items+1] = {text=T(_("不可读 %1 份；最多列出 1000 份"), damaged), enabled=false}
    end
    local first = (page - 1) * 15 + 1
    for i = first, math.min(first + 14, #entries) do
        local entry = entries[i]
        items[#items+1] = {text=string.format("%s · %s · %s · %s", entry.name,
            entry.form, entry.date, labels[entry.status]),
            help_text=entry.accn,
            callback=function() self:prepareTranslation(entry.cik, entry.accn) end}
    end
    if first + 15 <= #entries then
        items[#items+1] = {text=_("下一页"),
            sub_item_table_func=function() return self:getLocalTranslationItems(page + 1) end}
    end
    return items
end

function TranslationUI:prepareTranslation(cik, accn)
    if self.sec_busy then self:showMessage(_("已有 SEC 任务正在运行。")); return end
    self.sec_busy = true
    local opts = self:translationOptions()
    local library = Library:new(opts)
    local translator = library:translator(opts)
    Trapper:wrap(function()
        local progress = responsiveProgress()
        local stats, record = library:estimate(cik, accn, translator,
            function() return progress(_("正在检查本地原文与翻译缓存…")) end)
        Trapper:reset()
        self.sec_busy = false
        if not stats then self:showMessage(record); return end
        if stats.requests > 0 and not translator.cache_only and opts.deepseek_api_key == "" then
            self:showMessage(_("仍有未缓存内容。请先在翻译设置填写 API Key，或开启仅缓存模式。")); return
        end
        -- Freeze source and settings shown in the confirmation. An all-cached plan cannot turn paid.
        translator.expected_source_hash = record.state.source_hash
        translator.cache_only = translator.cache_only or stats.requests == 0
        local mode = translator.cache_only and _("仅使用缓存，不联网") or _("将向 DeepSeek 发送未缓存的原文")
        local text = string.format("%s\n%s\n模型：%s；思考：%s\n待请求约 %d 块；缓存命中 %d 块\n本轮至多 %d 请求 / %d 输入字节\n每请求至多 %d 输出 tokens\n不是金额预算；失败请求也可能收费。\n原文不变，未完成可续译。", record.source.company.name,
            mode, translator.model, translator.thinking and _("开") or _("关"),
            stats.requests, stats.cache_hits, translator.cache_only and 0 or translator.max_requests,
            translator.cache_only and 0 or translator.max_input_bytes, translator.max_output_tokens)
        local used = false
        UIManager:show(ConfirmBox:new{text=text, ok_text=_("生成 / 续译"), ok_callback=function()
            if used or self.sec_busy then return end
            used = true
            local function run()
                if self.sec_busy then self:showMessage(_("已有 SEC 任务正在运行，请稍后重试。")); return end
                self.sec_busy = true
                Trapper:wrap(function()
                    local progress = responsiveProgress()
                    local path, err, result = library:translate(cik, accn, translator, progress)
                    Trapper:reset()
                    self.sec_busy = false
                    if path then
                        self:showMessage(result == "reused" and _("中文版已完成，保留原文件与阅读进度。")
                            or _("中文版已生成，与原文保存在同一公司目录。"))
                    else self:showMessage(err) end
                end)
            end
            if translator.cache_only then run() else NetworkMgr:runWhenOnline(run) end
        end})
    end)
end

return TranslationUI
