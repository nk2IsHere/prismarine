-- # (luaH_getn) after various insert/delete patterns. Mirrored in table_test.dart.
local t = {}
for i = 1, 10 do t[i] = i end
t[5] = nil
print(#t)
t = {}
t[1] = 1 t[2] = 2 t[4] = 4
print(#t)
t = {1, 2, nil, 4}
print(#t)
t = {}
for i = 1, 20 do t[i] = i end
for i = 1, 19 do t[i] = nil end
print(#t)
t = {}
for i = 1, 7 do t[i] = i end
t[7] = nil t[6] = nil
print(#t)
t = {}
t[2] = 2
print(#t)
t = {}
for i = 1, 100 do t[i] = i end
for i = 50, 100 do t[i] = nil end
t[200] = 1
print(#t)
