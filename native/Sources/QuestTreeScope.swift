import Foundation

/// Keep a skill's quests together, including only the external ancestors they need.
struct QuestTreeScope {
  let members: [Quest]
  let quests: [Quest]
  let externalIDs: Set<String>
  init(skillID: String, quests all: [Quest]) {
    members = all.filter { $0.skill_id == skillID }
    let index = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let memberIDs = Set(members.map(\.id))
    var included = Set<String>()
    var pending = Array(memberIDs)
    while let id = pending.popLast() {
      guard let quest = index[id], included.insert(id).inserted else { continue }
      pending.append(contentsOf: quest.dependencies.filter { !included.contains($0) })
    }
    quests = all.filter { included.contains($0.id) }
    externalIDs = included.subtracting(memberIDs)
  }
  func selection(retaining selected: String?, fulfilled: Set<String>, unlocked: Set<String>) -> String? {
    if let selected, quests.contains(where: { $0.id == selected }) { return selected }
    return members.first { !fulfilled.contains($0.id) && unlocked.contains($0.id) }?.id
      ?? members.first?.id
  }

}
