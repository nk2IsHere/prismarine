-- Metamethods (uses setmetatable and type).
local V = {}
V.__index = V
local function new(x) return setmetatable({x = x}, V) end
V.__add = function(a, b) return new(a.x + b.x) end
V.__sub = function(a, b) return new(a.x - (type(b) == "table" and b.x or b)) end
V.__eq = function(a, b) return a.x == b.x end
V.__lt = function(a, b) return a.x < b.x end
V.__unm = function(a) return new(-a.x) end
V.__len = function(a) return a.x * 10 end
V.__concat = function(a, b)
  local l = type(a) == "table" and ("V" .. a.x) or a
  local r = type(b) == "table" and ("V" .. b.x) or b
  return l .. "|" .. r
end
local a, b = new(1), new(2)
print((a + b).x, (b - 5).x, (-a).x, #b)
print(a == b, a == new(1), a ~= new(1), a < b, b < a, a <= b, b <= a)
print("x" .. a .. "y", a .. 5, 5 .. a)
local W = {__eq = V.__eq}
local w = setmetatable({x = 1}, W)
print(a == w)
local W2 = {__eq = function() return true end}
print(a == setmetatable({x = 9}, W2))
local base = {greet = function(self) return "hi " .. self.name end}
local mid = setmetatable({}, {__index = base})
local obj = setmetatable({name = "jesse"}, {__index = mid})
print(obj:greet(), obj.missing)
local calls = 0
local lazy = setmetatable({}, {__index = function(t, k) calls = calls + 1 return k .. "!" end})
print(lazy.a, lazy.b, calls)
local store = {}
local proxy = setmetatable({}, {__newindex = store})
proxy.k = 5
print(proxy.k, store.k)
local log = {}
local watched = setmetatable({}, {__newindex = function(t, k, v) log[#log + 1] = k .. "=" .. v end})
watched.a = 1 watched.b = 2
print(#log, log[1], log[2], watched.a)
local callable = setmetatable({}, {__call = function(self, x, y) return x + y, self end})
local r, s = callable(2, 3)
print(r, s == callable)
