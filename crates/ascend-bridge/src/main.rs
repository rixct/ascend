use ascend_core::*;
use ascend_storage::Repository;
use chrono::{Local, NaiveDate, Utc};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    io::{self, BufRead, Read, Write},
    path::PathBuf,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum Command {
    Load,
    Tick {
        #[serde(default)]
        compact: bool,
    },
    Pause,
    ResetTimer,
    Presence {
        id: Id,
        present: bool,
        observed_at_ms: u64,
    },
    Focus {
        bundle_id: String,
        #[serde(default)]
        host: Option<String>,
        #[serde(default)]
        site_unavailable: bool,
    },
    DiscardSession {
        id: Id,
    },
    Notes {
        #[serde(default)]
        id: Option<Id>,
        text: String,
        #[serde(default)]
        compact: bool,
    },
    SetRoutine {
        items: Vec<String>,
        enabled: bool,
    },
    RoutineCheck {
        day: NaiveDate,
        id: Id,
        completed: bool,
    },
    Onboard {
        name: String,
        minutes: u32,
        #[serde(default = "default_starter")]
        starter: bool,
        #[serde(default)]
        routine_items: Option<Vec<String>>,
    },
    Settings {
        name: String,
        avatar: Option<String>,
        #[serde(default)]
        bio: Option<String>,
        minutes: u32,
        growth: u8,
        #[serde(default)]
        strict: bool,
    },
    CreateQuest {
        title: String,
        outcome: String,
        skill_id: Id,
        kind: QuestKind,
        priority: u8,
        minutes: u32,
        #[serde(default = "default_planned_sessions")]
        planned_sessions: u32,
        difficulty: f64,
        bonus: u64,
        deadline: Option<NaiveDate>,
        dependencies: Vec<Id>,
        #[serde(default)]
        steps: Vec<QuestStep>,
    },
    UpdateQuest {
        id: Id,
        title: String,
        outcome: String,
        skill_id: Id,
        kind: QuestKind,
        priority: u8,
        minutes: u32,
        #[serde(default = "default_planned_sessions")]
        planned_sessions: u32,
        difficulty: f64,
        bonus: u64,
        deadline: Option<NaiveDate>,
        dependencies: Vec<Id>,
        #[serde(default)]
        steps: Vec<QuestStep>,
    },
    CreateSkill {
        title: String,
        domain: Domain,
        prerequisites: Vec<Id>,
        #[serde(flatten)]
        focus_rules: FocusRules,
    },
    UpdateSkill {
        id: Id,
        title: String,
        domain: Domain,
        prerequisites: Vec<Id>,
        #[serde(flatten)]
        focus_rules: FocusRules,
    },
    DeleteSkill {
        id: Id,
    },
    Verify {
        id: Id,
        evidence: String,
    },
    Plan {
        ids: Vec<Id>,
    },
    Excuse {
        id: Option<Id>,
        reason: String,
    },
    Target {
        skill_id: Id,
        target: f64,
        weight: f64,
        unit: TargetUnit,
        next_week: bool,
    },
    Checkin {
        energy: u8,
        fatigue: u8,
        focus: u8,
        minutes: u32,
        unwell: bool,
    },
    Journal {
        text: String,
    },
    Status {
        id: Id,
        status: Status,
    },
    Start {
        id: Id,
        #[serde(default)]
        strict: bool,
    },
    Complete {
        id: Id,
        quest_id: Id,
        seconds: u32,
        result: String,
        finish: bool,
    },
    Export {
        path: PathBuf,
        csv: bool,
    },
    PreviewImport {
        path: PathBuf,
    },
    ConfirmImport,
    CancelImport,
    Backup,
}
struct Engine {
    repo: Repository,
    state: GameState,
    pending: Option<GameState>,
    last: Instant,
    fraction: Duration,
    presence: Option<PresenceLease>,
    focus: Option<FocusLease>,
    backup_day: NaiveDate,
    snapshot_day: NaiveDate,
}
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
fn invalid(text: &str) -> EngineError {
    EngineError::Invalid(text.into())
}
fn default_starter() -> bool {
    true
}
fn day() -> NaiveDate {
    Local::now().date_naive()
}
#[derive(Clone, Copy)]
struct PresenceLease {
    id: Id,
    from: Instant,
    until: Instant,
}
#[derive(Clone, Copy)]
struct FocusLease {
    id: Id,
    from: Instant,
    until: Instant,
    allowed: bool,
}
fn focus_configuration(state: &GameState) -> Option<(Id, FocusRules)> {
    let active = state.active.as_ref()?;
    let quest = state
        .quests
        .iter()
        .find(|quest| quest.id == active.quest_id)?;
    let skill = state
        .skills
        .iter()
        .find(|skill| skill.id == quest.skill_id)?;
    Some((skill.id, skill.focus_rules.clone()))
}
fn reset_focus_after_edit(state: &mut GameState, previous: &Option<(Id, FocusRules)>) -> bool {
    let changed = focus_configuration(state) != *previous;
    if changed {
        let restricts = state
            .active
            .as_ref()
            .is_some_and(|active| state.restricts_focus(active.quest_id));
        if let Some(active) = &mut state.active {
            active.focus_confirmed = !restricts;
        }
    }
    changed
}
fn unix_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

impl Engine {
    fn settle_if_needed(&mut self) -> Result<bool> {
        let today = day();
        let active = self.state.active.as_ref().map(|session| session.quest_id);
        let due = self.state.quests.iter().any(|quest| {
            quest.deadline.is_some_and(|deadline| deadline < today)
                && matches!(
                    quest.status,
                    Status::Planned | Status::Active | Status::Paused
                )
                && active != Some(quest.id)
        });
        if due {
            self.repo.apply(&mut self.state, |state| {
                state.settle_deadlines(today);
                Ok(())
            })?;
        }
        Ok(due)
    }
    fn open(path: PathBuf) -> Result<Self> {
        let (mut repo, mut state) = Repository::open(path)?;
        if state.adopt_current_list(day()) {
            repo.save(&state)?;
        }
        repo.checkpoint(&state)?;
        Ok(Self {
            repo,
            state,
            pending: None,
            last: Instant::now(),
            fraction: Duration::ZERO,
            presence: None,
            focus: None,
            backup_day: day(),
            snapshot_day: day(),
        })
    }
    fn advance(&mut self) -> Result<()> {
        let now = Instant::now();
        let delta = now.saturating_duration_since(self.last);
        let from = self.last;
        self.last = now;
        let restricts = self
            .state
            .active
            .as_ref()
            .is_some_and(|active| self.state.restricts_focus(active.quest_id));
        let focus_ok = self.state.active.as_ref().is_some_and(|active| {
            !self.state.restricts_focus(active.quest_id)
                || self.focus.as_ref().is_some_and(|lease| {
                    lease.id == active.id && lease.allowed && lease.until > now
                })
        });
        let previous = self.state.active.clone();
        if let Some(a) = &mut self.state.active
            && a.running
        {
            if delta > Duration::from_secs(5) {
                a.running = false;
                self.presence = None;
                self.focus = None;
            } else {
                let mut start = from;
                let mut end = now;
                if a.strict {
                    if let Some(lease) = self.presence.filter(|lease| lease.id == a.id) {
                        start = start.max(lease.from);
                        end = end.min(lease.until);
                    } else {
                        end = start;
                    }
                }
                if restricts {
                    if let Some(lease) =
                        self.focus.filter(|lease| lease.id == a.id && lease.allowed)
                    {
                        start = start.max(lease.from);
                        end = end.min(lease.until);
                    } else {
                        end = start;
                    }
                }
                let eligible = end.saturating_duration_since(start);
                let elapsed = self.fraction + eligible;
                a.elapsed_seconds = a
                    .elapsed_seconds
                    .saturating_add(elapsed.as_secs() as u32)
                    .min(86400);
                self.fraction = elapsed - Duration::from_secs(elapsed.as_secs());
            }
        }
        if let Some(active) = &mut self.state.active {
            active.presence_confirmed = active.strict
                && active.running
                && self
                    .presence
                    .is_some_and(|lease| lease.id == active.id && lease.until > now);
            active.focus_confirmed = !restricts || (active.running && focus_ok);
        }
        if self.state.active != previous
            && let Err(error) = self.repo.checkpoint(&self.state)
        {
            self.state.active = previous;
            return Err(error.into());
        }
        if self.backup_day != day() {
            self.repo.daily_backup()?;
            self.backup_day = day();
        }
        Ok(())
    }
    fn run(&mut self, cmd: Command) -> Result<Value> {
        let settled = self.settle_if_needed()?;
        let compact = matches!(
            &cmd,
            Command::Tick { compact: true }
                | Command::Notes { compact: true, .. }
                | Command::Presence { .. }
                | Command::Focus { .. }
        );
        let mut extra = json!({});
        match cmd {
            Command::Load => {}
            Command::Tick { .. } => self.advance()?,
            Command::Onboard {
                name,
                minutes,
                starter,
                routine_items,
            } => {
                self.repo.apply(&mut self.state, |s| {
                    if name.trim().is_empty() || !(5..=1440).contains(&minutes) {
                        return Err(invalid("Укажите имя и время от 5 до 1440 минут"));
                    }
                    if let Some(items) = routine_items {
                        s.set_routine(items, true, day())?;
                    }
                    s.settings.name = name.trim().into();
                    s.settings.daily_minutes = minutes;
                    s.settings.onboarded = true;
                    if starter {
                        s.starter_skills();
                    }
                    s.event("profile_created", "Профиль создан");
                    Ok(())
                })?;
            }
            Command::SetRoutine { items, enabled } => {
                self.repo
                    .apply(&mut self.state, |s| s.set_routine(items, enabled, day()))?;
            }
            Command::RoutineCheck {
                day: selected_day,
                id,
                completed,
            } => {
                self.repo.apply(&mut self.state, |s| {
                    s.set_routine_item(selected_day, day(), id, completed)
                })?;
            }
            Command::Settings {
                name,
                avatar,
                bio,
                minutes,
                growth,
                strict,
            } => {
                self.repo.apply(&mut self.state, |s| {
                    let name = name.trim().chars().take(64).collect::<String>();
                    if name.is_empty() || minutes == 0 || minutes > 1440 || growth > 15 {
                        return Err(invalid("Проверьте настройки профиля"));
                    }
                    s.settings.name = name;
                    s.settings.daily_minutes = minutes;
                    s.settings.growth_percent = growth;
                    s.settings.strict_mode = strict;
                    if let Some(bio) = bio {
                        s.settings.bio = bio.trim().chars().take(140).collect();
                    }
                    if let Some(avatar) = avatar {
                        if avatar.len() > 1_048_576 {
                            return Err(invalid("Изображение профиля слишком большое"));
                        }
                        s.settings.avatar = if avatar.is_empty() {
                            None
                        } else {
                            Some(avatar)
                        };
                    }
                    Ok(())
                })?;
            }
            Command::CreateQuest {
                title,
                outcome,
                skill_id,
                kind,
                priority,
                minutes,
                planned_sessions,
                difficulty,
                bonus,
                deadline,
                dependencies,
                steps,
            } => {
                self.repo.apply(&mut self.state, |s| {
                    s.create_quest(Quest {
                        id: Id::new_v4(),
                        title: title.trim().into(),
                        outcome: outcome.trim().into(),
                        skill_id,
                        kind,
                        priority,
                        estimate_minutes: minutes,
                        planned_sessions,
                        difficulty,
                        bonus_milli: bonus.saturating_mul(1000),
                        deadline,
                        dependencies,
                        steps,
                        status: Status::Planned,
                        created_at: Utc::now(),
                    })
                })?;
            }
            Command::UpdateQuest {
                id,
                title,
                outcome,
                skill_id,
                kind,
                priority,
                minutes,
                planned_sessions,
                difficulty,
                bonus,
                deadline,
                dependencies,
                steps,
            } => {
                self.advance()?;
                let focus_before = focus_configuration(&self.state);
                let changed = self.repo.apply(&mut self.state, |s| {
                    s.update_quest(
                        id,
                        Quest {
                            id,
                            title,
                            outcome,
                            skill_id,
                            kind,
                            priority,
                            estimate_minutes: minutes,
                            planned_sessions,
                            difficulty,
                            bonus_milli: bonus.saturating_mul(1000),
                            deadline,
                            dependencies,
                            steps,
                            status: Status::Planned,
                            created_at: Utc::now(),
                        },
                    )?;
                    Ok(reset_focus_after_edit(s, &focus_before))
                })?;
                if changed {
                    self.focus = None;
                }
            }
            Command::CreateSkill {
                title,
                domain,
                prerequisites,
                focus_rules,
            } => {
                self.repo.apply(&mut self.state, |s| {
                    if title.trim().is_empty()
                        || prerequisites
                            .iter()
                            .any(|id| !s.skills.iter().any(|skill| skill.id == *id))
                    {
                        return Err(invalid("Проверьте название и зависимости навыка"));
                    }
                    let focus_rules = focus_rules
                        .normalized()
                        .map_err(|_| invalid("Проверьте список приложений и сайтов"))?;
                    let id = s.add_skill(title.trim().into(), domain, prerequisites);
                    if let Some(skill) = s.skills.iter_mut().find(|skill| skill.id == id) {
                        skill.focus_rules = focus_rules;
                    }
                    Ok(())
                })?;
            }
            Command::UpdateSkill {
                id,
                title,
                domain,
                prerequisites,
                focus_rules,
            } => {
                self.advance()?;
                let focus_before = focus_configuration(&self.state);
                let changed = self.repo.apply(&mut self.state, |s| {
                    s.update_skill(id, title, domain, prerequisites, focus_rules)?;
                    Ok(reset_focus_after_edit(s, &focus_before))
                })?;
                if changed {
                    self.focus = None;
                }
            }
            Command::DeleteSkill { id } => {
                self.repo.apply(&mut self.state, |s| s.remove_skill(id))?;
            }
            Command::Verify { id, evidence } => {
                self.repo
                    .apply(&mut self.state, |s| s.verify_mastery(id, evidence))?;
            }
            Command::Plan { ids } => {
                let ids = if ids.is_empty() {
                    ascend_planner::propose(&self.state, day())
                } else {
                    ids
                };
                self.repo
                    .apply(&mut self.state, |s| s.commit_plan(day(), &ids))?;
            }
            Command::Excuse { id, reason } => {
                self.repo
                    .apply(&mut self.state, |s| s.excuse(day(), id, reason))?;
            }
            Command::Target {
                skill_id,
                target,
                weight,
                unit,
                next_week,
            } => {
                self.repo.apply(&mut self.state, |s| {
                    s.set_target(
                        WeeklyTarget {
                            id: Id::new_v4(),
                            week: GameState::week(day())
                                + chrono::Duration::days(if next_week { 7 } else { 0 }),
                            skill_id,
                            target,
                            weight,
                            unit,
                        },
                        day(),
                    )
                })?;
            }
            Command::Checkin {
                energy,
                fatigue,
                focus,
                minutes,
                unwell,
            } => {
                self.repo.apply(&mut self.state, |s| {
                    s.checkins.retain(|c| c.day != day());
                    s.checkins.push(CheckIn {
                        day: day(),
                        energy,
                        fatigue,
                        focus,
                        available_minutes: minutes,
                        unwell,
                    });
                    s.event("checkin", "Самочувствие обновлено");
                    Ok(())
                })?;
            }
            Command::Journal { text } => {
                self.repo.apply(&mut self.state, |s| {
                    if text.trim().is_empty() {
                        return Err(invalid("Введите запись"));
                    }
                    s.journal.push(JournalEntry {
                        id: Id::new_v4(),
                        day: day(),
                        text: text.trim().into(),
                    });
                    Ok(())
                })?;
            }
            Command::Status { id, status } => {
                self.repo
                    .apply(&mut self.state, |s| s.set_quest_status(id, status))?;
            }
            Command::Start { id, strict } => {
                self.repo.apply(&mut self.state, |s| {
                    if s.active.is_some() {
                        return Err(invalid("Сначала завершите текущее занятие"));
                    }
                    let strict = strict || s.settings.strict_mode;
                    let q = s
                        .quests
                        .iter()
                        .find(|q| q.id == id)
                        .ok_or(EngineError::Missing)?;
                    if !s.quest_unlocked(q) {
                        return Err(EngineError::Locked);
                    }
                    if !matches!(q.status, Status::Planned | Status::Paused | Status::Active) {
                        return Err(invalid("Квест закрыт"));
                    }
                    if q.kind == QuestKind::Habit
                        && s.sessions
                            .iter()
                            .any(|v| v.quest_id == id && v.day == day())
                    {
                        return Err(invalid("Привычка уже выполнена сегодня"));
                    }
                    let skill_id = q.skill_id;
                    let restricts = s
                        .skills
                        .iter()
                        .any(|skill| skill.id == skill_id && skill.focus_rules.restricts_focus());
                    s.active = Some(ActiveSession {
                        id: Id::new_v4(),
                        quest_id: id,
                        elapsed_seconds: 0,
                        running: true,
                        strict,
                        presence_confirmed: false,
                        focus_confirmed: !restricts,
                        notes: String::new(),
                    });
                    s.quests.iter_mut().find(|q| q.id == id).unwrap().status = Status::Active;
                    Ok(())
                })?;
                self.last = Instant::now();
                self.fraction = Duration::ZERO;
                self.presence = None;
                self.focus = None;
            }
            Command::Pause => {
                self.advance()?;
                self.repo.apply(&mut self.state, |s| {
                    let restricts = s
                        .active
                        .as_ref()
                        .is_some_and(|active| s.restricts_focus(active.quest_id));
                    if let Some(active) = &mut s.active {
                        active.running = !active.running;
                        active.presence_confirmed = false;
                        if !active.running {
                            active.focus_confirmed = !restricts;
                        }
                    }
                    Ok(())
                })?;
                self.last = Instant::now();
                self.presence = None;
                self.focus = None;
            }
            Command::ResetTimer => {
                self.advance()?;
                self.repo.apply(&mut self.state, |state| {
                    if let Some(active) = &mut state.active {
                        active.elapsed_seconds = 0;
                    }
                    Ok(())
                })?;
                self.fraction = Duration::ZERO;
                self.last = Instant::now();
            }
            Command::Focus {
                bundle_id,
                host,
                site_unavailable,
            } => {
                self.advance()?;
                let decision = self
                    .state
                    .active
                    .as_ref()
                    .filter(|active| active.running)
                    .map(|active| {
                        (
                            active.id,
                            self.state.focus_allows(
                                active.quest_id,
                                &bundle_id,
                                host.as_deref(),
                                site_unavailable,
                            ),
                        )
                    });
                let now = Instant::now();
                if let Some((id, allowed)) = decision {
                    if allowed {
                        let from = self
                            .focus
                            .filter(|lease| lease.id == id && lease.allowed && lease.until >= now)
                            .map(|lease| lease.from)
                            .unwrap_or(now);
                        self.focus = Some(FocusLease {
                            id,
                            from,
                            until: now + Duration::from_millis(2500),
                            allowed: true,
                        });
                    } else {
                        self.focus = Some(FocusLease {
                            id,
                            from: now,
                            until: now,
                            allowed: false,
                        });
                    }
                } else {
                    self.focus = None;
                }
                let confirmed = self.state.active.as_ref().is_some_and(|active| {
                    !self.state.restricts_focus(active.quest_id)
                        || self.focus.as_ref().is_some_and(|lease| {
                            lease.id == active.id && lease.allowed && lease.until > now
                        })
                });
                let previous = self.state.active.clone();
                if let Some(active) = &mut self.state.active {
                    active.focus_confirmed = confirmed;
                }
                if self.state.active != previous
                    && let Err(error) = self.repo.checkpoint(&self.state)
                {
                    self.state.active = previous;
                    self.focus = None;
                    return Err(error.into());
                }
            }
            Command::Presence {
                id,
                present,
                observed_at_ms,
            } => {
                self.advance()?;
                if self
                    .state
                    .active
                    .as_ref()
                    .is_some_and(|a| a.id == id && a.strict && a.running)
                {
                    let now = Instant::now();
                    let wall = unix_millis();
                    let fresh = observed_at_ms <= wall.saturating_add(100)
                        && wall.saturating_sub(observed_at_ms) <= 1000;
                    if present && fresh {
                        let from = self
                            .presence
                            .filter(|lease| lease.id == id && lease.until >= now)
                            .map_or(now, |lease| lease.from);
                        self.presence = Some(PresenceLease {
                            id,
                            from,
                            // Subtract delivery latency so delayed frames cannot extend presence.
                            until: now
                                + Duration::from_millis(1500 - wall.saturating_sub(observed_at_ms)),
                        });
                    } else {
                        self.presence = None;
                    }
                    let previous = self.state.active.clone();
                    if let Some(a) = &mut self.state.active {
                        a.presence_confirmed = self.presence.is_some();
                    }
                    if self.state.active != previous
                        && let Err(error) = self.repo.checkpoint(&self.state)
                    {
                        self.state.active = previous;
                        self.presence = None;
                        return Err(error.into());
                    }
                }
            }
            Command::DiscardSession { id } => {
                if self.state.active.as_ref().is_some_and(|a| a.id == id) {
                    self.repo.apply(&mut self.state, |s| {
                        if let Some(active) = s.active.take()
                            && let Some(quest) =
                                s.quests.iter_mut().find(|q| q.id == active.quest_id)
                            && quest.status == Status::Active
                        {
                            quest.status = Status::Planned;
                        }
                        Ok(())
                    })?;
                    self.presence = None;
                    self.focus = None;
                    self.fraction = Duration::ZERO;
                }
            }
            Command::Notes { id, text, .. } => {
                let previous = self.state.active.clone();
                if let Some(active) = &mut self.state.active
                    && id.is_none_or(|id| id == active.id)
                {
                    active.notes = text;
                }
                if self.state.active != previous
                    && let Err(error) = self.repo.checkpoint(&self.state)
                {
                    self.state.active = previous;
                    return Err(error.into());
                }
            }
            Command::Complete {
                id,
                quest_id,
                seconds,
                result,
                finish,
            } => {
                if !self.state.sessions.iter().any(|session| session.id == id)
                    && let Some(active) = &self.state.active
                    && (active.id == id || active.quest_id == quest_id)
                    && (active.id != id || active.quest_id != quest_id)
                {
                    return Err(invalid("Сначала завершите текущее занятие").into());
                }
                self.repo.apply(&mut self.state, |s| {
                    s.complete(Completion {
                        id,
                        quest_id,
                        seconds,
                        result,
                        finish_quest: finish,
                        day: day(),
                        at: Utc::now(),
                        utc_offset_seconds: Local::now().offset().local_minus_utc(),
                    })
                })?;
                if self.state.active.is_none() {
                    self.presence = None;
                    self.focus = None;
                }
            }
            Command::Export { path, csv } => {
                if csv {
                    self.repo.export_csv(&self.state, &path)?;
                } else {
                    self.repo.export_json(&self.state, &path)?;
                }
                extra = json!({"file":path});
            }
            Command::PreviewImport { path } => {
                if self.state.active.as_ref().is_some_and(|a| a.strict) {
                    return Err(invalid("Завершите строгую сессию перед импортом данных").into());
                }
                self.pending = None;
                let imported = if path.extension().is_some_and(|v| v == "csv") {
                    Repository::read_csv(&path, &self.state)?
                } else {
                    Repository::read_import(&path)?
                };
                extra = json!({"preview":{"name":imported.settings.name,"skills":imported.skills.len(),"quests":imported.quests.len(),"sessions":imported.sessions.len()}});
                self.pending = Some(imported);
            }
            Command::ConfirmImport => {
                if self.state.active.as_ref().is_some_and(|a| a.strict) {
                    return Err(invalid("Завершите строгую сессию перед импортом данных").into());
                }
                let imported = self
                    .pending
                    .take()
                    .ok_or_else(|| invalid("Сначала выберите файл"))?;
                self.repo.replace(&mut self.state, imported)?;
                self.presence = None;
                self.focus = None;
            }
            Command::CancelImport => {
                self.pending = None;
            }
            Command::Backup => {
                extra = json!({"file":self.repo.backup()?});
            }
        }
        if compact && !settled && self.snapshot_day == day() {
            Ok(json!({"ok": true, "timer": {"active": self.state.active}}))
        } else {
            self.snapshot_day = day();
            Ok(self.response(extra))
        }
    }
    fn response(&self, extra: Value) -> Value {
        let s = &self.state;
        let today = day();
        let (l, current, next) = ascend_core::xp::level(ascend_core::xp::rated_milli(s));
        let d = ascend_core::discipline::calculate(s, today);
        let routine_today = s.routine_on(today).map(|version| {
            let checked = s.routine_completed(today);
            json!({"day":today,"items":version.items.iter().map(|item|json!({"id":item.id,"title":item.title,"completed":checked.contains(&item.id)})).collect::<Vec<_>>()})
        });
        let r = ascend_planner::recommend(s, today);
        let history:Vec<_>=ascend_planner::history(s,today,ascend_planner::history_span(s,today)).iter().map(|v|json!({"day":v.day,"minutes":v.minutes,"xp":v.xp,"fatigue":v.fatigue,"discipline":v.discipline})).collect();
        let targets: Vec<_> = s
            .targets
            .iter()
            .map(|t| json!({"id":t.id,"actual":ascend_core::balance::actual(s,t)}))
            .collect();
        let attrs: Vec<_> = ascend_core::character::attributes(s, today)
            .iter()
            .map(|(name, value)| json!({"name":name,"value":value}))
            .collect();
        json!({"ok":true,"state":s,"summary":{"today":today,"week":GameState::week(today),"level":l,"level_xp":current as f64/1000.0,"next_xp":next as f64/1000.0,"discipline":d.score,"preliminary":d.preliminary,"routine_score":d.routine.map(|v|v*100.0),"routine_today":routine_today,"balance":ascend_core::balance::development(s,GameState::week(today)),"suggested_minutes":r.suggested_minutes,"recommendation":r.title,"recommendation_detail":r.explanation,"proposed":ascend_planner::propose(s,today),"unlocked_skills":s.skills.iter().filter(|v|s.skill_unlocked(v)).map(|v|v.id).collect::<Vec<_>>(),"unlocked_quests":s.quests.iter().filter(|v|s.quest_unlocked(v)).map(|v|v.id).collect::<Vec<_>>(),"attributes":attrs,"history":history,"targets":targets,"directory":self.repo.directory},"extra":extra})
    }
}
const MAX_COMMAND_BYTES: u64 = 50 * 1024 * 1024;
fn read_command(input: &mut impl BufRead) -> io::Result<Option<Vec<u8>>> {
    let mut line = Vec::new();
    input
        .take(MAX_COMMAND_BYTES + 1)
        .read_until(b'\n', &mut line)?;
    if line.len() as u64 > MAX_COMMAND_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Команда больше 50 МБ",
        ));
    }
    Ok((!line.is_empty()).then_some(line))
}
fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    let path = args
        .iter()
        .position(|v| v == "--data-dir")
        .and_then(|i| args.get(i + 1))
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                .join("Library/Application Support/ASCEND")
        });
    let mut engine = match Engine::open(path) {
        Ok(v) => v,
        Err(e) => {
            println!("{}", json!({"ok":false,"error":e.to_string()}));
            return Err(e);
        }
    };
    let mut out = io::BufWriter::new(io::stdout().lock());
    let mut input = io::stdin().lock();
    loop {
        let line = match read_command(&mut input) {
            Ok(Some(line)) => line,
            Ok(None) => break,
            Err(error) => {
                writeln!(out, "{}", json!({"ok": false, "error": error.to_string()}))?;
                out.flush()?;
                break;
            }
        };
        let response = serde_json::from_slice::<Command>(&line)
            .map_err(|e| Box::new(e) as Box<dyn std::error::Error>)
            .and_then(|c| engine.run(c));
        let value = response.unwrap_or_else(|e| json!({"ok":false,"error":e.to_string()}));
        writeln!(out, "{value}")?;
        out.flush()?;
    }
    if let Some(a) = &mut engine.state.active {
        a.running = false;
        a.presence_confirmed = false;
        engine.repo.checkpoint(&engine.state)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn command_reader_bounds_unterminated_input_and_keeps_record_boundaries() {
        let mut input = io::Cursor::new(b"{\"command\":\"load\"}\n{\"command\":\"pause\"}");
        assert!(matches!(
            serde_json::from_slice::<Command>(&read_command(&mut input).unwrap().unwrap()).unwrap(),
            Command::Load
        ));
        assert!(matches!(
            serde_json::from_slice::<Command>(&read_command(&mut input).unwrap().unwrap()).unwrap(),
            Command::Pause
        ));
        assert!(read_command(&mut input).unwrap().is_none());
        let mut infinite = io::BufReader::new(io::repeat(b'x'));
        assert_eq!(
            read_command(&mut infinite).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
    }
    #[test]
    fn compact_snapshots_and_import_cancellation() {
        let directory = std::env::temp_dir().join(format!("ascend-compact-{}", Id::new_v4()));
        let mut engine = Engine::open(directory.clone()).unwrap();
        let cmd = |v| serde_json::from_value::<Command>(v).unwrap();
        assert!(
            engine
                .run(cmd(json!({"command":"tick"})))
                .unwrap()
                .get("state")
                .is_some()
        );
        let snapshot = engine
            .run(cmd(json!({"command":"tick", "compact":true})))
            .unwrap();
        assert!(snapshot.get("state").is_none());
        assert!(snapshot["timer"]["active"].is_null());
        engine.snapshot_day = day() - chrono::Duration::days(1);
        assert!(
            engine
                .run(cmd(json!({"command":"tick", "compact":true})))
                .unwrap()
                .get("summary")
                .is_some()
        );
        engine.pending = Some(engine.state.clone());
        engine.run(Command::CancelImport).unwrap();
        assert!(engine.pending.is_none());
        assert!(engine.run(Command::ConfirmImport).is_err());
        drop(engine);
        std::fs::remove_dir_all(directory).unwrap();
    }
}

#[cfg(test)]
mod strict_tests;
