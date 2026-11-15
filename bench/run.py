import csv
import dataclasses
import json
import os
import pathlib
import platform
import random
import resource
import subprocess
import sys
import time


ROOT = pathlib.Path(__file__).resolve().parent
CACHE = ROOT / 'cache'
CORPUS = CACHE / 'corpus'
CPP = CACHE / 'cpp'
INVALID = CORPUS / 'invalid'
RESULTS = ROOT / 'results'
VENV_PYTHON = CACHE / 'venv' / 'bin' / 'python'
ZIG = CACHE / 'zig'
ATTEMPT_COUNT_MAX = 6
BACKGROUND_BUSY_MIN = 0.5
CELL_SECONDS_MAX = 900
COMPILERS = (('clang', 'Clang'), ('gcc', 'GCC'))
CPU_MEASURED = 2
CPU_SIBLING = 3
OUTPUT_KEYS = ('best_ns', 'bytes', 'checksum', 'median_ns', 'runs')
QUIET_POLL_COUNT_MAX = 60
QUIET_POLL_SECONDS = 0.25
RETRY_PAUSE_SECONDS = 2.0
ROUND_COUNT = 5
ROUND_SEED = 20261107
SIBLING_BUSY_MAX = 0.05
SIBLING_QUIET_MAX = 0.10
SWITCH_COUNT_MAX = 20
WORKLOADS = ('decode', 'document', 'dumps', 'encode', 'loads', 'tokenize', 'write')
WORKLOADS_READ = ('decode', 'document', 'loads', 'tokenize')
WORKLOADS_TYPED = ('decode', 'encode')
CPUS_WATCHED = (CPU_MEASURED, CPU_SIBLING)

INPUTS_ALL = (
    'canada.json',
    'citm_catalog.json',
    'github_events.json',
    'gsoc-2018.json',
    'marine_ik.json',
    'mesh.json',
    'numbers.json',
    'twitter.json',
    'twitter_varied.json',
    'update-center.json',
)

INPUTS_TYPED = (
    ('canada.json', 'canada'),
    ('twitter.json', 'twitter'),
    ('twitter_varied.json', 'twitter'),
)

TOOL_COMMANDS = (
    ('clang', ('clang++', '--version')),
    ('gcc', ('g++', '--version')),
    ('rustc', ('rustc', '--version')),
    ('zig', ('zig', 'version')),
)

FIELDS = (
    'round',
    'order',
    'workload',
    'input',
    'implementation',
    'variant',
    'language',
    'mode',
    'bytes',
    'runs',
    'best_ns',
    'median_ns',
    'checksum',
    'switches',
    'sibling_busy',
    'background_busy',
    'attempts',
    'gated',
    'started',
)

VALIDATION_FIELDS = (
    'workload',
    'implementation',
    'variant',
    'language',
    'case',
    'outcome',
    'returncode',
)


@dataclasses.dataclass(frozen=True)
class Subject:
    implementation: str
    variant: str
    language: str
    program: tuple[str, ...]
    modes: tuple[tuple[str, str], ...]

    def __post_init__(self) -> None:
        if not self.program:
            message = f'{self.implementation} ({self.variant}) has no program'
            raise ValueError(message)

        if not self.modes:
            message = f'{self.implementation} ({self.variant}) has no modes'
            raise ValueError(message)

        unknown = [workload for workload, _ in self.modes if workload not in WORKLOADS]

        if unknown:
            message = f'{self.implementation} ({self.variant}) has unknown workloads {unknown}'
            raise ValueError(message)


@dataclasses.dataclass(frozen=True)
class Cell:
    subject: Subject
    workload: str
    input: str
    mode: str

    def __post_init__(self) -> None:
        if self.workload not in WORKLOADS:
            message = f'{self.workload} is not a benchmark workload'
            raise ValueError(message)

        if '{' in self.mode:
            message = f'the {self.workload} mode {self.mode} still holds a placeholder'
            raise ValueError(message)

        if not self.input.endswith('.json'):
            message = f'the input {self.input} is not a JSON file'
            raise ValueError(message)


@dataclasses.dataclass(frozen=True)
class Attempt:
    output: dict[str, str]
    switches: int
    sibling_busy: float
    background_busy: int

    def __post_init__(self) -> None:
        missing = [key for key in OUTPUT_KEYS if key not in self.output]

        if missing:
            message = f'the driver output lacks {", ".join(missing)}: {self.output}'
            raise ValueError(message)

        if self.switches < 0:
            message = f'the involuntary switch count went backwards: {self.switches}'
            raise ValueError(message)


def main() -> None:
    cpu_count = os.cpu_count() or 0

    if sys.platform != 'linux':
        message = 'the benchmark harness pins its measurements with taskset and runs only on Linux'
        raise SystemExit(message)

    if cpu_count <= CPU_SIBLING:
        message = f'the harness pins to cpu{CPU_MEASURED} and watches cpu{CPU_SIBLING}'
        raise SystemExit(message)

    subjects = subjects_of()
    programs = {subject.program[0] for subject in subjects}
    missing = [program for program in programs if not pathlib.Path(program).exists()]

    if missing:
        message = f'build the drivers first with build.py, missing: {", ".join(sorted(missing))}'
        raise SystemExit(message)

    RESULTS.mkdir(parents=True, exist_ok=True)

    load_start = os.getloadavg()[0]
    started = now()

    validation_run(subjects)

    measurements = RESULTS / 'measurements.csv'

    with measurements.open('w', encoding='utf-8', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        cells = cells_of(subjects)

        writer.writeheader()

        for round_index in range(ROUND_COUNT):
            order = list(cells)
            generator = random.Random(ROUND_SEED + round_index)

            generator.shuffle(order)

            for order_index, cell in enumerate(order):
                row = row_measure(cell, order_index=order_index, round_index=round_index)

                writer.writerow(row)
                handle.flush()
                progress_write(row, len(order))

    environment = environment_of(load_start=load_start, started=started)
    text = json.dumps(environment, indent=4, sort_keys=True) + '\n'
    path = RESULTS / 'environment.json'

    path.write_text(text, encoding='utf-8')


def attempt_run(cell: Cell) -> Attempt:
    path = CORPUS / cell.input
    command = ['taskset', '-c', str(CPU_MEASURED), *cell.subject.program, cell.mode, str(path)]
    times_before = cpu_times()
    usage_before = resource.getrusage(resource.RUSAGE_CHILDREN)

    completed = subprocess.run(
        command,
        capture_output=True,
        check=False,
        cwd=ROOT,
        errors='replace',
        text=True,
        timeout=CELL_SECONDS_MAX,
    )

    usage_after = resource.getrusage(resource.RUSAGE_CHILDREN)
    times_after = cpu_times()
    lines = completed.stdout.strip().splitlines()

    if completed.returncode != 0:
        message = (
            f'{" ".join(command)} exited with {completed.returncode}: '
            f'{completed.stderr.strip()[-400:]}'
        )

        raise RuntimeError(message)

    if not lines:
        message = f'{" ".join(command)} printed no report'
        raise RuntimeError(message)

    pairs = [field.split('=', 1) for field in lines[-1].split()]
    busy = busy_fractions(times_after=times_after, times_before=times_before)
    others = {cpu: fraction for cpu, fraction in busy.items() if cpu not in CPUS_WATCHED}
    background = [cpu for cpu, fraction in others.items() if fraction >= BACKGROUND_BUSY_MIN]

    return Attempt(
        output=dict(pairs),
        switches=usage_after.ru_nivcsw - usage_before.ru_nivcsw,
        sibling_busy=busy[CPU_SIBLING],
        background_busy=len(background),
    )


def busy_fractions(
    *,
    times_after: dict[int, tuple[int, int]],
    times_before: dict[int, tuple[int, int]],
) -> dict[int, float]:
    if times_after.keys() != times_before.keys():
        message = 'the two CPU samples cover different CPUs'
        raise ValueError(message)

    fractions = {}

    for cpu, (busy_after, ticks_after) in times_after.items():
        busy_before, ticks_before = times_before[cpu]
        ticks = ticks_after - ticks_before

        fractions[cpu] = (busy_after - busy_before) / ticks if ticks > 0 else 0.0

    return fractions


def cell_measure(cell: Cell) -> tuple[Attempt, int, bool]:
    attempts = []

    for _ in range(ATTEMPT_COUNT_MAX):
        sibling_wait()

        attempt = attempt_run(cell)
        attempts.append(attempt)

        if attempt.switches <= SWITCH_COUNT_MAX:
            if attempt.sibling_busy <= SIBLING_BUSY_MAX:
                return attempt, len(attempts), True

        time.sleep(RETRY_PAUSE_SECONDS)

    quietest = min(attempts, key=interference_of)

    return quietest, len(attempts), False


def cells_of(subjects: tuple[Subject, ...]) -> list[Cell]:
    if not subjects:
        message = 'there are no subjects to measure'
        raise ValueError(message)

    cells = []

    for subject in subjects:
        for workload, mode in subject.modes:
            if workload in WORKLOADS_TYPED:
                pairs = [(name, mode.format(schema=schema)) for name, schema in INPUTS_TYPED]
            else:
                pairs = [(name, mode) for name in INPUTS_ALL]

            for name, mode_formatted in pairs:
                cell = Cell(subject=subject, workload=workload, input=name, mode=mode_formatted)
                cells.append(cell)

    return cells


def cpu_times() -> dict[int, tuple[int, int]]:
    times = {}

    for line in pathlib.Path('/proc/stat').read_text(encoding='ascii').splitlines():
        name, *fields = line.split()
        suffix = name.removeprefix('cpu')

        if suffix.isdigit():
            values = [int(field) for field in fields]
            idle = values[3] + values[4]
            ticks = sum(values[:8])

            times[int(suffix)] = (ticks - idle, ticks)

    if CPU_SIBLING not in times:
        message = f'/proc/stat has no cpu{CPU_SIBLING}'
        raise RuntimeError(message)

    return times


def cpuinfo_field(name: str) -> str:
    if not name:
        message = 'a cpuinfo field needs a name'
        raise ValueError(message)

    cpuinfo = pathlib.Path('/proc/cpuinfo').read_text(encoding='utf-8')

    for line in cpuinfo.splitlines():
        key, _, value = line.partition(':')

        if key.strip() == name:
            return value.strip()

    message = f'/proc/cpuinfo has no {name} field'
    raise RuntimeError(message)


def environment_of(*, load_start: float, started: str) -> dict[str, object]:
    if load_start < 0:
        message = f'the load average cannot be negative: {load_start}'
        raise ValueError(message)

    if not started.endswith('Z'):
        message = f'the start time is not in UTC: {started}'
        raise ValueError(message)

    finished = now()
    cpufreq = pathlib.Path(f'/sys/devices/system/cpu/cpu{CPU_MEASURED}/cpufreq')
    digests = json.loads((CORPUS / 'digests.json').read_text(encoding='utf-8'))
    commit_command = ('git', '-C', str(ROOT.parent), 'rev-parse', 'HEAD')
    status_command = ('git', '-C', str(ROOT.parent), 'status', '--porcelain')
    python_command = (str(VENV_PYTHON), '--version')
    tools = {name: version_of(command) for name, command in TOOL_COMMANDS}
    status = subprocess.run(status_command, capture_output=True, check=True, text=True)

    tools['kernel'] = platform.release()
    tools['python'] = version_of(python_command)

    return {
        'attempt_count_max': ATTEMPT_COUNT_MAX,
        'corpus_sha256': digests,
        'cpu': cpuinfo_field('model name'),
        'cpu_measured': CPU_MEASURED,
        'cpu_sibling': CPU_SIBLING,
        'energy_performance_preference': read_text(cpufreq / 'energy_performance_preference'),
        'finished': finished,
        'governor': read_text(cpufreq / 'scaling_governor'),
        'json_zig_commit': version_of(commit_command),
        'json_zig_modified_paths': len(status.stdout.splitlines()),
        'load_average_start': load_start,
        'microcode': cpuinfo_field('microcode'),
        'no_turbo': read_text(pathlib.Path('/sys/devices/system/cpu/intel_pstate/no_turbo')),
        'round_count': ROUND_COUNT,
        'round_seed': ROUND_SEED,
        'sibling_busy_max': SIBLING_BUSY_MAX,
        'started': started,
        'switch_count_max': SWITCH_COUNT_MAX,
        'tools': tools,
    }


def interference_of(attempt: Attempt) -> tuple[bool, int]:
    return attempt.sibling_busy > SIBLING_BUSY_MAX, attempt.switches


def line_write(line: str) -> None:
    if '\n' in line:
        message = f'a progress line cannot span lines: {line!r}'
        raise ValueError(message)

    text = line + '\n'
    count = sys.stdout.write(text)

    if count != len(text):
        message = f'stdout took {count} of {len(text)} characters'
        raise OSError(message)

    sys.stdout.flush()


def now() -> str:
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def progress_write(row: dict[str, object], count: int) -> None:
    if not 0 <= int(row['order']) < count:
        message = f'the order index {row["order"]} is outside the {count} cells of a round'
        raise ValueError(message)

    best_us = int(row['best_ns']) / 1000

    line = (
        f'round {row["round"]} {int(row["order"]) + 1}/{count} {row["workload"]} '
        f'{row["input"]} {row["implementation"]} ({row["variant"]}): {best_us:.1f} us, '
        f'{row["switches"]} switches, sibling {float(row["sibling_busy"]):.1%}, '
        f'attempts {row["attempts"]}'
    )

    line_write(line)


def read_text(path: pathlib.Path) -> str:
    if not path.is_absolute():
        message = f'{path} is not an absolute path'
        raise ValueError(message)

    return path.read_text(encoding='ascii').strip() if path.exists() else 'unavailable'


def row_measure(cell: Cell, *, order_index: int, round_index: int) -> dict[str, object]:
    if order_index < 0:
        message = f'the order index cannot be negative: {order_index}'
        raise ValueError(message)

    if not 0 <= round_index < ROUND_COUNT:
        message = f'the round index {round_index} is outside the {ROUND_COUNT} rounds'
        raise ValueError(message)

    started = now()
    attempt, attempt_count, gated = cell_measure(cell)

    return {
        'round': round_index,
        'order': order_index,
        'workload': cell.workload,
        'input': cell.input,
        'implementation': cell.subject.implementation,
        'variant': cell.subject.variant,
        'language': cell.subject.language,
        'mode': cell.mode,
        'bytes': attempt.output['bytes'],
        'runs': attempt.output['runs'],
        'best_ns': attempt.output['best_ns'],
        'median_ns': attempt.output['median_ns'],
        'checksum': attempt.output['checksum'],
        'switches': attempt.switches,
        'sibling_busy': f'{attempt.sibling_busy:.4f}',
        'background_busy': attempt.background_busy,
        'attempts': attempt_count,
        'gated': gated,
        'started': started,
    }


def sibling_wait() -> None:
    for _ in range(QUIET_POLL_COUNT_MAX):
        times_before = cpu_times()

        time.sleep(QUIET_POLL_SECONDS)

        times_after = cpu_times()
        busy = busy_fractions(times_after=times_after, times_before=times_before)

        if busy[CPU_SIBLING] <= SIBLING_QUIET_MAX:
            return


def subjects_cpp(compiler: str) -> tuple[Subject, ...]:
    if compiler not in dict(COMPILERS):
        message = f'{compiler} is not a benchmark compiler'
        raise ValueError(message)

    variant = dict(COMPILERS)[compiler]
    glaze = ((CPP / f'glaze_bench.{compiler}').as_posix(),)
    rapidjson = ((CPP / f'rapidjson_bench.{compiler}').as_posix(),)
    simdjson = ((CPP / f'simdjson_bench.{compiler}').as_posix(),)
    yyjson = ((CPP / f'yyjson_bench.{compiler}').as_posix(),)
    glaze_modes = (('decode', 'decode-{schema}'), ('encode', 'encode-{schema}'))
    rapidjson_modes = (('document', 'document'), ('write', 'write'))
    simdjson_modes = (('decode', 'decode-{schema}'), ('document', 'document'), ('write', 'write'))
    yyjson_modes = (('document', 'document'), ('write', 'write'))
    yyjson_raw_modes = (('document', 'document-raw'), ('write', 'write-raw'))

    return (
        Subject('Glaze', variant, 'C++', glaze, glaze_modes),
        Subject('RapidJSON', variant, 'C++', rapidjson, rapidjson_modes),
        Subject('simdjson', variant, 'C++', simdjson, simdjson_modes),
        Subject('yyjson', variant, 'C++', yyjson, yyjson_modes),
        Subject('yyjson (raw numbers)', variant, 'C++', yyjson, yyjson_raw_modes),
    )


def subjects_of() -> tuple[Subject, ...]:
    rust = ((CACHE / 'rust' / 'release' / 'json_bench').as_posix(),)
    python = (VENV_PYTHON.as_posix(), '-I', (ROOT / 'drivers' / 'python' / 'bench.py').as_posix())

    serde_modes = (
        ('decode', 'serde-decode-{schema}'),
        ('document', 'serde-document'),
        ('encode', 'serde-encode-{schema}'),
        ('tokenize', 'serde-ignored'),
        ('write', 'serde-write'),
    )

    simd_modes = (
        ('decode', 'simd-decode-{schema}'),
        ('document', 'simd-document'),
        ('encode', 'simd-encode-{schema}'),
        ('write', 'simd-write'),
    )

    sonic_modes = (
        ('decode', 'sonic-decode-{schema}'),
        ('document', 'sonic-document'),
        ('encode', 'sonic-encode-{schema}'),
        ('write', 'sonic-write'),
    )

    python_libraries = (
        ('json (stdlib)', 'json', True),
        ('json-zig', 'json_zig', True),
        ('msgspec', 'msgspec', True),
        ('orjson', 'orjson', True),
        ('pysimdjson', 'simdjson', False),
        ('python-rapidjson', 'rapidjson', True),
        ('ujson', 'ujson', True),
    )

    python_subjects = []

    for implementation, library, dumps in python_libraries:
        loads_mode = ('loads', f'loads-{library}')
        dumps_mode = ('dumps', f'dumps-{library}')
        modes = (loads_mode, dumps_mode) if dumps else (loads_mode,)
        subject = Subject(implementation, 'CPython 3.14', 'Python', python, modes)

        python_subjects.append(subject)

    rust_subjects = (
        Subject('serde_json', 'rustc', 'Rust', rust, serde_modes),
        Subject('simd-json', 'rustc', 'Rust', rust, simd_modes),
        Subject('sonic-rs', 'rustc', 'Rust', rust, sonic_modes),
    )

    return (
        *subjects_zig(),
        *subjects_cpp('gcc'),
        *subjects_cpp('clang'),
        *rust_subjects,
        *python_subjects,
    )


def subjects_zig() -> tuple[Subject, ...]:
    json_zig_modes = (
        ('decode', 'decode_{schema}'),
        ('document', 'document'),
        ('encode', 'encode_{schema}'),
        ('tokenize', 'tokenize'),
        ('write', 'write_document'),
    )

    std_modes = (
        ('decode', 'std_decode_{schema}'),
        ('document', 'std_document'),
        ('encode', 'std_encode_{schema}'),
        ('tokenize', 'std_tokenize'),
        ('write', 'std_write_document'),
    )

    configurations = (
        ('fast-native', 'ReleaseFast'),
        ('safe-native', 'ReleaseSafe'),
        ('safe-baseline', 'ReleaseSafe, x86-64 baseline'),
    )

    subjects = []

    for name, variant in configurations:
        program = ((ZIG / name / 'bin' / 'json_bench').as_posix(),)
        subject = Subject('json-zig', variant, 'Zig', program, json_zig_modes)

        subjects.append(subject)

    fast = ((ZIG / 'fast-native' / 'bin' / 'json_bench').as_posix(),)
    std_subject = Subject('std.json', 'ReleaseFast', 'Zig', fast, std_modes)

    subjects.append(std_subject)

    return tuple(subjects)


def validation_cells(subjects: tuple[Subject, ...]) -> list[Cell]:
    if not subjects:
        message = 'there are no subjects to validate'
        raise ValueError(message)

    paths = sorted(INVALID.glob('*.json'))
    cells = []

    if not paths:
        message = f'no invalid inputs in {INVALID}, run build.py first'
        raise SystemExit(message)

    for subject in subjects:
        for workload, mode in subject.modes:
            if workload not in WORKLOADS_READ:
                continue

            mode_formatted = mode.format(schema='twitter')

            for path in paths:
                name = path.relative_to(CORPUS).as_posix()
                cell = Cell(subject=subject, workload=workload, input=name, mode=mode_formatted)

                cells.append(cell)

    return cells


def validation_outcome(cell: Cell) -> tuple[str, int]:
    command = [*cell.subject.program, cell.mode, str(CORPUS / cell.input)]

    completed = subprocess.run(
        command,
        capture_output=True,
        check=False,
        cwd=ROOT,
        timeout=CELL_SECONDS_MAX,
    )

    if completed.returncode < 0:
        return 'crashed', completed.returncode

    if b'bytes=' in completed.stdout:
        return 'accepted', completed.returncode

    return 'rejected', completed.returncode


def validation_run(subjects: tuple[Subject, ...]) -> None:
    if not subjects:
        message = 'there are no subjects to validate'
        raise ValueError(message)

    cells = validation_cells(subjects)
    failures = []

    line_write(f'validating {len(cells)} invalid-input cells')

    with (RESULTS / 'validation.csv').open('w', encoding='utf-8', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=VALIDATION_FIELDS)

        writer.writeheader()

        for cell in cells:
            outcome, returncode = validation_outcome(cell)
            case = pathlib.PurePosixPath(cell.input).stem

            row = {
                'workload': cell.workload,
                'implementation': cell.subject.implementation,
                'variant': cell.subject.variant,
                'language': cell.subject.language,
                'case': case,
                'outcome': outcome,
                'returncode': returncode,
            }

            writer.writerow(row)

            if outcome == 'rejected':
                continue

            subject = f'{cell.subject.implementation} ({cell.subject.variant})'
            line = f'{subject} {cell.workload} {case}: {outcome}'

            line_write(line)

            if cell.subject.implementation == 'json-zig':
                failures.append(line)

    if failures:
        failure_text = '\n'.join(failures)
        message = f'json-zig accepted or crashed on invalid input:\n{failure_text}'
        raise SystemExit(message)


def version_of(command: tuple[str, ...]) -> str:
    if not command:
        message = 'a version query needs a command'
        raise ValueError(message)

    completed = subprocess.run(command, capture_output=True, check=True, text=True)

    return completed.stdout.strip().splitlines()[0]


if __name__ == '__main__':
    main()
