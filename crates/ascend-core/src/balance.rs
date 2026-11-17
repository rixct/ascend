use crate::*;
use chrono::NaiveDate;
pub fn actual(state: &GameState, t: &WeeklyTarget) -> f64 {
    let sessions: Vec<_> = state
        .sessions
        .iter()
        .filter(|s| s.skill_id == t.skill_id && (0..7).contains(&(s.day - t.week).num_days()))
        .collect();
    let counts = |session: &&Session| session.credited_seconds >= 5 * 60;
    match t.unit {
        // The same minutes XP credited, so a 24-hour note cannot close a goal XP ignored.
        TargetUnit::Minutes => sessions
            .iter()
            .map(|s| s.credited_seconds as f64 / 60.0)
            .sum(),
        TargetUnit::Sessions => sessions.iter().filter(|session| counts(session)).count() as f64,
        TargetUnit::Days => {
            let days: std::collections::HashSet<_> = sessions
                .iter()
                .filter(|session| counts(session))
                .map(|s| s.day)
                .collect();
            days.len() as f64
        }
        TargetUnit::Milestones => sessions
            .iter()
            .filter(|s| {
                s.completed_quest
                    && state
                        .quests
                        .iter()
                        .any(|q| q.id == s.quest_id && q.kind == QuestKind::Project)
            })
            .count() as f64,
    }
}
pub fn development(state: &GameState, week: NaiveDate) -> Option<f64> {
    let targets: Vec<_> = state
        .targets
        .iter()
        .filter(|t| t.week == week && t.target > 0.0 && t.weight > 0.0)
        .collect();
    let weight_of = |t: &&WeeklyTarget| t.weight.min(10.0);
    let weight: f64 = targets.iter().map(weight_of).sum();
    (weight > 0.0).then(|| {
        100.0
            * targets
                .iter()
                .map(|t| weight_of(t) * (actual(state, t) / t.target).clamp(0.0, 1.0))
                .sum::<f64>()
            / weight
    })
}
