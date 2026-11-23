#if DEBUG
  import AVFoundation
  import CryptoKit
  import Foundation
  import MediaPlayer
  import UIKit

  nonisolated private final class BackgroundArtworkRequest: @unchecked Sendable {
    let artwork: MPMediaItemArtwork
    init(_ artwork: MPMediaItemArtwork) { self.artwork = artwork }
    func render(_ size: CGSize) -> CGSize? {
      dispatchPrecondition(condition: .notOnQueue(.main))
      return artwork.image(at: size)?.size
    }
  }

  extension DevelopmentAcceptance {
    private actor ColdMediaCatalog: MusicCatalogServing {
      let base: FixtureCatalog
      private var held = false
      private var detailsHeld = false
      private(set) var detailCalls = 0
      private var detailWaiters: [CheckedContinuation<Void, Never>] = []
      func holdDetails() { detailsHeld = true }
      func releaseDetails() {
        detailsHeld = false
        let waiting = detailWaiters
        detailWaiters = []
        for waiter in waiting { waiter.resume() }
      }
      private var sequence = 0
      private var pending: [Int: (MediaSource, CheckedContinuation<MediaSource, Error>)] = [:]
      init(_ base: FixtureCatalog) { self.base = base }
      func hold() { held = true }
      var pendingRequests: [Int] { pending.keys.sorted() }
      func release(_ id: Int, error: ClientError? = nil) {
        guard let (source, continuation) = pending.removeValue(forKey: id) else { return }
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: source)
        }
      }
      func releaseAll() {
        releaseDetails()
        held = false
        for id in pendingRequests { release(id) }
      }
      func verifyIdentity() async throws { try await base.verifyIdentity() }
      func validate(ids: [String]) async throws -> [MusicItem] { try await base.validate(ids: ids) }
      func artwork(item: MusicItem) async throws -> Data? { try await base.artwork(item: item) }
      func musicLibraries(refresh: Bool) async throws -> [MusicLibrary] {
        try await base.musicLibraries(refresh: refresh)
      }
      func catalog(_ query: CatalogQuery) async throws -> [MusicItem] {
        try await base.catalog(query)
      }
      func albumTracks(library: String, album: String) async throws -> [MusicItem] {
        try await base.albumTracks(library: library, album: album)
      }
      func albumDetail(library: String, album: MusicItem) async throws -> MusicAlbumPage {
        detailCalls += 1
        if detailsHeld { await withCheckedContinuation { detailWaiters.append($0) } }
        return try await base.albumDetail(library: library, album: album)
      }
      func artistDetail(library: String, artist: MusicItem) async throws -> MusicItem {
        try await base.artistDetail(library: library, artist: artist)
      }
      func media(
        library: String, trackID: String, quality: StreamQuality,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
      ) async throws -> MediaSource {
        let source = try await base.media(
          library: library, trackID: trackID, quality: quality, isCurrent: isCurrent)
        guard held else { return source }
        guard pending.count < 8 else { throw ClientError.unavailable }
        sequence += 1
        let id = sequence
        return try await withCheckedThrowingContinuation { pending[id] = (source, $0) }
      }
    }
    private actor StartInsertionGate {
      private(set) var entered = false
      private var released = false
      private var continuation: CheckedContinuation<Void, Never>?
      func hold() async {
        entered = true
        await withTaskCancellationHandler {
          await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { self.continuation = continuation }
          }
        } onCancel: {
          Task { await self.release() }
        }
      }
      func release() {
        released = true
        continuation?.resume()
        continuation = nil
      }
    }
    private static func coldReplacementChecks(
      store: PlayerStore, native: NativePlayer
    )
      async throws -> [String: Any]
    {
      let source = Bundle.main.resourceURL!.appendingPathComponent("Fixtures/tone.wav")
      let service = ColdMediaCatalog(FixtureCatalog(source: source))
      let commit = StartInsertionGate()
      func wait(_ stage: String, _ check: () async -> Bool) async throws {
        for _ in 0..<100 {
          if await check() { return }
          try await Task.sleep(for: .milliseconds(50))
        }
        throw CheckFailure(step: stage)
      }
      func checkProjection(_ position: Double) throws {
        let center = MPRemoteCommandCenter.shared()
        guard center.playCommand.isEnabled, center.pauseCommand.isEnabled,
          center.nextTrackCommand.isEnabled, center.previousTrackCommand.isEnabled,
          center.changePlaybackPositionCommand.isEnabled
        else { throw CheckFailure(step: "cold-replacement-disabled-remote-transport") }
        guard let current = store.current,
          MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
            == current.track.title,
          MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyAlbumTitle] as? String
            == current.track.album,
          native.lastNowPlayingProjection?.rate == 0,
          abs((native.lastNowPlayingProjection?.clock ?? -1) - position) < 0.001,
          native.queueReadout.preparing, native.queueReadout.queued.isEmpty
        else { throw CheckFailure(step: "cold-pending-projection-not-exact-target") }
      }
      do {
        await store.enterFixture(service: service)
        await store.browser?.start()
        try await wait("cold-library-not-accepted") {
          store.browser?.libraryID != nil && store.browser?.loadingLibraries == false
        }
        let initialSelection = try await albumSelection(
          store: store, album: CatalogFixtures.album(0))
        guard !initialSelection.items.isEmpty else {
          throw CheckFailure(step: "cold-album-not-accepted")
        }
        store.playSelection(initialSelection)
        try await wait("cold-initial-start") { store.playing }
        try await wait("card-successor-not-prepared") {
          store.queue.entries.dropFirst(store.queue.index + 1).first.map {
            native.hasPrepared($0.id)
          } == true
        }
        let acceptedOccurrence = store.current?.id
        let oldDelivery = native.remoteDeliveryForCheck()
        let cardOrigin = store.playbackOrigin(library: "fixture-music")
        let cardTarget = CatalogFixtures.album(1)
        let detailCalls = await service.detailCalls
        await service.holdDetails()
        store.playAlbum(cardTarget, origin: cardOrigin)
        oldDelivery(.pause)
        guard store.playbackRequested, store.current?.id == acceptedOccurrence,
          store.isPreparingAlbum(cardTarget.id, origin: cardOrigin)
        else { throw CheckFailure(step: "old-remote-delivery-cancelled-new-card-intent") }
        try await wait("card-detail-not-held") { await service.detailCalls == detailCalls + 1 }
        let liveDelivery = native.remoteDeliveryForCheck()
        native.seek(17.6)
        try await wait("card-natural-advance") {
          store.current?.id != acceptedOccurrence && store.playing
        }
        guard store.isPreparingAlbum(cardTarget.id, origin: cardOrigin) else {
          throw CheckFailure(step: "natural-advance-cancelled-card-intent")
        }
        liveDelivery(.pause)
        guard !store.playbackRequested, !store.isPreparingAlbum(cardTarget.id, origin: cardOrigin)
        else { throw CheckFailure(step: "current-remote-pause-did-not-cancel-card-intent") }
        await service.releaseDetails()
        try await Task.sleep(for: .milliseconds(50))
        guard !store.playbackRequested, store.current?.track.albumID != cardTarget.id else {
          throw CheckFailure(step: "late-card-detail-resurrected-after-current-pause")
        }
        let coldSelection = try await albumSelection(store: store, album: CatalogFixtures.album(1))
        await service.hold()
        store.playSelection(coldSelection)
        try checkProjection(0)
        store.pause()
        await service.releaseAll()
        let album = CatalogFixtures.album(2)
        let decodeAlbum = MusicItem(
          id: album.id, title: album.title, artist: album.artist, album: album.album,
          duration: album.duration, number: album.number, kind: album.kind,
          imageID: "cold-decode-" + UUID().uuidString, imageTag: album.imageTag)
        guard
          let decodeSelection = store.playbackSelection(
            [CatalogFixtures.tracks(decodeAlbum)[0]], library: "fixture-music")
        else { throw CheckFailure(step: "cold-decode-origin") }
        guard store.cover(decodeAlbum) == nil else {
          throw CheckFailure(step: "cold-decode-cache-not-cold")
        }
        native.beforeStartInsertionForCheck = { await commit.hold() }
        store.playSelection(decodeSelection)
        try await wait("cold-decode-insertion-not-held") { await commit.entered }
        guard let decodeOccurrence = store.current?.id, native.queueReadout.queued.isEmpty else {
          throw CheckFailure(step: "cold-decode-already-inserted")
        }
        await store.loadCover(decodeAlbum)
        guard let decodedData = store.cover(decodeAlbum) else {
          throw CheckFailure(step: "cold-decode-cache-not-accepted")
        }
        native.updateArtwork(decodedData, occurrence: decodeOccurrence)
        try await wait("cold-decode-during-preparation") {
          MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil
        }
        let acceptedArt =
          MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork]
          as? MPMediaItemArtwork
        let clearings = native.artworkClearingPublications
        await commit.release()
        try await wait("cold-decode-bound-start") { store.playing }
        guard acceptedArt != nil,
          MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork]
            as? MPMediaItemArtwork === acceptedArt,
          native.artworkClearingPublications == clearings
        else { throw CheckFailure(step: "cold-start-commit-overwrote-accepted-art") }
        store.pause()
        for quality in StreamQuality.allCases {
          store.quality(quality)
          guard
            let selection = store.playbackSelection(
              [CatalogFixtures.tracks(CatalogFixtures.album(1))[0]], library: "fixture-music")
          else { throw CheckFailure(step: "cold-selection-origin") }
          await service.hold()
          store.playSelection(selection)
          try await wait("cold-source-not-held") { await service.pendingRequests.count == 1 }
          let pendingDelivery = native.remoteDeliveryForCheck()
          store.seek(6)
          try await wait("cold-seek-six-not-held") { await service.pendingRequests.count == 2 }
          store.seek(2)
          try await wait("cold-seek-two-not-held") { await service.pendingRequests.count == 3 }
          try checkProjection(2)
          guard store.queue.position == 0 else {
            throw CheckFailure(step: "cold-pending-seek-accepted-clock")
          }
          let requests = await service.pendingRequests
          await service.release(requests[2])
          try await wait("cold-latest-source-start") {
            store.playing && store.queue.position >= 1.95
          }
          await service.release(requests[0], error: .forbidden)
          await service.release(requests[1])
          pendingDelivery(.pause)
          guard !store.playbackRequested, store.phase == .paused else {
            throw CheckFailure(step: "cold-pending-to-bound-lost-pause")
          }
          await service.releaseAll()
          await service.hold()
          store.playSelection(selection)
          try await wait("cold-zero-initial-not-held") { await service.pendingRequests.count == 1 }
          store.seek(6)
          try await wait("cold-zero-six-not-held") { await service.pendingRequests.count == 2 }
          store.seek(0)
          try await wait("cold-zero-not-held") { await service.pendingRequests.count == 3 }
          try checkProjection(0)
          let zero = await service.pendingRequests
          await service.release(zero[2])
          try await wait("cold-explicit-zero-start") { store.playing && store.queue.position < 1 }
          store.pause()
          await service.releaseAll()
        }
        let a = store.playbackSelection(
          [CatalogFixtures.tracks(CatalogFixtures.album(0))[0]], library: "fixture-music")!
        let b = store.playbackSelection(
          [CatalogFixtures.tracks(CatalogFixtures.album(1))[0]], library: "fixture-music")!
        await service.hold()
        store.playSelection(a)
        try await wait("cold-rapid-a") { await service.pendingRequests.count == 1 }
        let oldPause = native.remoteDeliveryForCheck()
        store.playSelection(b)
        try await wait("cold-rapid-b") { await service.pendingRequests.count == 2 }
        oldPause(.pause)
        guard store.playbackRequested else {
          throw CheckFailure(step: "cold-stale-pause-acted-on-b")
        }
        store.playSelection(a)
        try await wait("cold-rapid-final-a") { await service.pendingRequests.count == 3 }
        let rapid = await service.pendingRequests
        await service.release(rapid[1], error: .forbidden)
        await service.release(rapid[0])
        try checkProjection(0)
        let retired = native.remoteDeliveryForCheck()
        native.receiveRemoteForCheck(.pause)
        await service.releaseAll()
        retired(.play)
        guard !store.playbackRequested, native.queueReadout.queued.isEmpty,
          MPNowPlayingInfoCenter.default().nowPlayingInfo == nil
        else { throw CheckFailure(step: "cold-pause-resurrected") }
        return [
          "album_card_detail_intent_fences_remote_receipts": true,
          "cold_album_replacement_keeps_controls_and_exact_pending_identity": true,
          "cold_decode_during_native_preparation_survives_commit_without_blank": true,
          "cold_all_quality_latest_seek_and_zero_keep_accepted_clock": true,
          "cold_pending_to_bound_receipt_preserves_pause": true,
          "cold_rapid_stale_replies_and_pause_cannot_resurrect": true,
        ]
      } catch {
        native.beforeStartInsertionForCheck = nil
        store.pause()
        await commit.release()
        await service.releaseAll()
        throw error
      }
    }
    static func runArtworkCheck(
      store: PlayerStore, native: NativePlayer, runID: UUID,
      publish: (([String: Any]) -> Void)? = nil
    ) async {
      var report: [String: Any] = ["run_id": runID.uuidString]
      native.beginMeasurement(runID)
      defer {
        native.endMeasurement(runID)
        CoverArt.endMeasurement(runID)
        store.showPlayer = false
      }
      func currentArt() -> MPMediaItemArtwork? {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork]
          as? MPMediaItemArtwork
      }
      func wait(_ stage: String, _ check: () -> Bool) async throws {
        for _ in 0..<100 {
          if check() { return }
          try await Task.sleep(for: .milliseconds(50))
        }
        throw CheckFailure(step: stage + "-timeout")
      }
      func checkRemoteTransport() throws {
        let center = MPRemoteCommandCenter.shared()
        guard center.playCommand.isEnabled, center.pauseCommand.isEnabled,
          center.nextTrackCommand.isEnabled, center.previousTrackCommand.isEnabled,
          center.changePlaybackPositionCommand.isEnabled
        else { throw CheckFailure(step: "prepared-next-disabled-remote-transport") }
      }
      var checkedPreparingPause = false
      func checkPreparingPause() async throws {
        guard !checkedPreparingPause, native.queueReadout.preparing else { return }
        let occurrence = store.current?.id
        let accepted = store.queue.position
        native.receiveRemoteForCheck(.pause)
        guard !store.playbackRequested, store.phase == .paused,
          MPNowPlayingInfoCenter.default().nowPlayingInfo == nil,
          !MPRemoteCommandCenter.shared().pauseCommand.isEnabled
        else { throw CheckFailure(step: "remote-pause-did-not-retire-preparing") }
        native.receiveRemoteForCheck(.play)
        native.receiveRemoteForCheck(.next)
        native.receiveRemoteForCheck(.seek(3))
        try await Task.sleep(for: .milliseconds(300))
        guard !store.playbackRequested, store.phase == .paused,
          store.current?.id == occurrence, store.queue.position == accepted,
          MPNowPlayingInfoCenter.default().nowPlayingInfo == nil
        else { throw CheckFailure(step: "retired-remote-command-resurrected-playback") }
        checkedPreparingPause = true
        store.play()
        try await wait("remote-pause-explicit-resume") { store.playing }
      }
      func checkPreparingSeek() throws {
        let accepted = store.queue.position
        native.seek(1)
        guard native.lastNowPlayingProjection?.clock == 1,
          native.lastNowPlayingProjection?.rate == 0, store.queue.position == accepted
        else { throw CheckFailure(step: "preparing-seek-accepted-unconfirmed-clock") }
        native.seek(0)
        guard native.lastNowPlayingProjection?.clock == 0,
          native.lastNowPlayingProjection?.rate == 0, store.queue.position == accepted
        else { throw CheckFailure(step: "preparing-latest-seek-did-not-project") }
        report["preparing_seek_projects_without_accepted_clock"] = true
      }
      do {
        let selection = try await fixtureAlbumSelection(store: store)
        store.playSelection(selection)
        try await wait("artwork-start") { store.playing && store.queue.position > 0.5 }
        guard let occurrence = store.current?.id else {
          throw CheckFailure(step: "missing-occurrence")
        }
        store.pause()
        let pausedStart = ProcessInfo.processInfo.systemUptime
        let pausedCounts = native.measurement(runID)!
        let pausedMetadata = native.nowPlayingPublications
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800), format: format)
          .image { ctx in
            UIColor.systemIndigo.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
          }
        guard let data = image.pngData() else { throw CheckFailure(step: "generated-image-failed") }
        native.updateArtwork(data, occurrence: occurrence)
        try await wait("artwork-current-decode") { currentArt() != nil }
        guard let art = currentArt(), art.bounds.width == 600, art.bounds.height == 400,
          let resized = art.image(at: CGSize(width: 120, height: 80)),
          resized.size == CGSize(width: 120, height: 80)
        else { throw CheckFailure(step: "unbounded-artwork") }
        report["published_downsampled_600x400_and_resized_120x80"] = true
        let snapshot = BackgroundArtworkRequest(art)
        let backgroundSize: CGSize? = await withCheckedContinuation { continuation in
          DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: snapshot.render(CGSize(width: 96, height: 64)))
          }
        }
        guard backgroundSize == CGSize(width: 96, height: 64) else {
          throw CheckFailure(step: "background-artwork-request-failed")
        }
        report["background_queue_image_request_96x64"] = true
        native.updateArtwork(data, occurrence: occurrence)
        report["identical_art_present_immediately"] = currentArt() != nil
        guard currentArt() === art else {
          throw CheckFailure(step: "accepted-art-blanked-before-identical-decode")
        }
        report["identical_accepted_art_does_not_blank"] = true
        native.updateArtwork(nil, occurrence: occurrence)
        guard currentArt() == nil else { throw CheckFailure(step: "missing-art-did-not-clear") }
        native.updateArtwork(data, occurrence: occurrence)
        native.updateArtwork(Data([0, 1, 2]), occurrence: occurrence)
        try await Task.sleep(for: .milliseconds(300))
        guard currentArt() == nil else {
          throw CheckFailure(step: "invalid-or-stale-art-published")
        }
        report["missing_invalid_and_superseded_art_clear"] = true
        native.updateArtwork(data, occurrence: occurrence)
        let retiredRemoteDelivery = native.remoteDeliveryForCheck()
        let pausedEnd = native.measurement(runID)!
        report["paused_clock_callbacks"] = pausedEnd.callbacks - pausedCounts.callbacks
        report["paused_position_publications"] = pausedEnd.positions - pausedCounts.positions
        report["paused_timeline_publications"] = pausedEnd.timelines - pausedCounts.timelines
        report["paused_nowplaying_publications"] = native.nowPlayingPublications - pausedMetadata
        report["paused_window_seconds"] = ProcessInfo.processInfo.systemUptime - pausedStart
        native.stop()
        try await Task.sleep(for: .milliseconds(300))
        guard MPNowPlayingInfoCenter.default().nowPlayingInfo == nil else {
          throw CheckFailure(step: "stopped-art-republished")
        }
        report["stopped_decode_cannot_republish"] = true
        await store.browser?.start()
        guard let library = store.browser?.libraryID else {
          throw CheckFailure(step: "invented-music-library-missing")
        }
        let firstAlbum = CatalogFixtures.album(0)
        let nextAlbum = CatalogFixtures.album(1)
        _ = try await albumSelection(store: store, album: firstAlbum)
        await store.loadCover(nextAlbum)
        let firstTracks = CatalogFixtures.tracks(firstAlbum)
        let nextTracks = CatalogFixtures.tracks(nextAlbum)
        store.playItems(
          [firstTracks[0], firstTracks[1], nextTracks[0], nextTracks[1]], library: library)
        let sameCover = store.queue.entries[1].id
        let differentCover = store.queue.entries[2].id
        let selectedPrepared = store.queue.entries[3].id
        try await wait("same-cover-prepared") {
          store.playing && currentArt() != nil && native.preparedArtworkReady(for: sameCover)
        }
        CoverArt.beginMeasurement(runID)
        store.showPlayer = true
        try await wait("rendered-cover-readiness") {
          guard let measured = CoverArt.measurement(runID) else { return false }
          return measured.bodies > 0 && measured.images > 0
        }
        guard let consoleStart = AppLog.acceptance(runID), consoleStart.chain else {
          throw CheckFailure(step: "structured-console-chain-missing")
        }
        report["structured_console_default_chain"] = true
        report["structured_console_example"] = consoleStart.example
        report["startup_launch_mode_labelled"] = consoleStart.acceptanceMode
        report["startup_scope_retirement_labelled"] = consoleStart.scopedRetirement
        guard consoleStart.acceptanceMode, consoleStart.scopedRetirement else {
          throw CheckFailure(step: "console-attribution-incomplete")
        }
        let renderStart = CoverArt.measurement(runID)!
        let nativeStart = native.measurement(runID)!
        let metadataStart = native.nowPlayingPublications
        let clockStart = store.queue.position
        let started = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(1))
        let renderEnd = CoverArt.measurement(runID)!
        let nativeEnd = native.measurement(runID)!
        guard let consoleEnd = AppLog.acceptance(runID), consoleEnd.count == consoleStart.count
        else {
          throw CheckFailure(step: "structured-console-clock-spam")
        }
        report["structured_console_ticks_do_not_emit"] = true
        guard nativeEnd.callbacks > nativeStart.callbacks,
          nativeEnd.positions > nativeStart.positions, store.queue.position > clockStart
        else { throw CheckFailure(step: "rendered-cover-clock-did-not-advance") }
        report["rendered_cover_bodies"] = renderStart.bodies
        report["playing_cover_bodies"] = renderEnd.bodies - renderStart.bodies
        report["playing_image_constructions"] = renderEnd.images - renderStart.images
        report["playing_image_constructor_ms"] =
          renderEnd.constructorMilliseconds - renderStart.constructorMilliseconds
        report["playing_clock_callbacks"] = nativeEnd.callbacks - nativeStart.callbacks
        report["playing_position_publications"] = nativeEnd.positions - nativeStart.positions
        report["playing_timeline_publications"] = nativeEnd.timelines - nativeStart.timelines
        report["playing_nowplaying_publications"] = native.nowPlayingPublications - metadataStart
        report["playing_window_seconds"] = ProcessInfo.processInfo.systemUptime - started
        report["rendered_artwork_clock_measurement"] = true
        CoverArt.endMeasurement(runID)
        store.showPlayer = false
        let replacementOccurrence = store.current?.id
        retiredRemoteDelivery(.pause)
        guard store.playbackRequested, store.playing, store.current?.id == replacementOccurrence
        else {
          throw CheckFailure(step: "retired-queued-command-controlled-replacement")
        }
        report["retired_remote_delivery_cannot_control_replacement"] = true
        guard let firstArt = currentArt(), firstArt.bounds.width > firstArt.bounds.height else {
          throw CheckFailure(step: "accepted-wide-cover-missing")
        }
        let graph = native.nativePlayerIdentity
        let sameNeedsSource = !native.queueReadout.ready.contains(sameCover)
        let sameTitle = store.queue.entries[1].track.title
        store.next()
        try checkRemoteTransport()
        guard store.current?.id == sameCover, currentArt() === firstArt,
          MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
            == sameTitle
        else {
          throw CheckFailure(step: "same-cover-prepared-next-blanked")
        }
        if sameNeedsSource {
          guard native.queueReadout.preparing, native.queueReadout.queued.isEmpty,
            native.lastNowPlayingProjection?.rate == 0, native.lastNowPlayingProjection?.clock == 0,
            store.queue.position == 0
          else { throw CheckFailure(step: "unknown-media-bypassed-fresh-preparation") }
          try checkPreparingSeek()
          try await checkPreparingPause()
        }
        report["cached_same_cover_prepared_next_never_blanks"] = true
        try await wait("different-cover-prepared") {
          native.preparedArtworkReady(for: differentCover)
        }
        let differentNeedsSource = !native.queueReadout.ready.contains(differentCover)
        let differentTitle = store.queue.entries[2].track.title
        store.next()
        try checkRemoteTransport()
        guard store.current?.id == differentCover, let nextArt = currentArt(),
          nextArt !== firstArt, nextArt.bounds.width < nextArt.bounds.height,
          native.nativePlayerIdentity == graph,
          MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
            == differentTitle
        else { throw CheckFailure(step: "different-cover-prepared-next-blanked-or-stale") }
        if differentNeedsSource {
          guard native.queueReadout.preparing, native.queueReadout.queued.isEmpty,
            native.lastNowPlayingProjection?.rate == 0, native.lastNowPlayingProjection?.clock == 0,
            store.queue.position == 0
          else { throw CheckFailure(step: "unknown-different-cover-media-bypassed-preparation") }
          try checkPreparingSeek()
          try await checkPreparingPause()
        }
        guard sameNeedsSource || differentNeedsSource else {
          throw CheckFailure(step: "unknown-media-fallback-not-observed")
        }
        report["unknown_media_keeps_fresh_source_fallback_at_rate_zero"] = true
        report["cached_different_cover_prepared_next_adopts_accepted_image"] = true
        report["prepared_next_keeps_existing_native_graph"] = true
        report["prepared_next_keeps_remote_transport_enabled"] = true
        guard checkedPreparingPause else {
          throw CheckFailure(step: "remote-preparing-pause-not-observed")
        }
        report["remote_pause_cancels_preparing_and_retired_commands"] = true
        try await wait("selected-occurrence-prepared") {
          store.playing && native.preparedArtworkReady(for: selectedPrepared)
        }
        let selectedTitle = store.queue.entries[3].track.title
        let selectionNeedsSource = !native.queueReadout.ready.contains(selectedPrepared)
        let beforeSelectionArt = currentArt()
        store.select(selectedPrepared)
        try checkRemoteTransport()
        guard store.current?.id == selectedPrepared, currentArt() === beforeSelectionArt,
          native.nativePlayerIdentity == graph,
          MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
            == selectedTitle
        else { throw CheckFailure(step: "prepared-selection-lost-presentation-or-owner") }
        if selectionNeedsSource {
          guard native.queueReadout.preparing, native.queueReadout.queued.isEmpty,
            native.lastNowPlayingProjection?.rate == 0, native.lastNowPlayingProjection?.clock == 0
          else { throw CheckFailure(step: "prepared-selection-bypassed-fresh-preparation") }
        }
        report["prepared_selection_keeps_remote_transport_enabled"] = true
        store.pause()
        native.stop()
        try await Task.sleep(for: .milliseconds(300))
        guard MPNowPlayingInfoCenter.default().nowPlayingInfo == nil else {
          throw CheckFailure(step: "prepared-art-republished-after-stop")
        }
        report["prepared_artwork_stop_cannot_republish"] = true
        let center = MPRemoteCommandCenter.shared()
        guard !center.playCommand.isEnabled, !center.pauseCommand.isEnabled,
          !center.nextTrackCommand.isEnabled, !center.previousTrackCommand.isEnabled,
          !center.changePlaybackPositionCommand.isEnabled
        else { throw CheckFailure(step: "stopped-remote-transport-remains-enabled") }
        report["stopped_remote_transport_is_disabled"] = true
        report.merge(try await coldReplacementChecks(store: store, native: native)) {
          _, new in new
        }
        report["finished"] = true
      } catch {
        report["failure"] = (error as? CheckFailure)?.step ?? "unexpected-artwork-error"
        report["failure_phase"] =
          switch store.phase {
          case .paused: 0
          case .preparing: 1
          case .playing: 2
          case .waiting: 3
          case .failed: 4
          }
        report["failure_native_code"] = store.lastPlaybackFailure?.detail.code ?? 0
        let nativeClock = native.queueReadout.seconds
        report["failure_native_clock"] = nativeClock.isFinite ? nativeClock : -1
        report["failure_model_clock"] = store.queue.position
        report["failure_requested"] = store.playbackRequested
        report["failure_native_queued_count"] = native.queueReadout.queued.count
        report["failure_native_ready_count"] = native.queueReadout.ready.count
        report["failure_art_cached_count"] = native.artworkPreparationReadout.cached
        report["failure_art_authorized_count"] = native.artworkPreparationReadout.authorized
        report["failure_art_prepared_decoded"] = native.artworkPreparationReadout.decoded
      }
      if let publish {
        publish(report)
      } else {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
          try? data.write(
            to: documents.appendingPathComponent("nowplaying-artwork-report.json"), options: .atomic
          )
        }
      }
    }
  }
#endif
