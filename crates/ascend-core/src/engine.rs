use crate::*;
use chrono::{DateTime, Datelike, NaiveDate, Utc, Weekday};
use std::collections::{HashMap, HashSet};

#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("Объект не найден")]
    Missing,
    #[error("{0}")]
    Invalid(String),
    #[error("Сначала выполните зависимости")]
    Locked,
}
type Result<T> = std::result::Result<T, EngineError>;
fn invalid(s: &str) -> EngineError {
    EngineError::Invalid(s.into())
}
fn clean_steps(steps: Vec<QuestStep>) -> Result<Vec<QuestStep>> {
    let mut seen = HashSet::new();
    let mut cleaned = Vec::new();
    for mut step in steps {
        let title = step.title.trim();
        if title.is_empty() {
            continue;
        }
        if title.chars().count() > 120 {
            return Err(invalid("Подпункт слишком длинный"));
        }
        if !seen.insert(step.id) {
            return Err(invalid("Подпункты не должны повторяться"));
        }
        step.title = title.to_string();
        cleaned.push(step);
        if cleaned.len() > 24 {
            return Err(invalid("Не больше 24 подпунктов"));
        }
    }
    Ok(cleaned)
}
fn steps_are_clean(steps: &[QuestStep]) -> bool {
    matches!(clean_steps(steps.to_vec()), Ok(cleaned) if cleaned == steps)
}
fn normalize_quest(q: &mut Quest) -> Result<()> {
    q.title = q.title.trim().to_string();
    q.outcome = q.outcome.trim().to_string();
    q.steps = clean_steps(std::mem::take(&mut q.steps))?;
    if q.title.is_empty() {
        return Err(invalid("Укажите название"));
    }
    if q.kind == QuestKind::Habit {
        if q.planned_sessions > 365 {
            return Err(invalid("Привычка закрепляется от 7 до 365 дней"));
        }
        q.planned_sessions = q.planned_sessions.max(7);
    } else if !(1..=10_000).contains(&q.planned_sessions) {
        return Err(invalid("Количество сессий должно быть от 1 до 10000"));
    }
    if q.estimate_minutes == 0
        || q.estimate_minutes > 1440
        || !(0.5..=2.0).contains(&q.difficulty)
        || !(1..=3).contains(&q.priority)
    {
        return Err(invalid("Проверьте время, сложность и приоритет"));
    }
    Ok(())
}

#[derive(Debug, Clone)]
pub struct Completion {
    pub id: Id,
    pub quest_id: Id,
    pub seconds: u32,
    pub result: String,
    pub finish_quest: bool,
    pub day: NaiveDate,
    pub at: DateTime<Utc>,
    pub utc_offset_seconds: i32,
}
impl GameState {
    pub fn create_quest(&mut self, mut q: Quest) -> Result<()> {
        normalize_quest(&mut q)?;
        if self.quests.iter().any(|old| old.id == q.id) {
            return Err(invalid("Квест уже существует"));
        }
        self.planning_error(&q)?;
        self.event(
            "quest_created",
            format!(
                "Создано: {}. Оценка, вес, сложность и бонус зафиксированы.",
                q.title
            ),
        );
        self.quests.push(q);
        Ok(())
    }
    pub fn update_quest(&mut self, id: Id, mut next: Quest) -> Result<()> {
        let index = self
            .quests
            .iter()
            .position(|quest| quest.id == id)
            .ok_or(EngineError::Missing)?;
        next.id = id;
        next.status = self.quests[index].status;
        next.created_at = self.quests[index].created_at;
        normalize_quest(&mut next)?;
        if next.skill_id != self.quests[index].skill_id
            && self.sessions.iter().any(|session| session.quest_id == id)
        {
            return Err(invalid(
                "Навык квеста с сохранёнными сессиями менять нельзя",
            ));
        }
        self.planning_error(&next)?;
        let previous = self.quests[index].clone();
        self.quests[index] = next;
        if let Err(error) = self.validate() {
            self.quests[index] = previous;
            return Err(error);
        }
        Ok(())
    }
    fn planning_error(&self, q: &Quest) -> Result<()> {
        if q.dependencies.contains(&q.id) {
            return Err(invalid("Квест не может зависеть от самого себя"));
        }
        if !self.skills.iter().any(|s| s.id == q.skill_id)
            || q.dependencies
                .iter()
                .any(|id| !self.quests.iter().any(|parent| parent.id == *id))
        {
            return Err(EngineError::Missing);
        }
        if (q.kind != QuestKind::Project && q.bonus_milli != 0) || q.bonus_milli > 40000 {
            return Err(invalid(
                "Бонус этапа: от 0 до 40 XP; у задач и привычек бонуса нет",
            ));
        }
        if self
            .skills
            .iter()
            .any(|s| s.id == q.skill_id && s.domain == Domain::Recovery)
            && q.kind != QuestKind::Habit
        {
            return Err(invalid(
                "Восстановление учитывается как поддерживающая привычка с фиксированной наградой",
            ));
        }
        if q.kind == QuestKind::Project && q.bonus_milli > 0 {
            let project_roots = self.project_root_map(Some(q));
            let roots = project_roots
                .get(&q.id)
                .ok_or_else(|| invalid("Обнаружен цикл зависимостей"))?;
            if roots.len() > 1 {
                return Err(invalid(
                    "Этап с бонусом должен принадлежать одной цепочке проекта",
                ));
            }
            let allocated: u64 = self
                .quests
                .iter()
                .filter(|old| {
                    old.id != q.id
                        && old.kind == QuestKind::Project
                        && project_roots
                            .get(&old.id)
                            .is_some_and(|old_roots| !old_roots.is_disjoint(roots))
                })
                .map(|old| old.bonus_milli)
                .sum();
            if allocated + q.bonus_milli > 40000 {
                return Err(invalid(
                    "Общий бонус связанных этапов проекта ограничен 40 XP. Распределите его заранее; практика продолжает приносить XP",
                ));
            }
        }
        Ok(())
    }
    fn project_root_map(&self, replacement: Option<&Quest>) -> HashMap<Id, HashSet<Id>> {
        // Propagate project roots once in dependency order. Rewalking every ancestor for every
        // milestone made long project chains grow quartically during save and import validation.
        let nodes: Vec<_> = self
            .quests
            .iter()
            .filter(|q| replacement.is_none_or(|next| next.id != q.id))
            .chain(replacement)
            .collect();
        let positions: HashMap<_, _> = nodes.iter().enumerate().map(|(i, q)| (q.id, i)).collect();
        let mut pending = vec![0; nodes.len()];
        let mut dependents = vec![Vec::new(); nodes.len()];
        for (index, quest) in nodes.iter().enumerate() {
            for dep in &quest.dependencies {
                if let Some(&parent) = positions.get(dep) {
                    pending[index] += 1;
                    dependents[parent].push(index);
                }
            }
        }
        let mut ready: Vec<_> = pending
            .iter()
            .enumerate()
            .filter_map(|(index, count)| (*count == 0).then_some(index))
            .collect();
        let mut roots = vec![HashSet::new(); nodes.len()];
        let mut result = HashMap::new();
        while let Some(index) = ready.pop() {
            if roots[index].is_empty() && nodes[index].kind == QuestKind::Project {
                roots[index].insert(nodes[index].id);
            }
            let current = std::mem::take(&mut roots[index]);
            for &child in &dependents[index] {
                roots[child].extend(current.iter().copied());
                pending[child] -= 1;
                if pending[child] == 0 {
                    ready.push(child);
                }
            }
            result.insert(nodes[index].id, current);
        }
        result
    }
    pub fn complete(&mut self, c: Completion) -> Result<u64> {
        if self.sessions.iter().any(|s| s.id == c.id) {
            return Ok(0);
        }
        if c.seconds == 0
            || c.seconds > 86400
            || c.result.trim().is_empty()
            || !(-86399..=86399).contains(&c.utc_offset_seconds)
        {
            return Err(invalid(
                "Подтвердите результат и время (от 1 секунды до 24 часов)",
            ));
        }
        let strict = self.active.as_ref().is_some_and(|a| a.strict);
        if self.settings.strict_mode {
            let confirmed = self.active.as_ref().is_some_and(|active| {
                active.strict
                    && active.id == c.id
                    && active.quest_id == c.quest_id
                    && c.seconds <= active.elapsed_seconds
            });
            if !confirmed {
                return Err(invalid(
                    "В строгом режиме время засчитывается только запущенной сессией",
                ));
            }
        }
        if let Some(active) = self.active.as_ref().filter(|a| a.strict)
            && (active.id != c.id
                || active.quest_id != c.quest_id
                || c.seconds > active.elapsed_seconds)
        {
            return Err(invalid(
                "В строгой сессии можно сохранить только подтверждённое таймером время",
            ));
        }
        let q = self
            .quests
            .iter()
            .find(|q| q.id == c.quest_id)
            .ok_or(EngineError::Missing)?
            .clone();
        if matches!(q.status, Status::Cancelled | Status::Missed)
            || q.status == Status::Completed && q.kind != QuestKind::Habit
        {
            return Err(invalid("Квест уже закрыт"));
        }
        if !self.quest_unlocked(&q) {
            return Err(EngineError::Locked);
        }
        if q.kind == QuestKind::Habit
            && self
                .sessions
                .iter()
                .any(|s| s.quest_id == q.id && s.day == c.day)
        {
            return Err(invalid("Эта привычка уже отмечена сегодня"));
        }
        if q.kind == QuestKind::Habit && !c.finish_quest {
            return Err(invalid(
                "Привычка отмечается после выполнения. Для частичной практики используйте обычную задачу",
            ));
        }
        if c.finish_quest && q.kind != QuestKind::Habit {
            let already = self
                .sessions
                .iter()
                .filter(|session| session.quest_id == q.id)
                .count();
            if already + 1 < q.planned_sessions as usize {
                return Err(invalid(
                    "Квест закрывается после всех запланированных сессий",
                ));
            }
        }
        // One shared daily pool, including habits, so switching skills does not reset R.
        let prior: u32 = self
            .sessions
            .iter()
            .filter(|s| s.day == c.day)
            .map(|s| s.credited_seconds)
            .fold(0_u32, u32::saturating_add);
        let mut award = xp::practice(c.seconds, q.estimate_minutes, q.difficulty, prior);
        if q.kind == QuestKind::Habit {
            let used: u64 = self
                .sessions
                .iter()
                .filter(|s| {
                    s.day == c.day
                        && self
                            .quests
                            .iter()
                            .any(|q| q.id == s.quest_id && q.kind == QuestKind::Habit)
                })
                .map(|s| s.reward_milli)
                .sum();
            award.milli = 1000_u64.min(4000_u64.saturating_sub(used));
            award.explanation = format!(
                "Поддерживающее действие: {:.1} XP. Общий предел всех привычек — 4 XP/день, одна отметка привычки в день.",
                award.milli as f64 / 1000.0
            );
        }
        if c.finish_quest && q.kind == QuestKind::Project && q.bonus_milli > 0 {
            let earlier: u64 = self
                .sessions
                .iter()
                .filter(|session| session.quest_id == q.id)
                .map(|session| session.reward_milli)
                .sum();
            let practice = earlier.saturating_add(award.milli);
            let bonus = q.bonus_milli.min(practice);
            award.milli = award.milli.saturating_add(bonus);
            award.explanation.push_str(&format!(
                " + {:.2} XP: бонус этапа, не выше XP практики по этому этапу.",
                bonus as f64 / 1000.0
            ));
        }
        // All validation precedes mutations. Repository commits this complete state atomically.
        let skill_xp = self
            .skills
            .iter()
            .find(|s| s.id == q.skill_id)
            .ok_or(EngineError::Missing)?
            .xp_milli
            .checked_add(award.milli)
            .ok_or_else(|| invalid("Переполнение XP"))?;
        let character_xp = self
            .character_xp_milli
            .checked_add(award.milli)
            .ok_or_else(|| invalid("Переполнение XP"))?;
        self.character_xp_milli = character_xp;
        self.skills
            .iter_mut()
            .find(|s| s.id == q.skill_id)
            .ok_or(EngineError::Missing)?
            .xp_milli = skill_xp;
        if c.finish_quest {
            if q.kind != QuestKind::Habit {
                let quest = self.quests.iter_mut().find(|v| v.id == q.id).unwrap();
                quest.status = Status::Completed;
                for step in &mut quest.steps {
                    step.done = true;
                }
            }
            if let Some(plan) = self.plans.iter_mut().find(|p| p.day == c.day) {
                for item in &mut plan.items {
                    if item.quest_id == q.id {
                        item.completed = true;
                    }
                }
            }
        }
        self.sessions.push(Session {
            id: c.id,
            quest_id: q.id,
            skill_id: q.skill_id,
            day: c.day,
            completed_at: c.at,
            utc_offset_seconds: c.utc_offset_seconds,
            seconds: c.seconds,
            credited_seconds: award.credited_seconds,
            estimate_minutes: q.estimate_minutes,
            difficulty: q.difficulty,
            reward_milli: award.milli,
            explanation: award.explanation.clone(),
            result: c.result,
            completed_quest: c.finish_quest,
            strict,
        });
        if self.active.as_ref().is_some_and(|a| a.id == c.id) {
            self.active = None;
        }
        self.event(
            "session_completed",
            format!(
                "{}: +{:.2} XP. {}",
                q.title,
                award.milli as f64 / 1000.0,
                award.explanation
            ),
        );
        Ok(award.milli)
    }
    pub fn commit_plan(&mut self, day: NaiveDate, ids: &[Id]) -> Result<()> {
        if ids.len() > 3 || ids.is_empty() {
            return Err(invalid("Выберите от одного до трёх обязательств"));
        }
        if self.plans.iter().any(|p| p.day == day) {
            return Err(invalid(
                "План уже принят. Используйте перенос с объяснением",
            ));
        }
        let mut seen = HashSet::new();
        let mut items = vec![];
        for id in ids {
            if !seen.insert(id) {
                return Err(invalid("Обязательства не должны повторяться"));
            }
            let q = self
                .quests
                .iter()
                .find(|q| q.id == *id)
                .ok_or(EngineError::Missing)?;
            if !self.quest_unlocked(q)
                || matches!(
                    q.status,
                    Status::Completed | Status::Cancelled | Status::Missed
                )
                || self
                    .sessions
                    .iter()
                    .any(|s| s.quest_id == *id && s.day == day)
            {
                return Err(invalid("План принимается до начала выполнения"));
            }
            items.push(PlanItem {
                quest_id: *id,
                weight: f64::from(q.priority),
                estimate_minutes: q.estimate_minutes,
                completed: false,
                excused: false,
            });
        }
        self.plans.push(DailyPlan {
            day,
            created_at: Utc::now(),
            items,
            rest: false,
            reason: String::new(),
        });
        self.event(
            "plan_committed",
            format!("{day}: принято {} обязательств", ids.len()),
        );
        Ok(())
    }
    pub fn excuse(&mut self, day: NaiveDate, quest_id: Option<Id>, reason: String) -> Result<()> {
        if reason.trim().is_empty() {
            return Err(invalid("Укажите причину изменения плана"));
        }
        if let Some(p) = self.plans.iter_mut().find(|p| p.day == day) {
            for i in &mut p.items {
                if !i.completed && (quest_id.is_none() || quest_id == Some(i.quest_id)) {
                    i.excused = true;
                }
            }
            if quest_id.is_none() {
                p.rest = true;
            }
            p.reason = reason.clone();
        } else if quest_id.is_none() {
            self.plans.push(DailyPlan {
                day,
                created_at: Utc::now(),
                items: vec![],
                rest: true,
                reason: reason.clone(),
            });
        } else {
            return Err(EngineError::Missing);
        }
        self.event("plan_changed", format!("{day}: {reason}"));
        Ok(())
    }
    pub fn set_quest_status(&mut self, id: Id, status: Status) -> Result<()> {
        if matches!(status, Status::Completed | Status::Active) {
            return Err(invalid("Завершите занятие с подтверждением результата"));
        }
        if self
            .active
            .as_ref()
            .is_some_and(|session| session.quest_id == id)
        {
            return Err(invalid("Сначала завершите активную сессию"));
        }
        {
            let quest = self
                .quests
                .iter_mut()
                .find(|quest| quest.id == id)
                .ok_or(EngineError::Missing)?;
            if quest.status == Status::Completed {
                return Err(invalid("Квест уже завершён"));
            }
            // Returning a missed quest to the plan drops the expired date, or the next day would miss it again.
            if quest.status == Status::Missed && status != Status::Missed {
                quest.deadline = None;
            }
            quest.status = status;
        }
        self.event("quest_status", format!("{id}: {}", status.label()));
        Ok(())
    }
    pub fn verify_mastery(&mut self, id: Id, evidence: String) -> Result<()> {
        if evidence.trim().chars().count() < 8 {
            return Err(invalid(
                "Опишите проверенный результат подробнее (от 8 символов)",
            ));
        }
        let skill = self
            .skills
            .iter()
            .find(|s| s.id == id)
            .ok_or(EngineError::Missing)?;
        if !self.skill_unlocked(skill) {
            return Err(EngineError::Locked);
        }
        if !self.skill_quests_completed(id) {
            return Err(invalid("Сначала выполните все квесты этого навыка"));
        }
        let open = self
            .quests
            .iter()
            .filter(|quest| {
                quest.skill_id == id && !matches!(quest.status, Status::Cancelled | Status::Missed)
            })
            .count();
        // One confirmation opens a questless skill. Further confirmations stop at the finished quests.
        let cap = open.max(1);
        if self
            .skills
            .iter()
            .find(|s| s.id == id)
            .is_some_and(|skill| skill.mastery as usize >= cap)
        {
            return Err(invalid(
                "Все выполненные квесты этого навыка уже подтверждены",
            ));
        }
        let s = self.skills.iter_mut().find(|s| s.id == id).unwrap();
        if s.evidence.contains(&evidence) {
            return Err(invalid("Этот результат уже подтверждён"));
        }
        s.mastery = s.mastery.saturating_add(1);
        s.evidence.push(evidence.clone());
        let title = s.title.clone();
        self.event("mastery_verified", format!("{title}: {evidence}"));
        Ok(())
    }
    pub fn remove_skill(&mut self, id: Id) -> Result<()> {
        let title = self
            .skills
            .iter()
            .find(|s| s.id == id)
            .map(|s| s.title.clone())
            .ok_or(EngineError::Missing)?;
        let quests: HashSet<_> = self
            .quests
            .iter()
            .filter(|q| q.skill_id == id)
            .map(|q| q.id)
            .collect();
        let removed = self
            .sessions
            .iter()
            .filter(|s| s.skill_id == id)
            .try_fold(0_u64, |total, s| total.checked_add(s.reward_milli))
            .ok_or_else(|| invalid("Переполнение XP"))?;
        self.character_xp_milli = self
            .character_xp_milli
            .checked_sub(removed)
            .ok_or_else(|| invalid("XP не соответствует журналу"))?;
        self.sessions.retain(|s| s.skill_id != id);
        self.quests.retain(|q| q.skill_id != id);
        for quest in &mut self.quests {
            quest.dependencies.retain(|dep| !quests.contains(dep));
        }
        for plan in &mut self.plans {
            plan.items.retain(|item| !quests.contains(&item.quest_id));
        }
        self.plans
            .retain(|plan| plan.rest || !plan.items.is_empty());
        self.targets.retain(|t| t.skill_id != id);
        if self
            .active
            .as_ref()
            .is_some_and(|a| quests.contains(&a.quest_id))
        {
            self.active = None;
        }
        self.skills.retain(|s| s.id != id);
        for skill in &mut self.skills {
            skill.prerequisites.retain(|pre| *pre != id);
        }
        self.event("skill_deleted", format!("Навык удалён: {title}"));
        Ok(())
    }
    pub fn set_target(&mut self, target: WeeklyTarget, today: NaiveDate) -> Result<()> {
        if target.week < GameState::week(today) {
            return Err(invalid("Цели прошлых недель зафиксированы"));
        }
        if target.week.weekday() != Weekday::Mon {
            return Err(invalid("Недельная цель должна начинаться в понедельник"));
        }
        if !target.target.is_finite()
            || target.target <= 0.0
            || !target.weight.is_finite()
            || !(0.0..=10.0).contains(&target.weight)
            || target.weight == 0.0
            || !self.skills.iter().any(|s| s.id == target.skill_id)
        {
            return Err(invalid(
                "Цель должна быть положительной, а вес — больше 0 и не больше 10",
            ));
        }
        // An accepted weekly target is immutable; a new plan starts next Monday.
        if self
            .targets
            .iter()
            .any(|t| t.week == target.week && t.skill_id == target.skill_id)
        {
            return Err(invalid(
                "Цель этого навыка уже принята на неделю. Изменения — со следующей недели",
            ));
        }
        self.event(
            "target_set",
            format!(
                "Неделя {}: {} {} для {}",
                target.week,
                target.target,
                target.unit,
                self.skill_name(target.skill_id)
            ),
        );
        self.targets.push(target);
        Ok(())
    }
    pub fn update_skill(
        &mut self,
        id: Id,
        title: String,
        domain: Domain,
        prerequisites: Vec<Id>,
        focus_rules: FocusRules,
    ) -> Result<()> {
        let title = title.trim().to_string();
        if title.is_empty()
            || prerequisites.contains(&id)
            || prerequisites
                .iter()
                .any(|parent| !self.skills.iter().any(|skill| skill.id == *parent))
        {
            return Err(invalid("Проверьте название и зависимости навыка"));
        }
        let focus_rules = focus_rules
            .normalized()
            .map_err(|_| invalid("Проверьте список приложений и сайтов"))?;
        let index = self
            .skills
            .iter()
            .position(|skill| skill.id == id)
            .ok_or(EngineError::Missing)?;
        let previous = self.skills[index].clone();
        self.skills[index].title = title;
        self.skills[index].domain = domain;
        self.skills[index].prerequisites = prerequisites;
        self.skills[index].focus_rules = focus_rules;
        if let Err(error) = self.validate() {
            self.skills[index] = previous;
            return Err(error);
        }
        Ok(())
    }
    pub fn validate(&self) -> Result<()> {
        self.validate_routine()?;
        if self.schema_version != 1 {
            return Err(invalid("Неподдерживаемая версия данных"));
        }
        if self
            .settings
            .avatar
            .as_ref()
            .is_some_and(|image| image.len() > 1_048_576)
        {
            return Err(invalid("Изображение профиля слишком большое"));
        }
        fn unique(ids: impl Iterator<Item = Id>) -> bool {
            let mut s = HashSet::new();
            ids.into_iter().all(|id| s.insert(id))
        }
        if !unique(self.skills.iter().map(|s| s.id))
            || !unique(self.quests.iter().map(|s| s.id))
            || !unique(self.sessions.iter().map(|s| s.id))
            || !unique(self.targets.iter().map(|s| s.id))
            || !unique(self.events.iter().map(|s| s.id))
            || !unique(self.journal.iter().map(|s| s.id))
        {
            return Err(invalid("Повторяющиеся идентификаторы"));
        }
        let skills: HashSet<_> = self.skills.iter().map(|s| s.id).collect();
        let quests: HashSet<_> = self.quests.iter().map(|q| q.id).collect();
        if self.skills.iter().any(|skill| {
            let rules = &skill.focus_rules;
            normalize_focus_lists(&rules.apps, &rules.sites)
                .ok()
                .is_none_or(|(apps, sites)| apps != rules.apps || sites != rules.sites)
        }) {
            return Err(invalid("Проверьте список приложений и сайтов"));
        }
        if self
            .skills
            .iter()
            .any(|s| s.prerequisites.iter().any(|i| !skills.contains(i)))
            || self.quests.iter().any(|q| {
                !skills.contains(&q.skill_id)
                    || q.dependencies.iter().any(|i| !quests.contains(i))
                    || q.estimate_minutes == 0
                    || q.estimate_minutes > 1440
                    || !(1..=10_000).contains(&q.planned_sessions)
                    || !q.difficulty.is_finite()
                    || !(0.5..=2.0).contains(&q.difficulty)
                    || !(1..=3).contains(&q.priority)
                    || q.bonus_milli > 40000
                    || (q.kind != QuestKind::Project && q.bonus_milli != 0)
                    || (q.kind != QuestKind::Habit
                        && self
                            .skills
                            .iter()
                            .any(|s| s.id == q.skill_id && s.domain == Domain::Recovery))
                    || !steps_are_clean(&q.steps)
            })
        {
            return Err(invalid("Нарушены ссылки или правила квестов"));
        }
        fn acyclic<'a>(nodes: impl Iterator<Item = (Id, &'a [Id])>) -> bool {
            // Kahn's algorithm uses bounded heap storage instead of one call frame per dependency.
            let nodes: Vec<_> = nodes.collect();
            let positions: std::collections::HashMap<_, _> = nodes
                .iter()
                .enumerate()
                .map(|(index, (id, _))| (*id, index))
                .collect();
            let mut pending = vec![0; nodes.len()];
            let mut dependents = vec![Vec::new(); nodes.len()];
            for (index, (_, deps)) in nodes.iter().enumerate() {
                for dep in *deps {
                    if let Some(&parent) = positions.get(dep) {
                        pending[index] += 1;
                        dependents[parent].push(index);
                    }
                }
            }
            let mut ready: Vec<_> = pending
                .iter()
                .enumerate()
                .filter_map(|(index, count)| (*count == 0).then_some(index))
                .collect();
            let mut visited = 0;
            while let Some(index) = ready.pop() {
                visited += 1;
                for &child in &dependents[index] {
                    pending[child] -= 1;
                    if pending[child] == 0 {
                        ready.push(child);
                    }
                }
            }
            visited == nodes.len()
        }
        if !acyclic(
            self.skills
                .iter()
                .map(|s| (s.id, s.prerequisites.as_slice())),
        ) || !acyclic(
            self.quests
                .iter()
                .map(|q| (q.id, q.dependencies.as_slice())),
        ) {
            return Err(invalid("Обнаружен цикл зависимостей"));
        }
        let mut budgets = HashMap::new();
        let project_roots = if self.quests.iter().any(|q| q.bonus_milli > 0) {
            self.project_root_map(None)
        } else {
            HashMap::new()
        };
        for q in self.quests.iter().filter(|q| q.bonus_milli > 0) {
            let roots = &project_roots[&q.id];
            if roots.len() != 1 {
                return Err(invalid("Некорректная цепочка бонусов проекта"));
            }
            let total = budgets
                .entry(*roots.iter().next().unwrap())
                .or_insert(0_u64);
            *total = total
                .checked_add(q.bonus_milli)
                .ok_or_else(|| invalid("Переполнение бонуса"))?;
            if *total > 40000 {
                return Err(invalid("Бюджет бонусов проекта превышен"));
            }
        }
        let quest_skills: HashMap<_, _> = self.quests.iter().map(|q| (q.id, q.skill_id)).collect();
        if self.sessions.iter().any(|s| {
            !quests.contains(&s.quest_id)
                || !skills.contains(&s.skill_id)
                || s.seconds == 0
                || s.seconds > 86400
                || s.credited_seconds > s.seconds
                || s.estimate_minutes == 0
                || s.estimate_minutes > 1440
                || s.credited_seconds > s.estimate_minutes.saturating_mul(75)
                || !s.difficulty.is_finite()
                || !(0.5..=2.0).contains(&s.difficulty)
                || !(-86399..=86399).contains(&s.utc_offset_seconds)
                || quest_skills.get(&s.quest_id) != Some(&s.skill_id)
                || s.result.trim().is_empty()
        }) {
            return Err(invalid("Некорректный журнал сессий"));
        }
        let mut skill_totals = HashMap::<Id, u64>::new();
        let total = self.sessions.iter().try_fold(0_u64, |total, session| {
            let subtotal = skill_totals.entry(session.skill_id).or_default();
            *subtotal = subtotal.checked_add(session.reward_milli)?;
            total.checked_add(session.reward_milli)
        });
        if total != Some(self.character_xp_milli)
            || self
                .skills
                .iter()
                .any(|skill| skill_totals.get(&skill.id).copied().unwrap_or(0) != skill.xp_milli)
        {
            return Err(invalid("XP не соответствует журналу"));
        }
        let mut days = HashSet::new();
        if self.plans.iter().any(|p| {
            !days.insert(p.day)
                || p.items.len() > 3
                || !unique(p.items.iter().map(|i| i.quest_id))
                || p.items.iter().any(|i| {
                    !quests.contains(&i.quest_id) || !i.weight.is_finite() || i.weight <= 0.0
                })
        }) {
            return Err(invalid("Некорректный план"));
        }
        let mut targets = HashSet::new();
        if self.targets.iter().any(|t| {
            !skills.contains(&t.skill_id)
                || !t.target.is_finite()
                || t.target <= 0.0
                || !t.weight.is_finite()
                || t.weight <= 0.0
                || !targets.insert((t.week, t.skill_id))
                || t.week.weekday() != Weekday::Mon
        }) {
            return Err(invalid("Некорректные недельные цели"));
        }
        if self.checkins.iter().any(|c| {
            c.energy > 100 || c.fatigue > 100 || c.focus > 100 || c.available_minutes > 1440
        }) || self.active.as_ref().is_some_and(|a| {
            !quests.contains(&a.quest_id)
                || a.elapsed_seconds > 86400
                || self.sessions.iter().any(|session| session.id == a.id)
        }) {
            return Err(invalid("Некорректное состояние таймера или самочувствия"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod project_index_tests {
    use super::*;

    fn node(skill_id: Id, kind: QuestKind, dependencies: Vec<Id>) -> Quest {
        Quest {
            id: Id::new_v4(),
            title: "Milestone".into(),
            outcome: String::new(),
            skill_id,
            kind,
            priority: 1,
            estimate_minutes: 25,
            planned_sessions: 1,
            difficulty: 1.0,
            bonus_milli: 0,
            deadline: None,
            dependencies,
            steps: vec![],
            status: Status::Planned,
            created_at: Utc::now(),
        }
    }
    fn original_roots(state: &GameState, quest: &Quest) -> HashSet<Id> {
        let ancestors = |quest: &Quest| {
            let mut todo = quest.dependencies.clone();
            let mut seen = HashSet::new();
            while let Some(id) = todo.pop() {
                if seen.insert(id)
                    && let Some(parent) = state.quests.iter().find(|q| q.id == id)
                {
                    todo.extend(&parent.dependencies);
                }
            }
            seen
        };
        let all = ancestors(quest);
        let mut roots: HashSet<_> = state
            .quests
            .iter()
            .filter(|q| q.kind == QuestKind::Project && all.contains(&q.id))
            .filter(|q| {
                !ancestors(q).iter().any(|id| {
                    state
                        .quests
                        .iter()
                        .any(|p| p.id == *id && p.kind == QuestKind::Project)
                })
            })
            .map(|q| q.id)
            .collect();
        if roots.is_empty() {
            roots.insert(quest.id);
        }
        roots
    }
    #[test]
    fn indexed_project_roots_match_branching_and_intermediate_tasks() {
        for seed in 0..30_u64 {
            let mut state = GameState::default();
            let skill = state.add_skill("Projects".into(), Domain::Mind, vec![]);
            let mut random = seed + 1;
            for index in 0..30 {
                let mut dependencies = Vec::new();
                for previous in &state.quests {
                    random = random.wrapping_mul(6364136223846793005).wrapping_add(1);
                    if random % 11 == 0 {
                        dependencies.push(previous.id);
                    }
                }
                let kind = if index % 3 == 0 {
                    QuestKind::Daily
                } else {
                    QuestKind::Project
                };
                state.quests.push(node(skill, kind, dependencies));
            }
            let indexed = state.project_root_map(None);
            for quest in state.quests.iter().filter(|q| q.kind == QuestKind::Project) {
                assert_eq!(indexed[&quest.id], original_roots(&state, quest));
            }
            // Source order is not dependency order in imported JSON.
            state.quests.reverse();
            assert_eq!(state.project_root_map(None), indexed);
        }
    }
    #[test]
    fn long_project_chain_validates_its_shared_bonus_without_rewalking_ancestors() {
        let mut state = GameState::default();
        let skill = state.add_skill("Projects".into(), Domain::Mind, vec![]);
        for _ in 0..2000 {
            let dependencies = state.quests.last().map(|q| vec![q.id]).unwrap_or_default();
            let mut quest = node(skill, QuestKind::Project, dependencies);
            quest.bonus_milli = 20;
            state.quests.push(quest);
        }
        state.validate().unwrap();
        state.quests.last_mut().unwrap().bonus_milli = 21;
        assert!(state.validate().is_err());
    }
    #[test]
    fn moving_a_project_recalculates_the_whole_descendant_budget_atomically() {
        let mut state = GameState::default();
        let skill = state.add_skill("Projects".into(), Domain::Mind, vec![]);
        let mut left = node(skill, QuestKind::Project, vec![]);
        left.bonus_milli = 20_000;
        let mut child = node(skill, QuestKind::Project, vec![left.id]);
        child.bonus_milli = 20_000;
        let mut right = node(skill, QuestKind::Project, vec![]);
        right.bonus_milli = 30_000;
        state.quests = vec![left.clone(), child.clone(), right.clone()];
        state.validate().unwrap();
        let mut moved = left.clone();
        moved.dependencies = vec![right.id];
        assert!(state.update_quest(left.id, moved).is_err());
        assert!(state.quests[0].dependencies.is_empty());
        let mut moved = child.clone();
        moved.dependencies = vec![right.id];
        assert!(state.update_quest(child.id, moved.clone()).is_err());
        assert_eq!(state.quests[1].dependencies, vec![left.id]);
        moved.bonus_milli = 10_000;
        state.update_quest(child.id, moved).unwrap();
        assert_eq!(state.quests[1].dependencies, vec![right.id]);
        state.validate().unwrap();
    }
}
