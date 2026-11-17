import CoreGraphics
import Foundation

@main struct SkillTreeLayoutTests {
  static func skill(_ id: String, _ parents: [String] = []) -> Skill {
    Skill(
      id: id, title: id, domain: "Mind", xp_milli: 0, mastery: 0, evidence: [],
      prerequisites: parents)
  }
  static func main() {
    precondition(SkillTreeLayout(skills: []).frames.isEmpty)
    let skills = [
      skill("A"), skill("B", ["A"]), skill("C", ["A"]), skill("D", ["B", "C"]), skill("E"),
    ]
    let graph = SkillTreeLayout(skills: skills)
    precondition(graph.columns.count == 3)
    precondition(Set(graph.columns[0]) == ["A", "E"])
    precondition(Set(graph.columns[1]) == ["B", "C"])
    precondition(graph.columns[2] == ["D"])
    precondition(graph.edges.count == 4)
    precondition(graph.ancestors(of: "D", skills: skills) == ["A", "B", "C", "D"])
    for edge in graph.edges {
      precondition(graph.frames[edge.source]!.maxX < graph.frames[edge.target]!.minX)
    }
    let frames = Array(graph.frames.values)
    for i in frames.indices {
      precondition(graph.size.width >= frames[i].maxX && graph.size.height >= frames[i].maxY)
      for j in frames.indices where j > i { precondition(!frames[i].intersects(frames[j])) }
    }
    let cache = SkillTreeLayoutCache()
    precondition(
      cache.layout(skills: skills, key: SkillTreeLayout.signature(skills)).columns.count == 3)
    var updated = skills
    updated[0].xp_milli = 20_000
    updated[0].mastery = 1
    precondition(SkillTreeLayout.signature(updated) == SkillTreeLayout.signature(skills))
    updated[3].prerequisites = ["A"]
    precondition(SkillTreeLayout.signature(updated) != SkillTreeLayout.signature(skills))
    precondition(SkillTreeLayout(skills: updated).columns.count == 2)
    precondition(
      cache.layout(skills: updated, key: SkillTreeLayout.signature(updated)).columns.count == 2)
    let orphan = SkillTreeLayout(skills: [skill("A", ["missing"])])
    precondition(orphan.unresolved == ["A"] && orphan.frames.count == 1)
    let cycle = [skill("A", ["B"]), skill("B", ["A"]), skill("C", ["B"])]
    let cyclic = SkillTreeLayout(skills: cycle)
    precondition(cyclic.frames.count == 3 && cyclic.unresolved.count == 3)
    precondition(cyclic.ancestors(of: "C", skills: cycle) == ["A", "B", "C"])
    precondition(SkillTreeLayout(skills: [skill("A"), skill("A")]).frames.count == 1)
    precondition(SkillTreeLayout(skills: [skill("A"), skill("B", ["A", "A"])]).edges.count == 1)
    let chain = (0..<1000).map { skill("n\($0)", $0 == 0 ? [] : ["n\($0 - 1)"]) }
    let large = SkillTreeLayout(skills: chain)
    precondition(large.frames.count == 1000 && large.edges.count == 999)
    precondition(large.ancestors(of: "n999", skills: chain).count == 1000)
    let forest = SkillTreeLayout(skills: (0..<1000).map { skill("r\($0)") })
    precondition(forest.frames.count == 1000 && forest.columns.count == 1)
    print(
      "Skill tree OK: roots, branches, merged prerequisites, ordering, non-overlap, updates, missing references, cycles, duplicate IDs, 1000-node chain and forest"
    )
  }
}
