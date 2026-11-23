// Ported from Lua 5.2.3 lopcodes.h / lopcodes.c (MIT; see LICENSE-lua).
// ignore_for_file: constant_identifier_names

import 'dart:typed_data';

import 'config.dart';
import 'proto.dart';

/// Opcodes in lopcodes.h order.
abstract final class Op {
  static const MOVE = 0, LOADK = 1, LOADKX = 2, LOADBOOL = 3, LOADNIL = 4;
  static const GETUPVAL = 5, GETTABUP = 6, GETTABLE = 7, SETTABUP = 8;
  static const SETUPVAL = 9, SETTABLE = 10, NEWTABLE = 11, SELF = 12;
  static const ADD = 13, SUB = 14, MUL = 15, DIV = 16, MOD = 17, POW = 18;
  static const UNM = 19, NOT = 20, LEN = 21, CONCAT = 22, JMP = 23;
  static const EQ = 24, LT = 25, LE = 26, TEST = 27, TESTSET = 28;
  static const CALL = 29, TAILCALL = 30, RETURN = 31, FORLOOP = 32;
  static const FORPREP = 33, TFORCALL = 34, TFORLOOP = 35, SETLIST = 36;
  static const CLOSURE = 37, VARARG = 38, EXTRAARG = 39;
}

const opNames = [
  'MOVE', 'LOADK', 'LOADKX', 'LOADBOOL', 'LOADNIL', 'GETUPVAL', 'GETTABUP',
  'GETTABLE', 'SETTABUP', 'SETUPVAL', 'SETTABLE', 'NEWTABLE', 'SELF', 'ADD',
  'SUB', 'MUL', 'DIV', 'MOD', 'POW', 'UNM', 'NOT', 'LEN', 'CONCAT', 'JMP',
  'EQ', 'LT', 'LE', 'TEST', 'TESTSET', 'CALL', 'TAILCALL', 'RETURN',
  'FORLOOP', 'FORPREP', 'TFORCALL', 'TFORLOOP', 'SETLIST', 'CLOSURE',
  'VARARG', 'EXTRAARG', //
];

/// Instruction formats.
enum OpMode { iABC, iABx, iAsBx, iAx }

/// Argument kinds.
enum OpArg { n, u, r, k }

/// `luaP_opmodes`: (test, setsA, B kind, C kind, format).
const List<(bool, bool, OpArg, OpArg, OpMode)> opModes = [
  (false, true, OpArg.r, OpArg.n, OpMode.iABC), // MOVE
  (false, true, OpArg.k, OpArg.n, OpMode.iABx), // LOADK
  (false, true, OpArg.n, OpArg.n, OpMode.iABx), // LOADKX
  (false, true, OpArg.u, OpArg.u, OpMode.iABC), // LOADBOOL
  (false, true, OpArg.u, OpArg.n, OpMode.iABC), // LOADNIL
  (false, true, OpArg.u, OpArg.n, OpMode.iABC), // GETUPVAL
  (false, true, OpArg.u, OpArg.k, OpMode.iABC), // GETTABUP
  (false, true, OpArg.r, OpArg.k, OpMode.iABC), // GETTABLE
  (false, false, OpArg.k, OpArg.k, OpMode.iABC), // SETTABUP
  (false, false, OpArg.u, OpArg.n, OpMode.iABC), // SETUPVAL
  (false, false, OpArg.k, OpArg.k, OpMode.iABC), // SETTABLE
  (false, true, OpArg.u, OpArg.u, OpMode.iABC), // NEWTABLE
  (false, true, OpArg.r, OpArg.k, OpMode.iABC), // SELF
  (false, true, OpArg.k, OpArg.k, OpMode.iABC), // ADD
  (false, true, OpArg.k, OpArg.k, OpMode.iABC), // SUB
  (false, true, OpArg.k, OpArg.k, OpMode.iABC), // MUL
  (false, true, OpArg.k, OpArg.k, OpMode.iABC), // DIV
  (false, true, OpArg.k, OpArg.k, OpMode.iABC), // MOD
  (false, true, OpArg.k, OpArg.k, OpMode.iABC), // POW
  (false, true, OpArg.r, OpArg.n, OpMode.iABC), // UNM
  (false, true, OpArg.r, OpArg.n, OpMode.iABC), // NOT
  (false, true, OpArg.r, OpArg.n, OpMode.iABC), // LEN
  (false, true, OpArg.r, OpArg.r, OpMode.iABC), // CONCAT
  (false, false, OpArg.r, OpArg.n, OpMode.iAsBx), // JMP
  (true, false, OpArg.k, OpArg.k, OpMode.iABC), // EQ
  (true, false, OpArg.k, OpArg.k, OpMode.iABC), // LT
  (true, false, OpArg.k, OpArg.k, OpMode.iABC), // LE
  (true, false, OpArg.n, OpArg.u, OpMode.iABC), // TEST
  (true, true, OpArg.r, OpArg.u, OpMode.iABC), // TESTSET
  (false, true, OpArg.u, OpArg.u, OpMode.iABC), // CALL
  (false, true, OpArg.u, OpArg.u, OpMode.iABC), // TAILCALL
  (false, false, OpArg.u, OpArg.n, OpMode.iABC), // RETURN
  (false, true, OpArg.r, OpArg.n, OpMode.iAsBx), // FORLOOP
  (false, true, OpArg.r, OpArg.n, OpMode.iAsBx), // FORPREP
  (false, false, OpArg.n, OpArg.u, OpMode.iABC), // TFORCALL
  (false, true, OpArg.r, OpArg.n, OpMode.iAsBx), // TFORLOOP
  (false, false, OpArg.u, OpArg.u, OpMode.iABC), // SETLIST
  (false, true, OpArg.u, OpArg.n, OpMode.iABx), // CLOSURE
  (false, true, OpArg.u, OpArg.n, OpMode.iABC), // VARARG
  (false, false, OpArg.u, OpArg.u, OpMode.iAx), // EXTRAARG
];

const maxArgA = 255, maxArgB = 511, maxArgC = 511;
const maxArgBx = (1 << 18) - 1,
    maxArgSBx = maxArgBx >> 1,
    maxArgAx = (1 << 26) - 1;

/// Bit 8 of a B/C argument marks a constant index (`BITRK`).
const bitRK = 1 << 8;
const maxIndexRK = bitRK - 1;

/// Fields per OP_SETLIST flush (`LFIELDS_PER_FLUSH`).
const lFieldsPerFlush = 50;

/// The standard opcode of instruction [i].
int opOf(int i) => _standard[i & 0x3F];
int argA(int i) => (i >> 6) & 0xFF;
int argC(int i) => (i >> 14) & 0x1FF;
int argB(int i) => (i >> 23) & 0x1FF;
int argBx(int i) => (i >> 14) & 0x3FFFF;
int argSBx(int i) => argBx(i) - maxArgSBx;
int argAx(int i) => (i >> 6) & 0x3FFFFFF;
bool isK(int x) => x & bitRK != 0;
int indexK(int x) => x & ~bitRK;

int createABC(int o, int a, int b, int c) =>
    o | (a << 6) | (b << 23) | (c << 14);
int createABx(int o, int a, int bx) => o | (a << 6) | (bx << 14);
int createAx(int o, int ax) => o | (ax << 6);

/// The specialised opcodes of the float32 mode: `ADD` to `POW`, then
/// `FORLOOP` and `FORPREP`, which the float32Single mode shares.
const opFloat32 = 40;
const opSub32 = 41, opMul32 = 42, opDiv32 = 43, opMod32 = 44, opPow32 = 45;
const opForLoop32 = 46, opForPrep32 = 47;

/// The specialised opcodes of the float32Single mode: `ADD` to `POW`.
const opSingle = 48;
const opSubSingle = 49, opMulSingle = 50, opDivSingle = 51;
const opModSingle = 52, opPowSingle = 53;

/// The standard opcode of each opcode, specialised ones included.
final _standard = Uint8List.fromList([
  for (var o = 0; o < 64; o++)
    o < opFloat32
        ? o
        : o < opFloat32 + 6
        ? Op.ADD + o - opFloat32
        : o == opFloat32 + 6
        ? Op.FORLOOP
        : o == opFloat32 + 7
        ? Op.FORPREP
        : o < opSingle + 6
        ? Op.ADD + o - opSingle
        : o,
]);

/// Rewrites the arithmetic and numeric `for` instructions of [p] and its
/// nested prototypes to the opcodes of [mode].
void specialiseProto(LuaProto p, LuaNumberMode mode) {
  if (mode == LuaNumberMode.float64) return;
  final code = p.code;
  final arith = mode == LuaNumberMode.float32 ? opFloat32 : opSingle;
  for (var pc = 0; pc < code.length; pc++) {
    final i = code[pc];
    final op = i & 0x3F;
    final to = op >= Op.ADD && op <= Op.POW
        ? arith + op - Op.ADD
        : op == Op.FORLOOP
        ? opFloat32 + 6
        : op == Op.FORPREP
        ? opFloat32 + 7
        : op;
    if (to != op) code[pc] = (i & ~0x3F) | to;
  }
  for (final q in p.protos) {
    specialiseProto(q, mode);
  }
}
