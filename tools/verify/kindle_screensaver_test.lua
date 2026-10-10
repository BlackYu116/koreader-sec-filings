local path=arg[1] or "./contrib/kindle/2-kindle-screensaver.lua";local count=0
local function check(ok,label) count=count+1;assert(ok,label);print('PASS '..label) end
local function fixture(kind,special)
 local x={timers={},refresh=0,commands={},state='active',env={},warnings=0}
 local dev={isKindle=function() return kind~=false end,isSpecialOffers=special~=false,
  getPowerDevice=function() return {getPowerdState=function() return x.state end} end}
 dev.intoScreenSaver=function(self)
  assert(not self.isSpecialOffers);if x.fail_into then error('into failed') end
  self.screen_saver_mode=true;return 'in',nil,'last'
 end
 dev.outofScreenSaver=function(self)
  assert(not self.isSpecialOffers);if x.fail_out then error('out failed') end
  self.screen_saver_mode=false;return 'out',nil,'last'
 end
 dev.exitingScreenSaver=function(self) assert(self.isSpecialOffers);x.exit_calls=(x.exit_calls or 0)+1 end
 local ui={scheduleIn=function(_,delay,fn) assert(delay==3);x.timers[fn]=true end,
  unschedule=function(_,fn) x.timers[fn]=nil end,
  setDirty=function(_,target,mode) assert(target=='all' and mode=='full');x.refresh=x.refresh+1 end}
 local env=setmetatable({require=function(name)
  if name=='device' then return dev elseif name=='ui/uimanager' then return ui
  elseif name=='logger' then return {warn=function() x.warnings=x.warnings+1 end} end
  error('unexpected dependency: '..name)
 end,os={getenv=function(k) return x.env[k] end,execute=function(cmd) x.commands[#x.commands+1]=cmd end}}, {__index=_G})
 local function install() local f=assert(loadfile(path));setfenv(f,env);f() end
 x.dev=dev;x.install=install;x.original_into=dev.intoScreenSaver;install();return x
end
local x=fixture(false,true);check(x.dev.intoScreenSaver==x.original_into,'non-Kindle untouched')
x=fixture(true,false);check(x.dev.intoScreenSaver==x.original_into,'non-ad Kindle untouched')
x=fixture();local wrapped=x.dev.intoScreenSaver;x.install();check(x.dev.intoScreenSaver==wrapped,'duplicate loading does not wrap twice')
local a,b,c=x.dev:intoScreenSaver();check(a=='in' and b==nil and c=='last' and x.dev.isSpecialOffers,'into returns nil slots and restores identity')
x.fail_out=true;local ok=pcall(function() x.dev:outofScreenSaver() end)
check(not ok and x.dev.isSpecialOffers and next(x.timers)==nil,'out exception restores identity without timer')
x.fail_out=false;a,b,c=x.dev:outofScreenSaver()
check(a=='out' and b==nil and c=='last' and x.dev.isSpecialOffers,'out returns nil slots and restores identity')
check(x.refresh==0 and next(x.timers),'OutOfSS waits for completion or bounded fallback')
x.dev:exitingScreenSaver();check(x.refresh==1 and next(x.timers)==nil and x.exit_calls==1,'ExitingSS refreshes and removes fallback')
x.dev:exitingScreenSaver();check(x.refresh==1,'duplicate ExitingSS does not repaint again')
x=fixture();x.dev:intoScreenSaver();x.dev:outofScreenSaver();local stale=assert(next(x.timers))
x.dev:intoScreenSaver();stale();check(x.refresh==0 and next(x.timers)==nil,'new sleep cancels previous cycle and rejects stale callback')
x.dev:outofScreenSaver();local fallback=assert(next(x.timers));fallback()
check(x.refresh==1 and next(x.timers)==nil,'missing ExitingSS uses one fallback')
x=fixture();x.dev:intoScreenSaver();x.dev:outofScreenSaver();x.state='screenSaver';assert(next(x.timers))()
check(x.refresh==0,'native state must actually be active before refresh')
x=fixture();x.dev:intoScreenSaver();x.dev:outofScreenSaver();x.dev.screen_saver_lock=true;x.dev:exitingScreenSaver()
check(x.refresh==0,'gesture lock is not bypassed')
x=fixture();x.env.CVM_STOPPED='yes';x.dev:intoScreenSaver();x.dev:outofScreenSaver()
check(#x.commands==1 and x.commands[1]=='killall -STOP cvm','only launcher-marked CVM stop is restored')
x=fixture();x.dev:intoScreenSaver();x.dev:outofScreenSaver();check(#x.commands==0,'unmarked native processes untouched')
x=fixture();x.fail_into=true;ok=pcall(function() x.dev:intoScreenSaver() end)
check(not ok and x.dev.isSpecialOffers,'into exception restores identity')
x=fixture();x.dev:exitingScreenSaver();check(x.refresh==0,'ExitingSS before OutOfSS does not prematurely redraw')
x.dev:intoScreenSaver();x.dev:outofScreenSaver();assert(next(x.timers))()
check(x.refresh==1,'out-of-order event still has bounded fallback')
print(string.format('screensaver candidate: %d checks passed; simulated events only',count))
