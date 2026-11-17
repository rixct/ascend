//! Builds a filled local profile for manual checks. Not part of the normal test run:
//! `cargo test -p ascend-core --test sample_profile -- --ignored`
use ascend_core::*;
use chrono::{Duration, NaiveDate, Utc};
use std::path::PathBuf;

#[test]
#[ignore]
fn write_sample_profile() {
    let today = chrono::Local::now().date_naive();
    let state = sample(today);
    state.validate().expect("sample profile");
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/sample-profile.json");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, serde_json::to_vec_pretty(&state).unwrap()).unwrap();
    eprintln!("wrote {}", path.display());
}

fn sample(today: NaiveDate) -> GameState {
    let mut state = GameState::default();
    state.settings.name = "Тестовый профиль".into();
    state.settings.bio = "Профиль для ручной проверки экранов.".into();
    state.settings.onboarded = true;
    state.settings.daily_minutes = 90;
    state.settings.growth_percent = 10;
    state.settings.strict_mode = false;

    let basics = state.add_skill("Основы".into(), Domain::Mind, vec![]);
    let english = state.add_skill("Английский".into(), Domain::Mind, vec![basics]);
    state.add_skill("Архитектура".into(), Domain::Mind, vec![english]);
    let body = state.add_skill("Тело".into(), Domain::Body, vec![]);
    let order = state.add_skill("Порядок".into(), Domain::Organization, vec![]);
    let social = state.add_skill("Общение".into(), Domain::Social, vec![]);
    let recovery = state.add_skill("Сон".into(), Domain::Recovery, vec![]);
    state
        .skills
        .iter_mut()
        .find(|skill| skill.id == english)
        .unwrap()
        .description = "Чтение, времена и разговор.".into();

    let first = quest(
        &mut state,
        basics,
        "Первая глава",
        QuestKind::Daily,
        1,
        25,
        1.0,
        2,
        0,
    );
    let reading = quest(
        &mut state,
        english,
        "Читать 15 минут",
        QuestKind::Habit,
        30,
        15,
        1.0,
        3,
        0,
    );
    let tenses = quest(
        &mut state,
        english,
        "Все времена",
        QuestKind::Daily,
        12,
        25,
        1.0,
        2,
        0,
    );
    let retell = quest(
        &mut state,
        english,
        "Пересказ главы",
        QuestKind::Daily,
        3,
        20,
        1.5,
        2,
        0,
    );
    let talk = dependent(
        &mut state,
        english,
        "Свободный разговор",
        QuestKind::Daily,
        4,
        25,
        1.0,
        3,
        0,
        vec![retell],
    );
    dependent(
        &mut state,
        english,
        "Продвинутый разговор",
        QuestKind::Daily,
        4,
        25,
        1.5,
        2,
        0,
        vec![talk],
    );
    let book = steps_quest(&mut state, english);
    let story = quest(
        &mut state,
        english,
        "Короткий рассказ",
        QuestKind::Project,
        3,
        30,
        1.0,
        2,
        8_000,
    );
    let essay = quest(
        &mut state,
        english,
        "Черновик эссе",
        QuestKind::Daily,
        2,
        30,
        1.0,
        1,
        0,
    );
    let dropped = quest(
        &mut state,
        english,
        "Старый план",
        QuestKind::Daily,
        2,
        20,
        0.5,
        1,
        0,
    );
    let expired = quest(
        &mut state,
        english,
        "Глава к сроку",
        QuestKind::Daily,
        2,
        25,
        1.0,
        2,
        0,
    );
    state
        .quests
        .iter_mut()
        .find(|quest| quest.id == expired)
        .unwrap()
        .deadline = Some(today - Duration::days(1));
    let workout = quest(
        &mut state,
        body,
        "Зарядка",
        QuestKind::Habit,
        21,
        20,
        1.0,
        2,
        0,
    );
    let week = quest(
        &mut state,
        order,
        "Разобрать неделю",
        QuestKind::Daily,
        4,
        30,
        1.0,
        2,
        0,
    );
    let conversation = quest(
        &mut state,
        social,
        "Разговор 10 минут",
        QuestKind::Habit,
        14,
        10,
        1.0,
        2,
        0,
    );
    let sleep = quest(
        &mut state,
        recovery,
        "Сон в одно время",
        QuestKind::Habit,
        14,
        10,
        1.0,
        3,
        0,
    );

    state
        .set_quest_status(essay, Status::Paused)
        .expect("pause");
    state
        .set_quest_status(dropped, Status::Cancelled)
        .expect("cancel");
    sit(&mut state, first, today - Duration::days(20), 25, true);
    state
        .verify_mastery(basics, "Первая глава прочитана и пересказана.".into())
        .expect("mastery");

    state
        .commit_plan(today, &[reading, tenses, book])
        .expect("today plan");
    let earlier = today - Duration::days(6);
    state
        .commit_plan(earlier, &[reading, sleep, week])
        .expect("earlier plan");
    state
        .excuse(earlier, Some(week), "Не хватило вечера".into())
        .expect("excuse");
    state
        .excuse(today - Duration::days(11), None, "День без плана".into())
        .expect("rest");

    for ago in 1..=12 {
        sit(&mut state, reading, today - Duration::days(ago), 15, true);
    }
    for ago in 0..=8 {
        sit(&mut state, workout, today - Duration::days(ago), 20, true);
    }
    for ago in 2..=9 {
        sit(&mut state, sleep, today - Duration::days(ago), 10, true);
    }
    for ago in 1..=6 {
        sit(
            &mut state,
            conversation,
            today - Duration::days(ago),
            10,
            true,
        );
    }
    for ago in [2, 4, 7, 9] {
        sit(&mut state, tenses, today - Duration::days(ago), 25, false);
    }
    for ago in [1, 2, 3, 4, 6, 8, 10, 11] {
        sit(&mut state, book, today - Duration::days(ago), 45, false);
    }
    sit(&mut state, story, today - Duration::days(14), 30, false);
    sit(&mut state, story, today - Duration::days(13), 30, false);
    sit(&mut state, story, today - Duration::days(12), 30, true);
    sit(&mut state, retell, today - Duration::days(10), 20, false);
    sit(&mut state, retell, today - Duration::days(9), 20, false);
    sit(&mut state, retell, today - Duration::days(8), 20, true);
    sit(&mut state, week, today - Duration::days(5), 30, false);
    sit(&mut state, week, today - Duration::days(3), 30, false);

    state.settle_deadlines(today);

    state
        .set_routine(
            vec![
                "Вода".into(),
                "Зарядка".into(),
                "Чтение".into(),
                "Сон".into(),
                "Разобрать стол".into(),
                "Час без телефона".into(),
            ],
            true,
            today - Duration::days(20),
        )
        .expect("routine");
    let items: Vec<Id> = state
        .routine_on(today)
        .unwrap()
        .items
        .iter()
        .map(|item| item.id)
        .collect();
    for ago in 1..=14 {
        let day = today - Duration::days(ago);
        let completed: Vec<Id> = items
            .iter()
            .enumerate()
            .filter(|(index, _)| !(ago as usize + index).is_multiple_of(3))
            .map(|(_, id)| *id)
            .collect();
        state.routine_days.push(RoutineDay { day, completed });
    }
    state.routine_days.sort_by_key(|record| record.day);
    for id in items.iter().take(2) {
        state
            .set_routine_item(today, today, *id, true)
            .expect("today check");
    }

    for ago in 0..14 {
        let day = today - Duration::days(ago);
        state.checkins.push(CheckIn {
            day,
            energy: 70 - (ago as u8 % 5) * 8,
            fatigue: 20 + (ago as u8 % 4) * 10,
            focus: 60 + (ago as u8 % 3) * 10,
            available_minutes: 90,
            unwell: ago == 11,
        });
    }
    for (ago, text) in [
        (
            1,
            "Прочитал главу про настоящее совершённое и записал примеры.",
        ),
        (3, "Зарядка далась легче, чем на прошлой неделе."),
        (6, "Вечер ушёл на пересказ, разговор отложил."),
        (9, "Танебаум: глава про систему команд."),
        (12, "Короткий рассказ закончен, без лишних правок."),
    ] {
        state.journal.push(JournalEntry {
            id: Id::new_v4(),
            day: today - Duration::days(ago),
            text: text.into(),
        });
    }

    state
        .set_target(
            WeeklyTarget {
                id: Id::new_v4(),
                week: GameState::week(today),
                skill_id: english,
                target: 180.0,
                weight: 2.0,
                unit: TargetUnit::Minutes,
            },
            today,
        )
        .expect("target");
    state
        .set_target(
            WeeklyTarget {
                id: Id::new_v4(),
                week: GameState::week(today),
                skill_id: body,
                target: 4.0,
                weight: 1.0,
                unit: TargetUnit::Sessions,
            },
            today,
        )
        .expect("target");
    state.targets.push(WeeklyTarget {
        id: Id::new_v4(),
        week: GameState::week(today) - Duration::days(7),
        skill_id: english,
        target: 120.0,
        weight: 1.5,
        unit: TargetUnit::Minutes,
    });
    state
}

#[allow(clippy::too_many_arguments)]
fn quest(
    state: &mut GameState,
    skill: Id,
    title: &str,
    kind: QuestKind,
    sessions: u32,
    minutes: u32,
    difficulty: f64,
    priority: u8,
    bonus: u64,
) -> Id {
    dependent(
        state,
        skill,
        title,
        kind,
        sessions,
        minutes,
        difficulty,
        priority,
        bonus,
        vec![],
    )
}

#[allow(clippy::too_many_arguments)]
fn dependent(
    state: &mut GameState,
    skill: Id,
    title: &str,
    kind: QuestKind,
    sessions: u32,
    minutes: u32,
    difficulty: f64,
    priority: u8,
    bonus: u64,
    dependencies: Vec<Id>,
) -> Id {
    let id = Id::new_v4();
    state
        .create_quest(Quest {
            id,
            title: title.into(),
            outcome: format!("Практика: {title}"),
            skill_id: skill,
            kind,
            priority,
            estimate_minutes: minutes,
            planned_sessions: sessions,
            difficulty,
            bonus_milli: bonus,
            deadline: None,
            dependencies,
            steps: vec![],
            status: Status::Planned,
            created_at: Utc::now(),
        })
        .unwrap_or_else(|error| panic!("{title}: {error}"));
    id
}

fn steps_quest(state: &mut GameState, skill: Id) -> Id {
    let id = Id::new_v4();
    let titles = [
        "Структура компьютера",
        "Цифровая логика",
        "Микроархитектура",
        "Набор команд",
        "Операционная система",
        "Ассемблер",
        "Параллельные системы",
        "Заключение",
    ];
    state
        .create_quest(Quest {
            id,
            title: "Танебаум".into(),
            outcome: "Прочитана «Архитектура компьютера»".into(),
            skill_id: skill,
            kind: QuestKind::Project,
            priority: 3,
            estimate_minutes: 45,
            planned_sessions: 12,
            difficulty: 1.5,
            bonus_milli: 20_000,
            deadline: None,
            dependencies: vec![],
            steps: titles
                .into_iter()
                .enumerate()
                .map(|(index, title)| QuestStep {
                    id: Id::new_v4(),
                    title: title.into(),
                    done: index < 3,
                })
                .collect(),
            status: Status::Planned,
            created_at: Utc::now(),
        })
        .expect("book");
    id
}

fn sit(state: &mut GameState, quest: Id, day: NaiveDate, minutes: u32, finish: bool) {
    state
        .complete(Completion {
            id: Id::new_v4(),
            quest_id: quest,
            seconds: minutes * 60,
            result: "Сессия записана для проверки".into(),
            finish_quest: finish,
            day,
            at: day.and_hms_opt(15, 0, 0).unwrap().and_utc(),
            utc_offset_seconds: 10_800,
        })
        .unwrap_or_else(|error| panic!("{day} {minutes}m: {error}"));
}
