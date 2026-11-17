use crate::*;
#[cfg(test)]
use chrono::Duration;
use chrono::NaiveDate;
use std::collections::HashSet;

type Result<T> = std::result::Result<T, EngineError>;

const MAX_ITEMS: usize = 12;
const MAX_TITLE: usize = 100;
fn invalid() -> EngineError {
    EngineError::Invalid(
        "Укажите от 1 до 12 уникальных пунктов рутины длиной до 100 символов".into(),
    )
}
fn valid_titles<'a>(mut titles: impl Iterator<Item = &'a str>) -> bool {
    let mut unique = HashSet::new();
    titles.all(|title| {
        !title.trim().is_empty()
            && title == title.trim()
            && title.chars().count() <= MAX_TITLE
            && unique.insert(title.to_lowercase())
    })
}

impl GameState {
    pub fn routine_version_on(&self, day: NaiveDate) -> Option<&RoutineVersion> {
        let end = self
            .routine_versions
            .partition_point(|v| v.effective_from <= day);
        end.checked_sub(1)
            .map(|index| &self.routine_versions[index])
    }
    pub fn routine_on(&self, day: NaiveDate) -> Option<&RoutineVersion> {
        self.routine_version_on(day).filter(|v| v.enabled)
    }
    pub fn routine_completed(&self, day: NaiveDate) -> &[Id] {
        self.routine_days
            .binary_search_by_key(&day, |v| v.day)
            .map(|index| self.routine_days[index].completed.as_slice())
            .unwrap_or(&[])
    }
    pub fn set_routine(
        &mut self,
        titles: Vec<String>,
        enabled: bool,
        today: NaiveDate,
    ) -> Result<NaiveDate> {
        let titles: Vec<_> = titles.into_iter().map(|v| v.trim().to_string()).collect();
        if titles.is_empty() {
            return self.clear_routine(today);
        }
        if !(1..=MAX_ITEMS).contains(&titles.len())
            || !valid_titles(titles.iter().map(String::as_str))
        {
            return Err(invalid());
        }
        // The same list already runs today, including every later day, so this is a no-op.
        if self
            .routine_versions
            .last()
            .is_some_and(|last| last.effective_from <= today)
            && self.routine_version_on(today).is_some_and(|current| {
                current.enabled == enabled
                    && current
                        .items
                        .iter()
                        .map(|item| &item.title)
                        .eq(titles.iter())
            })
        {
            return Ok(today);
        }
        let previous = self.routine_versions.last();
        let items = titles
            .into_iter()
            .map(|title| {
                let id = previous
                    .and_then(|v| {
                        v.items
                            .iter()
                            .find(|i| i.title.to_lowercase() == title.to_lowercase())
                    })
                    .map_or_else(Id::new_v4, |i| i.id);
                RoutineItem { id, title }
            })
            .collect();
        self.routine_versions
            .retain(|version| version.effective_from < today);
        self.routine_versions.push(RoutineVersion {
            effective_from: today,
            enabled,
            items,
        });
        self.prune_checks(today);
        self.event("routine_updated", format!("Рутина обновлена с {today}"));
        Ok(today)
    }
    /// A list scheduled for a later day is the routine the person is editing now.
    /// Bring it forward so today's checkboxes apply to those tasks. Earlier days stay put.
    pub fn adopt_current_list(&mut self, today: NaiveDate) -> bool {
        let Some(last) = self.routine_versions.last().cloned() else {
            return false;
        };
        if last.effective_from <= today {
            return false;
        }
        self.routine_versions
            .retain(|version| version.effective_from < today);
        self.routine_versions.push(RoutineVersion {
            effective_from: today,
            enabled: last.enabled,
            items: last.items,
        });
        self.prune_checks(today);
        true
    }
    fn prune_checks(&mut self, today: NaiveDate) {
        let Some(index) = self
            .routine_days
            .iter()
            .position(|record| record.day == today)
        else {
            return;
        };
        let allowed: HashSet<_> = self
            .routine_on(today)
            .map(|version| version.items.iter().map(|item| item.id).collect())
            .unwrap_or_default();
        self.routine_days[index]
            .completed
            .retain(|id| allowed.contains(id));
        if self.routine_days[index].completed.is_empty() {
            self.routine_days.remove(index);
        }
    }
    fn clear_routine(&mut self, today: NaiveDate) -> Result<NaiveDate> {
        if self.routine_versions.is_empty() {
            return Err(invalid());
        }
        if self.routine_version_on(today).is_none_or(|version| {
            !version.enabled && version.items.is_empty() && version.effective_from == today
        }) && self
            .routine_versions
            .last()
            .is_some_and(|last| last.effective_from <= today)
        {
            return Ok(today);
        }
        self.routine_versions
            .retain(|version| version.effective_from < today);
        self.routine_versions.push(RoutineVersion {
            effective_from: today,
            enabled: false,
            items: vec![],
        });
        self.prune_checks(today);
        self.event("routine_updated", format!("Рутина обновлена с {today}"));
        Ok(today)
    }
    pub fn set_routine_item(
        &mut self,
        day: NaiveDate,
        today: NaiveDate,
        id: Id,
        completed: bool,
    ) -> Result<()> {
        if day != today {
            return Err(EngineError::Invalid(
                "Можно отмечать рутину только за сегодняшний день".into(),
            ));
        }
        if !self
            .routine_on(day)
            .is_some_and(|v| v.items.iter().any(|i| i.id == id))
        {
            return Err(EngineError::Invalid(
                "Пункт сегодняшней рутины не найден".into(),
            ));
        }
        let index = match self.routine_days.binary_search_by_key(&day, |v| v.day) {
            Ok(index) => index,
            Err(index) => {
                if !completed {
                    return Ok(());
                }
                self.routine_days.insert(
                    index,
                    RoutineDay {
                        day,
                        completed: vec![],
                    },
                );
                index
            }
        };
        let marked = &mut self.routine_days[index].completed;
        if completed {
            if !marked.contains(&id) {
                marked.push(id);
            }
        } else {
            marked.retain(|v| *v != id);
        }
        Ok(())
    }
    pub(crate) fn validate_routine(&self) -> Result<()> {
        if !self
            .routine_versions
            .windows(2)
            .all(|v| v[0].effective_from < v[1].effective_from)
            || !self.routine_days.windows(2).all(|v| v[0].day < v[1].day)
        {
            return Err(invalid());
        }
        for version in &self.routine_versions {
            if version.items.is_empty() {
                if version.enabled {
                    return Err(invalid());
                }
                continue;
            }
            let mut ids = HashSet::new();
            if !(1..=MAX_ITEMS).contains(&version.items.len())
                || !valid_titles(version.items.iter().map(|v| v.title.as_str()))
                || !version
                    .items
                    .iter()
                    .all(|v| !v.id.is_nil() && ids.insert(v.id))
            {
                return Err(invalid());
            }
        }
        for record in &self.routine_days {
            let Some(version) = self.routine_on(record.day) else {
                return Err(invalid());
            };
            let mut ids = HashSet::new();
            if !record
                .completed
                .iter()
                .all(|id| ids.insert(*id) && version.items.iter().any(|v| v.id == *id))
            {
                return Err(invalid());
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn day() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 11, 15).unwrap()
    }
    fn titles() -> Vec<String> {
        vec!["Plan the day".into(), "Read".into()]
    }
    #[test]
    fn checks_are_per_day_idempotent_and_do_not_award_xp() {
        let mut s = GameState::default();
        assert_eq!(s.set_routine(titles(), true, day()).unwrap(), day());
        let id = s.routine_on(day()).unwrap().items[0].id;
        s.set_routine_item(day(), day(), id, true).unwrap();
        s.set_routine_item(day(), day(), id, true).unwrap();
        assert_eq!(s.routine_completed(day()), &[id]);
        assert_eq!(s.character_xp_milli, 0);
        assert!(s.routine_completed(day() + Duration::days(1)).is_empty());
        assert!(
            s.set_routine_item(day(), day() + Duration::days(1), id, false)
                .is_err()
        );
        assert!(
            s.set_routine_item(day(), day(), Id::new_v4(), true)
                .is_err()
        );
        s.set_routine_item(day(), day(), id, false).unwrap();
        assert!(s.routine_completed(day()).is_empty());
        s.validate().unwrap();
    }
    #[test]
    fn editing_updates_today_and_keeps_an_earlier_day() {
        let mut s = GameState::default();
        s.set_routine(titles(), true, day()).unwrap();
        let yesterday = day() - Duration::days(1);
        s.routine_versions[0].effective_from = yesterday;
        let old_id = s.routine_on(yesterday).unwrap().items[0].id;
        s.routine_days.push(RoutineDay {
            day: yesterday,
            completed: vec![old_id],
        });
        assert_eq!(
            s.set_routine(vec!["New item".into()], true, day()).unwrap(),
            day()
        );
        assert_eq!(s.routine_on(yesterday).unwrap().items[0].id, old_id);
        assert_eq!(s.routine_completed(yesterday), &[old_id]);
        assert_eq!(s.routine_on(day()).unwrap().items[0].title, "New item");
        assert_eq!(
            s.routine_on(day() + Duration::days(1)).unwrap().items[0].title,
            "New item"
        );
        assert!(s.routine_completed(day() + Duration::days(1)).is_empty());
        let id = s.routine_on(day()).unwrap().items[0].id;
        s.set_routine_item(day(), day(), id, true).unwrap();
        s.set_routine(vec!["New item".into()], false, day())
            .unwrap();
        assert!(s.routine_on(day()).is_none());
        assert!(s.routine_on(day() + Duration::days(1)).is_none());
        assert!(s.routine_completed(day()).is_empty());
        assert_eq!(s.routine_completed(yesterday), &[old_id]);
        s.validate().unwrap();
    }
    #[test]
    fn reordering_keeps_ids_on_today() {
        let mut s = GameState::default();
        s.set_routine(titles(), true, day()).unwrap();
        let ids: Vec<_> = s
            .routine_on(day())
            .unwrap()
            .items
            .iter()
            .map(|item| item.id)
            .collect();
        assert_eq!(
            s.set_routine(vec!["Read".into(), "Plan the day".into()], true, day())
                .unwrap(),
            day()
        );
        let today = s.routine_on(day()).unwrap();
        assert_eq!(today.items[0].id, ids[1]);
        assert_eq!(today.items[0].title, "Read");
        assert_eq!(today.items[1].id, ids[0]);
        s.validate().unwrap();
    }
    #[test]
    fn clearing_the_last_item_turns_the_list_off_today() {
        let mut s = GameState::default();
        assert!(s.set_routine(vec![], true, day()).is_err());
        s.set_routine(titles(), true, day()).unwrap();
        let id = s.routine_on(day()).unwrap().items[0].id;
        s.set_routine_item(day(), day(), id, true).unwrap();
        assert_eq!(s.set_routine(vec![], false, day()).unwrap(), day());
        assert!(s.routine_on(day()).is_none());
        assert!(s.routine_completed(day()).is_empty());
        s.validate().unwrap();
    }
    #[test]
    fn a_future_list_can_be_checked_today_and_resets_tomorrow() {
        let mut s = GameState::default();
        s.set_routine(vec!["Old".into()], true, day()).unwrap();
        s.routine_versions.push(RoutineVersion {
            effective_from: day() + Duration::days(1),
            enabled: true,
            items: vec![RoutineItem {
                id: Id::new_v4(),
                title: "New".into(),
            }],
        });
        assert!(s.adopt_current_list(day()));
        let id = s.routine_on(day()).unwrap().items[0].id;
        assert_eq!(s.routine_on(day()).unwrap().items[0].title, "New");
        s.set_routine_item(day(), day(), id, true).unwrap();
        assert_eq!(s.routine_completed(day()), &[id]);
        assert!(s.routine_completed(day() + Duration::days(1)).is_empty());
        assert_eq!(
            s.routine_on(day() + Duration::days(1)).unwrap().items[0].id,
            id
        );
        assert!(!s.adopt_current_list(day()));
        s.validate().unwrap();
    }
    #[test]
    fn routine_waits_for_a_finished_day_and_ignores_unopened_days() {
        let mut s = GameState::default();
        assert_eq!(discipline::calculate(&s, day()).score, None);
        s.set_routine(titles(), true, day()).unwrap();
        let items = s.routine_on(day()).unwrap().items.clone();
        s.set_routine_item(day(), day(), items[0].id, true).unwrap();
        s.set_routine_item(day(), day(), items[1].id, true).unwrap();
        // Today is still open, so checking the list does not move the score yet.
        assert_eq!(discipline::calculate(&s, day()).score, None);
        let yesterday = day() - Duration::days(1);
        s.routine_versions[0].effective_from = yesterday;
        s.routine_days[0].day = yesterday;
        // Two items fill half of the routine share. 40 × 0.5 = 20.
        assert!((discipline::calculate(&s, day()).score.unwrap() - 20.0).abs() < 1e-8);
        // The day before yesterday was never opened, so it is not a zero.
        assert!(
            (discipline::calculate(&s, day() + Duration::days(2))
                .score
                .unwrap()
                - 20.0)
                .abs()
                < 1e-8
        );
        assert_eq!(
            discipline::calculate(&s, yesterday).score,
            None,
            "The first routine day has no earlier day to judge"
        );
    }
    #[test]
    fn routine_and_plans_combine_without_punishing_a_new_list() {
        let mut s = GameState::default();
        s.plans.push(DailyPlan {
            day: day(),
            created_at: chrono::Utc::now(),
            items: vec![PlanItem {
                quest_id: Id::new_v4(),
                weight: 1.0,
                estimate_minutes: 25,
                completed: true,
                excused: false,
            }],
            rest: false,
            reason: String::new(),
        });
        // A kept promise with no timer still reaches 100. Accuracy is omitted until time exists.
        assert!((discipline::calculate(&s, day()).score.unwrap() - 100.0).abs() < 1e-8);
        s.set_routine(titles(), true, day()).unwrap();
        assert!(
            (discipline::calculate(&s, day()).score.unwrap() - 100.0).abs() < 1e-8,
            "Creating today's routine must not cut a finished plan"
        );
        let yesterday = day() - Duration::days(1);
        s.routine_versions[0].effective_from = yesterday;
        let items = s.routine_on(yesterday).unwrap().items.clone();
        s.routine_days.push(RoutineDay {
            day: yesterday,
            completed: vec![items[0].id],
        });
        // Plan stays 100 and is weighted 60. One of two items is 0.25 of the routine share: 40 × 0.25 = 10.
        assert!((discipline::calculate(&s, day()).score.unwrap() - 70.0).abs() < 1e-8);
    }
    #[test]
    fn invalid_data_is_rejected_without_rewriting_history() {
        let mut s = GameState::default();
        for invalid_titles in [
            vec![],
            vec![" ".into()],
            vec!["Read".into(), " read ".into()],
            vec!["a".repeat(101)],
            vec!["x".into(); 13],
        ] {
            assert!(s.set_routine(invalid_titles, true, day()).is_err());
            assert!(s.routine_versions.is_empty());
        }
        s.set_routine(titles(), true, day()).unwrap();
        s.routine_days.push(RoutineDay {
            day: day(),
            completed: vec![Id::new_v4()],
        });
        assert!(s.validate().is_err());
    }
}
