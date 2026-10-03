"""Produce a real server JSON backup (`schema_version: 1.0`) for the iOS migration tests.

The account is synthetic. Run from `backend/`:
    python scripts/generate_legacy_backup_fixture.py
"""
import json, os, sys, tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

root = Path(tempfile.mkdtemp(prefix='bolus-fixture-'))
os.environ.update({'DATABASE_URL': 'sqlite:///' + str(root / 'fixture.db'), 'REPORT_DIR': str(root / 'reports'),
                   'TASK_ALWAYS_EAGER': 'true', 'REDIS_URL': '', 'DEMO_ENABLED': 'false', 'CLINICAL_USE_ENABLED': 'true',
                   'FEATURE_AI': 'true', 'YAZIO_ENABLED': 'false', 'USDA_API_KEY': '',
                   'APP_ENCRYPTION_KEY': 'Zm9yLXRlc3RzLW9ubHktbm90LWEtcmVhbC1rZXktMDA='})
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import httpx  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from app.db import Base, engine  # noqa: E402
from app.main import app  # noqa: E402
from app.ai import service  # noqa: E402

OUT = Path(__file__).resolve().parents[2] / 'ios' / 'Tests' / 'BolusCoreTests' / 'Fixtures' / 'legacy_server_backup.json'


def main():
    Base.metadata.create_all(engine)
    now = datetime.now(timezone.utc)
    iso = lambda dt: dt.isoformat()
    with TestClient(app) as client:
        assert client.post('/api/auth/register', json={'email': 'legacy@example.com', 'password': 'legacy-fixture-password', 'name': 'Мария'}).status_code == 201
        client.headers['x-csrf-token'] = client.cookies['csrf']
        segments = [{'start_time': '00:00', 'end_time': '12:00', 'icr': 10, 'isf': 2, 'target': 6, 'correct_above': 7},
                    {'start_time': '12:00', 'end_time': '24:00', 'icr': 12, 'isf': 2.5, 'target': 6, 'correct_above': 7.5}]
        profile = {'rapid_insulin_name': 'Фиасп', 'basal_insulin_name': 'Тресиба', 'bolus_increment': 0.5, 'basal_increment': 1,
                   'max_bolus': 15, 'insulin_action_duration': 4, 'confirmed': True, 'segments': segments}
        assert client.put('/api/profile', json=profile).status_code == 200
        profile['bolus_increment'] = 1
        assert client.put('/api/profile', json=profile).status_code == 200
        assert client.post('/api/glucose', json={'value': 7.4, 'measured_at': iso(now - timedelta(minutes=3)), 'client_id': 'g1'}).status_code == 201
        assert client.post('/api/glucose', json={'value': 162, 'unit': 'mg/dL', 'measured_at': iso(now - timedelta(hours=5)), 'client_id': 'g2'}).status_code == 201
        cola = {'name_snapshot': 'Кола', 'food_source': 'yazio', 'food_id': 'catalog-1', 'grams': None, 'amount': 250, 'unit': 'ml',
                'carbs': 26.450000000000003, 'protein': 0, 'fat': 0, 'calories': 102.5, 'fiber': None, 'sugar': None}
        pasta = {'name_snapshot': 'Макароны', 'food_source': 'custom', 'food_id': '', 'grams': 180, 'amount': 180, 'unit': 'g',
                 'carbs': 55.548, 'protein': 10.4, 'fat': 1.6, 'calories': 284.4, 'fiber': 3.2, 'sugar': 1.1}
        meal = client.post('/api/meals', json={'name': 'Обед', 'meal_type': 'lunch', 'eaten_at': iso(now - timedelta(minutes=2)),
                                               'items': [pasta, cola], 'client_id': 'm1'}).json()
        assert client.post('/api/insulin', json={'units': 14, 'insulin_type': 'basal', 'purpose': 'basal',
                                                 'administered_at': iso(now - timedelta(hours=10)), 'client_id': 'b1'}).status_code == 201
        assert client.post('/api/activity', json={'name': 'Ходьба', 'duration_minutes': 40, 'occurred_at': iso(now - timedelta(hours=4)),
                                                  'client_id': 'a1'}).status_code == 201
        assert client.post('/api/notes', json={'note': '=формула не исполняется', 'occurred_at': iso(now - timedelta(hours=1)), 'client_id': 'n1'}).status_code == 201
        calc = client.post('/api/bolus/calculate', json={'glucose': 7.4, 'carbs': 0, 'timestamp': iso(datetime.now(timezone.utc)),
                                                         'measured_at': iso(now - timedelta(minutes=3)), 'meal_id': meal['id']}).json()
        assert calc['calculation_status'] == 'ok', calc
        assert client.post(f"/api/bolus/{calc['calculation_id']}/confirm", json={'actual_units': calc['recommended_bolus'],
                                                                                  'administered_at': iso(datetime.now(timezone.utc))}).status_code == 200
        blocked = client.post('/api/bolus/calculate', json={'glucose': 7.4, 'carbs': 20, 'timestamp': iso(datetime.now(timezone.utc)),
                                                           'measured_at': iso(now - timedelta(hours=2))}).json()
        assert blocked['calculation_status'] == 'blocked'
        user_id = client.get('/api/users/me').json()['id']
        sync = {'expected_user_id': user_id, 'timezone': 'Europe/Moscow',
                'workouts': [{'id': '8f4c3a5e-1b2d-4c6e-9f00-112233445566', 'name': 'Бег', 'source_name': 'Apple Watch',
                              'started_at': iso(now - timedelta(hours=3)), 'ended_at': iso(now - timedelta(hours=2, minutes=25)),
                              'duration_minutes': 35, 'active_energy': 310, 'distance_km': 5.2}],
                'days': [{'date': (now - timedelta(days=1)).date().isoformat(), 'steps': 8412, 'exercise_minutes': 41}]}
        assert client.post('/api/imports/healthkit', json=sync).status_code == 200
        start = (now - timedelta(days=10)).date().isoformat()
        assert client.post('/api/cycle', json={'start_date': start, 'cycle_length': 29}).status_code == 201
        food = client.post('/api/foods/custom', json={'name': 'Сырник домашний', 'brand': '', 'serving_name': '1 шт', 'serving_weight': 60,
                                                      'carbs': 14.2, 'protein': 9, 'fat': 6, 'calories': 150, 'fiber': None, 'sugar': 4}).json()
        assert client.post('/api/foods/favorites', json={'external_id': food['id'], 'provider': 'custom', 'name': food['name'],
                                                          'brand': '', 'serving_name': '1 шт', 'serving_weight': 60, 'carbs': 14.2,
                                                          'protein': 9, 'fat': 6, 'calories': 150, 'fiber': None, 'sugar': 4}).status_code == 201
        assert client.post('/api/foods/favorites', json={'external_id': 'catalog-1', 'provider': 'yazio', 'name': 'Кола', 'brand': 'Coca Cola',
                                                          'serving_name': '100 мл', 'serving_weight': 100, 'base_unit': 'ml', 'carbs': 10.58,
                                                          'protein': 0, 'fat': 0, 'calories': 41, 'fiber': None, 'sugar': None}).status_code == 201
        assert client.post('/api/recipes', json={'name': 'Паста с колой', 'ingredients': [pasta, cola], 'cooked_weight': 430, 'servings': 2}).status_code == 201
        assert client.put('/api/ai/settings', json={'api_key': 'sk-fixture-not-a-real-key-123456', 'consent': True, 'model': 'gpt-4.1-mini'}).status_code == 200
        insight = {'summary': 'Наблюдений пока мало.', 'observations': ['Глюкоза записана дважды.'], 'possible_explanations': [],
                   'questions': ['Есть ли измерения после тренировки?'], 'safety_flags': ['Ручные измерения не отражают весь день.']}
        body = {'status': 'completed', 'output': [{'type': 'message', 'content': [{'type': 'output_text', 'text': json.dumps(insight, ensure_ascii=False)}]}],
                'usage': {'input_tokens': 111, 'output_tokens': 42, 'total_tokens': 153}}
        original = httpx.AsyncClient
        service.httpx.AsyncClient = lambda **kw: original(transport=httpx.MockTransport(lambda request: httpx.Response(200, json=body)), **kw)
        try:
            assert client.post('/api/ai/chat', json={'question': 'Объясни расчёт', 'days': 14, 'calculation_id': calc['calculation_id']}).status_code == 200
        finally:
            service.httpx.AsyncClient = original
        today = datetime.now(timezone.utc).date()
        job = client.post('/api/reports', json={'type': 'doctor', 'format': 'json', 'date_from': str(today - timedelta(days=6)), 'date_to': str(today)}).json()
        content = client.get(f"/api/reports/{job['id']}/download").content
    data = json.loads(content)
    assert data['schema_version'] == '1.0' and 'password_hash' not in content.decode() and 'sk-fixture' not in content.decode()
    OUT.write_text(json.dumps(data, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print(OUT, len(data['entries']), 'entries')


if __name__ == '__main__':
    main()
