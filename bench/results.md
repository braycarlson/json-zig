# Benchmark results

The `chart.py` script generates this file from `results/measurements.csv`. The throughput is in GB/s (10^9 bytes per second), and higher is better. Each value is the median over 5 rounds of the fastest run in that round. A read divides the input size by the time. A write divides the median output length across implementations by the time, so every ratio within a column is a ratio of times. The summary ratio divides the json-zig throughput by the throughput of the fastest other implementation. An asterisk marks an implementation that accepts invalid input, and the Validation section lists each outcome.

## Summary

| Workload | json-zig | json-zig ReleaseSafe | Fastest other | Its throughput | Ratio |
|---|---:|---:|---|---:|---:|
| Parse into a document | 4.93 | 3.09 | simdjson (C++, GCC) | 3.46 | 1.43x |
| Decode into typed values | 3.48 | 2.63 | simdjson On-Demand (C++, Clang) * | 3.37 | 1.03x |
| Tokenize without building values | 4.11 | 2.94 | serde_json IgnoredAny (Rust) | 2.33 | 1.77x |
| Write a document | 9.61 | 6.64 | yyjson raw numbers (C++, GCC) | 4.22 | 2.28x |
| Encode typed values | 4.45 | 3.55 | Glaze (C++, GCC) | 4.08 | 1.09x |
| Python loads | 1.26 | n/a | orjson | 1.06 | 1.19x |
| Python dumps | 2.94 | n/a | orjson | 2.14 | 1.37x |

## Parse into a document

| Implementation | canada | citm_catalog | github_events | gsoc-2018 | marine_ik | mesh | numbers | twitter | twitter_varied | update-center | Geomean |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| json-zig (Zig, ReleaseFast) | **3.97** | **7.94** | **7.98** | **8.34** | **2.66** | **3.17** | **4.72** | **6.78** | 2.54 | **5.91** | **4.93** |
| simdjson (C++, GCC) | 1.76 | 6.09 | 6.92 | 7.08 | 1.75 | 1.76 | 2.00 | 5.99 | **2.62** | 4.80 | 3.46 |
| simdjson (C++, Clang) | 1.68 | 6.31 | 6.99 | 7.04 | 1.67 | 1.64 | 1.95 | 6.27 | 2.58 | 5.16 | 3.44 |
| json-zig (Zig, ReleaseSafe) | 2.23 | 4.92 | 5.04 | 5.83 | 1.67 | 1.86 | 2.75 | 4.19 | 1.88 | 3.62 | 3.09 |
| yyjson (C++, Clang) | 2.05 | 5.54 | 4.89 | 4.35 | 1.88 | 1.81 | 2.11 | 5.17 | 0.94 | 2.90 | 2.75 |
| yyjson raw numbers (C++, Clang) | 2.42 | 5.24 | 4.84 | 4.35 | 1.97 | 1.63 | 1.97 | 5.07 | 0.93 | 2.89 | 2.73 |
| yyjson raw numbers (C++, GCC) | 2.16 | 4.82 | 4.76 | 4.32 | 2.06 | 1.72 | 2.11 | 4.80 | 0.88 | 3.16 | 2.71 |
| yyjson (C++, GCC) | 1.71 | 5.15 | 4.80 | 4.31 | 1.76 | 1.60 | 1.85 | 4.87 | 0.89 | 3.14 | 2.58 |
| sonic-rs (Rust) | 1.56 | 4.03 | 4.73 | 6.31 | 1.37 | 1.44 | 1.40 | 3.29 | 1.54 | 3.96 | 2.52 |
| json-zig (Zig, ReleaseSafe, x86-64 baseline) | 2.27 | 3.33 | 3.90 | 5.82 | 1.70 | 1.61 | 2.30 | 3.23 | 0.88 | 2.98 | 2.49 |
| simd-json (Rust) | 1.29 | 3.56 | 3.40 | 5.30 | 1.11 | 1.07 | 1.42 | 3.18 | 2.19 | 2.37 | 2.17 |
| RapidJSON (C++, GCC) | 0.45 | 2.97 | 1.59 | 1.84 | 1.00 | 0.81 | 0.85 | 1.20 | 0.63 | 1.37 | 1.11 |
| RapidJSON (C++, Clang) | 0.46 | 1.95 | 0.93 | 1.04 | 0.84 | 0.75 | 0.78 | 0.85 | 0.51 | 0.74 | 0.82 |
| serde_json (Rust) | 0.36 | 1.19 | 0.81 | 2.05 | 0.55 | 0.50 | 0.88 | 0.70 | 0.42 | 0.61 | 0.71 |
| std.json (Zig, ReleaseFast) | 0.32 | 0.65 | 0.52 | 0.45 | 0.22 | 0.22 | 0.33 | 0.55 | 0.34 | 0.34 | 0.37 |

## Decode into typed values

| Implementation | canada | twitter | twitter_varied | Geomean |
|---|---:|---:|---:|---:|
| json-zig (Zig, ReleaseFast) | **1.98** | 6.68 | 3.18 | **3.48** |
| simdjson On-Demand (C++, Clang) * | 1.68 | **6.82** | 3.36 | 3.37 |
| simdjson On-Demand (C++, GCC) * | 1.69 | 6.57 | **3.43** | 3.37 |
| json-zig (Zig, ReleaseSafe) | 1.45 | 4.97 | 2.54 | 2.63 |
| Glaze (C++, Clang) | 1.81 | 2.89 | 1.51 | 1.99 |
| Glaze (C++, GCC) | 1.85 | 2.66 | 1.35 | 1.88 |
| simd-json (Rust) | 1.08 | 2.49 | 1.75 | 1.68 |
| json-zig (Zig, ReleaseSafe, x86-64 baseline) | 1.34 | 3.66 | 0.94 | 1.66 |
| sonic-rs (Rust) | 0.90 | 2.48 | 1.51 | 1.50 |
| serde_json (Rust) | 0.67 | 1.83 | 0.69 | 0.95 |
| std.json (Zig, ReleaseFast) | 0.56 | 0.83 | 0.46 | 0.59 |

## Tokenize without building values

| Implementation | canada | citm_catalog | github_events | gsoc-2018 | marine_ik | mesh | numbers | twitter | twitter_varied | update-center | Geomean |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| json-zig (Zig, ReleaseFast) | **3.03** | **5.78** | **6.37** | **9.83** | **2.15** | **2.55** | **3.91** | **5.18** | **2.85** | **4.00** | **4.11** |
| json-zig (Zig, ReleaseSafe) | 2.07 | 4.10 | 4.55 | 7.50 | 1.51 | 1.73 | 2.51 | 3.79 | 2.22 | 3.00 | 2.94 |
| serde_json IgnoredAny (Rust) | 2.13 | 2.71 | 3.88 | 5.52 | 1.61 | 1.93 | 2.25 | 2.45 | 0.76 | 2.86 | 2.33 |
| json-zig (Zig, ReleaseSafe, x86-64 baseline) | 1.86 | 2.92 | 3.81 | 6.75 | 1.23 | 1.21 | 1.94 | 3.11 | 0.92 | 2.41 | 2.21 |
| std.json (Zig, ReleaseFast) | 1.36 | 1.28 | 0.89 | 0.51 | 0.92 | 1.09 | 1.39 | 1.03 | 0.52 | 0.65 | 0.91 |

## Write a document

| Implementation | canada | citm_catalog | github_events | gsoc-2018 | marine_ik | mesh | numbers | twitter | twitter_varied | update-center | Geomean |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| json-zig (Zig, ReleaseFast) | **9.54** | **5.91** | **13.1** | **23.4** | **4.75** | **7.21** | **12.9** | **12.0** | **7.51** | **9.68** | **9.61** |
| json-zig (Zig, ReleaseSafe) | 6.73 | 3.94 | 9.17 | 21.6 | 3.05 | 4.63 | 8.17 | 7.62 | 5.59 | 6.47 | 6.64 |
| json-zig (Zig, ReleaseSafe, x86-64 baseline) | 6.60 | 3.88 | 8.68 | 19.8 | 2.98 | 4.43 | 7.84 | 7.34 | 5.34 | 6.22 | 6.38 |
| yyjson raw numbers (C++, GCC) | 5.85 | 4.12 | 8.49 | 4.96 | 2.27 | 4.20 | 8.30 | 6.48 | 0.83 | 4.14 | 4.22 |
| yyjson raw numbers (C++, Clang) | 5.56 | 3.62 | 6.31 | 4.71 | 2.15 | 4.42 | 9.18 | 4.93 | 0.78 | 3.35 | 3.82 |
| yyjson (C++, GCC) | 1.30 | 4.00 | 8.49 | 4.96 | 0.91 | 1.36 | 1.09 | 6.51 | 0.83 | 4.15 | 2.41 |
| yyjson (C++, Clang) | 1.44 | 3.93 | 6.43 | 4.71 | 1.14 | 1.69 | 1.40 | 5.06 | 0.78 | 3.35 | 2.39 |
| sonic-rs (Rust) | 1.25 | 1.62 | 4.07 | 9.45 | 0.68 | 0.99 | 1.18 | 3.33 | 1.67 | 2.98 | 2.00 |
| simdjson (C++, Clang) | 0.96 | 2.06 | 4.55 | 6.79 | 0.64 | 0.88 | 0.89 | 3.85 | 1.43 | 2.80 | 1.85 |
| simdjson (C++, GCC) | 0.77 | 2.25 | 5.13 | 7.32 | 0.59 | 0.77 | 0.73 | 4.26 | 1.50 | 3.10 | 1.83 |
| serde_json (Rust) | 1.28 | 1.63 | 2.51 | 3.30 | 0.71 | 1.03 | 1.20 | 2.35 | 1.11 | 1.91 | 1.54 |
| simd-json (Rust) | 0.96 | 1.69 | 3.38 | 6.39 | 0.42 | 0.65 | 0.70 | 1.80 | 1.02 | 1.95 | 1.37 |
| RapidJSON (C++, Clang) | 0.48 | 1.74 | 3.51 | 5.57 | 0.49 | 0.62 | 0.53 | 2.61 | 0.90 | 2.02 | 1.29 |
| RapidJSON (C++, GCC) | 0.43 | 1.47 | 2.80 | 4.68 | 0.47 | 0.54 | 0.44 | 1.98 | 0.79 | 1.60 | 1.09 |
| std.json (Zig, ReleaseFast) | 0.65 | 0.97 | 1.12 | 0.50 | 0.30 | 0.49 | 0.53 | 1.08 | 0.35 | 0.63 | 0.61 |

## Encode typed values

| Implementation | canada | twitter | twitter_varied | Geomean |
|---|---:|---:|---:|---:|
| json-zig (Zig, ReleaseFast) | **1.83** | **13.1** | **3.67** | **4.45** |
| Glaze (C++, GCC) | 1.71 | 11.5 | 3.45 | 4.08 |
| json-zig (Zig, ReleaseSafe) | 1.30 | 10.7 | 3.21 | 3.55 |
| json-zig (Zig, ReleaseSafe, x86-64 baseline) | 1.11 | 9.86 | 3.15 | 3.26 |
| Glaze (C++, Clang) | 1.04 | 8.80 | 2.99 | 3.01 |
| sonic-rs (Rust) | 1.53 | 4.51 | 2.26 | 2.50 |
| serde_json (Rust) | 1.62 | 2.69 | 1.75 | 1.97 |
| simd-json (Rust) | 1.12 | 2.91 | 1.59 | 1.73 |
| std.json (Zig, ReleaseFast) | 0.77 | 1.01 | 0.35 | 0.65 |

## Python loads

| Implementation | canada | citm_catalog | github_events | gsoc-2018 | marine_ik | mesh | numbers | twitter | twitter_varied | update-center | Geomean |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| json-zig | **1.16** | **1.90** | **1.94** | **2.34** | **0.87** | 0.97 | **1.66** | **1.40** | **0.51** | **1.01** | **1.26** |
| orjson | 1.07 | 1.75 | 1.78 | 1.38 | 0.59 | **1.09** | 1.50 | 1.33 | 0.35 | 0.87 | 1.06 |
| msgspec | 0.87 | 1.10 | 1.58 | 1.81 | 0.71 | 0.85 | 1.22 | 0.93 | 0.36 | 0.85 | 0.94 |
| pysimdjson | 0.82 | 1.29 | 1.32 | 1.57 | 0.65 | 0.78 | 1.13 | 0.73 | 0.33 | 0.51 | 0.83 |
| ujson * | 0.39 | 1.16 | 0.91 | 1.12 | 0.54 | 0.61 | 0.62 | 0.70 | 0.35 | 0.54 | 0.64 |
| json (stdlib) * | 0.14 | 0.40 | 0.57 | 0.93 | 0.26 | 0.27 | 0.28 | 0.34 | 0.21 | 0.35 | 0.33 |
| python-rapidjson | 0.13 | 0.39 | 0.59 | 0.83 | 0.26 | 0.27 | 0.30 | 0.38 | 0.16 | 0.30 | 0.31 |

## Python dumps

| Implementation | canada | citm_catalog | github_events | gsoc-2018 | marine_ik | mesh | numbers | twitter | twitter_varied | update-center | Geomean |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| json-zig | **1.68** | **2.42** | **7.38** | **10.8** | **1.05** | **1.51** | **1.72** | **6.03** | **1.90** | **4.69** | **2.94** |
| orjson | 1.43 | 1.89 | 4.45 | 8.19 | 0.86 | 1.21 | 1.25 | 3.40 | 1.66 | 2.80 | 2.14 |
| msgspec | 0.92 | 1.76 | 2.90 | 3.44 | 0.49 | 0.75 | 0.72 | 2.57 | 1.35 | 1.98 | 1.40 |
| ujson | 0.26 | 0.38 | 0.60 | 0.44 | 0.23 | 0.30 | 0.29 | 0.58 | 0.20 | 0.38 | 0.34 |
| python-rapidjson | 0.09 | 0.44 | 1.04 | 1.22 | 0.10 | 0.11 | 0.09 | 0.83 | 0.33 | 0.81 | 0.32 |
| json (stdlib) | 0.08 | 0.23 | 0.38 | 0.32 | 0.09 | 0.11 | 0.09 | 0.37 | 0.21 | 0.30 | 0.19 |

## Validation

| Workload | Implementation | `skipped_bracket` | `skipped_control` | `skipped_literal` | `skipped_number` | `skipped_utf8` | `string_surrogate` | `string_utf8` | `trailing` |
|---|---|---|---|---|---|---|---|---|---|
| decode | Glaze | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| decode | json-zig | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| decode | serde_json | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| decode | simd-json | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| decode | simdjson On-Demand | **accepts** | rejects | **accepts** | **accepts** | rejects | rejects | rejects | rejects |
| decode | sonic-rs | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| decode | std.json | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| document | json-zig | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| document | RapidJSON | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| document | serde_json | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| document | simd-json | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| document | simdjson | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| document | sonic-rs | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| document | std.json | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| document | yyjson | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| document | yyjson raw numbers | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| loads | json (stdlib) | rejects | rejects | rejects | rejects | rejects | **accepts** | rejects | rejects |
| loads | json-zig | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| loads | msgspec | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| loads | orjson | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| loads | pysimdjson | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| loads | python-rapidjson | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| loads | ujson | rejects | **accepts** | rejects | **accepts** | rejects | **accepts** | rejects | rejects |
| tokenize | json-zig | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| tokenize | serde_json IgnoredAny | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |
| tokenize | std.json | rejects | rejects | rejects | rejects | rejects | rejects | rejects | rejects |

## Measurement quality

| Measure | Value |
|---|---|
| Cells | 540 |
| Measurements | 2700 |
| Median spread of the fastest runs over the rounds, (max - min) / median | 0.8% |
| Worst spread of the fastest runs over the rounds | 20.3% (write twitter.json, RapidJSON GCC) |
| Measurements retried for interference | 37 |
| Measurements without a quiet attempt | 0 |
| Measurements with another CPU at least 50% busy | 2181 (81%) |

## Environment

| Property | Value |
|---|---|
| CPU | 13th Gen Intel(R) Core(TM) i7-13700K |
| Microcode | 0x133 |
| Pinned CPU | 2, SMT sibling 3 watched |
| Governor and EPP | powersave, power |
| Turbo boost | enabled |
| Kernel | 7.0.0-43-generic |
| Zig | 0.17.0 |
| GCC | g++ (Ubuntu 15.2.0-16ubuntu1) 15.2.0 |
| Clang | Ubuntu clang version 21.1.8 (6ubuntu1) |
| Rust | rustc 1.99.0 (b940084d7 2026-09-28) |
| Python | Python 3.14.4 |
| json-zig commit | b0acdea88eeb7ec2e9c78b5a605b6d13b734d679 |
| Modified paths in the working tree | 30 |
| Load average at start | 3.05 |
| Started (UTC) | 2026-11-08T13:16:52Z |
| Finished (UTC) | 2026-11-08T14:34:23Z |
