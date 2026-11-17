#!/usr/bin/env python3
"""Exercise the real Rust IPC process used by the native macOS interface."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


class Engine:
    def __init__(self, directory):
        self.process = subprocess.Popen(
            [str(ROOT / "target/release/ascend-engine"), "--data-dir", str(directory)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        )

    def send(self, command, **values):
        self.process.stdin.write(json.dumps(dict(command=command, **values)) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        assert line, "Engine closed its output"
        return json.loads(line)

    def ok(self, command, **values):
        response = self.send(command, **values)
        assert response["ok"], response
        return response

    def close(self):
        self.process.stdin.close()
        assert self.process.wait(timeout=10) == 0


def main():
    with tempfile.TemporaryDirectory(prefix="ASCEND-bridge-test-") as directory:
        directory = Path(directory)
        engine = Engine(directory)
        initial = engine.ok("load")
        assert not initial["state"]["settings"]["onboarded"]
        state = engine.ok("onboard", name="Проверка", minutes=90)["state"]
        # Avatars travel with the local profile and survive export/import and restarts.
        avatar = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6fGQAAAAASUVORK5CYII="
        settings = engine.ok("settings", name="Alex", minutes=90, growth=10, avatar=avatar)["state"]["settings"]
        assert settings["name"] == "Alex" and settings["avatar"] == avatar
        # Older clients omit avatar; an ordinary settings save must retain it.
        assert engine.ok("settings", name="Alex", minutes=90, growth=10)["state"]["settings"]["avatar"] == avatar
        assert not engine.send("settings", name="Rejected", minutes=90, growth=10, avatar="a" * 1_048_577)["ok"]
        assert engine.ok("load")["state"]["settings"]["name"] == "Alex"
        skill = state["skills"][0]["id"]
        assert not engine.send("unknown_command")["ok"]
        assert not engine.send("create_quest", title="", outcome="", skill_id=skill,
                               kind="Daily", priority=2, minutes=25, difficulty=1.0,
                               bonus=0, deadline=None, dependencies=[])["ok"]
        assert not engine.ok("load")["state"]["quests"]
        state = engine.ok("create_quest", title="Нативная форма", outcome="Результат сохранён",
                          skill_id=skill, kind="Daily", priority=2, minutes=25,
                          difficulty=1.0, bonus=0, deadline=None, dependencies=[])["state"]
        quest = state["quests"][0]["id"]
        engine.ok("plan", ids=[quest])
        active = engine.ok("start", id=quest)["state"]["active"]
        engine.ok("notes", text="Восстановление заметки")
        engine.close()
        engine = Engine(directory)
        reloaded = engine.ok("load")["state"]
        assert reloaded["settings"]["avatar"] == avatar
        restored = reloaded["active"]
        assert not restored["running"] and restored["id"] == active["id"]
        assert restored["notes"] == "Восстановление заметки"
        completion = dict(id=active["id"], quest_id=quest, seconds=1500,
                          result="Проверено сохранение", finish=True)
        state = engine.ok("complete", **completion)["state"]
        assert state["character_xp_milli"] == 10000
        assert state["plans"][0]["items"][0]["completed"]
        assert engine.ok("complete", **completion)["state"]["character_xp_milli"] == 10000
        for csv, suffix in [(False, "json"), (True, "csv")]:
            path = str(directory / f"export.{suffix}")
            engine.ok("export", path=path, csv=csv)
            preview = engine.ok("preview_import", path=path)["extra"]["preview"]
            assert preview["sessions"] == 1
            assert engine.ok("confirm_import")["state"]["character_xp_milli"] == 10000
        assert engine.ok("load")["state"]["settings"]["avatar"] == avatar
        # Legacy JSON has no avatar field and must continue to load.
        legacy = json.loads((directory / "export.json").read_text())
        legacy["settings"].pop("avatar")
        legacy_path = directory / "legacy.json"
        legacy_path.write_text(json.dumps(legacy))
        engine.ok("preview_import", path=str(legacy_path))
        assert engine.ok("confirm_import")["state"]["settings"].get("avatar") is None
        engine.ok("settings", name="Alex", minutes=90, growth=10, avatar=avatar)
        assert engine.ok("settings", name="Alex", minutes=90, growth=10, avatar="")["state"]["settings"].get("avatar") is None
        engine.close()
        engine = Engine(directory)
        assert engine.ok("load")["state"]["character_xp_milli"] == 10000
        removed = reloaded["skills"][0]
        after = engine.ok("delete_skill", id=removed["id"])["state"]
        assert all(skill["id"] != removed["id"] for skill in after["skills"])
        assert all(quest["skill_id"] != removed["id"] for quest in after["quests"])
        assert engine.ok("load")["state"]["character_xp_milli"] == 0
        assert not engine.send("delete_skill", id=removed["id"])["ok"]
        engine.close()
    with tempfile.TemporaryDirectory(prefix="ASCEND-bridge-empty-") as directory:
        engine = Engine(Path(directory))
        empty = engine.ok("onboard", name="Пустой", minutes=30, starter=False)["state"]
        assert empty["settings"]["onboarded"] and not empty["skills"]
        engine.close()
    print("Native bridge OK: validation, plan, timer recovery, result, idempotency, JSON/CSV, restart, avatar, legacy profiles, delete skill, empty start")


if __name__ == "__main__":
    main()
