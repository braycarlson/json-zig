import collections
import csv
import dataclasses
import datetime as dt
import json
import math
import pathlib
import statistics

from xml.sax.saxutils import escape


ROOT = pathlib.Path(__file__).resolve().parent
ASSETS = ROOT.parent / 'assets'
RESULTS = ROOT / 'results'
AXIS_STEP_FACTORS = (0.1, 0.2, 0.25, 0.5, 1, 2, 2.5, 5, 10)
AXIS_TICK_COUNT_MAX = 6
AXIS_TOLERANCE = 1e-9
BAR_GAP = 12
BAR_HEIGHT = 18
BAR_RADIUS = 4
CHART_PADDING = 24
CHART_WIDTH = 800
COLOR_PREFIXES = ('#', 'rgba(')
CPU_NAME_NOISE = ('13th Gen ', '(R)', '(TM)')
ELEMENT_NAMES = ('line', 'path', 'rect', 'text', 'title', 'tspan')
FONT_FAMILY = "system-ui, -apple-system, 'Segoe UI', sans-serif"
FOOTER_GAP = 50
FOOTER_PITCH = 17
LABEL_WIDTH = 252
OUTCOMES = ('accepted', 'crashed', 'rejected')
PLOT_TOP = 88
ROW_PITCH = 30
TICK_DECIMALS_MAX = 5
TURBO_STATES = (('0', 'enabled'), ('1', 'disabled'))
VALUE_TENTHS_MIN = 10
VALUE_WHOLE_MIN = 100
VALUE_WIDTH = 56
VARIANT_BASELINE = 'ReleaseSafe, x86-64 baseline'
WORKLOADS_READ = ('decode', 'document', 'loads', 'tokenize')
BAR_LEFT = CHART_PADDING + LABEL_WIDTH + BAR_GAP
BAR_WIDTH_MAX = CHART_WIDTH - BAR_LEFT - VALUE_WIDTH - CHART_PADDING

ENVIRONMENT_KEYS = (
    'cpu',
    'cpu_measured',
    'cpu_sibling',
    'energy_performance_preference',
    'finished',
    'governor',
    'json_zig_commit',
    'json_zig_modified_paths',
    'load_average_start',
    'microcode',
    'no_turbo',
    'round_count',
    'started',
    'tools',
)

LABELS = (
    (('decode', 'simdjson'), 'simdjson On-Demand'),
    (('document', 'yyjson (raw numbers)'), 'yyjson raw numbers'),
    (('tokenize', 'serde_json'), 'serde_json IgnoredAny'),
    (('write', 'yyjson (raw numbers)'), 'yyjson raw numbers'),
)

SUMMARY_COLUMNS = (
    'Workload',
    'json-zig',
    'json-zig ReleaseSafe',
    'Fastest other',
    'Its throughput',
    'Ratio',
)

WORKLOADS = (
    ('document', 'Parse into a document'),
    ('decode', 'Decode into typed values'),
    ('tokenize', 'Tokenize without building values'),
    ('write', 'Write a document'),
    ('encode', 'Encode typed values'),
    ('loads', 'Python loads'),
    ('dumps', 'Python dumps'),
)


@dataclasses.dataclass(frozen=True)
class Cell:
    workload: str
    input: str
    implementation: str
    variant: str
    language: str
    size_bytes: int
    checksum: str
    time_ns: float
    spread: float

    def __post_init__(self) -> None:
        if self.workload not in dict(WORKLOADS):
            message = f'{self.workload} is not a charted workload'
            raise ValueError(message)

        if self.size_bytes <= 0:
            message = f'{self.workload} {self.input} {self.implementation} reports no bytes'
            raise ValueError(message)

        if self.time_ns <= 0:
            message = f'{self.workload} {self.input} {self.implementation} reports no time'
            raise ValueError(message)


@dataclasses.dataclass(frozen=True)
class Series:
    workload: str
    implementation: str
    variant: str
    language: str
    throughputs: dict[str, float]
    geomean: float

    def __post_init__(self) -> None:
        if not self.throughputs:
            message = f'{self.implementation} ({self.variant}) has no {self.workload} inputs'
            raise ValueError(message)

        if self.geomean <= 0:
            message = f'{self.implementation} ({self.variant}) has a geomean of {self.geomean}'
            raise ValueError(message)


@dataclasses.dataclass(frozen=True)
class Theme:
    accent: str
    baseline: str
    border: str
    grid: str
    ink: str
    muted: str
    neutral: str
    secondary: str
    surface: str

    def __post_init__(self) -> None:
        colors = dataclasses.astuple(self)

        if not all(color.startswith(COLOR_PREFIXES) for color in colors):
            message = f'a theme color is neither hex nor rgba: {colors}'
            raise ValueError(message)


@dataclasses.dataclass(frozen=True)
class Layout:
    plot_bottom: int
    footer_top: int
    height: int

    def __post_init__(self) -> None:
        if not PLOT_TOP < self.plot_bottom < self.footer_top < self.height:
            message = f'the chart layout is out of order: {self}'
            raise ValueError(message)


@dataclasses.dataclass(frozen=True)
class Chart:
    footer: list[str]
    notes: dict[tuple[str, str], list[str]]
    series: list[Series]
    subtitle: str
    title: str

    def __post_init__(self) -> None:
        if not self.series:
            message = f'the {self.title} chart has no series'
            raise ValueError(message)

        if not self.footer:
            message = f'the {self.title} chart has no footer'
            raise ValueError(message)

    @property
    def axis(self) -> tuple[float, float]:
        return axis_of(max(item.geomean for item in self.series))

    @property
    def layout(self) -> Layout:
        plot_bottom = PLOT_TOP + len(self.series) * ROW_PITCH
        footer_top = plot_bottom + FOOTER_GAP
        height = footer_top + (len(self.footer) - 1) * FOOTER_PITCH + CHART_PADDING

        return Layout(plot_bottom=plot_bottom, footer_top=footer_top, height=height)


@dataclasses.dataclass(frozen=True)
class Results:
    cells: list[Cell]
    environment: dict[str, object]
    notes: dict[tuple[str, str], list[str]]
    rows: list[dict[str, str]]
    series: list[Series]
    validation: list[dict[str, str]]

    def __post_init__(self) -> None:
        missing = [key for key in ENVIRONMENT_KEYS if key not in self.environment]

        if missing:
            message = f'environment.json lacks {", ".join(missing)}'
            raise ValueError(message)

        if not self.series:
            message = 'the measurements produced no series'
            raise ValueError(message)


THEME_DARK = Theme(
    accent='#3987e5',
    baseline='#383835',
    border='rgba(255,255,255,0.10)',
    grid='#2c2c2a',
    ink='#f0efec',
    muted='#898781',
    neutral='#5f5e59',
    secondary='#c3c2b7',
    surface='#1a1a19',
)

THEME_LIGHT = Theme(
    accent='#2a78d6',
    baseline='#c3c2b7',
    border='rgba(11,11,11,0.10)',
    grid='#e1e0d9',
    ink='#0b0b0b',
    muted='#898781',
    neutral='#b4b2a9',
    secondary='#52514e',
    surface='#fcfcfb',
)

THEMES = (('light', THEME_LIGHT), ('dark', THEME_DARK))


def main() -> None:
    results = results_read()

    ASSETS.mkdir(parents=True, exist_ok=True)

    for workload, _ in WORKLOADS:
        chart = chart_of(results, workload)

        for ground, theme in THEMES:
            svg = chart_svg(chart, theme)
            path = ASSETS / f'json-zig-benchmark-{workload}-on-{ground}.svg'

            path.write_text(svg, encoding='utf-8')

    markdown = markdown_of(results)
    path = ROOT / 'results.md'

    path.write_text(markdown, encoding='utf-8')


def attributes_of(attributes: dict[str, object]) -> str:
    if any(value is None for value in attributes.values()):
        message = f'an attribute has no value: {attributes}'
        raise ValueError(message)

    entities = {'"': '&quot;'}
    pairs = [f'{key}="{escape(str(value), entities)}"' for key, value in attributes.items()]

    return ' '.join(pairs)


def axis_of(value_max: float) -> tuple[float, float]:
    if value_max <= 0:
        message = f'value_max must be positive: {value_max}'
        raise ValueError(message)

    magnitude = 10 ** math.floor(math.log10(value_max))

    for factor in AXIS_STEP_FACTORS:
        step = factor * magnitude
        count = math.ceil(value_max / step - AXIS_TOLERANCE)

        if count <= AXIS_TICK_COUNT_MAX:
            return step, count * step

    message = f'no axis step fits {value_max}'
    raise RuntimeError(message)


def bar_path(*, left: float, right: float, top: float) -> str:
    if right < left:
        message = f'a bar ends at {right} before it starts at {left}'
        raise ValueError(message)

    if top < PLOT_TOP:
        message = f'a bar at {top} starts above the plot at {PLOT_TOP}'
        raise ValueError(message)

    radius = min(BAR_RADIUS, (right - left) / 2, BAR_HEIGHT / 2)
    bottom = top + BAR_HEIGHT

    return (
        f'M{left:.1f},{top:.1f} H{right - radius:.1f} '
        f'A{radius:.1f},{radius:.1f} 0 0 1 {right:.1f},{top + radius:.1f} '
        f'V{bottom - radius:.1f} '
        f'A{radius:.1f},{radius:.1f} 0 0 1 {right - radius:.1f},{bottom:.1f} '
        f'H{left:.1f} Z'
    )


def cells_aggregate(rows: list[dict[str, str]], round_count: int) -> list[Cell]:
    if not rows:
        message = 'measurements.csv has no rows'
        raise ValueError(message)

    if round_count < 1:
        message = f'round_count must be positive: {round_count}'
        raise ValueError(message)

    groups = collections.defaultdict(list)
    cells = []

    for row in rows:
        key = (row['workload'], row['input'], row['implementation'], row['variant'])
        groups[key].append(row)

    for (workload, name, implementation, variant), group in sorted(groups.items()):
        label = f'{workload} {name} {implementation} ({variant})'
        checksums = {row['checksum'] for row in group}
        sizes = {int(row['bytes']) for row in group}
        times = sorted(int(row['best_ns']) for row in group)
        time_ns = statistics.median(times)

        if len(group) != round_count:
            message = f'{label}: {len(group)} rounds, expected {round_count}'
            raise RuntimeError(message)

        if len(checksums) != 1:
            message = f'{label}: the checksums {sorted(checksums)} differ between rounds'
            raise RuntimeError(message)

        if len(sizes) != 1:
            message = f'{label}: the sizes {sorted(sizes)} differ between rounds'
            raise RuntimeError(message)

        cell = Cell(
            workload=workload,
            input=name,
            implementation=implementation,
            variant=variant,
            language=group[0]['language'],
            size_bytes=sizes.pop(),
            checksum=checksums.pop(),
            time_ns=time_ns,
            spread=(times[-1] - times[0]) / time_ns,
        )

        cells.append(cell)

    return cells


def chart_axis(chart: Chart, theme: Theme) -> list[str]:
    layout = chart.layout
    step, axis_max = chart.axis
    scale = BAR_WIDTH_MAX / axis_max
    tick_count = round(axis_max / step)
    parts = []

    for index in range(tick_count + 1):
        value = index * step
        position = BAR_LEFT + value * scale
        stroke = theme.baseline if index == 0 else theme.grid
        tick = tick_format(value=value, step=step)

        line = {
            'x1': f'{position:.1f}',
            'x2': f'{position:.1f}',
            'y1': PLOT_TOP - 6,
            'y2': f'{layout.plot_bottom + 6:.1f}',
            'stroke': stroke,
            'stroke-width': 1,
        }

        label = {
            'x': f'{position:.1f}',
            'y': f'{layout.plot_bottom + 22:.1f}',
            'fill': theme.muted,
            'font-size': 11,
            'text-anchor': 'middle',
        }

        gridline = element_empty('line', line)
        text = element('text', label, content=tick)

        parts.append(gridline)
        parts.append(text)

    return parts


def chart_footer(chart: Chart, theme: Theme) -> list[str]:
    layout = chart.layout
    parts = []

    for index, line in enumerate(chart.footer):
        attributes = {
            'x': CHART_PADDING,
            'y': layout.footer_top + index * FOOTER_PITCH,
            'fill': theme.muted,
            'font-size': 11,
        }

        text = element('text', attributes, content=escape(line))

        parts.append(text)

    return parts


def chart_header(chart: Chart, theme: Theme) -> list[str]:
    layout = chart.layout

    root = {
        'xmlns': 'http://www.w3.org/2000/svg',
        'width': CHART_WIDTH,
        'height': layout.height,
        'viewBox': f'0 0 {CHART_WIDTH} {layout.height}',
        'role': 'img',
        'aria-labelledby': 'title',
    }

    frame = {
        'x': 0.5,
        'y': 0.5,
        'width': CHART_WIDTH - 1,
        'height': layout.height - 1,
        'rx': 12,
        'fill': theme.surface,
        'stroke': theme.border,
    }

    heading = {
        'x': CHART_PADDING,
        'y': 42,
        'fill': theme.ink,
        'font-size': 17,
        'font-weight': 600,
    }

    caption = {'x': CHART_PADDING, 'y': 64, 'fill': theme.secondary, 'font-size': 13}
    description = escape(f'{chart.title}. {chart.subtitle}.')
    identifier = {'id': 'title'}

    return [
        f'<svg {attributes_of(root)}>',
        element('title', identifier, content=description),
        element_empty('rect', frame),
        f'<g font-family="{FONT_FAMILY}">',
        element('text', heading, content=escape(chart.title)),
        element('text', caption, content=escape(chart.subtitle)),
    ]


def chart_of(results: Results, workload: str) -> Chart:
    if workload not in dict(WORKLOADS):
        message = f'{workload} is not a charted workload'
        raise ValueError(message)

    workload_series = [item for item in results.series if item.workload == workload]
    series = chart_series(workload_series)
    input_count = len(series[0].throughputs)
    subtitle = f'Throughput in GB/s, geometric mean over {input_count} inputs, higher is better'
    notes = notes_footer(results, series)
    machine = footer_of(results)
    title = dict(WORKLOADS)[workload]

    return Chart(
        footer=[*notes, machine],
        notes=results.notes,
        series=series,
        subtitle=subtitle,
        title=title,
    )


def chart_rows(chart: Chart, theme: Theme) -> list[str]:
    _, axis_max = chart.axis
    scale = BAR_WIDTH_MAX / axis_max
    parts = []

    for index, item in enumerate(chart.series):
        marked = (item.workload, item.implementation) in chart.notes
        name, suffix = label_of(item, marked=marked)
        highlighted = item.implementation == 'json-zig'
        center = PLOT_TOP + index * ROW_PITCH + ROW_PITCH / 2
        right = BAR_LEFT + item.geomean * scale
        value = value_format(item.geomean)
        name_style = {'fill': theme.ink, 'font-weight': 600 if highlighted else 400}
        suffix_style = {'fill': theme.secondary}
        name_tspan = element('tspan', name_style, content=escape(name))
        suffix_tspan = element('tspan', suffix_style, content=escape(suffix))
        tooltip = f'<title>{escape(f"{name}{suffix}: {value} GB/s")}</title>'
        outline = bar_path(left=BAR_LEFT, right=right, top=center - BAR_HEIGHT / 2)

        label = {
            'x': CHART_PADDING + LABEL_WIDTH,
            'y': f'{center:.1f}',
            'dy': '0.35em',
            'font-size': 13,
            'text-anchor': 'end',
            'xml:space': 'preserve',
        }

        bar = {'d': outline, 'fill': theme.accent if highlighted else theme.neutral}

        tip = {
            'x': f'{right + 6:.1f}',
            'y': f'{center:.1f}',
            'dy': '0.35em',
            'fill': theme.secondary,
            'font-size': 12,
            'style': 'font-variant-numeric: tabular-nums',
        }

        label_text = element('text', label, content=name_tspan + suffix_tspan)
        bar_shape = element('path', bar, content=tooltip)
        tip_text = element('text', tip, content=value)

        parts.append(label_text)
        parts.append(bar_shape)
        parts.append(tip_text)

    return parts


def chart_series(series: list[Series]) -> list[Series]:
    if not series:
        message = 'a workload has no series to chart'
        raise ValueError(message)

    groups = collections.defaultdict(list)

    for item in series:
        if item.variant == VARIANT_BASELINE:
            continue

        identity = item.language if item.language == 'C++' else item.variant
        groups[(item.implementation, identity)].append(item)

    best = [max(group, key=lambda entry: entry.geomean) for group in groups.values()]

    return sorted(best, key=lambda entry: entry.geomean, reverse=True)


def chart_svg(chart: Chart, theme: Theme) -> str:
    header = chart_header(chart, theme)
    axis = chart_axis(chart, theme)
    rows = chart_rows(chart, theme)
    footer = chart_footer(chart, theme)
    parts = [*header, *axis, *rows, *footer, '</g>', '</svg>']

    return '\n'.join(parts) + '\n'


def checksums_verify(cells: list[Cell]) -> None:
    if not cells:
        message = 'there are no cells to verify'
        raise ValueError(message)

    groups = collections.defaultdict(set)

    for cell in cells:
        if cell.workload in WORKLOADS_READ:
            groups[(cell.workload, cell.input)].add(cell.checksum)

    disagreements = {key: sorted(found) for key, found in groups.items() if len(found) != 1}

    if disagreements:
        message = f'implementations disagree on what they read: {disagreements}'
        raise RuntimeError(message)


def divisors_of(cells: list[Cell]) -> dict[tuple[str, str], float]:
    if not cells:
        message = 'there are no cells to divide'
        raise ValueError(message)

    lengths = collections.defaultdict(lambda: collections.defaultdict(set))
    divisors = {}

    for cell in cells:
        lengths[(cell.workload, cell.input)][cell.implementation].add(cell.size_bytes)

    for (workload, name), by_implementation in sorted(lengths.items()):
        counts = [sorted(found) for found in by_implementation.values()]
        mixed = [found for found in counts if len(found) != 1]
        values = [found[0] for found in counts]

        if mixed:
            message = f'{workload} {name}: inconsistent sizes {dict(by_implementation)}'
            raise RuntimeError(message)

        if workload in WORKLOADS_READ:
            if len(set(values)) != 1:
                message = f'{workload} {name}: the readers saw different sizes {sorted(values)}'
                raise RuntimeError(message)

        divisors[(workload, name)] = statistics.median(values)

    return divisors


def element(name: str, attributes: dict[str, object], *, content: str) -> str:
    if name not in ELEMENT_NAMES:
        message = f'{name} is not an element the charts draw'
        raise ValueError(message)

    if not attributes:
        message = f'the {name} element has no attributes'
        raise ValueError(message)

    if content.count('<') != content.count('>'):
        message = f'the {name} content is not escaped: {content}'
        raise ValueError(message)

    return f'<{name} {attributes_of(attributes)}>{content}</{name}>'


def element_empty(name: str, attributes: dict[str, object]) -> str:
    if name not in ELEMENT_NAMES:
        message = f'{name} is not an element the charts draw'
        raise ValueError(message)

    if not attributes:
        message = f'the {name} element has no attributes'
        raise ValueError(message)

    return f'<{name} {attributes_of(attributes)}/>'


def footer_of(results: Results) -> str:
    environment = results.environment
    cpu = str(environment['cpu'])

    for noise in CPU_NAME_NOISE:
        cpu = cpu.replace(noise, '')

    tools = environment['tools']
    kernel = str(tools['kernel']).split('-', 1)[0]
    finished = dt.datetime.fromisoformat(str(environment['finished']))
    date = finished.astimezone().date().isoformat()

    return (
        f'{cpu}, one P-core, Linux {kernel}. '
        f'Each value is the median over {environment["round_count"]} rounds of the fastest run '
        f'in each, measured {date}.'
    )


def geomean_of(values: list[float]) -> float:
    if not values:
        message = 'a geometric mean needs at least one value'
        raise ValueError(message)

    if min(values) <= 0:
        message = f'a geometric mean needs positive values: {values}'
        raise ValueError(message)

    return math.exp(statistics.fmean(math.log(value) for value in values))


def label_of(series: Series, *, marked: bool) -> tuple[str, str]:
    key = (series.workload, series.implementation)
    name = dict(LABELS).get(key, series.implementation)
    marker = ' *' if marked else ''

    if series.language == 'Python':
        return name, marker

    if series.language == 'Rust':
        return name, f' (Rust){marker}'

    return name, f' ({series.language}, {series.variant}){marker}'


def markdown_environment(results: Results) -> list[str]:
    environment = results.environment
    tools = environment['tools']
    pinned = f'{environment["cpu_measured"]}, SMT sibling {environment["cpu_sibling"]} watched'
    governor = f'{environment["governor"]}, {environment["energy_performance_preference"]}'
    turbo = dict(TURBO_STATES).get(str(environment['no_turbo']), environment['no_turbo'])
    load_average = f'{environment["load_average_start"]:.2f}'

    pairs = (
        ('CPU', environment['cpu']),
        ('Microcode', environment['microcode']),
        ('Pinned CPU', pinned),
        ('Governor and EPP', governor),
        ('Turbo boost', turbo),
        ('Kernel', tools['kernel']),
        ('Zig', tools['zig']),
        ('GCC', tools['gcc']),
        ('Clang', tools['clang']),
        ('Rust', tools['rustc']),
        ('Python', tools['python']),
        ('json-zig commit', environment['json_zig_commit']),
        ('Modified paths in the working tree', environment['json_zig_modified_paths']),
        ('Load average at start', load_average),
        ('Started (UTC)', environment['started']),
        ('Finished (UTC)', environment['finished']),
    )

    table = [f'| {name} | {value} |' for name, value in pairs]

    return ['## Environment', '', '| Property | Value |', '|---|---|', *table, '']


def markdown_of(results: Results) -> str:
    introduction = (
        'The `chart.py` script generates this file from `results/measurements.csv`. The '
        'throughput is in GB/s (10^9 bytes per second), and higher is better. Each value is the '
        f'median over {results.environment["round_count"]} rounds of the fastest run in that '
        'round. A read divides the input size by the time. A write divides the median output '
        'length across implementations by the time, so every ratio within a column is a ratio of '
        'times. The summary ratio divides the json-zig throughput by the throughput of the '
        'fastest other implementation. An asterisk marks an implementation that accepts invalid '
        'input, and the Validation section lists each outcome.'
    )

    workloads = [line for workload, _ in WORKLOADS for line in markdown_workload(results, workload)]

    lines = [
        '# Benchmark results',
        '',
        introduction,
        '',
        *markdown_summary(results),
        *workloads,
        *markdown_validation(results),
        *markdown_quality(results),
        *markdown_environment(results),
    ]

    return '\n'.join(lines)


def markdown_quality(results: Results) -> list[str]:
    spreads = [cell.spread for cell in results.cells]
    worst = max(results.cells, key=lambda cell: cell.spread)
    ungated = [row for row in results.rows if row['gated'] != 'True']
    retried = [row for row in results.rows if int(row['attempts']) > 1]
    background = [row for row in results.rows if int(row['background_busy']) > 0]
    background_share = f'{len(background)} ({len(background) / len(results.rows):.0%})'
    worst_cell = f'{worst.workload} {worst.input}, {worst.implementation} {worst.variant}'

    pairs = (
        ('Cells', len(results.cells)),
        ('Measurements', len(results.rows)),
        (
            'Median spread of the fastest runs over the rounds, (max - min) / median',
            f'{statistics.median(spreads):.1%}',
        ),
        ('Worst spread of the fastest runs over the rounds', f'{worst.spread:.1%} ({worst_cell})'),
        ('Measurements retried for interference', len(retried)),
        ('Measurements without a quiet attempt', len(ungated)),
        ('Measurements with another CPU at least 50% busy', background_share),
    )

    table = [f'| {name} | {value} |' for name, value in pairs]
    lines = ['## Measurement quality', '', '| Measure | Value |', '|---|---|', *table, '']

    if not ungated:
        return lines

    names = [
        f'- Round {row["round"]}, {row["workload"]} {row["input"]}, {row["implementation"]} '
        f'({row["variant"]}): {row["switches"]} switches, sibling '
        f'{float(row["sibling_busy"]):.1%} busy.'
        for row in ungated
    ]

    explanation = 'Each measurement without a quiet attempt kept its quietest one.'

    return [*lines, explanation, '', *names, '']


def markdown_summary(results: Results) -> list[str]:
    header = '| ' + ' | '.join(SUMMARY_COLUMNS) + ' |'
    lines = ['## Summary', '', header, '|---|---:|---:|---|---:|---:|']

    for workload, title in WORKLOADS:
        workload_series = [item for item in results.series if item.workload == workload]
        chosen = chart_series(workload_series)
        own = [item for item in chosen if item.implementation == 'json-zig']
        others = [item for item in chosen if item.implementation != 'json-zig']
        fast = next(item for item in own if item.variant != 'ReleaseSafe')
        safe = next((item for item in own if item.variant == 'ReleaseSafe'), None)
        other = others[0]
        marked = (other.workload, other.implementation) in results.notes
        name, suffix = label_of(other, marked=marked)
        safe_text = value_format(safe.geomean) if safe else 'n/a'

        line = (
            f'| {title} | {value_format(fast.geomean)} | {safe_text} | {name}{suffix} | '
            f'{value_format(other.geomean)} | {fast.geomean / other.geomean:.2f}x |'
        )

        lines.append(line)

    lines.append('')

    return lines


def markdown_validation(results: Results) -> list[str]:
    case_names = {row['case'] for row in results.validation}
    cases = sorted(case_names)
    outcomes = collections.defaultdict(lambda: collections.defaultdict(set))

    for row in results.validation:
        outcomes[(row['workload'], row['implementation'])][row['case']].add(row['outcome'])

    header = '| Workload | Implementation | ' + ' | '.join(f'`{case}`' for case in cases) + ' |'
    divider = '|---|---|' + '---|' * len(cases)
    lines = ['## Validation', '', header, divider]
    ordered = sorted(outcomes.items(), key=lambda item: (item[0][0], item[0][1].casefold()))

    for (workload, implementation), by_case in ordered:
        key = (workload, implementation)
        name = dict(LABELS).get(key, implementation)
        verdicts = [validation_verdict(by_case[case]) for case in cases]
        line = f'| {workload} | {name} | ' + ' | '.join(verdicts) + ' |'

        lines.append(line)

    lines.append('')

    return lines


def markdown_workload(results: Results, workload: str) -> list[str]:
    if workload not in dict(WORKLOADS):
        message = f'{workload} is not a charted workload'
        raise ValueError(message)

    series = [item for item in results.series if item.workload == workload]

    if not series:
        message = f'there are no {workload} series'
        raise ValueError(message)

    inputs = sorted(series[0].throughputs)
    ranked = sorted(series, key=lambda item: item.geomean, reverse=True)
    best = {name: max(item.throughputs[name] for item in series) for name in inputs}
    geomean_best = max(item.geomean for item in series)
    columns = [name.removesuffix('.json') for name in inputs]
    header = '| Implementation | ' + ' | '.join(columns) + ' | Geomean |'
    divider = '|---|' + '---:|' * (len(inputs) + 1)
    lines = [f'## {dict(WORKLOADS)[workload]}', '', header, divider]

    for item in ranked:
        marked = (item.workload, item.implementation) in results.notes
        name, suffix = label_of(item, marked=marked)
        values = [table_value(value=item.throughputs[key], best=best[key]) for key in inputs]
        geomean = table_value(value=item.geomean, best=geomean_best)
        line = f'| {name}{suffix} | ' + ' | '.join(values) + f' | {geomean} |'

        lines.append(line)

    lines.append('')

    return lines


def notes_footer(results: Results, series: list[Series]) -> list[str]:
    if not series:
        message = 'a chart footer needs the series it describes'
        raise ValueError(message)

    case_names = {row['case'] for row in results.validation}
    lines = []

    for item in series:
        key = (item.workload, item.implementation)

        if key not in results.notes:
            continue

        accepted = results.notes[key]
        name, _ = label_of(item, marked=False)
        cases = ', '.join(accepted)
        line = f'* {name} accepts {len(accepted)} of {len(case_names)} invalid inputs: {cases}.'

        lines.append(line)

    unique = dict.fromkeys(lines)

    return list(unique)


def notes_of(validation: list[dict[str, str]]) -> dict[tuple[str, str], list[str]]:
    if not validation:
        message = 'validation.csv has no rows'
        raise ValueError(message)

    accepted = collections.defaultdict(set)

    for row in validation:
        if row['outcome'] == 'rejected':
            continue

        case = row['case'] if row['outcome'] == 'accepted' else f'{row["case"]} ({row["outcome"]})'
        accepted[(row['workload'], row['implementation'])].add(case)

    return {key: sorted(cases) for key, cases in accepted.items()}


def results_read() -> Results:
    environment_text = (RESULTS / 'environment.json').read_text(encoding='utf-8')
    environment = json.loads(environment_text)
    rows = rows_read(RESULTS / 'measurements.csv')
    validation = rows_read(RESULTS / 'validation.csv')
    cells = cells_aggregate(rows, environment['round_count'])

    checksums_verify(cells)

    divisors = divisors_of(cells)
    notes = notes_of(validation)
    series = series_of(cells, divisors)

    return Results(
        cells=cells,
        environment=environment,
        notes=notes,
        rows=rows,
        series=series,
        validation=validation,
    )


def rows_read(path: pathlib.Path) -> list[dict[str, str]]:
    if not path.is_file():
        message = f'{path} does not exist, run run.py first'
        raise FileNotFoundError(message)

    with path.open(encoding='utf-8', newline='') as handle:
        reader = csv.DictReader(handle)
        rows = list(reader)

    if not rows:
        message = f'{path} has no rows'
        raise ValueError(message)

    return rows


def series_of(cells: list[Cell], divisors: dict[tuple[str, str], float]) -> list[Series]:
    if not all((cell.workload, cell.input) in divisors for cell in cells):
        message = 'a cell has no divisor for its workload and input'
        raise ValueError(message)

    groups = collections.defaultdict(dict)
    inputs = collections.defaultdict(set)
    series = []

    for cell in cells:
        key = (cell.workload, cell.implementation, cell.variant, cell.language)
        groups[key][cell.input] = divisors[(cell.workload, cell.input)] / cell.time_ns
        inputs[cell.workload].add(cell.input)

    for (workload, implementation, variant, language), throughputs in sorted(groups.items()):
        if set(throughputs) != inputs[workload]:
            message = f'{implementation} ({variant}) lacks inputs for {workload}'
            raise RuntimeError(message)

        item = Series(
            workload=workload,
            implementation=implementation,
            variant=variant,
            language=language,
            throughputs=throughputs,
            geomean=geomean_of(list(throughputs.values())),
        )

        series.append(item)

    return series


def table_value(*, value: float, best: float) -> str:
    if not 0 < value <= best:
        message = f'a table value {value} must be positive and at most the best {best}'
        raise ValueError(message)

    text = value_format(value)

    return f'**{text}**' if value == best else text


def tick_format(*, value: float, step: float) -> str:
    if step <= 0:
        message = f'an axis step must be positive: {step}'
        raise ValueError(message)

    if value < 0:
        message = f'an axis tick must not be negative: {value}'
        raise ValueError(message)

    for decimals in range(TICK_DECIMALS_MAX + 1):
        scaled = step * 10**decimals

        if abs(scaled - round(scaled)) < AXIS_TOLERANCE:
            return f'{value:.{decimals}f}'

    message = f'step {step} needs more than {TICK_DECIMALS_MAX} decimals'
    raise ValueError(message)


def validation_verdict(outcomes: set[str]) -> str:
    if not outcomes:
        message = 'a validation case has no outcome'
        raise ValueError(message)

    if not outcomes.issubset(OUTCOMES):
        message = f'unknown validation outcomes: {sorted(outcomes)}'
        raise ValueError(message)

    if outcomes == {'rejected'}:
        return 'rejects'

    if 'crashed' in outcomes:
        return '**crashes**'

    return '**accepts**'


def value_format(value: float) -> str:
    if value <= 0:
        message = f'a throughput must be positive: {value}'
        raise ValueError(message)

    if value >= VALUE_WHOLE_MIN:
        return f'{value:.0f}'

    if value >= VALUE_TENTHS_MIN:
        return f'{value:.1f}'

    return f'{value:.2f}'


if __name__ == '__main__':
    main()
