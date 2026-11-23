-- Calls, multiple results, adjustments, tail calls, methods.
local function f(...) return ... end
print(f(1, 2, 3))
print((f(1, 2, 3)))
print(f(1, nil, 3))
local function g(a, b, c) return c, b, a end
print(g(1, 2))
print(g(f(1, 2, 3)))
print(g(f(1, 2, 3), 10))
local t = {f(1, 2, 3)}
print(#t, t[3])
t = {f(1, 2, 3), f(4, 5)}
print(#t, t[1], t[2], t[3])
local function sum(n, acc) if n == 0 then return acc end return sum(n - 1, acc + n) end
print(sum(10000, 0))
local function depth(n) if n == 0 then return 0 end return 1 + depth(n - 1) end
print(depth(150))
local obj = {v = 5}
function obj:get(x) return self.v + x end
print(obj:get(1), obj.get(obj, 2))
local function multi() return 1, 2, 3 end
local a, b, c, d = multi()
print(a, b, c, d)
local u = {multi(), multi()}
print(#u)
