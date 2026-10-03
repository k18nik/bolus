"""Generate shared test vectors from the Python reference implementation.

The same JSON files are checked by `tests/test_shared_vectors.py` (Python) and by
`ios/Tests/BolusCoreTests/SharedVectorTests.swift` (Swift). Both sides must
reproduce every expected value exactly.

Run from `backend/`:  python scripts/generate_shared_vectors.py
"""
import json, math, random, statistics, sys, uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.bolus.engine import calculate  # noqa: E402
from app.iob.engine import AdministeredDose, calculate_iob  # noqa: E402
from app.analytics.engine import summarize, hourly_profile, daily_breakdown, activity_response  # noqa: E402

OUT = Path(__file__).resolve().parents[2] / 'ios' / 'Tests' / 'BolusCoreTests' / 'Fixtures'
AT = datetime(2026, 10, 2, 12, tzinfo=timezone.utc)
SEED = 20261003


def enc(value):
    """JSON-safe floats: NaN/Infinity become strings on both sides."""
    if isinstance(value, float) and not math.isfinite(value):
        return 'NaN' if math.isnan(value) else ('Infinity' if value > 0 else '-Infinity')
    if isinstance(value, dict):
        return {k: enc(v) for k, v in value.items()}
    if isinstance(value, list):
        return [enc(v) for v in value]
    return value


def iso(dt):
    return dt.isoformat()


def bolus_vectors(rng):
    base = {'glucose': 10.2, 'unit': 'mmol/L', 'carbs': 62, 'icr': 10, 'isf': 2, 'target': 6, 'correct_above': 7,
            'dia': 4, 'iob': 0.9, 'max_bolus': 15, 'measured_at': iso(AT)}
    cases = []

    def add(name, **changes):
        data = {**base, **changes}
        data = {k: v for k, v in data.items() if v is not ...}
        result = calculate(dict(data), AT)
        cases.append({'id': name, 'at': iso(AT), 'input': enc(data), 'expected': enc(result)})

    # Documented and edge cases.
    add('documented-example')
    for step in (0.1, 0.25, 0.5, 1.0, 2.0):
        add(f'documented-step-{step}', bolus_increment=step)
    add('step-legacy-absent', bolus_increment=...)
    for step in (0.3, 0.0, -1.0, float('nan'), float('inf')):
        add(f'invalid-step-{step}', bolus_increment=step)
    add('glucose-missing', glucose=None)
    add('glucose-nan', glucose=float('nan'))
    add('glucose-low-edge', glucose=3.9, carbs=30)
    add('glucose-below-edge', glucose=3.8999999999999995)
    add('glucose-high-edge', glucose=30.0)
    add('glucose-above-edge', glucose=30.000000000000004)
    add('threshold-exact', glucose=7, carbs=0, iob=0)
    add('threshold-above', glucose=7.000000000000001, carbs=0, iob=0)
    add('target-exact', glucose=6, carbs=0, iob=0)
    add('below-target', glucose=5, carbs=50, iob=0)
    add('iob-covers-all', glucose=10, carbs=0, iob=8)
    add('iob-partial', glucose=12, carbs=45, iob=1.35, bolus_increment=0.5)
    add('max-exceeded', glucose=6, carbs=50.1, iob=0, max_bolus=5)
    add('max-exact', glucose=6, carbs=50, iob=0, max_bolus=5)
    add('stale', measured_at=iso(AT - timedelta(seconds=900, microseconds=1)))
    add('fresh-edge', measured_at=iso(AT - timedelta(seconds=900)))
    add('future', measured_at=iso(AT + timedelta(seconds=60, microseconds=1)))
    add('future-edge', measured_at=iso(AT + timedelta(seconds=60)))
    add('time-invalid', measured_at='invalid')
    add('time-missing', measured_at=None)
    add('unit-mismatch', unit='mg/dL')
    for key in ('carbs', 'icr', 'isf', 'target', 'correct_above', 'dia', 'iob', 'max_bolus'):
        add(f'nan-{key}', **{key: float('nan')})
        add(f'inf-{key}', **{key: float('inf')})
    for key, values in {'icr': (0, -1, 200, 200.1), 'isf': (0, 30, 30.1), 'dia': (1.99, 2, 8, 8.01),
                        'iob': (-0.01, 0, 200, 200.01), 'carbs': (-0.1, 0, 500, 500.1), 'max_bolus': (0, 0.1, 50, 50.1),
                        'target': (3.89, 3.9, 15, 15.01), 'correct_above': (5.99, 30, 30.01)}.items():
        for value in values:
            add(f'bound-{key}-{value}', **{key: value})
    add('thirds', glucose=10, carbs=10, icr=3, isf=6, target=6, correct_above=6, iob=0)
    add('mgdl-converted', glucose=180 / 18, carbs=50, iob=0)
    add('many-blockers', glucose=2, icr=0, isf=0, dia=1, iob=-1, carbs=600, max_bolus=0, target=2, unit='x', measured_at=None)

    # Systematic grid.
    for glucose in (3.9, 5, 6.5, 7, 9.4, 13.7, 22.2, 30):
        for carbs in (0, 12.5, 37.5, 62, 145):
            for icr, isf in ((3, 1.5), (8, 2), (12.5, 3.3)):
                for iob in (0, 0.45, 2.75):
                    for step in (0.1, 0.5, 1.0):
                        add(f'grid-{glucose}-{carbs}-{icr}-{isf}-{iob}-{step}', glucose=glucose, carbs=carbs, icr=icr,
                            isf=isf, iob=iob, bolus_increment=step, max_bolus=25)

    # Random inputs, including blocked ones.
    for index in range(1200):
        data = {
            'glucose': rng.choice([round(rng.uniform(2.5, 32), rng.choice([1, 2])), rng.uniform(3.9, 30), rng.randint(70, 540) / 18]),
            'carbs': rng.choice([0, round(rng.uniform(0, 520), rng.choice([0, 1, 2])), rng.randint(0, 5000) / 10]),
            'icr': rng.choice([round(rng.uniform(0.1, 30), 1), rng.uniform(1, 210), rng.choice([0, -2, 3, 7, 9])]),
            'isf': rng.choice([round(rng.uniform(0.2, 6), 1), rng.uniform(0.1, 32), rng.choice([0, 1.7, 2.2])]),
            'target': rng.choice([round(rng.uniform(3.5, 9), 1), rng.choice([5, 5.5, 6, 6.5, 16])]),
            'dia': rng.choice([3, 3.5, 4, 4.5, 5, 6, 8, 1.5, 9]),
            'iob': rng.choice([0, round(rng.uniform(0, 12), 2), rng.uniform(0, 210)]),
            'max_bolus': rng.choice([5, 10, 15, 25, 50, round(rng.uniform(0.1, 55), 1)]),
        }
        data['correct_above'] = rng.choice([data['target'], data['target'] + rng.choice([0, 0.5, 1, 2.3]), 31, data['target'] - 1])
        data['measured_at'] = iso(AT - timedelta(seconds=rng.choice([0, 30, 300, 899, 900, 901, -59, -61, 3600]),
                                                 microseconds=rng.choice([0, 0, 1, 250000, 999999])))
        if rng.random() < 0.8:
            data['bolus_increment'] = rng.choice([0.1, 0.25, 0.5, 1.0, 2.0, 0.3])
        result = calculate({**base, **data, 'unit': 'mmol/L'}, AT)
        cases.append({'id': f'random-{index:04d}', 'at': iso(AT), 'input': enc({**base, **data, 'unit': 'mmol/L'}), 'expected': enc(result)})
    return cases


def iob_vectors(rng):
    cases = []
    model_errors = 0

    def add(name, doses, at=AT):
        objects = [AdministeredDose(d['units'], datetime.fromisoformat(d['administered_at']), d['dia_hours'], d['insulin_type']) for d in doses]
        try:
            expected = calculate_iob(objects, at)
            error = None
        except ValueError as exc:
            expected, error = None, str(exc)
        cases.append({'id': name, 'at': iso(at), 'doses': enc(doses), 'expected': enc(expected), 'error': error})

    def dose(units, offset_seconds, dia, kind='rapid', micro=0):
        return {'units': units, 'administered_at': iso(AT - timedelta(seconds=offset_seconds, microseconds=micro)),
                'dia_hours': dia, 'insulin_type': kind}

    add('empty', [])
    add('reference', [dose(4, 7200, 4), dose(2, 3600, 4), dose(20, 0, 4, 'basal')])
    add('just-now', [dose(3, 0, 4)])
    add('future-dose', [dose(3, -600, 4)])
    add('half-life', [dose(5, 7200, 4)])
    add('expired', [dose(5, 14400, 4)])
    add('dia-saved-at-injection', [dose(4, 10800, 3), dose(4, 10800, 6)])
    add('invalid-dia', [dose(1, 600, 1.5)])
    add('invalid-dia-high', [dose(1, 600, 8.5)])
    add('basal-with-invalid-dia-is-skipped', [dose(10, 600, 0, 'basal')])
    add('negative-units', [dose(-1, 600, 4)])
    add('nan-units', [dose(float('nan'), 600, 4)])
    add('micro-offsets', [dose(1.3, 5400, 4.5, micro=123457), dose(2.7, 600, 3.5, micro=999999)])
    for index in range(600):
        doses = []
        for _ in range(rng.randint(1, 7)):
            doses.append(dose(rng.choice([round(rng.uniform(0.1, 15), rng.choice([1, 2])), rng.choice([1, 2, 3.5, 0.25]), 0]),
                              rng.choice([rng.randint(-3600, 36000), rng.randint(0, 28800)]),
                              rng.choice([2, 2.5, 3, 3.5, 4, 4.5, 5, 6, 7, 8]),
                              'basal' if rng.random() < 0.15 else 'rapid', micro=rng.choice([0, 0, rng.randint(0, 999999)])))
        add(f'random-{index:04d}', doses)
    return cases


def analytics_vectors(rng):
    cases = []
    zones = ['Europe/Moscow', 'UTC', 'America/New_York', 'Asia/Vladivostok']
    for index in range(80):
        tz = rng.choice(zones)
        days = rng.choice([1, 3, 7, 14])
        date_to = (AT - timedelta(days=rng.randint(0, 2))).date()
        date_from = date_to - timedelta(days=days - 1)
        start = datetime.combine(date_from, datetime.min.time(), timezone.utc) - timedelta(hours=14)
        span = (days + 1) * 86400
        entries = []
        kinds = ['glucose'] * 6 + ['insulin'] * 2 + ['meal', 'activity', 'note']
        for n in range(rng.randint(0 if index < 4 else 5, 160)):
            kind = rng.choice(kinds)
            at = start + timedelta(seconds=rng.randint(0, span), microseconds=rng.choice([0, rng.randint(0, 999999)]))
            if kind == 'glucose':
                data = {'value_mmol': rng.choice([round(rng.uniform(2.2, 24), 1), rng.randint(40, 430) / 18, rng.choice([3.9, 10, 10.0, 3.8, 10.1])])}
            elif kind == 'insulin':
                basal = rng.random() < 0.3
                data = {'units': rng.choice([1, 2, 0.5, round(rng.uniform(0.5, 24), 1)]), 'insulin_type': 'basal' if basal else 'rapid',
                        'purpose': 'basal' if basal else rng.choice(['meal', 'correction', 'meal_and_correction', 'manual'])}
            elif kind == 'meal':
                data = {'total_carbs': round(rng.uniform(0, 120), rng.choice([0, 1, 4])), 'total_calories': round(rng.uniform(0, 900), rng.choice([0, 2]))}
            elif kind == 'activity':
                data = {'name': rng.choice(['Ходьба', 'Бег', 'Йога']), 'duration_minutes': rng.choice([20, 45, 61, round(rng.uniform(5, 120), 1)]),
                        'source': rng.choice(['manual', 'apple_health'])}
            else:
                data = {'note': 'note'}
            entries.append({'id': str(uuid.UUID(int=rng.getrandbits(128))), 'kind': kind, 'occurred_at': iso(at), 'data': data})
        entries.sort(key=lambda e: e['occurred_at'])
        zone_start = datetime.combine(date_from, datetime.min.time(), ZoneInfo(tz))
        zone_end = datetime.combine(date_to + timedelta(days=1), datetime.min.time(), ZoneInfo(tz))
        rows = [e for e in entries if zone_start <= datetime.fromisoformat(e['occurred_at']) < zone_end]
        cases.append({
            'id': f'analytics-{index:03d}', 'timezone': tz, 'date_from': date_from.isoformat(), 'date_to': date_to.isoformat(),
            'entries': rows,
            'expected': enc({'metrics': summarize(rows, days, tz), 'hourly': hourly_profile(rows, tz),
                             'daily': daily_breakdown(rows, date_from, date_to, tz), 'activity_response': activity_response(rows)}),
        })
    return cases


def numeric_vectors(rng):
    rounds, stats = [], []
    specials = [0.125, 0.375, 2.675, 6.125, 1.005, 0.5, 2.5, 1 / 3, 2 / 3, 26.450000000000003, 8.816666666666666]
    for _ in range(400):
        x = rng.choice([rng.uniform(0, 1000), round(rng.uniform(0, 30), 3), rng.choice(specials), rng.randint(0, 9000) / rng.choice([3, 7, 18, 1000])])
        n = rng.choice([0, 1, 2, 3, 4])
        rounds.append({'x': x, 'n': n, 'expected': round(x, n)})
    for _ in range(150):
        values = [rng.choice([round(rng.uniform(2, 25), 1), rng.randint(36, 450) / 18, rng.uniform(0, 30)]) for _ in range(rng.choice([1, 2, 3, 7, 40, 150]))]
        stats.append({'values': values, 'mean': statistics.mean(values), 'median': statistics.median(values), 'pstdev': statistics.pstdev(values)})
    return {'round': rounds, 'statistics': stats}


def write(name, payload):
    """Compact JSON with one list item per line (readable diffs, small files)."""
    def dump(value):
        return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(',', ':'))
    parts = []
    for key, value in payload.items():
        if isinstance(value, list):
            items = ',\n'.join(dump(item) for item in value)
            parts.append(dump(key) + ':[\n' + items + '\n]')
        else:
            parts.append(dump(key) + ':' + dump(value))
    path = OUT / name
    path.write_text('{' + ',\n'.join(parts) + '}\n', encoding='utf-8')
    return path


def main():
    rng = random.Random(SEED)
    OUT.mkdir(parents=True, exist_ok=True)
    meta = {'generator': 'backend/scripts/generate_shared_vectors.py', 'seed': SEED}
    print(write('bolus_vectors.json', {**meta, 'cases': bolus_vectors(rng)}))
    print(write('iob_vectors.json', {**meta, 'cases': iob_vectors(rng)}))
    print(write('analytics_vectors.json', {**meta, 'cases': analytics_vectors(rng)}))
    print(write('numeric_vectors.json', {**meta, **numeric_vectors(rng)}))


if __name__ == '__main__':
    main()
