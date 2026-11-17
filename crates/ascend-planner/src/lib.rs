use ascend_core::*;
use chrono::{Duration, NaiveDate};

#[derive(Debug, Clone)]
pub struct Recommendation {
    pub title: String,
    pub explanation: String,
    pub suggested_minutes: u32,
    pub mental: f64,
    pub physical: f64,
    pub recovery: f64,
}
pub fn recommend(state: &GameState, today: NaiveDate) -> Recommendation {
    let check = state.checkins.iter().find(|c| c.day == today);
    let available = check.map_or(state.settings.daily_minutes, |c| c.available_minutes);
    let active_days: std::collections::HashSet<_> = state
        .sessions
        .iter()
        .filter(|s| s.day >= today - Duration::days(28) && s.day < today)
        .map(|s| s.day)
        .collect();
    let baseline = if active_days.is_empty() {
        available.min(90)
    } else {
        (state
            .sessions
            .iter()
            .filter(|s| active_days.contains(&s.day))
            .map(|s| u64::from(s.seconds))
            .sum::<u64>()
            / 60
            / active_days.len() as u64) as u32
    };
    let fatigue = check.map_or(30, |c| c.fatigue);
    let energy = check.map_or(60, |c| c.energy);
    let recent_fatigue = state
        .checkins
        .iter()
        .filter(|c| c.day >= today - Duration::days(7) && c.day <= today && c.fatigue >= 75)
        .count();
    let week = GameState::week(today);
    let prev = ascend_core::balance::development(state, week - Duration::days(7));
    let prev2 = ascend_core::balance::development(state, week - Duration::days(14));
    let calibrated = active_days.len() >= 7;
    let comfortable_week = |start: NaiveDate| {
        let entries: Vec<_> = state
            .checkins
            .iter()
            .filter(|c| c.day >= start && c.day < start + Duration::days(7))
            .collect();
        entries.len() >= 3
            && entries
                .iter()
                .all(|c| !c.unwell && c.fatigue < 60 && c.energy > 25)
    };
    let (title, why, minutes) = if check.is_some_and(|c| c.unwell)
        || fatigue >= 75
        || energy <= 25
        || recent_fatigue >= 3
    {
        (
            "Восстановление в приоритете",
            "Недомогание, мало энергии или высокая усталость. Сократите план; отдых сохраняет весь накопленный прогресс.",
            baseline.min(available) / 2,
        )
    } else if !calibrated {
        (
            "Неделя наблюдения",
            "Пока мало истории. Начните с комфортного объёма, без автоматического увеличения целей.",
            baseline.min(available),
        )
    } else if prev.is_some_and(|v| v > 80.0)
        && prev2.is_some_and(|v| v > 80.0)
        && comfortable_week(week - Duration::days(7))
        && comfortable_week(week - Duration::days(14))
    {
        (
            "Можно обсудить небольшой рост",
            "Две завершённые недели выше 80%, самочувствие комфортное. Это предложение; цели сами не изменятся.",
            (baseline * (100 + u32::from(state.settings.growth_percent.clamp(0, 15))) / 100)
                .min(available),
        )
    } else if prev.is_some_and(|v| v < 60.0) {
        (
            "Сделайте план легче",
            "Выполнение прошлой недели ниже 60%. Снизьте объём или пересмотрите приоритеты.",
            (baseline * 80 / 100).min(available),
        )
    } else {
        (
            "Сохраните комфортный темп",
            "Доступное время ограничивает план. Недельные приоритеты можно перераспределить при следующем обзоре.",
            baseline.min(available),
        )
    };
    Recommendation {
        title: title.into(),
        explanation: format!(
            "{why} Привычный объём: {baseline} мин, доступно: {available} мин. Правило планирования, не медицинская оценка."
        ),
        suggested_minutes: minutes,
        mental: minutes as f64 * energy as f64 / 100.0,
        physical: minutes as f64 * (100 - fatigue) as f64 / 100.0,
        recovery: fatigue as f64,
    }
}
pub fn propose(state: &GameState, today: NaiveDate) -> Vec<Id> {
    let rec = recommend(state, today);
    let mut candidates: Vec<_> = state
        .quests
        .iter()
        .filter(|q| {
            matches!(q.status, Status::Planned | Status::Paused | Status::Active)
                && state.quest_unlocked(q)
                && !state
                    .sessions
                    .iter()
                    .any(|s| s.quest_id == q.id && s.day == today)
        })
        .collect();
    candidates.sort_by(|a, b| {
        let score = |q: &Quest| {
            let urgency = q.deadline.map_or(0.0, |d| {
                let days = (d - today).num_days();
                if days <= 0 {
                    100.0
                } else {
                    40.0 / (days as f64 + 1.0)
                }
            });
            let lag = state
                .targets
                .iter()
                .find(|t| t.skill_id == q.skill_id && t.week == GameState::week(today))
                .map_or(0.0, |t| {
                    20.0 * (1.0 - (ascend_core::balance::actual(state, t) / t.target).min(1.0))
                });
            q.priority as f64 * 15.0 + urgency + lag
        };
        score(b)
            .total_cmp(&score(a))
            .then(a.created_at.cmp(&b.created_at))
    });
    let mut remaining = rec.suggested_minutes;
    let mut mental = rec.mental;
    let mut physical = rec.physical;
    let mut out = vec![];
    for q in candidates {
        let domain = state
            .skills
            .iter()
            .find(|s| s.id == q.skill_id)
            .map(|s| s.domain)
            .unwrap_or(Domain::Mind);
        let cost = q.estimate_minutes as f64 * q.difficulty;
        let mental_cost = if matches!(domain, Domain::Mind | Domain::Organization | Domain::Social)
        {
            cost * 0.6
        } else {
            0.0
        };
        let physical_cost = if domain == Domain::Body {
            cost * 0.6
        } else {
            0.0
        };
        if q.estimate_minutes <= remaining && mental_cost <= mental && physical_cost <= physical {
            out.push(q.id);
            remaining -= q.estimate_minutes;
            mental -= mental_cost;
            physical -= physical_cost;
        }
        if out.len() == 3 {
            break;
        }
    }
    out
}
#[derive(Debug, Clone)]
pub struct DayStats {
    pub day: NaiveDate,
    pub minutes: f64,
    pub xp: f64,
    pub fatigue: Option<u8>,
    pub discipline: Option<f64>,
}
pub fn history_span(state: &GameState, today: NaiveDate) -> i64 {
    let mut earliest = today - Duration::days(89);
    let floor = today - Duration::days(366 * 10);
    let created = state.created_at.date_naive();
    if created <= today && created < earliest {
        earliest = created;
    }
    for day in state
        .sessions
        .iter()
        .map(|session| session.day)
        .chain(state.plans.iter().map(|plan| plan.day))
        .chain(state.checkins.iter().map(|check| check.day))
        .chain(state.journal.iter().map(|entry| entry.day))
        .chain(
            state
                .routine_versions
                .iter()
                .map(|version| version.effective_from),
        )
        .chain(state.routine_days.iter().map(|record| record.day))
    {
        if day < earliest {
            earliest = day;
        }
    }
    if earliest < floor {
        earliest = floor;
    }
    (today - earliest).num_days() + 1
}
pub fn history(state: &GameState, today: NaiveDate, days: i64) -> Vec<DayStats> {
    let discipline = ascend_core::discipline::Calculator::new(state);
    let mut totals = std::collections::HashMap::new();
    for session in &state.sessions {
        let entry = totals.entry(session.day).or_insert((0.0, 0.0));
        entry.0 += session.seconds as f64 / 60.0;
        entry.1 += session.reward_milli as f64 / 1000.0;
    }
    let mut fatigue = std::collections::HashMap::new();
    for check in &state.checkins {
        fatigue.entry(check.day).or_insert(check.fatigue);
    }
    (0..days)
        .rev()
        .map(|i| {
            let day = today - Duration::days(i);
            DayStats {
                day,
                minutes: totals.get(&day).map_or(0.0, |entry| entry.0),
                xp: totals.get(&day).map_or(0.0, |entry| entry.1),
                fatigue: fatigue.get(&day).copied(),
                discipline: discipline.calculate(day).score,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn illness_never_increases_load() {
        let mut s = GameState::default();
        let today = NaiveDate::from_ymd_opt(2026, 11, 14).unwrap();
        s.checkins.push(CheckIn {
            day: today,
            energy: 90,
            fatigue: 10,
            focus: 90,
            available_minutes: 360,
            unwell: true,
        });
        let r = recommend(&s, today);
        assert!(r.suggested_minutes <= 45);
        assert!(propose(&s, today).is_empty());
    }
    #[test]
    fn no_history_does_not_recommend_six_hours() {
        let mut s = GameState::default();
        s.settings.daily_minutes = 360;
        let r = recommend(&s, NaiveDate::from_ymd_opt(2026, 11, 14).unwrap());
        assert!(r.suggested_minutes <= 90);
    }
    fn simulated(percentage: u32, fatigue: u8) -> (GameState, NaiveDate) {
        let today = NaiveDate::from_ymd_opt(2026, 11, 16).unwrap();
        let mut s = GameState::default();
        s.starter_skills();
        let skill = s.skills[0].id;
        for i in (1..=14).rev() {
            let day = today - Duration::days(i);
            let id = Id::new_v4();
            s.create_quest(Quest {
                id,
                title: "Ежедневная практика".into(),
                outcome: "Проверенный результат".into(),
                skill_id: skill,
                kind: QuestKind::Daily,
                priority: 3,
                estimate_minutes: 50,
                planned_sessions: 1,
                difficulty: 1.0,
                bonus_milli: 0,
                deadline: None,
                dependencies: vec![],
                steps: vec![],
                status: Status::Planned,
                created_at: chrono::Utc::now() - Duration::days(i),
            })
            .unwrap();
            s.commit_plan(day, &[id]).unwrap();
            s.complete(Completion {
                id: Id::new_v4(),
                quest_id: id,
                seconds: 30 * percentage,
                result: "Решение с тестами".into(),
                finish_quest: true,
                day,
                at: chrono::Utc::now() - Duration::days(i),
                utc_offset_seconds: 10800,
            })
            .unwrap();
            s.checkins.push(CheckIn {
                day,
                energy: 85,
                fatigue,
                focus: 80,
                available_minutes: 90,
                unwell: false,
            });
        }
        for i in [7, 14] {
            s.targets.push(WeeklyTarget {
                id: Id::new_v4(),
                week: today - Duration::days(i),
                skill_id: skill,
                target: 350.0,
                weight: 1.0,
                unit: TargetUnit::Minutes,
            });
        }
        s.checkins.push(CheckIn {
            day: today,
            energy: 85,
            fatigue: 20,
            focus: 80,
            available_minutes: 360,
            unwell: false,
        });
        s.validate().unwrap();
        (s, today)
    }
    #[test]
    fn two_comfortable_successful_weeks_only_offer_configured_growth() {
        let (s, day) = simulated(100, 20);
        let r = recommend(&s, day);
        assert_eq!(r.suggested_minutes, 55);
        assert!(r.title.contains("рост"));
        assert_eq!(s.targets[0].target, 350.0);
    }
    #[test]
    fn poor_completion_reduces_plan_instead_of_removing_progress() {
        let (s, day) = simulated(40, 20);
        let xp = s.character_xp_milli;
        let r = recommend(&s, day);
        assert_eq!(r.suggested_minutes, 16);
        assert!(r.title.contains("легче"));
        assert_eq!(s.character_xp_milli, xp);
    }
    #[test]
    fn fatigued_history_prevents_growth_even_after_success() {
        let (s, day) = simulated(100, 80);
        let r = recommend(&s, day);
        assert!(r.suggested_minutes <= 25);
        assert!(r.title.contains("Восстановление"));
    }
    #[test]
    fn suggested_plan_respects_time_and_three_commitment_limit() {
        let (mut s, day) = simulated(100, 20);
        for _ in 0..10 {
            s.create_quest(Quest {
                id: Id::new_v4(),
                title: "Небольшая практика".into(),
                outcome: "Результат".into(),
                skill_id: s.skills[0].id,
                kind: QuestKind::Daily,
                priority: 2,
                estimate_minutes: 10,
                planned_sessions: 1,
                difficulty: 1.0,
                bonus_milli: 0,
                deadline: None,
                dependencies: vec![],
                steps: vec![],
                status: Status::Planned,
                created_at: chrono::Utc::now(),
            })
            .unwrap();
        }
        let ids = propose(&s, day);
        assert_eq!(ids.len(), 3);
        assert!(
            ids.iter()
                .map(|id| s
                    .quests
                    .iter()
                    .find(|q| q.id == *id)
                    .unwrap()
                    .estimate_minutes)
                .sum::<u32>()
                <= recommend(&s, day).suggested_minutes
        );
    }
    #[test]
    fn historical_chart_keeps_unsorted_session_totals_and_missing_days() {
        let (mut state, today) = simulated(100, 20);
        state.sessions.reverse();
        let points = history(&state, today, 16);
        assert_eq!(points.len(), 16);
        assert_eq!(points[0].day, today - Duration::days(15));
        assert_eq!(points[0].minutes, 0.0);
        assert_eq!(points[0].xp, 0.0);
        assert_eq!(points[0].fatigue, None);
        assert_eq!(points[0].discipline, None);
        for point in &points[1..15] {
            assert_eq!(point.minutes, 50.0);
            assert_eq!(point.xp, 20.0);
            assert_eq!(point.fatigue, Some(20));
            assert!((point.discipline.unwrap() - 100.0).abs() < 1e-8);
        }
        assert_eq!(points[15].minutes, 0.0);
        assert_eq!(points[15].fatigue, Some(20));
    }
    #[test]
    fn routine_only_history_is_included_in_the_chart_span() {
        let today = NaiveDate::from_ymd_opt(2026, 11, 16).unwrap();
        let mut state = GameState {
            created_at: today.and_hms_opt(0, 0, 0).unwrap().and_utc(),
            ..GameState::default()
        };
        state
            .set_routine(vec!["Read".into()], true, today - Duration::days(365))
            .unwrap();
        assert_eq!(history_span(&state, today), 366);
    }
}
