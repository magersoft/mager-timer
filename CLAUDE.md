# MagerMotivate

macOS-виджет в menubar: сколько заработано за рабочий день, переработка, перерывы, цели. Swift 6.2+, macOS 26, SwiftPM без Xcode-проекта. Описание для людей — в README.md.

## Команды

```bash
swift test                          # все тесты (только MotivateCore)
swift test --filter DayStartTests   # один набор
./scripts/build-app.sh --install    # собрать .app, положить в ~/Applications, перезапустить
open -n build/MagerMotivate.app --args --data-dir /tmp/motivate-demo --fake-now 2026-10-27T16:55
```

`--install` иногда падает на запуске с `_LSOpenURLsWithCompletionHandler() failed with error -600` — просто повторить.

## Устройство

- `Sources/MotivateCore` — вся логика, без UI и без чтения часов: текущее время всегда приходит параметром `now`. Ключевые файлы:
  - `Engine` — план и фазы дня, деньги;
  - `Tracker` (`DayTracker`) — состояние сегодняшнего дня, закрытие прошлых дней;
  - `Breaks` — перерывы;
  - `Snapshot` (`DaySnapshot`) — готовые строки и действия для меню;
  - `Models`, `Storage`, `WorkCalendar`, `Money`.
- `Sources/MagerMotivate` — SwiftUI-приложение (`MenuBarExtra`, настройки, оверлей перерыва):
  - здесь включено `defaultIsolation(MainActor)`, в ядре — нет;
  - `AppModel.tick()` раз в такт передаёт в трекер время и простой (`ActivityMonitor.idleSeconds()`).
- Новая логика идёт в ядро и покрывается тестами. View только показывает `DaySnapshot` и вызывает действия `AppModel`.

## Соглашения

- Новые поля в сохраняемых моделях (`DayRecord`, `Settings`) читаются через `decodeIfPresent` с разумным значением по умолчанию: старые JSON читаются без миграции.
- Тексты интерфейса и суммы — на русском. Форматирование сумм и времени живёт в `Money` и `Snapshot`, а не во view.
- Отступ 2 пробела. Комментарии редкие и объясняют «почему».

## Тесты

- Swift Testing (`@Test`, `#expect`), имена тестов — фразы в обратных кавычках.
- Хелперы в `Tests/MotivateCoreTests/Support.swift`:
  - время — московское: `at("2026-10-27 13:30")`;
  - календарь — фикстура `isdayoff-2026.txt`;
  - `makeEngine()` даёт ставку ровно 1 700 ₽/ч (октябрь 2026).
- День сам по графику не начинается. Тестам, которые проверяют то, что идёт после начала, нужна запись `started("2026-10-27")` (`at:` меняет время начала).

## Процесс

- Фичи идут через OpenSpec (`openspec/changes/<name>`: proposal, design, specs, tasks), команды `/opsx:propose`, `/opsx:apply`, `/opsx:archive`. Артефакты пишутся на русском.
- `openspec/specs` пока пуст: новые capability описываются только через ADDED Requirements.
- Пункты tasks.md с ручной проверкой отмечаются выполненными только после подтверждения пользователя.
- Сеть — только isdayoff.ru (календарь) и cbr-xml-daily.ru (курсы). Других запросов не добавлять без явного решения.
