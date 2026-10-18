-- Offline HTTP streaming tests. Native socket abort behavior remains a device check.
package.path='./secfilings.koplugin/?.lua;'..package.path
local http={TIMEOUT=60}; package.loaded['socket.http']=http
package.loaded.ltn12={sink={table=function(t) return function(s) if s then t[#t+1]=s end;return 1 end end}}
package.loaded.logger={warn=function() end,info=function() end}
local S=require('sec_source'):new{user_agent='Test test@example.invalid',max_doc_bytes=8,max_metadata_bytes=4}
local count=0
local function check(ok,s) count=count+1;assert(ok,s);print('PASS '..s) end
local requests,accepted=0,0
http.request=function(o)
 requests=requests+1
 for i=1,100 do
  local ok,err=o.sink('ab')
  if not ok then return nil,err end
  accepted=accepted+2
 end
 return 1,200
end
local value,err=S:fetch('https://fixture/meta')
check(not value and accepted==4 and requests==1,'metadata sink stops at cap without retrying oversized response')
accepted=0;requests=0
value,err=S:filingContent(1,{accn='0000000001-26-000001',form='10-Q',primary='doc.htm'})
check(not value and accepted==8 and requests==1,'filing sink uses document cap before concatenation')
http.request=function(o) assert(o.sink('abcd'));assert(o.sink(nil));return 1,200 end
check(S:fetch('https://fixture/exact')=='abcd','exact boundary is accepted')
http.request=function() error('transport exception') end
value,err=S:fetch('https://fixture/exception',1)
check(not value and http.TIMEOUT==60,'transport exception restores shared timeout')
http.request=function(o) o.sink('ab');o.sink(nil,'broken stream');return nil,'broken stream' end
check(not S:fetch('https://fixture/partial',1),'partial failed response never becomes success')
print('source limits: '..count..' checks passed; offline HTTP only')
