# TradeSticker — UI/UX Specification

**Status:** Draft for discovery and implementation planning  
**Platform:** macOS  
**Audience:** Claude Code / product designer / macOS engineer  
**Language:** Russian documentation, English symbols/API names

## 1. Цель

Нативное приложение для macOS с независимыми окнами-стикерами для отслеживания логических торговых сделок, курсов валют на нескольких биржах и балансов/истории портфеля.

**Ключевое требование:** визуально это **стикеры на рабочем столе, а не обычные окна macOS**. Никакого стандартного title bar и **никаких трёх traffic-light кнопок** (закрыть/свернуть/развернуть) в левом верхнем углу — даже в состоянии hover. Управление реализуется собственным контекстным меню и необязательными компактными controls.

Стикеры независимы: каждый имеет собственную позицию, размер, режим отображения, выбранные данные и источник. Интерфейс — компактный, информационно плотный, с native macOS feel, Dark/Light theme и без избыточной декоративности.

## 2. Общие правила окна-стикера

### Внешний вид

- Полностью скрыты системный title bar и стандартные кнопки окна.
- Закруглённые углы, лёгкая тень, настраиваемая непрозрачность; вариант с vibrancy/material как **опция**, не обязательное поведение.
- Приложение не рисует псевдо-titlebar с traffic lights.
- Заголовок виджета (например `BTC/USDT`, `Watchlist`, `Portfolio`) — часть **контента**, не системный chrome.
- Незаметная зона для перетаскивания; не перехватывает интерактивные элементы.
- Resize handle в правом нижнем углу может появляться при hover или в режиме редактирования.
- Все основные действия доступны без hover, через правый клик/контекстное меню и/или меню приложения.

### Поведение

- Free positioning и resize; размеры ограничены минимальными размерами layout.
- Опция `Always on Top` **для каждого** окна.
- Опция `Show on All Spaces` **для каждого** окна, насколько это поддерживается macOS.
- Отдельные состояния `locked/unlocked` для защиты от случайного перемещения/resize.
- Сохранение и восстановление: display ID/monitor, frame, layout, theme, opacity, pinned/locked, widget config.
- При отключении монитора окно должно переместиться в видимую область основного дисплея, а не остаться за пределами экрана.
- Учитывать Mission Control, Spaces, full-screen apps, несколько мониторов, sleep/wake, смену разрешения, изменение scaling.
- Независимое закрытие стикера **не завершает приложение**; приложение управляется через Menu Bar.
- Все стикеры можно скрыть/показать из Menu Bar.
- Можно создать несколько стикеров одного типа с разными настройками.
- Обязательны keyboard/accessibility alternatives для drag/resize; поддержать VoiceOver, Dynamic Type где практично, контраст и reduced motion.

### Управление

Контекстное меню стикера:

- `Configure…`
- `Compact / Detailed` либо `Layout…`
- `Lock Position`
- `Always on Top`
- `Show on All Spaces`
- `Opacity…`
- `Duplicate Sticker`
- `Hide Sticker`
- `Close Sticker`

Дополнительные inline-контролы на виджете: `…` для меню, необязательный pin indicator, действия по сделке. Не помещать стандартные window controls.

## 3. Дизайн-система

- Native SwiftUI style с AppKit там, где необходимо управление окнами.
- Небольшие отступы, хорошая читабельность, системные шрифты/macOS typography.
- Positive price/PnL — зелёный; negative — красный; warning/stale — янтарный; неизвестно — нейтральный. Цвет **не единственный** признак: использовать и текст/icon.
- Числа моноширинные (`monospacedDigit`), разумные разделители разрядов, точность по инструменту, выравнивание значений вправо.
- Чётко обозначать валюту измерения (USD, USDT, BTC): не считать USD и USDT эквивалентами без явной политики valuation.
- Контролируемая плотность: `ultraCompact`, `compact`, `detailed`.
- Тема приложения и локальная тема виджета при необходимости.
- Hover может проявлять второстепенные элементы, но не должен быть единственным способом вызвать критически важные действия.
- Все цены/графики на макетах — демонстрационные.

## 4. Тип виджета: Trade — одна логическая сделка на окно

Для каждой сделки собственное окно. **Logical Trade != Exchange Order != Execution/Fill != Balance**. Несколько покупок и частичных продаж могут входить в одну сделку; несколько сделок могут относиться к одной и той же паре.

### Trade v1 — Minimal

- Иконка, `BTC/USDT`, направление, краткая биржа.
- Крупная `Current Price`, цветной `PnL % / PnL amount`.
- Необязательный sparkline; минимум оконного chrome.
- Подходит для постоянного мониторинга многих сделок.

### Trade v2 — Compact (предпочтительный default)

- Всё из Minimal.
- `Avg Entry`, `Target`, `Quantity`, `Unrealized PnL`.
- При необходимости `Buy More`, `Sell Part`, `Close` — в read-only MVP **неактивны/отсутствуют**, не имитировать реальные ордера.

### Trade v3 — Detailed

- Exchange + account + market type + direction + symbol.
- Current price, sparkline, quantity, average entry, target, optional stop, market value.
- Realized PnL, Unrealized PnL, Total PnL, fees, progress/distance to target.
- Кнопки просмотра history, настройки target/alerts.
- Продумать error/loading/stale состояния без перепрыгивания layout.

### Trade v4 — Short / Sell-first

- Явная маркировка семантики: `Futures/Margin SHORT` **или** логическая стратегия `Sell then buy back` на Spot.
- Нельзя смешивать spot sell-first workflow с биржевой short-позицией и заёмными средствами.
- Цена входа, целевая цена выкупа, текущая цена, PnL в корректной модели.

### Trade v5 — Target Progress

- Основной акцент на цели: круговой/линейный индикатор расстояния до target.
- Не изображать progress как гарантированно монотонное движение: рынок может удаляться от цели; выбрать корректную формулу с объяснимыми boundary cases.
- Current price, target, PnL, количество; маленький график по желанию.

### Конфигурируемые поля Trade

`icon`, `symbol`, `exchange`, `account`, `marketType`, `direction`, `currentPrice`, `avgEntry`, `target`, `stopLoss`, `quantity`, `positionValue`, `realizedPnl`, `unrealizedPnl`, `totalPnl`, `pnlPercent`, `fees`, `distanceToTarget`, `sparkline`, `lastUpdate`, `dataStatus`.

## 5. Тип виджета: Watchlist — выбранные пары и биржи

Одна или несколько бирж в **одном** окне. Несколько watchlists с независимыми парами, периодами, колонками и стилями.

### Watchlist v1 — Minimal List

Строка: icon, pair, last price, change %. Подходит для узкого вертикального виджета.

### Watchlist v2 — Custom Table (предпочтительный default)

Настраиваемая таблица: пары, source, price, change, high/low, volume, age/status. Сортировка, изменение порядка/видимости колонок, изменение ширины с сохранением. При узком окне — понятная адаптация (не делать нечитаемую микро-таблицу).

### Watchlist v3 — Card Grid

Каждая пара — компактная карточка с icon/symbol, price, change, небольшим графиком. 1–N колонок в зависимости от размеров окна.

### Watchlist v4 — Sparkline Table

Таблица с выделенной колонкой mini chart и выбираемым периодом (например 1h/24h/7d). Обязательна единая семантика временных окон и timestamps.

### Watchlist v5 — Cross-Exchange

Один инструмент в нескольких источниках: колонки Binance/Poloniex/Bybit, timestamp/age для каждого. Опционально best bid/ask, spread, difference между источниками; сравнивать сопоставимые market types и пары/quote currencies. Не выдавать spread по last-price за исполнимую арбитражную прибыль.

### Watchlist v6 — Custom Layout / Field Presets

UI настройки полей: checkbox/reorder для колонок, presets, precision, сортировка, источники по строкам, фильтры, группы. Все настройки сохраняются отдельно для каждого экземпляра.

### Поля Watchlist

**Идентификация:** `icon`, `displayName`, `symbol`, `base`, `quote`, `exchange`, `marketType`.

**Рынок:** `last`, `bid`, `ask`, `spreadAbsolute`, `spreadPercent`, `change24hPercent`, `change24hAbsolute`, `change7dPercent`, `high24h`, `low24h`, `volume24hBase`, `volume24hQuote`, `sparkline(period)`, `pricePrecision`.

**Данные:** `connectionState`, `freshnessState`, `lastExchangeEventTime`, `lastReceivedAt`, `dataAge`, `latencyEstimate`, `sourceError`.

`volume` всегда должен указывать единицу измерения/тип (base или quote); 24h-high и 24h-low относятся к 24h, не к произвольному периоду sparkline.

### Состояния источника

Разделять **Connection** (`connecting`, `connected`, `reconnecting`, `disconnected`) и **Freshness** (`fresh`, `stale`, `unknown`). При исправном WebSocket цена конкретной пары может устареть. Порог stale должен учитывать источник/тип потока/ликвидность пары. `lastReceivedAt` ≠ exchange event time.

Не прятать проблему: показывать `Stale · 2m ago`, `Reconnecting…`, `Offline`, при этом последнее известное значение можно оставлять помеченным как устаревшее.

## 6. Тип виджета: Portfolio — баланс и история стоимости

Независимая область выбора `exchange/account/all accounts`, валюта оценки (USD/USDT и др.), временной диапазон, расчётная доступность истории.

### Portfolio v1 — Summary

Total portfolio value, изменение за период, компактный график, top assets/распределение, статус обновления. Указывать базу сравнения изменения.

### Portfolio v2 — Assets Table

Asset, amount total/free/locked, current rate, value in valuation currency, share %, optional 24h market change. Источник и аккаунт понятны без дополнительных экранов.

### Portfolio v3 — History (предпочтительный default)

Large historical value chart; time ranges `1D / 1W / 1M / 3M / 1Y / ALL / Custom`. На hover/click — дата, total value, change; snapshot/time sampling. Показать coverage (`History available since …`) и пробелы в данных.

### Portfolio v4 — Analytics

Asset allocation (donut/columns) + historical changes, toggles `Allocation / Performance / History`. Разделить valuation и performance.

### Важные финансовые определения

- `Portfolio Value`: рыночная стоимость находящихся в собственности активов в определённый момент.
- `Portfolio Performance`: результат с корректировкой на external deposits/withdrawals; определить метод (например, time-weighted return) отдельно.
- Deposit/withdrawal/transfer != trading profit. Внутренние переводы между своими аккаунтами не должны создавать ложную прибыль в агрегированном портфеле.
- История прошлой стоимости не всегда полностью восстанавливается через API: snapshots начинаются с момента включения или используются подтверждённые исторические операции + цены. Отображать coverage/uncertainty.
- Поддержка нескольких бирж/аккаунтов подразумевает дедупликацию внутренних переводов и согласованную валюту оценки.

## 7. Управление данными и состояние UI

- Общие stream/subscription services переиспользуются между всеми виджетами. 10 окон с BTC/USDT не должны создавать 10 одинаковых независимых WebSocket-подключений без причины.
- Отдельно настроить cadence получения market data и cadence отрисовки UI.
- loading / empty / reconnecting / stale / permission-denied / unavailable source — обязательные состояния.
- При отсутствии Internet не показывать устаревшие цифры как live.
- На первом этапе **read-only**, никаких торговых API permissions и отправки ордеров.
- Для будущих trade-кнопок обязателен confirm flow, явные комиссии, тип ордера, preview, результаты исполнения и защита от повтора.

## 8. Технические рекомендации (не предрешённая архитектура)

Рассмотреть SwiftUI для контента и AppKit `NSWindow`/`NSPanel` для floating windows. Проверить правильность сочетания `styleMask`, `titleVisibility`, `titlebarAppearsTransparent`, `nonactivatingPanel`, `isMovableByWindowBackground`, `collectionBehavior`, уровней окон, shadow, background/opacity, key/main window и focus. `nonactivatingPanel` нельзя безоговорочно применять к любому NSWindow. Нужен реальный macOS prototype/Spike, не только скриншоты.

Использовать Menu Bar app как контроллер workspace; отдельный `WidgetWindowManager` хранит lifecycle, frames, configs. SwiftUI views должны оставаться тестируемыми независимо от lifecycle окна.

## 9. Acceptance criteria (UI MVP)

1. Создание 5–10 независимых стикеров произвольных типов.
2. Ни в одном стикере **не видны три стандартные кнопки macOS**, включая hover/focus/resize.
3. Нет системной title bar; собственная контентная шапка минимальна или отсутствует.
4. Стикеры можно перемещать и менять в размере, не ломая интерактивные элементы.
5. Lock position, Always on Top и All Spaces имеют ожидаемую семантику и проверены вручную.
6. При рестарте восстанавливаются размеры, позиции, выбранные поля/пары/источники.
7. Работают несколько мониторов, отключение внешнего дисплея, Spaces, Mission Control, sleep/wake.
8. В Watchlist можно создавать несколько экземпляров и менять видимость/порядок колонок.
9. Можно отобразить одну пару с нескольких бирж, не смешивая устаревшие и новые котировки.
10. Видно подключение источника **и отдельно** возраст данных по паре.
11. В Portfolio есть текущая стоимость и исторический график, с честной индикацией периода доступных данных.
12. Демо работает с mock data; интеграция публичного WebSocket Binance — первый отдельный vertical slice.
13. Контраст, keyboard access, формат чисел, accessibility labels проверены.
14. При закрытии одного виджета приложение продолжает работать в Menu Bar.

## 10. Предлагаемый порядок реализации

**Spike A — Desktop window shell:** одно настоящее borderless окно без traffic lights; drag/resize/menu bar/persistence; проверки Spaces + screens.

**Spike B — Multiple windows:** 10 экземпляров, разные configs, lifecycle, restore, lock/on-top.

**Slice C — Watchlist:** таблица с mock data, field selection, layouts, freshness indicators.

**Slice D — Real market stream:** Binance public WebSocket, shared subscriptions, reconnect, update cadence.

**Slice E — Trade:** local logical trade, entry/target/quantity/PnL, mock/test calculation.

**Slice F — Portfolio:** manual/mock balances, value history, coverage indicator; позже account APIs.

## 11. Задача для Claude Code

1. Прочитай этот документ и сформулируй краткое понимание UI.
2. Исследуй официальный macOS API для borderless/window-style floating panels и ограничения; приведи ссылки.
3. Проверь конфликтующие требования (например All Spaces + fullscreen, focus у nonactivating panel, draggable surface + кликабельные таблицы).
4. Предложи 2–3 технических способа реализации window shell и сравни их.
5. Составь минимальный UI implementation plan с проверяемыми milestones; не создавай десятки абстракций заранее.
6. Начни с **Spike A**, только после согласования плана. Сначала mock data, без Binance secrets и реальных ордеров.
7. Сохраняй результат решений в архитектурных документах/ADRs.

**Non-goal:** копировать системный интерфейс Stickies пиксель-в-пиксель; цель — похожая простота, но с собственным компактным финансовым UI.
