import Foundation

// Presentation-only translations for labels previously supplied by the Rust engine.
// Stored quest names, notes, evidence and journal entries stay exactly as entered.
func englishName(_ value: String) -> String {
  guard AppLanguage.current == .english else { return value }
  return englishNames[value] ?? value
}

func englishText(_ value: String) -> String {
  guard AppLanguage.current == .english else { return value }
  if let exact = engineTranslations[value] { return exact }
  var result = value
  for (source, target) in orderedEngineTranslations {
    result = result.replacingOccurrences(of: source, with: target)
  }
  for (source, target) in orderedEngineFragments {
    result = result.replacingOccurrences(of: source, with: target)
  }
  return result
}

extension Skill { var displayTitle: String { englishName(title) } }

private let englishNames = [
  "Основы Rust": "Rust fundamentals", "Архитектура и тесты": "Architecture & testing",
  "Разработка macOS": "macOS development", "Готовое приложение": "Shipping an app",
  "Математика": "Mathematics", "Планирование": "Planning",
  "Посильная активность": "Gentle activity",
  "Режим восстановления": "Recovery routine", "Регулярное питание": "Regular meals",
  "Коммуникация": "Communication",
  "Обучение": "Learning", "Физическая форма": "Physical fitness",
  "Самоорганизация": "Organization",
  "Общение": "Social", "Восстановление": "Recovery", "Дисциплина": "Discipline",
  "Интеллект": "Intellect", "Концентрация": "Concentration", "Социальные навыки": "Social skills",
  "Исследователь": "Explorer",
]

private let engineTranslations: [String: String] = [
  "Укажите от 1 до 12 уникальных пунктов рутины длиной до 100 символов": "Enter 1–12 unique routine items, up to 100 characters each.",
  "Можно отмечать рутину только за сегодняшний день": "Routine checks can only be changed for today. The day may have changed; try again.",
  "Пункт сегодняшней рутины не найден": "This item is not in today's routine.",

  "В строгой сессии можно сохранить только подтверждённое таймером время": "Strict sessions can save only time confirmed by the timer.",
  "В строгом режиме время засчитывается только запущенной сессией":
    "Strict mode records only time from a running camera session.",
  "Квест закрывается после всех запланированных сессий":
    "A quest closes after all of its planned sessions.",
  "Привычка закрепляется от 7 до 365 дней": "A habit takes between 7 and 365 days to establish.",
  "Все выполненные квесты этого навыка уже подтверждены":
    "Every finished quest on this skill is already verified.",
  "Цель должна быть положительной, а вес — больше 0 и не больше 10":
    "The target must be positive, and the weight must be above 0 and at most 10.",
  "Завершите строгую сессию перед импортом данных": "End the strict session before importing data.",
  "Сначала выполните все квесты этого навыка":
    "Complete all quests for this skill before verifying mastery.",
  "Количество сессий должно быть от 1 до 10000": "Planned sessions must be between 1 and 10,000.",
  "Проверьте значения формы": "Check the form values.",
  "Движок не ответил вовремя. Перезапустите ASCEND.": "The local engine timed out. Restart ASCEND.",
  "Ответ движка слишком большой. Перезапустите ASCEND.":
    "The local engine response is too large. Restart ASCEND.",
  "Восстановление в приоритете": "Prioritize recovery",
  "Неделя наблюдения": "Finding your rhythm",
  "Можно обсудить небольшой рост": "Ready for a small step up",
  "Сделайте план легче": "Keep your plan lighter",
  "Сохраните комфортный темп": "Stay with a comfortable pace",
  "Недомогание, мало энергии или высокая усталость. Сократите план; отдых сохраняет весь накопленный прогресс.":
    "Feeling unwell, low energy, or high fatigue. Reduce your plan; your progress is safe while you rest.",
  "Пока мало истории. Начните с комфортного объёма, без автоматического увеличения целей.":
    "Start with a comfortable amount of practice while your history builds. Goals never increase automatically.",
  "Две завершённые недели выше 80%, самочувствие комфортное. Это предложение; цели сами не изменятся.":
    "You completed over 80% in two comfortable weeks. A small increase is optional; your goals will not change on their own.",
  "Выполнение прошлой недели ниже 60%. Снизьте объём или пересмотрите приоритеты.":
    "Last week's completion was below 60%. Consider less work or different priorities.",
  "Доступное время ограничивает план. Недельные приоритеты можно перераспределить при следующем обзоре.":
    "Keep your plan within the time available. Revisit weekly priorities at your next review.",
  "Объект не найден": "This item could not be found.",
  "Сначала выполните зависимости": "Complete the prerequisites first.",
  "Укажите название": "Enter a title.",
  "Подпункт слишком длинный": "A step is too long.",
  "Подпункты не должны повторяться": "Each step can only appear once.",
  "Не больше 24 подпунктов": "A quest can have at most 24 steps.",
  "Квест не может зависеть от самого себя": "A quest cannot depend on itself.",
  "Навык квеста с сохранёнными сессиями менять нельзя":
    "A quest that already has saved sessions keeps its skill.",
  "Проверьте время, сложность и приоритет": "Check the duration, difficulty, and priority.",
  "Квест уже существует": "This quest already exists.",
  "Квест уже закрыт": "This quest is already closed.",
  "Квест уже завершён": "This quest is already completed.",
  "Квест закрыт": "This quest is closed.",
  "Бонус этапа: от 0 до 40 XP; у задач и привычек бонуса нет":
    "Milestone bonuses must be between 0 and 40 XP. Tasks and habits do not have milestone bonuses.",
  "Восстановление учитывается как поддерживающая привычка с фиксированной наградой":
    "Recovery is tracked as a supporting habit with a fixed reward.",
  "Этап с бонусом должен принадлежать одной цепочке проекта":
    "A rewarded milestone must belong to one project chain.",
  "Общий бонус связанных этапов проекта ограничен 40 XP. Распределите его заранее; практика продолжает приносить XP":
    "Linked milestones share a 40 XP bonus budget. Allocate it in advance; practice still earns XP.",
  "Подтвердите результат и время (от 1 секунды до 24 часов)":
    "Confirm an outcome and active time between one second and 24 hours.",
  "Эта привычка уже отмечена сегодня": "This habit has already been logged today.",
  "Привычка уже выполнена сегодня": "This habit is already complete for today.",
  "Привычка отмечается после выполнения. Для частичной практики используйте обычную задачу":
    "Log a habit once it is complete. Use a task to record partial practice.",
  "Переполнение XP": "The XP value is too large.",
  "Выберите от одного до трёх обязательств": "Choose one to three commitments.",
  "План уже принят. Используйте перенос с объяснением":
    "Today's plan is already accepted. Reschedule an item with a reason.",
  "Обязательства не должны повторяться": "Choose each commitment only once.",
  "План принимается до начала выполнения": "Accept the plan before starting the work.",
  "Укажите причину изменения плана": "Add a reason for changing the plan.",
  "Опишите проверенный результат подробнее (от 8 символов)":
    "Describe the verified outcome in at least eight characters.",
  "Этот результат уже подтверждён": "This outcome has already been verified.",
  "Цели прошлых недель зафиксированы": "Goals from previous weeks are locked.",
  "Недельная цель должна начинаться в понедельник": "A weekly goal starts on Monday.",
  "Цель и вес должны быть положительными": "The target and weight must both be positive.",
  "Цель этого навыка уже принята на неделю. Изменения — со следующей недели":
    "This skill already has an accepted goal for the week. Schedule changes for next week.",
  "Укажите имя и время от 5 до 1440 минут":
    "Enter a name and a daily time budget from 5 to 1,440 minutes.",
  "Изображение профиля слишком большое": "The profile photo is too large.",
  "Проверьте настройки профиля": "Check your profile settings.",
  "Описание длиннее 140 символов": "Bio is longer than 140 characters.",
  "Проверьте название и зависимости навыка": "Check the skill name and prerequisites.",
  "Проверьте список приложений и сайтов": "Check the apps and websites for this skill.",
  "Навык удалён:": "Skill deleted:",
  "Введите запись": "Write an entry first.",
  "Завершите занятие с подтверждением результата": "Finish the session and confirm its outcome.",
  "Сначала завершите активную сессию": "Finish the active session first.",
  "Сначала завершите текущее занятие": "Finish your current session first.",
  "Сначала выберите файл": "Choose a file first.",
  "Файл больше 50 МБ": "The file is larger than 50 MB.",
  "Для экспорта JSON выберите файл с расширением .json":
    "Choose a .json file for the JSON export.",
  "Данные изменены другим экземпляром ASCEND. Перезапустите приложение.":
    "Another ASCEND window changed this profile. Restart the app to load the latest data.",
  "Неподдерживаемая версия базы данных": "This database version is not supported.",
  "Движок недоступен. Перезапустите ASCEND.": "The local engine is unavailable. Restart ASCEND.",
  "Соединение с движком закрыто.": "The connection to the local engine was closed.",
  "Не удалось сохранить изменения": "Your changes could not be saved.",
  "Неподдерживаемая версия данных": "This data version is not supported.",
  "Повторяющиеся идентификаторы": "The file contains duplicate identifiers.",
  "Нарушены ссылки или правила квестов": "The file contains invalid quest references or rules.",
  "Обнаружен цикл зависимостей": "The file contains a circular dependency.",
  "Некорректная цепочка бонусов проекта": "The project bonus chain is invalid.",
  "Переполнение бонуса": "The bonus value is too large.",
  "Бюджет бонусов проекта превышен": "The project bonus budget has been exceeded.",
  "Некорректный журнал сессий": "The session history is invalid.",
  "XP не соответствует журналу": "XP totals do not match the session history.",
  "Некорректный план": "The daily plan is invalid.",
  "Некорректные недельные цели": "The weekly goals are invalid.",
  "Некорректное состояние таймера или самочувствия": "The saved timer or check-in is invalid.",
  "Для импорта CSV нужны существующие квесты и навыки с теми же ID":
    "CSV imports require existing quests and skills with matching IDs.",
  "Некорректное значение в CSV": "The CSV contains an invalid value.",
  "Профиль создан": "Profile created", "Самочувствие обновлено": "Check-in updated",
  "Импортированы локальные данные; предыдущая база сохранена":
    "Local data imported; the previous database was backed up.",
]

private let engineFragments = [
  "Рутина обновлена с ": "Routine updated from ",
  "Привычный объём:": "Typical practice:", "мин, доступно:": "min; available:",
  "мин. Правило планирования, не медицинская оценка.":
    "min. A planning estimate, not a medical measurement.",
  "Поддерживающее действие:": "Supporting habit:",
  "Общий предел всех привычек — 4 XP/день, одна отметка привычки в день.":
    "All habits share a 4 XP daily limit. Each habit can be logged once per day.",
  "бонус этапа, не выше XP практики по этому этапу.":
    "milestone bonus, limited to the practice XP earned on it.",
  "Учтено": "Credited",
  " из ": " of ", "мин (лимит 125% оценки).": "min (125% estimate limit).",
  "мин/день": "min per day",
  "0,5 до 300, затем 0,25.": "0.5 up to 300, then 0.25.", "до 180": "up to 180",
  "Создано:": "Created:",
  "Оценка, вес, сложность и бонус зафиксированы.":
    "Estimate, weight, difficulty, and bonus locked.",
  "принято": "accepted", "обязательств": "commitments", "Неделя ": "Week ", " для ": " for ",
  "срок истёк": "the deadline passed",
  "Выполнено": "Completed", "Запланировано": "Planned", "На паузе": "Paused",
  "Отменено": "Cancelled", "Пропущено": "Missed",
  "Нет столбца CSV:": "Missing CSV column:", "Файл:": "File:", "Ошибка:": "Error:",
  " мин": " min", " дней": " days", " занятий": " sessions", " этапов": " milestones",
]

private let orderedEngineTranslations = engineTranslations.sorted { $0.key.count > $1.key.count }
private let orderedEngineFragments = engineFragments.sorted { $0.key.count > $1.key.count }
