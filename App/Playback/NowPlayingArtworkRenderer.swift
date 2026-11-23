import Foundation
import MediaPlayer
import UIKit

enum NowPlayingArtworkRenderer {
  nonisolated static func makeArtwork(image: UIImage) -> MPMediaItemArtwork {
    let render: @Sendable (CGSize) -> UIImage = { requested in
      let size = CGSize(
        width: max(1, min(image.size.width, requested.width)),
        height: max(1, min(image.size.height, requested.height)))
      let scale = min(size.width / image.size.width, size.height / image.size.height)
      let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(
          in: CGRect(
            x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2,
            width: drawSize.width, height: drawSize.height))
      }
    }
    return MPMediaItemArtwork(boundsSize: image.size, requestHandler: render)
  }
}
