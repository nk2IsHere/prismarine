//! mcsm_lua_native's library: compiles Lua source with stock Lua 5.2.3
//! (configured like GameApp.exe; vendored C built by build.rs) and hands back
//! the dumped chunk or the error text. Everything happens in a fresh state
//! per call; Lua's errors are caught inside Lua (luaL_loadbufferx is a
//! protected call), so no longjmp crosses Rust or Dart frames.
//!
//! `unsafe` is only the FFI edge: Lua's C API and the C ABI Dart calls
//! (lib/src/native.dart).

use std::ffi::{c_char, c_int, c_void, CStr};

#[repr(C)]
struct LuaState {
    _opaque: [u8; 0],
}

type Writer = unsafe extern "C" fn(*mut LuaState, *const c_void, usize, *mut c_void) -> c_int;

const LUA_OK: c_int = 0;
const LUA_ERRMEM: c_int = 4;

extern "C" {
    fn luaL_newstate() -> *mut LuaState;
    fn luaL_loadbufferx(
        l: *mut LuaState,
        buff: *const c_char,
        sz: usize,
        name: *const c_char,
        mode: *const c_char,
    ) -> c_int;
    fn lua_dump(l: *mut LuaState, writer: Writer, data: *mut c_void) -> c_int;
    fn lua_tolstring(l: *mut LuaState, idx: c_int, len: *mut usize) -> *const c_char;
    fn lua_close(l: *mut LuaState);
    fn malloc(n: usize) -> *mut c_void;
    fn free(p: *mut c_void);
}

/// Appends to a Vec; false when it can't grow (Lua's memory error).
fn add(b: &mut Vec<u8>, bytes: &[u8]) -> bool {
    if b.try_reserve(bytes.len()).is_err() {
        return false;
    }
    b.extend_from_slice(bytes);
    true
}

/// lua_dump's writer: [ud] is the output Vec.
unsafe extern "C" fn writer(
    _l: *mut LuaState,
    p: *const c_void,
    sz: usize,
    ud: *mut c_void,
) -> c_int {
    // SAFETY: `ud` is the Vec `compile` passed to lua_dump, borrowed only
    // here for the call; Lua hands `sz` readable bytes at `p`.
    let (b, bytes) = unsafe {
        (
            &mut *(ud as *mut Vec<u8>),
            std::slice::from_raw_parts(p as *const u8, sz),
        )
    };
    if add(b, bytes) {
        0
    } else {
        1
    }
}

/// Compiles [src] as a text chunk named [name] in a fresh state: Ok(the
/// dumped chunk, host layout), or Err((status, message)) — 1 a syntax
/// error, 4 memory.
pub fn compile(src: &[u8], name: &CStr) -> Result<Vec<u8>, (i32, Vec<u8>)> {
    // SAFETY: a new state, closed below; nothing else holds it.
    let l = unsafe { luaL_newstate() };
    if l.is_null() {
        return Err((4, Vec::new()));
    }
    let mut b: Vec<u8> = Vec::new();
    // SAFETY: `l` is open; `src` is read within its length, `name` and the
    // mode are NUL-terminated; a load error stays inside the protected
    // call and leaves its message on the stack.
    let status = unsafe {
        luaL_loadbufferx(
            l,
            src.as_ptr().cast(),
            src.len(),
            name.as_ptr(),
            c"t".as_ptr(),
        )
    };
    let r = if status == LUA_OK {
        // SAFETY: the loaded function is on top of `l`'s stack; the writer
        // gets `b`, which outlives the call.
        let failed = unsafe { lua_dump(l, writer, (&mut b as *mut Vec<u8>).cast()) } != 0;
        if failed {
            Err((4, b))
        } else {
            Ok(b)
        }
    } else {
        let mut n = 0usize;
        // SAFETY: the error value is on top of the stack; a string's bytes
        // stay valid until the state closes (below, after the copy).
        let m = unsafe { lua_tolstring(l, -1, &mut n) };
        let msg: &[u8] = if m.is_null() {
            b"(no message)"
        } else {
            // SAFETY: lua_tolstring returned `n` bytes at `m`.
            unsafe { std::slice::from_raw_parts(m as *const u8, n) }
        };
        let ok = add(&mut b, msg);
        Err((if status == LUA_ERRMEM || !ok { 4 } else { 1 }, b))
    };
    // SAFETY: `l` is open and not used after.
    unsafe { lua_close(l) };
    r
}

/// Compiles [len] bytes of Lua source at [src] as a text chunk named
/// [name] in a fresh state. Returns 0 and the dumped chunk (host layout) in
/// *out, 1 (syntax error) or 4 (memory) with the error message in *out.
/// *out is malloc'd (or null when empty); release it with mcsm_luac_free.
///
/// # Safety
/// [src] holds [len] bytes; [name] is NUL-terminated; [out] and [outlen]
/// are writable.
#[no_mangle]
pub unsafe extern "C" fn mcsm_luac_compile(
    src: *const c_char,
    len: usize,
    name: *const c_char,
    out: *mut *mut c_char,
    outlen: *mut usize,
) -> c_int {
    // SAFETY: the caller's contract.
    let (src, name) = unsafe {
        (
            std::slice::from_raw_parts(src as *const u8, len),
            CStr::from_ptr(name),
        )
    };
    let (status, bytes) = match compile(src, name) {
        Ok(b) => (0, b),
        Err((s, b)) => (s, b),
    };
    let (p, n) = if bytes.is_empty() {
        (std::ptr::null_mut(), 0)
    } else {
        // SAFETY: a plain allocation of the chunk's size.
        let p = unsafe { malloc(bytes.len()) }.cast::<c_char>();
        if p.is_null() {
            return give(out, outlen, std::ptr::null_mut(), 0, 4);
        }
        // SAFETY: `p` has room for the bytes and doesn't overlap them.
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), p.cast(), bytes.len()) };
        (p, bytes.len())
    };
    give(out, outlen, p, n, status)
}

fn give(
    out: *mut *mut c_char,
    outlen: *mut usize,
    p: *mut c_char,
    n: usize,
    status: c_int,
) -> c_int {
    // SAFETY: mcsm_luac_compile's contract: both are writable.
    unsafe {
        *out = p;
        *outlen = n;
    }
    status
}

/// # Safety
/// [p] came from mcsm_luac_compile (or is null), released once.
#[no_mangle]
pub unsafe extern "C" fn mcsm_luac_free(p: *mut c_void) {
    // SAFETY: the caller's contract: malloc'd by mcsm_luac_compile.
    unsafe { free(p) };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg_attr(miri, ignore)]
    fn compiles_and_reports_syntax_errors() {
        let chunk = compile(b"return 1 + 2", c"=t").unwrap();
        // A 5.2 binary chunk: ESC "Lua", version 0x52.
        assert_eq!(&chunk[..5], b"\x1bLua\x52");
        let (status, msg) = compile(b"return +", c"=t").unwrap_err();
        assert_eq!(status, 1);
        assert!(String::from_utf8_lossy(&msg).starts_with("t:1:"));
    }

    #[test]
    fn the_writer_appends() {
        let mut b = Vec::new();
        assert!(add(&mut b, b"ab"));
        assert!(add(&mut b, b"c"));
        assert_eq!(b, b"abc");
    }
}

/// luaconf.h's `luai_numpow` (constant folding of `^`): the Dart VM's double
/// `pow` (its fast paths, then the libm crate's pow), as mcsm_lua's `luaPow`
/// and prismarine_math's `dpow` compute it, so folded constants are the same bits
/// on every target and equal the runtime's.
#[no_mangle]
pub extern "C" fn mcsm_luac_pow(b: f64, e: f64) -> f64 {
    if e == 0.0 {
        return 1.0;
    }
    if !e.is_nan() {
        if e == 1.0 {
            return b;
        }
        if e == 2.0 {
            return b * b;
        }
        if e == 3.0 {
            return b * b * b;
        }
    }
    if b.is_nan() {
        return f64::NAN;
    }
    if b == 1.0 {
        return 1.0;
    }
    if e.is_nan() {
        return f64::NAN;
    }
    if b != f64::NEG_INFINITY && e == 0.5 {
        if b == 0.0 {
            return 0.0;
        }
        return b.sqrt();
    }
    libm::pow(b, e)
}
