-- Upvalues: sharing, per-iteration capture, closing on break, the closure cache.
local function counter()
  local n = 0
  return function() n = n + 1 return n end, function() return n end
end
local inc, get = counter()
inc() inc()
print(get(), inc(), get())
local fs = {}
for i = 1, 3 do fs[i] = function() return i end end
print(fs[1](), fs[2](), fs[3]())
local gs = {}
local j = 1
while j <= 3 do local k = j gs[j] = function() return k end j = j + 1 end
print(gs[1](), gs[2](), gs[3]())
local function mk() return function() end end
print(mk() == mk())
local function mk2(x) return function() return x end end
print(mk2(1) == mk2(1))
local m1 = mk2(1)
print(m1 == m1)
local shared
do local v = 10 shared = function() v = v + 1 return v end end
print(shared(), shared())
local function outer()
  local a = 1
  local function mid() local function inner() a = a + 1 return a end return inner end
  return mid()
end
local h = outer()
print(h(), h())
local acc = {}
for i = 1, 3 do local x = i * 10 acc[#acc + 1] = function() return x end if i == 2 then break end end
print(#acc, acc[1](), acc[2]())
local function rec(n) if n <= 1 then return 1 end return n * rec(n - 1) end
print(rec(10))
