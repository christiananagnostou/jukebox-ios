#if DEBUG && AUDIO_CLOCK_ACCEPTANCE && canImport(MediaToolbox)
  import Foundation
  import AVFoundation
  import AudioToolbox
  import CoreMedia
  import MediaToolbox
  import Synchronization

  struct AudioClockPoint: Sendable, Equatable {
    let time: Double
    let level: Float
    let detail: Float
    let bands: SIMD8<Float>

    init(time: Double, level: Float, detail: Float, bands: SIMD8<Float> = .zero) {
      self.time = time
      self.level = level
      self.detail = detail
      self.bands = bands
    }
  }

  struct AudioClockBandAccumulator: Sendable {
    private let alpha = SIMD8<Double>(
      0.0510127138458861, 0.1226942309016543, 0.2695973089513544,
      0.5195502098007229, 0.7921204236492381, 0, 0, 0)
    private var first: SIMD8<Double> = .zero
    private var second: SIMD8<Double> = .zero
    private(set) var energies: SIMD8<Double> = .zero

    mutating func append(_ sample: Double) {
      first += alpha * (SIMD8<Double>(repeating: sample) - first)
      second += alpha * (first - second)
      let separated = SIMD8<Double>(
        second[0], second[1] - second[0], second[2] - second[1],
        second[3] - second[2], second[4] - second[3], sample - second[4], 0, 0)
      energies += separated * separated
    }

    mutating func resetCell() { energies = .zero }
    mutating func reset() { self = Self() }

    static func rms(_ energies: SIMD8<Double>, divisor: Double) -> SIMD8<Float> {
      SIMD8<Float>(
        Float(max(0, energies[0] / divisor).squareRoot()),
        Float(max(0, energies[1] / divisor).squareRoot()),
        Float(max(0, energies[2] / divisor).squareRoot()),
        Float(max(0, energies[3] / divisor).squareRoot()),
        Float(max(0, energies[4] / divisor).squareRoot()),
        Float(max(0, energies[5] / divisor).squareRoot()), 0, 0)
    }
  }

  @MainActor
  final class AudioClockTap {
    enum InstallationError: Error {
      case existingAudioMix
      case preferredFormatUnavailable
      case requiresNewMixedTapRuntime
      case creation(OSStatus)
    }

    private let state: AudioClockTapState
    private let tap: MTAudioProcessingTap
    private let mix: AVAudioMix
    private weak var item: AVPlayerItem?

    static func install(on item: AVPlayerItem) throws -> AudioClockTap {
      guard item.audioMix == nil else { throw InstallationError.existingAudioMix }
      guard #available(iOS 27.0, macOS 27.0, tvOS 27.0, visionOS 27.0, *) else {
        throw InstallationError.requiresNewMixedTapRuntime
      }
      guard
        let preferred = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
          channels: 1, interleaved: false)
      else { throw InstallationError.preferredFormatUnavailable }

      let state = AudioClockTapState()
      var callbacks = makeCallbacks(state)
      var tap: MTAudioProcessingTap?
      let status = MTAudioProcessingTapCreateWithPreferredFormat(
        kCFAllocatorDefault, &callbacks,
        MTAudioProcessingTapCreationFlags(kMTAudioProcessingTapCreationFlag_PostEffects),
        preferred.formatDescription, &tap)
      guard status == noErr, let tap else { throw InstallationError.creation(status) }
      let parameters = AVMutableAudioMixInputParameters()
      parameters.trackID = 0
      return attach(item: item, state: state, tap: tap, parameters: parameters)
    }

    static func install(on item: AVPlayerItem, track: AVAssetTrack) throws -> AudioClockTap {
      guard item.audioMix == nil else { throw InstallationError.existingAudioMix }
      let state = AudioClockTapState()
      var callbacks = makeCallbacks(state)
      var tap: MTAudioProcessingTap?
      let flags = MTAudioProcessingTapCreationFlags(kMTAudioProcessingTapCreationFlag_PostEffects)
      let status: OSStatus
      if #available(iOS 27.0, macOS 27.0, tvOS 27.0, visionOS 27.0, *) {
        guard
          let preferred = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
            channels: 1, interleaved: false)
        else { throw InstallationError.preferredFormatUnavailable }
        status = MTAudioProcessingTapCreateWithPreferredFormat(
          kCFAllocatorDefault, &callbacks, flags, preferred.formatDescription, &tap)
      } else {
        status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, flags, &tap)
      }
      guard status == noErr, let tap else { throw InstallationError.creation(status) }
      let parameters = AVMutableAudioMixInputParameters(track: track)
      return attach(item: item, state: state, tap: tap, parameters: parameters)
    }

    func drain() -> [AudioClockPoint] { state.drain() }

    var dropped: UInt64 { state.droppedCount.load(ordering: .relaxed) }
    var partial: UInt64 { state.partialCount.load(ordering: .relaxed) }
    var inputSampleRate: Int32 { state.inputRate.load(ordering: .relaxed) }
    var inputChannels: Int32 { state.inputChannels.load(ordering: .relaxed) }
    var conversionMode: Int32 { state.conversionMode.load(ordering: .relaxed) }
    var processCallbacks: UInt64 { state.callbackCount.load(ordering: .relaxed) }
    var formatStatus: Int32 { state.status.load(ordering: .relaxed) }
    var sourceStatus: Int32 { state.sourceStatus.load(ordering: .relaxed) }
    var discontinuities: UInt64 { state.discontinuityCount.load(ordering: .relaxed) }

    func invalidate() { state.active.store(false, ordering: .releasing) }

    deinit { state.active.store(false, ordering: .releasing) }

    private init(
      item: AVPlayerItem, state: AudioClockTapState,
      tap: MTAudioProcessingTap, mix: AVAudioMix
    ) {
      self.item = item
      self.state = state
      self.tap = tap
      self.mix = mix
    }

    private static func attach(
      item: AVPlayerItem, state: AudioClockTapState,
      tap: MTAudioProcessingTap,
      parameters: AVMutableAudioMixInputParameters
    ) -> AudioClockTap {
      parameters.audioTapProcessor = tap
      let mix = AVMutableAudioMix()
      mix.inputParameters = [parameters]
      let collector = AudioClockTap(item: item, state: state, tap: tap, mix: mix)
      item.audioMix = mix
      return collector
    }

    private static func makeCallbacks(_ state: AudioClockTapState) -> MTAudioProcessingTapCallbacks
    {
      MTAudioProcessingTapCallbacks(
        version: Int32(kMTAudioProcessingTapCallbacksVersion_0),
        clientInfo: Unmanaged.passUnretained(state).toOpaque(),
        init: { _, info, storage in
          guard let info else { return }
          _ = Unmanaged<AudioClockTapState>.fromOpaque(info).retain()
          storage.pointee = info
        },
        finalize: { tap in
          Unmanaged<AudioClockTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
        },
        prepare: { tap, _, format in
          audioClockState(tap).prepare(format.pointee)
        },
        unprepare: { tap in
          let state = audioClockState(tap)
          state.resetSequence()
          state.encoding = .unsupported
        },
        process: { tap, requested, _, buffers, framesOut, flagsOut in
          var sourceFlags: MTAudioProcessingTapFlags = 0
          var sourceRange = CMTimeRange.invalid
          var actual: CMItemCount = 0
          let result = MTAudioProcessingTapGetSourceAudio(
            tap, requested, buffers, &sourceFlags, &sourceRange, &actual)
          framesOut.pointee = actual
          flagsOut.pointee = sourceFlags
          let state = audioClockState(tap)
          state.callbackCount.wrappingAdd(1, ordering: .relaxed)
          guard result == noErr else {
            state.sourceStatus.store(result, ordering: .relaxed)
            state.drop(frames: actual > 0 ? actual : requested)
            return
          }
          guard state.active.load(ordering: .acquiring) else { return }
          guard
            state.processing.compareExchange(
              expected: false, desired: true, ordering: .acquiring
            ).exchanged
          else {
            state.status.store(6, ordering: .relaxed)
            state.drop(frames: actual)
            return
          }
          defer { state.processing.store(false, ordering: .releasing) }
          state.observe(frames: actual, flags: sourceFlags, range: sourceRange, buffers: buffers)
        })
    }
  }

  private final class AudioClockTapState: @unchecked Sendable {
    enum Encoding: Equatable { case unsupported, float32, float64, int16, int32 }
    static let capacity = 8192
    static let cellFrames = 480
    static let sampleRate = 24_000.0
    let active = Atomic<Bool>(true)
    let processing = Atomic<Bool>(false)
    let droppedCount = Atomic<UInt64>(0)
    let partialCount = Atomic<UInt64>(0)
    let inputRate = Atomic<Int32>(0)
    let inputChannels = Atomic<Int32>(0)
    let conversionMode = Atomic<Int32>(0)
    let callbackCount = Atomic<UInt64>(0)
    let discontinuityCount = Atomic<UInt64>(0)
    let status = Atomic<Int32>(0)
    let sourceStatus = Atomic<Int32>(0)
    private let writeIndex = Atomic<UInt64>(0)
    private let readIndex = Atomic<UInt64>(0)
    private let points: UnsafeMutablePointer<AudioClockPoint>

    var encoding: Encoding = .unsupported
    private var stride = 0
    private var sampleBytes = 0
    private var sawTimedBuffer = false
    private var sourceRate = 24_000.0
    private var channels = 1
    private var planar = false
    private var sourcePrevious: Double?
    private var sourcePreviousTime = 0.0
    private var gridStart = 0.0
    private var outputIndex: UInt64 = 0
    private var count = 0
    private var energy = 0.0
    private var differenceEnergy = 0.0
    private var previous: Double?
    private var cellStart = 0.0
    private var expectedStart: Double?
    private var invalidCell = false
    private var bandAccumulator = AudioClockBandAccumulator()

    init() {
      points = .allocate(capacity: Self.capacity)
      points.initialize(
        repeating: AudioClockPoint(time: 0, level: 0, detail: 0), count: Self.capacity)
    }

    deinit {
      points.deinitialize(count: Self.capacity)
      points.deallocate()
    }

    func prepare(_ format: AudioStreamBasicDescription) {
      resetSequence()
      encoding = .unsupported
      conversionMode.store(0, ordering: .relaxed)
      inputRate.store(0, ordering: .relaxed)
      inputChannels.store(0, ordering: .relaxed)
      status.store(2, ordering: .relaxed)
      guard format.mFormatID == kAudioFormatLinearPCM,
        format.mSampleRate.isFinite,
        format.mSampleRate >= 8_000, format.mSampleRate <= 192_000,
        format.mChannelsPerFrame == 1 || format.mChannelsPerFrame == 2,
        format.mFramesPerPacket == 1,
        (format.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0,
        (format.mFormatFlags & kAudioFormatFlagIsPacked) != 0,
        format.mBytesPerFrame > 0, format.mBytesPerFrame <= 16,
        format.mBytesPerPacket == format.mBytesPerFrame
      else { return }
      let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
      let isSigned = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
      switch (isFloat, isSigned, format.mBitsPerChannel) {
      case (true, false, 32):
        encoding = .float32
        sampleBytes = 4
      case (true, false, 64):
        encoding = .float64
        sampleBytes = 8
      case (false, true, 16):
        encoding = .int16
        sampleBytes = 2
      case (false, true, 32):
        encoding = .int32
        sampleBytes = 4
      default: return
      }
      sourceRate = format.mSampleRate
      channels = Int(format.mChannelsPerFrame)
      planar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
      stride = Int(format.mBytesPerFrame)
      guard stride == sampleBytes * (planar ? 1 : channels) else {
        encoding = .unsupported
        return
      }
      inputRate.store(Int32(sourceRate.rounded()), ordering: .relaxed)
      inputChannels.store(Int32(channels), ordering: .relaxed)
      let resampled = abs(sourceRate - Self.sampleRate) > 0.001
      conversionMode.store(
        channels == 1 ? (resampled ? 2 : 1) : (resampled ? 4 : 3), ordering: .relaxed)
      status.store(1, ordering: .relaxed)
    }

    func observe(
      frames: CMItemCount, flags: MTAudioProcessingTapFlags,
      range: CMTimeRange, buffers: UnsafeMutablePointer<AudioBufferList>
    ) {
      guard frames > 0 else {
        if (flags & MTAudioProcessingTapFlags(kMTAudioProcessingTapFlag_EndOfStream)) != 0 {
          resetSequence()
        }
        return
      }
      guard encoding != .unsupported else {
        drop(frames: frames)
        return
      }
      let start = CMTimeGetSeconds(range.start)
      let duration = CMTimeGetSeconds(range.duration)
      if !start.isFinite, !duration.isFinite, !sawTimedBuffer { return }
      let expectedDuration = Double(frames) / sourceRate
      guard start.isFinite, abs(start) <= 1_000_000,
        duration.isFinite, duration > 0,
        abs(duration - expectedDuration) <= max(0.025, min(0.10, 0.25 * expectedDuration))
      else {
        status.store(3, ordering: .relaxed)
        resetSequence()
        drop(frames: frames)
        return
      }
      let list = UnsafeMutableAudioBufferListPointer(buffers)
      guard list.count == (planar ? channels : 1),
        list[0].mNumberChannels == (planar ? 1 : UInt32(channels)),
        let firstData = list[0].mData,
        frames <= Int(list[0].mDataByteSize) / stride
      else {
        rejectBuffers(frames)
        return
      }
      var secondData: UnsafeRawPointer? = nil
      if planar && channels == 2 {
        guard list[1].mNumberChannels == 1, let data = list[1].mData,
          frames <= Int(list[1].mDataByteSize) / stride
        else {
          rejectBuffers(frames)
          return
        }
        secondData = UnsafeRawPointer(data)
      }
      let isNewStream =
        (flags & MTAudioProcessingTapFlags(kMTAudioProcessingTapFlag_StartOfStream)) != 0
      let gap = expectedStart.map { abs(start - $0) > 0.030 } ?? false
      if isNewStream || gap {
        discontinuityCount.wrappingAdd(1, ordering: .relaxed)
        resetSequence()
      }
      let sampleStart = expectedStart ?? start
      sawTimedBuffer = true
      let first = UnsafeRawPointer(firstData)
      for frame in 0..<frames {
        let offset = frame * stride
        let left = sample(first, byteOffset: offset)
        var mono = left
        if channels == 2 {
          let right = sample(secondData ?? first, byteOffset: offset + (planar ? 0 : sampleBytes))
          mono =
            left.isFinite && right.isFinite && abs(left) <= 16 && abs(right) <= 16
            ? 0.5 * (left + right) : .nan
        }
        if !mono.isFinite || abs(mono) > 16 { status.store(5, ordering: .relaxed) }
        appendInput(mono, at: sampleStart + Double(frame) / sourceRate)
      }
      expectedStart = sampleStart + expectedDuration
      if (flags & MTAudioProcessingTapFlags(kMTAudioProcessingTapFlag_EndOfStream)) != 0 {
        resetSequence()
      }
    }

    private func rejectBuffers(_ frames: CMItemCount) {
      status.store(4, ordering: .relaxed)
      resetSequence()
      drop(frames: frames)
    }

    private func appendInput(_ value: Double, at time: Double) {
      if let old = sourcePrevious {
        guard time > sourcePreviousTime else {
          discontinuityCount.wrappingAdd(1, ordering: .relaxed)
          resetSequence()
          appendFirst(value, at: time)
          return
        }
        var nextTime = gridStart + Double(outputIndex) / Self.sampleRate
        var emitted = 0
        while nextTime <= time + 1e-10 && emitted < 4 {
          let fraction = min(
            1.0, max(0.0, (nextTime - sourcePreviousTime) / (time - sourcePreviousTime)))
          let interpolated = fraction >= 1 ? value : old + fraction * (value - old)
          appendOutput(interpolated, at: nextTime)
          outputIndex &+= 1
          emitted += 1
          nextTime = gridStart + Double(outputIndex) / Self.sampleRate
        }
        sourcePrevious = value
        sourcePreviousTime = time
      } else {
        appendFirst(value, at: time)
      }
    }

    private func appendFirst(_ value: Double, at time: Double) {
      gridStart = time
      outputIndex = 1
      sourcePrevious = value
      sourcePreviousTime = time
      appendOutput(value, at: time)
    }

    private func appendOutput(_ value: Double, at time: Double) {
      if count == 0 { cellStart = time }
      if value.isFinite && abs(value) <= 16 {
        let difference = previous.map { value - $0 } ?? 0
        energy += value * value
        differenceEnergy += difference * difference
        previous = value
        bandAccumulator.append(value)
      } else {
        invalidCell = true
        previous = nil
        bandAccumulator.append(0)
        status.store(5, ordering: .relaxed)
      }
      count += 1
      if count == Self.cellFrames {
        if invalidCell {
          droppedCount.wrappingAdd(1, ordering: .relaxed)
        } else {
          enqueue(
            AudioClockPoint(
              time: cellStart,
              level: Float((energy / Double(Self.cellFrames)).squareRoot()),
              detail: Float((differenceEnergy / Double(Self.cellFrames)).squareRoot()),
              bands: AudioClockBandAccumulator.rms(
                bandAccumulator.energies, divisor: Double(Self.cellFrames))))
        }
        count = 0
        energy = 0
        differenceEnergy = 0
        invalidCell = false
        bandAccumulator.resetCell()
      }
    }

    private func sample(_ raw: UnsafeRawPointer, byteOffset: Int) -> Double {
      switch encoding {
      case .float32: return Double(raw.loadUnaligned(fromByteOffset: byteOffset, as: Float.self))
      case .float64: return raw.loadUnaligned(fromByteOffset: byteOffset, as: Double.self)
      case .int16:
        return Double(raw.loadUnaligned(fromByteOffset: byteOffset, as: Int16.self)) / 32_768
      case .int32:
        return Double(raw.loadUnaligned(fromByteOffset: byteOffset, as: Int32.self)) / 2_147_483_648
      case .unsupported: return .nan
      }
    }

    func resetSequence() {
      if count > 0 { partialCount.wrappingAdd(1, ordering: .relaxed) }
      count = 0
      energy = 0
      differenceEnergy = 0
      previous = nil
      expectedStart = nil
      invalidCell = false
      bandAccumulator.reset()
      sourcePrevious = nil
      sourcePreviousTime = 0
      gridStart = 0
      outputIndex = 0
    }

    func drop(frames: CMItemCount) {
      let lowerBoundFramesPerCell = 160
      let cells =
        frames > 0
        ? UInt64(frames / lowerBoundFramesPerCell + (frames % lowerBoundFramesPerCell == 0 ? 0 : 1))
        : 1
      droppedCount.wrappingAdd(cells, ordering: .relaxed)
    }

    private func enqueue(_ point: AudioClockPoint) {
      let write = writeIndex.load(ordering: .relaxed)
      let read = readIndex.load(ordering: .acquiring)
      guard write &- read < UInt64(Self.capacity) else {
        droppedCount.wrappingAdd(1, ordering: .relaxed)
        return
      }
      points[Int(write % UInt64(Self.capacity))] = point
      writeIndex.store(write &+ 1, ordering: .releasing)
    }

    func drain() -> [AudioClockPoint] {
      let read = readIndex.load(ordering: .relaxed)
      let write = writeIndex.load(ordering: .acquiring)
      let available = min(write &- read, UInt64(Self.capacity))
      var result: [AudioClockPoint] = []
      result.reserveCapacity(Int(available))
      for offset in 0..<available {
        result.append(points[Int((read &+ offset) % UInt64(Self.capacity))])
      }
      readIndex.store(read &+ available, ordering: .releasing)
      return result
    }
  }

  private func audioClockState(_ tap: MTAudioProcessingTap) -> AudioClockTapState {
    Unmanaged<AudioClockTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
      .takeUnretainedValue()
  }
#endif
