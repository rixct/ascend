import Foundation

@main struct SessionGoalsTests {
  static func main() throws {
    let data = Data(
      """
      {"id":"q","title":"Study","outcome":"Finish exercises","skill_id":"skill",
       "kind":"Daily","priority":2,"estimate_minutes":25,"difficulty":1,
       "bonus_milli":0,"deadline":null,"dependencies":[],"status":"Active"}
      """.utf8)
    let legacy = try JSONDecoder().decode(Quest.self, from: data)
    precondition(legacy.sessionTarget == 1 && !legacy.closed)
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    object["planned_sessions"] = 5
    let current = try JSONDecoder().decode(
      Quest.self, from: JSONSerialization.data(withJSONObject: object))
    precondition(current.sessionTarget == 5)
    let sessions = (0..<8).map { index in
      Session(
        id: "s\(index)", quest_id: "q", skill_id: "skill",
        day: index < 5 ? "2026-11-15" : "2026-11-16", seconds: 1500,
        reward_milli: 10000, explanation: "Practice", result: "Exercises", completed_quest: false)
    }
    let totals = QuestPractice.totals(sessions)
    precondition(totals["q"]?.sessions == 8 && totals["q"]?.seconds == 12000)
    precondition(QuestPractice.totals([]).isEmpty)
    precondition(!current.closed, "Reaching the session plan must not complete a task")
    print(
      "Session models OK: legacy defaults, planned counts, 5 + 3 sessions across days, total time, no automatic completion"
    )
  }
}
