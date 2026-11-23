use super::cache::{self, Held, FAILED, QUEUED, READY};
use super::codec::Pcm;

/// The test loader: "<n>.pcm" decodes to n frames of mono ramps; anything
/// else fails.
fn load(path: &str) -> Option<Pcm> {
    let name = path.rsplit('/').next()?;
    let n: i64 = name.strip_suffix(".pcm")?.parse().ok()?;
    Some(Pcm {
        samples: (0..n).map(|i| i as f32).collect(),
        frames: n,
        channels: 1,
        rate: 48000,
    })
}

// One test: the cache is process-wide.
#[test]
fn cache_decodes_holds_and_drops() {
    cache::set_loader(load);
    cache::clear();
    let s0 = cache::stats();

    // Wanted ahead of need, then taken and waited for.
    let st = cache::want("t/16.pcm");
    assert!(st == QUEUED || st == READY || st == cache::DECODING);
    let h = Held::acquire("t/16.pcm");
    assert_eq!(h.wait(), READY);
    let p = h.entry().pcm().unwrap();
    assert_eq!((p.frames, p.channels, p.rate), (16, 1, 48000));
    assert_eq!(p.samples[15], 15.0);

    // A file that won't decode.
    let bad = Held::acquire("t/nothing.wav");
    assert_eq!(bad.wait(), FAILED);
    assert!(bad.entry().pcm().is_none());

    // Two scene changes drop what nobody holds or wanted since.
    let other = Held::acquire("t/8.pcm");
    assert_eq!(other.wait(), READY);
    drop(other);
    cache::scene_changed();
    cache::scene_changed();
    let s = cache::stats();
    // Held: 16 and the failed one; dropped: 8.
    assert_eq!(s[0] - s0[0], 2);
    assert_eq!(s[1] - s0[1], 16 * 4);
    assert!(s[5] > s0[5]);

    // Over budget: the oldest unheld entries go first.
    cache::set_budget(40 * 4);
    for n in [10, 11, 12] {
        let h = Held::acquire(&format!("t/{n}.pcm"));
        assert_eq!(h.wait(), READY);
    }
    let s = cache::stats();
    assert!(s[1] <= 40 * 4 + 16 * 4);
    // The held entry stays whatever the budget.
    assert_eq!(h.entry().pcm().unwrap().frames, 16);
    cache::set_budget(512 << 20);

    // A reference waited for on another thread.
    let x = Held::acquire("t/32.pcm");
    let t = std::thread::spawn(move || (x.wait(), x));
    let (st, x) = t.join().unwrap();
    assert_eq!(st, READY);
    assert_eq!(x.entry().pcm().unwrap().frames, 32);

    drop(x);
    drop(h);
    drop(bad);
    cache::clear();
    assert_eq!(cache::stats()[0], 0);
}

/// The vendored decoders on a real file (not under Miri: foreign code).
#[test]
#[cfg_attr(miri, ignore)]
fn decoders_reject_garbage() {
    assert!(super::codec::decode_mp3(&[]).is_none());
    assert!(super::codec::decode_ogg(&[0u8; 64]).is_none());
}

/// A prefetch asked for while the stream opens or once it is open is
/// served as the whole decode's samples, with nothing read as silence (the
/// test file is shorter than the ring, so this checks the bookkeeping, not
/// the timing).
#[test]
#[cfg_attr(miri, ignore)]
fn stream_prefetch_serves_the_decoded_samples() {
    use super::stream::Stream;
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/data/synthetic.ogg");
    let whole = super::codec::decode_ogg(&std::fs::read(path).unwrap()).unwrap();
    for before_open in [false, true] {
        let s = Stream::open(path, 0.1);
        if before_open {
            s.prefetch(48000);
        }
        let mut n = 0;
        while s.ready() != 1 {
            assert!(n < 2000, "stream did not open");
            n += 1;
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        if !before_open {
            s.prefetch(48000);
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
        let mut out = vec![0f32; 2048];
        assert_eq!(
            s.read(&mut out, 48000, 1024),
            1024,
            "before_open {before_open}"
        );
        assert_eq!(s.take_missing(), 0, "before_open {before_open}");
        assert_eq!(&out[..], &whole.samples[48000 * 2..(48000 + 1024) * 2]);
    }
}
