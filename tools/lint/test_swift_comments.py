import unittest

from tools.comments import inventory


class SwiftCommentTests(unittest.TestCase):
    def test_swift_parser_distinguishes_trivia_from_strings_regex_and_compiler_syntax(self):
        key = ('', 'example.swift')
        src = r'''#if DEBUG
let url = "https://example.invalid/*plain*/"
let raw = #"""
// data
/* data */
"""#
let pattern = #/https?://[^/]+/#
let text = "é \(1 /* expression */ + 2)" // trailing
/// Information.
/* outer /* nested */ end */
#endif
'''
        self.assertEqual(inventory({key: src.encode()})[key], [
            (8, '/* expression */'), (8, '// trailing'), (9, '/// Information.'),
            (10, '/* outer /* nested */ end */')])
