#!/usr/bin/env python3
"""Check that the tree's requirements match the real engine, including merged branches."""
import tempfile

from bridge_smoke import Engine


def main():
    with tempfile.TemporaryDirectory(prefix="ASCEND-skill-tree-") as directory:
        engine = Engine(directory)
        engine.ok("onboard", name="Skill tree test", minutes=90)

        def add(title, parents):
            response = engine.ok("create_skill", title=title, domain="Mind", prerequisites=parents)
            return next(s["id"] for s in response["state"]["skills"] if s["title"] == title)

        first = add("Foundation A", [])
        second = add("Foundation B", [])
        merged = add("Merged skill", [first, second])
        final = add("Final skill", [merged])
        response = engine.ok("load")
        assert merged not in response["summary"]["unlocked_skills"]
        assert not engine.send("verify", id=merged, evidence="Premature verification")["ok"]
        response = engine.ok(
            "create_quest", title="Practice only", outcome="Practice completed", skill_id=first,
            kind="Daily", priority=2, minutes=25, difficulty=1.0, bonus=0, deadline=None, dependencies=[])
        quest = response["state"]["quests"][-1]["id"]
        engine.ok("start", id=quest)
        active = engine.ok("load")["state"]["active"]
        response = engine.ok("complete", id=active["id"], quest_id=quest, seconds=1500,
                             result="Completed a practice session", finish=True)
        assert next(s for s in response["state"]["skills"] if s["id"] == first)["xp_milli"] > 0
        assert merged not in response["summary"]["unlocked_skills"], "XP must not unlock a branch"
        response = engine.ok("verify", id=first, evidence="Verified foundation A")
        assert merged not in response["summary"]["unlocked_skills"], "Every prerequisite is required"
        response = engine.ok("verify", id=second, evidence="Verified foundation B")
        assert merged in response["summary"]["unlocked_skills"]
        assert final not in response["summary"]["unlocked_skills"]
        response = engine.ok("verify", id=merged, evidence="Verified merged skill")
        assert final in response["summary"]["unlocked_skills"]
        engine.close()
        engine = Engine(directory)
        assert final in engine.ok("load")["summary"]["unlocked_skills"]
        engine.ok("delete_skill", id=first)
        assert first not in next(s for s in engine.ok("load")["state"]["skills"] if s["id"] == merged)["prerequisites"]
        engine.close()
    print("Skill tree bridge OK: XP vs milestones, all prerequisites, chained unlocking, persistence, deletion")


if __name__ == "__main__":
    main()
