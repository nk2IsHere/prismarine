-- pairs/next order (fixed hash seed 0). Mirrored in table_test.dart.
local t = {}
t.alpha = 1 t.beta = 1 t.gamma = 1 t.delta = 1 t.x = 1 t.y = 1 t.z = 1
for k in pairs(t) do print(k) end
print("--")
t = {}
t[3.5] = 1 t[-1] = 1 t[100] = 1 t[2^40] = 1 t[1] = 1 t[0] = 1 t[true] = 1 t[false] = 1
for k in pairs(t) do print(k) end
print("--")
t = {}
for i = 1, 10 do t[i] = i end
for i = 1, 10, 2 do t[i] = nil end
t.a = 1 t.b = 2 t[20] = 20
for k, v in pairs(t) do print(k, v) end
print("--")
t = {}
for i = 1, 40 do t["k" .. i] = i end
for i = 1, 40, 3 do t["k" .. i] = nil end
for k in pairs(t) do print(k) end
print("--")
t = {}
t[16777217] = "a"
print(t[16777216])
