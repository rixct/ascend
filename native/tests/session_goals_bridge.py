#!/usr/bin/env python3
import json
from pathlib import Path
import tempfile

from bridge_smoke import Engine


def main():
    with tempfile.TemporaryDirectory(prefix="ASCEND-session-goals-") as directory:
        directory = Path(directory)
        engine = Engine(directory)
        state = engine.ok("onboard", name="Study sessions", minutes=90)["state"]
        skill = state["skills"][0]["id"]
        fields = dict(title="Study a course", outcome="Complete exercises", skill_id=skill,
                      kind="Daily", priority=2, minutes=25, difficulty=1.0, bonus=0,
                      deadline=None, dependencies=[])
        for invalid in [0, -1, 10001, 1.5, None]:
            assert not engine.send("create_quest", **fields, planned_sessions=invalid)["ok"]
        assert not engine.ok("load")["state"]["quests"]
        state = engine.ok("create_quest", **fields, planned_sessions=5)["state"]
        quest = state["quests"][0]["id"]
        assert state["quests"][0]["planned_sessions"] == 5
        # Exceeding the plan keeps the task open; only explicit completion closes it.
        for _ in range(8):
            active = engine.ok("start", id=quest)["state"]["active"]
            state = engine.ok("complete", id=active["id"], quest_id=quest, seconds=1500,
                              result="Saved a study session", finish=False)["state"]
            assert state["quests"][0]["status"] == "Active"
        assert len(state["sessions"]) == 8
        assert sum(s["seconds"] for s in state["sessions"]) == 12000
        engine.close()
        engine = Engine(directory)
        state = engine.ok("load")["state"]
        assert state["quests"][0]["planned_sessions"] == 5 and len(state["sessions"]) == 8
        active = engine.ok("start", id=quest)["state"]["active"]
        state = engine.ok("complete", id=active["id"], quest_id=quest, seconds=1500,
                          result="Course completed", finish=True)["state"]
        assert state["quests"][0]["status"] == "Completed"
        path = directory / "export.json"
        engine.ok("export", path=str(path), csv=False)
        data = json.loads(path.read_text())
        assert data["quests"][0]["planned_sessions"] == 5
        engine.ok("preview_import", path=str(path))
        assert engine.ok("confirm_import")["state"]["quests"][0]["planned_sessions"] == 5
        data["quests"][0].pop("planned_sessions")
        path.write_text(json.dumps(data))
        engine.ok("preview_import", path=str(path))
        assert engine.ok("confirm_import")["state"]["quests"][0]["planned_sessions"] == 1
        fields["title"] = "Legacy client"
        assert engine.ok("create_quest", **fields)["state"]["quests"][-1]["planned_sessions"] == 1
        engine.close()
    print("Session goals bridge OK: validation, 8 x 25 min, manual completion, restart, export/import, legacy defaults")


if __name__ == "__main__":
    main()
