-- Comparisons.
print(1 < 2, 2 < 1, 1 <= 1, "a" < "b", "a" < "B", "abc" < "abd", "" < "a", "a\0b" < "a\0c", "Z" < "a")
print(1 == 1, "1" == 1, nil == nil, true == true, {} == {})
local t = {}
print(t == t)
local zero = 0
print(0 == -0, 1 / zero == 1 / zero, zero / zero == zero / zero)
local nan = zero / zero
print(nan ~= nan)
print(16777217 == 16777216, 2 ^ 24 + 1 == 2 ^ 24)
