-- Concatenation and number-to-string.
print(1 .. "", 0.1 .. "", -0.0 .. "", 1e15 .. "", 2 ^ 63 .. "")
print("a" .. "b" .. "c" .. 1 .. 2)
local s = ""
for i = 1, 5 do s = s .. i .. "," end
print(s)
print("" .. "", "x" .. "", "" .. "y")
print(1 .. 2, 1.5 .. 2.25)
local parts = {"obj_", 3, "_lookAt"}
print(parts[1] .. parts[2] .. parts[3])
