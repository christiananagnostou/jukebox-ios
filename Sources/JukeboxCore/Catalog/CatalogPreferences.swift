import Foundation

enum CatalogLayout: String, Codable, CaseIterable, Sendable { case grid, list }

struct CatalogDevicePreferences: Equatable, Codable, Sendable {
  var layout = CatalogLayout.grid
  var selectionFeedback = true
}

struct CatalogSelectionFeedback {
  private var last: TimeInterval?
  mutating func admit(enabled: () -> Bool, at now: TimeInterval) -> Bool {
    guard enabled(), now.isFinite, now >= 0,
      last.map({ now - $0 >= 0.15 }) ?? true
    else { return false }
    last = now
    return true
  }
}

struct CatalogYearDraft: Equatable, Sendable {
  var from: String
  var to: String
  init(selection: CatalogYearRange, bounds: ClosedRange<Int>) {
    from = String(selection.lower ?? bounds.lowerBound)
    to = String(selection.upper ?? bounds.upperBound)
  }
  var accepted: CatalogYearRange? {
    func year(_ text: String) -> Int? {
      guard (1...4).contains(text.utf8.count),
        text.utf8.allSatisfy({ (48...57).contains($0) })
      else { return nil }
      return Int(text)
    }
    guard let lower = year(from), let upper = year(to) else { return nil }
    return CatalogYearRange(lower: lower, upper: upper)
  }
}

struct CatalogYearRange: Equatable, Codable, Sendable {
  let lower: Int?
  let upper: Int?
  static let all = CatalogYearRange(lower: nil, upper: nil)!
  init?(lower: Int?, upper: Int?) {
    guard
      (lower == nil && upper == nil)
        || (lower != nil && upper != nil && (1...9999).contains(lower!)
          && (1...9999).contains(upper!) && lower! <= upper!)
    else { return nil }
    self.lower = lower
    self.upper = upper
  }
  var isAll: Bool { lower == nil }
  func contains(_ year: Int?) -> Bool {
    if isAll { return true }
    guard let year, let lower, let upper else { return false }
    return (lower...upper).contains(year)
  }
  private enum CodingKeys: String, CodingKey { case lower, upper }
  init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    guard
      let value = Self(
        lower: try fields.decodeIfPresent(Int.self, forKey: .lower),
        upper: try fields.decodeIfPresent(Int.self, forKey: .upper))
    else { throw ClientError.invalidResponse }
    self = value
  }
}

struct CatalogBrowsePreferences: Equatable, Codable, Sendable {
  var favoritesOnly = false
  var years = CatalogYearRange.all
  var sorts: [MusicCategory: CatalogSort] = [:]
  var home: HomeLayout?
  func options(for category: MusicCategory) -> CatalogBrowseOptions {
    let requested = sorts[category] ?? .title
    return CatalogBrowseOptions(
      sort: CatalogSort.choices(for: category).contains(requested) ? requested : .title,
      favoritesOnly: favoritesOnly, years: category == .artists ? .all : years)
  }
  mutating func accept(_ options: CatalogBrowseOptions, for category: MusicCategory) {
    guard options.isValid(for: category) else { return }
    favoritesOnly = options.favoritesOnly
    if category != .artists { years = options.years }
    sorts[category] = options.sort
  }
}

struct CatalogYearFacet: Equatable, Sendable {
  let values: [Int]
  init(_ years: [Int]) throws {
    guard years.count <= 10000, years.allSatisfy({ (0...9999).contains($0) })
    else { throw ClientError.invalidResponse }
    values = Set(years.filter { $0 > 0 }).sorted()
  }
  var bounds: ClosedRange<Int>? {
    guard let first = values.first, let last = values.last else { return nil }
    return first...last
  }
  var decades: [ClosedRange<Int>] {
    Set(values.map { $0 / 10 }).sorted().map { max(1, $0 * 10)...min(9999, $0 * 10 + 9) }
  }
  func wireYears(for range: CatalogYearRange) throws -> String? {
    guard !range.isAll else { return nil }
    let result = values.filter { range.contains($0) }.map(String.init).joined(separator: ",")
    guard result.utf8.count <= 4096 else { throw ClientError.invalidResponse }
    return result
  }
}

struct RecentSearchIdentity: Codable, Hashable, Sendable {
  let library: String
  let category: MusicCategory
  let id: String
  static let limit = 20
  init?(library: String, category: MusicCategory, id: String) {
    guard Self.valid(library), Self.valid(id) else { return nil }
    self.library = library
    self.category = category
    self.id = id
  }
  private static func valid(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0)
          || (97...122).contains($0) || $0 == 45 || $0 == 95
      }
  }
  private enum CodingKeys: String, CodingKey { case library, category, id }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guard
      let value = Self(
        library: try c.decode(String.self, forKey: .library),
        category: try c.decode(MusicCategory.self, forKey: .category),
        id: try c.decode(String.self, forKey: .id))
    else { throw ClientError.invalidResponse }
    self = value
  }
}
