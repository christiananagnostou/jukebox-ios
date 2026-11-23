import Foundation

struct CatalogRows: RandomAccessCollection, Equatable, Sendable {
  typealias Index = Int
  typealias Element = MusicItem
  private var offsets: [Int] = []
  private var blocks: [[MusicItem]] = []
  private var ends: [Int] = []
  var startIndex: Int { 0 }
  var endIndex: Int { ends.last ?? 0 }
  subscript(position: Int) -> MusicItem {
    precondition(position >= 0 && position < endIndex)
    var lower = 0
    var upper = ends.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if ends[middle] <= position { lower = middle + 1 } else { upper = middle }
    }
    return blocks[lower][position - (lower == 0 ? 0 : ends[lower - 1])]
  }
  mutating func insert(_ page: [MusicItem], at offset: Int) {
    guard !page.isEmpty else { return }
    let index =
      offsets.last.map { offset > $0 } ?? true
      ? offsets.endIndex : (offsets.firstIndex(where: { $0 > offset }) ?? offsets.endIndex)
    offsets.insert(offset, at: index)
    blocks.insert(page, at: index)
    if index == ends.count {
      ends.append((ends.last ?? 0) + page.count)
    } else {
      ends.insert((index == 0 ? 0 : ends[index - 1]) + page.count, at: index)
      for following in (index + 1)..<ends.count { ends[following] += page.count }
    }
  }
}

struct CatalogPresentationReceipt<Owner: Hashable> {
  let owner: Owner
  let presentation: UUID?
  func admits(owner: Owner, presentation: UUID?, isCurrent: () -> Bool) -> Bool {
    isCurrent() && self.owner == owner && self.presentation == presentation
  }
}
