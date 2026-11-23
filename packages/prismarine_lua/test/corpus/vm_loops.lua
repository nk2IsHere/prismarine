-- Numeric for in float32, generic for, break.
for i = 0, 1, 0.1 do print(i) end
for i = 10, 1, -3 do print(i) end
for i = 1, 0 do print("never") end
for i = "1", "3" do print(i) end
for i = 1, 3 do local i = i * 2 print(i) end
local function iter(t, i) i = i + 1 if t[i] then return i, t[i] end end
for i, v in iter, {"a", "b", "c"}, 0 do print(i, v) end
local n = 0
for i = 1, 5 do for j = 1, 5 do if j > i then break end n = n + 1 end end
print(n)
local x = 0
while true do x = x + 1 if x >= 7 then break end end
print(x)
local c = 0
for i = 16777214, 16777218 do c = c + 1 if c > 6 then break end print(i) end
