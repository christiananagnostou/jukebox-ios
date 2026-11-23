import Foundation

enum HomeSection: String, CaseIterable, Identifiable, Sendable {
  case recent, favorites, playlists, discover, artists, genres
  var id: Self { self }
  var title: String {
    switch self {
    case .recent: "Recently played"
    case .favorites: "Favorites"
    case .playlists: "Your playlists"
    case .discover: "Discover"
    case .artists: "Artists"
    case .genres: "Genres"
    }
  }
}

struct HomeLayout: Equatable, Codable, Sendable {
  private(set) var order = HomeSection.allCases
  private(set) var hidden = Set<HomeSection>()
  var visible: [HomeSection] { order.filter { !hidden.contains($0) } }

  init() {}
  mutating func setVisible(_ visible: Bool, section: HomeSection) {
    if visible { hidden.remove(section) } else { hidden.insert(section) }
  }
  mutating func move(from offsets: IndexSet, to destination: Int) {
    guard let first = offsets.first, let last = offsets.last, first >= 0, last < order.count,
      (0...order.count).contains(destination)
    else { return }
    let moved = offsets.map { order[$0] }
    for index in offsets.reversed() { order.remove(at: index) }
    order.insert(contentsOf: moved, at: destination - offsets.count(in: 0..<destination))
  }

  private enum CodingKeys: String, CodingKey { case order, hidden }
  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let saved = try values.decodeIfPresent([String].self, forKey: .order) ?? []
    var seen = Set<HomeSection>()
    order = (saved.compactMap(HomeSection.init(rawValue:)) + HomeSection.allCases)
      .filter { seen.insert($0).inserted }
    hidden = Set(
      (try values.decodeIfPresent([String].self, forKey: .hidden) ?? [])
        .compactMap(HomeSection.init(rawValue:)))
  }
  func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(order.map(\.rawValue), forKey: .order)
    try values.encode(order.filter(hidden.contains).map(\.rawValue), forKey: .hidden)
  }
}

struct HomeGenre: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  var covers: [MusicItem] = []
}
