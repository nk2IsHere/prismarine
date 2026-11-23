-- Assignments, evaluation order, float32 arithmetic, coercions, control flow.
local a, b, c = 1, 2
print(a, b, c)
local x, y = 1, 2
x, y = y, x
print(x, y)
local t = {}
local i = 1
i, t[i] = i + 1, 20
print(i, t[1], t[2])
print(1 + 2 * 3 - 4 / 2, 7 % 3, -7 % 3, 7 % -3, 2 ^ 10, -2 ^ 2)
print(0.1 + 0.2, 0.1 + 0.2 == 0.3, 1 / 3, 16777217, 16777216 + 1)
local zero = 0
print(10 / zero, -10 / zero, 1e39)
print(1e15, 1e14, 123456789012345, 2 ^ 53, 0.1 * 3)
print(not nil, not 0, nil == false, 1 == 1.0, "1" == 1)
print("10" + 1, "3" * "4", "0x10" + 0, " 5 " * 2, "1e1" - 1)
print(#"hello", #{1, 2, 3})
local n = 5
local s = 0
while n > 0 do s = s + n; n = n - 1 end
print(s)
repeat local z = s; s = s - 10 until z < 0
print(s)
if s > 0 then print("pos") elseif s == 0 then print("zero") else print("neg") end
print(1 and 2, nil and 2, false or "x", nil or false, 1 or undefined_global())
local big = 2 ^ 24
print(big + 1, big + 2, big * 3 + 1)
local k = 3.7
print(k % 1, -k % 1, k - k % 1)
