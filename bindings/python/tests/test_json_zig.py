import array
import contextlib
import enum
import fractions
import functools
import gc
import itertools
import json
import math
import random
import re
import struct
import sys
import tracemalloc
import weakref

import pytest

import json_zig


DEPTH_MAX = 6
JSON_ZIG_DEPTH_MAX = 128
MUTATION_ALPHABET = b'{}[]",:0123456789.eE+-\\/tnrfaulsbu \t\n\r'
MUTATION_COUNT = 500
SEEDS = range(40)
SURROGATE = re.compile('[\ud800-\udfff]')

MUTATION_FRAGMENTS = (
    b'\x00',
    b'\x1f',
    b'\xc0',
    b'\xc3\xa9',
    b'\xe2\x82',
    b'\xed\xa0\x80',
    b'\xef\xbb\xbf',
    b'\xf0\x9f\x98\x80',
    b'\xff',
    b'-0.0e-0',
    b'1e400',
    b'123456789012345678901234567890',
    b'Infinity',
    b'NaN',
    b'\\u',
    b'\\ud83d',
    b'\\ude00',
    b'[' * (JSON_ZIG_DEPTH_MAX + 1),
)

WORDS = (
    '',
    'a',
    'key',
    'café',
    '日本語',
    'tab\there',
    'quote"inside',
    'back\\slash',
    '\U0001f600',
    'x' * 90,
)

NAMES = (
    '',
    '_',
    '__',
    '_private',
    '__dunder__',
    'trailing_',
    'a__b',
    'user_id',
    'userId',
    'UserID',
    'HTTPServer',
    'XMLHttpRequest',
    'v2_field',
    'field_2nd',
    'already-kebab',
    'Content-Type',
    'straße_name',
    'éclairType',
    'ÜberName',
    '\u03c3_word',
    'İstanbul_x',
    'x٣Abc',
    '日本_語',
    'tab\tname_x',
    'quote"inside_x',
    'long_' + 'segment_' * 12 + 'End',
    'Long' + 'Segment' * 12 + 'end',
)

STYLES = ('camel', 'kebab', 'lower', 'pascal', 'snake', 'upper')


def integer_random(prng: random.Random) -> int:
    assert isinstance(prng, random.Random)

    wide = prng.random() < 0.1
    result = prng.randrange(-(10**30), 10**30) if wide else prng.randrange(-(2**63), 2**64)

    assert -(10**30) <= result < 10**30

    return result


def float_random(prng: random.Random) -> float:
    assert isinstance(prng, random.Random)

    wide = prng.random() < 0.5
    result = prng.uniform(-1e300, 1e300) if wide else prng.random() * 10 ** prng.randrange(-30, 30)

    assert math.isfinite(result)

    return result


def scalar_random(prng: random.Random) -> object:
    assert isinstance(prng, random.Random)

    choices = (
        None,
        prng.random() < 0.5,
        integer_random(prng),
        float_random(prng),
        prng.choice(WORDS) + prng.choice(('', str(prng.randrange(100)))),
    )

    result = prng.choice(choices)

    assert result is None or isinstance(result, bool | int | float | str)

    return result


def value_random(prng: random.Random) -> object:
    assert isinstance(prng, random.Random)

    root: list[object] = []
    pending = [(root, 0)]

    for _ in range(10_000):
        if not pending:
            break

        container, depth = pending.pop()

        for _ in range(prng.randrange(6)):
            shape = prng.randrange(4) if depth < DEPTH_MAX else 3
            child: object = [] if shape == 0 else {} if shape == 1 else scalar_random(prng)

            if isinstance(container, list):
                container.append(child)
            else:
                container[prng.choice(WORDS)] = child

            if shape < 2:
                pending.append((child, depth + 1))

    assert not pending

    return root


def children_of(item: object) -> list[object]:
    assert item is None or isinstance(item, bool | int | float | str | list | dict)

    result = (
        list(item.values()) if isinstance(item, dict) else item if isinstance(item, list) else []
    )

    assert len(result) == (len(item) if isinstance(item, dict | list) else 0)

    return result


def node_count(value: object) -> int:
    assert value is None or isinstance(value, bool | int | float | str | list | dict)

    count = 0
    pending = [value]

    for _ in range(1_000_000):
        if not pending:
            break

        item = pending.pop()
        count += 1 + (len(item) if isinstance(item, dict) else 0)
        pending.extend(children_of(item))

    assert not pending

    return count


@pytest.mark.parametrize('seed', SEEDS)
def test_loads_matches_the_standard_library_on_random_documents(seed: int) -> None:
    assert seed in SEEDS

    prng = random.Random(seed)
    value = value_random(prng)

    for text in (
        json.dumps(value),
        json.dumps(value, indent=2),
        json.dumps(value, indent='\t', ensure_ascii=False),
        json.dumps(value, separators=(',', ':')),
    ):
        expected = json.loads(text)

        assert json_zig.loads(text) == expected
        assert json_zig.loads(text.encode()) == expected
        assert json_zig.Document(text.encode()).as_objects() == expected


def test_loads_matches_the_standard_library_on_a_document_longer_than_the_margin() -> None:
    prng = random.Random(7)
    text = json.dumps([value_random(prng) for _ in range(400)], indent=4).encode()

    assert len(text) > 64 * 1024
    assert json_zig.loads(text) == json.loads(text)


@pytest.mark.parametrize(
    'text',
    [
        '0',
        '-0',
        '1',
        '-1',
        '9223372036854775807',
        '9223372036854775808',
        '18446744073709551615',
        '18446744073709551616',
        '-9223372036854775808',
        '-9223372036854775809',
        '1.5',
        '-0.0',
        '1e5',
        '1E-5',
        '2.5e+3',
        '1e400',
        '-1e400',
        '1e-400',
        '0.1',
        '123456789012345678901234567890.5',
    ],
)
def test_numbers_keep_their_python_type_and_value(text: str) -> None:
    assert text.lstrip('-')[0].isdigit()

    expected = json.loads(text)
    actual = json_zig.loads(text)

    assert type(actual) is type(expected)
    assert repr(actual) == repr(expected)


@pytest.mark.parametrize(
    'text',
    [
        '',
        ' ',
        '[',
        '[1,]',
        '{"a" 1}',
        '{"a":1,}',
        '01',
        '1.',
        '"abc',
        '"\\x"',
        'tru',
        '[1] 2',
        '\xff',
        '"\\ud800"',
    ],
)
def test_invalid_documents_raise_value_error(text: str) -> None:
    assert isinstance(text, str)

    data = text.encode('utf-8', 'surrogatepass')

    assert isinstance(data, bytes)

    with pytest.raises(ValueError, match='line'):
        json_zig.loads(data)


def document_objects(data: bytes) -> object:
    assert isinstance(data, bytes)

    return json_zig.Document(data).as_objects()


def verdict(data: bytes, function: object) -> tuple[str, str]:
    assert isinstance(data, bytes)
    assert callable(function)

    try:
        value = function(data)
        result = (type(value).__name__, repr(value))
    except ValueError as error:
        result = ('error', str(error))

    return result


@pytest.mark.parametrize(
    'data',
    [
        b'1',
        b' 1',
        b'1 ',
        b'\t\n\r 1 \r\n\t',
        b'-0',
        b'01',
        b'1.',
        b'-',
        b'1 2',
        b'1e',
        b'1x',
        b'-123456789',
        b'3.141592653589793',
        b'123456789012345678901234567890',
        b'123456789012345678901234567890.5',
        b'"abc"',
        b' "abc" ',
        b'""',
        b'"',
        b'"abc',
        b'abc"',
        b'"a" "b"',
        b'"a"b',
        b'"a\\nb"',
        b'"a\\u00e9b"',
        b'"\\ud83d\\ude00"',
        b'"\\udfaa"',
        '"héllo wörld"'.encode(),
        '"€"'.encode(),
        '"\U0001f600"'.encode(),
        b'"\xed\xa0\x80"',
        b'"\xc3"',
        b'"\xc0\x80"',
        b'"\xff"',
        b'"a\x1fb"',
        b'"a\x7fb"',
        b'"' + b'x' * 100 + b'"',
        b'"' + b'x' * 99 + b'\\""',
        b'"' + b'x' * 99 + b'\x01"',
        b'"' + 'é'.encode() * 40 + b'"',
        b'true',
        b'false',
        b'null',
        b' true ',
        b'tru',
        b'truex',
        b'nul',
        b'nulll',
        b'True',
        b'NaN',
        b' ',
        b'',
    ],
)
def test_a_root_scalar_matches_the_document_path(data: bytes) -> None:
    assert isinstance(data, bytes)

    assert verdict(data, json_zig.loads) == verdict(data, document_objects)


@pytest.mark.parametrize('seed', SEEDS)
def test_mutated_root_scalars_match_the_document_path(seed: int) -> None:
    assert seed in SEEDS

    prng = random.Random(seed)
    padding = prng.choice((b'', b' ', b'\n\t'))
    document = padding + json.dumps(scalar_random(prng), ensure_ascii=prng.random() < 0.5).encode()

    for _ in range(MUTATION_COUNT):
        data = mutated(prng, document)

        assert verdict(data, json_zig.loads) == verdict(data, document_objects), data


@pytest.mark.parametrize('seed', SEEDS)
def test_mutated_indented_documents_match_the_document_path(seed: int) -> None:
    assert seed in SEEDS

    prng = random.Random(seed)
    indent = prng.choice((2, 4, 8, 33, '\t'))
    text = json.dumps(value_random(prng), indent=indent, ensure_ascii=prng.random() < 0.5)
    document = text.replace('\n', '\r\n').encode() if prng.random() < 0.3 else text.encode()

    assert verdict(document, json_zig.loads) == verdict(document, document_objects)

    for _ in range(MUTATION_COUNT):
        data = mutated(prng, document)

        assert verdict(data, json_zig.loads) == verdict(data, document_objects), data


def mutated(prng: random.Random, data: bytes) -> bytes:
    assert isinstance(prng, random.Random)
    assert isinstance(data, bytes)

    result = bytearray(data)

    for _ in range(prng.randrange(1, 4)):
        position = prng.randrange(len(result) + 1)
        choice = prng.randrange(4)

        if choice == 0:
            if result:
                result[min(position, len(result) - 1)] = prng.choice(MUTATION_ALPHABET)
        elif choice == 1:
            result[position:position] = prng.choice(MUTATION_FRAGMENTS)
        elif choice == 2:
            del result[position : position + prng.randrange(1, 8)]
        else:
            del result[position:]

    assert len(result) <= len(data) + 3 * max(len(fragment) for fragment in MUTATION_FRAGMENTS)

    return bytes(result)


def outcome(data: bytes, loads: object) -> tuple[bool, object]:
    assert isinstance(data, bytes)
    assert callable(loads)

    try:
        result = (True, loads(data))
    except (RecursionError, ValueError):
        result = (False, None)

    return result


def strictness_of(data: bytes) -> str | None:
    assert isinstance(data, bytes)

    encoding = encoding_strictness_of(data)

    if encoding is not None:
        return encoding

    members = json.loads(data, object_pairs_hook=list)
    result = value_strictness_of(members)

    assert result in (None, 'depth', 'non_finite', 'surrogate')

    return result


def encoding_strictness_of(data: bytes) -> str | None:
    assert isinstance(data, bytes)

    encoding = json.detect_encoding(data)

    if encoding == 'utf-8-sig':
        return 'bom'

    if encoding != 'utf-8':
        return 'encoding'

    try:
        _ = data.decode('utf-8')
    except UnicodeDecodeError:
        return 'encoding'

    return None


def value_strictness_of(value: object) -> str | None:
    assert value is None or isinstance(value, bool | int | float | str | list)

    pending = [(value, 1)]

    for _ in range(1_000_000):
        if not pending:
            break

        item, depth = pending.pop()

        if isinstance(item, tuple):
            pending.extend((child, depth) for child in item)

            continue

        if isinstance(item, list):
            if depth > JSON_ZIG_DEPTH_MAX:
                return 'depth'

            pending.extend((child, depth + 1) for child in item)

        if isinstance(item, float):
            if not math.isfinite(item):
                return 'non_finite'

        if isinstance(item, str):
            if SURROGATE.search(item):
                return 'surrogate'

    assert not pending

    return None


@pytest.mark.parametrize('seed', SEEDS)
def test_loads_rejects_only_what_the_standard_library_rejects_or_json_zig_refuses(
    seed: int,
) -> None:
    assert seed in SEEDS

    prng = random.Random(seed)
    document = json.dumps(value_random(prng), ensure_ascii=prng.random() < 0.5).encode()

    for _ in range(MUTATION_COUNT):
        data = mutated(prng, document)
        expected_accepted, expected = outcome(data, json.loads)
        accepted, actual = outcome(data, json_zig.loads)

        if accepted:
            assert expected_accepted, data
            assert repr(actual) == repr(expected), data
        elif expected_accepted:
            assert strictness_of(data) is not None, data
        else:
            assert expected is None


@pytest.mark.parametrize(
    ('data', 'strictness'),
    [
        (b'{"a":"\\ude00","a":""}', 'surrogate'),
        (b'[NaN]', 'non_finite'),
        (b'[Infinity]', 'non_finite'),
        (b'{"a":-Infinity}', 'non_finite'),
        (b'["\\ud800"]', 'surrogate'),
        (b'["\\uDd1e\\uD834"]', 'surrogate'),
        (b'{"\\udfaa":0}', 'surrogate'),
        (b'["\xed\xa0\x80"]', 'encoding'),
        ('["\u00e9"]'.encode('utf-16-le'), 'encoding'),
        ('["\u00e9"]'.encode('utf-32'), 'encoding'),
        (b'\xef\xbb\xbf{}', 'bom'),
        (b'[' * (JSON_ZIG_DEPTH_MAX + 1) + b']' * (JSON_ZIG_DEPTH_MAX + 1), 'depth'),
        (b'{"a":' * (JSON_ZIG_DEPTH_MAX + 1) + b'1' + b'}' * (JSON_ZIG_DEPTH_MAX + 1), 'depth'),
    ],
)
def test_loads_refuses_what_rfc_8259_leaves_open_where_the_standard_library_accepts(
    data: bytes,
    strictness: str,
) -> None:
    assert isinstance(data, bytes)

    accepted = json.loads(data)

    assert isinstance(accepted, list | dict)
    assert strictness_of(data) == strictness

    with pytest.raises(ValueError, match='line'):
        json_zig.loads(data)


@pytest.mark.parametrize(
    'text',
    [
        '[[1]]',
        '[[[1]]]',
        '[[[[]]]]',
        '[[[1],[2]]]',
        '{"a":[[[1]]]}',
        '[{"a":[[{}]]}]',
    ],
)
def test_document_converts_containers_that_outnumber_their_leaves(text: str) -> None:
    assert text.count('[') + text.count('{') >= text.count(',') + 1

    expected = json.loads(text)

    assert json_zig.Document(text.encode()).as_objects() == expected
    assert json_zig.loads(text) == expected


@pytest.mark.parametrize(
    'text',
    [
        '{"":""}',
        '{"":"","":""}',
        '[{"":""},{"":""}]',
        '{"a":{"":""},"":"a"}',
        '{"e":"e","":""}',
    ],
)
def test_a_key_and_its_value_may_be_the_same_string_object(text: str) -> None:
    assert '"":""' in text

    expected = json.loads(text)

    for source in (text, text.encode()):
        assert json_zig.loads(source) == expected

    assert json_zig.Document(text.encode()).as_objects() == expected
    assert json_zig.dumps(expected) == json.dumps(expected, separators=(',', ':')).encode()


def test_loads_accepts_nesting_at_the_depth_limit_like_the_standard_library() -> None:
    arrays = b'[' * JSON_ZIG_DEPTH_MAX + b'1' + b']' * JSON_ZIG_DEPTH_MAX
    objects = b'{"a":' * JSON_ZIG_DEPTH_MAX + b'1' + b'}' * JSON_ZIG_DEPTH_MAX

    for data in (arrays, objects):
        expected = json.loads(data)

        assert strictness_of(data) is None
        assert json_zig.loads(data) == expected
        assert json_zig.Document(data).as_objects() == expected


@pytest.mark.parametrize('text', ['{\n  "a": 1,\n  "b" 2\n}', '[\n\n   tru\n]', '[1,\n 2 3]'])
def test_errors_name_the_line_and_column_the_standard_library_names(text: str) -> None:
    assert '\n' in text

    with pytest.raises(json.JSONDecodeError) as expected:
        json.loads(text)

    position = f'line {expected.value.lineno} column {expected.value.colno}'

    assert expected.value.lineno > 1

    with pytest.raises(ValueError, match=position):
        json_zig.loads(text)


def test_a_trailing_comma_is_reported_at_the_closing_bracket() -> None:
    with pytest.raises(ValueError, match='line 2 column 4') as array:
        json_zig.loads(b'[1,\n 2,]')

    assert array.value.doc[array.value.pos] == ']'

    with pytest.raises(ValueError, match='line 1 column 9') as dictionary:
        json_zig.loads(b'{"a": 1,}')

    assert dictionary.value.doc[dictionary.value.pos] == '}'


def test_non_text_input_raises_type_error() -> None:
    with pytest.raises(TypeError, match='bytes or str') as raised:
        json_zig.loads(3)

    assert not isinstance(raised.value, json.JSONDecodeError)

    with pytest.raises(TypeError, match='bytes'):
        json_zig.Document('text')


def test_document_counts_every_value_and_key() -> None:
    value = {'a': [1, 2, {'b': None}], 'c': 'd', 'e': {}}
    document = json_zig.Document(json.dumps(value).encode())

    assert document.node_count == node_count(value)
    assert document.as_objects() == value


def test_duplicate_keys_keep_the_last_value_like_the_standard_library() -> None:
    text = b'{"a": 1, "a": 2, "b": {"c": 3, "c": 4}}'

    assert json_zig.loads(text) == json.loads(text)
    assert json_zig.loads(text) == {'a': 2, 'b': {'c': 4}}


def test_repeated_loads_do_not_leak() -> None:
    text = json.dumps([value_random(random.Random(seed)) for seed in range(50)]).encode()

    for _ in range(20):
        json_zig.loads(text)

    tracemalloc.start()
    before = tracemalloc.get_traced_memory()[0]

    for _ in range(200):
        json_zig.loads(text)
        json_zig.Document(text).as_objects()

    after = tracemalloc.get_traced_memory()[0]
    tracemalloc.stop()

    assert before >= 0
    assert after - before < 64 * 1024


def number_random(prng: random.Random) -> str:
    assert isinstance(prng, random.Random)

    digits = ''.join(prng.choice('0123456789') for _ in range(prng.randrange(1, 26)))
    digits = digits.lstrip('0') or '0'
    sign = '-' if prng.random() < 0.5 else ''
    shape = prng.randrange(4)

    if shape == 0:
        return sign + digits

    point = prng.randrange(1, len(digits) + 1)
    text = sign + digits[:point] + '.' + (digits[point:] or '0')

    if shape == 1:
        return text

    exponent = prng.randrange(-330, 330) if shape == 2 else prng.randrange(-25, 25)
    signs = ['', '+'] if exponent >= 0 else ['']
    result = text + prng.choice('eE') + prng.choice(signs) + str(exponent)

    assert result.lstrip('-')[0].isdigit()

    return result


@pytest.mark.parametrize('seed', range(20))
def test_numbers_match_the_standard_library_bit_for_bit(seed: int) -> None:
    assert 0 <= seed < 20

    prng = random.Random(1000 + seed)
    texts = [number_random(prng) for _ in range(1000)]
    texts += ['9007199254740993', '9007199254740993.0', '-65.613616999999977', '0.1e-310']

    expected = json.loads('[' + ','.join(texts) + ']')
    actual = json_zig.loads('[' + ','.join(texts) + ']')

    for text, left, right in zip(texts, expected, actual, strict=True):
        assert type(left) is type(right), text
        assert repr(left) == repr(right), text


def halfway_texts(prng: random.Random) -> list[str]:
    assert isinstance(prng, random.Random)

    low = 10 ** prng.uniform(-1, 3)
    high = math.nextafter(low, math.inf)
    middle = (fractions.Fraction(low) + fractions.Fraction(high)) / 2
    texts = []

    for places in range(1, 20):
        scaled = middle * 10**places

        for mantissa in (math.floor(scaled), math.ceil(scaled)):
            if len(str(mantissa)) <= 19:
                text = str(mantissa).rjust(places + 1, '0')
                texts.append(text[:-places] + '.' + text[-places:])

    assert texts

    return texts


@pytest.mark.parametrize('seed', range(20))
def test_decimals_beside_a_halfway_point_round_like_the_standard_library(seed: int) -> None:
    assert 0 <= seed < 20

    prng = random.Random(5000 + seed)
    texts = [text for _ in range(200) for text in halfway_texts(prng)]

    expected = json.loads('[' + ','.join(texts) + ']')
    actual = json_zig.loads('[' + ','.join(texts) + ']')

    for text, left, right in zip(texts, expected, actual, strict=True):
        assert left.hex() == right.hex(), text


@pytest.mark.parametrize('seed', range(10))
def test_numbers_split_by_any_blank_run_load_like_the_standard_library(seed: int) -> None:
    assert 0 <= seed < 10

    prng = random.Random(9000 + seed)
    separators = (',', ', ', ',\n\t\t', ',\n    ', ',\r\n  ', ' ,', '\n,\n', ',' + ' ' * 40, ',\t')
    numbers = ('0', '-7', '12', '3.25', '-0.5', '1e5', '2.5E-3', '123456789012', '-98765.4321')

    for _ in range(50):
        count = prng.randint(1, 40)
        items = [prng.choice(numbers) for _ in range(count)]
        text = items[0]

        for item in items[1:]:
            text += prng.choice(separators) + item

        document = f'[{text}]'
        nested = f'{{"values": [{text}], "tail": [{text}, "end"]}}'

        for candidate in (document, nested, '  ' + document + '\n'):
            assert json_zig.loads(candidate) == json.loads(candidate), candidate


@pytest.mark.parametrize('seed', range(10))
def test_integers_of_sixteen_to_twenty_digits_load_like_the_standard_library(seed: int) -> None:
    assert 0 <= seed < 10

    prng = random.Random(9500 + seed)
    edges = [2**63 - 1, 2**63, 2**63 + 1, 2**64 - 1, 2**64, 10**15, 10**16 - 1, 10**19 - 1, 10**19]
    values = edges + [-value for value in edges]

    for _ in range(200):
        digits = prng.randint(16, 20)
        value = prng.randrange(10 ** (digits - 1), 10**digits)
        values.append(-value if prng.random() < 0.4 else value)

    prng.shuffle(values)

    texts = [str(value) for value in values]
    documents = (
        '[' + ','.join(texts) + ']',
        '[' + ', '.join(texts) + ']',
        '{' + ','.join(f'"k{index}":{text}' for index, text in enumerate(texts)) + '}',
        '[' + ','.join(texts[:3]) + ']',
        '[1,' + texts[0] + ']',
    )

    for document in documents:
        assert json_zig.loads(document) == json.loads(document), document[:80]


def wide_texts(prng: random.Random) -> list[str]:
    assert isinstance(prng, random.Random)

    low = 10 ** prng.uniform(-300, 300)
    high = math.nextafter(low, math.inf)
    middle = (fractions.Fraction(low) + fractions.Fraction(high)) / 2
    exponent = math.floor(math.log10(low))
    texts = []

    for digits in range(14, 20):
        scaled = middle * fractions.Fraction(10) ** (digits - 1 - exponent)
        candidates = (math.floor(scaled), math.ceil(scaled))

        texts.extend(
            f'{mantissa}e{exponent - digits + 1}'
            for mantissa in candidates
            if len(str(mantissa)) <= 19
        )

    sign = '-' if prng.random() < 0.5 else ''
    whole = prng.randrange(1, 10 ** prng.randint(1, 10))
    fraction = prng.randrange(0, 10 ** prng.randint(1, 9))
    power = prng.randint(-360, 330)
    texts.append(f'{sign}{whole}.{fraction}e{power}')
    texts.append(repr(prng.uniform(1, 10) * 10.0 ** prng.randint(-320, 300)))

    assert texts

    return texts


@pytest.mark.parametrize('seed', range(20))
def test_wide_exponents_load_like_the_standard_library(seed: int) -> None:
    assert 0 <= seed < 20

    prng = random.Random(7000 + seed)
    edges = ['1e400', '-1e400', '9999999999999999999e290', '0e-400', '-0.0e-50', '0.000e300']
    texts = [text for _ in range(200) for text in wide_texts(prng)] + edges

    for separator in (',', ', '):
        document = '[' + separator.join(texts) + ']'
        expected = json.loads(document)
        actual = json_zig.loads(document)

        for text, left, right in zip(texts, expected, actual, strict=True):
            assert left.hex() == right.hex(), text


@pytest.mark.parametrize('seed', range(10))
def test_repeated_integers_load_like_the_standard_library(seed: int) -> None:
    assert 0 <= seed < 10

    prng = random.Random(7000 + seed)
    pool = [prng.randrange(-(10**15) + 1, 10**15) for _ in range(3000)]
    pool += [offset * 1024 for offset in range(-64, 64)]
    pool += list(range(-5, 257))
    texts = [str(prng.choice(pool)) for _ in range(20000)]
    text = '[' + ', '.join(texts) + ']'

    expected = json.loads(text)
    actual = json_zig.loads(text)

    assert actual == expected
    assert all(type(value) is int for value in actual)


@pytest.mark.parametrize('seed', range(10))
def test_unique_and_repeated_integer_runs_load_like_the_standard_library(seed: int) -> None:
    assert 0 <= seed < 10

    prng = random.Random(7100 + seed)
    unique = [prng.randrange(10**6, 10**12) for _ in range(prng.randrange(1, 400))]
    repeated = [prng.choice(unique) for _ in range(prng.randrange(1, 400))]
    orders = (unique + repeated, repeated + unique, repeated + unique + repeated)

    for values in orders:
        text = '[' + ','.join(str(value) for value in values) + ']'
        actual = json_zig.loads(text)

        assert actual == json.loads(text)
        assert all(type(value) is int for value in actual)


@pytest.mark.parametrize('seed', range(10))
def test_keys_reused_across_calls_load_like_the_standard_library(seed: int) -> None:
    assert 0 <= seed < 10

    prng = random.Random(7300 + seed)
    alphabet = 'abcxyz_\u00e9\u4e2d\U0001f600'
    lengths = (0, 1, 2, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 80)
    pool = []

    for _ in range(3000):
        length = prng.choice(lengths)
        pool.append(''.join(prng.choice(alphabet) for _ in range(length)))

    for _ in range(300):
        count = prng.randrange(1, 40)
        members = {prng.choice(pool): prng.randrange(-5, 300) for _ in range(count)}
        text = json.dumps(members, ensure_ascii=prng.random() < 0.3)
        expected = json.loads(text)
        actual = json_zig.loads(text)

        assert actual == expected
        assert list(actual) == list(expected)


@pytest.mark.parametrize('seed', range(5))
def test_keys_sharing_a_cache_set_load_like_the_standard_library(seed: int) -> None:
    assert 0 <= seed < 5

    prng = random.Random(7400 + seed)
    keys = []

    for length in (1, 8, 20, 40):
        for _ in range(6):
            middle = ''.join(prng.choice('0123456789') for _ in range(length))
            keys.append(f'samehead{middle}sametail')

    for _ in range(300):
        count = prng.randrange(1, 8)
        members = {prng.choice(keys): prng.randrange(100) for _ in range(count)}
        text = json.dumps(members)
        expected = json.loads(text)
        actual = json_zig.loads(text)

        assert actual == expected
        assert list(actual) == list(expected)


def test_evicted_keys_never_change_a_live_result_and_hash_like_new_keys() -> None:
    prng = random.Random(7500)
    live = []

    for round_index in range(40):
        count = prng.randrange(50, 3000)
        members = {f'{prng.getrandbits(64):016x}': index for index in range(count)}
        text = json.dumps(members)
        result = json_zig.loads(text)

        assert result == members
        assert all(result[key] == value for key, value in members.items())

        if round_index % 4 == 0:
            live.append((result, members))

    for result, members in live:
        assert result == members
        assert all(result[key] == value for key, value in members.items())


def test_keys_repeated_after_many_new_keys_load_like_the_standard_library() -> None:
    prng = random.Random(7600)

    for round_index in range(30):
        members = {}

        for index in range(1500 + round_index):
            members[f'{prng.getrandbits(64):016x}'] = {'lat': index, 'lng': -index}

        text = json.dumps(members)
        result = json_zig.loads(text)

        assert result == members

        del result

    gc.collect()

    assert json_zig.loads('{"lat":1,"lng":2}') == {'lat': 1, 'lng': 2}


@pytest.mark.parametrize('size', [64, 4000, 4060, 4096, 4160, 9000, 70000])
def test_escaped_strings_load_like_the_standard_library_around_the_scratch_size(size: int) -> None:
    assert size >= 64

    escaped = 'tab\there "quoted" back\\slash \u00e9 \U0001f600 line\nfeed'
    filler = 'x' * max(0, size - 200)
    members = {'first': escaped, 'filler': filler, 'last': escaped, 'tail': [escaped] * 3}

    for escaping in (False, True):
        text = json.dumps(members, ensure_ascii=escaping)

        assert json_zig.loads(text) == json.loads(text)
        assert json_zig.loads(text.encode()) == json.loads(text)


class Reentrant:
    def __init__(self, outcomes: list[bool]) -> None:
        assert isinstance(outcomes, list)

        self.cycle = self
        self.outcomes = outcomes

    def __del__(self) -> None:
        text = json.dumps({f'nested{index}': index for index in range(40)})
        self.outcomes.append(json_zig.loads(text) == json.loads(text))


def test_loads_called_from_a_finalizer_during_loads_matches_the_standard_library() -> None:
    nested = []

    with contextlib.ExitStack() as stack:
        stack.callback(gc.set_threshold, *gc.get_threshold())
        gc.set_threshold(1)

        for round_index in range(50):
            for _ in range(5):
                Reentrant(nested)

            members = {f'outer{round_index}_{index}': [index] for index in range(60)}
            text = json.dumps(members)

            assert json_zig.loads(text) == members

    gc.collect()

    assert nested
    assert all(nested)


@pytest.mark.parametrize('seed', range(10))
def test_numbers_between_blank_runs_load_like_the_standard_library(seed: int) -> None:
    assert 0 <= seed < 10

    prng = random.Random(7200 + seed)
    blanks = ('', ' ', '  ', '\n', '\n  ', '\n    ', '\t', '\r\n ', ' \n\t ')
    count = prng.randrange(1, 300)
    parts = []

    for index in range(count):
        number = prng.randrange(-(10**9), 10**9)
        piece = str(number) if prng.random() < 0.5 else f'{number}.{prng.randrange(10**6)}'
        tail = prng.choice(blanks)
        separator = ',' + tail if index + 1 < count else tail

        parts.append(piece + separator)

    text = '[' + prng.choice(blanks) + ''.join(parts) + ']'

    assert json_zig.loads(text) == json.loads(text)


def test_integers_before_an_invalid_token_raise_value_error() -> None:
    texts = [str(value % 1000 * 7919) for value in range(5000)]
    valid = '[' + ','.join(texts) + ']'

    with pytest.raises(json.JSONDecodeError):
        json_zig.loads(valid[:-1] + ', 1x]')

    assert json_zig.loads(valid) == json.loads(valid)


def dumps_expected(value: object) -> bytes:
    assert value is None or isinstance(value, bool | int | float | str | list | tuple | dict)

    result = json.dumps(value, separators=(',', ':'), ensure_ascii=False).encode()

    assert result

    return result


@pytest.mark.parametrize('seed', SEEDS)
def test_dumps_matches_the_standard_library_on_random_documents(seed: int) -> None:
    assert seed in SEEDS

    value = value_random(random.Random(seed))
    actual = json_zig.dumps(value)

    assert actual == dumps_expected(value)
    assert json.loads(actual) == value


def test_loads_reads_every_mix_of_literals_like_the_standard_library() -> None:
    literals = (True, False, None)

    for length in range(1, 6):
        for mix in itertools.product(literals, repeat=length):
            items = list(mix)

            for text in (json.dumps(items, separators=(',', ':')), json.dumps(items, indent=8)):
                assert json_zig.loads(text.encode()) == items
                assert json_zig.loads(text) == items

    prng = random.Random(0x6C6F6164)

    for size in (7, 8, 9, 1000, 70_000):
        items = [prng.choice(literals) for _ in range(size)]

        for text in (json.dumps(items, separators=(',', ':')), json.dumps(items, indent=8)):
            assert json_zig.loads(text.encode()) == items


def test_loads_refuses_every_near_literal_like_the_standard_library() -> None:
    tokens = (
        'nul',
        'tru',
        'fals',
        'nulll',
        'truex',
        'falsey',
        'NULL',
        'True',
        'fal se',
        'nu11',
        'falsE',
        'nulL',
        'truE',
        'fa',
        'n',
    )
    layouts = (
        '[{}]',
        '[true,{}]',
        '[{},null]',
        '{{"a":{}}}',
        '[\n        {}\n]',
        '[{},true,false]',
    )

    for token in tokens:
        for layout in layouts:
            text = layout.format(token)

            with pytest.raises(json.JSONDecodeError):
                json.loads(text)

            with pytest.raises(json.JSONDecodeError):
                json_zig.loads(text.encode())

    refused = (
        '[1,]',
        '[true,]',
        '{"a":}',
        '[true,,false]',
        '{"a":true,}',
        '[null,true,false,]',
        '[[true,],[true,false,null]]',
        '{"a":{"b":},"c":[true,false]}',
    )

    for text in refused:
        with pytest.raises(json.JSONDecodeError):
            json.loads(text)

        with pytest.raises(json.JSONDecodeError):
            json_zig.loads(text.encode())


def test_dumps_writes_every_mix_of_literals_like_the_standard_library() -> None:
    literals = (True, False, None)

    for length in range(1, 6):
        for mix in itertools.product(literals, repeat=length):
            items = list(mix)
            members = {f'key{index}': item for index, item in enumerate(items)}

            nested = [items, members, items[-1]]

            assert json_zig.dumps(items) == dumps_expected(items)
            assert json_zig.dumps(members) == dumps_expected(members)
            assert json_zig.dumps(nested) == dumps_expected(nested)

    prng = random.Random(0x6C697465)

    for size in (7, 8, 9, 63, 64, 65, 1000, 70_000):
        items = [prng.choice(literals) for _ in range(size)]

        assert json_zig.dumps(items) == dumps_expected(items)


@pytest.mark.parametrize('seed', range(20))
def test_dumps_writes_floats_like_repr(seed: int) -> None:
    assert 0 <= seed < 20

    prng = random.Random(9000 + seed)
    values = [struct_float(prng.getrandbits(64)) for _ in range(2000)]
    values += [0.0, -0.0, 1e16, 1e15, 0.0001, 0.00001, 5e-324, 1.7976931348623157e308]
    finite = [value for value in values if math.isfinite(value)]

    for value in finite:
        assert json_zig.dumps(value) == repr(value).encode(), repr(value)


def struct_float(bits: int) -> float:
    assert 0 <= bits < 2**64

    result = struct.unpack('<d', bits.to_bytes(8, 'little'))[0]

    assert isinstance(result, float)

    return result


@pytest.mark.parametrize(
    'text',
    [
        '',
        'plain ascii',
        ''.join(chr(point) for point in range(0x20)),
        'quote " backslash \\ slash / delete \x7f',
        'caf\xe9 \xff',
        'snowman ☃ and 日本語',
        'astral \U0001f600 \U0010ffff',
        'x' * 1000 + '\n' + 'y' * 37,
        '☃' * 100 + '"',
    ],
)
def test_dumps_escapes_strings_like_the_standard_library(text: str) -> None:
    assert isinstance(text, str)

    assert json_zig.dumps(text) == dumps_expected(text)
    assert json_zig.dumps({text: [text]}) == dumps_expected({text: [text]})


def test_dumps_writes_integers_of_every_size() -> None:
    values = [0, 1, -1, 2**30 - 1, 2**30, -(2**30), 2**63 - 1, -(2**63), 2**64, 10**40, -(10**40)]

    for value in values:
        assert json_zig.dumps(value) == str(value).encode()

    flags = [True, False]

    assert json_zig.dumps(flags) == b'[true,false]'
    assert json_zig.dumps(None) == b'null'


def test_dumps_writes_subclasses_like_their_base() -> None:
    class Text(str):
        __slots__ = ()

    class Number(int):
        pass

    class Real(float):
        pass

    class Mapping(dict):
        pass

    class Sequence(list):
        pass

    value = Mapping(a=Sequence([Text('t'), Number(7), Real(1.5), (1, 2)]), b=enum_value())

    assert json_zig.dumps(value) == dumps_expected(value)


def test_dumps_writes_exact_and_subclass_values_mixed_like_the_standard_library() -> None:
    class Text(str):
        __slots__ = ()

    class Number(int):
        pass

    class Real(float):
        pass

    class Mapping(dict):
        pass

    class Sequence(list):
        pass

    class Pair(tuple):
        __slots__ = ()

    exact = ['t', 7, 1.5, {'k': 1}, [2], (3, 4), True, None]
    derived = [Text('t'), Number(7), Real(1.5), Mapping(k=1), Sequence([2]), Pair((3, 4))]
    values = (
        [*exact, *derived],
        [*derived, *exact],
        Mapping(a=exact, b=derived),
        {'a': derived, 'b': exact},
    )

    for value in values:
        assert json_zig.dumps(value) == dumps_expected(value)


def enum_value() -> object:
    class Level(enum.IntEnum):
        high = 3

    result = Level.high

    assert result == 3

    return result


@pytest.mark.parametrize(
    'value',
    [math.inf, -math.inf, math.nan, [1.0, math.nan], {'a': math.inf}],
)
def test_dumps_refuses_non_finite_floats(value: object) -> None:
    assert value is not None

    with pytest.raises(ValueError, match='non-finite'):
        json_zig.dumps(value)


@pytest.mark.parametrize('value', [object(), {1: 2}, {(1,): 'a'}, [b'bytes'], {1.5}])
def test_dumps_refuses_what_json_cannot_hold(value: object) -> None:
    assert value is not None

    with pytest.raises(TypeError):
        json_zig.dumps(value)


def test_dumps_refuses_lone_surrogates() -> None:
    with pytest.raises(ValueError, match='surrogate'):
        json_zig.dumps('\ud800')

    assert json_zig.dumps('\ud7ff\ue000') == '"\ud7ff\ue000"'.encode()


def test_dumps_refuses_cycles_and_extreme_nesting() -> None:
    cycle: list[object] = []
    cycle.append(cycle)

    deep: list[object] = []
    shallow: list[object] = []

    for _ in range(2000):
        deep = [deep]

    for _ in range(1024):
        shallow = [shallow]

    with pytest.raises(ValueError, match='deep'):
        json_zig.dumps(cycle)

    with pytest.raises(ValueError, match='deep'):
        json_zig.dumps(deep)

    assert json_zig.dumps(shallow) == b'[' * 1025 + b']' * 1025


def test_dumps_writes_large_documents() -> None:
    prng = random.Random(11)
    value = [value_random(prng) for _ in range(300)]
    actual = json_zig.dumps(value)

    assert len(actual) > 64 * 1024
    assert actual == dumps_expected(value)


def test_repeated_dumps_do_not_leak() -> None:
    value = [value_random(random.Random(seed)) for seed in range(50)]

    for _ in range(20):
        json_zig.dumps(value)

    tracemalloc.start()
    before = tracemalloc.get_traced_memory()[0]

    for _ in range(200):
        json_zig.dumps(value)

        with pytest.raises(TypeError):
            json_zig.dumps([1, object()])

    after = tracemalloc.get_traced_memory()[0]
    tracemalloc.stop()

    assert before >= 0
    assert after - before < 64 * 1024


@pytest.mark.parametrize('seed', range(10))
def test_dumps_escapes_random_short_strings_like_the_standard_library(seed: int) -> None:
    assert 0 <= seed < 10

    prng = random.Random(7000 + seed)
    alphabets = ('ab"\\\n\x00\x1f\x7f /', 'ab"\\\n\x00\x1f\xe9☃\U0001f600')
    texts = []

    for _ in range(1000):
        alphabet = prng.choice(alphabets)
        texts.append(''.join(prng.choice(alphabet) for _ in range(prng.randrange(40))))

    assert json_zig.dumps(texts) == dumps_expected(texts)


def test_dumps_walks_every_dictionary_layout() -> None:
    class Holder:
        pass

    holder = Holder()
    holder.first = 1
    holder.second = [2, 3]

    deleted = {'x': 1, 'y': 2, 'z': 3}
    del deleted['y']

    general: dict[object, object] = {1: 'a', 'k': 'v'}
    del general[1]

    value = [vars(holder), deleted, general, {}]

    assert list(deleted) == ['x', 'z']
    assert list(general) == ['k']
    assert json_zig.dumps(value) == dumps_expected(value)


def words_joined(name: str, *, capital_first: bool) -> str:
    assert isinstance(name, str)

    parts = name.split('_')

    if not name:
        return name

    if len(parts) == 1:
        if not capital_first:
            return name

    result = []
    first = True

    for part in parts:
        if first:
            if not part:
                result.append('_')
                continue

            if not capital_first:
                first = False
                result.append(part)
                continue

        first = False
        result.append(part.title())

    return ''.join(result)


def snake_spaced(name: str) -> str:
    assert isinstance(name, str)

    spaced = re.sub(r'([A-Z]+)([A-Z][a-z])', r'\1_\2', name)
    spaced = re.sub(r'([a-z\d])([A-Z])', r'\1_\2', spaced)

    return spaced.replace('-', '_').lower()


def renamed_expected(*, style: str, name: str) -> str:
    assert style in STYLES
    assert isinstance(name, str)

    if style == 'camel':
        return words_joined(name, capital_first=False)

    if style == 'pascal':
        return words_joined(name, capital_first=True)

    if style == 'kebab':
        return name.strip('_').replace('_', '-')

    if style == 'snake':
        return snake_spaced(name)

    return name.lower() if style == 'lower' else name.upper()


def name_random(prng: random.Random) -> str:
    assert isinstance(prng, random.Random)

    alphabets = ('aAbBzZ09_-', 'aAéÉüÜßΣİǆ٣日_-', 'xX1_Ü-')
    alphabet = prng.choice(alphabets)
    result = ''.join(prng.choice(alphabet) for _ in range(prng.randrange(18)))

    assert len(result) < 18

    return result


class Styled:
    def __init__(self, style: str) -> None:
        assert style in STYLES

        self.style = style

    def __call__(self, name: str) -> str:
        assert isinstance(name, str)

        return renamed_expected(style=self.style, name=name)


class Kept:
    def __init__(self, rename: object) -> None:
        assert callable(rename)

        self.rename = rename

    def __call__(self, name: str) -> str:
        assert isinstance(name, str)

        result = self.rename(name)

        return name if result is None else result


def loads_renamed(text: str, rename: object) -> object:
    assert isinstance(text, str)
    assert callable(rename)

    kept = Kept(rename)

    def hook(pairs: list[tuple[str, object]]) -> dict[str, object]:
        assert isinstance(pairs, list)

        return {kept(key): child for key, child in pairs}

    return json.loads(text, object_pairs_hook=hook)


def dumps_renamed(value: object, *, rename: object) -> object:
    assert value is not None
    assert callable(rename)

    kept = Kept(rename)

    def hook(pairs: list[tuple[str, object]]) -> list[tuple[str, object]]:
        assert isinstance(pairs, list)

        return [(kept(key), child) for key, child in pairs]

    return json.loads(json.dumps(value), object_pairs_hook=hook)


def keyed_random(prng: random.Random) -> object:
    assert isinstance(prng, random.Random)

    root: list[object] = [value_random(prng)]
    pending: list[object] = [root]

    for _ in range(100_000):
        if not pending:
            break

        item = pending.pop()
        slots = list(item) if isinstance(item, dict) else list(range(len(item)))

        for slot in slots:
            child = item[slot]

            if isinstance(child, dict):
                child = {name_random(prng): grandchild for grandchild in child.values()}
                item[slot] = child

            if isinstance(child, list | dict):
                pending.append(child)

    assert not pending

    return root[0]


@pytest.mark.parametrize('style', STYLES)
def test_rename_styles_follow_msgspec_and_inflection(style: str) -> None:
    assert style in STYLES

    names = list(NAMES) + [name_random(random.Random(seed)) for seed in range(2000)]
    table = {name: index for index, name in enumerate(dict.fromkeys(names))}
    text = json.dumps(table, ensure_ascii=False)
    expected = loads_renamed(text, Styled(style))

    assert json_zig.loads(text, rename=style) == expected
    assert json_zig.loads(text.encode(), rename=style) == expected


@pytest.mark.parametrize('seed', range(12))
def test_rename_applies_at_every_depth(seed: int) -> None:
    assert 0 <= seed < 12

    prng = random.Random(9000 + seed)
    text = json.dumps(keyed_random(prng), ensure_ascii=False)

    for style in STYLES:
        expected = loads_renamed(text, Styled(style))

        assert json_zig.loads(text, rename=style) == expected
        assert json_zig.loads(text.encode(), rename=style) == expected


def test_rename_reaches_long_and_escaped_keys() -> None:
    names = ['long_key_' * 20, 'escaped\n_key', 'quote"key_x', 'ü' * 40 + '_tail', 'Xy' * 50]
    text = json.dumps([{name: [{name: 1}]} for name in names], ensure_ascii=False)

    for style in STYLES:
        assert json_zig.loads(text, rename=style) == loads_renamed(text, Styled(style))


class Sparse:
    def __getitem__(self, name: str) -> str:
        assert isinstance(name, str)

        if name == 'b':
            raise KeyError(name)

        return name * 2


def test_rename_takes_a_callable_or_a_mapping() -> None:
    text = '{"a": {"b": 1, "c": [{"a": 2}]}, "d": 3}'
    mapping = {'a': 'alpha', 'c': None}

    assert json_zig.loads(text, rename=str.upper) == loads_renamed(text, str.upper)
    assert json_zig.loads(text, rename=mapping) == loads_renamed(text, mapping.get)
    assert json_zig.loads(text, rename=Sparse()) == {'aa': {'b': 1, 'cc': [{'aa': 2}]}, 'dd': 3}
    assert json_zig.loads(text, rename={}) == json.loads(text)
    assert json_zig.loads(text, rename=None) == json.loads(text)


def test_rename_keeps_the_last_of_keys_that_rename_alike() -> None:
    text = '{"user_id": 1, "userId": 2, "x": {"a_b": 3, "aB": 4}}'

    assert json_zig.loads(text, rename='camel') == {'userId': 2, 'x': {'aB': 4}}
    assert json_zig.loads(text, rename='camel') == loads_renamed(text, Styled('camel'))


class RenameError(LookupError):
    pass


def rename_refused(name: str) -> str:
    assert isinstance(name, str)

    raise RenameError(name)


def rename_numbered(name: str) -> int:
    assert isinstance(name, str)

    return len(name)


def test_rename_refuses_what_is_not_a_policy() -> None:
    with pytest.raises(ValueError, match='style'):
        json_zig.loads(b'{}', rename='title')

    with pytest.raises(TypeError, match='mapping'):
        json_zig.loads(b'{}', rename=3)

    with pytest.raises(TypeError, match='str or None'):
        json_zig.loads(b'{"a": 1}', rename=rename_numbered)

    with pytest.raises(RenameError, match='a'):
        json_zig.loads(b'{"a": 1}', rename=rename_refused)

    with pytest.raises(ValueError, match='style'):
        json_zig.dumps({}, rename='title')

    with pytest.raises(RenameError, match='a'):
        json_zig.dumps({'a': 1}, rename=rename_refused)

    assert json_zig.loads(b'{"a": 1}', rename='upper') == {'A': 1}


@pytest.mark.parametrize('seed', range(12))
def test_dumps_renames_keys_at_every_depth(seed: int) -> None:
    assert 0 <= seed < 12

    value = keyed_random(random.Random(9100 + seed))

    for style in STYLES:
        actual = json_zig.dumps(value, rename=style)
        expected = dumps_renamed(value, rename=Styled(style))

        assert json.loads(actual, object_pairs_hook=list) == expected

    assert json_zig.dumps(value, rename=str.upper) == json_zig.dumps(value, rename='upper')
    assert json_zig.dumps(value, rename={}) == dumps_expected(value)


@pytest.mark.parametrize(
    'text',
    [
        '"',
        '"abc',
        '["abc',
        '["a\\nbc',
        '["x\\u00e9y',
        '{"a',
        '{"a":"b',
        '["\u00e9", "abc',
        '[1, "' + 'x' * 100,
        '[\n "a\\tb',
    ],
)
def test_an_unterminated_string_is_reported_at_its_quote_like_the_standard_library(
    text: str,
) -> None:
    assert '"' in text

    with pytest.raises(json.JSONDecodeError) as expected:
        json.loads(text)

    position = expected.value.pos

    assert text[position] == '"'

    for source in (text, text.encode()):
        with pytest.raises(json.JSONDecodeError) as raised:
            json_zig.loads(source)

        assert raised.value.pos == position
        assert (raised.value.lineno, raised.value.colno) == (
            expected.value.lineno,
            expected.value.colno,
        )

    with pytest.raises(json.JSONDecodeError) as raised:
        json_zig.Document(text.encode())

    assert raised.value.pos == position


def test_errors_are_json_decode_errors_at_the_character() -> None:
    cases = [
        ('{"é": 1,}', '}', 1, 9),
        ('[1,\n 2,]', ']', 2, 4),
        ('{"日本": [1 2]}', '2', 1, 11),
        ('\n\n  tru', 't', 3, 3),
    ]

    for text, character, line, column in cases:
        data = text.encode()

        for source in (text, data, bytearray(data), memoryview(data)):
            with pytest.raises(json.JSONDecodeError) as raised:
                json_zig.loads(source)

            error = raised.value

            assert error.doc == text
            assert error.doc[error.pos] == character
            assert (error.lineno, error.colno) == (line, column)
            assert 'line' not in error.msg

        with pytest.raises(json.JSONDecodeError) as raised:
            json_zig.Document(data)

        assert raised.value.doc[raised.value.pos] == character


def test_errors_on_invalid_utf8_keep_a_decoded_document() -> None:
    data = b'["ok", "\xff"]'

    with pytest.raises(json.JSONDecodeError) as raised:
        json_zig.loads(data)

    assert raised.value.doc == data.decode('utf-8', 'replace')
    assert 0 <= raised.value.pos <= len(raised.value.doc)


@pytest.mark.parametrize('seed', range(8))
def test_buffers_load_like_bytes(seed: int) -> None:
    assert 0 <= seed < 8

    data = json.dumps(value_random(random.Random(9200 + seed)), ensure_ascii=False).encode()
    expected = json.loads(data)
    framed = b'#' + data + b'#'

    assert json_zig.loads(bytearray(data)) == expected
    assert json_zig.loads(memoryview(data)) == expected
    assert json_zig.loads(memoryview(framed)[1:-1]) == expected
    assert json_zig.loads(array.array('B', data)) == expected
    assert json_zig.Document(bytearray(data)).as_objects() == expected


class Clobbering:
    def __init__(self, source: bytearray, filler: bytes) -> None:
        assert isinstance(source, bytearray)
        assert isinstance(filler, bytes)

        self.filler = filler
        self.source = source

    def __call__(self, name: str) -> str:
        assert isinstance(name, str)

        self.source[:] = self.filler

        return name


def test_buffers_are_copied_before_parsing() -> None:
    source = bytearray(b'{"a": "kept", "b": [1, 2]}')
    filler = b'[' * len(source)
    clobbered = Clobbering(source, filler)

    assert json_zig.loads(source, rename=clobbered) == {'a': 'kept', 'b': [1, 2]}

    source[:] = b'{"x": [3, 4, "five"]}'
    document = json_zig.Document(source)
    source[:] = filler

    assert document.as_objects() == {'x': [3, 4, 'five']}


def test_buffers_that_are_not_contiguous_raise_type_error() -> None:
    with pytest.raises(TypeError, match='buffer'):
        json_zig.loads(memoryview(b'[1, 2]  ')[::2])

    with pytest.raises(TypeError, match='buffer'):
        json_zig.Document('text')

    assert json_zig.loads(memoryview(b'[1, 2]  ')[:6]) == [1, 2]


def unknown_random(prng: random.Random) -> object:
    assert isinstance(prng, random.Random)

    choices = (fractions.Fraction(prng.randrange(9), 7), {1, 2}, frozenset('ab'), 1j)
    result = prng.choice(choices)

    assert not isinstance(result, int | float | str | list | dict)

    return result


def default_value(prng: random.Random) -> object:
    assert isinstance(prng, random.Random)

    root: list[object] = [value_random(prng)]
    pending: list[object] = [root]

    for _ in range(100_000):
        if not pending:
            break

        item = pending.pop()
        slots = list(item) if isinstance(item, dict) else list(range(len(item)))

        for slot in slots:
            if isinstance(item[slot], list | dict):
                pending.append(item[slot])

                continue

            if prng.random() >= 0.2:
                continue

            item[slot] = unknown_random(prng)

    assert not pending

    return root[0]


def converted(value: object) -> object:
    assert value is not None

    if isinstance(value, fractions.Fraction):
        return [value.numerator, value.denominator]

    if isinstance(value, set | frozenset):
        return sorted(value)

    if isinstance(value, complex):
        return {'real': value.real, 'imaginary': value.imag}

    raise TypeError(type(value).__name__)


@pytest.mark.parametrize('seed', range(12))
def test_dumps_calls_default_like_the_standard_library(seed: int) -> None:
    assert 0 <= seed < 12

    value = default_value(random.Random(9300 + seed))
    expected = json.dumps(value, default=converted, separators=(',', ':'), ensure_ascii=False)
    plain = json.loads(expected)

    assert json_zig.dumps(value, default=converted) == expected.encode()
    assert json_zig.dumps(value, default=converted, rename='upper') == json_zig.dumps(
        plain,
        rename='upper',
    )


class Wrapper:
    def __init__(self, inner: object) -> None:
        assert not isinstance(inner, Wrapper) or inner is not self

        self.inner = inner


def unwrapped(value: object) -> object:
    assert value is not None

    if isinstance(value, Wrapper):
        return value.inner

    raise TypeError(type(value).__name__)


def boxed(value: object) -> object:
    assert value is not None

    return [value]


def test_default_chains_until_a_value_serializes() -> None:
    value = {'a': Wrapper(Wrapper([Wrapper(1), {'b': Wrapper('c')}]))}
    expected = json.dumps(value, default=unwrapped, separators=(',', ':')).encode()

    assert json_zig.dumps(value, default=unwrapped) == expected

    with pytest.raises(ValueError, match='Circular'):
        json.dumps(Wrapper(None), default=lambda inner: inner)

    with pytest.raises(ValueError, match='default'):
        json_zig.dumps(Wrapper(None), default=lambda inner: inner)

    with pytest.raises(ValueError, match='Circular'):
        json.dumps(Wrapper(None), default=boxed)

    with pytest.raises(ValueError, match='deep'):
        json_zig.dumps(Wrapper(None), default=boxed)

    with pytest.raises(TypeError, match='object'):
        json_zig.dumps([1, object()], default=unwrapped)


def mutation_grow(value: object, *, grown: dict[str, object]) -> object:
    assert value is not None
    assert isinstance(grown, dict)

    grown['c'] = 3

    return type(value).__name__


def mutation_shrink(value: object, *, holder: list[object], shrunk: list[object]) -> object:
    assert value is not None
    assert isinstance(holder, list)
    assert isinstance(shrunk, list)

    shrunk.clear()
    holder.clear()

    return type(value).__name__


def mutation_append(value: object, *, appended: list[object]) -> object:
    assert value is not None
    assert isinstance(appended, list)

    if len(appended) < 6:
        appended.append(object())

    return [len(appended), type(value).__name__]


def mutation_delete(value: object, *, deleted: dict[str, object]) -> object:
    assert value is not None
    assert isinstance(deleted, dict)

    _ = deleted.pop('b', None)

    return type(value).__name__


def mutation_resize(value: object, *, resized: dict[str, object]) -> object:
    assert value is not None
    assert isinstance(resized, dict)

    for index in range(1, 40):
        _ = resized.setdefault(f'k{index}', index)

    return type(value).__name__


def mutation_cases() -> list[tuple[object, object]]:
    grown: dict[str, object] = {'a': object(), 'b': 2}
    shrunk: list[object] = [object(), 1, 2]
    holder: list[object] = [[object(), 5], shrunk]
    appended: list[object] = [object(), 1]
    deleted: dict[str, object] = {'a': object(), 'b': 2, 'c': 3}
    resized: dict[str, object] = {'k0': object()}

    result = [
        (grown, functools.partial(mutation_grow, grown=grown)),
        (holder, functools.partial(mutation_shrink, holder=holder, shrunk=shrunk)),
        (appended, functools.partial(mutation_append, appended=appended)),
        (deleted, functools.partial(mutation_delete, deleted=deleted)),
        (resized, functools.partial(mutation_resize, resized=resized)),
    ]

    assert all(callable(default) for _, default in result)

    return result


def test_default_that_mutates_the_document_matches_the_standard_library() -> None:
    expected = [
        json.dumps(value, default=default, separators=(',', ':')).encode()
        for value, default in mutation_cases()
    ]

    actual = [json_zig.dumps(value, default=default) for value, default in mutation_cases()]

    assert actual == expected


class Clearing:
    def __init__(
        self,
        target: dict[str, object],
        *,
        alive: list[bool],
        probe: weakref.ref,
    ) -> None:
        assert isinstance(target, dict)
        assert isinstance(alive, list)
        assert callable(probe)

        self.alive = alive
        self.probe = probe
        self.target = target

    def renamed(self, name: str) -> str:
        assert isinstance(name, str)

        self.target.clear()
        self.alive.append(self.probe() is not None)

        return name.upper()


class ClearingCall(Clearing):
    def __call__(self, name: str) -> str:
        assert isinstance(name, str)

        return self.renamed(name)


class ClearingMapping(Clearing):
    def __getitem__(self, name: str) -> str:
        assert isinstance(name, str)

        return self.renamed(name)


def test_rename_that_mutates_the_document_keeps_the_pair_it_renames() -> None:
    class Watched(dict):
        pass

    alive: list[bool] = []
    called: dict[str, object] = {'a': Watched(x=1), 'b': 2}
    mapped: dict[str, object] = {'a': Watched(x=1), 'b': 2}
    probes = [weakref.ref(called['a']), weakref.ref(mapped['a'])]
    clear_called = ClearingCall(called, alive=alive, probe=probes[0])
    clear_mapped = ClearingMapping(mapped, alive=alive, probe=probes[1])

    assert json_zig.dumps(called, rename=clear_called) == b'{"A":{"X":1}}'
    assert json_zig.dumps(mapped, rename=clear_mapped) == b'{"A":{"X":1}}'
    assert alive == [True, True, True, True]
    assert [probe() for probe in probes] == [None, None]


class Tracked:
    live = 0

    def __init__(self) -> None:
        assert Tracked.live >= 0

        Tracked.live += 1

    def __del__(self) -> None:
        assert Tracked.live > 0

        Tracked.live -= 1


def tracked(value: object) -> object:
    assert value is not None

    return 'done' if isinstance(value, Tracked) else Tracked()


def titled(name: str) -> str:
    assert isinstance(name, str)

    return name.title()


def test_hooks_release_every_reference() -> None:
    keys = [f'key_{index}_name' for index in range(50)]
    value = [{key: object() for key in keys}, {'k' * 80 + key: [object()] for key in keys}]
    text = json.dumps([dict.fromkeys(keys, 1), {'k' * 80 + key: 2 for key in keys}])
    mapping = {key: key.upper() for key in keys}
    source = bytearray(text.encode())
    observed = [*keys, mapping, titled, tracked, source]
    before = [sys.getrefcount(item) for item in observed]

    for _ in range(200):
        json_zig.dumps(value, default=tracked, rename=titled)
        json_zig.dumps(value, default=tracked, rename=mapping)
        json_zig.dumps(value, default=tracked, rename='camel')
        json_zig.loads(source, rename=titled)
        json_zig.loads(source, rename=mapping)
        json_zig.Document(source).as_objects()

    after = [sys.getrefcount(item) for item in observed]

    assert after == before
    assert Tracked.live == 0


def fresh(inner: object) -> object:
    assert inner is not None

    return type(inner)()


def hooks_window(value: object, text: bytes) -> None:
    assert isinstance(value, list)
    assert isinstance(text, bytes)

    for _ in range(50):
        json_zig.dumps(value, default=converted, rename='camel')
        json_zig.dumps(value, default=converted, rename=str.lower)
        json_zig.loads(text, rename='snake')
        json_zig.loads(text, rename=str.upper)
        json_zig.loads(text, rename={'a': 'b'})

        with pytest.raises(ValueError, match='default'):
            json_zig.dumps([1, object()], default=fresh)


def test_repeated_hooks_do_not_leak() -> None:
    value = [default_value(random.Random(seed)) for seed in range(20)]
    text = json.dumps(json.loads(json_zig.dumps(value, default=converted))).encode()

    hooks_window(value, text)
    tracemalloc.start()
    hooks_window(value, text)
    middle = tracemalloc.get_traced_memory()[0]
    hooks_window(value, text)
    after = tracemalloc.get_traced_memory()[0]
    tracemalloc.stop()

    assert middle >= 0
    assert after - middle < 64 * 1024
