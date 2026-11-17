use crate::*;
use chrono::{Duration, NaiveDate, Utc};
fn day() -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 11, 14).unwrap()
}
fn setup() -> GameState {
    let mut s = GameState::default();
    s.starter_skills();
    s
}
fn quest(s: &GameState, kind: QuestKind) -> Quest {
    Quest {
        id: Id::new_v4(),
        title: "Тестовая практика".into(),
        outcome: "Решена задача, тесты проходят".into(),
        skill_id: s.skills[0].id,
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
fn completion(q: Id) -> Completion {
    Completion {
        id: Id::new_v4(),
        quest_id: q,
        seconds: 1500,
        result: "Реализация проверена тестами".into(),
        finish_quest: true,
        day: day(),
        at: Utc::now(),
        utc_offset_seconds: 10800,
    }
}
#[test]
fn duplicate_completion_is_idempotent() {
    let mut s = setup();
    let q = quest(&s, QuestKind::Daily);
    let id = q.id;
    s.create_quest(q).unwrap();
    let c = completion(id);
    assert_eq!(s.complete(c.clone()).unwrap(), 10000);
    assert_eq!(s.complete(c).unwrap(), 0);
    assert_eq!(s.sessions.len(), 1);
    assert_eq!(s.character_xp_milli, 10000);
    s.validate().unwrap();
}
#[test]
fn different_event_id_cannot_repeat_closed_quest() {
    let mut s = setup();
    let q = quest(&s, QuestKind::Daily);
    let id = q.id;
    s.create_quest(q).unwrap();
    s.complete(completion(id)).unwrap();
    assert!(s.complete(completion(id)).is_err());
    assert_eq!(s.character_xp_milli, 10000);
}
#[test]
fn habit_cap_is_shared_between_all_habits() {
    let mut s = setup();
    for _ in 0..100 {
        let q = quest(&s, QuestKind::Habit);
        let id = q.id;
        s.create_quest(q).unwrap();
        s.complete(completion(id)).unwrap();
    }
    assert_eq!(s.character_xp_milli, 4000);
    assert_eq!(s.sessions.len(), 100);
    s.validate().unwrap();
}
#[test]
fn habit_once_per_day_and_return_tomorrow() {
    let mut s = setup();
    let q = quest(&s, QuestKind::Habit);
    let id = q.id;
    s.create_quest(q).unwrap();
    s.complete(completion(id)).unwrap();
    assert!(s.complete(completion(id)).is_err());
    let mut c = completion(id);
    c.day += Duration::days(1);
    s.complete(c).unwrap();
    assert_eq!(s.character_xp_milli, 2000);
}
#[test]
fn bonus_cannot_be_farmed_by_splitting_a_project() {
    let mut s = setup();
    let mut q = quest(&s, QuestKind::Project);
    q.bonus_milli = 30000;
    let id = q.id;
    s.create_quest(q).unwrap();
    let mut stage = quest(&s, QuestKind::Project);
    stage.dependencies = vec![id];
    stage.bonus_milli = 20000;
    assert!(s.create_quest(stage.clone()).is_err());
    stage.bonus_milli = 10000;
    s.create_quest(stage).unwrap();
    s.validate().unwrap();
}
#[test]
fn partial_project_has_no_bonus_and_does_not_complete_promise() {
    let mut s = setup();
    let mut q = quest(&s, QuestKind::Project);
    q.bonus_milli = 40000;
    let id = q.id;
    s.create_quest(q).unwrap();
    s.commit_plan(day(), &[id]).unwrap();
    let mut c = completion(id);
    c.finish_quest = false;
    s.complete(c).unwrap();
    assert_eq!(s.character_xp_milli, 10000);
    assert!(!s.plans[0].items[0].completed);
    s.complete(completion(id)).unwrap();
    // Two 25-minute sittings earn 20 XP, so the 40 XP allocation pays 20.
    assert_eq!(s.character_xp_milli, 40000);
    assert!(s.plans[0].items[0].completed);
}
#[test]
fn zero_time_or_no_evidence_cannot_reward() {
    let mut s = setup();
    let q = quest(&s, QuestKind::Daily);
    let id = q.id;
    s.create_quest(q).unwrap();
    let mut c = completion(id);
    c.seconds = 0;
    assert!(s.complete(c).is_err());
    let mut c = completion(id);
    c.result = " ".into();
    assert!(s.complete(c).is_err());
    assert_eq!(s.character_xp_milli, 0);
}
#[test]
fn unlocked_by_mastery_not_character_xp() {
    let mut s = setup();
    let mut q = quest(&s, QuestKind::Daily);
    q.skill_id = s.skills[1].id;
    let id = q.id;
    s.create_quest(q).unwrap();
    assert!(matches!(
        s.complete(completion(id)),
        Err(EngineError::Locked)
    ));
    let gate = quest(&s, QuestKind::Daily);
    let gate_id = gate.id;
    s.create_quest(gate).unwrap();
    s.complete(completion(gate_id)).unwrap();
    s.verify_mastery(s.skills[0].id, "Решён набор задач на ownership".into())
        .unwrap();
    s.complete(completion(id)).unwrap();
}
#[test]
fn dependencies_block_until_result_confirmed() {
    let mut s = setup();
    let a = quest(&s, QuestKind::Daily);
    let aid = a.id;
    s.create_quest(a).unwrap();
    let mut b = quest(&s, QuestKind::Daily);
    b.dependencies = vec![aid];
    let bid = b.id;
    s.create_quest(b).unwrap();
    assert!(s.complete(completion(bid)).is_err());
    s.complete(completion(aid)).unwrap();
    s.complete(completion(bid)).unwrap();
}
#[test]
fn unscheduled_work_does_not_replace_promised_work() {
    let mut s = setup();
    let a = quest(&s, QuestKind::Daily);
    let aid = a.id;
    s.create_quest(a).unwrap();
    s.commit_plan(day(), &[aid]).unwrap();
    for _ in 0..10 {
        let mut b = quest(&s, QuestKind::Daily);
        b.estimate_minutes = 2;
        let id = b.id;
        s.create_quest(b).unwrap();
        let mut c = completion(id);
        c.seconds = 120;
        s.complete(c).unwrap();
    }
    assert!(!s.plans[0].items[0].completed);
    let d = discipline::calculate(&s, day() + Duration::days(1));
    assert_eq!(d.score, Some(0.0));
}
#[test]
fn plans_cannot_be_added_after_work_or_replaced() {
    let mut s = setup();
    let q = quest(&s, QuestKind::Daily);
    let id = q.id;
    s.create_quest(q).unwrap();
    s.complete(completion(id)).unwrap();
    assert!(s.commit_plan(day(), &[id]).is_err());
    let q = quest(&s, QuestKind::Daily);
    let id = q.id;
    s.create_quest(q).unwrap();
    s.commit_plan(day(), &[id]).unwrap();
    assert!(s.commit_plan(day(), &[id]).is_err());
}
#[test]
fn plan_maximum_three_and_no_duplicate_ids() {
    let mut s = setup();
    let mut ids = vec![];
    for _ in 0..4 {
        let q = quest(&s, QuestKind::Daily);
        ids.push(q.id);
        s.create_quest(q).unwrap();
    }
    assert!(s.commit_plan(day(), &ids).is_err());
    assert!(s.commit_plan(day(), &[ids[0], ids[0]]).is_err());
    s.commit_plan(day(), &ids[..3]).unwrap();
}
#[test]
fn rest_and_force_majeure_are_not_failures() {
    let mut s = setup();
    let q = quest(&s, QuestKind::Daily);
    let id = q.id;
    s.create_quest(q).unwrap();
    s.commit_plan(day(), &[id]).unwrap();
    s.excuse(day(), None, "Болезнь".into()).unwrap();
    assert_eq!(
        discipline::calculate(&s, day() + Duration::days(1)).score,
        None
    );
    assert_eq!(s.character_xp_milli, 0);
    assert!(s.excuse(day(), None, "".into()).is_err());
}
#[test]
fn current_day_is_not_failed_before_it_ends() {
    let mut s = setup();
    let q = quest(&s, QuestKind::Daily);
    let id = q.id;
    s.create_quest(q).unwrap();
    s.commit_plan(day(), &[id]).unwrap();
    assert_eq!(discipline::calculate(&s, day()).score, None);
    assert_eq!(
        discipline::calculate(&s, day() + Duration::days(1)).score,
        Some(0.0)
    );
}
#[test]
fn long_absence_does_not_remove_xp() {
    let mut s = setup();
    let q = quest(&s, QuestKind::Daily);
    let id = q.id;
    s.create_quest(q).unwrap();
    s.commit_plan(day(), &[id]).unwrap();
    s.complete(completion(id)).unwrap();
    let xp = s.character_xp_milli;
    let d = discipline::calculate(&s, day() + Duration::days(100));
    assert_eq!(d.score, None);
    assert_eq!(s.character_xp_milli, xp);
}
#[test]
fn balance_has_no_cross_compensation() {
    let mut s = setup();
    let q = quest(&s, QuestKind::Daily);
    let id = q.id;
    s.create_quest(q).unwrap();
    s.complete(completion(id)).unwrap();
    for skill in [s.skills[0].id, s.skills[5].id] {
        s.set_target(
            WeeklyTarget {
                id: Id::new_v4(),
                week: GameState::week(day()),
                skill_id: skill,
                target: 10.0,
                weight: 1.0,
                unit: TargetUnit::Minutes,
            },
            day(),
        )
        .unwrap();
    }
    assert_eq!(balance::development(&s, GameState::week(day())), Some(50.0));
}
#[test]
fn no_targets_has_no_invented_balance() {
    assert_eq!(balance::development(&setup(), GameState::week(day())), None);
}
#[test]
fn historical_targets_and_retroactive_edits_are_rejected() {
    let mut s = setup();
    let t = WeeklyTarget {
        id: Id::new_v4(),
        week: GameState::week(day()),
        skill_id: s.skills[0].id,
        target: 60.0,
        weight: 1.0,
        unit: TargetUnit::Minutes,
    };
    s.set_target(t.clone(), day()).unwrap();
    assert!(s.set_target(t.clone(), day()).is_err());
    let mut t = t;
    t.week -= Duration::days(7);
    assert!(s.set_target(t, day()).is_err());
}
#[test]
fn cyclic_import_and_ledger_corruption_rejected() {
    let mut s = setup();
    s.skills[0].prerequisites = vec![s.skills[1].id];
    assert!(s.validate().is_err());
    s.skills[0].prerequisites.clear();
    s.character_xp_milli = 10000;
    assert!(s.validate().is_err());
}
#[test]
fn timezone_and_midnight_keep_reward_day_explicit() {
    let mut s = setup();
    let q = quest(&s, QuestKind::Habit);
    let id = q.id;
    s.create_quest(q).unwrap();
    let mut c = completion(id);
    c.utc_offset_seconds = 10800;
    s.complete(c).unwrap();
    let mut next = completion(id);
    next.day += Duration::days(1);
    next.utc_offset_seconds = -18000;
    s.complete(next).unwrap();
    assert_eq!(s.sessions[0].day, day());
    assert_eq!(s.sessions[1].utc_offset_seconds, -18000);
    assert_eq!(s.character_xp_milli, 2000);
}
#[test]
fn recovery_cannot_reward_unbounded_practice() {
    let mut s = setup();
    let mut q = quest(&s, QuestKind::Daily);
    q.skill_id = s
        .skills
        .iter()
        .find(|s| s.domain == Domain::Recovery)
        .unwrap()
        .id;
    assert!(s.create_quest(q.clone()).is_err());
    q.kind = QuestKind::Habit;
    s.create_quest(q).unwrap();
}
#[test]
fn project_budget_tracks_branching_and_intermediate_tasks() {
    let mut s = setup();
    let mut root = quest(&s, QuestKind::Project);
    let root_id = root.id;
    root.bonus_milli = 20000;
    s.create_quest(root).unwrap();
    let mut task = quest(&s, QuestKind::Daily);
    let task_id = task.id;
    task.dependencies = vec![root_id];
    s.create_quest(task).unwrap();
    let mut child = quest(&s, QuestKind::Project);
    child.dependencies = vec![task_id];
    child.bonus_milli = 20000;
    s.create_quest(child).unwrap();
    let mut branch = quest(&s, QuestKind::Project);
    branch.dependencies = vec![root_id];
    branch.bonus_milli = 1000;
    assert!(s.create_quest(branch).is_err());
    s.validate().unwrap();
}
#[test]
fn deleting_a_skill_drops_its_progress_and_leaves_the_rest() {
    let mut s = setup();
    let removed = s.skills[0].id;
    let kept = s.skills[2].id;
    let q = quest(&s, QuestKind::Daily);
    let qid = q.id;
    s.create_quest(q).unwrap();
    s.complete(completion(qid)).unwrap();
    s.set_target(
        WeeklyTarget {
            id: Id::new_v4(),
            week: GameState::week(day()),
            skill_id: removed,
            target: 25.0,
            weight: 1.0,
            unit: TargetUnit::Minutes,
        },
        day(),
    )
    .unwrap();
    s.plans.push(DailyPlan {
        day: day(),
        created_at: Utc::now(),
        items: vec![PlanItem {
            quest_id: qid,
            weight: 1.0,
            estimate_minutes: 25,
            completed: true,
            excused: false,
        }],
        rest: false,
        reason: String::new(),
    });
    s.active = Some(ActiveSession {
        id: Id::new_v4(),
        quest_id: qid,
        elapsed_seconds: 10,
        running: false,
        strict: false,
        presence_confirmed: false,
        focus_confirmed: true,
        notes: String::new(),
    });
    let before = s.skills.len();
    s.remove_skill(removed).unwrap();
    assert_eq!(s.skills.len(), before - 1);
    assert!(s.skills.iter().all(|skill| skill.id != removed));
    assert!(
        s.skills
            .iter()
            .all(|skill| !skill.prerequisites.contains(&removed))
    );
    assert!(s.quests.is_empty());
    assert!(s.sessions.is_empty());
    assert!(s.targets.is_empty());
    assert!(s.plans.is_empty());
    assert!(s.active.is_none());
    assert_eq!(s.character_xp_milli, 0);
    assert!(s.skills.iter().any(|skill| skill.id == kept));
    s.validate().unwrap();
    assert!(s.remove_skill(removed).is_err());
}

#[test]
fn long_dependency_chains_do_not_use_the_call_stack() {
    std::thread::Builder::new()
        .stack_size(128 * 1024)
        .spawn(|| {
            let mut state = GameState::default();
            let mut previous = Vec::new();
            for _ in 0..20_000 {
                let id = state.add_skill("Skill".into(), Domain::Mind, previous);
                previous = vec![id];
            }
            state.validate().unwrap();
            let last = state.skills.last().unwrap().id;
            state.skills[0].prerequisites.push(last);
            assert!(state.validate().is_err());
        })
        .unwrap()
        .join()
        .unwrap();
}

#[test]
fn planned_sessions_default_for_legacy_quests_and_validate() {
    for count in [0, 10_001] {
        let mut state = setup();
        let mut invalid = quest(&state, QuestKind::Daily);
        invalid.planned_sessions = count;
        assert!(state.create_quest(invalid.clone()).is_err());
        state.quests.push(invalid);
        assert!(state.validate().is_err());
    }
}

#[test]
fn study_sessions_continue_across_days_until_explicitly_completed() {
    let mut state = setup();
    let mut q = quest(&state, QuestKind::Daily);
    q.planned_sessions = 5;
    let id = q.id;
    state.create_quest(q).unwrap();
    let mut last = None;
    for index in 0..8 {
        let mut c = completion(id);
        c.day = day() + Duration::days(if index < 5 { 0 } else { 1 });
        c.at = c.day.and_hms_opt(12 + index % 5, 0, 0).unwrap().and_utc();
        c.finish_quest = false;
        state.complete(c.clone()).unwrap();
        assert_ne!(state.quests[0].status, Status::Completed);
        last = Some(c);
    }
    assert_eq!(state.sessions.len(), 8);
    assert_eq!(
        state.sessions.iter().map(|s| s.seconds).sum::<u32>(),
        200 * 60
    );
    assert_eq!(state.sessions.iter().filter(|s| s.day == day()).count(), 5);
    assert_eq!(
        state
            .sessions
            .iter()
            .filter(|s| s.day == day() + Duration::days(1))
            .count(),
        3
    );
    let xp = state.character_xp_milli;
    assert_eq!(state.complete(last.unwrap()).unwrap(), 0);
    assert_eq!(state.sessions.len(), 8);
    assert_eq!(state.character_xp_milli, xp);
    let mut final_session = completion(id);
    final_session.day = day() + Duration::days(2);
    final_session.finish_quest = true;
    state.complete(final_session).unwrap();
    assert_eq!(state.quests[0].status, Status::Completed);
    assert!(state.sessions.last().unwrap().completed_quest);
    state.validate().unwrap();
}

#[test]
fn planned_sessions_gate_completion_and_bonus_cannot_exceed_practice() {
    let mut state = setup();
    let mut q = quest(&state, QuestKind::Project);
    q.planned_sessions = 10;
    q.bonus_milli = 20_000;
    let id = q.id;
    state.create_quest(q).unwrap();
    let mut early = completion(id);
    early.finish_quest = true;
    assert!(state.complete(early).is_err());
    assert_eq!(state.quests[0].status, Status::Planned);
    assert_eq!(state.character_xp_milli, 0);
    for index in 0..9 {
        let mut partial = completion(id);
        partial.day = day();
        partial.at = day().and_hms_opt(8 + index, 0, 0).unwrap().and_utc();
        partial.finish_quest = false;
        state.complete(partial).unwrap();
        assert_ne!(state.quests[0].status, Status::Completed);
    }
    let reward = state.complete(completion(id)).unwrap();
    assert_eq!(state.quests[0].status, Status::Completed);
    // Seven full-rate sittings, then three inside the half-rate hour, plus the 20 XP bonus.
    assert_eq!(reward, 25_000);
    assert_eq!(state.character_xp_milli, 106_000);
    assert!(state.complete(completion(id)).is_err());
}

#[test]
fn mastery_requires_every_quest_and_partial_sessions_do_not_satisfy_it() {
    let mut state = setup();
    let skill = state.skills[0].id;
    let first = quest(&state, QuestKind::Daily);
    let first_id = first.id;
    let mut next = quest(&state, QuestKind::Daily);
    next.dependencies = vec![first_id];
    let next_id = next.id;
    state.create_quest(first).unwrap();
    state.create_quest(next).unwrap();
    let evidence = "Подтверждён полный набор результатов".to_string();
    let events = state.events.len();
    assert!(state.verify_mastery(skill, evidence.clone()).is_err());
    assert_eq!(state.events.len(), events);
    assert_eq!(state.skills[0].mastery, 0);
    let mut partial = completion(first_id);
    partial.finish_quest = false;
    state.complete(partial).unwrap();
    assert!(!state.quest_fulfilled(&state.quests[0]));
    assert!(!state.quest_unlocked(&state.quests[1]));
    assert!(state.verify_mastery(skill, evidence.clone()).is_err());
    state.complete(completion(first_id)).unwrap();
    assert!(state.quest_unlocked(&state.quests[1]));
    state.quests[1].status = Status::Paused;
    assert!(!state.skill_quests_completed(skill));
    assert!(state.verify_mastery(skill, evidence.clone()).is_err());
    for status in [Status::Cancelled, Status::Missed] {
        state.quests[1].status = status;
        assert!(state.skill_quests_completed(skill));
        state.verify_mastery(skill, evidence.clone()).unwrap();
        state.skills[0].mastery = 0;
        state.skills[0].evidence.clear();
    }
    state.quests[1].status = Status::Planned;
    assert!(!state.skill_quests_completed(skill));
    state.complete(completion(next_id)).unwrap();
    assert!(state.skill_quests_completed(skill));
    state.verify_mastery(skill, evidence.clone()).unwrap();
    assert_eq!(state.skills[0].mastery, 1);
    let added = quest(&state, QuestKind::Daily);
    state.create_quest(added).unwrap();
    assert!(
        state
            .verify_mastery(skill, "Новое подтверждение после добавления квеста".into())
            .is_err()
    );
    assert_eq!(
        state.skills[0].mastery, 1,
        "Existing verified evidence is retained"
    );
    state.validate().unwrap();
}

#[test]
fn recurring_habit_fulfils_a_prerequisite_after_seven_days() {
    let mut state = setup();
    let skill = state.skills[0].id;
    let habit = quest(&state, QuestKind::Habit);
    let habit_id = habit.id;
    let mut child = quest(&state, QuestKind::Daily);
    child.dependencies = vec![habit_id];
    let child_id = child.id;
    state.create_quest(habit).unwrap();
    state.create_quest(child).unwrap();
    assert!(!state.quest_unlocked(&state.quests[1]));
    state.complete(completion(habit_id)).unwrap();
    assert_ne!(state.quests[0].status, Status::Completed);
    assert!(!state.quest_fulfilled(&state.quests[0]));
    assert!(!state.quest_unlocked(&state.quests[1]));
    for index in 1..7 {
        let mut next = completion(habit_id);
        next.day = day() + Duration::days(index);
        state.complete(next).unwrap();
    }
    assert!(state.quest_fulfilled(&state.quests[0]));
    assert!(state.quest_unlocked(&state.quests[1]));
    assert!(
        state
            .verify_mastery(skill, "Достаточно подробное подтверждение".into())
            .is_err()
    );
    state.complete(completion(child_id)).unwrap();
    state
        .verify_mastery(skill, "Достаточно подробное подтверждение".into())
        .unwrap();
    state.validate().unwrap();
}

#[test]
fn mastery_is_once_without_quests_and_once_per_finished_quest() {
    let mut state = setup();
    let skill = state.skills[0].id;
    state
        .verify_mastery(skill, "Пустой навык открывает ветку один раз".into())
        .unwrap();
    assert!(
        state
            .verify_mastery(skill, "Повтор без нового квеста не считается".into())
            .is_err()
    );
    assert_eq!(state.skills[0].mastery, 1);
    for title in ["Первый квест", "Второй квест"] {
        let mut quest = quest(&state, QuestKind::Daily);
        quest.title = title.into();
        let id = quest.id;
        state.create_quest(quest).unwrap();
        state.complete(completion(id)).unwrap();
    }
    state
        .verify_mastery(skill, "Подтверждение после двух квестов".into())
        .unwrap();
    assert_eq!(state.skills[0].mastery, 2);
    assert!(
        state
            .verify_mastery(skill, "Лишнее подтверждение сверх квестов".into())
            .is_err()
    );
}

#[test]
fn diminishing_returns_are_shared_by_every_skill() {
    let mut state = setup();
    let mut first = quest(&state, QuestKind::Daily);
    first.estimate_minutes = 180;
    let first_id = first.id;
    state.create_quest(first).unwrap();
    let mut other = quest(&state, QuestKind::Daily);
    other.skill_id = state.skills[5].id;
    let other_id = other.id;
    state.create_quest(other).unwrap();
    let mut long = completion(first_id);
    long.seconds = 180 * 60;
    long.finish_quest = false;
    state.complete(long).unwrap();
    let mut next = completion(other_id);
    next.finish_quest = false;
    assert_eq!(state.complete(next).unwrap(), 5_000);
}

#[test]
fn strict_mode_rejects_typed_time() {
    let mut state = setup();
    state.settings.strict_mode = true;
    let quest_id = {
        let quest = quest(&state, QuestKind::Daily);
        let id = quest.id;
        state.create_quest(quest).unwrap();
        id
    };
    assert!(state.complete(completion(quest_id)).is_err());
    let session_id = Id::new_v4();
    state.active = Some(ActiveSession {
        id: session_id,
        quest_id,
        elapsed_seconds: 1500,
        running: false,
        strict: true,
        presence_confirmed: false,
        focus_confirmed: true,
        notes: String::new(),
    });
    let mut saved = completion(quest_id);
    saved.id = session_id;
    assert_eq!(state.complete(saved).unwrap(), 10_000);
    assert!(state.sessions[0].strict);
}

#[test]
fn passed_deadline_becomes_missed_until_returned() {
    let mut state = setup();
    let mut quest = quest(&state, QuestKind::Daily);
    quest.deadline = Some(day() - Duration::days(1));
    let id = quest.id;
    state.create_quest(quest).unwrap();
    state.settle_deadlines(day());
    assert_eq!(state.quests[0].status, Status::Missed);
    assert!(state.complete(completion(id)).is_err());
    state.set_quest_status(id, Status::Planned).unwrap();
    state.settle_deadlines(day());
    assert_eq!(state.quests[0].status, Status::Planned);
    assert!(state.quests[0].deadline.is_none());
    state.complete(completion(id)).unwrap();
    assert_eq!(state.quests[0].status, Status::Completed);
}

#[test]
fn weekly_goals_use_credited_time_and_ignore_tiny_sessions() {
    let mut state = setup();
    let quest_id = {
        let quest = quest(&state, QuestKind::Daily);
        let id = quest.id;
        state.create_quest(quest).unwrap();
        id
    };
    let mut tiny = completion(quest_id);
    tiny.seconds = 1;
    tiny.finish_quest = false;
    state.complete(tiny).unwrap();
    let week = GameState::week(day());
    let sessions = WeeklyTarget {
        id: Id::new_v4(),
        week,
        skill_id: state.skills[0].id,
        target: 1.0,
        weight: 1.0,
        unit: TargetUnit::Sessions,
    };
    assert_eq!(balance::actual(&state, &sessions), 0.0);
    let mut real = completion(quest_id);
    real.finish_quest = false;
    state.complete(real).unwrap();
    assert_eq!(balance::actual(&state, &sessions), 1.0);
    let minutes = WeeklyTarget {
        unit: TargetUnit::Minutes,
        target: 25.0,
        ..sessions.clone()
    };
    assert_eq!(balance::actual(&state, &minutes), 25.0 + 1.0 / 60.0);
}

#[test]
fn finishing_inside_the_estimate_is_accurate() {
    let mut state = setup();
    let quest_id = {
        let quest = quest(&state, QuestKind::Daily);
        let id = quest.id;
        state.create_quest(quest).unwrap();
        id
    };
    state.commit_plan(day(), &[quest_id]).unwrap();
    let mut fast = completion(quest_id);
    fast.seconds = 10 * 60;
    state.complete(fast).unwrap();
    let fast_score = discipline::calculate(&state, day()).precision;
    assert_eq!(fast_score, 1.0);
    let mut state = setup();
    let quest_id = {
        let quest = quest(&state, QuestKind::Daily);
        let id = quest.id;
        state.create_quest(quest).unwrap();
        id
    };
    state.commit_plan(day(), &[quest_id]).unwrap();
    let mut slow = completion(quest_id);
    slow.seconds = 50 * 60;
    state.complete(slow).unwrap();
    assert!((discipline::calculate(&state, day()).precision - 0.5).abs() < 1e-8);
}
