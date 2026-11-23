from contextlib import redirect_stdout
import io
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest

from tools import comments


class CommentTests(unittest.TestCase):
    def test_python_comments_and_docstrings_preserve_data_and_unicode_locations(self):
        source = ('#!/usr/bin/env python3\n"""module\ndocs"""\n'
                  'def demo():\n    """function docs"""\n'
                  '    return "é #not a comment"  # inline\n'
                  'payload = """# literal\n// literal"""\n')
        key = ('', 'demo.py')
        self.assertEqual(comments.inventory({key: source.encode()})[key], [
            (2, '"""module\ndocs"""'), (5, '"""function docs"""'), (6, '# inline')])

    def test_xml_and_xcode_strings_are_data_and_directives_are_exact(self):
        xml = ('<?xml version="1.0"?><root label="&lt;!--x--&gt;">'
               '<![CDATA[<!--text-->]]><!--one\ntwo--></root>').encode()
        project = b'// !$*UTF8*$!\n{ name = "/* data */ // data"; /* actual */ }'
        blobs = {('', 'a.xcscheme'): xml, ('', 'project.pbxproj'): project,
                 ('', '.gitignore'): b'\\#literal\n# explanation\n'}
        result = comments.inventory(blobs)
        self.assertEqual(result[('', 'a.xcscheme')], [(1, '<!--one\ntwo-->')])
        self.assertEqual(result[('', 'project.pbxproj')], [(2, '/* actual */')])
        self.assertEqual(result[('', '.gitignore')], [(2, '# explanation')])
        self.assertTrue(comments.directive('Package.swift', 0, '// swift-tools-version: 6.0'))
        self.assertFalse(comments.directive('Package.swift', 0, '// swift-tools-version: 6.0 explanation'))
        self.assertFalse(comments.directive('Other.swift', 0, '// swift-tools-version: 6.0'))
        self.assertFalse(comments.directive('Package.swift', 5, '// swift-tools-version: 6.0'))

    def test_yaml_and_ruby_preserve_hashes_in_scalars_and_interpolation(self):
        yaml = ('title: "é # data" # visible\ncontent: | # header\n'
                '  # literal block\nstep: path#fragment\n# final\n')
        ruby = 'title = "é #{1 + 2} # data" # genuine\n=begin\n\nold prose\n=end\n'
        entries = comments.inventory({('', 'test.yml'): yaml.encode(), ('', 'test.rb'): ruby.encode()})
        self.assertEqual(entries[('', 'test.yml')], [(1, '# visible'), (2, '# header'), (5, '# final')])
        self.assertEqual(entries[('', 'test.rb')], [
            (1, '# genuine'), (2, '=begin\n\nold prose\n=end')])

    def test_ratchet_checks_content_multiplicity_files_and_paid_down_debt(self):
        with TemporaryDirectory() as directory, redirect_stdout(io.StringIO()):
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
            git('init', '-q')
            git('config', 'user.name', 'Test')
            git('config', 'user.email', 'fixture@example.invalid')
            source = root / 'source.py'
            source.write_text('# one\n# two\nvalue = 7\n')
            git('add', 'source.py')
            git('commit', '-qm', 'baseline')
            original = git('rev-parse', 'HEAD')
            source.write_text('value = 7\n# two\n')
            self.assertFalse(comments.check([original], root))
            source.write_text('# different\n# two\nvalue = 7\n')
            self.assertTrue(comments.check([original], root))
            source.write_text('# two\n# two\nvalue = 7\n')
            self.assertTrue(comments.check([original], root))
            source.write_text('# two\nvalue = 7\n')
            git('add', 'source.py')
            git('commit', '-qm', 'pay down')
            source.write_text('# two\n# one\nvalue = 7\n')
            self.assertTrue(comments.check([original, 'HEAD'], root))
            source.unlink()
            (root / 'new.py').write_text('# two\n')
            self.assertTrue(comments.check([original], root))
            (root / 'new.py').write_text('value = "# two"\n')
            self.assertFalse(comments.check([original], root))
            (root / 'new.py').write_text('# newly committed\n')
            git('add', '-A')
            git('commit', '-qm', 'unreviewed comment')
            self.assertTrue(comments.check([original, 'HEAD'], root))
