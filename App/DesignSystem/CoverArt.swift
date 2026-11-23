import ImageIO
import SwiftUI
import UIKit

struct CoverArt: View {
  let data: Data?
  let demo: Bool
  let fallbackTitle: String?
  init(data: Data?, demo: Bool, fallbackTitle: String? = nil) {
    self.data = data
    self.demo = demo
    self.fallbackTitle = fallbackTitle
  }
  #if DEBUG
    struct RenderMeasurement {
      let runID: UUID
      var bodies = 0
      var images = 0
      var constructorMilliseconds = 0.0
    }
    private var measuresPlayerSurface = false
    func measuredPlayerArtwork() -> Self {
      var copy = self
      copy.measuresPlayerSurface = true
      return copy
    }
    @MainActor private static var renderMeasurement: RenderMeasurement?
    @MainActor static func beginMeasurement(_ runID: UUID) {
      renderMeasurement = RenderMeasurement(runID: runID)
    }
    @MainActor static func measurement(_ runID: UUID) -> RenderMeasurement? {
      renderMeasurement.flatMap { $0.runID == runID ? $0 : nil }
    }
    @MainActor static func endMeasurement(_ runID: UUID) {
      if renderMeasurement?.runID == runID { renderMeasurement = nil }
    }
    @MainActor private static func countBody(measured: Bool) {
      guard measured else { return }
      if let count = renderMeasurement?.bodies, count < 10_000 {
        renderMeasurement?.bodies = count + 1
      }
    }
  #endif
  @MainActor private func image(_ data: Data) -> UIImage? {
    #if DEBUG
      let run = measuresPlayerSurface ? Self.renderMeasurement?.runID : nil
      let start = run == nil ? 0 : ProcessInfo.processInfo.systemUptime
    #endif
    let image = UIImage(data: data)
    #if DEBUG
      if let run, Self.renderMeasurement?.runID == run,
        let count = Self.renderMeasurement?.images, count < 10_000
      {
        Self.renderMeasurement?.images = count + 1
        let elapsed = max(0, (ProcessInfo.processInfo.systemUptime - start) * 1_000)
        let prior = Self.renderMeasurement?.constructorMilliseconds ?? 0
        Self.renderMeasurement?.constructorMilliseconds = min(60_000, prior + elapsed)
      }
    #endif
    return image
  }
  var body: some View {
    #if DEBUG
      let _ = Self.countBody(measured: measuresPlayerSurface)
    #endif
    Rectangle().fill(.quaternary).aspectRatio(1, contentMode: .fit).overlay {
      GeometryReader { bounds in
        ZStack {
          if let data, let image = image(data) {
            Image(uiImage: image).resizable().scaledToFill().frame(
              width: bounds.size.width, height: bounds.size.height)
          } else if demo {
            GeometryReader { proxy in
              ZStack {
                Color(red: 0.14, green: 0.23, blue: 0.34)
                Circle().fill(Color(red: 0.88, green: 0.82, blue: 0.68)).frame(
                  width: proxy.size.width * 0.27
                ).offset(x: proxy.size.width * 0.15, y: -proxy.size.height * 0.16)
                Ellipse().fill(Color(red: 0.32, green: 0.46, blue: 0.53)).frame(
                  width: proxy.size.width * 1.8, height: proxy.size.height * 0.8
                ).offset(x: -proxy.size.width * 0.2, y: proxy.size.height * 0.3)
                Ellipse().fill(Color(red: 0.19, green: 0.33, blue: 0.40)).frame(
                  width: proxy.size.width * 1.8, height: proxy.size.height * 0.7
                ).offset(x: proxy.size.width * 0.3, y: proxy.size.height * 0.52)
              }
            }
          } else {
            Rectangle().fill(.quaternary)
            if let initial = fallbackTitle?.trimmingCharacters(in: .whitespacesAndNewlines).first {
              Text(String(initial)).font(.title.weight(.medium)).foregroundStyle(.secondary)
            } else {
              Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary)
            }
          }
        }.frame(width: bounds.size.width, height: bounds.size.height).clipped()
      }
    }.clipShape(.rect(cornerRadius: MusicUI.artworkRadius)).contentShape(.rect)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Album artwork")
      .accessibilityValue(data == nil ? "placeholder" : "loaded")
      .accessibilityIdentifier("cover-art")
      .accessibilityHidden(!exposeFixtureGeometry)
  }
  private var exposeFixtureGeometry: Bool {
    #if DEBUG
      ProcessInfo.processInfo.arguments.contains("--art-layout")
    #else
      false
    #endif
  }
}

extension CoverArt {
  nonisolated static func tone(from data: Data) async -> ArtworkTone? {
    await Task.detached(priority: .utility) {
      guard !Task.isCancelled,
        let source = CGImageSourceCreateWithData(
          data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 16,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary)
      else { return nil }
      var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
      let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard
          let context = CGContext(
            data: bytes.baseAddress, width: 16, height: 16,
            bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        return true
      }
      guard drawn, !Task.isCancelled else { return nil }
      var red = 0.0
      var green = 0.0
      var blue = 0.0
      var count = 0.0
      for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 32 {
        red += Double(pixels[index])
        green += Double(pixels[index + 1])
        blue += Double(pixels[index + 2])
        count += 255
      }
      guard count > 0 else { return nil }
      return ArtworkTone(red: red / count, green: green / count, blue: blue / count)
    }.value
  }
}
