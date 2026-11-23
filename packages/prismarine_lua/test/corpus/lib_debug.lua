-- debug library (no addresses).
local function f(a, b, ...) local x = 1 return debug.getinfo(1, "nSl") end
local i = f()
print(i.short_src, i.linedefined, i.lastlinedefined, i.what, i.currentline, i.source)
local j = debug.getinfo(f)
print(j.what, j.nparams, j.isvararg, j.nups, j.linedefined)
local p = debug.getinfo(print)
print(p.what, p.short_src, p.source, p.currentline, p.linedefined)
local function named() return debug.getinfo(1, "n") end
local n = named()
print(n.name, n.namewhat)
G_named = named
local g = G_named()
print(g.name, g.namewhat)
local function locals(alpha, beta)
  local gamma = 3
  local names = {}
  local k = 1
  while true do
    local name, value = debug.getlocal(1, k)
    if not name then break end
    names[#names + 1] = name .. "=" .. (type(value) == "table" and "table" or tostring(value))
    k = k + 1
  end
  return table.concat(names, " ")
end
print(locals(1, 2))
local up1, up2 = 10, 20
local function uses() return up1 + up2 end
print(debug.getupvalue(uses, 1), debug.getupvalue(uses, 2), debug.getupvalue(uses, 3))
print(debug.setupvalue(uses, 1, 100), uses())
print(debug.traceback("msg", 1):match("^msg\nstack traceback:\n\t[^\n]+"))
print(type(debug.getregistry()), debug.getmetatable("x").__index == string)
print(debug.gethook())
