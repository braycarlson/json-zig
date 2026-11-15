import dataclasses
import hashlib
import json
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parent
CACHE = ROOT / 'cache'
CORPUS = CACHE / 'corpus'
CPP = CACHE / 'cpp'
DRIVERS = ROOT / 'drivers'
PYTHON_BINDING = ROOT.parent / 'bindings' / 'python'
SOURCES = CACHE / 'sources'
VENV = CACHE / 'venv'
BOOLEAN_TRUE_PROBABILITY = 0.5
CHECKOUT_COMMIT_PATTERN = '[0-9a-f]{40}'
CHECKOUT_NAME_PATTERN = '[a-z][a-z-]*'
CPP_COMPILERS = (('clang', 'clang++'), ('gcc', 'g++'))
CPP_FLAGS = ('-O3', '-march=native', '-DNDEBUG', '-falign-functions=64')
INTEGER_SIGNED_MAX = (1 << 63) - 1
INVALID_DIRECTORY = 'invalid'
PYTHON = '/usr/bin/python3'
RUST_FLAGS = '-C target-cpu=native -C llvm-args=-align-all-functions=6'
VARIED_NAME = 'twitter_varied.json'
VARIED_SEED = 20261107
VARIED_STATUS_COUNT = 3000

INVALID_EDITS = (
    ('skipped_bracket', b'"retweeted_status": {', b'"retweeted_status": {"bad": [1}, '),
    ('skipped_control', b'"result_type": "recent"', b'"result_type": "rec\x01ent"'),
    ('skipped_literal', b'"is_translator": false', b'"is_translator": fals'),
    ('skipped_number', b'"retweeted_status": {', b'"retweeted_status": {"bad": 01, '),
    ('skipped_utf8', b'"result_type": "recent"', b'"result_type": "rec\xffent"'),
    ('string_surrogate', b'"text": "@aym0566x', b'"text": "@aym\xed\xa0\x800566x'),
    ('string_utf8', b'"text": "@aym0566x', b'"text": "@aym\xff0566x'),
    ('trailing', b'"since_id_str": "0"\n  }\n}', b'"since_id_str": "0"\n  }\n} x'),
)

PUBLIC_INPUTS = (
    'canada.json',
    'citm_catalog.json',
    'github_events.json',
    'gsoc-2018.json',
    'marine_ik.json',
    'mesh.json',
    'numbers.json',
    'twitter.json',
    'update-center.json',
)

PYTHON_PACKAGES = (
    'msgspec==0.22.0',
    'orjson==3.13.0',
    'pysimdjson==7.0.2',
    'python-rapidjson==1.26',
    'typing-extensions==4.16.0',
    'ujson==6.1.0',
)

VARIED_ALPHABET = (
    ('abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,:;!?#@-_', 70),
    ('áéíñöüçßøå', 10),
    ('あいう日本語中文한국', 10),
    ('\U0001f600\U0001f60a\U0001f44d✨❤', 5),
    ('"\\/\n\t', 5),
)

ZIG_CONFIGURATIONS = (
    ('fast-native', ('-Doptimize=fast', '-Dcpu=native')),
    ('safe-baseline', ('-Doptimize=safe', '-Dcpu=baseline')),
    ('safe-native', ('-Doptimize=safe', '-Dcpu=native')),
)


@dataclasses.dataclass(frozen=True)
class Checkout:
    name: str
    url: str
    commit: str

    def __post_init__(self) -> None:
        if re.fullmatch(CHECKOUT_NAME_PATTERN, self.name) is None:
            message = f'the checkout name {self.name!r} is not a plain directory name'
            raise ValueError(message)

        if re.fullmatch(CHECKOUT_COMMIT_PATTERN, self.commit) is None:
            message = f'{self.name} is pinned to {self.commit!r}, not a full commit hash'
            raise ValueError(message)


CHECKOUTS = (
    Checkout(
        'glaze',
        'https://github.com/stephenberry/glaze.git',
        '43b175e7446862b84ed07b2e5f5138433777680e',
    ),
    Checkout(
        'rapidjson',
        'https://github.com/Tencent/rapidjson.git',
        '297637bc0a0f00dc504dbc1a47ebdaa577f8ae19',
    ),
    Checkout(
        'simdjson',
        'https://github.com/simdjson/simdjson.git',
        '40a686ab89dc5ee58ec10d0514dd5c99abbc472b',
    ),
    Checkout(
        'simdjson-data',
        'https://github.com/simdjson/simdjson-data.git',
        '4197c425e857f0ec38e89822fdd0bd9ea21f4daf',
    ),
    Checkout(
        'yyjson',
        'https://github.com/ibireme/yyjson.git',
        '6447536015f3d600f3d65323b10976103b337ca7',
    ),
)


def main() -> None:
    if sys.platform != 'linux':
        message = 'the benchmark harness pins its measurements with taskset and runs only on Linux'
        raise SystemExit(message)

    for checkout in CHECKOUTS:
        checkout_fetch(checkout)

    corpus_prepare()
    zig_build()
    cpp_build('gcc')
    cpp_build('clang')
    rust_build()
    python_build()


def character_pick(generator: random.Random) -> str:
    if not isinstance(generator, random.Random):
        message = f'a character pick needs a random.Random, not {type(generator).__name__}'
        raise TypeError(message)

    weight_total = sum(weight for _, weight in VARIED_ALPHABET)
    point = generator.random() * weight_total

    for characters, weight in VARIED_ALPHABET:
        if point < weight:
            return characters[int(generator.random() * len(characters))]

        point -= weight

    return VARIED_ALPHABET[0][0][0]


def checked(
    command: list[str],
    directory: pathlib.Path,
    overrides: tuple[tuple[str, str], ...] = (),
) -> None:
    if not command:
        message = 'a build step needs a command'
        raise ValueError(message)

    if not directory.is_dir():
        message = f'the build step {command[0]} runs in {directory}, which is not a directory'
        raise NotADirectoryError(message)

    if not all(name.isupper() for name, _ in overrides):
        message = f'an environment override is not an uppercase variable name: {overrides}'
        raise ValueError(message)

    line = '+ ' + ' '.join(command) + '\n'
    count = sys.stdout.write(line)

    if count != len(line):
        message = f'stdout took {count} of {len(line)} characters'
        raise OSError(message)

    sys.stdout.flush()

    environment = os.environ | dict(overrides)
    completed = subprocess.run(command, cwd=directory, env=environment, check=False)

    if completed.returncode != 0:
        message = f'{command[0]} exited with {completed.returncode} in {directory}'
        raise RuntimeError(message)


def checkout_fetch(checkout: Checkout) -> None:
    directory = SOURCES / checkout.name

    if (directory / '.git').is_dir():
        head_query = ['git', 'rev-parse', 'HEAD']

        completed = subprocess.run(
            head_query,
            capture_output=True,
            check=True,
            cwd=directory,
            text=True,
        )

        if completed.stdout.strip() == checkout.commit:
            return

        shutil.rmtree(directory)

    directory.mkdir(parents=True)

    initialize = ['git', 'init', '--quiet']
    fetch = ['git', 'fetch', '--quiet', '--depth', '1', checkout.url, checkout.commit]
    switch = ['git', 'checkout', '--quiet', 'FETCH_HEAD']

    for command in (initialize, fetch, switch):
        checked(command, directory)


def corpus_prepare() -> None:
    CORPUS.mkdir(parents=True, exist_ok=True)

    examples = SOURCES / 'simdjson-data' / 'jsonexamples'

    for name in PUBLIC_INPUTS:
        shutil.copyfile(examples / name, CORPUS / name)

    varied_write(source=CORPUS / 'twitter.json', target=CORPUS / VARIED_NAME)
    invalid_write(directory=CORPUS / INVALID_DIRECTORY, source=CORPUS / 'twitter.json')

    invalid_names = [f'{INVALID_DIRECTORY}/{name}.json' for name, _, _ in INVALID_EDITS]
    names = (*PUBLIC_INPUTS, VARIED_NAME, *invalid_names)
    digests = {name: digest_of(CORPUS / name) for name in names}
    text = json.dumps(digests, indent=4, sort_keys=True) + '\n'

    (CORPUS / 'digests.json').write_text(text, encoding='utf-8')


def cpp_build(tag: str) -> None:
    if tag not in dict(CPP_COMPILERS):
        message = f'{tag} is not a benchmark compiler'
        raise ValueError(message)

    CPP.mkdir(parents=True, exist_ok=True)

    compiler = dict(CPP_COMPILERS)[tag]
    cpp = DRIVERS / 'cpp'
    simdjson = SOURCES / 'simdjson' / 'singleheader'
    yyjson = SOURCES / 'yyjson' / 'src'
    yyjson_object = CPP / f'yyjson.{tag}.o'
    cxx = [compiler, *CPP_FLAGS, '-std=c++20', f'-I{cpp}']

    yyjson_compile = [
        compiler,
        '-x',
        'c',
        *CPP_FLAGS,
        '-c',
        str(yyjson / 'yyjson.c'),
        '-o',
        str(yyjson_object),
    ]

    simdjson_compile = [
        *cxx,
        f'-I{simdjson}',
        str(cpp / 'simdjson_bench.cpp'),
        str(simdjson / 'simdjson.cpp'),
        '-o',
        str(CPP / f'simdjson_bench.{tag}'),
    ]

    yyjson_link = [
        *cxx,
        f'-I{yyjson}',
        str(cpp / 'yyjson_bench.cpp'),
        str(yyjson_object),
        '-o',
        str(CPP / f'yyjson_bench.{tag}'),
    ]

    rapidjson_compile = [
        *cxx,
        '-DRAPIDJSON_SSE42',
        f'-I{SOURCES / "rapidjson" / "include"}',
        str(cpp / 'rapidjson_bench.cpp'),
        '-o',
        str(CPP / f'rapidjson_bench.{tag}'),
    ]

    glaze_compile = [
        compiler,
        *CPP_FLAGS,
        '-std=c++23',
        f'-I{cpp}',
        f'-I{SOURCES / "glaze" / "include"}',
        str(cpp / 'glaze_bench.cpp'),
        '-o',
        str(CPP / f'glaze_bench.{tag}'),
    ]

    commands = (yyjson_compile, simdjson_compile, yyjson_link, rapidjson_compile, glaze_compile)

    for command in commands:
        checked(command, ROOT)


def digest_of(path: pathlib.Path) -> str:
    if not path.is_file():
        message = f'{path} does not exist, so it has no digest'
        raise FileNotFoundError(message)

    return hashlib.sha256(path.read_bytes()).hexdigest()


def invalid_write(*, directory: pathlib.Path, source: pathlib.Path) -> None:
    if directory.name != INVALID_DIRECTORY:
        message = f'the invalid inputs go in a directory named {INVALID_DIRECTORY}, not {directory}'
        raise ValueError(message)

    if not source.is_file():
        message = f'the invalid inputs are edits of {source}, which does not exist'
        raise FileNotFoundError(message)

    data = source.read_bytes()

    directory.mkdir(parents=True, exist_ok=True)

    for name, pattern, replacement in INVALID_EDITS:
        index = data.index(pattern)
        edited = data[:index] + replacement + data[index + len(pattern) :]

        (directory / f'{name}.json').write_bytes(edited)


def mutated(template: object, generator: random.Random) -> object:
    if not isinstance(template, dict):
        message = f'a mutation template is an object, not {type(template).__name__}'
        raise TypeError(message)

    if not isinstance(generator, random.Random):
        message = f'a mutation needs a random.Random, not {type(generator).__name__}'
        raise TypeError(message)

    result = [None]
    root = (template, result, 0)
    pending = [root]

    while pending:
        value, parent, slot = pending.pop()

        if isinstance(value, dict):
            copy = dict.fromkeys(value)
            children = [(child, copy, key) for key, child in value.items()]

            parent[slot] = copy
            pending.extend(children)
        elif isinstance(value, list):
            copy_list = [None] * len(value)
            children = [(child, copy_list, index) for index, child in enumerate(value)]

            parent[slot] = copy_list
            pending.extend(children)
        else:
            parent[slot] = scalar_mutated(value, generator)

    return result[0]


def python_build() -> None:
    venv_create = ['uv', 'venv', '--clear', '--python', PYTHON, str(VENV)]

    checked(venv_create, ROOT)

    venv_python = str(VENV / 'bin' / 'python')
    version_query = [venv_python, '-c', 'import sys; print(*sys.version_info[:2], sep=".")']
    completed = subprocess.run(version_query, capture_output=True, check=True, text=True)
    version = completed.stdout.strip()
    wheel_build = ['zig', 'build', f'wheel-host-{version}:json_zig']

    checked(wheel_build, PYTHON_BINDING)

    tag = 'cp' + version.replace('.', '')
    dist = PYTHON_BINDING / 'zig-out' / 'dist'
    wheels = sorted(dist.glob(f'json_zig-*-{tag}-{tag}-manylinux*_x86_64.whl'))

    if len(wheels) != 1:
        message = f'expected one {tag} manylinux x86_64 wheel in {dist}, found {len(wheels)}'
        raise RuntimeError(message)

    packages_install = ['uv', 'pip', 'install', '--python', venv_python, *PYTHON_PACKAGES]
    wheel_install = ['uv', 'pip', 'install', '--python', venv_python, '--reinstall', str(wheels[0])]

    checked(packages_install, ROOT)
    checked(wheel_install, ROOT)


def rust_build() -> None:
    command = ['cargo', 'build', '--release', '--locked']
    overrides = (('CARGO_TARGET_DIR', str(CACHE / 'rust')), ('RUSTFLAGS', RUST_FLAGS))

    checked(command, DRIVERS / 'rust', overrides)


def scalar_mutated(value: object, generator: random.Random) -> object:
    if not isinstance(generator, random.Random):
        message = f'a scalar mutation needs a random.Random, not {type(generator).__name__}'
        raise TypeError(message)

    if isinstance(value, dict | list):
        message = f'a scalar mutation got a {type(value).__name__}'
        raise TypeError(message)

    if isinstance(value, bool):
        return generator.random() < BOOLEAN_TRUE_PROBABILITY

    if isinstance(value, int):
        span = 2 * abs(value) + 10
        magnitude = min(int(generator.random() * span), INTEGER_SIGNED_MAX)

        return -magnitude if value < 0 else magnitude

    if isinstance(value, float):
        return round(generator.random() * (2 * abs(value) + 1), 6)

    if isinstance(value, str):
        length = int(len(value) * (0.5 + generator.random()))
        characters = [character_pick(generator) for _ in range(length)]

        return ''.join(characters)

    return value


def varied_write(*, source: pathlib.Path, target: pathlib.Path) -> None:
    if not source.is_file():
        message = f'the varied input is built from {source}, which does not exist'
        raise FileNotFoundError(message)

    if target == source:
        message = f'the varied input would overwrite its source {source}'
        raise ValueError(message)

    document = json.loads(source.read_bytes())
    templates = document['statuses']
    generator = random.Random(VARIED_SEED)
    statuses = []

    for _ in range(VARIED_STATUS_COUNT):
        template = templates[int(generator.random() * len(templates))]
        status = mutated(template, generator)

        statuses.append(status)

    document['statuses'] = statuses
    document['search_metadata'] = mutated(document['search_metadata'], generator)

    text = json.dumps(document, ensure_ascii=False, indent=2) + '\n'

    target.write_text(text, encoding='utf-8')


def zig_build() -> None:
    for name, options in ZIG_CONFIGURATIONS:
        prefix = CACHE / 'zig' / name
        command = ['zig', 'build', *options, '--prefix', str(prefix)]

        checked(command, ROOT)


if __name__ == '__main__':
    main()
