//! Bus strips and their DSP chains, as strip.dart.

use super::*;

// ---------------------------------------------------------------- strips

pub(crate) trait Sink {
    fn prop(&mut self, owner: i32, index: i64) -> Option<f64>;
    /// [buf] is stereo, mono in both channels with [mono], or 5.1 when [ch]
    /// is 6.
    fn send(&mut self, fx: &'static Fx, buf: &[f32], mono: bool, ch: usize);
    fn sidechain(&mut self, targets: &[i32], buf: &[f32], keys: &mut Keys);
    /// An echo was asked for a longer delay than it was built for.
    fn refused(&mut self, fx: &'static Fx);
    /// An effect on a 5.1 strip has no 5.1 form and passes the signal.
    fn no51(&mut self, fx: &'static Fx);
}

// The render keeps every stage inline and allocates nothing for it.
#[allow(clippy::large_enum_variant)]
pub(crate) enum Stage {
    Fader,
    Effect {
        fx: &'static Fx,
        dsp: Dsp,
        key: Option<usize>,
    },
    Send(&'static Fx),
    Tap(&'static Fx),
}

static NO_BUS: Bus = Bus {
    guid: -1,
    master: false,
    output: -1,
    output_path: -1,
    path: -1,
    volume: 0.0,
    layout: 1,
    format: 0,
    fx: Vec::new(),
    props: Vec::new(),
};

/// The state that building needs, the model and the collector of the pools
/// of instances.
pub struct Build<'a> {
    pub m: &'static Model,
    pub garbage: &'a basedrop::Handle,
}

pub struct Strip {
    pub(crate) def: &'static Bus,
    pub(crate) mono: bool,
    /// The strip runs in 5.1 as a 5.1 bus or event strip, as Dart's
    /// `BusStrip._wide`.
    pub(crate) wide: bool,
    /// The stage index of its surround pan. Its output is 5.1 from there.
    pub(crate) surround: Option<usize>,
    /// The 5.1 input sum beside [input], on a strip that runs in 5.1.
    pub(crate) input51: Vec<f32>,
    /// The stereo chain before a surround pan on a strip that does not run
    /// in 5.1.
    pub(crate) work: Vec<f32>,
    pub(crate) st: Vec<Stage>,
    pub(crate) input: Vec<f32>,
    pub(crate) output: Vec<f32>,
    pub(crate) out_mono: bool,
    pub(crate) gain: Option<f64>,
    /// A gain ramp that the owner applies at the fader in this pass, as
    /// Dart's BusStrip.faderFrom and faderTo. The master track of an event
    /// takes the instance volume here.
    pub(crate) fader_from: f64,
    pub(crate) fader_to: f64,
    pub(crate) last_peak: f64,
    pub(crate) end_peak: f64,
}

/// Returns an upper bound of the value that automation, modulators or mix
/// states can give a property. The map of a mapped property ends there, and
/// else the largest values of the curves and the modulators add to [base].
fn prop_max(p: &Prop, base: f64) -> f64 {
    if let Some(m) = &p.map {
        return m.y.iter().copied().fold(base, f64::max);
    }
    let mut v = base;
    for a in &p.autos {
        v += a.curve.y.iter().copied().fold(0.0, f64::max);
    }
    for m in &p.mods {
        v += m.min.abs().max(m.max.abs()) / 100.0;
    }
    v
}

/// Returns the longest delay in frames that an echo can be asked for, from
/// its stored or default delay, its automation and modulators and the mix
/// states of it.
fn echo_room(m: &Model, fx: &Fx, keys: &[(i32, i64, Prop)]) -> i64 {
    let mut ms: f64 = 500.0;
    if let Some(p) = fx.params.first() {
        if let Some(v) = p.stored() {
            ms = ms.max(v);
        }
    }
    let base = ms;
    for p in fx
        .props
        .iter()
        .chain(keys.iter().filter(|k| k.0 == fx.guid).map(|k| &k.2))
    {
        if p.index == 1000 {
            ms = ms.max(prop_max(p, base));
        }
    }
    for d in &m.snaps {
        for en in &d.snap {
            if en.target == fx.guid && en.prop == 1000 {
                ms = ms.max(en.value);
            }
        }
    }
    dround(ms * RATE_F / 1000.0).max(1)
}

fn create_dsp(b: &Build, fx: &'static Fx, keys: &[(i32, i64, Prop)]) -> Option<Dsp> {
    if fx.dsp < 0 {
        return None;
    }
    let echo = if fx.dsp == crate::mix::dsp::ECHO {
        echo_room(b.m, fx, keys)
    } else {
        0
    };
    let mut d = Dsp::new(fx.dsp, &b.m.taps, echo)?;
    d.keep22k = !fx.pass_at_top;
    fx_params(&mut d, fx);
    d.start();
    Some(d)
}

/// Returns how many parameters of an effect automation and mix states can
/// address. A compressor with up to 6 stored parameters has 5 and its
/// sidechain and link parameters count only when the model stores them.
/// Dart's lookups of the others find nothing.
pub(crate) fn props_of(fx: &Fx, dsp: &Dsp) -> usize {
    if dsp.is_compressor() && fx.params.len() <= 6 {
        5
    } else {
        dsp.nparams()
    }
}

/// Sets the stored parameters of the effect, as a new DSP takes them.
fn fx_params(d: &mut Dsp, fx: &'static Fx) {
    for (i, p) in fx.params.iter().enumerate() {
        if p.has_value {
            d.set(i, p.value);
        }
    }
    if d.is_compressor() {
        d.set_use_sidechain(fx.sidechain_input);
    }
}

impl Strip {
    pub(crate) fn empty() -> Strip {
        Strip {
            def: &NO_BUS,
            mono: false,
            wide: false,
            surround: None,
            input51: Vec::new(),
            work: Vec::new(),
            st: Vec::new(),
            input: Vec::new(),
            output: Vec::new(),
            out_mono: false,
            gain: None,
            fader_from: 1.0,
            fader_to: 1.0,
            last_peak: 0.0,
            end_peak: 0.0,
        }
    }

    /// Builds the strip of bus [def] for passes of up to [frames] frames.
    /// Effects that the engine does not have go to [unsupported]. [keys] is
    /// the automation of an instance that its effects can get.
    pub(crate) fn build(
        b: &Build,
        def: &'static Bus,
        frames: usize,
        keys: &[(i32, i64, Prop)],
        unsupported: &mut Vec<&'static Fx>,
    ) -> Strip {
        let mut pre = Vec::new();
        let mut post = Vec::new();
        for fx in &def.fx {
            if fx.bypass {
                continue;
            }
            let stage = match fx.kind {
                FX_SEND => Stage::Send(fx),
                FX_SIDECHAIN => {
                    if fx.inactive {
                        continue;
                    }
                    Stage::Tap(fx)
                }
                FX_DSP => match create_dsp(b, fx, keys) {
                    Some(dsp) => Stage::Effect { fx, dsp, key: None },
                    None => {
                        unsupported.push(fx);
                        continue;
                    }
                },
                _ => continue,
            };
            if fx.prefader {
                pre.push(stage);
            } else {
                post.push(stage);
            }
        }
        pre.push(Stage::Fader);
        pre.extend(post);
        let (mono, wide) = match def.format {
            0 => (def.layout == LAYOUT_MONO, def.layout == LAYOUT_SURROUND51),
            f => (f == 1, f == 6),
        };
        let surround = pre
            .iter()
            .position(|s| matches!(s, Stage::Effect { dsp, .. } if dsp.surround()));
        // The DSPs that run 5.1 get their twins now and Dart's at first use.
        let from = if wide { Some(0) } else { surround };
        if let Some(from) = from {
            for st in pre.iter_mut().skip(from) {
                if let Stage::Effect { fx, dsp, .. } = st {
                    let echo = if fx.dsp == crate::mix::dsp::ECHO {
                        echo_room(b.m, fx, keys)
                    } else {
                        0
                    };
                    dsp.make_twins(&b.m.taps, echo, frames);
                }
            }
        }
        let out_ch = if wide || surround.is_some() { 6 } else { 2 };
        Strip {
            def,
            mono,
            wide,
            surround,
            input51: if wide {
                vec![0.0; frames * 6]
            } else {
                Vec::new()
            },
            work: if surround.is_some() && !wide {
                vec![0.0; frames * 2]
            } else {
                Vec::new()
            },
            st: pre,
            input: vec![0.0; frames * 2],
            output: vec![0.0; frames * out_ch],
            out_mono: false,
            gain: None,
            fader_from: 1.0,
            fader_to: 1.0,
            last_peak: 0.0,
            end_peak: 0.0,
        }
    }

    /// Resets the strip to new, as a new strip in Dart, in the memory that it
    /// has.
    pub(crate) fn reset(&mut self) {
        self.out_mono = false;
        self.gain = None;
        self.fader_from = 1.0;
        self.fader_to = 1.0;
        self.last_peak = 0.0;
        self.end_peak = 0.0;
        for s in self.st.iter_mut() {
            if let Stage::Effect { fx, dsp, .. } = s {
                dsp.reset();
                fx_params(dsp, fx);
                dsp.start();
            }
        }
    }

    /// Sets the position of the event on the pan DSPs of the strip.
    pub(crate) fn set_spatial(&mut self, azimuth: f64, distance: f64) {
        for s in self.st.iter_mut() {
            if let Stage::Effect { dsp, .. } = s {
                if dsp.kind == crate::mix::dsp::PAN {
                    dsp.set_spatial(azimuth, distance);
                }
            }
        }
    }

    pub(crate) fn effect(&mut self, guid: i32) -> Option<&mut Dsp> {
        for s in self.st.iter_mut() {
            if let Stage::Effect { fx, dsp, .. } = s {
                if fx.guid == guid {
                    return Some(dsp);
                }
            }
        }
        None
    }

    /// Starts a pass of [frames] frames, no more than the strip was built
    /// for. The output has 6 channels on a strip that runs in 5.1 or ends in
    /// 5.1 after a surround pan, else 2.
    pub(crate) fn out_ch(&self) -> usize {
        if self.wide || self.surround.is_some() {
            6
        } else {
            2
        }
    }

    pub(crate) fn begin(&mut self, frames: usize) {
        self.input[..frames * 2].fill(0.0);
        if self.wide {
            self.input51[..frames * 6].fill(0.0);
        }
    }

    /// Adds [buf], stereo, mono in both channels with [src_mono] or 5.1 when
    /// [src_ch] is 6, with the format rules of BusStrip.add.
    pub(crate) fn add(&mut self, buf: &[f32], frames: usize, src_mono: bool, src_ch: usize) {
        // A strip taken out while it processes, by a send into itself.
        if self.input.len() < frames * 2 {
            return;
        }
        if src_ch == 6 {
            self.add51(buf, frames);
            return;
        }
        let inp = &mut self.input;
        if src_mono == self.mono {
            for i in 0..frames * 2 {
                inp[i] = (inp[i] as f64 + buf[i] as f64) as f32;
            }
        } else if src_mono {
            for i in 0..frames * 2 {
                inp[i] = (inp[i] as f64 + buf[i] as f64 * UPMIX) as f32;
            }
        } else {
            for i in 0..frames {
                let m = (buf[i * 2] as f64 + buf[i * 2 + 1] as f64) * UPMIX;
                inp[i * 2] = (inp[i * 2] as f64 + m) as f32;
                inp[i * 2 + 1] = (inp[i * 2 + 1] as f64 + m) as f32;
            }
        }
    }

    pub(crate) fn keyed(&self, keys: &Keys) -> bool {
        for s in &self.st {
            if let Stage::Effect { dsp, key, .. } = s {
                if dsp.is_compressor()
                    && dsp.use_sidechain()
                    && key.is_some_and(|k| keys.slot[k].is_some())
                {
                    return true;
                }
            }
        }
        for s in &self.st {
            if let Stage::Effect { dsp, .. } = s {
                if dsp.ringing() {
                    return true;
                }
            }
        }
        false
    }

    pub(crate) fn quiet(&self, keys: &Keys) -> bool {
        self.end_peak < 1e-7 && !self.keyed(keys)
    }

    pub(crate) fn process(
        &mut self,
        frames: usize,
        sink: &mut dyn Sink,
        keys: &mut Keys,
        scratch: &mut [f32],
    ) {
        if self.out_ch() == 6 {
            self.process51(frames, sink, keys, scratch);
            return;
        }
        let n2 = frames * 2;
        let mut in_peak = 0.0f64;
        for i in 0..n2 {
            let a = (self.input[i] as f64).abs();
            if a > in_peak {
                in_peak = a;
            }
        }
        if in_peak == 0.0 && self.last_peak < 1e-7 && !self.keyed(keys) {
            let guid = self.def.guid;
            let vol = self.def.volume;
            for k in 0..self.st.len() {
                match &mut self.st[k] {
                    Stage::Fader => {
                        self.gain = Some(db_gain(sink.prop(guid, 0).unwrap_or(vol)));
                    }
                    Stage::Effect { dsp, key, .. } => {
                        let keyed = key.is_some_and(|k| keys.slot[k].is_some());
                        if dsp.idle(frames as i64, keyed) {
                            if let Some(k) = *key {
                                keys.slot[k] = None;
                            }
                        }
                    }
                    _ => {}
                }
            }
            self.output[..n2].fill(0.0);
            self.out_mono = self.mono;
            self.end_peak = 0.0;
            return;
        }
        self.output[..n2].copy_from_slice(&self.input[..n2]);
        let mut m = self.mono;
        for k in 0..self.st.len() {
            match &mut self.st[k] {
                Stage::Fader => {
                    let g = db_gain(sink.prop(self.def.guid, 0).unwrap_or(self.def.volume));
                    let g0 = self.gain.unwrap_or(g);
                    self.gain = Some(g);
                    let (e0, e1) = (self.fader_from, self.fader_to);
                    let out = &mut self.output;
                    for i in 0..frames {
                        let kk = (g0 + (g - g0) * (i as f64 / frames as f64))
                            * (e0 + (e1 - e0) * (i as f64 / frames as f64));
                        out[i * 2] = (out[i * 2] as f64 * kk) as f32;
                        out[i * 2 + 1] = (out[i * 2 + 1] as f64 * kk) as f32;
                    }
                }
                Stage::Effect { fx, dsp, key } => {
                    for i in 0..props_of(fx, dsp) {
                        if let Some(v) = sink.prop(fx.guid, 1000 + i as i64) {
                            dsp.set(i, v);
                        }
                    }
                    {
                        let kk = key.and_then(|k| keys.slot[k]).map(|i| &keys.pool[i][..]);
                        m = dsp.process(&mut self.output, frames, m, kk);
                    }
                    if dsp.take_refused() {
                        sink.refused(fx);
                    }
                    if dsp.is_compressor() {
                        if let Some(k) = *key {
                            keys.slot[k] = None;
                        }
                    }
                }
                Stage::Send(fx) => {
                    let fx = *fx;
                    let g = db_gain(sink.prop(fx.guid, 0).unwrap_or(fx.level));
                    if g == 0.0 {
                        continue;
                    }
                    for (d, &o) in scratch[..n2].iter_mut().zip(&self.output[..n2]) {
                        *d = (o as f64 * g) as f32;
                    }
                    sink.send(fx, &scratch[..n2], m, 2);
                }
                Stage::Tap(fx) => {
                    let fx = *fx;
                    sink.sidechain(&fx.targets, &self.output[..n2], keys);
                }
            }
        }
        self.out_mono = m;
        let (mut out_peak, mut end_peak) = (0.0f64, 0.0f64);
        let end = frames.saturating_sub(64) * 2;
        for i in 0..n2 {
            let a = (self.output[i] as f64).abs();
            if a > out_peak {
                out_peak = a;
            }
            if i >= end && a > end_peak {
                end_peak = a;
            }
        }
        self.last_peak = out_peak;
        self.end_peak = end_peak;
    }
}
