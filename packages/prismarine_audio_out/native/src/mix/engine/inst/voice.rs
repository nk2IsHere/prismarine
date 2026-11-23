//! Rendering voices and nested events.

use super::*;

impl Inst {
    pub(super) fn render_voice(&mut self, cx: &mut Cx, s: &mut Sound, frames: i64) -> bool {
        let bus = s.bus;
        let Sound { delay, body, .. } = s;
        let Body::Voice {
            reader,
            rate,
            gain,
            lp,
            pos,
            pan,
            fade_from,
            faded,
            bend,
            armed,
        } = body
        else {
            unreachable!()
        };
        if !reader.src.ready()
            || (*armed && !stream_ready_at(cx.sh, reader, dfloor(dmax(*pos, 0.0))))
        {
            *delay = (*delay - frames).max(0);
            return true;
        }
        *armed = false;
        let src = &reader.src;
        let at = *delay;
        *delay = 0;
        if at >= frames {
            *delay = at - frames;
            return true;
        }
        let r = if *bend == 0.0 {
            *rate
        } else {
            *rate * dpow(2.0, *bend / 12.0)
        };
        let bus_mono = self.strips[bus].mono;
        // A quad source's rear pair goes to a 5.1 strip's SL and SR.
        let rear = self.strips[bus].wide && src.channels() >= 4;
        let (mut k, down) = src_format(src, bus_mono);
        let (mut gl, mut gr) = (1.0, 1.0);
        if let Some((l, r)) = *pan {
            if bus_mono {
                k *= (l * l + r * r).sqrt();
            } else {
                let sc = if src.channels() == 1 { 1.0 } else { SQRT2 };
                k = 1.0;
                gl = l * sc;
                gr = r * sc;
            }
        }
        let mut p = *pos;
        if let Some(from) = *fade_from {
            // A stolen voice: full gain up to the fade, then 64 frames down
            // to silence (Dart `_Voice.render`).
            let f0 = at.max(from);
            if f0 > at {
                let st = &mut self.strips[bus];
                let more = reader_add(
                    cx.sh,
                    &mut *cx.chunk,
                    reader,
                    &mut st.input,
                    if rear {
                        Some(&mut st.input51[..])
                    } else {
                        None
                    },
                    at,
                    f0 - at,
                    &mut p,
                    r,
                    *gain * k,
                    *gain * k,
                    None,
                    *lp,
                    down,
                    gl,
                    gr,
                );
                if !more {
                    return false;
                }
            }
            let n = (frames - f0).min(64 - *faded);
            let g0 = *gain * k * (1.0 - *faded as f64 / 64.0);
            let g1 = *gain * k * (1.0 - (*faded + n) as f64 / 64.0);
            let st = &mut self.strips[bus];
            let more = reader_add(
                cx.sh,
                &mut *cx.chunk,
                reader,
                &mut st.input,
                if rear {
                    Some(&mut st.input51[..])
                } else {
                    None
                },
                f0,
                n,
                &mut p,
                r,
                g0,
                g1,
                None,
                *lp,
                down,
                gl,
                gr,
            );
            *faded += n;
            *fade_from = Some(0);
            if !more || *faded >= 64 {
                return false;
            }
            *pos = p;
            return true;
        }
        let st = &mut self.strips[bus];
        let more = reader_add(
            cx.sh,
            &mut *cx.chunk,
            reader,
            &mut st.input,
            if rear {
                Some(&mut st.input51[..])
            } else {
                None
            },
            at,
            frames - at,
            &mut p,
            r,
            *gain * k,
            *gain * k,
            None,
            *lp,
            down,
            gl,
            gr,
        );
        if !more {
            return false;
        }
        *pos = p;
        true
    }

    pub(super) fn render_nested(&mut self, cx: &mut Cx, s: &mut Sound, frames: i64) -> bool {
        let bus = s.bus;
        if s.delay >= frames {
            s.delay -= frames;
            return true;
        }
        let at = s.delay;
        s.delay = 0;
        let Body::Nested { event, inst } = &mut s.body else {
            unreachable!()
        };
        for st in &inst.stubs {
            if let Some(v) = self.vals().automated(inst.prop(st.index), None) {
                event.set_param_guid(st.guid, v);
            }
        }
        let n = (frames - at) as usize;
        let ch = event.out_ch();
        let mut whole = std::mem::take(&mut event.nest_buf);
        if whole.len() < n * ch {
            problem!(
                cx,
                "nested event pass of {} frames in {}: over its room",
                n,
                cx.s(self.def.path)
            );
            event.nest_buf = whole;
            return true;
        }
        let buf = &mut whole[..n * ch];
        buf.fill(0.0);
        event.render(cx, buf, n as i64);
        if !event.snap_out.is_empty() {
            let mut out = std::mem::take(&mut event.snap_out);
            for op in out.drain(..) {
                if self.snap_out.len() < self.snap_out.capacity() {
                    self.snap_out.push(op);
                }
            }
            event.snap_out = out;
        }
        let at = at as usize;
        let strip = &mut self.strips[bus];
        if ch == 6 {
            // A 5.1 nested event (S2) goes in through the strip's 5.1 rule.
            if strip.wide {
                let inp = &mut strip.input51[at * 6..(at + n) * 6];
                for f in 0..n * 6 {
                    inp[f] = (inp[f] as f64 + buf[f] as f64) as f32;
                }
            } else {
                let mut st = [0.0f32; 2 * 64];
                let mut k = 0;
                while k < n {
                    let m = (n - k).min(64);
                    downmix51(&buf[k * 6..(k + m) * 6], m, &mut st[..m * 2]);
                    strip.add_stereo_at(&st[..m * 2], at + k, m);
                    k += m;
                }
            }
        } else if strip.mono {
            let input = &mut strip.input;
            for f in 0..n {
                let m = (buf[f * 2] as f64 + buf[f * 2 + 1] as f64) * UPMIX;
                input[(at + f) * 2] = (input[(at + f) * 2] as f64 + m) as f32;
                input[(at + f) * 2 + 1] = (input[(at + f) * 2 + 1] as f64 + m) as f32;
            }
        } else {
            let input = &mut strip.input;
            for f in 0..n * 2 {
                input[at * 2 + f] = (input[at * 2 + f] as f64 + buf[f] as f64) as f32;
            }
        }
        event.nest_buf = whole;
        for (key, val) in event.send_out.iter() {
            let Some(o) = self.send_out.put(key, frames as usize * 2) else {
                problem!(
                    cx,
                    "no room for send {} in {}",
                    cx.s(key),
                    cx.s(self.def.path)
                );
                continue;
            };
            for f in 0..val.len() {
                o[at * 2 + f] = (o[at * 2 + f] as f64 + val[f] as f64) as f32;
            }
        }
        !event.done
    }
}
