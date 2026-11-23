//! The render, as prismarine_audio's AudioEngine (engine.dart), EventPlayer
//! (player.dart), EventInstance and its sounds (instance.dart), SourceReader
//! (voice.dart), BusStrip (strip.dart), MixerGraph (graph.dart),
//! MixStateInstance (mix_state.dart), Curve and PiecewiseMap (curve.dart)
//! and Rng (rng.dart), function for function and in the same float order.
//! It runs on one thread at a time, the device's in real time and the
//! caller's in lockstep.

use std::fmt::Write as _;
use std::sync::atomic::Ordering;

use crate::mix::dmath::*;
use crate::mix::dsp::{Dsp, Keys};
use crate::mix::model::*;
use crate::mix::source::{Kind, Src, SrcRef};
use crossbeam_queue::ArrayQueue;
use crossbeam_utils::CachePadded;

use basedrop::Owned;

#[macro_use]
mod cx;
mod cmd;
mod core;
mod core_apply;
mod graph;
mod inst;
mod reader;
mod snapshot;
mod strip;
mod strip51;

pub use self::core::*;
pub use cmd::*;
pub use cx::*;
use graph::*;
pub use inst::Inst;
pub use inst::*;
use reader::*;
pub use snapshot::*;
pub use strip::*;
use strip51::*;
