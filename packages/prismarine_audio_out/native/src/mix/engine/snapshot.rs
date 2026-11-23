//! Snapshot instances (snapshot.dart).

use super::*;

// ---------------------------------------------------------------- the mixer

pub struct Snap {
    pub(crate) def: &'static Event,
    pub(crate) order: i64,
    pub(crate) priority: i64,
    pub(crate) stopped: bool,
    pub(crate) values: Vec<f64>,
    /// Started by an event instrument: its snapshot intensity (0–1), and
    /// the key its asks use (−1 for a game's snapshot).
    pub(crate) scale: f64,
    pub(crate) key: i64,
}

impl Snap {
    /// A snapshot instance of [def] (built by the poster; the render gives
    /// it its order).
    pub fn build(def: &'static Event) -> Snap {
        Snap {
            def,
            order: 0,
            priority: def.priority,
            stopped: false,
            values: def
                .snap_params
                .iter()
                .map(|sp| def.params[sp.1].def)
                .collect(),
            scale: 1.0,
            key: -1,
        }
    }

    /// SnapshotInstance.setParameterGuid.
    pub(crate) fn set_guid(&mut self, guid: i32, value: f64) {
        let d = self.def;
        if let Some(i) = d
            .snap_params
            .iter()
            .position(|sp| d.params[sp.1].guid == guid)
        {
            let p = &d.params[d.snap_params[i].1];
            self.values[i] = dclamp(value, p.min, p.max);
        }
    }

    /// SnapshotInstance.setAuto.
    pub(crate) fn set_auto(&mut self, dist: f64, cone: f64) {
        let d = self.def;
        for (i, sp) in d.snap_params.iter().enumerate() {
            let p = &d.params[sp.1];
            if p.kind == 1 {
                self.values[i] = dclamp(dist, p.min, p.max);
            } else if p.kind == 2 {
                self.values[i] = dclamp(cone, p.min, p.max);
            }
        }
    }

    /// SnapshotInstance.entryValue: the entry's automation at the
    /// snapshot's parameters, else its stored value.
    pub(crate) fn entry_value(&self, en: &SnapEntry) -> f64 {
        let Some(p) = &en.auto else {
            return en.value;
        };
        let mut r: Option<f64> = None;
        for a in &p.autos {
            let v = mapped(p, curve_at(&a.curve, self.input(a)));
            r = Some(match r {
                None => v,
                Some(r) if p.volume => r + v,
                Some(_) => v,
            });
        }
        r.unwrap_or(en.value)
    }

    /// SnapshotInstance._input: the parameter by GUID, else by name.
    fn input(&self, a: &Auto) -> f64 {
        let d = self.def;
        if let Some(i) = d
            .snap_params
            .iter()
            .position(|sp| d.params[sp.1].guid == a.guid)
        {
            return self.values[i];
        }
        match d
            .snap_params
            .iter()
            .position(|sp| a.name >= 0 && sp.0 == a.name)
        {
            Some(i) => self.values[i],
            None => 0.0,
        }
    }

    pub(crate) fn intensity(&self) -> f64 {
        let d = self.def;
        let mut v = 1.0;
        if let Some(p) = &d.intensity_prop {
            if let Some(a) = p.autos.first() {
                let hit = d
                    .snap_params
                    .iter()
                    .position(|sp| a.name >= 0 && sp.0 == a.name);
                let x = match hit {
                    Some(i) => self.values[i],
                    None => self.values.first().copied().unwrap_or(0.0),
                };
                v = curve_at(&a.curve, x);
            }
        }
        dclamp(v * d.intensity * self.scale, 0.0, 1.0)
    }
}
