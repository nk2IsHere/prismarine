//! Audio decoding outside the Dart heap: the vendored decoders ([codec]),
//! the process-wide decoded-audio cache ([cache]), background whole-file
//! decodes ([jobs]) and streamed Ogg Vorbis ([stream]); [ffi] is their C ABI
//! for Dart (lib/src/native.dart). The mixer uses them directly.

pub mod cache;
pub mod codec;
pub mod ffi;
pub mod jobs;
mod os;
pub mod stream;

#[cfg(test)]
mod tests;
