-- A native "wait" (passed in) used from Lua: plain call, inside __index, and a getter.
local wait = ...
local function use(x) local r = wait(x) return r + 1 end
local function index(t, k) return wait(k) end
local function get(t) return t.foo end
return use, index, get
