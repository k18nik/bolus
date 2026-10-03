# Apple «Здоровье»: текущая интеграция и следующий шаг

## Сейчас: импорт в веб-приложении

Endpoint: `POST /api/imports/apple-health`, multipart field `file`, авторизованная сессия + CSRF. Принимает `export.xml` или ZIP с единственным `export.xml`. Запись оригинального архива на постоянное хранение не выполняется.

Поток: выбранный пользователем файл → bounded XML parser → Workout/ActivitySummary → стабильный client_id → account-owned Entry → дневник/график/analytics. Никаких соединений импорта с Bolus Engine.

- Время Workout нормализуется в UTC из timezone offset Apple.
- Дедупликация Workout по sourceName + startDate + endDate + workoutActivityType.
- Дневная сводка хранится отдельно как `activity_summary` с привязкой к локальной дате пользователя.
- Повторная сводка той же даты пропускается; изменение уже импортированной сводки пока не синхронизируется.
- Сырые steps и другие Record не суммируются. Для сопоставления нескольких источников нужна отдельная политика reconciliation.
- XML entities запрещены, ZIP не распаковывается на диск, размер/количество записей ограничены.

## Нативное приложение iOS

HealthKit capability предоставляется нативным приложениям; web/PWA не может запросить HealthKit store через браузер. Источники Apple:

- [Configuring HealthKit access](https://developer.apple.com/documentation/xcode/configuring-healthkit-access)
- [Authorizing access to health data](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)

В `ios/` находится нативное local-first приложение с read-only HealthKit и ручной синхронизацией **HealthKit → SwiftData**, без сервера и без интернета. Инструкция установки — в [ios/README.md](../ios/README.md), архитектура — в [LOCAL_FIRST.md](LOCAL_FIRST.md).

Читаются тренировки, шаги, activeEnergyBurned, appleExerciseTime и distanceWalkingRunning; дневные показатели агрегирует HKStatisticsCollectionQuery по локальным дням. Перед сохранением приложение показывает число тренировок и дней. Тренировки сохраняются с UUID HealthKit в `dedupeKey`, дневные сводки — по дате, поэтому повторная синхронизация обновляет записи и не создаёт копий. Недоступные поля не подменяются нулями, сводки не суммируются с тренировками, активность не меняет дозу и IOB. Endpoint `POST /api/imports/healthkit` остаётся только для веб-версии.

Для дальнейшей автоматической фоновой синхронизации остаются:

1. HKAnchoredObjectQuery с persisted anchor и обработкой удалённых объектов.
2. Ограниченная долговременная сессия устройства для фоновой доставки.
3. Интеграционные тесты на физическом iPhone. Background delivery — best effort, не обещание постоянной синхронизации.

Сборка и тесты приложения на симуляторе выполняются в GitHub Actions. Разрешения HealthKit и реальные данные часов проверяются только на физическом iPhone с подписью владельца.
