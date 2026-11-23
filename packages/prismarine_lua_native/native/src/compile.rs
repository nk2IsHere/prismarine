// Compiles Lua source with stock Lua 5.2.3, which build.rs builds from the
// vendored C with the luaconf.h of the crate, and returns the dumped chunk
// or the error text. Each call works in a fresh state. Lua catches its
// errors inside the protected call of luaL_loadbufferx, and no longjmp
// crosses Rust or Dart frames.
//
// `unsafe` is only at the FFI edge, the C API of Lua and the C ABI that Dart
// calls.

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

/// Appends to a Vec. Returns false when it cannot grow, a memory error of Lua.
fn add(b: &mut Vec<u8>, bytes: &[u8]) -> bool {
    if b.try_reserve(bytes.len()).is_err() {
        return false;
    }
    b.extend_from_slice(bytes);
    true
}

/// The writer of lua_dump. [ud] is the output Vec.
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

/// Compiles [src] as the text chunk [name] in a fresh state. Returns the
/// dumped chunk in the layout of the host, or the status and the message of
/// the error. The status is 1 for a syntax error and 4 for memory.
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

/// Compiles the [len] bytes of Lua source at [src] as the text chunk [name]
/// in a fresh state. Returns 0 with the dumped chunk in the layout of the
/// host in *out. Returns 1 for a syntax error or 4 for memory with the error
/// message in *out.
/// *out is allocated with malloc, or null when empty. Release it with the
/// free function of this library.
///
/// # Safety
/// [src] holds [len] bytes. [name] ends with NUL. [out] and [outlen] are
/// writable.
#[cfg_attr(lua_float32, export_name = "prismarine_luac32_compile")]
#[cfg_attr(not(lua_float32), export_name = "prismarine_luac64_compile")]
pub unsafe extern "C" fn luac_compile(
    src: *const c_char,
    len: usize,
    name: *const c_char,
    out: *mut *mut c_char,
    outlen: *mut usize,
) -> c_int {
    // SAFETY: the contract of the caller.
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
    // SAFETY: the contract of luac_compile makes both writable.
    unsafe {
        *out = p;
        *outlen = n;
    }
    status
}

/// # Safety
/// [p] came from luac_compile or is null, and is released once.
#[cfg_attr(lua_float32, export_name = "prismarine_luac32_free")]
#[cfg_attr(not(lua_float32), export_name = "prismarine_luac64_free")]
pub unsafe extern "C" fn luac_free(p: *mut c_void) {
    // SAFETY: the contract of the caller. luac_compile allocated it.
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

/// `luai_numpow` of luaconf.h for the constant folding of `^`. It is the
/// double `pow` of the Dart VM with its fast paths and then the pow of the
/// libm crate, as `dpow` of prismarine_math computes it. Folded constants are
/// the same bits on every target and equal the results of the runtime.
#[no_mangle]
pub extern "C" fn prismarine_luac_pow(b: f64, e: f64) -> f64 {
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
