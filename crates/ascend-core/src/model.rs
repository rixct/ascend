use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub type Id = Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Domain {
    Mind,
    Body,
    Organization,
    Social,
    Recovery,
}
impl Domain {
    pub const ALL: [Self; 5] = [
        Self::Mind,
        Self::Body,
        Self::Organization,
        Self::Social,
        Self::Recovery,
    ];
    pub fn label(self) -> &'static str {
        match self {
            Self::Mind => "Обучение",
            Self::Body => "Физическая форма",
            Self::Organization => "Самоорганизация",
            Self::Social => "Общение",
            Self::Recovery => "Восстановление",
        }
    }
}
impl std::fmt::Display for Domain {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.label())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Skill {
    pub id: Id,
    pub title: String,
    pub domain: Domain,
    pub description: String,
    pub xp_milli: u64,
    pub mastery: u8,
    pub evidence: Vec<String>,
    pub prerequisites: Vec<Id>,
    #[serde(flatten)]
    pub focus_rules: FocusRules,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FocusListMode {
    #[default]
    OnlyListed,
    ExceptListed,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "StoredFocusRules", into = "StoredFocusRules")]
pub struct FocusRules {
    pub mode: FocusListMode,
    /// Bundle identifiers.
    pub apps: Vec<String>,
    /// Domains. Subdomains also match.
    pub sites: Vec<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default)]
struct StoredFocusRules {
    focus_list_mode: FocusListMode,
    allowed_apps: Vec<String>,
    allowed_sites: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    excluded_apps: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    excluded_sites: Option<Vec<String>>,
}

impl From<StoredFocusRules> for FocusRules {
    fn from(stored: StoredFocusRules) -> Self {
        let mode = stored.focus_list_mode;
        let (apps, sites) = match mode {
            FocusListMode::OnlyListed => (stored.allowed_apps, stored.allowed_sites),
            FocusListMode::ExceptListed => (
                stored.excluded_apps.unwrap_or(stored.allowed_apps),
                stored.excluded_sites.unwrap_or(stored.allowed_sites),
            ),
        };
        Self { mode, apps, sites }
    }
}

impl From<FocusRules> for StoredFocusRules {
    fn from(rules: FocusRules) -> Self {
        let mut stored = Self {
            focus_list_mode: rules.mode,
            ..Self::default()
        };
        // Older releases ignore the exclusion fields and see an unrestricted timer.
        match rules.mode {
            FocusListMode::OnlyListed => {
                stored.allowed_apps = rules.apps;
                stored.allowed_sites = rules.sites;
            }
            FocusListMode::ExceptListed => {
                stored.excluded_apps = Some(rules.apps);
                stored.excluded_sites = Some(rules.sites);
            }
        }
        stored
    }
}
const FOCUS_LIMIT: usize = 24;
fn default_focus_confirmed() -> bool {
    true
}
/// Turn a pasted URL or host into the hostname the timer compares.
pub fn normalize_site(raw: &str) -> Option<String> {
    let mut text = raw.trim().to_ascii_lowercase();
    if text.is_empty() || text.len() > 300 {
        return None;
    }
    for prefix in ["https://", "http://"] {
        if let Some(rest) = text.strip_prefix(prefix) {
            text = rest.to_string();
        }
    }
    if let Some(end) = text.find(['/', '?', '#']) {
        text.truncate(end);
    }
    if let Some(at) = text.rfind('@') {
        text = text[at + 1..].to_string();
    }
    if let Some(rest) = text.strip_prefix("www.") {
        text = rest.to_string();
    }
    if let Some(colon) = text.find(':') {
        let port = &text[colon + 1..];
        if port.is_empty() || !port.bytes().all(|byte| byte.is_ascii_digit()) {
            return None;
        }
        text.truncate(colon);
    }
    let text = text.trim_matches('.').to_string();
    if text.is_empty() || text.len() > 253 || (text != "localhost" && !text.contains('.')) {
        return None;
    }
    let labels = text.split('.');
    if labels.clone().any(|label| {
        label.is_empty()
            || label.len() > 63
            || label.starts_with('-')
            || label.ends_with('-')
            || !label
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    }) {
        return None;
    }
    Some(text)
}
fn normalize_bundle(raw: &str) -> Option<String> {
    let text = raw.trim();
    if text.is_empty()
        || text.len() > 255
        || text.starts_with('.')
        || text.ends_with('.')
        || text.contains("..")
        || !text
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'.' || byte == b'-')
    {
        return None;
    }
    Some(text.to_string())
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("Invalid app or website focus list")]
pub struct InvalidFocusList;

pub fn normalize_focus_lists(
    apps: impl IntoIterator<Item = impl AsRef<str>>,
    sites: impl IntoIterator<Item = impl AsRef<str>>,
) -> Result<(Vec<String>, Vec<String>), InvalidFocusList> {
    let mut allowed_apps = Vec::new();
    for raw in apps {
        let bundle = normalize_bundle(raw.as_ref()).ok_or(InvalidFocusList)?;
        if !allowed_apps.contains(&bundle) {
            allowed_apps.push(bundle);
        }
    }
    let mut allowed_sites = Vec::new();
    for raw in sites {
        let host = normalize_site(raw.as_ref()).ok_or(InvalidFocusList)?;
        if !allowed_sites.contains(&host) {
            allowed_sites.push(host);
        }
    }
    if allowed_apps.len() > FOCUS_LIMIT || allowed_sites.len() > FOCUS_LIMIT {
        return Err(InvalidFocusList);
    }
    Ok((allowed_apps, allowed_sites))
}
impl FocusRules {
    pub fn normalized(mut self) -> Result<Self, InvalidFocusList> {
        (self.apps, self.sites) = normalize_focus_lists(self.apps, self.sites)?;
        Ok(self)
    }
    pub fn restricts_focus(&self) -> bool {
        !self.apps.is_empty() || !self.sites.is_empty()
    }
    pub fn allows_focus(
        &self,
        bundle_id: &str,
        host: Option<&str>,
        site_unavailable: bool,
    ) -> bool {
        let bundle_id = bundle_id.trim();
        if !self.restricts_focus() || bundle_id == "dev.ascend.desktop" {
            return true;
        }
        let listed = self.apps.iter().any(|id| id == bundle_id)
            || host.and_then(normalize_site).is_some_and(|host| {
                self.sites.iter().any(|site| {
                    host == *site
                        || host
                            .strip_suffix(site.as_str())
                            .is_some_and(|prefix| prefix.ends_with('.'))
                })
            });
        match self.mode {
            FocusListMode::OnlyListed => listed,
            FocusListMode::ExceptListed => {
                !listed && !bundle_id.is_empty() && (self.sites.is_empty() || !site_unavailable)
            }
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum QuestKind {
    Daily,
    Project,
    Habit,
}
impl QuestKind {
    pub const ALL: [Self; 3] = [Self::Daily, Self::Project, Self::Habit];
}
impl std::fmt::Display for QuestKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Daily => "Задача",
            Self::Project => "Этап проекта",
            Self::Habit => "Привычка",
        })
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Status {
    Planned,
    Active,
    Paused,
    Completed,
    Cancelled,
    Missed,
}
impl Status {
    pub fn label(self) -> &'static str {
        match self {
            Self::Planned => "Запланировано",
            Self::Active => "В работе",
            Self::Paused => "На паузе",
            Self::Completed => "Выполнено",
            Self::Cancelled => "Отменено",
            Self::Missed => "Пропущено",
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestStep {
    pub id: Id,
    pub title: String,
    pub done: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Quest {
    pub id: Id,
    pub title: String,
    pub outcome: String,
    pub skill_id: Id,
    pub kind: QuestKind,
    pub priority: u8,
    pub estimate_minutes: u32,
    #[serde(default = "default_planned_sessions")]
    pub planned_sessions: u32,
    pub difficulty: f64,
    pub bonus_milli: u64,
    pub deadline: Option<NaiveDate>,
    pub dependencies: Vec<Id>,
    #[serde(default)]
    pub steps: Vec<QuestStep>,
    pub status: Status,
    pub created_at: DateTime<Utc>,
}
pub fn default_planned_sessions() -> u32 {
    1
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub id: Id,
    pub quest_id: Id,
    pub skill_id: Id,
    pub day: NaiveDate,
    pub completed_at: DateTime<Utc>,
    pub utc_offset_seconds: i32,
    pub seconds: u32,
    pub credited_seconds: u32,
    pub estimate_minutes: u32,
    pub difficulty: f64,
    pub reward_milli: u64,
    pub explanation: String,
    pub result: String,
    pub completed_quest: bool,
    #[serde(default)]
    pub strict: bool,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActiveSession {
    pub id: Id,
    pub quest_id: Id,
    pub elapsed_seconds: u32,
    pub running: bool,
    #[serde(default)]
    pub strict: bool,
    #[serde(default)]
    pub presence_confirmed: bool,
    /// False while a skill's app or site list is set and the front window is not on it.
    #[serde(default = "default_focus_confirmed")]
    pub focus_confirmed: bool,
    pub notes: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanItem {
    pub quest_id: Id,
    pub weight: f64,
    pub estimate_minutes: u32,
    pub completed: bool,
    pub excused: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DailyPlan {
    pub day: NaiveDate,
    pub created_at: DateTime<Utc>,
    pub items: Vec<PlanItem>,
    pub rest: bool,
    pub reason: String,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TargetUnit {
    Minutes,
    Sessions,
    Days,
    Milestones,
}
impl TargetUnit {
    pub const ALL: [Self; 4] = [Self::Minutes, Self::Sessions, Self::Days, Self::Milestones];
}
impl std::fmt::Display for TargetUnit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Minutes => "мин",
            Self::Sessions => "занятий",
            Self::Days => "дней",
            Self::Milestones => "этапов",
        })
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeeklyTarget {
    pub id: Id,
    pub week: NaiveDate,
    pub skill_id: Id,
    pub target: f64,
    pub weight: f64,
    pub unit: TargetUnit,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckIn {
    pub day: NaiveDate,
    pub energy: u8,
    pub fatigue: u8,
    pub focus: u8,
    pub available_minutes: u32,
    pub unwell: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JournalEntry {
    pub id: Id,
    pub day: NaiveDate,
    pub text: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GameEvent {
    pub id: Id,
    pub at: DateTime<Utc>,
    pub kind: String,
    pub description: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Settings {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar: Option<String>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub bio: String,
    pub dark: bool,
    pub growth_percent: u8,
    pub daily_minutes: u32,
    pub onboarded: bool,
    #[serde(default)]
    pub strict_mode: bool,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            name: "Исследователь".into(),
            avatar: None,
            bio: String::new(),
            dark: true,
            growth_percent: 10,
            daily_minutes: 90,
            onboarded: false,
            strict_mode: false,
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoutineItem {
    pub id: Id,
    pub title: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoutineVersion {
    pub effective_from: NaiveDate,
    pub enabled: bool,
    pub items: Vec<RoutineItem>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoutineDay {
    pub day: NaiveDate,
    pub completed: Vec<Id>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GameState {
    pub schema_version: u32,
    pub created_at: DateTime<Utc>,
    pub character_xp_milli: u64,
    pub settings: Settings,
    pub skills: Vec<Skill>,
    pub quests: Vec<Quest>,
    pub sessions: Vec<Session>,
    pub plans: Vec<DailyPlan>,
    pub targets: Vec<WeeklyTarget>,
    pub checkins: Vec<CheckIn>,
    pub journal: Vec<JournalEntry>,
    pub events: Vec<GameEvent>,
    pub active: Option<ActiveSession>,
    #[serde(default)]
    pub routine_versions: Vec<RoutineVersion>,
    #[serde(default)]
    pub routine_days: Vec<RoutineDay>,
}
impl Default for GameState {
    fn default() -> Self {
        Self {
            schema_version: 1,
            created_at: Utc::now(),
            character_xp_milli: 0,
            settings: Settings::default(),
            skills: vec![],
            quests: vec![],
            sessions: vec![],
            plans: vec![],
            targets: vec![],
            checkins: vec![],
            journal: vec![],
            events: vec![],
            active: None,
            routine_versions: vec![],
            routine_days: vec![],
        }
    }
}
impl GameState {
    pub fn skill_name(&self, id: Id) -> &str {
        self.skills
            .iter()
            .find(|s| s.id == id)
            .map(|s| s.title.as_str())
            .unwrap_or("Навык")
    }
    pub fn week(day: NaiveDate) -> NaiveDate {
        use chrono::Datelike;
        day - chrono::Duration::days(day.weekday().num_days_from_monday() as i64)
    }
    pub fn event(&mut self, kind: &str, description: impl Into<String>) {
        self.events.push(GameEvent {
            id: Id::new_v4(),
            at: Utc::now(),
            kind: kind.into(),
            description: description.into(),
        });
    }
    pub fn skill_unlocked(&self, skill: &Skill) -> bool {
        skill
            .prerequisites
            .iter()
            .all(|id| self.skills.iter().any(|s| s.id == *id && s.mastery > 0))
    }
    pub fn habit_days(&self, id: Id) -> usize {
        self.sessions
            .iter()
            .filter(|s| s.quest_id == id && s.completed_quest)
            .map(|s| s.day)
            .collect::<std::collections::HashSet<_>>()
            .len()
    }
    pub fn quest_fulfilled(&self, q: &Quest) -> bool {
        if q.status == Status::Completed {
            return true;
        }
        q.kind == QuestKind::Habit && self.habit_days(q.id) >= q.planned_sessions.max(7) as usize
    }
    /// Cancelled and missed quests are set aside. A skill with no remaining quests is ready to verify once.
    pub fn skill_quests_completed(&self, id: Id) -> bool {
        self.quests
            .iter()
            .filter(|q| q.skill_id == id && !matches!(q.status, Status::Cancelled | Status::Missed))
            .all(|q| self.quest_fulfilled(q))
    }
    pub fn quest_unlocked(&self, q: &Quest) -> bool {
        q.dependencies.iter().all(|id| {
            self.quests
                .iter()
                .any(|p| p.id == *id && self.quest_fulfilled(p))
        }) && self
            .skills
            .iter()
            .any(|s| s.id == q.skill_id && self.skill_unlocked(s))
    }
    pub fn focus_allows(
        &self,
        quest_id: Id,
        bundle_id: &str,
        host: Option<&str>,
        site_unavailable: bool,
    ) -> bool {
        self.quests
            .iter()
            .find(|quest| quest.id == quest_id)
            .and_then(|quest| self.skills.iter().find(|skill| skill.id == quest.skill_id))
            .is_some_and(|skill| {
                skill
                    .focus_rules
                    .allows_focus(bundle_id, host, site_unavailable)
            })
    }
    pub fn restricts_focus(&self, quest_id: Id) -> bool {
        self.quests
            .iter()
            .find(|quest| quest.id == quest_id)
            .and_then(|quest| self.skills.iter().find(|skill| skill.id == quest.skill_id))
            .is_some_and(|skill| skill.focus_rules.restricts_focus())
    }
    /// A deadline that has passed closes the quest as missed. The active session is left alone
    /// so a sitting already underway can still be saved.
    pub fn settle_deadlines(&mut self, today: chrono::NaiveDate) {
        let active = self.active.as_ref().map(|session| session.quest_id);
        let mut missed = Vec::new();
        for quest in &mut self.quests {
            if quest.deadline.is_some_and(|deadline| deadline < today)
                && matches!(
                    quest.status,
                    Status::Planned | Status::Active | Status::Paused
                )
                && active != Some(quest.id)
            {
                quest.status = Status::Missed;
                missed.push(quest.title.clone());
            }
        }
        for title in missed {
            self.event("quest_missed", format!("{title}: срок истёк"));
        }
    }
    pub fn add_skill(&mut self, title: String, domain: Domain, prerequisites: Vec<Id>) -> Id {
        let id = Id::new_v4();
        self.skills.push(Skill {
            id,
            title,
            domain,
            description: String::new(),
            xp_milli: 0,
            mastery: 0,
            evidence: vec![],
            prerequisites,
            focus_rules: FocusRules::default(),
        });
        id
    }
    pub fn starter_skills(&mut self) {
        if !self.skills.is_empty() {
            return;
        }
        let rust = self.add_skill("Основы Rust".into(), Domain::Mind, vec![]);
        let arch = self.add_skill("Архитектура и тесты".into(), Domain::Mind, vec![rust]);
        self.add_skill("Async / Tokio".into(), Domain::Mind, vec![rust]);
        let desktop = self.add_skill("Разработка macOS".into(), Domain::Mind, vec![arch]);
        self.add_skill("Готовое приложение".into(), Domain::Mind, vec![desktop]);
        self.add_skill("Математика".into(), Domain::Mind, vec![]);
        self.add_skill("Планирование".into(), Domain::Organization, vec![]);
        self.add_skill("Посильная активность".into(), Domain::Body, vec![]);
        self.add_skill("Режим восстановления".into(), Domain::Recovery, vec![]);
        self.add_skill("Регулярное питание".into(), Domain::Recovery, vec![]);
        self.add_skill("Коммуникация".into(), Domain::Social, vec![]);
    }
}
