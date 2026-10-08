-- SEC filing 的稳定身份、路径和安全文件名。
-- 纯 Lua 5.1；不依赖 UI 或设备专有模块。
local Filing = {}

local function cleanPart(value, fallback)
    local s = tostring(value or "")
    s = s:gsub("[%c]", " ")
    s = s:gsub("[/\\:%*%?%\"<>|]", "-")
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("%.+$", "")
    if s == "" or s == "." or s == ".." then return fallback end
    return s
end

function Filing.cik(cik)
    local n = tonumber(cik)
    if not n then return cleanPart(cik, "unknown") end
    return string.format("%010d", n)
end

function Filing.accession(filing)
    return cleanPart(filing and (filing.accn or filing.accession), "unknown-accession")
end

function Filing.companyDir(company)
    return string.format("%s [CIK %s]", cleanPart(company and company.name, "未命名公司"),
        Filing.cik(company and company.cik))
end

function Filing.form(filing)
    return cleanPart(filing and filing.form, "FILING")
end

function Filing.date(filing)
    return cleanPart(filing and (filing.date or filing.filing_date), "未知日期")
end

function Filing.key(company, filing)
    return Filing.cik(company and company.cik) .. ":" .. Filing.accession(filing)
end

function Filing.label(filing, language)
    local suffix = language == "zh" and "中文" or "原文"
    return string.format("%s · %s · %s · %s.epub", Filing.date(filing),
        Filing.form(filing), Filing.accession(filing), suffix)
end

function Filing.outputPath(out_dir, company, filing, language)
    return tostring(out_dir) .. "/" .. Filing.companyDir(company) .. "/" ..
        Filing.label(filing, language)
end

function Filing.workPath(work_dir, company, filing)
    return tostring(work_dir) .. "/" .. Filing.cik(company and company.cik) .. "/" ..
        Filing.accession(filing)
end

return Filing
