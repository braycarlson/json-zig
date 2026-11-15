import functools
import gc
import json
import pathlib
import sys
import time

import msgspec
import orjson
import rapidjson
import simdjson
import ujson

import json_zig

from typing_extensions import Callable


ARGUMENT_COUNT_MAX = 4
ARGUMENT_COUNT_MIN = 3
MILLISECOND_NS = 1_000_000
RUN_COUNT_MAX = 1_000_000
RUN_COUNT_MIN = 20
SCALAR_TYPES = bool | int | float | str | None
SEPARATORS_COMPACT = (',', ':')
TIME_MS_MIN_DEFAULT = 1_000
TIME_MS_MIN_MAX = 60_000
WARMUP_COUNT = 3

DUMPERS = (
    ('json', functools.partial(json.dumps, ensure_ascii=False, separators=SEPARATORS_COMPACT)),
    ('json_zig', json_zig.dumps),
    ('msgspec', msgspec.json.Encoder().encode),
    ('orjson', orjson.dumps),
    ('rapidjson', functools.partial(rapidjson.dumps, ensure_ascii=False)),
    ('ujson', functools.partial(ujson.dumps, ensure_ascii=False, escape_forward_slashes=False)),
)

LOADERS = (
    ('json', json.loads),
    ('json_zig', json_zig.loads),
    ('msgspec', msgspec.json.Decoder().decode),
    ('orjson', orjson.loads),
    ('rapidjson', rapidjson.loads),
    ('simdjson', functools.partial(simdjson.Parser().parse, recursive=True)),
    ('ujson', ujson.loads),
)


def main() -> None:
    if not ARGUMENT_COUNT_MIN <= len(sys.argv) <= ARGUMENT_COUNT_MAX:
        message = 'usage: bench.py <loads|dumps>-<library> <path> [time_ms_min]'
        raise SystemExit(message)

    operation, _, library = sys.argv[1].partition('-')
    data = pathlib.Path(sys.argv[2]).read_bytes()
    time_ns_min = time_ns_min_of(sys.argv[ARGUMENT_COUNT_MIN:])

    if operation == 'loads':
        loads_measure(library, data, time_ns_min)
    elif operation == 'dumps':
        reference = json.loads(data)
        dumps_measure(library, reference, time_ns_min)
    else:
        message = f'unknown operation {operation}'
        raise SystemExit(message)


def count_of(root: object) -> int:
    if not isinstance(root, dict | list):
        message = f'a document root is an object or an array, not {type(root).__name__}'
        raise TypeError(message)

    count = 0
    pending = [root]

    while pending:
        value = pending.pop()
        count += 1

        if isinstance(value, dict):
            count += len(value)
            pending.extend(value.values())
        elif isinstance(value, list):
            pending.extend(value)
        elif isinstance(value, SCALAR_TYPES):
            continue
        else:
            message = f'unexpected {type(value).__name__} in a decoded document'
            raise TypeError(message)

    return count


def dumps_measure(library: str, reference: object, time_ns_min: int) -> None:
    if not 0 < time_ns_min <= TIME_MS_MIN_MAX * MILLISECOND_NS:
        message = f'the minimum measured time {time_ns_min} ns is outside its bounds'
        raise ValueError(message)

    if library not in dict(DUMPERS):
        message = f'no dumps for {library}'
        raise SystemExit(message)

    if not isinstance(reference, dict | list):
        message = f'a dumps reference is an object or an array, not {type(reference).__name__}'
        raise TypeError(message)

    function = dict(DUMPERS)[library]
    output = function(reference)
    encoded = output if isinstance(output, bytes) else output.encode()

    if json.loads(encoded) != reference:
        message = f'{library} wrote a document that does not read back as the input'
        raise RuntimeError(message)

    size_bytes = len(encoded)

    del output
    del encoded

    best_ns, median_ns, run_count = measure(reference, time_ns_min, function)

    report(
        best_ns=best_ns,
        checksum=str(size_bytes),
        median_ns=median_ns,
        run_count=run_count,
        size_bytes=size_bytes,
    )


def loads_measure(library: str, data: bytes, time_ns_min: int) -> None:
    if not 0 < time_ns_min <= TIME_MS_MIN_MAX * MILLISECOND_NS:
        message = f'the minimum measured time {time_ns_min} ns is outside its bounds'
        raise ValueError(message)

    if library not in dict(LOADERS):
        message = f'no loads for {library}'
        raise SystemExit(message)

    if not data:
        message = f'the {library} loads input is empty'
        raise ValueError(message)

    function = dict(LOADERS)[library]
    result = function(data)
    count = count_of(result)

    del result

    best_ns, median_ns, run_count = measure(data, time_ns_min, function)

    report(
        best_ns=best_ns,
        checksum=str(count),
        median_ns=median_ns,
        run_count=run_count,
        size_bytes=len(data),
    )

    if function(data) != json.loads(data):
        message = f'{library} decoded the input differently from the standard library'
        raise RuntimeError(message)


def measure(
    argument: object,
    time_ns_min: int,
    function: Callable[[object], object],
) -> tuple[int, int, int]:
    if not isinstance(argument, bytes | dict | list):
        message = f'a measured argument is bytes or a document, not {type(argument).__name__}'
        raise TypeError(message)

    if not 0 < time_ns_min <= TIME_MS_MIN_MAX * MILLISECOND_NS:
        message = f'the minimum measured time {time_ns_min} ns is outside its bounds'
        raise ValueError(message)

    clock = time.perf_counter_ns
    samples = []
    time_ns_total = 0

    for _ in range(WARMUP_COUNT):
        function(argument)

    gc.collect()
    gc.disable()

    while len(samples) < RUN_COUNT_MAX:
        if len(samples) >= RUN_COUNT_MIN:
            if time_ns_total >= time_ns_min:
                break

        start = clock()
        result = function(argument)
        elapsed_ns = clock() - start

        del result
        samples.append(elapsed_ns)
        time_ns_total += elapsed_ns

    gc.enable()
    samples.sort()

    if len(samples) < RUN_COUNT_MIN:
        message = f'only {len(samples)} runs completed, fewer than {RUN_COUNT_MIN}'
        raise RuntimeError(message)

    return samples[0], samples[len(samples) // 2], len(samples)


def report(
    *,
    best_ns: int,
    checksum: str,
    median_ns: int,
    run_count: int,
    size_bytes: int,
) -> None:
    if best_ns > median_ns:
        message = f'best {best_ns} exceeds median {median_ns}'
        raise RuntimeError(message)

    if not checksum:
        message = 'a report needs a checksum'
        raise ValueError(message)

    if run_count < RUN_COUNT_MIN:
        message = f'only {run_count} runs completed, fewer than {RUN_COUNT_MIN}'
        raise ValueError(message)

    if size_bytes <= 0:
        message = f'a report needs a positive size, not {size_bytes}'
        raise ValueError(message)

    line = (
        f'bytes={size_bytes} runs={run_count} best_ns={best_ns} '
        f'median_ns={median_ns} checksum={checksum}\n'
    )

    count = sys.stdout.write(line)

    if count != len(line):
        message = f'stdout took {count} of {len(line)} characters'
        raise OSError(message)

    sys.stdout.flush()


def time_ns_min_of(arguments: list[str]) -> int:
    if len(arguments) > 1:
        message = f'expected at most one minimum measured time, got {arguments}'
        raise SystemExit(message)

    text = arguments[0] if arguments else str(TIME_MS_MIN_DEFAULT)

    if not text.isdecimal():
        message = f'the minimum measured time is a count of milliseconds, not {text!r}'
        raise SystemExit(message)

    time_ms_min = int(text)

    if not 0 < time_ms_min <= TIME_MS_MIN_MAX:
        message = f'the minimum measured time {time_ms_min} ms is outside 1 to {TIME_MS_MIN_MAX}'
        raise SystemExit(message)

    return time_ms_min * MILLISECOND_NS


if __name__ == '__main__':
    main()
