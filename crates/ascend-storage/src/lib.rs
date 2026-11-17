use ascend_core::*;
use chrono::Local;
use rusqlite::{Connection, params};
use serde::{Serialize, de::DeserializeOwned};
use std::{
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("SQLite: {0}")]
    Sql(#[from] rusqlite::Error),
    #[error("Файл: {0}")]
    Io(#[from] std::io::Error),
    #[error("JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("CSV: {0}")]
    Csv(#[from] csv::Error),
    #[error("{0}")]
    Invalid(#[from] EngineError),
    #[error("Данные изменены другим экземпляром ASCEND. Перезапустите приложение.")]
    Conflict,
    #[error("Неподдерживаемая версия базы данных")]
    Version,
}
pub type Result<T> = std::result::Result<T, StorageError>;
pub struct Repository {
    conn: Connection,
    pub directory: PathBuf,
    revision: i64,
}
impl Repository {
    pub fn open(directory: impl AsRef<Path>) -> Result<(Self, GameState)> {
        let directory = directory.as_ref().to_path_buf();
        fs::create_dir_all(&directory)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        }
        let conn = Connection::open(directory.join("ascend.sqlite3"))?;
        conn.busy_timeout(Duration::from_secs(5))?;
        conn.execute_batch(
            "PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;",
        )?;
        let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version > 1 {
            return Err(StorageError::Version);
        }
        conn.execute_batch(include_str!("schema.sql"))?;
        let exists: i64 = conn.query_row("SELECT count(*) FROM profiles", [], |r| r.get(0))?;
        if exists == 0 {
            conn.execute(
                "INSERT INTO profiles(id,revision,data) VALUES(1,0,?1)",
                [serde_json::to_string(&GameState::default())?],
            )?;
        }
        let mut repo = Self {
            conn,
            directory,
            revision: 0,
        };
        let mut state = repo.load()?;
        // A crash or shutdown never silently counts time spent away.
        if let Some(active) = &mut state.active {
            active.running = false;
            active.presence_confirmed = false;
        }
        repo.daily_backup()?;
        Ok((repo, state))
    }
    fn rows<T: DeserializeOwned>(&self, table: &str) -> Result<Vec<T>> {
        let mut stmt = self
            .conn
            .prepare(&format!("SELECT data FROM {table} ORDER BY rowid"))?;
        let mut rows = stmt.query([])?;
        let mut values = Vec::new();
        while let Some(row) = rows.next()? {
            let json: String = row.get(0)?;
            values.push(serde_json::from_str(&json)?);
        }
        Ok(values)
    }
    pub fn load(&mut self) -> Result<GameState> {
        // All tables must belong to the same revision, even while another app writes.
        let tx = self.conn.unchecked_transaction()?;
        let (rev, json): (i64, String) =
            self.conn
                .query_row("SELECT revision,data FROM profiles WHERE id=1", [], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })?;
        let mut s: GameState = serde_json::from_str(&json)?;
        s.skills = self.rows("skills")?;
        s.quests = self.rows("quests")?;
        s.sessions = self.rows("sessions")?;
        s.plans = self.rows("daily_plans")?;
        s.targets = self.rows("weekly_targets")?;
        s.checkins = self.rows("checkins")?;
        s.journal = self.rows("journal_entries")?;
        s.events = self.rows("game_events")?;
        s.validate()?;
        tx.commit()?;
        self.revision = rev;
        Ok(s)
    }
    pub fn save(&mut self, state: &GameState) -> Result<()> {
        state.validate()?;
        #[derive(Serialize)]
        struct Metadata<'a> {
            schema_version: u32,
            created_at: &'a chrono::DateTime<chrono::Utc>,
            character_xp_milli: u64,
            settings: &'a Settings,
            active: &'a Option<ActiveSession>,
            routine_versions: &'a [RoutineVersion],
            routine_days: &'a [RoutineDay],
            skills: [(); 0],
            quests: [(); 0],
            sessions: [(); 0],
            plans: [(); 0],
            targets: [(); 0],
            checkins: [(); 0],
            journal: [(); 0],
            events: [(); 0],
        }
        let meta = Metadata {
            schema_version: state.schema_version,
            created_at: &state.created_at,
            character_xp_milli: state.character_xp_milli,
            settings: &state.settings,
            active: &state.active,
            routine_versions: &state.routine_versions,
            routine_days: &state.routine_days,
            skills: [],
            quests: [],
            sessions: [],
            plans: [],
            targets: [],
            checkins: [],
            journal: [],
            events: [],
        };
        let tx = self.conn.transaction()?;
        let changed = tx.execute(
            "UPDATE profiles SET revision=revision+1,data=?1 WHERE id=1 AND revision=?2",
            params![serde_json::to_string(&meta)?, self.revision],
        )?;
        if changed != 1 {
            return Err(StorageError::Conflict);
        }
        tx.execute_batch("DELETE FROM sessions; DELETE FROM quests; DELETE FROM skills; DELETE FROM daily_plans; DELETE FROM weekly_targets; DELETE FROM checkins; DELETE FROM journal_entries; DELETE FROM game_events;")?;
        fn put(
            tx: &rusqlite::Transaction<'_>,
            table: &str,
            id: String,
            v: &impl Serialize,
        ) -> Result<()> {
            tx.prepare_cached(&format!("INSERT INTO {table}(id,data) VALUES(?1,?2)"))?
                .execute(params![id, serde_json::to_string(v)?])?;
            Ok(())
        }
        for s in &state.skills {
            put(&tx, "skills", s.id.to_string(), s)?;
        }
        for q in &state.quests {
            tx.prepare_cached("INSERT INTO quests(id,skill_id,data) VALUES(?1,?2,?3)")?
                .execute(params![
                    q.id.to_string(),
                    q.skill_id.to_string(),
                    serde_json::to_string(q)?
                ])?;
        }
        for s in &state.sessions {
            tx.prepare_cached("INSERT INTO sessions(id,quest_id,skill_id,reward_milli,data) VALUES(?1,?2,?3,?4,?5)")?
                .execute(params![s.id.to_string(),s.quest_id.to_string(),s.skill_id.to_string(),s.reward_milli as i64,serde_json::to_string(s)?])?;
        }
        for p in &state.plans {
            put(&tx, "daily_plans", p.day.to_string(), p)?;
        }
        for t in &state.targets {
            put(&tx, "weekly_targets", t.id.to_string(), t)?;
        }
        for c in &state.checkins {
            put(&tx, "checkins", c.day.to_string(), c)?;
        }
        for j in &state.journal {
            put(&tx, "journal_entries", j.id.to_string(), j)?;
        }
        for e in &state.events {
            put(&tx, "game_events", e.id.to_string(), e)?;
        }
        tx.commit()?;
        self.revision += 1;
        Ok(())
    }
    pub fn checkpoint(&mut self, state: &GameState) -> Result<()> {
        let active = serde_json::to_string(&state.active)?;
        let changed=self.conn.execute("UPDATE profiles SET data=json_set(data,'$.active',json(?1)),revision=revision+1 WHERE id=1 AND revision=?2",params![active,self.revision])?;
        if changed != 1 {
            return Err(StorageError::Conflict);
        }
        self.revision += 1;
        Ok(())
    }
    /// Mutate a candidate copy; failed validation or disk writes leave the displayed state intact.
    pub fn apply<T>(
        &mut self,
        state: &mut GameState,
        f: impl FnOnce(&mut GameState) -> std::result::Result<T, EngineError>,
    ) -> Result<T> {
        let mut next = state.clone();
        let result = f(&mut next)?;
        self.save(&next)?;
        *state = next;
        Ok(result)
    }
    pub fn backup(&self) -> Result<PathBuf> {
        let dir = self.directory.join("backups");
        fs::create_dir_all(&dir)?;
        let path = dir.join(format!(
            "ascend-{}.sqlite3",
            Local::now().format("%Y%m%d-%H%M%S-%f")
        ));
        let mut dest = Connection::open(&path)?;
        rusqlite::backup::Backup::new(&self.conn, &mut dest)?.run_to_completion(
            128,
            Duration::from_millis(5),
            None,
        )?;
        Ok(path)
    }
    pub fn daily_backup(&self) -> Result<()> {
        let dir = self.directory.join("backups");
        fs::create_dir_all(&dir)?;
        let prefix = format!("ascend-{}", Local::now().format("%Y%m%d"));
        let mut files = fs::read_dir(&dir)?
            .filter_map(|v| v.ok())
            .map(|v| v.path())
            .filter(|p| p.extension().is_some_and(|v| v == "sqlite3"))
            .collect::<Vec<_>>();
        if !files.iter().any(|p| {
            p.file_name()
                .is_some_and(|n| n.to_string_lossy().starts_with(&prefix))
        }) {
            files.push(self.backup()?);
        }
        files.sort();
        let remove = files.len().saturating_sub(14);
        for f in files.into_iter().take(remove) {
            fs::remove_file(f)?;
        }
        Ok(())
    }
    pub fn export_json(&self, state: &GameState, path: &Path) -> Result<()> {
        if path.extension().is_none_or(|v| v != "json") {
            return Err(std::io::Error::other(
                "Для экспорта JSON выберите файл с расширением .json",
            )
            .into());
        }
        atomic_write(path, &serde_json::to_vec_pretty(state)?)?;
        Ok(())
    }
    pub fn read_import(path: &Path) -> Result<GameState> {
        use std::io::Read;
        let mut input = import_reader(path)?;
        let mut bytes = Vec::new();
        input.read_to_end(&mut bytes)?;
        check_import_limit(&input)?;
        let mut state: GameState = serde_json::from_slice(&bytes)?;
        state.validate()?;
        if let Some(a) = &mut state.active {
            a.running = false;
            a.presence_confirmed = false;
        }
        Ok(state)
    }
    pub fn replace(&mut self, state: &mut GameState, mut imported: GameState) -> Result<PathBuf> {
        if let Some(active) = &mut imported.active {
            active.running = false;
            active.presence_confirmed = false;
        }
        imported.validate()?;
        let backup = self.backup()?;
        imported.event(
            "import",
            "Импортированы локальные данные; предыдущая база сохранена",
        );
        self.save(&imported)?;
        *state = imported;
        Ok(backup)
    }
    pub fn export_csv(&self, state: &GameState, path: &Path) -> Result<()> {
        let mut w = csv::Writer::from_writer(Vec::new());
        w.write_record([
            "id",
            "quest_id",
            "skill_id",
            "seconds",
            "completed_quest",
            "strict",
            "day",
            "completed_utc",
            "utc_offset_seconds",
            "quest",
            "skill",
            "minutes",
            "credited_minutes",
            "xp",
            "result",
            "explanation",
        ])?;
        for s in &state.sessions {
            let title = state
                .quests
                .iter()
                .find(|q| q.id == s.quest_id)
                .map(|q| q.title.as_str())
                .unwrap_or("");
            // Spreadsheet formula injection is escaped only in CSV; original JSON remains exact.
            let safe = |v: &str| {
                if v.starts_with(['=', '+', '-', '@', '\t', '\r', '\'']) {
                    format!("'{v}")
                } else {
                    v.to_owned()
                }
            };
            w.write_record([
                s.id.to_string(),
                s.quest_id.to_string(),
                s.skill_id.to_string(),
                s.seconds.to_string(),
                s.completed_quest.to_string(),
                s.strict.to_string(),
                s.day.to_string(),
                s.completed_at.to_rfc3339(),
                s.utc_offset_seconds.to_string(),
                safe(title),
                safe(state.skill_name(s.skill_id)),
                format!("{:.2}", s.seconds as f64 / 60.0),
                format!("{:.2}", s.credited_seconds as f64 / 60.0),
                format!("{:.3}", s.reward_milli as f64 / 1000.0),
                safe(&s.result),
                safe(&s.explanation),
            ])?;
        }
        w.flush()?;
        let bytes = w
            .into_inner()
            .map_err(|e| std::io::Error::other(e.to_string()))?;
        atomic_write(path, &bytes)?;
        Ok(())
    }
    pub fn read_csv(path: &Path, base: &GameState) -> Result<GameState> {
        let mut reader = csv::Reader::from_reader(import_reader(path)?);
        let headers = reader.headers()?.clone();
        let mut next = base.clone();
        // CSV is historical replay, not a running session. Keep the preference and
        // active timer intact, but do not require today's camera lease for old rows.
        let active = next.active.take();
        let strict_mode = next.settings.strict_mode;
        next.settings.strict_mode = false;
        for row in reader.records() {
            let row = row?;
            let get = |name: &str| -> Result<&str> {
                headers
                    .iter()
                    .position(|h| h == name)
                    .and_then(|i| row.get(i))
                    .ok_or_else(|| EngineError::Invalid(format!("Нет столбца CSV: {name}")).into())
            };
            let parse_error = || EngineError::Invalid("Некорректное значение в CSV".into());
            let result = get("result")?;
            let result = if ["''", "'=", "'+", "'-", "'@", "'\t", "'\r"]
                .iter()
                .any(|prefix| result.starts_with(prefix))
            {
                &result[1..]
            } else {
                result
            };
            let quest_id: Id = get("quest_id")?.parse().map_err(|_| parse_error())?;
            let skill_id: Id = get("skill_id")?.parse().map_err(|_| parse_error())?;
            if !next
                .quests
                .iter()
                .any(|q| q.id == quest_id && q.skill_id == skill_id)
            {
                return Err(EngineError::Invalid(
                    "Для импорта CSV нужны существующие квесты и навыки с теми же ID".into(),
                )
                .into());
            }
            let session_id: Id = get("id")?.parse().map_err(|_| parse_error())?;
            let was_present = next.sessions.iter().any(|s| s.id == session_id);
            next.complete(Completion {
                id: session_id,
                quest_id,
                seconds: get("seconds")?.parse().map_err(|_| parse_error())?,
                result: result.into(),
                finish_quest: get("completed_quest")?.parse().map_err(|_| parse_error())?,
                day: get("day")?.parse().map_err(|_| parse_error())?,
                at: chrono::DateTime::parse_from_rfc3339(get("completed_utc")?)
                    .map_err(|_| parse_error())?
                    .with_timezone(&chrono::Utc),
                utc_offset_seconds: get("utc_offset_seconds")?
                    .parse()
                    .map_err(|_| parse_error())?,
            })?;
            if !was_present
                && let Some(value) = headers
                    .iter()
                    .position(|h| h == "strict")
                    .and_then(|i| row.get(i))
            {
                let strict: bool = value.parse().map_err(|_| parse_error())?;
                if let Some(session) = next.sessions.iter_mut().find(|s| s.id == session_id) {
                    session.strict = strict;
                }
            }
        }
        check_import_limit(&reader.into_inner())?;
        next.settings.strict_mode = strict_mode;
        next.active =
            active.filter(|active| !next.sessions.iter().any(|session| session.id == active.id));
        next.validate()?;
        if let Some(a) = &mut next.active {
            a.running = false;
            a.presence_confirmed = false;
        }
        Ok(next)
    }
}
const IMPORT_LIMIT: u64 = 50 * 1024 * 1024;
fn import_reader(path: &Path) -> std::io::Result<std::io::Take<fs::File>> {
    use std::io::Read;
    let file = fs::File::open(path)?;
    if file.metadata()?.len() > IMPORT_LIMIT {
        return Err(std::io::Error::other("Файл больше 50 МБ"));
    }
    // Bound the actual read too: the file can grow after the metadata check.
    Ok(file.take(IMPORT_LIMIT + 1))
}
fn check_import_limit(input: &std::io::Take<fs::File>) -> std::io::Result<()> {
    if input.limit() == 0 {
        Err(std::io::Error::other("Файл больше 50 МБ"))
    } else {
        Ok(())
    }
}
fn atomic_write(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let temp = path.with_file_name(format!(
        ".{}.{}.tmp",
        path.file_name().unwrap_or_default().to_string_lossy(),
        Id::new_v4()
    ));
    let result = (|| {
        use std::io::Write;
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        fs::rename(&temp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn dir() -> PathBuf {
        std::env::temp_dir().join(format!("ascend-test-{}", Id::new_v4()))
    }
    #[test]
    fn roundtrip_conflict_backup_and_import() {
        let dir = dir();
        let (mut a, mut s) = Repository::open(&dir).unwrap();
        s.starter_skills();
        a.save(&s).unwrap();
        let (mut b, mut stale) = Repository::open(&dir).unwrap();
        a.apply(&mut s, |s| {
            s.settings.name = "Анна".into();
            Ok(())
        })
        .unwrap();
        stale.settings.name = "Старая копия".into();
        assert!(matches!(b.save(&stale), Err(StorageError::Conflict)));
        let path = dir.join("export.json");
        a.export_json(&s, &path).unwrap();
        let imported = Repository::read_import(&path).unwrap();
        assert_eq!(imported.settings.name, "Анна");
        let backup = a.backup().unwrap();
        let check = Connection::open(backup).unwrap();
        assert_eq!(
            check
                .query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0))
                .unwrap(),
            "ok"
        );
        let loaded = a.load().unwrap();
        assert_eq!(loaded.skills.len(), 11);
        drop(a);
        drop(b);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn failed_command_never_mutates_or_writes() {
        let dir = dir();
        let (mut r, mut s) = Repository::open(&dir).unwrap();
        let before = s.settings.name.clone();
        let result = r.apply(&mut s, |s| {
            s.settings.name = "bad".into();
            Err::<(), _>(EngineError::Missing)
        });
        assert!(result.is_err());
        assert_eq!(s.settings.name, before);
        assert_eq!(r.load().unwrap().settings.name, before);
        drop(r);
        fs::remove_dir_all(dir).unwrap();
    }
    fn add_quest(s: &mut GameState) -> Id {
        s.starter_skills();
        let id = Id::new_v4();
        s.create_quest(Quest {
            id,
            title: "Сохранение".into(),
            outcome: "Проверена запись".into(),
            skill_id: s.skills[0].id,
            kind: QuestKind::Daily,
            priority: 2,
            estimate_minutes: 25,
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
        id
    }
    #[test]
    fn active_checkpoint_restores_paused_without_offline_time() {
        let dir = dir();
        let (mut r, mut s) = Repository::open(&dir).unwrap();
        let q = add_quest(&mut s);
        r.save(&s).unwrap();
        s.active = Some(ActiveSession {
            id: Id::new_v4(),
            quest_id: q,
            elapsed_seconds: 137,
            running: true,
            strict: false,
            presence_confirmed: false,
            focus_confirmed: true,
            notes: "Заметка".into(),
        });
        r.checkpoint(&s).unwrap();
        drop(r);
        let (r, s) = Repository::open(&dir).unwrap();
        let a = s.active.unwrap();
        assert_eq!(a.elapsed_seconds, 137);
        assert!(!a.running);
        assert_eq!(a.notes, "Заметка");
        assert_eq!(s.character_xp_milli, 0);
        drop(r);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn csv_replays_engine_and_duplicate_import_is_idempotent() {
        let dir = dir();
        let (r, mut s) = Repository::open(&dir).unwrap();
        let q = add_quest(&mut s);
        let base = s.clone();
        s.complete(Completion {
            id: Id::new_v4(),
            quest_id: q,
            seconds: 1500,
            result: "=Результат, с запятой и \"кавычками\"".into(),
            finish_quest: true,
            day: Local::now().date_naive(),
            at: chrono::Utc::now(),
            utc_offset_seconds: 10800,
        })
        .unwrap();
        let path = dir.join("sessions.csv");
        r.export_csv(&s, &path).unwrap();
        let merged = Repository::read_csv(&path, &base).unwrap();
        assert_eq!(merged.character_xp_milli, 10000);
        assert_eq!(merged.sessions[0].result, s.sessions[0].result);
        let twice = Repository::read_csv(&path, &merged).unwrap();
        assert_eq!(twice.sessions.len(), 1);
        assert_eq!(twice.character_xp_milli, 10000);
        drop(r);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn csv_history_replay_preserves_strict_preference_and_session_flags() {
        let dir = dir();
        let (r, mut source) = Repository::open(&dir).unwrap();
        let quest = add_quest(&mut source);
        let mut base = source.clone();
        base.settings.strict_mode = true;
        source
            .complete(Completion {
                id: Id::new_v4(),
                quest_id: quest,
                seconds: 1500,
                result: "Historical practice".into(),
                finish_quest: true,
                day: Local::now().date_naive(),
                at: chrono::Utc::now(),
                utc_offset_seconds: 0,
            })
            .unwrap();
        source.sessions[0].strict = true;
        source.sessions[0].explanation = "=IMPORTDATA(\"example\")".into();
        let path = dir.join("history.csv");
        r.export_csv(&source, &path).unwrap();
        assert!(fs::read_to_string(&path).unwrap().contains("'=IMPORTDATA"));
        let imported = Repository::read_csv(&path, &base).unwrap();
        assert!(imported.settings.strict_mode);
        assert!(imported.sessions[0].strict);
        assert_eq!(imported.sessions[0].seconds, 1500);
        assert_eq!(base.sessions.len(), 0);
        assert!(imported.active.is_none());
        drop(r);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn loads_keep_one_revision_during_concurrent_writes() {
        use std::sync::{Arc, Barrier};
        let dir = dir();
        let (mut reader, mut initial) = Repository::open(&dir).unwrap();
        initial.starter_skills();
        initial.settings.name = "0".into();
        for skill in &mut initial.skills {
            skill.title = "0".into();
        }
        reader.save(&initial).unwrap();
        let barrier = Arc::new(Barrier::new(2));
        let writer_barrier = barrier.clone();
        let writer_dir = dir.clone();
        let writer = std::thread::spawn(move || {
            let (mut writer, mut state) = Repository::open(writer_dir).unwrap();
            writer_barrier.wait();
            for revision in 1..=100 {
                state.settings.name = revision.to_string();
                for skill in &mut state.skills {
                    skill.title = revision.to_string();
                }
                writer.save(&state).unwrap();
            }
        });
        barrier.wait();
        for _ in 0..200 {
            let state = reader.load().unwrap();
            assert!(
                state
                    .skills
                    .iter()
                    .all(|skill| skill.title == state.settings.name)
            );
        }
        writer.join().unwrap();
        assert_eq!(reader.load().unwrap().settings.name, "100");
        drop(reader);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn imports_remain_bounded_if_a_file_grows_after_opening() {
        use std::io::Read;
        let dir = dir();
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("growing.json");
        fs::write(&path, b"{}").unwrap();
        let mut reader = import_reader(&path).unwrap();
        fs::OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap()
            .set_len(IMPORT_LIMIT + 4096)
            .unwrap();
        let copied = std::io::copy(&mut reader, &mut std::io::sink()).unwrap();
        assert_eq!(copied, IMPORT_LIMIT + 1);
        assert!(check_import_limit(&reader).is_err());
        assert!(import_reader(&path).is_err());
        assert_eq!(reader.read(&mut [0; 1]).unwrap(), 0);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn failed_atomic_export_removes_its_temporary_file() {
        let dir = dir();
        fs::create_dir_all(dir.join("occupied")).unwrap();
        assert!(atomic_write(&dir.join("occupied"), b"data").is_err());
        let entries: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(entries, vec![std::ffi::OsString::from("occupied")]);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn csv_unknown_foreign_keys_do_not_change_base() {
        let dir = dir();
        let (r, mut s) = Repository::open(&dir).unwrap();
        let q = add_quest(&mut s);
        s.complete(Completion {
            id: Id::new_v4(),
            quest_id: q,
            seconds: 60,
            result: "Тест".into(),
            finish_quest: true,
            day: Local::now().date_naive(),
            at: chrono::Utc::now(),
            utc_offset_seconds: 0,
        })
        .unwrap();
        let path = dir.join("sessions.csv");
        r.export_csv(&s, &path).unwrap();
        let base = GameState::default();
        assert!(Repository::read_csv(&path, &base).is_err());
        assert_eq!(base.sessions.len(), 0);
        drop(r);
        fs::remove_dir_all(dir).unwrap();
    }
}
