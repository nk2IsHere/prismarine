-- table library (sort with exact comparator call counts).
local seed = 7
local function rnd() seed = (seed * 75 + 74) % 65537 return seed end
local a = {}
for i = 1, 50 do a[i] = rnd() % 1000 end
local calls = 0
table.sort(a, function(x, y) calls = calls + 1 return x < y end)
print(calls, a[1], a[25], a[50])
local b = {}
for i = 1, 50 do b[i] = rnd() % 100 end
table.sort(b)
print(table.concat(b, ","))
local w = {"pear", "apple", "fig", "banana", "kiwi"}
table.sort(w)
print(table.concat(w, " "))
table.sort(w, function(x, y) return #x < #y end)
print(table.concat(w, " "))
print(pcall(table.sort, {3, 1, 2}, function(x, y) return true end))
print(pcall(table.sort, {1, "x"}))
local t = {1, 2, 3}
table.insert(t, 4)
table.insert(t, 1, 0)
print(table.concat(t, ","), #t)
print(pcall(table.insert, t, 10, 1))
print(pcall(table.insert, t))
print(pcall(table.insert, t, 1, 2, 3))
print(table.remove(t), table.remove(t, 1), table.concat(t, ","))
print(table.remove({}), table.remove({}, 1), pcall(table.remove, {1, 2}, 5))
print(table.concat({1, 2.5, "x"}, "-"), table.concat({}, ","), table.concat({1, 2, 3}, ",", 2), table.concat({1, 2, 3}, ",", 2, 3))
print(pcall(table.concat, {1, {}, 3}))
print(pcall(table.concat, {1, 2}, ",", 1, 3))
local p = table.pack(1, nil, 3)
print(p.n, p[1], p[2], p[3])
print(table.unpack({1, 2, 3}))
print(table.unpack({1, 2, 3}, 2))
print(table.unpack({1, 2, 3}, 2, 5))
print(select("#", table.unpack({}, 1, 0)))
local L = setmetatable({}, {__len = function() return 2 end})
L[1], L[2], L[3] = "a", "b", "c"
print(table.concat(L, ","), table.unpack(L))
table.insert(L, "z")
print(rawget(L, 3))
