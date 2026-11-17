use super::*;

struct Fixture(Engine, PathBuf, Id);
impl Fixture {
    fn new(strict: bool) -> Self {
        let dir = std::env::temp_dir().join(format!("ascend-strict-{}", Id::new_v4()));
        let mut e = Engine::open(dir.clone()).unwrap();
        e.run(
            serde_json::from_value(json!({"command":"onboard","name":"Test","minutes":90}))
                .unwrap(),
        )
        .unwrap();
        let skill = e.state.skills[0].id;
        e.run(serde_json::from_value(json!({"command":"create_quest","title":"Study","outcome":"Exercises","skill_id":skill,"kind":"Daily","priority":2,"minutes":25,"difficulty":1,"bonus":0,"dependencies":[]})).unwrap()).unwrap();
        let quest = e.state.quests[0].id;
        e.run(Command::Start { id: quest, strict }).unwrap();
        Self(e, dir, quest)
    }
    fn id(&self) -> Id {
        self.0.state.active.as_ref().unwrap().id
    }
    fn heartbeat(&mut self, present: bool, timestamp: u64) {
        self.0
            .run(Command::Presence {
                id: self.id(),
                present,
                observed_at_ms: timestamp,
            })
            .unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.1);
    }
}

#[test]
fn strict_clock_requires_a_fresh_matching_lease_and_expires() {
    let mut f = Fixture::new(true);
    f.0.last = Instant::now() - Duration::from_secs(2);
    f.0.advance().unwrap();
    assert_eq!(f.0.state.active.as_ref().unwrap().elapsed_seconds, 0);
    f.heartbeat(true, unix_millis() - 2000);
    assert!(!f.0.state.active.as_ref().unwrap().presence_confirmed);
    f.heartbeat(true, unix_millis() + 2000);
    assert!(!f.0.state.active.as_ref().unwrap().presence_confirmed);
    f.0.run(Command::Presence {
        id: Id::new_v4(),
        present: true,
        observed_at_ms: unix_millis(),
    })
    .unwrap();
    assert!(f.0.presence.is_none());
    f.heartbeat(true, unix_millis() - 900);
    assert!(
        f.0.presence
            .unwrap()
            .until
            .saturating_duration_since(Instant::now())
            <= Duration::from_millis(700)
    );
    f.heartbeat(true, unix_millis());
    assert!(f.0.state.active.as_ref().unwrap().presence_confirmed);
    // Intersect elapsed time with a lease that has already expired: exactly 2 seconds.
    let now = Instant::now();
    f.0.last = now - Duration::from_secs(4);
    f.0.presence = Some(PresenceLease {
        id: f.id(),
        from: now - Duration::from_secs(3),
        until: now - Duration::from_secs(1),
    });
    f.0.advance().unwrap();
    assert_eq!(f.0.state.active.as_ref().unwrap().elapsed_seconds, 2);
    assert!(!f.0.state.active.as_ref().unwrap().presence_confirmed);
    // Keep the clock monotonic: rewinding last would replay an already credited lease.
    f.0.advance().unwrap();
    assert_eq!(f.0.state.active.as_ref().unwrap().elapsed_seconds, 2);
    f.heartbeat(true, unix_millis());
    f.heartbeat(false, unix_millis());
    assert!(f.0.presence.is_none());
    assert!(!f.0.state.active.as_ref().unwrap().presence_confirmed);
}

#[test]
fn pause_sleep_and_restore_do_not_reuse_camera_confirmation() {
    let mut f = Fixture::new(true);
    f.heartbeat(true, unix_millis());
    f.0.run(Command::Pause).unwrap();
    f.heartbeat(true, unix_millis());
    assert!(!f.0.state.active.as_ref().unwrap().running);
    assert!(f.0.presence.is_none());
    f.0.run(Command::Pause).unwrap();
    assert!(!f.0.state.active.as_ref().unwrap().presence_confirmed);
    f.heartbeat(true, unix_millis());
    f.0.last = Instant::now() - Duration::from_secs(10);
    f.0.advance().unwrap();
    assert!(!f.0.state.active.as_ref().unwrap().running);
    assert_eq!(f.0.state.active.as_ref().unwrap().elapsed_seconds, 0);
    f.0.run(Command::Pause).unwrap();
    f.heartbeat(true, unix_millis());
    let restored = Engine::open(f.1.clone()).unwrap();
    let active = restored.state.active.as_ref().unwrap();
    assert!(active.strict);
    assert!(!active.running && !active.presence_confirmed);
    assert!(restored.presence.is_none());
}

#[test]
fn strict_time_is_authoritative_and_discard_awards_nothing() {
    let mut f = Fixture::new(true);
    f.0.state.active.as_mut().unwrap().elapsed_seconds = 120;
    let complete = |id, seconds| Command::Complete {
        id,
        quest_id: f.2,
        seconds,
        result: "Solved exercises".into(),
        finish: false,
    };
    assert!(f.0.run(complete(f.id(), 121)).is_err());
    assert!(f.0.run(complete(Id::new_v4(), 60)).is_err());
    assert!(f.0.state.sessions.is_empty());
    f.0.run(complete(f.id(), 120)).unwrap();
    assert!(f.0.state.sessions[0].strict);
    assert_eq!(f.0.state.sessions[0].seconds, 120);
    let xp = f.0.state.character_xp_milli;
    f.0.run(Command::Start {
        id: f.2,
        strict: true,
    })
    .unwrap();
    assert!(
        f.0.run(Command::PreviewImport {
            path: f.1.join("missing.json")
        })
        .unwrap_err()
        .to_string()
        .contains("строгую")
    );
    f.0.pending = Some(f.0.state.clone());
    assert!(f.0.run(Command::ConfirmImport).is_err());
    f.0.run(Command::DiscardSession { id: Id::new_v4() })
        .unwrap();
    assert!(f.0.state.active.is_some());
    f.0.run(Command::DiscardSession { id: f.id() }).unwrap();
    assert!(f.0.state.active.is_none());
    assert_eq!(f.0.state.sessions.len(), 1);
    assert_eq!(f.0.state.character_xp_milli, xp);
    assert_eq!(f.0.state.quests[0].status, Status::Planned);
}

#[test]
fn normal_and_legacy_sessions_keep_their_existing_behavior() {
    let mut f = Fixture::new(false);
    f.heartbeat(true, unix_millis());
    assert!(f.0.presence.is_none());
    f.0.last = Instant::now() - Duration::from_secs(2);
    f.0.advance().unwrap();
    assert_eq!(f.0.state.active.as_ref().unwrap().elapsed_seconds, 2);
    let value =
        json!({"id":f.id(),"quest_id":f.2,"elapsed_seconds":20,"running":false,"notes":"Legacy"});
    let old: ActiveSession = serde_json::from_value(value).unwrap();
    assert!(!old.strict && !old.presence_confirmed && old.focus_confirmed);
    f.0.run(Command::Complete {
        id: f.id(),
        quest_id: f.2,
        seconds: 1500,
        result: "Manual time".into(),
        finish: false,
    })
    .unwrap();
    assert!(!f.0.state.sessions[0].strict);
}

#[test]
fn a_listed_app_or_site_is_required_before_the_timer_counts() {
    let mut f = Fixture::new(false);
    let skill = f.0.state.quests[0].skill_id;
    let entry =
        f.0.state
            .skills
            .iter_mut()
            .find(|item| item.id == skill)
            .unwrap();
    entry.allowed_apps = vec!["com.apple.dt.Xcode".into()];
    entry.allowed_sites = vec!["github.com".into()];
    f.0.last = Instant::now() - Duration::from_secs(2);
    f.0.advance().unwrap();
    assert_eq!(f.0.state.active.as_ref().unwrap().elapsed_seconds, 0);
    assert!(!f.0.state.active.as_ref().unwrap().focus_confirmed);

    f.0.run(Command::Focus {
        bundle_id: "com.apple.Safari".into(),
        host: Some("notgithub.com".into()),
    })
    .unwrap();
    f.0.last = Instant::now() - Duration::from_secs(2);
    f.0.advance().unwrap();
    assert_eq!(f.0.state.active.as_ref().unwrap().elapsed_seconds, 0);

    f.0.run(Command::Focus {
        bundle_id: "com.apple.Safari".into(),
        host: Some("https://docs.github.com/rust".into()),
    })
    .unwrap();
    let now = Instant::now();
    let lease = f.0.focus.as_mut().unwrap();
    lease.from = now - Duration::from_secs(2);
    lease.until = now + Duration::from_secs(2);
    f.0.last = now - Duration::from_secs(2);
    f.0.advance().unwrap();
    assert!(f.0.state.active.as_ref().unwrap().elapsed_seconds >= 2);
    assert!(f.0.state.active.as_ref().unwrap().focus_confirmed);
}

#[test]
fn strict_presence_and_focus_must_overlap() {
    let mut f = Fixture::new(true);
    let skill = f.0.state.quests[0].skill_id;
    f.0.state
        .skills
        .iter_mut()
        .find(|item| item.id == skill)
        .unwrap()
        .allowed_apps = vec!["com.apple.dt.Xcode".into()];
    let now = Instant::now();
    f.0.last = now - Duration::from_secs(4);
    f.0.presence = Some(PresenceLease {
        id: f.id(),
        from: now - Duration::from_secs(4),
        until: now,
    });
    f.0.focus = Some(FocusLease {
        id: f.id(),
        from: now - Duration::from_secs(2),
        until: now,
        allowed: true,
    });
    f.0.advance().unwrap();
    assert_eq!(f.0.state.active.as_ref().unwrap().elapsed_seconds, 2);
}

#[test]
fn resetting_the_session_timer_returns_it_to_zero() {
    let mut f = Fixture::new(false);
    f.0.state.active.as_mut().unwrap().elapsed_seconds = 40;
    f.0.run(Command::ResetTimer).unwrap();
    let active = f.0.state.active.as_ref().unwrap();
    assert_eq!(active.elapsed_seconds, 0);
    assert!(active.running);
    assert!(f.0.state.sessions.is_empty());
}

#[test]
fn strict_history_survives_json_and_csv_round_trips() {
    let mut f = Fixture::new(true);
    let base = f.0.state.clone();
    f.0.state.active.as_mut().unwrap().elapsed_seconds = 125;
    f.0.run(Command::Complete {
        id: f.id(),
        quest_id: f.2,
        seconds: 125,
        result: "Done".into(),
        finish: false,
    })
    .unwrap();
    let json_path = f.1.join("history.json");
    f.0.repo.export_json(&f.0.state, &json_path).unwrap();
    assert!(Repository::read_import(&json_path).unwrap().sessions[0].strict);
    let csv_path = f.1.join("history.csv");
    f.0.repo.export_csv(&f.0.state, &csv_path).unwrap();
    let mut import_base = base;
    import_base.active = None;
    let imported = Repository::read_csv(&csv_path, &import_base).unwrap();
    assert!(imported.sessions[0].strict);
    assert_eq!(imported.sessions[0].seconds, 125);
    let mut legacy = serde_json::to_value(&f.0.state).unwrap();
    legacy["sessions"][0]
        .as_object_mut()
        .unwrap()
        .remove("strict");
    let old: GameState = serde_json::from_value(legacy).unwrap();
    assert!(!old.sessions[0].strict);
}

#[test]
fn notes_for_an_old_session_never_replace_current_notes() {
    let mut f = Fixture::new(false);
    f.0.run(Command::Notes {
        id: Some(f.id()),
        text: "Current".into(),
        compact: true,
    })
    .unwrap();
    f.0.run(Command::Notes {
        id: Some(Id::new_v4()),
        text: "Stale".into(),
        compact: true,
    })
    .unwrap();
    assert_eq!(f.0.state.active.as_ref().unwrap().notes, "Current");
    f.0.run(Command::Notes {
        id: None,
        text: "Legacy client".into(),
        compact: true,
    })
    .unwrap();
    assert_eq!(f.0.state.active.as_ref().unwrap().notes, "Legacy client");
}

#[test]
fn changing_active_skill_focus_rules_invalidates_the_old_permission() {
    let mut f = Fixture::new(false);
    let skill = f.0.state.quests[0].skill_id;
    let change = |apps: Vec<String>| Command::UpdateSkill {
        id: skill,
        title: "Study".into(),
        domain: Domain::Mind,
        prerequisites: vec![],
        allowed_apps: apps,
        allowed_sites: vec![],
    };
    f.0.run(change(vec!["com.apple.dt.Xcode".into()])).unwrap();
    f.0.run(Command::Focus {
        bundle_id: "com.apple.dt.Xcode".into(),
        host: None,
    })
    .unwrap();
    assert!(f.0.state.active.as_ref().unwrap().focus_confirmed);
    assert!(f.0.focus.is_some());
    f.0.run(change(vec!["com.apple.Terminal".into()])).unwrap();
    assert!(f.0.focus.is_none());
    assert!(!f.0.state.active.as_ref().unwrap().focus_confirmed);
    let before = f.0.state.active.as_ref().unwrap().elapsed_seconds;
    f.0.last = Instant::now() - Duration::from_secs(2);
    f.0.advance().unwrap();
    assert_eq!(f.0.state.active.as_ref().unwrap().elapsed_seconds, before);
    f.0.run(Command::Focus {
        bundle_id: "com.apple.Terminal".into(),
        host: None,
    })
    .unwrap();
    assert!(f.0.state.active.as_ref().unwrap().focus_confirmed);
    f.0.run(change(vec![])).unwrap();
    assert!(f.0.state.active.as_ref().unwrap().focus_confirmed);
}

#[test]
fn moving_active_quest_invalidates_the_old_skills_focus_permission() {
    let mut f = Fixture::new(false);
    let next_skill = f.0.state.skills[1].id;
    f.0.run(Command::UpdateSkill {
        id: next_skill,
        title: "New skill".into(),
        domain: Domain::Mind,
        prerequisites: vec![],
        allowed_apps: vec!["com.apple.Terminal".into()],
        allowed_sites: vec![],
    })
    .unwrap();
    f.0.run(Command::Focus {
        bundle_id: "com.apple.dt.Xcode".into(),
        host: None,
    })
    .unwrap();
    let mut quest = serde_json::to_value(&f.0.state.quests[0]).unwrap();
    let object = quest.as_object_mut().unwrap();
    object.insert("command".into(), json!("update_quest"));
    object.insert("skill_id".into(), json!(next_skill));
    object.insert("minutes".into(), json!(25));
    object.insert("bonus".into(), json!(0));
    f.0.run(serde_json::from_value(quest).unwrap()).unwrap();
    assert!(f.0.focus.is_none());
    assert!(!f.0.state.active.as_ref().unwrap().focus_confirmed);
}

#[test]
fn compact_tick_publishes_quests_settled_after_an_active_session_ends() {
    let mut f = Fixture::new(false);
    f.0.state.quests[0].deadline = Some(day() - chrono::Duration::days(1));
    f.0.run(Command::DiscardSession { id: f.id() }).unwrap();
    let response = f.0.run(Command::Tick { compact: true }).unwrap();
    assert!(response.get("state").is_some());
    assert_eq!(response["state"]["quests"][0]["status"], "Missed");
    assert_eq!(f.0.state.quests[0].status, Status::Missed);
}

#[test]
fn normal_completion_cannot_orphan_or_replace_another_active_session() {
    let mut f = Fixture::new(false);
    let session = f.id();
    let complete = |id, quest_id| Command::Complete {
        id,
        quest_id,
        seconds: 60,
        result: "Done".into(),
        finish: true,
    };
    assert!(f.0.run(complete(Id::new_v4(), f.2)).is_err());
    assert!(f.0.run(complete(session, Id::new_v4())).is_err());
    assert_eq!(f.id(), session);
    assert_eq!(f.0.state.quests[0].status, Status::Active);
    assert!(f.0.state.sessions.is_empty());
    f.0.run(complete(session, f.2)).unwrap();
    assert!(f.0.state.active.is_none());
    assert_eq!(f.0.state.quests[0].status, Status::Completed);
    f.0.run(complete(session, f.2)).unwrap();
    assert_eq!(f.0.state.sessions.len(), 1);
}
