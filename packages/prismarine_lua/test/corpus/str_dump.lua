-- string.dump and load of binary chunks.
local function f(a, b) return a + b, "k" end
local s = string.dump(f)
print(type(s), #s > 0, s:sub(1, 4) == "\27Lua")
local g = load(s, "=dumped", "b")
print(g(2, 3))
print(load(s, "x", "t"))
print(pcall(string.dump, print))
local up = 5
local h = load(string.dump(function() return up end))
print(h() == _G)
local e = load(string.dump(function() local x = nil; return x.y end), "=lit")
print(pcall(e))
local env = {k = "env"}
local fe = load(string.dump(function() return k end), "d", "b", env)
print(fe())
print(load(string.dump(f)) ~= f)
