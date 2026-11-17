import CoreGraphics
import Foundation

/// A bounded, iterative DAG layout. It never follows dependencies recursively.
struct SkillTreeLayout {
  struct Edge: Identifiable {
    let source: String
    let target: String
    var id: String { source + ":" + target }
  }
  static let card = CGSize(width: 216, height: 116)
  static let columnSpacing: CGFloat = 304
  static let rowSpacing: CGFloat = 148
  var frames: [String: CGRect] = [:]
  var edges: [Edge] = []
  var columns: [[String]] = []
  var size = CGSize(width: 360, height: 300)
  var unresolved = Set<String>()

  static func signature(_ skills: [Skill]) -> String {
    skills.map { $0.id + ":" + $0.domain + ":" + $0.prerequisites.joined(separator: ",") }
      .joined(separator: "|")
  }

  struct Node {
    let id: String
    let domain: String
    let prerequisites: [String]
  }
  init(skills: [Skill]) {
    self.init(
      nodes: skills.map { Node(id: $0.id, domain: $0.domain, prerequisites: $0.prerequisites) })
  }
  init(quests: [Quest]) {
    self.init(
      nodes: quests.map { Node(id: $0.id, domain: $0.skill_id, prerequisites: $0.dependencies) })
  }
  static func signature(_ quests: [Quest]) -> String {
    quests.map { $0.id + ":" + $0.skill_id + ":" + $0.dependencies.joined(separator: ",") }.joined(
      separator: "|")
  }
  private init(nodes skills: [Node]) {
    let byID = Dictionary(skills.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var seen = Set<String>()
    let ids = skills.compactMap { seen.insert($0.id).inserted ? $0.id : nil }
    guard !ids.isEmpty else { return }
    let order = Dictionary(
      ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
    var children: [String: [String]] = [:]
    var remaining: [String: Int] = [:]
    var ranks: [String: Int] = [:]
    for id in ids {
      let parents = Set(byID[id]?.prerequisites ?? [])
      remaining[id] = parents.filter { byID[$0] != nil }.count
      ranks[id] = 0
      for parent in parents.sorted() {
        guard byID[parent] != nil else {
          unresolved.insert(id)
          continue
        }
        children[parent, default: []].append(id)
        edges.append(Edge(source: parent, target: id))
      }
    }
    var queue = ids.filter { remaining[$0] == 0 }
    var index = 0
    while index < queue.count {
      let id = queue[index]
      index += 1
      for child in children[id] ?? [] {
        ranks[child] = max(ranks[child, default: 0], ranks[id, default: 0] + 1)
        remaining[child, default: 0] -= 1
        if remaining[child] == 0 { queue.append(child) }
      }
    }
    let cyclic = ids.filter { remaining[$0, default: 0] > 0 }
    let lastRank = (queue.compactMap { ranks[$0] }.max() ?? -1) + 1
    for id in cyclic {
      unresolved.insert(id)
      ranks[id] = lastRank
    }
    columns = Array(repeating: [], count: (ranks.values.max() ?? 0) + 1)
    for id in ids { columns[ranks[id, default: 0]].append(id) }
    var rowIndex: [String: Double] = [:]
    let domainOrder = ["Mind", "Body", "Organization", "Social", "Recovery"]
    for column in columns.indices {
      columns[column].sort { a, b in
        func weight(_ id: String) -> Double {
          let parents = (byID[id]?.prerequisites ?? []).compactMap { rowIndex[$0] }
          if !parents.isEmpty { return parents.reduce(0, +) / Double(parents.count) }
          return Double(domainOrder.firstIndex(of: byID[id]?.domain ?? "") ?? 5) * 1000
            + Double(order[id, default: 0])
        }
        let lhs = weight(a)
        let rhs = weight(b)
        return lhs == rhs ? order[a, default: 0] < order[b, default: 0] : lhs < rhs
      }
      for (row, id) in columns[column].enumerated() { rowIndex[id] = Double(row) }
    }
    let rows = columns.map(\.count).max() ?? 1
    size = CGSize(
      width: 88 + CGFloat(columns.count - 1) * Self.columnSpacing + Self.card.width,
      height: 116 + CGFloat(rows - 1) * Self.rowSpacing + Self.card.height)
    for (column, ids) in columns.enumerated() {
      let inset = CGFloat(rows - ids.count) * Self.rowSpacing / 2
      for (row, id) in ids.enumerated() {
        let x: CGFloat = 44 + CGFloat(column) * Self.columnSpacing
        let y: CGFloat = 72 + inset + CGFloat(row) * Self.rowSpacing
        frames[id] = CGRect(origin: CGPoint(x: x, y: y), size: Self.card)
      }
    }
  }

  func ancestors(of id: String, skills: [Skill]) -> Set<String> {
    let parents = Dictionary(
      skills.map { ($0.id, $0.prerequisites) }, uniquingKeysWith: { a, _ in a })
    return ancestors(of: id, parents: parents)
  }
  func ancestors(of id: String, quests: [Quest]) -> Set<String> {
    ancestors(
      of: id,
      parents: Dictionary(quests.map { ($0.id, $0.dependencies) }, uniquingKeysWith: { a, _ in a }))
  }
  private func ancestors(of id: String, parents: [String: [String]]) -> Set<String> {
    var visited = Set<String>()
    var pending = [id]
    while let next = pending.popLast() {
      guard visited.insert(next).inserted else { continue }
      pending.append(contentsOf: (parents[next] ?? []).filter { !visited.contains($0) })
    }
    return visited
  }
}

/// Main-view cache: geometry changes with dependencies, never with timer ticks or XP.
final class SkillTreeLayoutCache {
  private var key: String?
  private var value = SkillTreeLayout(skills: [])
  func layout(quests: [Quest], key: String) -> SkillTreeLayout {
    if self.key != key {
      value = SkillTreeLayout(quests: quests)
      self.key = key
    }
    return value
  }
  func layout(skills: [Skill], key: String) -> SkillTreeLayout {
    if self.key != key {
      value = SkillTreeLayout(skills: skills)
      self.key = key
    }
    return value
  }
}
