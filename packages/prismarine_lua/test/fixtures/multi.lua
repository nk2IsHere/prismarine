-- Returns a function giving several results, and one that calls a native callback.
return function(a, b) return a, b, a + b end, function(cb, n) return cb(n) end
