import argparse
import ast
import collections
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import tokenize
from xml.parsers import expat

from tools.support.paths import ROOT, WORK


def git(*args, root=ROOT):
    return subprocess.check_output(['git', '-C', str(root), *args])


def paths(*args, root=ROOT):
    return {os.fsdecode(name) for name in git(*args, root=root).split(b'\0') if name}


def supported(name):
    return Path(name).suffix in {'.swift', '.py', '.pbxproj', '.plist', '.xcscheme', '.yml', '.yaml', '.rb'} or Path(name).name == '.gitignore'


def python_ranges(source):
    lines = source.splitlines(keepends=True)
    offsets = [0]
    for line in lines:
        offsets.append(offsets[-1] + len(line.encode()))
    for token in tokenize.generate_tokens(io.StringIO(source).readline):
        if token.type == tokenize.COMMENT:
            line, column = token.start
            start = offsets[line - 1] + len(lines[line - 1][:column].encode())
            yield start, start + len(token.string.encode())
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            if ast.get_docstring(node, clean=False) is not None:
                doc = node.body[0]
                yield offsets[doc.lineno - 1] + doc.col_offset, offsets[doc.end_lineno - 1] + doc.end_col_offset


def swift_ranges(sources):
    compiler = Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip())
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    host = compiler.parents[1] / 'lib/swift/host'
    WORK.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='comment-lint-', dir=WORK) as temp:
        binary = Path(temp) / 'swift-comments'
        subprocess.run([str(compiler), '-sdk', sdk, '-j1', '-num-threads', '1', '-whole-module-optimization',
                        '-I', str(host), '-L', str(host), '-Xlinker', '-rpath', '-Xlinker', str(host),
                        str(ROOT / 'tools/lint/SwiftComments.swift'), '-o', str(binary)], check=True)
        output = subprocess.check_output([str(binary)], input=json.dumps(sources).encode())
    return json.loads(output)


OPENSTEP_TOKENS = re.compile(rb'"(?:\\.|[^"\\])*"|/\*[\s\S]*?\*/|//[^\r\n]*')


def other_ranges(name, data):
    if not data or (name.endswith('.plist') and data.startswith(b'bplist00')):
        return ()
    if name.endswith(('.yaml', '.yml', '.rb')):
        if b'#' not in data and not (name.endswith('.rb') and b'=begin' in data):
            return ()
        return json.loads(subprocess.check_output(
            ['ruby', str(ROOT / 'tools/lint/config_comments.rb'), Path(name).suffix], input=data))
    if name.endswith('.py'):
        return python_ranges(data.decode())
    if name.endswith('.pbxproj'):
        return (m.span() for m in OPENSTEP_TOKENS.finditer(data) if m[0].startswith(b'/'))
    if Path(name).name == '.gitignore':
        return (m.span() for m in re.finditer(rb'^#[^\r\n]*', data, re.M))
    found = []
    parser = expat.ParserCreate()
    def comment(_):
        start = parser.CurrentByteIndex
        found.append((start, data.index(b'-->', start) + 3))
    parser.CommentHandler = comment
    parser.Parse(data, True)
    return found


def directive(name, start, text):
    if start:
        return False
    if name == 'Package.swift':
        return re.fullmatch(r'// swift-tools-version:\s*\d+\.\d+(?:\.\d+)?[ \t]*', text) is not None
    if name.endswith('.pbxproj'):
        return text == '// !$*UTF8*$!'
    return name.endswith('.py') and text in ('#!/usr/bin/env python3', '#!/usr/bin/python3')


def inventory(blobs):
    swift = [key for key, data in blobs.items()
             if key[1].endswith('.swift') and (b'//' in data or b'/*' in data)]
    parsed = dict(zip(swift, swift_ranges([blobs[k].decode() for k in swift]))) if swift else {}
    result = {}
    for key, data in blobs.items():
        name = key[1]
        ranges = parsed.get(key, ()) if name.endswith('.swift') else other_ranges(name, data)
        rows = []
        for start, end in sorted(ranges):
            text = data[start:end].decode()
            if not directive(name, start, text):
                rows.append((data.count(b'\n', 0, start) + 1, text))
        result[key] = rows
    return result


def added(rows, baseline):
    remaining = collections.Counter(text for _, text in baseline)
    for line, text in rows:
        if remaining[text]:
            remaining[text] -= 1
        else:
            yield line, text


def work_blob(root, name):
    path = root / name
    if path.is_symlink():
        raise ValueError(f'{name}: linked source cannot be checked')
    return path.read_bytes() if path.exists() else b''


def check(bases, root=ROOT):
    untracked = paths('ls-files', '--others', '--exclude-standard', '-z', root=root)
    blobs = {}
    comparisons = []
    for base in dict.fromkeys(bases):
        tracked = paths('ls-tree', '-r', '--name-only', '-z', base, root=root)
        changed = paths('diff', '--no-renames', '--name-only', '-z', base, '--', root=root)
        for name in sorted(changed | untracked):
            if not supported(name):
                continue
            current = ('', name)
            original = (base, name)
            if current not in blobs:
                blobs[current] = work_blob(root, name)
            blobs[original] = git('show', base + ':' + name, root=root) if name in tracked else b''
            comparisons.append((current, original))
    scanned = inventory(blobs)
    findings = set()
    for current, original in comparisons:
        for line, text in added(scanned[current], scanned[original]):
            findings.add((current[1], line, text))
    for name, line, text in sorted(findings):
        print(f'{name}:{line}: new comment: {text.splitlines()[0]}')
    return bool(findings)


def default_base(root=ROOT):
    branch = subprocess.run(['git', '-C', str(root), 'merge-base', 'HEAD', 'origin/main'],
                            capture_output=True, text=True)
    return branch.stdout.strip() if branch.returncode == 0 else 'HEAD'


def main(arguments=None):
    parser = argparse.ArgumentParser(description='Inventory comments or reject additions to the reviewed source.')
    parser.add_argument('action', choices=['check', 'list'], nargs='?', default='check')
    parser.add_argument('--base', help='Reviewed Git commit used for the ratchet')
    args = parser.parse_args(arguments)
    if args.action == 'list':
        if args.base:
            ref = git('rev-parse', '--verify', '--end-of-options', args.base + '^{commit}').decode().strip()
            names = paths('ls-tree', '-r', '--name-only', '-z', ref)
            blobs = {(ref, name): git('show', ref + ':' + name) for name in sorted(names) if supported(name)}
        else:
            names = paths('ls-files', '--cached', '--others', '--exclude-standard', '-z')
            blobs = {('', name): work_blob(ROOT, name) for name in sorted(names) if supported(name)}
        for (_, name), rows in inventory(blobs).items():
            for line, text in rows:
                print(json.dumps({'path': name, 'line': line, 'text': text}, ensure_ascii=False))
        return 0
    base = git('rev-parse', '--verify', '--end-of-options', (args.base or default_base()) + '^{commit}').decode().strip()
    return int(check([base, git('rev-parse', 'HEAD').decode().strip()]))


if __name__ == '__main__':
    sys.exit(main())
