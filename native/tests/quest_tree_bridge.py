#!/usr/bin/env python3
import tempfile
from bridge_smoke import Engine


def main():
    with tempfile.TemporaryDirectory(prefix="ASCEND-quest-tree-") as directory:
        engine = Engine(directory)
        state = engine.ok("onboard", name="Quest tree", minutes=90)["state"]
        skill = state["skills"][0]["id"]
        def add(title, parents=None, kind="Daily"):
            r = engine.ok("create_quest", title=title, outcome="Verified outcome", skill_id=skill,
                          kind=kind, priority=2, minutes=25, planned_sessions=1,
                          difficulty=1.0, bonus=0, deadline=None, dependencies=parents or [])
            return next(q["id"] for q in r["state"]["quests"] if q["title"] == title)
        def finish(id, close=True):
            active = engine.ok("start", id=id)["state"]["active"]
            return engine.ok("complete", id=active["id"], quest_id=id, seconds=1500,
                             result="Saved outcome", finish=close)
        first = add("Foundations")
        next_id = add("Next step", [first])
        final = add("Final project", [first, next_id])
        assert not engine.send("verify", id=skill, evidence="Cannot skip unfinished quests")["ok"]
        assert not engine.send("start", id=next_id)["ok"]
        finish(first, close=False)
        assert not engine.send("verify", id=skill, evidence="Partial practice does not count")["ok"]
        finish(first)
        assert next_id in engine.ok("load")["summary"]["unlocked_quests"]
        assert final not in engine.ok("load")["summary"]["unlocked_quests"]
        engine.ok("status", id=next_id, status="Cancelled")
        assert not engine.send("verify", id=skill, evidence="Cancellation is not completion")["ok"]
        engine.ok("status", id=next_id, status="Planned")
        finish(next_id)
        assert final in engine.ok("load")["summary"]["unlocked_quests"]
        finish(final)
        state = engine.ok("verify", id=skill, evidence="All steps are completed")["state"]
        assert next(s for s in state["skills"] if s["id"] == skill)["mastery"] == 1
        habit = add("Daily review", kind="Habit")
        assert not engine.send("verify", id=skill, evidence="New quests need completion too")["ok"]
        finish(habit)
        assert not engine.send("verify", id=skill, evidence="One day does not establish a habit")["ok"]
        engine.close()
        engine = Engine(directory)
        state = engine.ok("load")["state"]
        assert next(s for s in state["skills"] if s["id"] == skill)["mastery"] == 1
        assert next(q for q in state["quests"] if q["id"] == final)["dependencies"] == [first, next_id]
        engine.close()
    print("Quest tree bridge OK: dependencies, merged branches, partial sessions, cancelled quests, mastery gate, habits, restart")


if __name__ == "__main__":
    main()
