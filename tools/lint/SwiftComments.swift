import Foundation
import SwiftParser
import SwiftSyntax

func commentRanges(in source: String) -> [[Int]] {
  var ranges: [[Int]] = []
  func collect(_ trivia: Trivia, at position: AbsolutePosition) {
    var offset = position.utf8Offset
    for piece in trivia {
      let end = offset + piece.sourceLength.utf8Length
      switch piece {
      case .lineComment, .docLineComment, .blockComment, .docBlockComment:
        ranges.append([offset, end])
      default: break
      }
      offset = end
    }
  }
  for token in Parser.parse(source: source).tokens(viewMode: .sourceAccurate) {
    collect(token.leadingTrivia, at: token.position)
    collect(token.trailingTrivia, at: token.endPositionBeforeTrailingTrivia)
  }
  return ranges
}

let input = FileHandle.standardInput.readDataToEndOfFile()
let sources = try JSONDecoder().decode([String].self, from: input)
try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(sources.map(commentRanges)))
