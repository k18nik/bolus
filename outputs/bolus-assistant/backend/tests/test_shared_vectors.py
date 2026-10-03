"""Shared Python/Swift test vectors.

The fixtures live with the Swift tests (`ios/Tests/BolusCoreTests/Fixtures`) and are
produced by `scripts/generate_shared_vectors.py`. This test proves that the Python
reference still yields exactly the stored values; the Swift test suite checks the same
files against the native port.
"""
import json, math, statistics
from datetime import date, datetime
from pathlib import Path
import pytest
from app.bolus.engine import calculate
from app.iob.engine import AdministeredDose, calculate_iob
from app.analytics.engine import summarize, hourly_profile, daily_breakdown, activity_response

FIXTURES = Path(__file__).resolve().parents[2] / 'ios' / 'Tests' / 'BolusCoreTests' / 'Fixtures'


def load(name):
    return json.loads((FIXTURES / name).read_text(encoding='utf-8'))


def dec(value):
    if isinstance(value, str) and value in ('NaN', 'Infinity', '-Infinity'):
        return float(value.replace('Infinity', 'inf'))
    if isinstance(value, dict):
        return {k: dec(v) for k, v in value.items()}
    if isinstance(value, list):
        return [dec(v) for v in value]
    return value


def same(a, b):
    if isinstance(a, float) and isinstance(b, float) and math.isnan(a) and math.isnan(b):
        return True
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b


def test_golden_cases_are_shared_with_swift():
    swift_copy = (FIXTURES / 'golden_bolus_cases.json').read_bytes()
    assert swift_copy == (Path(__file__).parent / 'golden' / 'bolus_cases.json').read_bytes()


def test_bolus_vectors():
    cases = load('bolus_vectors.json')['cases']
    assert len(cases) > 2000
    for case in cases:
        result = calculate(dec(case['input']), datetime.fromisoformat(case['at']))
        assert same(result, dec(case['expected'])), case['id']


def test_iob_vectors():
    cases = load('iob_vectors.json')['cases']
    assert len(cases) > 600
    for case in cases:
        doses = [AdministeredDose(d['units'], datetime.fromisoformat(d['administered_at']), d['dia_hours'], d['insulin_type'])
                 for d in dec(case['doses'])]
        if case['error']:
            with pytest.raises(ValueError):
                calculate_iob(doses, datetime.fromisoformat(case['at']))
        else:
            assert calculate_iob(doses, datetime.fromisoformat(case['at'])) == case['expected'], case['id']


def test_analytics_vectors():
    cases = load('analytics_vectors.json')['cases']
    for case in cases:
        rows, tz = case['entries'], case['timezone']
        start, end = date.fromisoformat(case['date_from']), date.fromisoformat(case['date_to'])
        days = (end - start).days + 1
        actual = {'metrics': summarize(rows, days, tz), 'hourly': hourly_profile(rows, tz),
                  'daily': daily_breakdown(rows, start, end, tz), 'activity_response': activity_response(rows)}
        assert same(actual, dec(case['expected'])), case['id']


def test_numeric_vectors():
    data = load('numeric_vectors.json')
    for case in data['round']:
        assert round(case['x'], case['n']) == case['expected']
    for case in data['statistics']:
        values = case['values']
        assert statistics.mean(values) == case['mean']
        assert statistics.median(values) == case['median']
        assert statistics.pstdev(values) == case['pstdev']
