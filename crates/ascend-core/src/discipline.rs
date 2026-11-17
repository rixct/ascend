use crate::*;
use chrono::{Duration, NaiveDate};
use std::collections::{BTreeMap, HashMap, HashSet};
#[derive(Debug, Clone, Default)]
pub struct Discipline {
    pub score: Option<f64>,
    pub commitments: f64,
    pub stability: f64,
    pub precision: f64,
    pub observed_days: usize,
    pub preliminary: bool,
    pub routine: Option<f64>,
}
/// Reuses journal indexes when calculating a chart with many historical dates.
pub struct Calculator<'a> {
    state: &'a GameState,
    plans: BTreeMap<NaiveDate, &'a DailyPlan>,
    work: HashMap<Id, Vec<(NaiveDate, u64)>>,
    habits: HashSet<Id>,
    used_days: HashSet<NaiveDate>,
}
impl<'a> Calculator<'a> {
    pub fn new(state: &'a GameState) -> Self {
        let mut work: HashMap<Id, Vec<(NaiveDate, u64)>> = HashMap::new();
        for session in &state.sessions {
            work.entry(session.quest_id)
                .or_default()
                .push((session.day, u64::from(session.seconds)));
        }
        for entries in work.values_mut() {
            entries.sort_unstable_by_key(|entry| entry.0);
            let mut total = 0_u64;
            for (_, seconds) in entries {
                total = total.saturating_add(*seconds);
                *seconds = total;
            }
        }
        Self {
            state,
            plans: state.plans.iter().map(|plan| (plan.day, plan)).collect(),
            work,
            habits: state
                .quests
                .iter()
                .filter(|q| q.kind == QuestKind::Habit)
                .map(|q| q.id)
                .collect(),
            used_days: state
                .routine_days
                .iter()
                .map(|r| r.day)
                .chain(state.sessions.iter().map(|s| s.day))
                .chain(state.plans.iter().map(|p| p.day))
                .chain(state.checkins.iter().map(|c| c.day))
                .chain(state.journal.iter().map(|j| j.day))
                .collect(),
        }
    }
    fn seconds(&self, quest: Id, day: NaiveDate) -> u64 {
        let Some(entries) = self.work.get(&quest) else {
            return 0;
        };
        let end = entries.partition_point(|(date, _)| *date <= day);
        let total = end.checked_sub(1).map_or(0, |index| entries[index].1);
        // A habit is a new promise every day; past repetitions do not make today's estimate late.
        if self.habits.contains(&quest) {
            let start = entries.partition_point(|(date, _)| *date < day);
            total - start.checked_sub(1).map_or(0, |index| entries[index].1)
        } else {
            total
        }
    }
    pub fn calculate(&self, today: NaiveDate) -> Discipline {
        let state = self.state;
        // Incomplete current-day promises become due tomorrow; completed ones are visible now.
        let start = today
            .checked_sub_signed(Duration::days(27))
            .unwrap_or(NaiveDate::MIN);
        let plans: Vec<_> = self
            .plans
            .range(start..=today)
            .map(|(_, plan)| *plan)
            .filter(|p| !p.rest)
            .collect();
        let mut weight = 0.0;
        let mut done = 0.0;
        let mut days = 0;
        let mut stable = 0.0;
        let mut precision = 0.0;
        let mut estimates = 0;
        for p in &plans {
            let due: Vec<_> = p
                .items
                .iter()
                .filter(|i| !i.excused && (p.day < today || i.completed))
                .collect();
            if due.is_empty() {
                continue;
            }
            days += 1;
            let mut all = true;
            for i in due {
                weight += i.weight;
                if i.completed {
                    done += i.weight;
                } else {
                    all = false;
                }
                if i.completed {
                    // All work up to the commitment counts. Finishing inside the estimate is accurate;
                    // only time beyond it lowers the score.
                    let actual = self.seconds(i.quest_id, p.day) as f64 / 60.0;
                    let estimate = i.estimate_minutes as f64;
                    if actual > 0.0 && estimate > 0.0 {
                        precision += if actual <= estimate {
                            1.0
                        } else {
                            estimate / actual
                        };
                        estimates += 1;
                    }
                }
            }
            if all {
                stable += 1.0;
            }
        }
        let c = if weight > 0.0 { done / weight } else { 0.0 };
        let s = if days > 0 { stable / days as f64 } else { 0.0 };
        let p = if estimates > 0 {
            precision / estimates as f64
        } else {
            0.0
        };
        // Without timed sessions the accuracy term is omitted, so a kept promise can still reach 100.
        let plan_score = (weight > 0.0).then_some(
            100.0
                * if estimates > 0 {
                    0.7 * c + 0.2 * s + 0.1 * p
                } else {
                    (0.7 * c + 0.2 * s) / 0.9
                },
        );
        let mut routine_sum = 0.0;
        let mut routine_days = 0;
        let mut observed: std::collections::BTreeSet<_> = plans.iter().map(|p| p.day).collect();
        // Finished days only. Today is still in progress, matching an open plan.
        // A day the app was never opened is skipped. Four items fill the routine share;
        // a single checkbox is a quarter of that share.
        for offset in 1..=28 {
            let Some(day) = today.checked_sub_signed(Duration::days(offset)) else {
                continue;
            };
            let Some(version) = state.routine_on(day) else {
                continue;
            };
            if !self.used_days.contains(&day) {
                continue;
            }
            routine_days += 1;
            let ratio = state.routine_completed(day).len() as f64 / version.items.len() as f64;
            let size = (version.items.len() as f64 / 4.0).min(1.0);
            routine_sum += ratio * size;
            observed.insert(day);
        }
        let routine = (routine_days > 0).then(|| routine_sum / routine_days as f64);
        // Plans alone can reach 100. A routine contributes at most 40, so skipping plans is not a perfect score.
        let score = match (plan_score, routine) {
            (Some(plans), Some(routine)) => Some(0.6 * plans + 40.0 * routine),
            (Some(plans), None) => Some(plans),
            (None, Some(routine)) => Some(40.0 * routine),
            (None, None) => None,
        };
        Discipline {
            score,
            routine,
            commitments: c,
            stability: s,
            precision: p,
            observed_days: observed.len(),
            preliminary: observed.len() < 7,
        }
    }
}

pub fn calculate(state: &GameState, today: NaiveDate) -> Discipline {
    Calculator::new(state).calculate(today)
}
