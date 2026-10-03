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

В `ios/` добавлен SwiftUI/Xcode-проект с read-only HealthKit и ручной синхронизацией. Инструкция установки и точные ограничения — в [ios/README.md](../ios/README.md). Endpoint `POST /api/imports/healthkit` принимает тренировки с UUID и дневные агрегаты. Он проверяет сессию, CSRF и ожидаемый user_id, обновляет записи атомарно, не создаёт повторных UUID и не затрагивает дозы или профиль.

На телефоне после подготовки показываются сервер, аккаунт и число записей; отправка — отдельной кнопкой. Базовые показатели активности формирует HKStatisticsCollectionQuery; недоступные поля не подменяются нулями. Сводки не суммируются с тренировками в расходе активности.

Для дальнейшей автоматической фоновой синхронизации остаются:

1. HKAnchoredObjectQuery с persisted anchor и обработкой удалённых объектов.
2. Ограниченная долговременная сессия устройства для фоновой доставки.
3. Интеграционные тесты на физическом iPhone. Background delivery — best effort, не обещание постоянной синхронизации.

Проект собран для Simulator и arm64 iPhone без подписи. Нативный интерфейс проверен в Simulator. Подпись Apple Team и проверка реального HealthKit на iPhone остаются установочными шагами; доступ к данным пользователя ещё не выдавался.
