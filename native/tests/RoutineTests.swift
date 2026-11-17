import Foundation

@main struct RoutineTests {
  static func main() throws {
    let blank=RoutineDraft.blank
    precondition(blank.count==3 && Set(blank.map(\.id)).count==3 && !RoutineDraft.valid(blank))
    let rows=[RoutineDraftItem(title:" Plan the day "),RoutineDraftItem(title:""),RoutineDraftItem(title:"Read")]
    precondition(RoutineDraft.valid(rows) && RoutineDraft.titles(rows)==["Plan the day","Read"])
    precondition(!RoutineDraft.valid([RoutineDraftItem(title:"Read"),RoutineDraftItem(title:" read ")]))
    precondition(!RoutineDraft.valid([RoutineDraftItem(title:String(repeating:"a",count:101))]))
    let daily=try JSONDecoder().decode(DailyRoutine.self,from:Data(#"{"day":"2026-11-15","items":[{"id":"1","title":"Read","completed":true},{"id":"2","title":"Plan","completed":false}]}"#.utf8))
    precondition(daily.items.filter(\.completed).count==1)
    let legacy=Data(#"{"settings":{"name":"Test","dark":true,"growth_percent":10,"daily_minutes":90,"onboarded":true},"character_xp_milli":0,"skills":[],"quests":[],"sessions":[],"plans":[],"targets":[],"checkins":[],"journal":[],"events":[],"active":null}"#.utf8)
    let old=try JSONDecoder().decode(GameState.self,from:legacy)
    precondition(old.routine_versions==nil && old.routine_days==nil)
    print("Routine models OK: optional legacy fields, checklist completion, stable draft rows, trimmed/empty names, duplicate validation")
  }
}
