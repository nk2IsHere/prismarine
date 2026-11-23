//! Audio decoding outside the Dart heap with the vendored decoders
//! ([codec]), the process-wide decoded-audio cache ([cache]), background
//! whole-file decodes ([jobs]) and streamed Ogg Vorbis ([stream]). [ffi] is
//! their C ABI for Dart in lib/src/native.dart. A crate that links this one
//! uses them directly.

pub mod cache;
pub mod codec;
pub mod ffi;
pub mod jobs;
mod os;
pub mod stream;

#[cfg(test)]
mod tests;
