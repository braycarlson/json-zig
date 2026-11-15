# Benchmarks

A benchmark harness that compares json-zig with JSON libraries for Zig, C++, Rust, and Python.

## Overview

This directory holds everything behind the published numbers: the drivers for each language, the script that fetches and builds pinned versions of each library, the runner, the chart generator, and the raw measurements. Each implementation reads the same inputs, and the charts are drawn only when the implementations agree on the values they read. The numbers compare these libraries on one machine rather than predict the results on another CPU.

## Results

The [full tables](results.md) carry each input, both compilers, the ReleaseSafe build of json-zig for the x86-64 baseline, the invalid-input matrix, and the measurement environment.

## Workloads

| Workload | Description | Inputs |
|---|---|---|
| Parse into a document | Each implementation parses the input into its own document type. | Each of the ten inputs. |
| Decode into typed values | Each implementation decodes the input into the same typed models and skips the fields the models leave out. | The canada, twitter, and twitter_varied inputs. |
| Tokenize without building values | Each implementation walks each token of the input and builds no values. | Each of the ten inputs. |
| Write a document | Each implementation writes a document it parsed beforehand as compact JSON. | Each of the ten inputs. |
| Encode typed values | Each implementation encodes the decoded models as compact JSON, with null members written out. | The canada, twitter, and twitter_varied inputs. |
| Python loads | Each module turns the bytes of the input into Python objects. | Each of the ten inputs. |
| Python dumps | Each module turns the decoded objects into compact JSON. | Each of the ten inputs. |

The twitter model reads each status with its user and entities, plus the search metadata, and leaves out the rest of each status, including the retweeted status. The canada model reads each feature with its name and the coordinates of each ring.

### Inputs

The nine public inputs come from [simdjson-data](https://github.com/simdjson/simdjson-data) at commit `4197c42`. The tenth is generated.

| Input | Size | Description |
|---|---:|---|
| canada.json | 2.25 MB | The border of Canada as GeoJSON, made almost entirely of floating point numbers. |
| citm_catalog.json | 1.73 MB | A ticketing catalog with many small objects, integer keys, and French text. |
| github_events.json | 65 KB | A page of events from the GitHub API. |
| gsoc-2018.json | 3.33 MB | The Google Summer of Code 2018 projects, made mostly of long strings. |
| marine_ik.json | 2.98 MB | A three.js model with long arrays of floating point numbers. |
| mesh.json | 724 KB | A mesh of floating point positions and integer indices. |
| numbers.json | 150 KB | A single array of floating point numbers. |
| twitter.json | 632 KB | A Twitter search result with a large share of Japanese text. |
| twitter_varied.json | 18.9 MB | A file of 3,000 statuses built from twitter.json with randomized strings, numbers, and booleans, including escapes, emoji, and CJK text. |
| update-center.json | 533 KB | The Jenkins update center, made mostly of strings. |

### Implementations

| Implementation | Version | Interfaces |
|---|---|---|
| json-zig | This repository | The `json.Document` parser and writer, `json.decode`, `json.encode`, `json.Tokenizer`, and the `json_zig` Python module. |
| std.json | Zig 0.17.0 | The `std.json.Scanner` tokenizer, `parseFromSliceLeaky` into `std.json.Value` or a model, and `std.json.Stringify`. |
| simdjson | 5.1.1 | The DOM parser, a handwritten On-Demand reader for the models, and the DOM serializer. |
| yyjson | 0.13.0 | The `yyjson_read_opts` reader in situ with a pool allocator, and `yyjson_write_buf`. A second row stores numbers as raw text. |
| RapidJSON | Commit `297637b` | The `GenericDocument::ParseInsitu` parser with a memory pool, and `Writer`. |
| Glaze | 9.1.0 | The `glz::read` and `glz::write` functions. |
| serde_json | 1.0.154 | The `from_str` and `to_writer` functions, `Value`, and `IgnoredAny`. |
| sonic-rs | 0.5.10 | The `from_slice` and `to_writer` functions, and `Value`. |
| simd-json | 0.19.0 | The tape with serde for the models, the tape alone for documents, and `BorrowedValue` with its writer. |
| orjson | 3.13.0 | The `orjson.loads` and `orjson.dumps` functions. |
| msgspec | 0.22.0 | A reused `msgspec.json.Decoder` and `msgspec.json.Encoder`. |
| pysimdjson | 7.0.2 | A reused `simdjson.Parser` with `recursive=True`, for loads only. |
| python-rapidjson | 1.26 | The `rapidjson.loads` and `rapidjson.dumps` functions. |
| ujson | 6.1.0 | The `ujson.loads` and `ujson.dumps` functions. |
| json | CPython 3.14.4 | The `json.loads` and `json.dumps` functions from the standard library. |

## How It Works

Each measurement runs in a fresh process pinned with `taskset` to CPU 2, one P-core of an Intel Core i7-13700K. The driver reads the input and builds whatever the workload leaves untimed, such as the parsed document a writer writes, the models an encoder encodes, or the fresh copy of the input that an in situ parser writes into. The timed loop follows three warmups and continues until it has at least 20 runs and one second of them. The result is the fastest run, because interference only adds time to a run. The median run is less stable: the run time of some cells switches between two levels within one process, and the share of runs at each level changes from one process to the next. The published run shows the effect: the five median runs of the json-zig ReleaseSafe writer on canada.json range from 318 to 362 µs, and its five fastest runs range from 310 to 312 µs. Each row of `results/measurements.csv` records the median run beside the fastest.

A round measures each cell once in an order shuffled with a fixed seed, and the runner takes five rounds. The tables report the median of the fastest runs of the five rounds. The shuffle spreads slow drift, such as heat or a background job, across the implementations rather than onto whichever one happens to run at that moment.

The runner waits up to 15 seconds before each cell for CPU 3, the SMT sibling of the measured core, to go idle. A cell that saw more than 20 involuntary context switches in the child process, or a sibling more than 5% busy, runs again, up to six attempts. Each row of `results/measurements.csv` records the switches, the sibling load, and the attempts.

Each driver prints a checksum with its time: the count of values and keys for a document or a token stream, an FNV-1a hash over each decoded field for the models, and the output length for a writer. The model hash takes each floating point number by its bits, so a difference of one unit in the last place changes it. The chart generator stops when two implementations disagree on the values they read, so a library that rounds numbers differently or reads less of the input never reaches a chart. The Python driver also stops when a module loads objects that differ from those of the standard library, or writes output that does not load back as its input.

A read divides the input size by the time. A write divides the median output length across the implementations by the time, because the length of the output depends on how each writer formats numbers. The divisor is the same for each implementation, so a ratio of two throughputs is the ratio of their times. The charts show the geometric mean over the inputs.

## Configuration

A library keeps its own defaults unless a rule below needs otherwise, and each exception is named in the rule.

| Rule | Description |
|---|---|
| Identical values | Each implementation must decode the same values. The serde_json build enables `float_roundtrip`, and RapidJSON parses with `kParseFullPrecisionFlag`, because both libraries otherwise return doubles for canada.json that are not correctly rounded. |
| Full validation | Each implementation must reject malformed input where its interface allows. The RapidJSON parser uses `kParseValidateEncodingFlag`, the Glaze reader uses `validate_skipped` and `validate_trailing_whitespace`, and the serde_json driver reads through `std::str::from_utf8` and `from_str` because `from_slice` leaves the UTF-8 of skipped strings unchecked. |
| Untimed freeing | A result is freed or reset outside the timer. The Rust harness drops it after the clock stops, the C++ and Zig drivers reset it in an untimed preparation step before each run, and the Python driver deletes it after the clock stops, with the garbage collector disabled for the timed loop. |
| Reused buffers | Each library that can reuse its buffers between parses does so: the simdjson parser, the simd-json buffers and tape, the yyjson pool, the RapidJSON memory pool, the std.json arena, and the json-zig storage and region. The serde_json `Value` allocates each string, array, and object through the system allocator, and the sonic-rs `Value` allocates fresh buffers for each parse, because both types own their memory. |
| Input copies | A parser that writes into its input gets a fresh copy before each run, outside the timer. This applies to simd-json, yyjson in situ, and RapidJSON in situ. |
| Default allocators | Each allocation outside those buffers goes through the system allocator in C, C++, and Rust, and through the default of each module in Python. The simd-json README recommends mimalloc, which this harness does not use. |
| Native builds | The C, C++, Rust, and Zig code targets the native CPU. The C and C++ code is built with both GCC 15.2 and Clang 21.1 at `-O3`, RapidJSON with `RAPIDJSON_SSE42` for its SIMD whitespace and string scanning, and the Rust driver uses fat LTO with one codegen unit. The simd-json build turns off runtime detection, as its README advises for `target-cpu=native`. |
| Function alignment | Each function in the C, C++, Rust, and Zig drivers starts on a 64-byte boundary. GCC and Clang take `-falign-functions=64`, the Rust build takes `-C llvm-args=-align-all-functions=6`, and the Zig build links through a linker script with `SUBALIGN(64)`, because Zig has no such option. A function otherwise starts wherever the code before it ends, so a change to the harness can move the hot loop of a library: one such change slowed the serde_json writer by 25% while it ran the same instructions. |
| Zig builds | The json-zig rows show ReleaseFast and ReleaseSafe, and the tables add ReleaseSafe for the x86-64 baseline. The std.json rows are ReleaseFast. |
| Python | Each module receives the bytes of the file, and each writer emits UTF-8 rather than `\u` escapes. The json-zig module is the ReleaseFast manylinux wheel that `zig build wheel-host-3.14:json_zig` builds in `bindings/python`, and it selects its x86-64-v3 code on this CPU. The other modules are the wheels their projects publish on PyPI, except pysimdjson, which uv builds from its source distribution. |

### Disclosures

- **Lazy numbers**: The json-zig document keeps each number as its source text and converts it on access, so a number-heavy input (canada, marine_ik, mesh, and numbers) costs it less than it costs a parser that converts each number during the parse. The yyjson raw numbers row runs yyjson with `YYJSON_READ_NUMBER_AS_RAW`, the same strategy, as a control. The json-zig document writer copies the number text, and so does the yyjson raw numbers writer.
- **Reused targets**: The Glaze reader fills the object from the previous run, which is its documented interface, so its strings and vectors keep their capacity between runs. The json-zig decoder writes into a region and the std.json decoder into an arena, both reset before each run, and the other decoders allocate fresh values each run.
- **Skipped values**: The simdjson On-Demand reader checks UTF-8 and unescaped control characters across the whole input, along with each value it reads and the structure that leads to it. Its design leaves the numbers, the literals, and the bracket matching inside skipped values unchecked.
- **Python**: The standard library and ujson accept an encoded surrogate. The ujson module also accepts a raw control character in a string and a number with a leading zero.
- **Authorship**: The json-zig author wrote this harness. The drivers, inputs, raw measurements, and environment are all in this directory, and a correction is welcome as an issue or a pull request.
- **One machine**: The results come from one Raptor Lake P-core on Linux. Another CPU changes the numbers and can change the order.

## Validation

The `run.py` script runs each reader on eight corrupted copies of twitter.json before it measures anything, and it records whether the reader rejects each one in `results/validation.csv`. The corruptions sit in a string the models read, in values the models skip, and after the end of the document.

| Case | Corruption |
|---|---|
| `string_utf8` | A 0xFF byte inside a status text the models read. |
| `string_surrogate` | An encoded UTF-16 surrogate (ED A0 80) inside the same text. |
| `skipped_utf8` | A 0xFF byte inside a string the models skip. |
| `skipped_control` | A raw 0x01 byte inside a string the models skip. |
| `skipped_number` | A number with a leading zero, `01`, inside an object the models skip. |
| `skipped_literal` | The literal `fals` in place of `false` in a field the models skip. |
| `skipped_bracket` | A mismatched bracket, `[1}`, inside an object the models skip. |
| `trailing` | The character `x` after the end of the document. |

An implementation that accepts any of them carries an asterisk in the charts and tables, and the [validation table](results.md#validation) lists each outcome.

## Reproducing

### Prerequisites

| Tool | Version used |
|---|---|
| Linux with `taskset` | 7.0.0 |
| Zig | 0.17.0 |
| GCC | 15.2.0 |
| Clang | 21.1.8 |
| Rust | 1.99.0 |
| Python | 3.14.4 |
| uv | 0.13.7 |

### Running

```sh
cd bench
python3 build.py
python3 run.py
python3 chart.py
```

The `build.py` script fetches the pinned sources with git into `cache/`, prepares the inputs, and builds each driver. The `run.py` script takes about an hour and writes `results/`. The `chart.py` script writes the charts into `assets/` at the root of the repository and the tables into `results.md`. The runner pins CPU 2 and watches CPU 3, so a machine with another core layout needs `CPU_MEASURED` and `CPU_SIBLING` changed in `run.py`.
