mod harness;
mod models;

use std::marker::PhantomData;
use std::process::ExitCode;

use serde::de::IgnoredAny;
use serde::{Deserialize, Serialize};
use simd_json::prelude::Writable;
use simd_json::{BorrowedValue, Buffers, Deserializer, INPUT_PADDING, Tape};
use sonic_rs::{JsonContainerTrait, JsonValueTrait};

use crate::harness::Workload;
use crate::models::{Canada, Twitter};

const INPUT_BYTES_MAX: usize = 1 << 30;

struct CanadaModel;

struct Encode<'value, Value, Function> {
    output: Vec<u8>,
    value: &'value Value,
    write: Function,
}

struct Parse<'input, Function> {
    input: &'input [u8],
    parse: Function,
}

struct SimdDecode<'input, M> {
    buffers: Buffers,
    copy: Vec<u8>,
    input: &'input [u8],
    model: PhantomData<M>,
    tape: Option<Tape<'static>>,
}

struct SimdDocument<'input> {
    buffers: Buffers,
    copy: Vec<u8>,
    input: &'input [u8],
    tape: Option<Tape<'static>>,
}

struct TwitterModel;

trait Model {
    type Value<'a>: Deserialize<'a>;

    fn checksum(value: &Self::Value<'_>) -> String;
}

impl Model for CanadaModel {
    type Value<'a> = Canada<'a>;

    fn checksum(value: &Canada) -> String {
        models::canada_checksum(value)
    }
}

impl Model for TwitterModel {
    type Value<'a> = Twitter<'a>;

    fn checksum(value: &Twitter) -> String {
        models::twitter_checksum(value)
    }
}

impl<Value, Function> Workload for Encode<'_, Value, Function>
where
    Function: Fn(&mut Vec<u8>, &Value) -> Result<(), String>,
{
    type Output<'a>
        = u64
    where
        Self: 'a;

    fn prepare(&mut self) {
        assert_ne!(self.output.capacity(), 0);

        self.output.clear();
    }

    fn run(&mut self) -> u64 {
        assert_eq!(self.output.len(), 0);

        (self.write)(&mut self.output, self.value).expect("the value encoded before measurement");

        let length = self.output.len() as u64;

        assert_ne!(length, 0);

        length
    }
}

impl<'input, Value, Function> Workload for Parse<'input, Function>
where
    Function: Fn(&'input [u8]) -> Result<Value, String>,
{
    type Output<'a>
        = Value
    where
        Self: 'a;

    fn prepare(&mut self) {
        assert_ne!(self.input.len(), 0);
    }

    fn run(&mut self) -> Value {
        (self.parse)(self.input).expect("the input parsed before measurement")
    }
}

impl<M: Model> Workload for SimdDecode<'_, M> {
    type Output<'a>
        = M::Value<'a>
    where
        Self: 'a;

    fn prepare(&mut self) {
        assert!(self.copy.len() >= self.input.len() + INPUT_PADDING);
        assert!(self.tape.is_some());

        self.copy[..self.input.len()].copy_from_slice(self.input);
    }

    fn run(&mut self) -> M::Value<'_> {
        assert!(self.copy.len() >= self.input.len() + INPUT_PADDING);

        let taken = self.tape.take().expect("every run returns the tape");
        let mut tape = taken.reset();
        let length = self.input.len();

        simd_json::fill_tape_padded(&mut self.copy, length, &mut self.buffers, &mut tape)
            .expect("the input parsed before measurement");

        let mut deserializer = Deserializer::from_tape(tape);
        let value = <M::Value<'_>>::deserialize(&mut deserializer)
            .expect("the input decoded before measurement");

        self.tape = Some(deserializer.into_tape().reset());

        value
    }
}

impl Workload for SimdDocument<'_> {
    type Output<'a>
        = u64
    where
        Self: 'a;

    fn prepare(&mut self) {
        assert!(self.copy.len() >= self.input.len() + INPUT_PADDING);
        assert!(self.tape.is_some());

        self.copy[..self.input.len()].copy_from_slice(self.input);
    }

    fn run(&mut self) -> u64 {
        assert!(self.copy.len() >= self.input.len() + INPUT_PADDING);

        let taken = self.tape.take().expect("every run returns the tape");
        let mut tape = taken.reset();
        let length = self.input.len();

        simd_json::fill_tape_padded(&mut self.copy, length, &mut self.buffers, &mut tape)
            .expect("the input parsed before measurement");

        let count = tape.0.len() as u64;

        assert!(count > 0);

        self.tape = Some(tape.reset());

        count
    }
}

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().collect();

    if arguments.len() < 3 {
        eprintln!("usage: json_bench <mode> <path> [time_ms_min]");

        return ExitCode::from(2);
    }

    if let Err(message) = harness::time_ns_min_set(&arguments[3..]) {
        eprintln!("{message}");

        return ExitCode::from(2);
    }

    let input = match std::fs::read(&arguments[2]) {
        Ok(input) => input,
        Err(error) => {
            eprintln!("cannot read {}: {error}", arguments[2]);

            return ExitCode::from(2);
        }
    };

    if input.is_empty() {
        eprintln!("{} is empty", arguments[2]);

        return ExitCode::from(2);
    }

    if input.len() > INPUT_BYTES_MAX {
        eprintln!("{} exceeds {INPUT_BYTES_MAX} bytes", arguments[2]);

        return ExitCode::from(2);
    }

    match mode_run(&arguments[1], &input) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");

            ExitCode::FAILURE
        }
    }
}

fn encode_measure<Value>(
    value: &Value,
    write: impl Fn(&mut Vec<u8>, &Value) -> Result<(), String>,
) -> Result<(), String> {
    let mut output: Vec<u8> = Vec::new();

    write(&mut output, value)?;

    let length = output.len() as u64;

    assert_ne!(length, 0);

    let mut workload = Encode {
        output,
        value,
        write,
    };

    let sample = harness::measure(&mut workload);

    assert_eq!(workload.output.len() as u64, length);

    harness::report(length, &sample, &length.to_string());

    Ok(())
}

fn ignored_measure(input: &[u8]) -> Result<(), String> {
    assert_ne!(input.len(), 0);
    assert!(input.len() <= INPUT_BYTES_MAX);

    let text = serde_checksum(&serde_parse::<serde_json::Value>(input)?);

    assert_ne!(text, "");

    parse_measure(input, serde_parse::<IgnoredAny>, |_| text.clone())
}

fn mode_run(mode: &str, input: &[u8]) -> Result<(), String> {
    assert_ne!(input.len(), 0);
    assert!(input.len() <= INPUT_BYTES_MAX);

    match mode {
        "serde-decode-canada" => {
            parse_measure(input, serde_parse::<Canada>, models::canada_checksum)
        }
        "serde-decode-twitter" => {
            parse_measure(input, serde_parse::<Twitter>, models::twitter_checksum)
        }
        "serde-document" => parse_measure(input, serde_parse::<serde_json::Value>, serde_checksum),
        "serde-encode-canada" => encode_measure(&serde_parse::<Canada>(input)?, serde_write),
        "serde-encode-twitter" => encode_measure(&serde_parse::<Twitter>(input)?, serde_write),
        "serde-ignored" => ignored_measure(input),
        "serde-write" => encode_measure(&serde_parse::<serde_json::Value>(input)?, serde_write),
        "simd-decode-canada" => simd_decode_measure::<CanadaModel>(input),
        "simd-decode-twitter" => simd_decode_measure::<TwitterModel>(input),
        "simd-document" => simd_document_measure(input),
        "simd-encode-canada" => encode_measure(&serde_parse::<Canada>(input)?, simd_write),
        "simd-encode-twitter" => encode_measure(&serde_parse::<Twitter>(input)?, simd_write),
        "simd-write" => simd_value_measure(input),
        "sonic-decode-canada" => {
            parse_measure(input, sonic_parse::<Canada>, models::canada_checksum)
        }
        "sonic-decode-twitter" => {
            parse_measure(input, sonic_parse::<Twitter>, models::twitter_checksum)
        }
        "sonic-document" => parse_measure(input, sonic_parse::<sonic_rs::Value>, sonic_checksum),
        "sonic-encode-canada" => encode_measure(&serde_parse::<Canada>(input)?, sonic_write),
        "sonic-encode-twitter" => encode_measure(&serde_parse::<Twitter>(input)?, sonic_write),
        "sonic-write" => encode_measure(&sonic_parse::<sonic_rs::Value>(input)?, sonic_write),
        _ => Err(format!("unknown mode {mode}")),
    }
}

fn parse_measure<'input, Value>(
    input: &'input [u8],
    parse: impl Fn(&'input [u8]) -> Result<Value, String>,
    checksum: impl Fn(&Value) -> String,
) -> Result<(), String> {
    assert_ne!(input.len(), 0);
    assert!(input.len() <= INPUT_BYTES_MAX);

    let text = checksum(&parse(input)?);

    assert_ne!(text, "");

    let mut workload = Parse { input, parse };
    let sample = harness::measure(&mut workload);

    harness::report(input.len() as u64, &sample, &text);

    Ok(())
}

fn serde_checksum(root: &serde_json::Value) -> String {
    let mut stack = vec![root];
    let mut count: u64 = 0;

    for _ in 0..=INPUT_BYTES_MAX {
        let Some(value) = stack.pop() else {
            break;
        };

        count += 1;

        match value {
            serde_json::Value::Object(object) => {
                count += object.len() as u64;
                stack.extend(object.values());
            }
            serde_json::Value::Array(array) => stack.extend(array.iter()),
            serde_json::Value::Bool(_)
            | serde_json::Value::Null
            | serde_json::Value::Number(_)
            | serde_json::Value::String(_) => {}
        }
    }

    assert_eq!(stack.len(), 0);
    assert!(count > 0);

    count.to_string()
}

fn serde_parse<'input, Value: Deserialize<'input>>(input: &'input [u8]) -> Result<Value, String> {
    assert_ne!(input.len(), 0);
    assert!(input.len() <= INPUT_BYTES_MAX);

    let text = std::str::from_utf8(input).map_err(|error| error.to_string())?;

    serde_json::from_str(text).map_err(|error| error.to_string())
}

fn serde_write<Value: Serialize>(output: &mut Vec<u8>, value: &Value) -> Result<(), String> {
    assert_eq!(output.len(), 0);

    serde_json::to_writer(&mut *output, value).map_err(|error| error.to_string())?;

    assert_ne!(output.len(), 0);

    Ok(())
}

fn simd_decode_measure<M: Model>(input: &[u8]) -> Result<(), String> {
    assert_ne!(input.len(), 0);
    assert!(input.len() <= INPUT_BYTES_MAX);

    let mut validation = input.to_vec();

    simd_json::from_slice::<M::Value<'_>>(&mut validation).map_err(|error| error.to_string())?;

    let mut workload = SimdDecode::<M> {
        buffers: Buffers::new(input.len()),
        copy: vec![0; input.len() + INPUT_PADDING],
        input,
        model: PhantomData,
        tape: Some(Tape::null().reset()),
    };

    let sample = harness::measure(&mut workload);

    assert!(workload.tape.is_some());

    workload.prepare();

    let text = M::checksum(&workload.run());

    harness::report(input.len() as u64, &sample, &text);

    Ok(())
}

fn simd_document_measure(input: &[u8]) -> Result<(), String> {
    assert_ne!(input.len(), 0);
    assert!(input.len() <= INPUT_BYTES_MAX);

    let mut validation = input.to_vec();

    simd_json::to_tape(&mut validation).map_err(|error| error.to_string())?;

    let mut workload = SimdDocument {
        buffers: Buffers::new(input.len()),
        copy: vec![0; input.len() + INPUT_PADDING],
        input,
        tape: Some(Tape::null().reset()),
    };

    let sample = harness::measure(&mut workload);

    assert!(workload.tape.is_some());

    workload.prepare();

    let count = workload.run();

    assert!(count > 0);

    harness::report(input.len() as u64, &sample, &count.to_string());

    Ok(())
}

fn simd_value_measure(input: &[u8]) -> Result<(), String> {
    assert_ne!(input.len(), 0);
    assert!(input.len() <= INPUT_BYTES_MAX);

    let mut copy = input.to_vec();
    let value = simd_json::to_borrowed_value(&mut copy).map_err(|error| error.to_string())?;

    encode_measure(&value, simd_value_write)
}

fn simd_value_write(output: &mut Vec<u8>, value: &BorrowedValue) -> Result<(), String> {
    assert_eq!(output.len(), 0);

    value.write(output).map_err(|error| error.to_string())?;

    assert_ne!(output.len(), 0);

    Ok(())
}

fn simd_write<Value: Serialize>(output: &mut Vec<u8>, value: &Value) -> Result<(), String> {
    assert_eq!(output.len(), 0);

    simd_json::to_writer(&mut *output, value).map_err(|error| error.to_string())?;

    assert_ne!(output.len(), 0);

    Ok(())
}

fn sonic_checksum(root: &sonic_rs::Value) -> String {
    let mut stack = vec![root];
    let mut count: u64 = 0;

    for _ in 0..=INPUT_BYTES_MAX {
        let Some(value) = stack.pop() else {
            break;
        };

        count += 1;

        if let Some(object) = value.as_object() {
            count += object.len() as u64;
            stack.extend(object.iter().map(|(_, child)| child));
        } else if let Some(array) = value.as_array() {
            stack.extend(array.iter());
        } else {
            assert!(value.is_number() || value.is_str() || value.is_boolean() || value.is_null());
        }
    }

    assert_eq!(stack.len(), 0);
    assert!(count > 0);

    count.to_string()
}

fn sonic_parse<'input, Value: Deserialize<'input>>(input: &'input [u8]) -> Result<Value, String> {
    assert_ne!(input.len(), 0);
    assert!(input.len() <= INPUT_BYTES_MAX);

    sonic_rs::from_slice(input).map_err(|error| error.to_string())
}

fn sonic_write<Value: Serialize>(output: &mut Vec<u8>, value: &Value) -> Result<(), String> {
    assert_eq!(output.len(), 0);

    sonic_rs::to_writer(&mut *output, value).map_err(|error| error.to_string())?;

    assert_ne!(output.len(), 0);

    Ok(())
}
