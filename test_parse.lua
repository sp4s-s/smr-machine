local json = require("scripts/lua_json")
local f = io.open("build/trading_terminal/raw_events.jsonl", "r")
local ct = 0
for i=1,10 do
  local l = f:read("*l")
  if l then
     local ok, ev = pcall(json.decode, l)
     print(ok, ev and ev.status or "no_status")
     ct = ct + 1
  end
end
print("Parsed " .. ct)
