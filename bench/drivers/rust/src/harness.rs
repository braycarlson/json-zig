use std::hint::black_box;
use std::sync::OnceLock;
use std::time::Instant;

pub const MILLISECOND_NS: u64 = 1_000_000;
pub const RUN_COUNT_MAX: usize = 1_000_000;
pub const RUN_COUNT_MIN: usize = 20;
pub const TIME_MS_MIN_DEFAULT: u64 = 1_000;
pub const TIME_MS_MIN_MAX: u64 = 60_000;
pub const WARMUP_COUNT: u32 = 3;

static TIME_NS_MIN: OnceLock<u64> = OnceLock::new();

const _: () = assert!(RUN_COUNT_MIN > 1);
const _: () = assert!(RUN_COUNT_MIN < RUN_COUNT_MAX);
const _: () = assert!(TIME_MS_MIN_DEFAULT > 0);
const _: () = assert!(TIME_MS_MIN_DEFAULT <= TIME_MS_MIN_MAX);
const _: () = assert!(WARMUP_COUNT > 0);

pub struct Fnv {
    pub state: u64,
}

pub struct Sample {
    pub best_ns: u64,
    pub median_ns: u64,
    pub run_count: u32,
}

pub trait Workload {
    type Output<'a>
    where
        Self: 'a;

    fn prepare(&mut self);

    fn run(&mut self) -> Self::Output<'_>;
}

impl Fnv {
    pub const INITIAL: Fnv = Fnv {
        state: 0xcbf2_9ce4_8422_2325,
    };

    fn bytes(&mut self, bytes: &[u8]) {
        assert!(u32::try_from(bytes.len()).is_ok());

        for &byte in bytes {
            self.state ^= u64::from(byte);
            self.state = self.state.wrapping_mul(0x0100_0000_01b3);
        }
    }

    pub fn boolean(&mut self, value: bool) {
        self.bytes(&[u8::from(value)]);
    }

    pub fn hex(&self) -> String {
        let text = format!("{:016x}", self.state);

        assert_eq!(text.len(), 16);
        assert!(text.bytes().all(|byte| byte.is_ascii_hexdigit()));

        text
    }

    pub fn integer(&mut self, value: u64) {
        assert!((value | 1).leading_zeros() < u64::BITS);

        self.bytes(&value.to_le_bytes());
    }

    pub fn text(&mut self, value: &str) {
        assert!(u32::try_from(value.len()).is_ok());

        self.integer(value.len() as u64);
        self.bytes(value.as_bytes());
    }
}

pub fn measure<W: Workload>(workload: &mut W) -> Sample {
    let time_ns_min = *TIME_NS_MIN
        .get()
        .expect("main sets the minimum measured time before it measures");

    assert!(time_ns_min > 0);
    assert!(time_ns_min <= TIME_MS_MIN_MAX * MILLISECOND_NS);

    let mut samples: Vec<u64> = Vec::with_capacity(RUN_COUNT_MAX);

    for _ in 0..WARMUP_COUNT {
        workload.prepare();
        drop(black_box(workload.run()));
    }

    let mut time_ns_total: u64 = 0;

    for _ in 0..RUN_COUNT_MIN {
        time_ns_total += sample_push(workload, &mut samples);
    }

    while samples.len() < RUN_COUNT_MAX {
        if time_ns_total >= time_ns_min {
            break;
        }

        time_ns_total += sample_push(workload, &mut samples);
    }

    assert!(samples.len() >= RUN_COUNT_MIN);
    assert!(samples.len() <= RUN_COUNT_MAX);
    assert!(time_ns_total >= time_ns_min || samples.len() == RUN_COUNT_MAX);

    samples.sort_unstable();

    assert!(samples[0] <= samples[samples.len().div_euclid(2)]);
    assert!(samples[0] <= samples[samples.len() - 1]);

    Sample {
        best_ns: samples[0],
        median_ns: samples[samples.len().div_euclid(2)],
        run_count: u32::try_from(samples.len()).expect("the run count fits in u32"),
    }
}

pub fn report(bytes: u64, sample: &Sample, checksum: &str) {
    assert!(bytes > 0);
    assert!(sample.best_ns <= sample.median_ns);
    assert!(sample.run_count as usize >= RUN_COUNT_MIN);
    assert_ne!(checksum, "");

    println!(
        "bytes={} runs={} best_ns={} median_ns={} checksum={}",
        bytes, sample.run_count, sample.best_ns, sample.median_ns, checksum,
    );
}

pub fn time_ns_min_set(arguments: &[String]) -> Result<(), String> {
    let time_ms_min = match arguments {
        [] => TIME_MS_MIN_DEFAULT,
        [text] => text.parse::<u64>().map_err(|error| {
            format!("the minimum measured time {text:?} is not a count: {error}")
        })?,
        _ => {
            return Err(format!(
                "expected at most one minimum measured time, got {arguments:?}"
            ));
        }
    };

    if !(1..=TIME_MS_MIN_MAX).contains(&time_ms_min) {
        return Err(format!(
            "the minimum measured time {time_ms_min} ms is outside 1 to {TIME_MS_MIN_MAX}"
        ));
    }

    TIME_NS_MIN
        .set(time_ms_min * MILLISECOND_NS)
        .map_err(|_| "the minimum measured time is set once".to_string())?;

    assert_eq!(TIME_NS_MIN.get(), Some(&(time_ms_min * MILLISECOND_NS)));

    Ok(())
}

fn sample_push<W: Workload>(workload: &mut W, samples: &mut Vec<u64>) -> u64 {
    assert!(samples.len() < RUN_COUNT_MAX);
    assert!(samples.capacity() >= RUN_COUNT_MAX);

    workload.prepare();

    let start = Instant::now();
    let output = black_box(workload.run());
    let elapsed = start.elapsed();

    drop(output);

    let elapsed_ns = u64::try_from(elapsed.as_nanos()).expect("a run fits in u64 nanoseconds");

    samples.push(elapsed_ns);

    elapsed_ns
}
