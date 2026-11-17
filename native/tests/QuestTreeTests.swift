import CoreGraphics
import Foundation

@main struct QuestTreeTests {
  static func quest(
    _ id: String, skill: String = "local", parents: [String] = [], kind: String = "Daily"
  ) -> Quest {
    Quest(
      id: id, title: id, outcome: "Verified work", skill_id: skill, kind: kind, priority: 2,
      estimate_minutes: 25, planned_sessions: 1, difficulty: 1, bonus_milli: 0,
      deadline: nil, dependencies: parents, status: "Planned")
  }
  static func main() {
    let quests = [
      quest("G", skill: "foreign"), quest("A", skill: "foreign", parents: ["G"]),
      quest("B", parents: ["A"]), quest("C", parents: ["B"]), quest("unrelated", skill: "foreign"),
    ]
    let scope = QuestTreeScope(skillID: "local", quests: quests)
    precondition(scope.members.map(\.id) == ["B", "C"])
    precondition(scope.quests.map(\.id) == ["G", "A", "B", "C"])
    precondition(scope.externalIDs == ["G", "A"])
    precondition(scope.selection(retaining: "A", fulfilled: [], unlocked: ["B"]) == "A")
    let detached = QuestTreeScope(skillID: "local", quests: [
      quest("A", skill: "foreign"), quest("B"), quest("C", parents: ["B"]),
    ])
    precondition(detached.selection(retaining: "A", fulfilled: [], unlocked: ["B"]) == "B")
    precondition(detached.selection(retaining: nil, fulfilled: ["B"], unlocked: ["B", "C"]) == "C")
    precondition(PrimaryDependency.updating(["A", "B", "C"], selected: "A") == ["A", "B", "C"])
    precondition(PrimaryDependency.updating(["A", "B", "C"], selected: "D") == ["D", "B", "C"])
    precondition(PrimaryDependency.updating(["A", "B", "C"], selected: "B") == ["B", "A", "C"])
    precondition(PrimaryDependency.updating(["A", "B", "C"], selected: "") == ["B", "C"])
    precondition(PrimaryDependency.updating([], selected: "A") == ["A"])
    let graph = SkillTreeLayout(quests: scope.quests)
    precondition(graph.columns == [["G"], ["A"], ["B"], ["C"]])
    precondition(graph.ancestors(of: "C", quests: scope.quests) == ["G", "A", "B", "C"])
    precondition(QuestTreeScope(skillID: "empty", quests: quests).quests.isEmpty)
    let cyclic = [quest("A", parents: ["B"]), quest("B", parents: ["A"])]
    precondition(QuestTreeScope(skillID: "local", quests: cyclic).quests.count == 2)
    precondition(SkillTreeLayout(quests: cyclic).unresolved.count == 2)
    let missing = [quest("M", parents: ["missing"])]
    precondition(
      SkillTreeLayout(quests: QuestTreeScope(skillID: "local", quests: missing).quests).unresolved
        == ["M"])
    let chain = (0..<1000).map { quest("q\($0)", parents: $0 == 0 ? [] : ["q\($0-1)"]) }
    precondition(SkillTreeLayout(quests: chain).frames.count == 1000)

    var state = GameState(
      settings: Profile(
        name: "Test", avatar: nil, bio: nil, dark: true, growth_percent: 10,
        daily_minutes: 90, onboarded: true), character_xp_milli: 0, skills: [],
      quests: [quest("task"), quest("habit", kind: "Habit")], sessions: [], plans: [],
      targets: [], checkins: [], journal: [], events: [], active: nil)
    precondition(!state.skillQuestsCompleted("local"))
    state.quests[0].status = "Cancelled"
    precondition(!state.questFulfilled(state.quests[0]))
    state.quests[0].status = "Completed"
    precondition(state.fulfilledQuestIDs == ["task"])
    state.sessions = [
      Session(
        id: "s", quest_id: "habit", skill_id: "local", day: "2026-11-15", seconds: 60,
        reward_milli: 2000, explanation: "Habit", result: "Done", completed_quest: true)
    ]
    precondition(state.fulfilledQuestIDs == ["task"])
    precondition(!state.skillQuestsCompleted("local"))
    precondition(!state.questFulfilled(state.quests[1]))
    precondition(state.verificationCap("local") == 1)

    var empty = state
    empty.quests = []
    precondition(empty.skillQuestsCompleted("local"))
    precondition(empty.verificationCap("local") == 1)
    var missed = quest("missed")
    missed.status = "Missed"
    empty.quests = [missed]
    precondition(empty.skillQuestsCompleted("local"))
    precondition(empty.verificationCap("local") == 1)

    var habit = quest("days", kind: "Habit")
    habit.planned_sessions = 1
    var days = state
    days.quests = [habit]
    days.sessions = (1...6).map { offset in
      Session(
        id: "day-\(offset)", quest_id: "days", skill_id: "local", day: "2026-11-\(offset)",
        seconds: 60, reward_milli: 1000, explanation: "Habit", result: "Done",
        completed_quest: true)
    }
    precondition(!days.questFulfilled(days.quests[0]))
    days.sessions.append(
      Session(
        id: "day-7", quest_id: "days", skill_id: "local", day: "2026-11-07", seconds: 60,
        reward_milli: 1000, explanation: "Habit", result: "Done", completed_quest: true))
    precondition(days.habitDays("days") == 7)
    precondition(days.questFulfilled(days.quests[0]))
    precondition(days.skillQuestsCompleted("local"))
    precondition(days.verificationCap("local") == 1)
    // Large recurring-quest histories use the same distinct-day rule as individual queries.
    var large = days
    large.quests = (0..<1000).map { quest("habit-\($0)", kind: "Habit") }
    large.sessions = (0..<1000).flatMap { index in
      (1...7).map { day in
        Session(id: "\(index)-\(day)", quest_id: "habit-\(index)", skill_id: "local",
          day: "2026-11-\(day)", seconds: 60, reward_milli: 1000, explanation: "Habit",
          result: "Done", completed_quest: true)
      }
    }
    large.sessions.append(large.sessions[0])
    large.quests.append(quest("not-started", kind: "Habit"))
    precondition(large.fulfilledQuestIDs.count == 1000)
    precondition(!large.fulfilledQuestIDs.contains("not-started"))
    for quest in days.quests {
      precondition(days.fulfilledQuestIDs.contains(quest.id) == days.questFulfilled(quest))
    }
    print(
      "Quest tree OK: nested scope, external ancestors, dependencies, cycles, missing references, 1000 nodes, mastery requirements, recurring habits, preserved dependency edits, detached selection, 7000-session index"
    )
  }
}
