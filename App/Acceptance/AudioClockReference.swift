#if DEBUG && AUDIO_CLOCK_ACCEPTANCE
  import Accelerate
  import AudioToolbox
  import Foundation

  struct AudioClockReference: Sendable {
    private static let rate = 24_000.0
    private static let cell = 0.020
    private static let cellFrames = 480
    private static let group = 4
    private static let minimumPoints = 125
    private static let maximumPoints = 600
    static let recommendedWindowPoints = 400
    private static let maximumBytes = 64 * 1024 * 1024
    private static let maximumFrames = 3_600 * 24_000
    private static let dimensions = 8
    private static let minimumCorrelation = 0.94
    private static let minimumMargin = 0.06

    enum MatchReason: Int, Sendable {
      case matched = 0
      case tooShort = 1
      case invalid = 2
      case silence = 3
      case lowVariation = 4
      case weakFit = 5
      case ambiguous = 6
      case missingBands = 7
      case referenceTooShort = 8
    }
    struct MatchDiagnostics: Sendable {
      let reason: MatchReason
      let cells: Int
      let bestScore: Double
      let rivalScore: Double
      let bestTime: Double
      var margin: Double { bestScore - rivalScore }
    }
    private enum Failure: Error { case input, decode, format, nonfinite, tooLong }
    private final class MemoryAudio: Sendable {
      let bytes: Data
      init(_ bytes: Data) { self.bytes = bytes }
    }
    private struct Energy: Sendable {
      let level: Double
      let detail: Double
      let bands: SIMD8<Double>
    }
    private struct Phase: Sendable {
      let offset: Int
      let fraction: Double
      let values: [[Double]]
      let sums: [[Double]]
      let sumSquares: [Double]
    }
    private let energies: [Energy]
    private let phases: [Phase]
    let duration: Double

    init(data: Data) throws {
      guard !data.isEmpty, data.count <= Self.maximumBytes else { throw Failure.input }
      let decoded = try Self.decode(data)
      self.init(energies: decoded.0, duration: Double(decoded.1) / Self.rate)
    }

    private init(energies: [Energy], duration: Double) {
      self.energies = energies
      self.duration = duration
      var prepared = [Phase]()
      prepared.reserveCapacity(16)
      for fraction in [0.0, 0.25, 0.5, 0.75] {
        for offset in 0..<Self.group {
          let available = max(0, energies.count - offset - (fraction == 0 ? 0 : 1))
          let count = available / Self.group
          var values = Array(repeating: [Double](), count: Self.dimensions)
          var sums = Array(repeating: [0.0], count: Self.dimensions)
          var sumSquares = [0.0]
          for dimension in 0..<Self.dimensions {
            values[dimension].reserveCapacity(count)
            sums[dimension].reserveCapacity(count + 1)
          }
          sumSquares.reserveCapacity(count + 1)
          for index in 0..<count {
            let energy = Self.grouped(
              energies, index: offset + index * Self.group, fraction: fraction)
            let vector = Self.features(energy)
            var square = 0.0
            for dimension in 0..<Self.dimensions {
              let value = vector[dimension]
              values[dimension].append(value)
              sums[dimension].append(sums[dimension].last! + value)
              square += value * value
            }
            sumSquares.append(sumSquares.last! + square)
          }
          prepared.append(
            Phase(
              offset: offset, fraction: fraction,
              values: values, sums: sums, sumSquares: sumSquares))
        }
      }
      phases = prepared
    }

    func points(from seconds: Double, count: Int) -> [AudioClockPoint] {
      guard seconds.isFinite, seconds >= 0, count > 0, count <= Self.maximumPoints else {
        return []
      }
      let location = seconds / Self.cell
      guard location < Double(energies.count) else { return [] }
      let start = Int(location.rounded(.down))
      let fraction = location - Double(start)
      guard start + count + (fraction > 1e-8 ? 1 : 0) <= energies.count else { return [] }
      return (0..<count).map { offset in
        let value = Self.interpolate(energies, index: start + offset, fraction: fraction)
        return AudioClockPoint(
          time: seconds + Double(offset) * Self.cell,
          level: Float(sqrt(value.level)), detail: Float(sqrt(value.detail)),
          bands: AudioClockBandAccumulator.rms(value.bands, divisor: 1))
      }
    }

    func match(_ points: [AudioClockPoint]) -> (time: Double, confidence: Double)? {
      let result = diagnose(points)
      guard result.reason == .matched else { return nil }
      return (result.bestTime, result.bestScore)
    }

    func diagnose(_ input: [AudioClockPoint]) -> MatchDiagnostics {
      let points = Array(input.prefix(Self.maximumPoints))
      let count = points.count
      func result(
        _ reason: MatchReason, _ best: Double = -1,
        _ rival: Double = -1, _ time: Double = -1
      ) -> MatchDiagnostics {
        MatchDiagnostics(
          reason: reason, cells: count, bestScore: best, rivalScore: rival, bestTime: time)
      }
      guard count >= Self.minimumPoints else { return result(.tooShort) }
      guard energies.count >= count else { return result(.referenceTooShort) }
      var raw = [Energy]()
      raw.reserveCapacity(count)
      var active = 0
      var sumLevelEnergy = 0.0
      var sumBands = 0.0
      for (index, point) in points.enumerated() {
        guard point.time.isFinite, point.level.isFinite, point.detail.isFinite,
          point.level >= 0, point.level <= 16, point.detail >= 0, point.detail <= 32
        else { return result(.invalid) }
        if index > 0, abs(point.time - points[index - 1].time - Self.cell) > 0.002 {
          return result(.invalid)
        }
        var bands = SIMD8<Double>.zero
        for band in 0..<6 {
          let value = Double(point.bands[band])
          guard value.isFinite, value >= 0, value <= 32 else { return result(.invalid) }
          bands[band] = value * value
          sumBands += bands[band]
        }
        let level = Double(point.level)
        let detail = Double(point.detail)
        if level >= 0.0001 { active += 1 }
        sumLevelEnergy += level * level
        raw.append(Energy(level: level * level, detail: detail * detail, bands: bands))
      }
      guard active * 10 >= count * 7, sqrt(sumLevelEnergy / Double(count)) >= 0.0005 else {
        return result(.silence)
      }
      guard sumBands > max(1e-12, sumLevelEnergy * 0.0001) else { return result(.missingBands) }
      let groupedCount = count / Self.group
      var query = Array(repeating: [Double](), count: Self.dimensions)
      var means = Array(repeating: 0.0, count: Self.dimensions)
      for dimension in 0..<Self.dimensions { query[dimension].reserveCapacity(groupedCount) }
      for index in 0..<groupedCount {
        let vector = Self.features(Self.grouped(raw, index: index * Self.group, fraction: 0))
        for dimension in 0..<Self.dimensions {
          query[dimension].append(vector[dimension])
          means[dimension] += vector[dimension]
        }
      }
      var queryNorm = 0.0
      for dimension in 0..<Self.dimensions {
        means[dimension] /= Double(groupedCount)
        for index in 0..<groupedCount {
          query[dimension][index] -= means[dimension]
          queryNorm += query[dimension][index] * query[dimension][index]
        }
      }
      guard queryNorm / Double(groupedCount) >= 0.0025 else { return result(.lowVariation) }

      var bestScore = -1.0
      var bestTime = -1.0
      var allScores = [[Float]]()
      allScores.reserveCapacity(phases.count)
      for phase in phases {
        let candidates = max(0, phase.sumSquares.count - groupedCount)
        var scores = Array(repeating: Float(-1), count: candidates)
        for start in 0..<candidates {
          let end = start + groupedCount
          var norm = phase.sumSquares[end] - phase.sumSquares[start]
          for dimension in 0..<Self.dimensions {
            let sum = phase.sums[dimension][end] - phase.sums[dimension][start]
            norm -= sum * sum / Double(groupedCount)
          }
          guard norm > queryNorm * 0.1, norm < queryNorm * 10 else { continue }
          var dot = 0.0
          for dimension in 0..<Self.dimensions {
            var contribution = 0.0
            query[dimension].withUnsafeBufferPointer { queryValues in
              phase.values[dimension].withUnsafeBufferPointer { referenceValues in
                vDSP_dotprD(
                  queryValues.baseAddress!, 1,
                  referenceValues.baseAddress!.advanced(by: start), 1,
                  &contribution, vDSP_Length(groupedCount))
              }
            }
            dot += contribution
          }
          let correlation = max(-1, min(1, dot / sqrt(queryNorm * norm)))
          scores[start] = Float(correlation)
          if correlation > bestScore {
            bestScore = correlation
            bestTime = Self.time(start: start, phase: phase)
          }
        }
        allScores.append(scores)
      }
      var rival = -1.0
      for (phaseIndex, scores) in allScores.enumerated() {
        for (start, score) in scores.enumerated() {
          if abs(Self.time(start: start, phase: phases[phaseIndex]) - bestTime) > 0.35 {
            rival = max(rival, Double(score))
          }
        }
      }
      guard bestScore >= Self.minimumCorrelation else {
        return result(.weakFit, bestScore, rival, bestTime)
      }
      guard bestScore - rival >= Self.minimumMargin else {
        return result(.ambiguous, bestScore, rival, bestTime)
      }
      return result(.matched, bestScore, rival, bestTime)
    }

    private static func time(start: Int, phase: Phase) -> Double {
      (Double(start * group + phase.offset) + phase.fraction) * cell
    }

    private static func features(_ energy: Energy) -> SIMD8<Double> {
      let level = max(energy.level, 1e-12)
      let detail = max(energy.detail, 1e-16)
      let spectralWeight = 1.0 / sqrt(6.0)
      var result = SIMD8<Double>.zero
      result[0] = 0.5 * log(level) * 0.5
      result[1] = 0.5 * log(detail / level) * 0.25
      for band in 0..<6 {
        result[band + 2] = 0.5 * log(max(energy.bands[band], 1e-16) / level) * spectralWeight
      }
      return result
    }

    private static func grouped(_ values: [Energy], index: Int, fraction: Double) -> Energy {
      var level = 0.0
      var detail = 0.0
      var bands = SIMD8<Double>.zero
      for offset in 0..<group {
        let value = interpolate(values, index: index + offset, fraction: fraction)
        level += value.level
        detail += value.detail
        bands += value.bands
      }
      return Energy(
        level: level / Double(group), detail: detail / Double(group), bands: bands / Double(group))
    }

    private static func interpolate(_ values: [Energy], index: Int, fraction: Double) -> Energy {
      guard fraction > 1e-8 else { return values[index] }
      let a = values[index]
      let b = values[index + 1]
      return Energy(
        level: a.level * (1 - fraction) + b.level * fraction,
        detail: a.detail * (1 - fraction) + b.detail * fraction,
        bands: a.bands * (1 - fraction) + b.bands * fraction)
    }

    private static func decode(_ data: Data) throws -> ([Energy], Int) {
      let owner = MemoryAudio(data)
      defer { withExtendedLifetime(owner) {} }
      let context = Unmanaged.passUnretained(owner).toOpaque()
      var file: AudioFileID?
      let opened = AudioFileOpenWithCallbacks(
        context,
        { context, position, requested, output, actual in
          actual.pointee = 0
          let data = Unmanaged<MemoryAudio>.fromOpaque(context).takeUnretainedValue().bytes
          guard position >= 0 else { return OSStatus(-50) }
          guard position < Int64(data.count) else { return noErr }
          let count = min(Int(requested), data.count - Int(position))
          if count > 0 {
            data.withUnsafeBytes { bytes in
              _ = memcpy(output, bytes.baseAddress!.advanced(by: Int(position)), count)
            }
            actual.pointee = UInt32(count)
          }
          return noErr
        }, nil,
        { context in
          Int64(Unmanaged<MemoryAudio>.fromOpaque(context).takeUnretainedValue().bytes.count)
        }, nil, 0, &file)
      guard opened == noErr, let file else { throw Failure.decode }
      defer { _ = AudioFileClose(file) }
      var wrapped: ExtAudioFileRef?
      guard ExtAudioFileWrapAudioFileID(file, false, &wrapped) == noErr, let wrapped else {
        throw Failure.decode
      }
      defer { _ = ExtAudioFileDispose(wrapped) }
      var format = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
        mBitsPerChannel: 32, mReserved: 0)
      guard
        ExtAudioFileSetProperty(
          wrapped, kExtAudioFileProperty_ClientDataFormat,
          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format) == noErr
      else { throw Failure.format }
      var actual = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      guard
        ExtAudioFileGetProperty(wrapped, kExtAudioFileProperty_ClientDataFormat, &size, &actual)
          == noErr,
        actual.mSampleRate == rate, actual.mChannelsPerFrame == 1, actual.mBitsPerChannel == 32,
        actual.mBytesPerFrame == 4, actual.mFormatFlags & kAudioFormatFlagIsFloat != 0
      else { throw Failure.format }

      let capacity = 4_800
      var buffer = Array(repeating: Float(0), count: capacity)
      var result = [Energy]()
      result.reserveCapacity(20_000)
      var total = 0
      var inCell = 0
      var level = 0.0
      var detail = 0.0
      var previous = 0.0
      var hasPrevious = false
      var bandAccumulator = AudioClockBandAccumulator()
      while true {
        var frames = UInt32(capacity)
        let status = buffer.withUnsafeMutableBytes { bytes -> OSStatus in
          var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers:
              AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
          return ExtAudioFileRead(wrapped, &frames, &list)
        }
        guard status == noErr else { throw Failure.decode }
        if frames == 0 { break }
        guard frames <= UInt32(capacity), total <= maximumFrames - Int(frames) else {
          throw Failure.tooLong
        }
        for index in 0..<Int(frames) {
          let sample = Double(buffer[index])
          guard sample.isFinite, abs(sample) <= 16 else { throw Failure.nonfinite }
          let difference = hasPrevious ? sample - previous : 0
          previous = sample
          hasPrevious = true
          level += sample * sample
          detail += difference * difference
          bandAccumulator.append(sample)
          inCell += 1
          if inCell == cellFrames {
            result.append(
              Energy(
                level: level / Double(cellFrames), detail: detail / Double(cellFrames),
                bands: bandAccumulator.energies / Double(cellFrames)))
            level = 0
            detail = 0
            inCell = 0
            bandAccumulator.resetCell()
          }
        }
        total += Int(frames)
      }
      guard total > 0 else { throw Failure.decode }
      return (result, total)
    }

    static func selfCheck() -> Bool {
      func invented(_ seed: UInt64) -> [Energy] {
        var state = seed
        var amplitude = 0.0
        var roughness = 0.0
        var spectrum = SIMD8<Double>.zero
        func random() -> Double {
          state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
          return Double(state >> 11) / 9_007_199_254_740_992 * 2 - 1
        }
        return (0..<2_400).map { index in
          amplitude = amplitude * 0.65 + random() * 0.35
          roughness = roughness * 0.65 + random() * 0.35
          for band in 0..<6 { spectrum[band] = spectrum[band] * 0.60 + random() * 0.40 }
          if index < 100 { return Energy(level: 0, detail: 0, bands: .zero) }
          let level = exp(-2.0 + amplitude * 0.8 + 0.25 * sin(Double(index) * 0.097))
          let detail = level * exp(-2.0 + roughness * 0.7 + 0.2 * cos(Double(index) * 0.157))
          var bands = SIMD8<Double>.zero
          for band in 0..<6 {
            bands[band] =
              level * level
              * exp(
                -1.5 + spectrum[band] * 1.2
                  + 0.35 * sin(Double(index) * (0.033 + Double(band) * 0.019)))
          }
          return Energy(level: level * level, detail: detail * detail, bands: bands)
        }
      }
      func withClock(
        _ points: [AudioClockPoint], _ clock: Double,
        gain: Float = 1, equalization: Bool = false
      ) -> [AudioClockPoint] {
        points.enumerated().map { index, point in
          var bands = point.bands * gain
          if equalization {
            for band in 0..<6 { bands[band] *= Float(0.6 + 0.11 * Double(band)) }
          }
          return AudioClockPoint(
            time: clock + Double(index) * cell,
            level: point.level * gain, detail: point.detail * gain, bands: bands)
        }
      }
      func scaled(_ value: Energy, _ factor: Double) -> Energy {
        Energy(
          level: value.level * factor, detail: value.detail * factor, bands: value.bands * factor)
      }
      let source = invented(91)
      let reference = Self(energies: source, duration: 48)
      let passage = reference.points(from: 11.347, count: recommendedWindowPoints)
      guard passage.count == recommendedWindowPoints,
        let located = reference.match(withClock(passage, 900, gain: 0.43, equalization: true)),
        abs(located.time - 11.347) <= 0.016, located.confidence >= minimumCorrelation,
        let replayed = reference.match(withClock(passage, 0)),
        abs(replayed.time - located.time) <= 0.016
      else { return false }
      let silence = (0..<400).map { AudioClockPoint(time: Double($0) * cell, level: 0, detail: 0) }
      let constant = (0..<400).map {
        AudioClockPoint(
          time: Double($0) * cell,
          level: 0.1, detail: 0.02, bands: SIMD8<Float>(repeating: 0.03))
      }
      guard reference.diagnose(silence).reason == .silence,
        reference.diagnose(constant).reason == .lowVariation,
        reference.diagnose(Array(passage.prefix(100))).reason == .tooShort
      else { return false }
      var broken = withClock(passage, 2)
      broken[70] = AudioClockPoint(
        time: broken[70].time + 0.1,
        level: broken[70].level, detail: broken[70].detail, bands: broken[70].bands)
      guard reference.diagnose(broken).reason == .invalid else { return false }
      let legacy = passage.map {
        AudioClockPoint(time: $0.time, level: $0.level, detail: $0.detail)
      }
      guard reference.diagnose(legacy).reason == .missingBands else { return false }

      var shortCopy = source
      for offset in 0..<200 { shortCopy[1_600 + offset] = source[500 + offset] }
      let extended = Self(energies: shortCopy, duration: 48)
      guard extended.diagnose(extended.points(from: 10.2, count: 150)).reason == .ambiguous,
        let contextual = extended.match(
          extended.points(from: 10.2, count: recommendedWindowPoints)),
        abs(contextual.time - 10.2) <= 0.016
      else { return false }

      var longCopy = source
      for offset in 0..<600 { longCopy[1_600 + offset] = source[500 + offset] }
      let repeated = Self(energies: longCopy, duration: 48)
      guard
        repeated.diagnose(repeated.points(from: 10.2, count: recommendedWindowPoints)).reason
          == .ambiguous
      else { return false }
      for offset in 0..<600 { longCopy[1_600 + offset] = scaled(source[500 + offset], 0.25) }
      let quieterRepeat = Self(energies: longCopy, duration: 48)
      guard
        quieterRepeat.diagnose(quieterRepeat.points(from: 10.2, count: recommendedWindowPoints))
          .reason == .ambiguous
      else { return false }

      let other = Self(energies: invented(7_733), duration: 48)
      guard reference.match(other.points(from: 21.125, count: recommendedWindowPoints)) == nil
      else { return false }
      let otherEnergy = invented(7_733)
      let misleading = source.enumerated().map { index, value in
        Energy(
          level: value.level, detail: value.detail,
          bands: otherEnergy[index].bands * (value.level / max(otherEnergy[index].level, 1e-12)))
      }
      let wrongSpectrum = Self(energies: misleading, duration: 48)
      return reference.match(wrongSpectrum.points(from: 11.347, count: recommendedWindowPoints))
        == nil
        && reference.points(from: -1, count: 150).isEmpty
        && reference.points(from: 47, count: 150).isEmpty
    }
  }
#endif

#if DEBUG && AUDIO_CLOCK_ACCEPTANCE && LIVE_MUSIC_ACCEPTANCE && os(iOS)
  import AVFoundation

  @MainActor enum AudioClockRoute {
    static let speaker = 2

    static var current: Int {
      mask(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType))
    }

    static func mask(_ ports: [AVAudioSession.Port]) -> Int {
      guard !ports.isEmpty else { return 1 }
      return ports.reduce(0) { result, port in
        let bit: Int =
          switch port {
          case .builtInSpeaker: speaker
          case .builtInReceiver: 4
          case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: 8
          case .airPlay: 16
          case .usbAudio: 32
          case .headphones, .lineOut, .HDMI, .displayPort: 64
          case .virtual: 128
          case .carAudio: 256
          default: 512
          }
        return result | bit
      }
    }
  }

  @MainActor enum AudioClockPauseControl {
    private static let blank = [
      "completed": 0, "source_error": 0, "requested_pause_ms": 3000,
      "frozen_native_delta_ms": -1, "frozen_display_delta_ms": -1,
      "paused_cells": 0, "paused_audible_cells": 0, "paused_span_ms": -1,
      "drops_before_pause": -1, "drops_during_pause": 0, "drops_after_pause": 0, "tap_format": 0,
      "matched_before": 0, "matched_after": 0, "median_before_ms": -999_999,
      "median_after_ms": -999_999, "last_native_ms": -1, "end_count": 0, "speaker_only": 0,
    ]
    static var empty: [String: [String: Int]] { ["mixed": blank, "track": blank] }

    static func measure(
      store: PlayerStore, native: NativePlayer, library: String, item: MusicItem,
      reference: AudioClockReference, deadline: Date
    ) async -> [String: [String: Int]] {
      var report = empty
      for path in ["mixed", "track"] {
        guard !Task.isCancelled, deadline.timeIntervalSinceNow > 43 else { break }
        report[path] = await pass(
          trackTap: path == "track", store: store, native: native, library: library,
          item: item, reference: reference, deadline: min(deadline, Date().addingTimeInterval(43)))
      }
      return report
    }

    private static func pass(
      trackTap: Bool, store: PlayerStore, native: NativePlayer, library: String, item: MusicItem,
      reference: AudioClockReference, deadline: Date
    ) async -> [String: Int] {
      var row = blank
      var tap: AudioClockTap?
      var occurrence: UUID?
      let originalHook = native.measureAudioItem
      let receive = native.onEvent
      native.measureAudioItem = { playerItem, entry in
        guard entry.entry.id == occurrence else { return }
        if trackTap {
          guard let track = try await playerItem.asset.loadTracks(withMediaType: .audio).first
          else {
            throw ClientError.invalidResponse
          }
          tap = try AudioClockTap.install(on: playerItem, track: track)
        } else {
          tap = try AudioClockTap.install(on: playerItem)
        }
      }
      var naturalEnds = 0
      native.onEvent = { event in
        if case .finished(let id) = event, id == occurrence { naturalEnds += 1 }
        receive?(event)
      }
      defer {
        if store.playbackRequested { store.pause() }
        tap?.invalidate()
        native.measureAudioItem = originalHook
        native.onEvent = receive
      }
      guard let selection = store.playbackSelection([item], library: library) else { return row }
      store.playSelection(selection)
      guard let id = store.current?.id else { return row }
      occurrence = id
      var cells: [AudioClockPoint] = []
      var anchors: [(item: Double, display: Double)] = []
      var dropsAtPause: UInt64?
      var dropsAtResume: UInt64?
      var pausedAt: ContinuousClock.Instant?
      var resumed = false
      var pauseFirst: (native: Double, display: Double)?
      var pauseLast: (native: Double, display: Double)?
      var pausedFirstPTS: Double?
      var pausedLastPTS: Double?
      var speakerOnly = true
      var lastNative = 0.0
      while Date() < deadline, !Task.isCancelled, store.current?.id == id, naturalEnds == 0 {
        let readout = native.queueReadout
        if store.phase == .failed {
          row["source_error"] = store.lastPlaybackFailure?.detail.code ?? -1
          break
        }
        if readout.occurrence == id, readout.seconds.isFinite {
          let fresh = tap?.drain() ?? []
          guard cells.count + fresh.count <= 2500 else { break }
          cells.append(contentsOf: fresh)
          let nativeTime = readout.seconds
          let display = store.playbackPosition
          lastNative = nativeTime
          if store.playing, readout.timeControlStatus == AVPlayer.TimeControlStatus.playing.rawValue
          {
            speakerOnly = speakerOnly && AudioClockRoute.current == AudioClockRoute.speaker
            anchors.append((nativeTime, display))
          }
          if let pausedAt, !resumed {
            let holding = pausedAt.duration(to: .now)
            if holding >= .milliseconds(350),
              readout.timeControlStatus == AVPlayer.TimeControlStatus.paused.rawValue
            {
              if pauseFirst == nil { pauseFirst = (nativeTime, display) }
              pauseLast = (nativeTime, display)
              row["paused_cells", default: 0] += fresh.count
              row["paused_audible_cells", default: 0] += fresh.filter { $0.level > 0.001 }.count
              if pausedFirstPTS == nil { pausedFirstPTS = fresh.first?.time }
              if let last = fresh.last { pausedLastPTS = last.time }
            }
            if holding >= .seconds(3) {
              dropsAtResume = tap?.dropped
              store.play()
              resumed = true
            }
          } else if pausedAt == nil, store.playing, nativeTime >= 12 {
            dropsAtPause = tap?.dropped
            store.pause()
            pausedAt = .now
          }
          if resumed, nativeTime >= 30 { break }
        }
        do { try await Task.sleep(for: .milliseconds(70)) } catch { break }
      }
      if store.playbackRequested { store.pause() }
      row["speaker_only"] = speakerOnly && !anchors.isEmpty ? 1 : 0
      row["end_count"] = naturalEnds
      row["last_native_ms"] = milliseconds(lastNative)
      if let first = pauseFirst, let last = pauseLast {
        row["frozen_native_delta_ms"] = milliseconds(last.native - first.native)
        row["frozen_display_delta_ms"] = milliseconds(last.display - first.display)
      }
      if let first = pausedFirstPTS, let last = pausedLastPTS {
        row["paused_span_ms"] = milliseconds(last - first + 0.020)
      }
      if let tap, let before = dropsAtPause, let resume = dropsAtResume {
        row["drops_before_pause"] = Int(clamping: before)
        row["drops_during_pause"] = Int(clamping: resume - before)
        row["drops_after_pause"] = Int(clamping: tap.dropped - resume)
        row["tap_format"] = Int(tap.formatStatus)
      }
      if let tap, tap.sourceStatus == 0, reference.duration > 31 {
        let observed = cells
        let clocks = anchors
        let offsets = await Task.detached(priority: .utility) {
          compare(cells: observed, anchors: clocks, reference: reference, trackTap: trackTap)
        }.value
        row["matched_before"] = offsets.before.count
        row["matched_after"] = offsets.after.count
        if !offsets.before.isEmpty {
          row["median_before_ms"] = offsets.before.sorted()[offsets.before.count / 2]
        }
        if !offsets.after.isEmpty {
          row["median_after_ms"] = offsets.after.sorted()[offsets.after.count / 2]
        }
        if resumed, lastNative >= 30, pauseLast != nil { row["completed"] = 1 }
      }
      return row
    }

    nonisolated private static func compare(
      cells: [AudioClockPoint], anchors: [(item: Double, display: Double)],
      reference: AudioClockReference, trackTap: Bool
    ) -> (before: [Int], after: [Int]) {
      var before: [Int] = []
      var after: [Int] = []
      guard cells.count >= 150 else { return (before, after) }
      for center in stride(from: 75, through: cells.count - 75, by: 100) {
        let mid = cells[center].time
        guard let clock = anchors.min(by: { abs($0.item - mid) < abs($1.item - mid) }),
          abs(clock.item - mid) < 0.25, clock.display < 9 || (trackTap && clock.display > 20)
        else { continue }
        for width in [400, 150] {
          let start = center - width / 2
          guard start >= 0, start + width <= cells.count else { continue }
          let window = Array(cells[start..<(start + width)])
          if !trackTap, let last = window.last, last.time + 0.020 >= 12 { continue }
          guard let first = window.first,
            zip(window, window.dropFirst()).allSatisfy({ abs($1.time - $0.time - 0.020) < 0.005 }),
            let match = reference.match(window)
          else { continue }
          let delta = milliseconds(clock.display - (match.time + mid - first.time))
          if clock.display < 9 { before.append(delta) } else { after.append(delta) }
          break
        }
      }
      return (before, after)
    }

    nonisolated private static func milliseconds(_ seconds: Double) -> Int {
      Int((seconds * 1000).rounded())
    }
  }
#endif
