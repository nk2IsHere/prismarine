//! Background decodes: a waveform FMOD keeps in memory is decoded whole on a
//! worker thread, never on the render thread; the render polls the job and
//! the instrument starts once its data is there (FMOD 1.06's late start).

use std::collections::VecDeque;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};

use super::codec::{self, Pcm};

pub struct Job {
    path: String,
    /// 0 queued or decoding, 1 done, −1 failed.
    state: AtomicI32,
    pcm: OnceLock<Pcm>,
}

impl Job {
    pub fn state(&self) -> i32 {
        self.state.load(Ordering::Acquire)
    }
    /// A done job's audio.
    pub fn pcm(&self) -> Option<&Pcm> {
        if self.state() == 1 {
            self.pcm.get()
        } else {
            None
        }
    }
}

struct Queue {
    jobs: VecDeque<Arc<Job>>,
    worker: bool,
}

static QUEUE: Mutex<Queue> = Mutex::new(Queue {
    jobs: VecDeque::new(),
    worker: false,
});
static WORK: Condvar = Condvar::new();

fn worker() {
    loop {
        let job = {
            let mut q = QUEUE.lock().unwrap_or_else(|e| e.into_inner());
            loop {
                if let Some(j) = q.jobs.pop_front() {
                    break j;
                }
                q = WORK.wait(q).unwrap_or_else(|e| e.into_inner());
            }
        };
        // A job its owner let go of before it ran is still decoded; its
        // memory goes with the last reference.
        match codec::decode_file(&job.path) {
            Some(p) => {
                let _ = job.pcm.set(p);
                job.state.store(1, Ordering::Release);
            }
            None => job.state.store(-1, Ordering::Release),
        }
    }
}

/// Queues a whole-file decode of [path] (.ogg, or .mp3 by extension).
pub fn decode_async(path: &str) -> Arc<Job> {
    let job = Arc::new(Job {
        path: path.to_string(),
        state: AtomicI32::new(0),
        pcm: OnceLock::new(),
    });
    let mut q = QUEUE.lock().unwrap_or_else(|e| e.into_inner());
    q.jobs.push_back(job.clone());
    if !q.worker
        && std::thread::Builder::new()
            .name("prismarine-decode-job".into())
            .spawn(worker)
            .is_ok()
    {
        q.worker = true;
    }
    WORK.notify_one();
    job
}
