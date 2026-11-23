import SwiftUI
import UIKit

private class CatalogReusableCell: UICollectionViewCell {
  var receipt: CatalogActionBinding?
  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
  }
  required init?(coder: NSCoder) { fatalError("Catalog cells are registered by type") }
  override func prepareForReuse() {
    super.prepareForReuse()
    receipt?.retire()
    receipt = nil
  }
}

private final class LibraryItemCell: CatalogReusableCell {
  private let host = UIHostingController(rootView: AnyView(EmptyView()))

  override init(frame: CGRect) {
    super.init(frame: frame)
    host.safeAreaRegions = []
  }

  required init?(coder: NSCoder) { fatalError("Catalog cells are registered by type") }

  func setRow(_ row: some View) { host.rootView = AnyView(row) }

  func display(in parent: UIViewController) {
    guard host.parent == nil else { return }
    parent.addChild(host)
    let view: UIView = host.view
    view.backgroundColor = .clear
    view.frame = contentView.bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    contentView.addSubview(view)
    host.didMove(toParent: parent)
  }

  func endDisplaying() {
    guard host.parent != nil else { return }
    host.willMove(toParent: nil)
    host.view.removeFromSuperview()
    host.removeFromParent()
  }
}

struct CatalogCollection<Header: View, Row: View, Footer: View>:
  UIViewControllerRepresentable
{
  let browser: MusicBrowser
  let layout: CatalogLayout
  let insets: EdgeInsets?
  let showsHeader: Bool
  let showsFooter: Bool
  let header: Header
  let footer: Footer
  let row: (MusicItem, @escaping () -> Bool) -> Row
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.displayScale) private var displayScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @Environment(\.scenePhase) private var scene
  @Environment(\.layoutDirection) private var direction
  @Environment(\.musicTextActivity) private var textActivity
  @Environment(\.musicTextMotionAllowed) private var textMotion
  init(
    browser: MusicBrowser, layout: CatalogLayout, insets: EdgeInsets? = nil, showsHeader: Bool,
    showsFooter: Bool,
    @ViewBuilder header: () -> Header,
    @ViewBuilder footer: () -> Footer,
    @ViewBuilder row: @escaping (MusicItem, @escaping () -> Bool) -> Row
  ) {
    self.browser = browser
    self.layout = layout
    self.insets = insets
    self.showsHeader = showsHeader
    self.showsFooter = showsFooter
    self.header = header()
    self.footer = footer()
    self.row = row
  }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIViewController(context: Context) -> Coordinator {
    context.coordinator.loadViewIfNeeded()
    return context.coordinator
  }
  func updateUIViewController(_ controller: Coordinator, context: Context) {
    controller.update(self)
  }
  static func dismantleUIViewController(_ controller: Coordinator, coordinator: Coordinator) {
    controller.saveAnchor()
    controller.retire()
    controller.collectionView.delegate = nil
    controller.collectionView.dataSource = nil
  }
  @MainActor
  final class Coordinator: UICollectionViewController {
    var input: CatalogCollection
    private var collection: UICollectionView? { isViewLoaded ? collectionView : nil }
    private var rows = CatalogRows()
    private var owner: UUID?
    private var revision: UUID?
    private var category: MusicCategory?
    private var position = CatalogReflowAnchor()
    private var restoring = false
    private var live = true
    private var width: CGFloat?
    private var layoutDepth = 0
    private var widthMutation: CatalogReflowAnchor.Transaction?
    init(_ parent: CatalogCollection) {
      self.input = parent
      super.init(collectionViewLayout: UICollectionViewFlowLayout())
    }
    required init?(coder: NSCoder) { fatalError("Catalog collection requires its current browser") }
    override func viewDidLoad() {
      super.viewDidLoad()
      collectionView.setCollectionViewLayout(makeLayout(), animated: false)
      collectionView.backgroundColor = .clear
      setContentScrollView(collectionView, for: .top)
      setContentScrollView(collectionView, for: .bottom)
      collectionView.contentInsetAdjustmentBehavior = input.insets == nil ? .automatic : .never
      if input.insets != nil {
        collectionView.automaticallyAdjustsScrollIndicatorInsets = false
        collectionView.topEdgeEffect.style = .soft
        collectionView.bottomEdgeEffect.style = .soft
      }
      collectionView.keyboardDismissMode = .onDrag
      collectionView.alwaysBounceVertical = true
      collectionView.allowsSelection = false
      collectionView.accessibilityIdentifier = "music-collection"
      for identifier in ["catalog-header", "catalog", "catalog-footer"] {
        collectionView.register(CatalogReusableCell.self, forCellWithReuseIdentifier: identifier)
      }
      collectionView.register(LibraryItemCell.self, forCellWithReuseIdentifier: "library-item")
    }
    override func viewWillTransition(
      to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator
    ) {
      saveAnchor()
      prepareReflow()
      super.viewWillTransition(to: size, with: coordinator)
    }
    override func viewWillLayoutSubviews() {
      layoutDepth += 1
      if layoutDepth == 1, width != view.bounds.width, !restoring,
        let owner = positionOwner, let collection
      {
        if width != nil { prepareReflow() }
        if let transaction = position.beginOwnedMutation(
          owner: owner, viewport: Double(collection.contentOffset.y))
        {
          widthMutation = transaction
          restoring = true
        }
      }
      super.viewWillLayoutSubviews()
    }
    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      layoutDepth -= 1
      guard layoutDepth == 0 else { return }
      width = view.bounds.width
      if let mutation = widthMutation {
        widthMutation = nil
        restoring = false
        if let owner = positionOwner, let collection {
          position.rebase(
            mutation, owner: owner, viewport: Double(collection.contentOffset.y))
        }
      }
      finishReflow()
    }
    private var current: Bool {
      live && input.browser.metadataIsCurrent && input.browser.scope == owner
        && input.browser.category == category && input.browser.window.revision == revision
        && input.browser.resultsAreCurrent
    }
    func makeLayout() -> UICollectionViewLayout {
      let configuration = UICollectionViewCompositionalLayoutConfiguration()
      if input.insets != nil { configuration.contentInsetsReference = .none }
      let grid = input.layout == .grid
      let category = input.browser.category
      let size = input.typeSize
      let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
      func line(_ style: UIFont.TextStyle) -> CGFloat {
        ceil(UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).lineHeight)
      }
      let title = line(.subheadline)
      let support = line(.caption2)
      let rowHeight = max(category.listRowHeight, title + 4 + support + 4)
      let cardDetails: CGFloat =
        switch category {
        case .artists: 8 + title
        case .albums:
          9
            + max(
              title + 3 + line(.caption1),
              UIFontMetrics(forTextStyle: .subheadline).scaledValue(
                for: AlbumCardLabels.minimumHeight, compatibleWith: traits))
        case .songs: 8 + title + 4 + support + 6 + max(MusicUI.target, support)
        }
      return UICollectionViewCompositionalLayout(
        sectionProvider: { section, environment in
          let available = max(1, environment.container.effectiveContentSize.width - 32)
          let cards = section == 1 && grid
          let count =
            cards ? max(1, Int((available + 12) / (size.isAccessibilitySize ? 200 : 116))) : 1
          let height: NSCollectionLayoutDimension
          if cards {
            let width = (available - CGFloat(count - 1) * 12) / CGFloat(count)
            height = .absolute(ceil(width + cardDetails))
          } else if section == 1 {
            height = .absolute(rowHeight)
          } else {
            height = .estimated(80)
          }
          let item = NSCollectionLayoutItem(
            layoutSize: NSCollectionLayoutSize(
              widthDimension: .fractionalWidth(1 / CGFloat(count)),
              heightDimension: height))
          let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(
              widthDimension: .fractionalWidth(1),
              heightDimension: height), repeatingSubitem: item, count: count)
          group.interItemSpacing = .fixed(12)
          let result = NSCollectionLayoutSection(group: group)
          result.interGroupSpacing = cards ? 18 : 0
          result.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: 16, bottom: section == 2 ? 24 : 0, trailing: 16)
          return result
        }, configuration: configuration)
    }
    func update(_ value: CatalogCollection) {
      guard let collection else { return }
      let old = input
      let window = value.browser.window
      let changed =
        owner != value.browser.scope || revision != window.revision
        || category != value.browser.category
      let reflow = old.layout != value.layout || old.typeSize != value.typeSize
      let environmentChanged =
        reflow || old.colorScheme != value.colorScheme
        || old.reduceMotion != value.reduceMotion || old.voiceOver != value.voiceOver
        || old.scene != value.scene || old.direction != value.direction
        || old.displayScale != value.displayScale || old.textActivity != value.textActivity
        || old.textMotion != value.textMotion
      if changed { position.reset() }
      let anchor = reflow && !changed ? captureAnchor() : nil
      let oldCount = rows.count
      let nextRows = window.items
      func adoptSnapshot() {
        input = value
        owner = value.browser.scope
        revision = window.revision
        category = value.browser.category
        rows = nextRows
      }
      if changed || nextRows.count < oldCount {
        UIView.performWithoutAnimation {
          adoptSnapshot()
          collection.reloadData()
          collection.setCollectionViewLayout(makeLayout(), animated: false)
          if let insets = value.insets { applyInsets(insets, to: collection) }
          collection.layoutIfNeeded()
        }
        requestRestore(.init(id: window.anchor, fraction: window.anchorFraction), attachment: true)
        return
      }
      var added = (oldCount..<nextRows.count).map { IndexPath(item: $0, section: 1) }
      var removed: [IndexPath] = []
      for (section, before, after) in [
        (0, old.showsHeader, value.showsHeader), (2, old.showsFooter, value.showsFooter),
      ] where before != after {
        let path = IndexPath(item: 0, section: section)
        if after { added.append(path) } else { removed.append(path) }
      }
      if !added.isEmpty || !removed.isEmpty {
        UIView.performWithoutAnimation {
          collection.performBatchUpdates {
            adoptSnapshot()
            collection.deleteItems(at: removed)
            collection.insertItems(at: added)
          }
        }
      } else {
        adoptSnapshot()
      }
      if let insets = value.insets { applyInsets(insets, to: collection) }
      if reflow {
        UIView.performWithoutAnimation {
          performTransition {
            collection.setCollectionViewLayout(makeLayout(), animated: false)
            configureVisible(in: collection, includingRows: true)
            collection.layoutIfNeeded()
          }
          requestRestore(anchor)
        }
      } else {
        configureVisible(in: collection, includingRows: environmentChanged)
      }
    }
    private func applyInsets(_ insets: EdgeInsets, to collection: UICollectionView) {
      let next = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
      let previous = collection.contentInset
      guard next != previous else { return }
      let anchoredY = collection.contentOffset.y + previous.top - next.top
      collection.contentInset = next
      collection.verticalScrollIndicatorInsets = next
      if previous.top != next.top {
        collection.setContentOffset(
          CGPoint(x: collection.contentOffset.x, y: anchoredY), animated: false)
      }
    }
    private func configureVisible(in collection: UICollectionView, includingRows: Bool) {
      let paths =
        includingRows
        ? collection.indexPathsForVisibleItems
        : [
          IndexPath(item: 0, section: 0), IndexPath(item: 0, section: 2),
        ]
      for index in paths where index.item < collection.numberOfItems(inSection: index.section) {
        if let cell = collection.cellForItem(at: index) { configure(cell, at: index) }
      }
    }
    override func numberOfSections(in collectionView: UICollectionView) -> Int { 3 }
    override func collectionView(
      _ collectionView: UICollectionView, numberOfItemsInSection section: Int
    )
      -> Int
    {
      switch section {
      case 0: input.showsHeader ? 1 : 0
      case 1: rows.count
      default: input.showsFooter ? 1 : 0
      }
    }
    override func collectionView(
      _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    )
      -> UICollectionViewCell
    {
      let identifier =
        switch indexPath.section {
        case 0: "catalog-header"
        case 1: input.insets == nil ? "catalog" : "library-item"
        default: "catalog-footer"
        }
      let cell = collectionView.dequeueReusableCell(withReuseIdentifier: identifier, for: indexPath)
      configure(cell, at: indexPath)
      return cell
    }
    private func configure(_ cell: UICollectionViewCell, at index: IndexPath) {
      cell.backgroundConfiguration = .clear()
      (cell as? CatalogReusableCell)?.receipt?.retire()
      (cell as? CatalogReusableCell)?.receipt = nil
      if index.section == 0 {
        cell.contentConfiguration = UIHostingConfiguration { host(input.header) }.margins(.all, 0)
      } else if index.section == 2 {
        cell.contentConfiguration = UIHostingConfiguration { host(input.footer) }.margins(.all, 0)
      } else if current, rows.indices.contains(index.item), let owner, let revision, let category {
        let item = rows[index.item]
        let binding = CatalogActionBinding(
          scope: owner, revision: revision, category: category, id: item.id,
          isRenderedCurrent: { [weak self, weak cell] in self?.live == true && cell != nil })
        (cell as? CatalogReusableCell)?.receipt = binding
        let browser = input.browser
        let content = host(input.row(item, { binding.isCurrent(in: browser) }).id(item.id))
        if let cell = cell as? LibraryItemCell {
          cell.setRow(content)
        } else {
          cell.contentConfiguration = UIHostingConfiguration { content }.margins(.all, 0)
        }
      } else {
        cell.contentConfiguration = nil
        (cell as? LibraryItemCell)?.setRow(EmptyView())
      }
    }
    private func host<Content: View>(_ content: Content) -> some View {
      content.buttonStyle(MusicButtonStyle())
        .environment(\.colorScheme, input.colorScheme)
        .environment(\.dynamicTypeSize, input.typeSize)
        .environment(\.displayScale, input.displayScale)
        .environment(\.scenePhase, input.scene)
        .environment(\.layoutDirection, input.direction)
        .environment(\.musicTextActivity, input.textActivity)
        .environment(\.musicTextMotionAllowed, input.textMotion)
    }
    override func collectionView(
      _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
      forItemAt indexPath: IndexPath
    ) {
      (cell as? LibraryItemCell)?.display(in: self)
      if collectionView.isDragging || collectionView.isDecelerating {
        loadNextPageIfNeeded(at: indexPath, cell: cell)
      }
    }
    override func collectionView(
      _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
      forItemAt indexPath: IndexPath
    ) {
      (cell as? LibraryItemCell)?.endDisplaying()
    }
    private func loadNextPageIfNeeded(at index: IndexPath, cell: UICollectionViewCell?) {
      guard index.section == 1, index.item >= rows.count - 8,
        let receipt = (cell as? CatalogReusableCell)?.receipt, receipt.isCurrent(in: input.browser)
      else { return }
      input.browser.continueListing(
        .later, scope: receipt.scope, category: receipt.category,
        query: input.browser.window.query, revision: receipt.revision)
    }
    override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      position.reset()
      if let last = collectionView.indexPathsForVisibleItems.filter({ $0.section == 1 }).max() {
        loadNextPageIfNeeded(at: last, cell: collectionView.cellForItem(at: last))
      }
    }
    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
      guard !restoring else { return }
      position.viewportChanged(to: Double(scrollView.contentOffset.y))
    }
    override func scrollViewDidEndDragging(
      _ scrollView: UIScrollView, willDecelerate decelerate: Bool
    ) {
      if !decelerate { saveAnchor() }
    }
    override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { saveAnchor() }
    private var positionOwner: CatalogReflowAnchor.Owner? {
      guard current, let owner, let revision else { return nil }
      return .init(scope: owner, revision: revision)
    }
    func prepareReflow() {
      guard !restoring else { return }
      guard let stamp = positionOwner, let collection else {
        position.reset()
        return
      }
      position.prepare(
        measured: measureAnchor(), viewport: Double(collection.contentOffset.y), owner: stamp)
    }
    private func performTransition(_ change: () -> Void) {
      guard !restoring, let stamp = positionOwner, let collection else {
        change()
        return
      }
      let viewport = Double(collection.contentOffset.y)
      let anchor = position.resolve(measured: measureAnchor(), viewport: viewport)
      let frame = anchorFrame(anchor)
      guard let transaction = position.beginOwnedMutation(owner: stamp, viewport: viewport)
      else {
        change()
        return
      }
      let previous = restoring
      restoring = true
      defer { restoring = previous }
      change()
      guard let current = positionOwner, current == stamp else { return }
      let actual = Double(collection.contentOffset.y)
      position.rebase(
        transaction, owner: current, viewport: actual,
        refined: actual != viewport || anchorFrame(anchor) != frame)
    }
    private func anchorFrame(_ anchor: CatalogReflowAnchor.Value?) -> CGRect? {
      guard current, let collection, let anchor else { return nil }
      if let id = anchor.id {
        guard let index = input.browser.window.index(of: id) else { return nil }
        return collection.layoutAttributesForItem(at: IndexPath(item: index, section: 1))?.frame
      }
      return input.showsHeader
        ? collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame : nil
    }
    private func requestRestore(_ anchor: CatalogReflowAnchor.Value?, attachment: Bool = false) {
      guard let stamp = positionOwner, let collection, let anchor else { return }
      let viewport = Double(collection.contentOffset.y)
      if attachment {
        position.attach(anchor, viewport: viewport, owner: stamp)
      } else {
        position.prepare(measured: anchor, viewport: viewport, owner: stamp)
      }
      finishReflow()
    }
    func finishReflow() {
      guard let owner, let revision, let collection else { return }
      if let anchor = position.finish(
        owner: .init(scope: owner, revision: revision),
        viewport: Double(collection.contentOffset.y),
        mutationInProgress: restoring,
        geometryIsUsable: collection.bounds.width > 0 && collection.bounds.height > 0
          && collection.contentSize.height > 0)
      {
        restore(anchor)
      }
    }
    private func captureAnchor() -> CatalogReflowAnchor.Value? {
      guard current, let collection else { return nil }
      return position.resolve(
        measured: measureAnchor(), viewport: Double(collection.contentOffset.y))
    }
    private func measureAnchor() -> CatalogReflowAnchor.Value? {
      guard current, let collection else { return nil }
      let top = collection.contentOffset.y + collection.adjustedContentInset.top
      if input.showsHeader,
        let frame = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
        frame.maxY > top, frame.height > 0
      {
        return .init(id: nil, fraction: Double(max(0, min(1, (top - frame.minY) / frame.height))))
      }
      let visible = collection.indexPathsForVisibleItems.filter { $0.section == 1 }.sorted()
      guard
        let index = visible.first(where: {
          (collection.layoutAttributesForItem(at: $0)?.frame.maxY ?? 0) > top
        }), rows.indices.contains(index.item),
        let frame = collection.layoutAttributesForItem(at: index)?.frame,
        frame.height > 0
      else { return nil }
      return .init(
        id: rows[index.item].id, fraction: Double(max(0, min(1, (top - frame.minY) / frame.height)))
      )
    }
    func retire() {
      live = false
      position.reset()
      for cell in collection?.visibleCells ?? [] {
        (cell as? CatalogReusableCell)?.receipt?.retire()
      }
    }
    func saveAnchor() {
      guard !restoring, let anchor = captureAnchor() else { return }
      input.browser.setAnchor(anchor.id, fraction: anchor.fraction, revision: revision)
    }
    private func restore(_ anchor: CatalogReflowAnchor.Value) {
      guard let stamp = positionOwner else {
        position.reset()
        return
      }
      guard let collection,
        let ticket = position.restoration(
          owner: stamp, viewport: Double(collection.contentOffset.y))
      else { return }
      let index: IndexPath
      if let id = anchor.id {
        guard let row = input.browser.window.index(of: id) else { return }
        index = IndexPath(item: row, section: 1)
      } else {
        index = IndexPath(item: 0, section: 0)
      }
      let previous = restoring
      restoring = true
      defer { restoring = previous }
      if anchor.id == nil && !input.showsHeader {
        collection.setContentOffset(
          CGPoint(x: 0, y: -collection.adjustedContentInset.top), animated: false)
        position.didRestore(ticket, viewport: Double(collection.contentOffset.y), owner: stamp)
        return
      }
      if collection.layoutAttributesForItem(at: index) == nil {
        collection.scrollToItem(at: index, at: .top, animated: false)
        collection.layoutIfNeeded()
      }
      guard let fresh = positionOwner, position.permits(ticket, owner: fresh),
        let frame = collection.layoutAttributesForItem(at: index)?.frame
      else { return }
      let desired =
        frame.minY + frame.height * anchor.fraction - collection.adjustedContentInset.top
      let bounded = CatalogViewportOffset.clamp(
        Double(desired), content: Double(collection.contentSize.height),
        viewport: Double(collection.bounds.height),
        topInset: Double(collection.adjustedContentInset.top),
        bottomInset: Double(collection.adjustedContentInset.bottom))
      collection.setContentOffset(CGPoint(x: 0, y: bounded), animated: false)
      guard let fresh = positionOwner else { return }
      position.didRestore(ticket, viewport: Double(collection.contentOffset.y), owner: fresh)
    }
  }
}
