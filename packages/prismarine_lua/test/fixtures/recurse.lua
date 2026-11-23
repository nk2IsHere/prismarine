-- Runaway non-tail recursion (stack overflow).
local function f() return 1 + f() end
return f
