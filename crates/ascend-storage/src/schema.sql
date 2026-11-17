BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS profiles(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL,data TEXT NOT NULL CHECK(json_valid(data)));
CREATE TABLE IF NOT EXISTS skills(id TEXT PRIMARY KEY,data TEXT NOT NULL CHECK(json_valid(data)));
CREATE TABLE IF NOT EXISTS quests(id TEXT PRIMARY KEY,skill_id TEXT NOT NULL REFERENCES skills(id),data TEXT NOT NULL CHECK(json_valid(data)));
CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,quest_id TEXT NOT NULL REFERENCES quests(id),skill_id TEXT NOT NULL REFERENCES skills(id),reward_milli INTEGER NOT NULL CHECK(reward_milli>=0),data TEXT NOT NULL CHECK(json_valid(data)));
CREATE TABLE IF NOT EXISTS daily_plans(id TEXT PRIMARY KEY,data TEXT NOT NULL CHECK(json_valid(data)));
CREATE TABLE IF NOT EXISTS weekly_targets(id TEXT PRIMARY KEY,data TEXT NOT NULL CHECK(json_valid(data)));
CREATE TABLE IF NOT EXISTS checkins(id TEXT PRIMARY KEY,data TEXT NOT NULL CHECK(json_valid(data)));
CREATE TABLE IF NOT EXISTS journal_entries(id TEXT PRIMARY KEY,data TEXT NOT NULL CHECK(json_valid(data)));
CREATE TABLE IF NOT EXISTS game_events(id TEXT PRIMARY KEY,data TEXT NOT NULL CHECK(json_valid(data)));
CREATE VIEW IF NOT EXISTS skill_xp_ledger AS SELECT id,skill_id,reward_milli,json_extract(data,'explanation') AS explanation FROM sessions;
CREATE INDEX IF NOT EXISTS sessions_skill ON sessions(skill_id);
PRAGMA user_version=1;
COMMIT;

