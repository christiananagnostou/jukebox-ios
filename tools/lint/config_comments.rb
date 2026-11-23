require 'json'
require 'psych'
require 'ripper'

source = STDIN.read.force_encoding(Encoding::UTF_8)
lines = source.lines
def offsets(lines)
  lines.each_with_object([0]) { |line, sums| sums << sums.last + line }
end

def yaml_ranges(source, lines)
  positions = offsets(lines.map(&:length))
  protected_spans = []
  Psych.parse_stream(source).each do |node|
    next unless node.is_a?(Psych::Nodes::Scalar)
    block = [Psych::Nodes::Scalar::LITERAL, Psych::Nodes::Scalar::FOLDED].include?(node.style)
    start_pos = block ? positions.fetch(node.start_line + 1, source.length) : positions[node.start_line] + node.start_column
    end_pos = positions.fetch(node.end_line, source.length) + node.end_column
    protected_spans << (start_pos...end_pos)
  end
  found = []
  ends_at = 0
  source.scan(/(?<!\S)#/) do
    start_pos = Regexp.last_match.begin(0)
    next if start_pos < ends_at || protected_spans.any? { |span| span.cover?(start_pos) }
    ends_at = source.index(/[\r\n]/, start_pos) || source.length
    found << [source[0...start_pos].bytesize, source[0...ends_at].bytesize]
  end
  found
end

def ruby_ranges(source, lines)
  positions = offsets(lines.map(&:bytesize))
  found = []
  document = nil
  Ripper.lex(source).each do |(line, column), type, token, _|
    start_pos = positions[line - 1] + column
    case type
    when :on_comment
      found << [start_pos, start_pos + token.chomp.bytesize]
    when :on_embdoc_beg
      document = start_pos
    when :on_embdoc_end
      found << [document, start_pos + token.chomp.bytesize]
      document = nil
    end
  end
  found << [document, source.bytesize] if document
  found
end

puts JSON.generate(ARGV.fetch(0) == '.rb' ? ruby_ranges(source, lines) : yaml_ranges(source, lines))
