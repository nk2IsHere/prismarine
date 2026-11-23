-- load of text chunks: env, readers, modes, chunk names in errors, dump round trip.
print(load("return 1 + 1")())
local env = {x = 5}
print(load("return x", "chunk", "t", env)())
local parts = {"return ", "1", " + ", "2"}
local i = 0
print(load(function() i = i + 1 return parts[i] end)())
print(type(load(function() return nil end)))
print(load(5))
print(load("return 1", "=name", "b"))
print(load(string.dump(function() return 1 end), "bin", "t"))
local function err(name)
  local f = load("local x = nil\nreturn x.y", name)
  return select(2, pcall(f))
end
print(err("=literal"))
print(err("@file.lua"))
print(err("short source"))
print(err("multi\nline"))
print(err(("long"):rep(30)))
print(err())
local f = load("local a, b = ... return a * b")
print(f(6, 7))
local g = load(string.dump(f))
print(g(3, 4))
print(loadstring)
print(load("syntax error here"))
print(load("return ...", "=v")(1, 2, 3))
