#if DEBUG
  import AVFoundation
  import CryptoKit
  import Foundation
  import MediaPlayer
  import UIKit

  extension DevelopmentAcceptance {
    static func runSessionEvents(
      store: PlayerStore, native: NativePlayer, runID: UUID,
      publish: (([String: Any]) -> Void)? = nil
    ) async {
      var report: [String: Any] = ["run_id": runID.uuidString]
      enum Stage: String {
        case start, appDeactivation, explicitResume, albumEnqueue, firstSeek, latestPausedSeek,
          resumeAfterSeek,
          selectSecond, selectFirst, rapidReplacement, boundSeek, pausedResetRetry,
          activeResetRetry,
          naturalAdvance, resumeAfterNaturalPause
      }
      func wait(_ stage: Stage, _ check: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
          if check() { return }
          try await Task.sleep(for: .milliseconds(100))
        }
        throw CheckFailure(step: "session-" + stage.rawValue + "-timeout")
      }
      do {
        let browser = try await readyBrowser(store: store)
        guard let origin = store.playbackOrigin(library: browser.authorizedLibrary),
          native.queueReadout.queued.isEmpty
        else { throw CheckFailure(step: "route-cold-owner-setup") }
        store.playAlbum(.fixtureAlbum, origin: origin)
        guard store.isPreparingAlbum(MusicItem.fixtureAlbum.id, origin: origin) else {
          throw CheckFailure(step: "route-cold-detail-not-pending")
        }
        for reason in [nil, UInt.max, AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue]
        {
          native.receiveRouteChangeForCheck(reason)
          guard store.isPreparingAlbum(MusicItem.fixtureAlbum.id, origin: origin) else {
            throw CheckFailure(step: "route-other-reason-paused-detail")
          }
        }
        native.receiveRouteChangeForCheck(
          AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
        guard !store.isPreparingAlbum(MusicItem.fixtureAlbum.id, origin: origin),
          !store.playbackRequested, store.phase == .paused, native.queueReadout.queued.isEmpty
        else { throw CheckFailure(step: "route-cold-pause-was-not-immediate") }
        let selection = try await fixtureAlbumSelection(store: store)
        store.playSelection(selection)
        try await wait(.start) { store.playing && store.queue.position > 0.5 }
        native.receiveRouteChangeForCheck(
          AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue)
        guard store.playbackRequested else { throw CheckFailure(step: "route-new-device-paused") }
        native.receiveRouteChangeForCheck(
          AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
        guard !store.playbackRequested, store.phase == .paused else {
          throw CheckFailure(step: "route-current-pause-was-not-immediate")
        }
        store.play()
        try await wait(.explicitResume) { store.playing }
        let before = store.queue.position
        native.sessionDeactivated(source: .app)
        try await wait(.appDeactivation) { store.playing && store.queue.position > before + 0.2 }
        guard store.playbackRequested else {
          throw CheckFailure(step: "app-stop-retired-new-playback")
        }
        report["late_app_deactivation_preserves_current_playback"] = true
        native.sessionDeactivated(source: .system)
        guard !store.playbackRequested && store.phase == .paused else {
          throw CheckFailure(step: "system-did-not-pause")
        }
        try await Task.sleep(for: .milliseconds(400))
        guard store.phase == .paused && !store.playbackRequested else {
          throw CheckFailure(step: "unrequested-resume")
        }
        report["system_deactivation_pauses_without_autoresume"] = true
        let paused = store.queue.position
        store.play()
        try await wait(.explicitResume) { store.playing && store.queue.position > paused + 0.2 }
        report["explicit_play_resumes"] = true
        try await wait(.albumEnqueue) {
          store.queue.entries.dropFirst(store.queue.index + 1).first.map {
            native.hasPrepared($0.id)
          } == true
        }
        let enqueueOccurrence = store.current?.id
        let enqueueGraph = native.nativePlayerIdentity
        let enqueueObservers = native.itemObservationInstallations
        let enqueueClock = store.queue.position
        store.enqueueSelection(selection, next: false)
        guard store.current?.id == enqueueOccurrence,
          native.queueReadout.occurrence == enqueueOccurrence,
          native.nativePlayerIdentity == enqueueGraph,
          native.itemObservationInstallations == enqueueObservers,
          store.queue.position == enqueueClock, store.playbackRequested, store.playing,
          store.queue.entries.count == selection.items.count * 2,
          Set(store.queue.entries.map(\.id)).count == selection.items.count * 2
        else { throw CheckFailure(step: "album-enqueue-replaced-current-source") }
        try await wait(.albumEnqueue) {
          store.queue.entries.dropFirst(store.queue.index + 1).first.map {
            native.hasPrepared($0.id)
          } == true
        }
        guard store.queue.entries.count >= 4, let successor = store.queue.successor else {
          throw CheckFailure(step: "future-queue-edit-fixture")
        }
        let distant = store.queue.entries.last!.id
        let beforeEdit = store.queue.position
        store.move(from: store.queue.entries.count - 1, to: 2)
        store.remove([distant])
        try await wait(.albumEnqueue) { store.playing && store.queue.position > beforeEdit + 0.2 }
        guard store.current?.id == enqueueOccurrence, native.nativePlayerIdentity == enqueueGraph,
          native.queueReadout.occurrence == enqueueOccurrence, native.hasPrepared(successor.id),
          native.itemObservationInstallations == enqueueObservers
        else { throw CheckFailure(step: "future-queue-edit-interrupted-current-or-successor") }
        report["future_queue_edits_preserve_native_items_and_clock"] = true
        let acceptedBeforeSeek = store.queue.position
        store.seek(4)
        report["seek_entry_model_clock"] = store.queue.position
        report["seek_entry_projection_clock"] = native.lastNowPlayingProjection?.clock ?? -1
        report["seek_entry_projection_rate"] = native.lastNowPlayingProjection?.rate ?? -1
        guard let pending = native.lastNowPlayingProjection,
          pending.rate == 0, abs(pending.clock - 4) < 0.001,
          abs(store.queue.position - acceptedBeforeSeek) < 0.05
        else { throw CheckFailure(step: "seek-entry-anchor-is-not-pending-intent") }
        try await wait(.firstSeek) { !native.queueReadout.seeking && store.queue.position >= 3.95 }
        report["pending_seek_projection_keeps_accepted_model_clock"] = true
        store.seek(6)
        store.seek(2)
        store.pause()
        guard let latest = native.lastNowPlayingProjection,
          abs(latest.clock - 2) < 0.001, latest.rate == 0, !store.playbackRequested
        else { throw CheckFailure(step: "latest-seek-pause-lost-target") }
        try await wait(.latestPausedSeek) {
          !native.queueReadout.seeking && abs(store.queue.position - 2) < 0.05
        }
        guard !store.playbackRequested && store.phase == .paused else {
          throw CheckFailure(step: "seek-completion-autoresumed-after-pause")
        }
        report["latest_pending_seek_preserves_explicit_pause"] = true
        store.play()
        try await wait(.resumeAfterSeek) { store.playing }
        let first = store.queue.entries[0].id
        let second = store.queue.entries[1].id
        let healthyGraph = native.nativePlayerIdentity
        store.select(second)
        try await wait(.selectSecond) { store.playing && native.queueReadout.occurrence == second }
        store.select(first)
        try await wait(.selectFirst) { store.playing && native.queueReadout.occurrence == first }
        guard native.nativePlayerIdentity == healthyGraph else {
          throw CheckFailure(step: "healthy-replacement-rebuilt-graph")
        }
        store.seek(4)
        store.select(second)
        store.select(first)
        try await wait(.rapidReplacement) {
          store.playing && native.queueReadout.occurrence == first
        }
        guard store.current?.id == first, store.queue.position < 2 else {
          throw CheckFailure(step: "superseded-seek-changed-new-occurrence")
        }
        report["a_b_a_rapid_replace_seek_preserves_current"] = true
        store.seek(3)
        try await wait(.boundSeek) { !native.queueReadout.seeking && store.queue.position >= 2.95 }
        store.pause()
        try await Task.sleep(for: .milliseconds(300))
        let observations = native.itemObservationInstallations
        native.recheckCurrentItem()
        native.recheckCurrentItem()
        guard native.itemObservationInstallations == observations else {
          throw CheckFailure(step: "same-item-reinstalled-observers")
        }
        let publications = native.nowPlayingPublications
        try await Task.sleep(for: .milliseconds(700))
        guard native.nowPlayingPublications == publications else {
          throw CheckFailure(step: "paused-tick-republishes-metadata")
        }
        report["same_item_observers_and_paused_metadata_stable"] = true
        let pausedEnqueueClock = store.queue.position
        let pausedEnqueueGraph = native.nativePlayerIdentity
        let pausedEnqueueObservers = native.itemObservationInstallations
        store.enqueueSelection(selection, next: false)
        guard !store.playbackRequested, store.phase == .paused,
          store.current?.id == first, native.queueReadout.occurrence == first,
          store.queue.position == pausedEnqueueClock,
          native.nativePlayerIdentity == pausedEnqueueGraph,
          native.itemObservationInstallations == pausedEnqueueObservers
        else { throw CheckFailure(step: "paused-album-enqueue-replaced-source-or-resumed") }
        report["album_enqueue_preserves_current_native_source_and_pause"] = true
        let pausedPosition = store.queue.position
        let oldGraph = native.nativePlayerIdentity
        NotificationCenter.default.post(
          name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        guard store.phase == .paused, !store.playbackRequested, store.current?.id == first,
          abs(store.queue.position - pausedPosition) < 0.05,
          native.nativePlayerIdentity != oldGraph, native.queueReadout.queued.isEmpty
        else {
          throw CheckFailure(step: "paused-reset-lost-clock-or-autoresumed")
        }
        report["paused_reset_preserves_accepted_clock_and_requires_play"] = true
        store.play()
        try await wait(.pausedResetRetry) {
          store.playing && store.queue.position > pausedPosition + 0.1
        }
        let acceptedPosition = store.queue.position
        NotificationCenter.default.post(
          name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        guard store.phase == .failed, !store.playbackRequested, store.current?.id == first,
          abs(store.queue.position - acceptedPosition) < 0.05
        else {
          throw CheckFailure(step: "active-reset-advanced-or-lost-clock")
        }
        report["active_reset_fails_without_false_end_or_autoresume"] = true
        store.play()
        try await wait(.activeResetRetry) {
          store.playing && store.queue.position > acceptedPosition + 0.1
        }
        report["explicit_retry_recreates_usable_graph"] = true
        let naturalDelivery = native.remoteDeliveryForCheck()
        store.seek(17.6)
        try await wait(.naturalAdvance) { store.current?.id == second && store.playing }
        naturalDelivery(.seek(0))
        naturalDelivery(.next)
        naturalDelivery(.previous)
        guard store.current?.id == second, !native.queueReadout.seeking else {
          throw CheckFailure(step: "natural-advance-accepted-old-relative-command")
        }
        naturalDelivery(.pause)
        guard !store.playbackRequested, store.phase == .paused else {
          throw CheckFailure(step: "natural-advance-dropped-live-pause")
        }
        store.play()
        try await wait(.resumeAfterNaturalPause) { store.playing }
        native.receiveRouteChangeForCheck(
          AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
        guard !store.playbackRequested, store.phase == .paused, store.current?.id == second else {
          throw CheckFailure(step: "route-natural-successor-pause-was-not-immediate")
        }
        store.play()
        try await wait(.resumeAfterNaturalPause) { store.playing }
        let oldPlay = native.remoteDeliveryForCheck()
        store.pause()
        oldPlay(.play)
        guard !store.playbackRequested else {
          throw CheckFailure(step: "queued-play-overrode-later-pause")
        }
        report["explicit_pause_fences_older_queued_play"] = true
        guard let loopEntry = store.current,
          let single = store.playbackSelection([loopEntry.track], library: loopEntry.libraryID)
        else { throw CheckFailure(step: "repeat-remote-selection") }
        for mode in [PlayerStore.RepeatMode.one, .all] {
          store.setRepeatMode(mode)
          store.playSelection(single)
          try await wait(.resumeAfterNaturalPause) { store.playing }
          let occurrence = store.current?.id
          let oldSource = native.remoteSourceRevisionForCheck
          let loopDelivery = native.remoteDeliveryForCheck()
          store.seek(17.6)
          try await wait(.naturalAdvance) {
            native.remoteSourceRevisionForCheck != oldSource && store.playing
              && store.current?.id == occurrence && !native.queueReadout.seeking
          }
          let newSource = native.remoteSourceRevisionForCheck
          loopDelivery(.seek(0))
          loopDelivery(.next)
          loopDelivery(.previous)
          loopDelivery(.play)
          guard native.remoteSourceRevisionForCheck == newSource,
            store.current?.id == occurrence, !native.queueReadout.seeking,
            store.playbackRequested
          else { throw CheckFailure(step: "repeat-accepted-old-source-action") }
          loopDelivery(.pause)
          guard !store.playbackRequested, store.phase == .paused else {
            throw CheckFailure(step: "repeat-dropped-session-pause")
          }
          let beforeResume = native.remoteDeliveryForCheck()
          store.play()
          try await wait(.resumeAfterNaturalPause) { store.playing }
          beforeResume(.pause)
          guard store.playbackRequested else {
            throw CheckFailure(step: "repeat-old-pause-overrode-explicit-resume")
          }
          let beforeReplacement = native.remoteDeliveryForCheck()
          store.playSelection(single)
          beforeReplacement(.pause)
          guard store.playbackRequested else {
            throw CheckFailure(step: "repeat-old-pause-overrode-explicit-replacement")
          }
          try await wait(.resumeAfterNaturalPause) { store.playing }
          store.pause()
        }
        report["natural_advance_preserves_pause_but_rejects_old_item_actions"] = true
        let retiredDelivery = native.remoteDeliveryForCheck()
        await store.logout()
        retiredDelivery(.pause)
        retiredDelivery(.play)
        retiredDelivery(.seek(0))
        guard store.active == nil, !store.playbackRequested, native.queueReadout.queued.isEmpty
        else {
          throw CheckFailure(step: "retired-remote-receipt-survived-account")
        }
        report["native_end_advances_exact_successor"] = true
        store.pause()
        report["finished"] = true
      } catch {
        report["failure"] = (error as? CheckFailure)?.step ?? "unexpected-session-error"
        report["failure_phase"] =
          switch store.phase {
          case .paused: 0
          case .preparing: 1
          case .playing: 2
          case .waiting: 3
          case .failed: 4
          }
        report["failure_native_code"] = store.lastPlaybackFailure?.detail.code ?? 0
        let clock = native.queueReadout.seconds
        report["failure_native_clock"] = clock.isFinite ? clock : -1
        report["failure_model_clock"] = store.queue.position
        report["failure_requested"] = store.playbackRequested
        report["failure_native_queued_count"] = native.queueReadout.queued.count
        report["failure_native_ready_count"] = native.queueReadout.ready.count
      }
      if let publish {
        publish(report)
      } else {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
          try? data.write(
            to: documents.appendingPathComponent("session-events-report.json"), options: .atomic)
        }
      }
    }
  }
#endif
