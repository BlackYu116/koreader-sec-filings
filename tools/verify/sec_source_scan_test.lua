-- Focused differential tests; dependency stubs never perform I/O/network.
for _, name in ipairs({'socket.http','ltn12','json','logger'}) do package.preload[name]=function() return {} end end
package.preload['libs/libkoreader-cre']=function() error('real cre unavailable') end
local source_path=(SEC_TEST_PLUGIN_DIR or './secfilings.koplugin')..'/sec_source.lua'
local old=assert(loadfile(source_path))()
local new=assert(loadfile(source_path))()
local function up(fn,name)
    for i=1,100 do local n,v=debug.getupvalue(fn,i); if n==name then return v end; if not n then break end end
    error('missing upvalue '..name)
end
-- Reconstruct just the pre-optimization helpers; the rest of the real cleaner
-- is shared. No external baseline checkout or network fixture is needed.
local function replace(fn,name,value)
 for i=1,100 do local n=debug.getupvalue(fn,i);if n==name then debug.setupvalue(fn,i,value);return end;if not n then break end end
 error('missing upvalue '..name)
end
local baseline_void=up(old.cleanHtml,'selfCloseVoid')
local tags,ci=up(baseline_void,'VOID_TAGS'),up(baseline_void,'ci')
replace(old.cleanHtml,'selfCloseVoid',function(s)
 for _,void in ipairs(tags) do local p=ci(void)
  s=s:gsub('(<%s*'..p..'%s[^>]-)/%s*>','%1>')
  s=s:gsub('<%s*'..p..'%s*>','<'..void..'/>')
  s=s:gsub('(<%s*'..p..'%s[^>]-)>','%1/>')
 end
 return s
end)
replace(old.cleanHtml,'dropTag',function(s,name)
 local p=ci(name)
 s=s:gsub('<%s*/?%s*'..p..'%s*>','')
 s=s:gsub('<%s*/?%s*'..p..'%s[^>]*>','')
 return (s:gsub('<%s*'..p..'%s*/>',''))
end)
replace(old.splitWideTables,'countTables',function(s)
 local _,n=s:gsub('<[Tt][Aa][Bb][Ll][Ee][%s>]','');return n
end)
local old_void,new_void=up(old.cleanHtml,'selfCloseVoid'),up(new.cleanHtml,'selfCloseVoid')
local old_drop,new_drop=up(old.cleanHtml,'dropTag'),up(new.cleanHtml,'dropTag')
local old_count,new_count=up(old.splitWideTables,'countTables'),up(new.splitWideTables,'countTables')
local count=up(new_count,'countMatches')
local fixtures={
    '', '<img>', '<IMG >', '<img src="x.png" alt="Full image"/>', '<img/>',
    '<br><BR ><br/><br />< Br > <br title="a > b">',
    '<font/>Text<span style="font-size:12pt"> remains</span><center>Yes</center>',
    '< / html ><body data-a="<br >">X</body>',
    '<!-- <img > --><tableau>no</tableau><TABLE >yes</TABLE>',
    '<br', '<br "unterminated', '<table><table><table></table></table></table>',
}
local tags={'br','hr','col','area','base','embed','source','track','wbr','input','meta','link','img','font','span','center','table','html','head','body','header','image'}
local gaps={'',' ','\t','\r\n','  '}
local attrs={'',' /','/',' id="x"',' src="z.png" alt="All pictures"',' a=" > <br >"',' style="white-space:pre"',' title=\'x\'',' a=">" /'}
math.randomseed(20261010)
for i=1,2000 do
    local chunks={}
    for j=1,math.random(1,18) do
        local tag=tags[math.random(#tags)]
        if math.random(2)==1 then tag=tag:upper() end
        chunks[#chunks+1]='text '..gaps[math.random(#gaps)]..'<'..gaps[math.random(#gaps)]..(math.random(4)==1 and '/' or '')..gaps[math.random(#gaps)]..tag..attrs[math.random(#attrs)]..'>'
    end
    fixtures[#fixtures+1]=table.concat(chunks)
end
local checks=0
for _,s in ipairs(fixtures) do
    assert(old_void(s)==new_void(s),'void mismatch')
    assert(old_count(s)==new_count(s),'table count mismatch')
    checks=checks+2
    for _,tag in ipairs(tags) do assert(old_drop(s,tag)==new_drop(s,tag),'drop mismatch '..tag);checks=checks+1 end
    for _,p in ipairs({'<%s*[Ii][Mm][Gg]%s*>','<%s*[Ii][Mm][Gg][%s][^>]*>'}) do
        local _,n=s:gsub(p,''); assert(n==count(s,p),'image count mismatch');checks=checks+1
    end
end
local docs={
    '<html><head><title>Title</title><meta name="author" content="SEC"/></head><body><p>All text &amp; numbers</p><img src="a.png" alt="Chart"/><img src="b.jpg" alt="Photo"></body></html>',
    '<html><body><table><tr><td>Account</td><td>2026</td><td>2025</td></tr><tr><td style="border-top:1px solid">Revenue</td><td>100</td><td>99</td></tr><tr><td><img src="chart.png" alt="chart"/>Graphic</td><td><table><tr><td>Nested text</td></tr></table></td><td>1</td></tr></table></body></html>',
    '<html><body><ix:header>Hidden metadata</ix:header><ix:nonFraction>123</ix:nonFraction><div style="color:white;font-size:1pt;line-height:0;display:none">Visible text<img src="slide.png" alt="slide"/></div></body></html>',
    '<html><body><br><BR/><hr noshade><input disabled><source src="a"><span>Text</span><font/>Tail</body></html>',
}
local function same_stats(a,b) for k,v in pairs(a) do assert(b[k]==v,k) end;for k,v in pairs(b) do assert(a[k]==v,k) end end
for _,doc in ipairs(docs) do
    for _,budget in ipairs({15,22,30}) do
        for _,drop in ipairs({false,true}) do
            old.table_avail_em,new.table_avail_em=budget,budget
            old.drop_images,new.drop_images=drop,drop
            local a,ai=old:cleanHtml(doc);local b,bi=new:cleanHtml(doc)
            assert(a==b,'clean output mismatch');same_stats(ai,bi);checks=checks+1
            if not drop and doc==docs[1] then assert(b:find('src="a.png"',1,true) and b:find('src="b.jpg"',1,true),'images lost');assert(bi.images==2) end
        end
    end
end
print(string.format('source scan: %d checks passed; %d helper inputs; %d full clean cases; real cre UNAVAILABLE',checks,#fixtures,#docs*3*2))
