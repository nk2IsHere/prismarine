//! Mix state instances, as mix_state.dart.

use super::*;

// ---------------------------------------------------------------- the mixer

pub struct Snap {
    pub(crate) def: &'static Event,
    pub(crate) order: i64,
    pub(crate) priority: i64,
    pub(crate) stopped: bool,
    pub(crate) values: Vec<f64>,
    /// The intensity from 0 to 1 of the instrument that started it and the
    /// key of its requests, −1 for a mix state that the game started.
    pub(crate) scale: f64,
    pub(crate) key: i64,
}

impl Snap {
    /// Makes a mix state instance of [def] on the poster. The render gives
    /// it its order.
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

    /// MixStateInstance.setParameterGuid.
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

    /// MixStateInstance.setAuto.
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

    /// Returns the value of an entry as MixStateInstance.entryValue, its
    /// automation at the parameters of the mix state, else its stored value.
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

    /// Returns the input of an automation as MixStateInstance._input, the
    /// parameter by id, else by name.
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
