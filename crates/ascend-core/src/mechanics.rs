use crate::*;
use chrono::{Duration, NaiveDate, Utc};

fn day() -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 11, 15).unwrap()
}
fn setup() -> GameState {
    let mut state = GameState::default();
    state.starter_skills();
    state
}
fn quest(state: &GameState, kind: QuestKind) -> Quest {
    Quest {
        id: Id::new_v4(),
        title: "Тестовая практика".into(),
        outcome: "Решена задача, тесты проходят".into(),
        skill_id: state.skills[0].id,
        kind,
        priority: 3,
        estimate_minutes: 25,
        planned_sessions: 1,
        difficulty: 1.0,
        bonus_milli: 0,
        deadline: None,
        dependencies: vec![],
        steps: vec![],
        status: Status::Planned,
        created_at: Utc::now(),
    }
}
fn completion(quest_id: Id) -> Completion {
    Completion {
        id: Id::new_v4(),
        quest_id,
        seconds: 1500,
        result: "Реализация проверена тестами".into(),
        finish_quest: true,
        day: day(),
        at: Utc::now(),
        utc_offset_seconds: 10800,
    }
}
fn near(actual: f64, expected: f64) {
    assert!(
        (actual - expected).abs() < 1e-8,
        "{actual} is not {expected}"
    );
}
fn skill(state: &GameState, domain: Domain) -> Id {
    state
        .skills
        .iter()
        .find(|skill| skill.domain == domain)
        .unwrap()
        .id
}
fn index(value: f64) -> f64 {
    100.0 * (1.0 - (-value / 1200.0).exp())
}
fn attribute(state: &GameState, name: &str) -> Option<f64> {
    character::attributes(state, day())
        .into_iter()
        .find(|(label, _)| *label == name)
        .map(|(_, value)| value)
}

#[test]
fn xp_tiers_difficulty_and_credit_cap_meet_at_exact_boundaries() {
    assert_eq!(xp::practice(1500, 25, 0.5, 0).milli, 5_000);
    assert_eq!(xp::practice(1500, 25, 2.0, 0).milli, 20_000);
    assert_eq!(xp::practice(1500, 25, f64::NAN, 0).milli, 10_000);
    assert_eq!(xp::practice(1, 25, 1.0, 0).milli, 7);

    let full = xp::practice(10_800, 144, 1.0, 0);
    assert_eq!(full.credited_seconds, 10_800);
    assert_eq!(full.milli, 72_000);
    assert_eq!(xp::practice(1, 1440, 1.0, 10_800).milli, 3);

    assert_eq!(xp::practice(18_000, 240, 1.0, 0).milli, 96_000);
    assert_eq!(xp::practice(1, 1440, 1.0, 18_000).milli, 2);
    // 800s at full rate and 1,200s at half rate.
    assert_eq!(xp::practice(2_000, 40, 1.0, 10_000).milli, 9_333);

    let capped = xp::practice(1_501, 20, 1.0, 0);
    assert_eq!(capped.credited_seconds, 1_500);
    assert_eq!(capped.milli, 10_000);
    let day_long = xp::practice(86_400, 1440, 1.0, 0);
    assert_eq!(day_long.credited_seconds, 86_400);
    assert_eq!(day_long.milli, 210_000);

    let whole = xp::practice(10_801, 200, 1.0, 0).milli;
    let head = xp::practice(10_799, 200, 1.0, 0).milli;
    let tail = xp::practice(2, 200, 1.0, 10_799).milli;
    assert_eq!(whole, head + tail);
}

#[test]
fn a_quest_can_be_created_without_an_outcome() {
    let mut state = setup();
    let mut task = quest(&state, QuestKind::Daily);
    task.outcome = "   ".into();
    state.create_quest(task.clone()).unwrap();
    assert_eq!(
        state
            .quests
            .iter()
            .find(|item| item.id == task.id)
            .unwrap()
            .outcome,
        ""
    );
    task.id = Id::new_v4();
    task.title = "  ".into();
    task.outcome = "Готовый результат".into();
    assert!(state.create_quest(task).is_err());
}

#[test]
fn completing_a_quest_checks_off_its_steps() {
    let mut state = setup();
    let mut task = quest(&state, QuestKind::Daily);
    task.planned_sessions = 2;
    task.steps = vec![
        QuestStep {
            id: Id::new_v4(),
            title: "Открытый шаг".into(),
            done: false,
        },
        QuestStep {
            id: Id::new_v4(),
            title: "Уже готовый шаг".into(),
            done: true,
        },
    ];
    let id = task.id;
    state.create_quest(task).unwrap();
    let mut partial = completion(id);
    partial.finish_quest = false;
    state.complete(partial).unwrap();
    assert!(state.quests[0].steps.iter().any(|step| !step.done));
    state.complete(completion(id)).unwrap();
    assert_eq!(state.quests[0].status, Status::Completed);
    assert!(state.quests[0].steps.iter().all(|step| step.done));
}

#[test]
fn editing_a_quest_keeps_saved_progress_and_steps_can_change() {
    let mut state = setup();
    let mut task = quest(&state, QuestKind::Daily);
    let id = task.id;
    let skill = task.skill_id;
    let created = task.created_at;
    let step = Id::new_v4();
    task.steps = vec![QuestStep {
        id: step,
        title: "  Черновик  ".into(),
        done: false,
    }];
    state.create_quest(task).unwrap();
    assert_eq!(state.quests[0].steps[0].title, "Черновик");
    state.complete(completion(id)).unwrap();
    let xp = state.character_xp_milli;
    let reward = state.sessions[0].reward_milli;
    let kept = Id::new_v4();
    let mut edited = state.quests[0].clone();
    edited.title = "  Новое название  ".into();
    edited.outcome = "   ".into();
    edited.steps = vec![
        QuestStep {
            id: step,
            title: "Первый".into(),
            done: true,
        },
        QuestStep {
            id: kept,
            title: "  Второй  ".into(),
            done: false,
        },
        QuestStep {
            id: Id::new_v4(),
            title: "   ".into(),
            done: false,
        },
    ];
    state.update_quest(id, edited).unwrap();
    let saved = state.quests.iter().find(|quest| quest.id == id).unwrap();
    assert_eq!(saved.title, "Новое название");
    assert_eq!(saved.outcome, "");
    assert_eq!(saved.status, Status::Completed);
    assert_eq!(saved.created_at, created);
    assert_eq!(saved.skill_id, skill);
    assert_eq!(saved.steps.len(), 2);
    assert!(saved.steps[0].done);
    assert_eq!(saved.steps[1].title, "Второй");
    assert_eq!(state.character_xp_milli, xp);
    assert_eq!(state.sessions[0].reward_milli, reward);
    assert_eq!(state.sessions[0].skill_id, skill);

    let mut removed = state
        .quests
        .iter()
        .find(|quest| quest.id == id)
        .unwrap()
        .clone();
    removed.steps.retain(|item| item.id == kept);
    state.update_quest(id, removed).unwrap();
    assert_eq!(
        state
            .quests
            .iter()
            .find(|quest| quest.id == id)
            .unwrap()
            .steps
            .len(),
        1
    );

    let mut blank = state
        .quests
        .iter()
        .find(|quest| quest.id == id)
        .unwrap()
        .clone();
    blank.title = "  ".into();
    assert!(state.update_quest(id, blank).is_err());
    assert_eq!(
        state
            .quests
            .iter()
            .find(|quest| quest.id == id)
            .unwrap()
            .title,
        "Новое название"
    );

    let mut moved = state
        .quests
        .iter()
        .find(|quest| quest.id == id)
        .unwrap()
        .clone();
    moved.skill_id = state.skills[1].id;
    assert!(state.update_quest(id, moved).is_err());
    assert_eq!(
        state
            .quests
            .iter()
            .find(|quest| quest.id == id)
            .unwrap()
            .skill_id,
        skill
    );

    let mut other = quest(&state, QuestKind::Daily);
    let other_id = other.id;
    other.dependencies = vec![id];
    state.create_quest(other).unwrap();
    let mut cycle = state
        .quests
        .iter()
        .find(|quest| quest.id == id)
        .unwrap()
        .clone();
    cycle.dependencies = vec![other_id];
    assert!(state.update_quest(id, cycle).is_err());
    assert!(
        state
            .quests
            .iter()
            .find(|quest| quest.id == id)
            .unwrap()
            .dependencies
            .is_empty()
    );
    assert_eq!(state.character_xp_milli, xp);
}

#[test]
fn habit_rewards_are_flat_and_their_time_still_spends_the_shared_day() {
    let mut state = setup();
    for (count, expected) in [(1, 7), (6, 7), (7, 7), (365, 365)] {
        let mut habit = quest(&state, QuestKind::Habit);
        habit.planned_sessions = count;
        let id = habit.id;
        state.create_quest(habit).unwrap();
        assert_eq!(
            state
                .quests
                .iter()
                .find(|quest| quest.id == id)
                .unwrap()
                .planned_sessions,
            expected
        );
    }
    let before = state.quests.len();
    let mut too_long = quest(&state, QuestKind::Habit);
    too_long.planned_sessions = 366;
    assert!(state.create_quest(too_long).is_err());
    for count in [0, 10_001] {
        let mut task = quest(&state, QuestKind::Daily);
        task.planned_sessions = count;
        assert!(state.create_quest(task).is_err());
    }
    assert_eq!(state.quests.len(), before);

    let recovery = skill(&state, Domain::Recovery);
    for kind in [QuestKind::Daily, QuestKind::Project] {
        let mut blocked = quest(&state, kind);
        blocked.skill_id = recovery;
        assert!(state.create_quest(blocked).is_err());
    }
    let mut allowed = quest(&state, QuestKind::Habit);
    allowed.skill_id = recovery;
    allowed.difficulty = 2.0;
    let recovery_habit = allowed.id;
    state.create_quest(allowed).unwrap();
    assert_eq!(state.complete(completion(recovery_habit)).unwrap(), 1_000);

    let mut filler = quest(&state, QuestKind::Daily);
    filler.estimate_minutes = 240;
    let filler_id = filler.id;
    state.create_quest(filler).unwrap();
    let mut long = completion(filler_id);
    long.seconds = 18_000;
    long.finish_quest = false;
    long.day += Duration::days(1);
    assert_eq!(state.complete(long).unwrap(), 96_000);
    let mut after_pool = quest(&state, QuestKind::Habit);
    after_pool.difficulty = 2.0;
    let after_id = after_pool.id;
    state.create_quest(after_pool).unwrap();
    let mut marked = completion(after_id);
    marked.day += Duration::days(1);
    assert_eq!(state.complete(marked).unwrap(), 1_000);

    let mut same_day = completion(after_id);
    same_day.day += Duration::days(1);
    let sessions = state.sessions.len();
    assert!(state.complete(same_day).is_err());
    assert_eq!(state.sessions.len(), sessions);
    let mut partial = completion(after_id);
    partial.day += Duration::days(2);
    partial.finish_quest = false;
    assert!(state.complete(partial).is_err());
}

#[test]
fn a_zero_xp_habit_still_counts_and_spends_credited_time() {
    let mut state = setup();
    let mut habits = Vec::new();
    for index in 0..5 {
        let mut habit = quest(&state, QuestKind::Habit);
        habit.title = format!("Привычка {index}");
        if index == 4 {
            habit.estimate_minutes = 180;
        }
        habits.push(habit.id);
        state.create_quest(habit).unwrap();
    }
    for id in &habits[..4] {
        assert_eq!(state.complete(completion(*id)).unwrap(), 1_000);
    }
    let mut fifth = completion(habits[4]);
    fifth.seconds = 10_800;
    assert_eq!(state.complete(fifth).unwrap(), 0);
    assert_eq!(state.habit_days(habits[4]), 1);
    assert!(state.sessions[4].completed_quest);
    assert_eq!(state.sessions[4].credited_seconds, 10_800);

    let mut task = quest(&state, QuestKind::Daily);
    task.skill_id = skill(&state, Domain::Body);
    let task_id = task.id;
    state.create_quest(task).unwrap();
    let reward = state.complete(completion(task_id)).unwrap();
    assert_eq!(reward, 4_500);
    assert_eq!(state.character_xp_milli, 8_500);
    state.validate().unwrap();
}

#[test]
fn habit_length_follows_the_saved_target_and_a_missed_habit_can_resume() {
    let mut legacy = setup();
    let mut habit = quest(&legacy, QuestKind::Habit);
    habit.planned_sessions = 1;
    let id = habit.id;
    legacy.quests.push(habit);
    legacy.validate().unwrap();
    for index in 0..6 {
        let mut logged = completion(id);
        logged.day = day() + Duration::days(index);
        legacy.complete(logged).unwrap();
    }
    assert!(!legacy.quest_fulfilled(&legacy.quests[0]));
    let mut seventh = completion(id);
    seventh.day = day() + Duration::days(6);
    legacy.complete(seventh).unwrap();
    assert!(legacy.quest_fulfilled(&legacy.quests[0]));

    let mut longer = setup();
    let mut habit = quest(&longer, QuestKind::Habit);
    habit.planned_sessions = 10;
    let id = habit.id;
    longer.create_quest(habit).unwrap();
    for index in 0..9 {
        let mut logged = completion(id);
        logged.day = day() + Duration::days(index);
        longer.complete(logged).unwrap();
    }
    assert!(!longer.quest_fulfilled(&longer.quests[0]));
    let mut last = completion(id);
    last.day = day() + Duration::days(9);
    longer.complete(last).unwrap();
    assert!(longer.quest_fulfilled(&longer.quests[0]));

    let mut missed = setup();
    let mut habit = quest(&missed, QuestKind::Habit);
    habit.deadline = Some(day() + Duration::days(5));
    let id = habit.id;
    missed.create_quest(habit).unwrap();
    for index in 0..6 {
        let mut logged = completion(id);
        logged.day = day() + Duration::days(index);
        missed.complete(logged).unwrap();
    }
    missed.settle_deadlines(day() + Duration::days(6));
    assert_eq!(missed.quests[0].status, Status::Missed);
    let mut blocked = completion(id);
    blocked.day = day() + Duration::days(6);
    assert!(missed.complete(blocked.clone()).is_err());
    missed.set_quest_status(id, Status::Planned).unwrap();
    missed.complete(blocked).unwrap();
    assert!(missed.quest_fulfilled(&missed.quests[0]));
    missed.settle_deadlines(day() + Duration::days(6));
    assert_eq!(missed.quests[0].status, Status::Planned);
}

#[test]
fn project_bonus_is_capped_by_practice_and_by_each_chain() {
    let mut tiny = setup();
    let mut project = quest(&tiny, QuestKind::Project);
    project.bonus_milli = 40_000;
    let id = project.id;
    tiny.create_quest(project).unwrap();
    let mut one_second = completion(id);
    one_second.seconds = 1;
    assert_eq!(tiny.complete(one_second).unwrap(), 14);
    assert_eq!(tiny.character_xp_milli, 14);

    let mut partial = setup();
    let mut project = quest(&partial, QuestKind::Project);
    project.bonus_milli = 40_000;
    let id = project.id;
    partial.create_quest(project).unwrap();
    let mut open = completion(id);
    open.finish_quest = false;
    assert_eq!(partial.complete(open).unwrap(), 10_000);
    assert_ne!(partial.quests[0].status, Status::Completed);
    assert_eq!(partial.complete(completion(id)).unwrap(), 30_000);
    assert_eq!(partial.character_xp_milli, 40_000);

    let mut early = setup();
    let mut project = quest(&early, QuestKind::Project);
    project.planned_sessions = 2;
    project.bonus_milli = 40_000;
    let id = project.id;
    early.create_quest(project).unwrap();
    assert!(early.complete(completion(id)).is_err());
    assert!(early.sessions.is_empty());
    assert_eq!(early.character_xp_milli, 0);
    assert_eq!(early.quests[0].status, Status::Planned);

    let mut chains = setup();
    let mut first = quest(&chains, QuestKind::Project);
    first.bonus_milli = 40_000;
    let first_id = first.id;
    let mut second = quest(&chains, QuestKind::Project);
    second.bonus_milli = 40_000;
    chains.create_quest(first).unwrap();
    chains.create_quest(second).unwrap();
    let mut overflow = quest(&chains, QuestKind::Project);
    overflow.dependencies = vec![first_id];
    overflow.bonus_milli = 1_000;
    assert!(chains.create_quest(overflow).is_err());
    assert_eq!(chains.quests.len(), 2);
    for kind in [QuestKind::Daily, QuestKind::Habit] {
        let mut bonus = quest(&chains, kind);
        bonus.bonus_milli = 1_000;
        assert!(chains.create_quest(bonus).is_err());
    }
    let mut too_much = quest(&chains, QuestKind::Project);
    too_much.bonus_milli = 40_001;
    assert!(chains.create_quest(too_much).is_err());
    chains.validate().unwrap();
}

#[test]
fn strict_mode_accepts_only_the_confirmed_clock() {
    let mut state = setup();
    state.settings.strict_mode = true;
    let quest_id = {
        let quest = quest(&state, QuestKind::Daily);
        let id = quest.id;
        state.create_quest(quest).unwrap();
        id
    };
    let other = {
        let quest = quest(&state, QuestKind::Daily);
        let id = quest.id;
        state.create_quest(quest).unwrap();
        id
    };
    assert!(state.complete(completion(quest_id)).is_err());
    assert!(state.sessions.is_empty());

    let session = Id::new_v4();
    state.active = Some(ActiveSession {
        id: session,
        quest_id,
        elapsed_seconds: 1_500,
        running: false,
        strict: false,
        presence_confirmed: false,
        focus_confirmed: true,
        notes: String::new(),
    });
    assert!(state.complete(completion(quest_id)).is_err());
    state.active.as_mut().unwrap().strict = true;
    let mut too_long = completion(quest_id);
    too_long.id = session;
    too_long.seconds = 1_501;
    assert!(state.complete(too_long).is_err());
    let mut wrong_quest = completion(other);
    wrong_quest.id = session;
    wrong_quest.seconds = 1_500;
    assert!(state.complete(wrong_quest).is_err());
    let mut wrong_session = completion(quest_id);
    wrong_session.seconds = 1_500;
    assert!(state.complete(wrong_session).is_err());

    let mut saved = completion(quest_id);
    saved.id = session;
    assert_eq!(state.complete(saved.clone()).unwrap(), 10_000);
    assert!(state.active.is_none());
    assert!(state.sessions[0].strict);
    assert_eq!(state.complete(saved).unwrap(), 0);
    assert_eq!(state.sessions.len(), 1);
    assert_eq!(state.character_xp_milli, 10_000);

    let mut open = setup();
    let quest_id = {
        let quest = quest(&open, QuestKind::Daily);
        let id = quest.id;
        open.create_quest(quest).unwrap();
        id
    };
    let session = Id::new_v4();
    open.active = Some(ActiveSession {
        id: session,
        quest_id,
        elapsed_seconds: 1_000,
        running: true,
        strict: true,
        presence_confirmed: true,
        focus_confirmed: true,
        notes: String::new(),
    });
    let mut over = completion(quest_id);
    over.id = session;
    over.seconds = 1_001;
    assert!(open.complete(over).is_err());
    let mut typed = quest(&open, QuestKind::Daily);
    typed.skill_id = skill(&open, Domain::Body);
    let typed_id = typed.id;
    open.create_quest(typed).unwrap();
    assert!(open.complete(completion(typed_id)).is_err());
    open.active = None;
    assert_eq!(open.complete(completion(typed_id)).unwrap(), 10_000);
    assert!(!open.sessions.last().unwrap().strict);
    state.validate().unwrap();
    open.validate().unwrap();
}

#[test]
fn deadlines_miss_only_overdue_open_quests_and_return_clears_the_date() {
    let mut state = setup();
    let mut today = quest(&state, QuestKind::Daily);
    today.deadline = Some(day());
    let today_id = today.id;
    let mut tomorrow = quest(&state, QuestKind::Daily);
    tomorrow.deadline = Some(day() + Duration::days(1));
    let tomorrow_id = tomorrow.id;
    let mut yesterday = quest(&state, QuestKind::Daily);
    yesterday.deadline = Some(day() - Duration::days(1));
    let yesterday_id = yesterday.id;
    let mut paused = quest(&state, QuestKind::Daily);
    paused.deadline = Some(day() - Duration::days(1));
    paused.status = Status::Paused;
    let paused_id = paused.id;
    let mut finished = quest(&state, QuestKind::Daily);
    finished.deadline = Some(day() - Duration::days(1));
    let finished_id = finished.id;
    state.create_quest(today).unwrap();
    state.create_quest(tomorrow).unwrap();
    state.create_quest(yesterday).unwrap();
    state.create_quest(paused).unwrap();
    state.create_quest(finished).unwrap();
    state.complete(completion(finished_id)).unwrap();
    state
        .quests
        .iter_mut()
        .find(|quest| quest.id == finished_id)
        .unwrap()
        .deadline = Some(day() - Duration::days(1));
    state.active = Some(ActiveSession {
        id: Id::new_v4(),
        quest_id: yesterday_id,
        elapsed_seconds: 10,
        running: true,
        strict: false,
        presence_confirmed: false,
        focus_confirmed: true,
        notes: String::new(),
    });
    let events = state.events.len();
    state.settle_deadlines(day());
    assert_eq!(status(&state, today_id), Status::Planned);
    assert_eq!(status(&state, tomorrow_id), Status::Planned);
    assert_eq!(status(&state, yesterday_id), Status::Planned);
    assert_eq!(status(&state, paused_id), Status::Missed);
    assert_eq!(status(&state, finished_id), Status::Completed);
    assert_eq!(state.events.len(), events + 1);
    state.settle_deadlines(day());
    assert_eq!(state.events.len(), events + 1);

    state.active = None;
    state.settle_deadlines(day());
    assert_eq!(status(&state, yesterday_id), Status::Missed);
    assert!(state.complete(completion(yesterday_id)).is_err());
    state
        .set_quest_status(yesterday_id, Status::Paused)
        .unwrap();
    assert!(
        state
            .quests
            .iter()
            .find(|quest| quest.id == yesterday_id)
            .unwrap()
            .deadline
            .is_none()
    );
    state.settle_deadlines(day());
    assert_eq!(status(&state, yesterday_id), Status::Paused);
    state
        .set_quest_status(yesterday_id, Status::Planned)
        .unwrap();
    state.complete(completion(yesterday_id)).unwrap();
    assert_eq!(status(&state, yesterday_id), Status::Completed);

    let mut protected = setup();
    let mut quest = quest(&protected, QuestKind::Daily);
    quest.deadline = Some(day() - Duration::days(1));
    quest.planned_sessions = 2;
    let id = quest.id;
    protected.create_quest(quest).unwrap();
    let session = Id::new_v4();
    protected.active = Some(ActiveSession {
        id: session,
        quest_id: id,
        elapsed_seconds: 1_500,
        running: true,
        strict: false,
        presence_confirmed: false,
        focus_confirmed: true,
        notes: String::new(),
    });
    protected.settle_deadlines(day());
    assert_eq!(status(&protected, id), Status::Planned);
    let mut sitting = completion(id);
    sitting.id = session;
    sitting.finish_quest = false;
    protected.complete(sitting).unwrap();
    assert!(protected.active.is_none());
    protected.settle_deadlines(day());
    assert_eq!(status(&protected, id), Status::Missed);
}

fn status(state: &GameState, id: Id) -> Status {
    state
        .quests
        .iter()
        .find(|quest| quest.id == id)
        .unwrap()
        .status
}

#[test]
fn status_changes_reject_closed_results_and_the_running_quest() {
    let mut state = setup();
    let first = quest(&state, QuestKind::Daily);
    let first_id = first.id;
    let second = quest(&state, QuestKind::Daily);
    let second_id = second.id;
    state.create_quest(first).unwrap();
    state.create_quest(second).unwrap();
    assert!(state.set_quest_status(first_id, Status::Completed).is_err());
    assert!(state.set_quest_status(first_id, Status::Active).is_err());
    assert!(
        state
            .set_quest_status(Id::new_v4(), Status::Paused)
            .is_err()
    );
    assert_eq!(status(&state, first_id), Status::Planned);
    state.active = Some(ActiveSession {
        id: Id::new_v4(),
        quest_id: first_id,
        elapsed_seconds: 1,
        running: true,
        strict: false,
        presence_confirmed: false,
        focus_confirmed: true,
        notes: String::new(),
    });
    assert!(state.set_quest_status(first_id, Status::Paused).is_err());
    state
        .set_quest_status(second_id, Status::Cancelled)
        .unwrap();
    assert_eq!(status(&state, second_id), Status::Cancelled);
    state.active = None;
    state.complete(completion(first_id)).unwrap();
    assert!(state.set_quest_status(first_id, Status::Cancelled).is_err());
    assert_eq!(status(&state, first_id), Status::Completed);
}

#[test]
fn mastery_floor_is_one_and_missed_quests_do_not_add_a_slot() {
    let mut state = setup();
    let skill = state.skills[0].id;
    let locked = state.skills[1].id;
    assert!(state.verify_mastery(skill, "коротко".into()).is_err());
    assert!(state.verify_mastery(skill, "   семь   ".into()).is_err());
    assert!(
        state
            .verify_mastery(locked, "Навык ещё закрыт предшественником".into())
            .is_err()
    );
    state.verify_mastery(skill, "12345678".into()).unwrap();
    assert!(state.verify_mastery(skill, "12345678".into()).is_err());
    assert_eq!(state.skills[0].mastery, 1);

    let mut only_one = quest(&state, QuestKind::Daily);
    only_one.title = "Единственный квест".into();
    let only_one = only_one.id;
    state
        .create_quest(only_one_quest(&state, only_one))
        .unwrap();
    state.complete(completion(only_one)).unwrap();
    assert!(
        state
            .verify_mastery(skill, "Один квест не добавляет второе подтверждение".into())
            .is_err()
    );
    assert_eq!(state.skills[0].mastery, 1);

    let mut missed = quest(&state, QuestKind::Daily);
    missed.title = "Пропущенный квест".into();
    missed.status = Status::Missed;
    state.create_quest(missed).unwrap();
    assert!(
        state
            .verify_mastery(skill, "Пропуск не увеличивает предел".into())
            .is_err()
    );

    let mut second = quest(&state, QuestKind::Daily);
    second.title = "Второй выполненный квест".into();
    let second = second.id;
    state.create_quest(second_quest(&state, second)).unwrap();
    state.complete(completion(second)).unwrap();
    state
        .verify_mastery(
            skill,
            "Второй квест открывает ещё одно подтверждение".into(),
        )
        .unwrap();
    assert_eq!(state.skills[0].mastery, 2);
    assert_eq!(state.character_xp_milli, 20_000);
    assert_eq!(xp::rated_milli(&state), 20_000);
}

fn only_one_quest(state: &GameState, id: Id) -> Quest {
    let mut quest = quest(state, QuestKind::Daily);
    quest.id = id;
    quest.title = "Единственный квест".into();
    quest
}
fn second_quest(state: &GameState, id: Id) -> Quest {
    let mut quest = quest(state, QuestKind::Daily);
    quest.id = id;
    quest.title = "Второй выполненный квест".into();
    quest
}

#[test]
fn plan_weights_use_priority_and_precision_uses_work_up_to_the_plan_day() {
    let mut weights = setup();
    weights.plans.push(plan(
        day() - Duration::days(1),
        vec![
            (Id::new_v4(), 1.0, 120, false),
            (Id::new_v4(), 3.0, 5, true),
        ],
    ));
    near(
        discipline::calculate(&weights, day()).score.unwrap(),
        100.0 * (0.7 * 0.75) / 0.9,
    );

    let mut stability = setup();
    stability.plans.push(plan(
        day() - Duration::days(1),
        vec![
            (Id::new_v4(), 1.0, 25, true),
            (Id::new_v4(), 1.0, 25, false),
        ],
    ));
    near(
        discipline::calculate(&stability, day()).score.unwrap(),
        100.0 * 0.35 / 0.9,
    );

    let mut earlier = setup();
    let mut task = quest(&earlier, QuestKind::Daily);
    task.planned_sessions = 2;
    let id = task.id;
    earlier.create_quest(task).unwrap();
    let mut first = completion(id);
    first.day -= Duration::days(1);
    first.seconds = 20 * 60;
    first.finish_quest = false;
    earlier.complete(first).unwrap();
    earlier.commit_plan(day(), &[id]).unwrap();
    let mut second = completion(id);
    second.seconds = 10 * 60;
    earlier.complete(second).unwrap();
    near(
        discipline::calculate(&earlier, day()).precision,
        25.0 / 30.0,
    );

    let mut later = setup();
    let task = quest(&later, QuestKind::Daily);
    let id = task.id;
    later.create_quest(task).unwrap();
    later.commit_plan(day(), &[id]).unwrap();
    let mut fast = completion(id);
    fast.seconds = 10 * 60;
    later.complete(fast).unwrap();
    later.sessions.push(Session {
        id: Id::new_v4(),
        quest_id: id,
        skill_id: later.skills[0].id,
        day: day() + Duration::days(1),
        completed_at: Utc::now(),
        utc_offset_seconds: 0,
        seconds: 40 * 60,
        credited_seconds: 40 * 60,
        estimate_minutes: 25,
        difficulty: 1.0,
        reward_milli: 0,
        explanation: String::new(),
        result: "Уже после дня плана".into(),
        completed_quest: false,
        strict: false,
    });
    assert_eq!(discipline::calculate(&later, day()).precision, 1.0);

    let mut exact = setup();
    let task = quest(&exact, QuestKind::Daily);
    let id = task.id;
    exact.create_quest(task).unwrap();
    exact.commit_plan(day() - Duration::days(1), &[id]).unwrap();
    let mut on_time = completion(id);
    on_time.day -= Duration::days(1);
    on_time.seconds = 25 * 60;
    exact.complete(on_time).unwrap();
    assert_eq!(discipline::calculate(&exact, day()).precision, 1.0);
    exact.sessions[0].seconds = 25 * 60 + 1;
    near(
        discipline::calculate(&exact, day()).precision,
        1_500.0 / 1_501.0,
    );
}

fn plan(day: NaiveDate, items: Vec<(Id, f64, u32, bool)>) -> DailyPlan {
    DailyPlan {
        day,
        created_at: Utc::now(),
        items: items
            .into_iter()
            .map(|(quest_id, weight, estimate_minutes, completed)| PlanItem {
                quest_id,
                weight,
                estimate_minutes,
                completed,
                excused: false,
            })
            .collect(),
        rest: false,
        reason: String::new(),
    }
}

#[test]
fn discipline_window_rest_and_excuses_follow_the_score_rules() {
    let mut old = setup();
    old.plans.push(plan(
        day() - Duration::days(28),
        vec![(Id::new_v4(), 1.0, 25, true)],
    ));
    assert_eq!(discipline::calculate(&old, day()).score, None);
    let mut kept = setup();
    kept.plans.push(plan(
        day() - Duration::days(27),
        vec![(Id::new_v4(), 1.0, 25, true)],
    ));
    near(discipline::calculate(&kept, day()).score.unwrap(), 100.0);

    let mut today = setup();
    let task = quest(&today, QuestKind::Daily);
    let id = task.id;
    today.create_quest(task).unwrap();
    today.commit_plan(day(), &[id]).unwrap();
    assert_eq!(discipline::calculate(&today, day()).score, None);
    today.complete(completion(id)).unwrap();
    near(discipline::calculate(&today, day()).score.unwrap(), 100.0);
    assert!(discipline::calculate(&today, day()).preliminary);

    let mut week = setup();
    for offset in 1..=7 {
        week.plans.push(plan(
            day() - Duration::days(offset),
            vec![(Id::new_v4(), 1.0, 25, true)],
        ));
    }
    assert!(!discipline::calculate(&week, day()).preliminary);
    week.plans.pop();
    assert!(discipline::calculate(&week, day()).preliminary);

    let mut rest = setup();
    rest.plans.push(DailyPlan {
        day: day() - Duration::days(1),
        created_at: Utc::now(),
        items: vec![PlanItem {
            quest_id: Id::new_v4(),
            weight: 1.0,
            estimate_minutes: 25,
            completed: false,
            excused: false,
        }],
        rest: true,
        reason: "Болезнь".into(),
    });
    rest.plans.push(plan(
        day() - Duration::days(2),
        vec![(Id::new_v4(), 1.0, 25, true)],
    ));
    near(discipline::calculate(&rest, day()).score.unwrap(), 100.0);

    let mut excused = setup();
    let kept_quest = quest(&excused, QuestKind::Daily);
    let kept_id = kept_quest.id;
    let dropped = quest(&excused, QuestKind::Daily);
    let dropped_id = dropped.id;
    excused.create_quest(kept_quest).unwrap();
    excused.create_quest(dropped).unwrap();
    excused.commit_plan(day(), &[kept_id, dropped_id]).unwrap();
    excused
        .excuse(day(), Some(dropped_id), "Перенос".into())
        .unwrap();
    excused.complete(completion(kept_id)).unwrap();
    near(discipline::calculate(&excused, day()).score.unwrap(), 100.0);
    assert_eq!(excused.character_xp_milli, 10_000);
    assert!(excused.excuse(day(), None, "  ".into()).is_err());
    assert!(
        excused
            .excuse(
                day() + Duration::days(1),
                Some(dropped_id),
                "Нет плана".into()
            )
            .is_err()
    );

    let mut created = setup();
    created.excuse(day(), None, "Выходной".into()).unwrap();
    assert!(created.plans[0].rest);
    assert_eq!(created.character_xp_milli, 0);
    assert_eq!(discipline::calculate(&created, day()).score, None);
}

#[test]
fn routine_size_and_lookback_have_hard_edges() {
    assert_eq!(routine_score(4, 4, 0), None);
    near(routine_score(4, 4, 1).unwrap(), 40.0);
    near(routine_score(1, 1, 1).unwrap(), 10.0);
    near(routine_score(8, 8, 1).unwrap(), 40.0);
    near(routine_score(8, 4, 1).unwrap(), 20.0);
    near(routine_score(4, 4, 28).unwrap(), 40.0);
    assert_eq!(routine_score(4, 4, 29), None);

    let mut unopened = GameState::default();
    unopened
        .set_routine(vec!["Read".into()], true, day())
        .unwrap();
    unopened.routine_versions[0].effective_from = day() - Duration::days(1);
    assert_eq!(discipline::calculate(&unopened, day()).score, None);

    let mut paused = unopened.clone();
    paused.routine_versions[0].enabled = false;
    paused.journal.push(JournalEntry {
        id: Id::new_v4(),
        day: day() - Duration::days(1),
        text: "День открыт".into(),
    });
    assert_eq!(discipline::calculate(&paused, day()).score, None);

    let mut journal = unopened.clone();
    journal.journal.push(JournalEntry {
        id: Id::new_v4(),
        day: day() - Duration::days(1),
        text: "День открыт".into(),
    });
    assert_eq!(discipline::calculate(&journal, day()).score, Some(0.0));
    let mut checkin = unopened;
    checkin.checkins.push(CheckIn {
        day: day() - Duration::days(1),
        energy: 50,
        fatigue: 20,
        focus: 70,
        available_minutes: 90,
        unwell: false,
    });
    assert_eq!(discipline::calculate(&checkin, day()).score, Some(0.0));
    assert_eq!(checkin.character_xp_milli, 0);
}

fn routine_score(items: usize, checked: usize, age: i64) -> Option<f64> {
    let mut state = GameState::default();
    let titles = (0..items).map(|index| format!("Пункт {index}")).collect();
    state.set_routine(titles, true, day()).unwrap();
    let on = day() - Duration::days(age);
    state.routine_versions[0].effective_from = on;
    let completed = state
        .routine_on(on)
        .unwrap()
        .items
        .iter()
        .take(checked)
        .map(|item| item.id)
        .collect();
    state.routine_days.push(RoutineDay { day: on, completed });
    discipline::calculate(&state, day()).score
}

#[test]
fn plans_and_routines_blend_only_after_both_exist() {
    let mut perfect = setup();
    perfect.plans.push(plan(
        day() - Duration::days(1),
        vec![(Id::new_v4(), 1.0, 25, true)],
    ));
    perfect
        .set_routine(
            vec!["One".into(), "Two".into(), "Three".into(), "Four".into()],
            true,
            day(),
        )
        .unwrap();
    perfect.routine_versions[0].effective_from = day() - Duration::days(1);
    let ids: Vec<_> = perfect
        .routine_on(day() - Duration::days(1))
        .unwrap()
        .items
        .iter()
        .map(|item| item.id)
        .collect();
    perfect.routine_days.push(RoutineDay {
        day: day() - Duration::days(1),
        completed: ids,
    });
    near(discipline::calculate(&perfect, day()).score.unwrap(), 100.0);

    let mut empty = setup();
    empty.plans.push(plan(
        day() - Duration::days(2),
        vec![(Id::new_v4(), 1.0, 25, true)],
    ));
    empty
        .set_routine(
            vec!["One".into(), "Two".into(), "Three".into(), "Four".into()],
            true,
            day(),
        )
        .unwrap();
    empty.routine_versions[0].effective_from = day() - Duration::days(1);
    empty.journal.push(JournalEntry {
        id: Id::new_v4(),
        day: day() - Duration::days(1),
        text: "Рутина открыта и не отмечена".into(),
    });
    near(discipline::calculate(&empty, day()).score.unwrap(), 60.0);

    let mut missed = setup();
    missed.plans.push(plan(
        day() - Duration::days(1),
        vec![(Id::new_v4(), 1.0, 25, false)],
    ));
    missed
        .set_routine(
            vec!["One".into(), "Two".into(), "Three".into(), "Four".into()],
            true,
            day(),
        )
        .unwrap();
    missed.routine_versions[0].effective_from = day() - Duration::days(1);
    let ids: Vec<_> = missed
        .routine_on(day() - Duration::days(1))
        .unwrap()
        .items
        .iter()
        .map(|item| item.id)
        .collect();
    missed.routine_days.push(RoutineDay {
        day: day() - Duration::days(1),
        completed: ids,
    });
    near(discipline::calculate(&missed, day()).score.unwrap(), 40.0);
}

#[test]
fn weekly_goals_count_credited_work_and_reject_bad_weights() {
    let mut state = setup();
    let quest_id = {
        let quest = quest(&state, QuestKind::Daily);
        let id = quest.id;
        state.create_quest(quest).unwrap();
        id
    };
    let week = GameState::week(day());
    let skill_id = state.skills[0].id;
    let target = move |unit, target, weight| WeeklyTarget {
        id: Id::new_v4(),
        week,
        skill_id,
        target,
        weight,
        unit,
    };
    let mut short = completion(quest_id);
    short.seconds = 299;
    short.finish_quest = false;
    state.complete(short).unwrap();
    assert_eq!(
        balance::actual(&state, &target(TargetUnit::Sessions, 1.0, 1.0)),
        0.0
    );
    assert_eq!(
        balance::actual(&state, &target(TargetUnit::Days, 1.0, 1.0)),
        0.0
    );
    near(
        balance::actual(&state, &target(TargetUnit::Minutes, 1.0, 1.0)),
        299.0 / 60.0,
    );

    let mut enough = completion(quest_id);
    enough.seconds = 300;
    enough.finish_quest = false;
    state.complete(enough).unwrap();
    let mut again = completion(quest_id);
    again.seconds = 300;
    again.finish_quest = false;
    state.complete(again).unwrap();
    assert_eq!(
        balance::actual(&state, &target(TargetUnit::Sessions, 1.0, 1.0)),
        2.0
    );
    assert_eq!(
        balance::actual(&state, &target(TargetUnit::Days, 1.0, 1.0)),
        1.0
    );

    let mut next_week = completion(quest_id);
    next_week.day = week + Duration::days(7);
    next_week.finish_quest = false;
    state.complete(next_week).unwrap();
    assert_eq!(
        balance::actual(&state, &target(TargetUnit::Sessions, 1.0, 1.0)),
        2.0
    );

    let mut fresh = setup();
    let mut long = quest(&fresh, QuestKind::Daily);
    long.planned_sessions = 1;
    let id = long.id;
    fresh.create_quest(long).unwrap();
    let mut hour = completion(id);
    hour.seconds = 3_600;
    hour.finish_quest = false;
    fresh.complete(hour).unwrap();
    near(
        balance::actual(&fresh, &target_for(&fresh, TargetUnit::Minutes)),
        31.25,
    );
    assert_eq!(
        balance::actual(&fresh, &target_for(&fresh, TargetUnit::Milestones)),
        0.0
    );
    let mut milestone = quest(&fresh, QuestKind::Project);
    milestone.planned_sessions = 2;
    let milestone_id = milestone.id;
    fresh.create_quest(milestone).unwrap();
    let mut unfinished = completion(milestone_id);
    unfinished.finish_quest = false;
    fresh.complete(unfinished).unwrap();
    assert_eq!(
        balance::actual(&fresh, &target_for(&fresh, TargetUnit::Milestones)),
        0.0
    );
    fresh.complete(completion(id)).unwrap();
    assert_eq!(
        balance::actual(&fresh, &target_for(&fresh, TargetUnit::Milestones)),
        0.0
    );
    fresh.complete(completion(milestone_id)).unwrap();
    assert_eq!(
        balance::actual(&fresh, &target_for(&fresh, TargetUnit::Milestones)),
        1.0
    );

    fresh
        .set_target(target_for(&fresh, TargetUnit::Minutes), day())
        .unwrap();
    fresh.targets[0].target = 1.0;
    assert_eq!(balance::development(&fresh, week), Some(100.0));

    let mut weighted = setup();
    let practiced = weighted.skills[0].id;
    let idle = weighted.skills[5].id;
    let task = quest(&weighted, QuestKind::Daily);
    let id = task.id;
    weighted.create_quest(task).unwrap();
    weighted.complete(completion(id)).unwrap();
    for (skill_id, weight) in [(practiced, 10.0), (idle, 1.0)] {
        weighted
            .set_target(
                WeeklyTarget {
                    id: Id::new_v4(),
                    week,
                    skill_id,
                    target: 25.0,
                    weight,
                    unit: TargetUnit::Minutes,
                },
                day(),
            )
            .unwrap();
    }
    near(
        balance::development(&weighted, week).unwrap(),
        1_000.0 / 11.0,
    );

    let mut legacy = weighted.clone();
    legacy.targets[0].weight = 50.0;
    legacy.targets[1].weight = 10.0;
    legacy.validate().unwrap();
    assert_eq!(balance::development(&legacy, week), Some(50.0));

    let mut rejected = setup();
    let base = WeeklyTarget {
        id: Id::new_v4(),
        week,
        skill_id: rejected.skills[0].id,
        target: 25.0,
        weight: 1.0,
        unit: TargetUnit::Minutes,
    };
    for weight in [0.0, -1.0, 10.1, f64::NAN, f64::INFINITY] {
        let mut bad = base.clone();
        bad.weight = weight;
        assert!(rejected.set_target(bad, day()).is_err());
    }
    let mut bad_target = base.clone();
    bad_target.target = f64::NAN;
    assert!(rejected.set_target(bad_target, day()).is_err());
    let mut midweek = base.clone();
    midweek.week += Duration::days(1);
    assert!(rejected.set_target(midweek.clone(), day()).is_err());
    rejected.targets.push(midweek);
    assert!(rejected.validate().is_err());
    rejected.targets.clear();
    let mut previous = base.clone();
    previous.week -= Duration::days(7);
    assert!(rejected.set_target(previous, day()).is_err());
    let mut missing = base.clone();
    missing.skill_id = Id::new_v4();
    assert!(rejected.set_target(missing, day()).is_err());
    rejected.set_target(base.clone(), day()).unwrap();
    assert!(rejected.set_target(base, day()).is_err());
    assert_eq!(rejected.targets.len(), 1);
}

fn target_for(state: &GameState, unit: TargetUnit) -> WeeklyTarget {
    WeeklyTarget {
        id: Id::new_v4(),
        week: GameState::week(day()),
        skill_id: state.skills[0].id,
        target: 25.0,
        weight: 1.0,
        unit,
    }
}

#[test]
fn attributes_follow_their_own_domain_and_level_follows_the_strongest() {
    let mut state = setup();
    assert!(attribute(&state, "Дисциплина").is_none());
    assert_eq!(attribute(&state, "Восстановление"), Some(0.0));
    state.plans.push(plan(
        day() - Duration::days(1),
        vec![(Id::new_v4(), 1.0, 25, true)],
    ));
    near(attribute(&state, "Дисциплина").unwrap(), 100.0);
    near(attribute(&state, "Самоорганизация").unwrap(), 0.0);

    state
        .verify_mastery(state.skills[0].id, "Подтверждение без квестов".into())
        .unwrap();
    near(attribute(&state, "Интеллект").unwrap(), index(10.0));
    assert_eq!(attribute(&state, "Физическая форма"), Some(0.0));
    assert_eq!(xp::rated_milli(&state), 0);
    assert_eq!(xp::level(xp::rated_milli(&state)).0, 0);

    let recovery = skill(&state, Domain::Recovery);
    let mut habit = quest(&state, QuestKind::Habit);
    habit.skill_id = recovery;
    let id = habit.id;
    state.create_quest(habit).unwrap();
    state.complete(completion(id)).unwrap();
    near(attribute(&state, "Восстановление").unwrap(), index(1.0));
    near(attribute(&state, "Интеллект").unwrap(), index(10.0));

    let mut focus = setup();
    let task = quest(&focus, QuestKind::Daily);
    let id = task.id;
    focus.create_quest(task).unwrap();
    let mut brief = completion(id);
    brief.seconds = 599;
    brief.finish_quest = false;
    focus.complete(brief).unwrap();
    assert_eq!(attribute(&focus, "Концентрация"), Some(0.0));
    let mut ten = completion(id);
    ten.seconds = 600;
    ten.finish_quest = false;
    focus.complete(ten).unwrap();
    near(
        attribute(&focus, "Концентрация").unwrap(),
        index(10.0 * 0.4),
    );

    let mut capped = setup();
    let task = quest(&capped, QuestKind::Daily);
    let id = task.id;
    capped.create_quest(task).unwrap();
    let mut hour = completion(id);
    hour.seconds = 3_600;
    hour.finish_quest = false;
    capped.complete(hour).unwrap();
    near(
        attribute(&capped, "Концентрация").unwrap(),
        index(1_875.0 / 60.0 * 0.4),
    );
    assert!(attribute(&capped, "Концентрация").unwrap() < index(24.0));

    let mut spread = setup();
    for skill in &mut spread.skills {
        skill.xp_milli = 0;
    }
    for domain in Domain::ALL {
        let id = skill(&spread, domain);
        spread
            .skills
            .iter_mut()
            .find(|skill| skill.id == id)
            .unwrap()
            .xp_milli = 20_000;
    }
    assert_eq!(xp::rated_milli(&spread), 40_000);
    assert_eq!(xp::level(40_000).0, 0);
    spread.skills[0].xp_milli = 100_000;
    for skill in spread.skills.iter_mut().skip(1) {
        skill.xp_milli = 0;
    }
    assert_eq!(xp::rated_milli(&spread), 100_000);
    assert_eq!(xp::level(100_000).0, 1);
}

#[test]
fn deleting_a_skill_keeps_the_rest_and_releases_dependents() {
    let mut state = setup();
    let removed = state.skills[0].id;
    let dependent_skill = state.skills[1].id;
    let kept = skill(&state, Domain::Organization);
    let removed_quest = quest(&state, QuestKind::Daily);
    let removed_quest_id = removed_quest.id;
    let mut child = quest(&state, QuestKind::Daily);
    child.skill_id = dependent_skill;
    child.dependencies = vec![removed_quest_id];
    child.title = "Зависимый квест".into();
    let child_id = child.id;
    let mut kept_quest = quest(&state, QuestKind::Daily);
    kept_quest.skill_id = kept;
    kept_quest.title = "Чужой квест".into();
    let kept_quest_id = kept_quest.id;
    state.create_quest(removed_quest).unwrap();
    state.create_quest(child).unwrap();
    state.create_quest(kept_quest).unwrap();
    state.complete(completion(removed_quest_id)).unwrap();
    state.complete(completion(kept_quest_id)).unwrap();
    assert!(state.complete(completion(child_id)).is_err());
    let week = GameState::week(day());
    for skill_id in [removed, kept] {
        state
            .set_target(
                WeeklyTarget {
                    id: Id::new_v4(),
                    week,
                    skill_id,
                    target: 25.0,
                    weight: 1.0,
                    unit: TargetUnit::Minutes,
                },
                day(),
            )
            .unwrap();
    }
    state.plans.push(plan(
        day(),
        vec![
            (removed_quest_id, 1.0, 25, true),
            (kept_quest_id, 2.0, 25, true),
        ],
    ));
    state.plans.push(plan(
        day() - Duration::days(1),
        vec![(removed_quest_id, 1.0, 25, true)],
    ));
    state.plans.push(DailyPlan {
        day: day() - Duration::days(2),
        created_at: Utc::now(),
        items: vec![],
        rest: true,
        reason: "Отдых".into(),
    });

    let mut clearing = state.clone();
    clearing.active = Some(ActiveSession {
        id: Id::new_v4(),
        quest_id: removed_quest_id,
        elapsed_seconds: 5,
        running: true,
        strict: false,
        presence_confirmed: false,
        focus_confirmed: true,
        notes: String::new(),
    });
    clearing.remove_skill(removed).unwrap();
    assert!(clearing.active.is_none());

    state.active = Some(ActiveSession {
        id: Id::new_v4(),
        quest_id: kept_quest_id,
        elapsed_seconds: 5,
        running: false,
        strict: false,
        presence_confirmed: false,
        focus_confirmed: true,
        notes: String::new(),
    });
    state.remove_skill(removed).unwrap();
    assert_eq!(state.active.as_ref().unwrap().quest_id, kept_quest_id);
    assert!(state.skills.iter().all(|skill| skill.id != removed));
    assert!(
        state
            .skills
            .iter()
            .all(|skill| !skill.prerequisites.contains(&removed))
    );
    assert!(
        state
            .quests
            .iter()
            .all(|quest| quest.dependencies.is_empty() || quest.id == kept_quest_id)
    );
    assert!(
        state
            .quests
            .iter()
            .any(|quest| quest.id == child_id && quest.dependencies.is_empty())
    );
    assert_eq!(state.sessions.len(), 1);
    assert_eq!(state.character_xp_milli, 10_000);
    assert_eq!(state.plans.len(), 2);
    assert_eq!(
        state
            .plans
            .iter()
            .find(|plan| plan.day == day())
            .unwrap()
            .items
            .len(),
        1
    );
    assert!(state.plans.iter().any(|plan| plan.rest));
    assert_eq!(state.targets.len(), 1);
    assert_eq!(state.targets[0].skill_id, kept);
    state.complete(completion(child_id)).unwrap();
    assert_eq!(state.character_xp_milli, 20_000);
    state.validate().unwrap();
    assert!(state.remove_skill(removed).is_err());
}

#[test]
fn overflow_and_corrupt_profiles_do_not_change_a_valid_journal() {
    for (skill_xp, character_xp) in [(u64::MAX - 1, 0), (0, u64::MAX - 1)] {
        let mut state = setup();
        let task = quest(&state, QuestKind::Daily);
        let id = task.id;
        state.create_quest(task).unwrap();
        state.skills[0].xp_milli = skill_xp;
        state.character_xp_milli = character_xp;
        let sessions = state.sessions.len();
        assert!(state.complete(completion(id)).is_err());
        assert_eq!(state.skills[0].xp_milli, skill_xp);
        assert_eq!(state.character_xp_milli, character_xp);
        assert_eq!(state.sessions.len(), sessions);
    }

    let mut legacy = setup();
    let mut habit = quest(&legacy, QuestKind::Habit);
    habit.planned_sessions = 1;
    habit.difficulty = 0.8;
    legacy.quests.push(habit);
    let mut old = quest(&legacy, QuestKind::Daily);
    old.difficulty = 1.2;
    legacy.quests.push(old);
    legacy.targets.push(WeeklyTarget {
        id: Id::new_v4(),
        week: GameState::week(day()),
        skill_id: legacy.skills[0].id,
        target: 10.0,
        weight: 50.0,
        unit: TargetUnit::Minutes,
    });
    legacy.validate().unwrap();

    let mut broken = setup();
    broken.schema_version = 2;
    assert!(broken.validate().is_err());
    broken.schema_version = 1;
    broken.character_xp_milli = 1;
    assert!(broken.validate().is_err());
    broken.character_xp_milli = 0;
    let mut task = quest(&broken, QuestKind::Daily);
    task.difficulty = 0.4;
    broken.quests.push(task);
    assert!(broken.validate().is_err());
    broken.quests.clear();
    let mut left = quest(&broken, QuestKind::Daily);
    let mut right = quest(&broken, QuestKind::Daily);
    left.dependencies = vec![right.id];
    right.dependencies = vec![left.id];
    broken.quests.push(left);
    broken.quests.push(right);
    assert!(broken.validate().is_err());

    let mut state = setup();
    let task = quest(&state, QuestKind::Daily);
    let id = task.id;
    state.create_quest(task).unwrap();
    state.complete(completion(id)).unwrap();
    state.sessions[0].credited_seconds = state.sessions[0].seconds + 1;
    assert!(state.validate().is_err());
    state.sessions[0].credited_seconds = state.sessions[0].seconds;
    state.sessions[0].skill_id = skill(&state, Domain::Body);
    assert!(state.validate().is_err());
    state.checkins.push(CheckIn {
        day: day(),
        energy: 101,
        fatigue: 0,
        focus: 0,
        available_minutes: 10,
        unwell: false,
    });
    assert!(state.validate().is_err());
    state.checkins.clear();
    state.sessions[0].skill_id = state.skills[0].id;
    state.active = Some(ActiveSession {
        id: Id::new_v4(),
        quest_id: id,
        elapsed_seconds: 86_401,
        running: false,
        strict: false,
        presence_confirmed: false,
        focus_confirmed: true,
        notes: String::new(),
    });
    assert!(state.validate().is_err());
    state.active = None;
    state.validate().unwrap();
}

#[test]
fn focus_lists_match_the_front_app_or_active_site() {
    assert_eq!(
        normalize_site("https://www.GitHub.com/rust-lang"),
        Some("github.com".into())
    );
    assert_eq!(
        normalize_site("http://docs.github.com:443/path?q=1"),
        Some("docs.github.com".into())
    );
    assert_eq!(normalize_site("localhost"), Some("localhost".into()));
    assert!(normalize_site("hello world").is_none());
    assert!(normalize_site("javascript:alert(1)").is_none());
    assert!(normalize_site("com").is_none());

    let mut skill = setup().skills.remove(0);
    assert!(skill.allows_focus("com.apple.finder", None));
    skill.allowed_apps = vec!["com.apple.dt.Xcode".into()];
    skill.allowed_sites = vec!["github.com".into()];
    assert!(skill.allows_focus("com.apple.dt.Xcode", None));
    assert!(skill.allows_focus("dev.ascend.desktop", None));
    assert!(skill.allows_focus("com.apple.Safari", Some("https://docs.github.com/en")));
    assert!(!skill.allows_focus("com.apple.Safari", Some("notgithub.com")));
    assert!(!skill.allows_focus("com.apple.Safari", Some("github.com.evil.com")));
    assert!(!skill.allows_focus("com.apple.Safari", None));

    let apps: Vec<_> = (0..25).map(|index| format!("app{index}.example")).collect();
    assert!(normalize_focus_lists(&apps, Vec::<String>::new()).is_err());
    let apps: Vec<_> = (0..24).map(|index| format!("app{index}.example")).collect();
    assert!(normalize_focus_lists(apps, ["https://www.GitHub.com/rust-lang"]).is_ok());
}

#[test]
fn editing_a_skill_keeps_progress_and_rejects_a_cycle() {
    let mut state = setup();
    let rust = state.skills[0].id;
    let architecture = state.skills[1].id;
    let task = quest(&state, QuestKind::Daily);
    let quest_id = task.id;
    state.create_quest(task).unwrap();
    state.complete(completion(quest_id)).unwrap();
    let xp = state.skills[0].xp_milli;
    assert!(xp > 0);
    state
        .update_skill(
            rust,
            "  Rust  ".into(),
            Domain::Mind,
            vec![],
            vec!["com.apple.dt.Xcode".into()],
            vec!["https://www.GitHub.com/rust-lang".into()],
        )
        .unwrap();
    assert_eq!(state.skills[0].title, "Rust");
    assert_eq!(state.skills[0].xp_milli, xp);
    assert_eq!(state.skills[0].mastery, 0);
    assert_eq!(state.skills[0].allowed_sites, vec!["github.com"]);
    let before = state.skills[0].clone();
    assert!(
        state
            .update_skill(
                rust,
                "Rust".into(),
                Domain::Mind,
                vec![rust],
                vec![],
                vec![]
            )
            .is_err()
    );
    assert_eq!(state.skills[0].title, before.title);
    assert!(state.skills[0].prerequisites.is_empty());
    assert!(
        state
            .update_skill(
                rust,
                "Rust".into(),
                Domain::Mind,
                vec![architecture],
                vec![],
                vec![],
            )
            .is_err()
    );
    assert!(state.skills[0].prerequisites.is_empty());
    assert!(
        state
            .update_skill(rust, "  ".into(), Domain::Mind, vec![], vec![], vec![])
            .is_err()
    );
    assert_eq!(state.skills[0].title, "Rust");
    assert!(
        state
            .update_skill(
                rust,
                "Rust".into(),
                Domain::Mind,
                vec![],
                vec!["hello world".into()],
                vec![],
            )
            .is_err()
    );
    assert_eq!(state.skills[0].allowed_apps, vec!["com.apple.dt.Xcode"]);
}

#[test]
fn recurring_habits_keep_daily_accuracy_and_import_order_does_not_change_it() {
    let mut state = setup();
    let habit = quest(&state, QuestKind::Habit);
    let id = habit.id;
    state.create_quest(habit).unwrap();
    for offset in (0..7).rev() {
        let date = day() - Duration::days(offset);
        state.commit_plan(date, &[id]).unwrap();
        let mut finished = completion(id);
        finished.day = date;
        state.complete(finished).unwrap();
    }
    state.validate().unwrap();
    let result = discipline::calculate(&state, day());
    near(result.precision, 1.0);
    near(result.score.unwrap(), 100.0);
    // Backups need not store the ledger in chronological order.
    state.sessions.reverse();
    let result = discipline::calculate(&state, day());
    near(result.precision, 1.0);
    near(result.score.unwrap(), 100.0);
}

#[test]
fn imported_timer_cannot_reuse_a_completed_session_identity() {
    let mut state = setup();
    let mut task = quest(&state, QuestKind::Daily);
    task.planned_sessions = 2;
    let id = task.id;
    state.create_quest(task).unwrap();
    let mut first = completion(id);
    first.finish_quest = false;
    let saved = first.id;
    state.complete(first).unwrap();
    state.active = Some(ActiveSession {
        id: saved,
        quest_id: id,
        elapsed_seconds: 1500,
        running: false,
        strict: false,
        presence_confirmed: false,
        focus_confirmed: true,
        notes: String::new(),
    });
    assert!(state.validate().is_err());
    state.active.as_mut().unwrap().id = Id::new_v4();
    state.validate().unwrap();
}

#[test]
fn extreme_imported_target_dates_do_not_overflow_calendar_arithmetic() {
    let mut state = setup();
    let mut target = target_for(&state, TargetUnit::Minutes);
    target.week = NaiveDate::MIN;
    state.targets.push(target.clone());
    assert!(state.validate().is_err());
    let task = quest(&state, QuestKind::Daily);
    let id = task.id;
    state.create_quest(task).unwrap();
    state.complete(completion(id)).unwrap();
    target.week = NaiveDate::MAX;
    assert_eq!(balance::actual(&state, &target), 0.0);
}
