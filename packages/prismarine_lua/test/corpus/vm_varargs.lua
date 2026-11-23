-- Varargs.
local function count(...) local t = {...} return #t end
print(count(), count(1), count(1, 2, 3))
local function pass(...) return ... end
print(pass(1, nil, 3))
local function va(a, ...) local b, c = ... return a, b, c end
print(va(1))
print(va(1, 2))
print(va(1, 2, 3, 4))
local function tail(...) return pass(...) end
print(tail("a", "b"))
local t = {pass(1, 2), pass(3, 4)}
print(#t, t[1], t[2], t[3])
local function nest(...) local function inner() return 1 end return inner(), ... end
print(nest(7, 8))
local function first(...) local x = ... return x end
print(first(9, 8, 7))
