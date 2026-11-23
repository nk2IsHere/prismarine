-- bit32 (results are float32: 4294967295 prints as 4294967296).
print(bit32.band(0xFF, 0x0F), bit32.band(), bit32.bor(1, 2, 4), bit32.bxor(0xFF, 0x0F), bit32.bnot(0), bit32.bnot(-1))
print(bit32.btest(1, 2), bit32.btest(3, 2), bit32.band(-1, 0xFFFF))
print(bit32.lshift(1, 4), bit32.lshift(1, 31), bit32.lshift(1, 32), bit32.rshift(256, 4), bit32.rshift(-1, 28), bit32.rshift(1, -4))
print(bit32.arshift(-256, 4), bit32.arshift(256, 4), bit32.arshift(0x80000000, 31), bit32.arshift(-1, 40))
print(bit32.lrotate(1, 1), bit32.lrotate(0x80000000, 1), bit32.rrotate(1, 1), bit32.lrotate(5, 32))
print(bit32.extract(0xF0, 4, 4), bit32.extract(0xF0, 0), bit32.replace(0, 0xF, 4, 4), bit32.replace(0xFF, 0, 0, 4))
print(pcall(bit32.extract, 1, -1), pcall(bit32.extract, 1, 0, 0), pcall(bit32.extract, 1, 30, 4))
print(bit32.band(2^32 + 5, 7), bit32.bor(1.9))
