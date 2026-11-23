#!/usr/bin/env python3
import argparse
import hashlib
import difflib
import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = 'Jukebox.xcodeproj/project.pbxproj'

def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def q(value):
    return json.dumps(str(value))

def add_references(text, names):
    for name in names:
        asset = name == 'App/Assets.xcassets'
        if not asset: source_name(name)
        if not asset and (not name.endswith('.swift') or not name.startswith(('App/', 'Sources/JukeboxCore/'))):
            raise ValueError('Only authored native Swift source or the app asset catalog is supported')
        existing = source_objects(text).get(name) if not asset else None
        if existing:
            builds = [body for _, body, _ in project_objects(text).values()
                      if scalar(body, 'isa') == 'PBXBuildFile'
                      and scalar(body, 'fileRef') == existing[0]]
            if len(builds) != 1:
                raise ValueError('Partial reference requires manual repair')
            continue
        fid, bid = ident(name), ident(name + '-build')
        if fid in text:
            if not asset or bid not in text:
                raise ValueError('Reference identity collision requires manual repair')
            continue
        def insert_list(text, owner, field, value):
            pattern = r'(' + ident(owner) + r'(?:\s*/\*[^*]*\*/)?\s*=\s*\{[^}]*?\b' + field + r'\s*=\s*\()'
            result, count = re.subn(pattern, lambda m: m[1] + '\n\t\t\t\t' + value + ',', text, flags=re.S)
            if count != 1:
                raise ValueError('Expected source owner is missing or ambiguous; project was not written')
            return result
        updated = insert_list(text, 'group', 'children', fid)
        updated = insert_list(updated, 'resources' if asset else 'sources', 'files', bid)
        kind = 'folder.assetcatalog' if asset else 'sourcecode.swift'
        definitions = f'\n{fid} = {{ isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(name)}; sourceTree = "<group>"; }};\n{bid} = {{ isa = PBXBuildFile; fileRef = {fid}; }};'
        updated, count = re.subn(r'(\bobjects\s*=\s*\{)', lambda m: m[1] + definitions, updated, count=1)
        if count != 1:
            raise ValueError('Project objects are missing; project was not written')
        text = updated
    if 'App/Assets.xcassets' in names:
        for owner in ['target-Debug', 'target-Release']:
            pattern = r'(' + ident(owner) + r'(?:\s*/\*[^*]*\*/)?\s*=\s*\{[^}]*?\bbuildSettings\s*=\s*\{)([^}]*)(})'
            def setting(match):
                existing = re.findall(r'\bASSETCATALOG_COMPILER_APPICON_NAME\s*=\s*([^;]+);', match[2])
                if existing:
                    if existing != ['AppIcon']:
                        raise ValueError('Existing app icon setting requires explicit review')
                    return match[0]
                return match[1] + '\n\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;' + match[2] + match[3]
            text, count = re.subn(pattern, setting, text, flags=re.S)
            if count != 1:
                raise ValueError('Expected app configuration is missing or ambiguous')
    return text

def source_name(name):
    path = Path(name)
    if (path.is_absolute() or '..' in path.parts or str(path) != name
            or not name.endswith('.swift')
            or not name.startswith(('App/', 'Sources/JukeboxCore/'))):
        raise ValueError('Only canonical authored Swift source paths are supported')
    return name


def without_comments(text):
    return re.sub(r'"(?:[^"\\]|\\.)*"|/\*.*?\*/|//[^\n]*',
                  lambda m: m[0] if m[0].startswith('"') else ' ', text, flags=re.S)


def project_objects(text):
    result = {}
    pattern = r'\b([A-F0-9]{24})(?:\s*/\*[^*]*\*/)?\s*=\s*\{'
    for match in re.finditer(pattern, text):
        start, depth, cursor = match.end(), 1, match.end()
        quoted, comment = False, False
        while cursor < len(text) and depth:
            pair = text[cursor:cursor + 2]
            char = text[cursor]
            if comment:
                if pair == '*/': comment = False; cursor += 2; continue
            elif quoted:
                if char == '\\': cursor += 2; continue
                if char == '"': quoted = False
            elif pair == '/*': comment = True; cursor += 2; continue
            elif char == '"': quoted = True
            elif char == '{': depth += 1
            elif char == '}': depth -= 1
            cursor += 1
        if depth: raise ValueError('Unterminated project object')
        body = text[start:cursor - 1]
        if scalar(body, 'isa') is None: continue
        identity = match[1]
        if identity in result: raise ValueError('Duplicate project object identity')
        result[identity] = (identity, body, text[match.start():cursor])
    return result


def scalar(body, field):
    value = re.search(r'\b' + field + r'\s*=\s*("(?:[^"\\]|\\.)*"|[^;{}]+);', without_comments(body))
    if not value: return None
    raw = value[1].strip()
    return json.loads(raw) if raw.startswith('"') else raw


def identifiers(body, field):
    value = re.search(r'\b' + field + r'\s*=\s*\(([^()]*)\)\s*;', without_comments(body))
    if not value: raise ValueError('Missing project reference list: ' + field)
    values = [item.strip() for item in value[1].split(',') if item.strip()]
    if any(not re.fullmatch(r'[A-F0-9]{24}', item) for item in values):
        raise ValueError('Unresolved project reference list')
    if len(values) != len(set(values)): raise ValueError('Duplicate project membership')
    return values


def source_objects(text):
    result = {}
    for identity, body, definition in project_objects(text).values():
        if scalar(body, 'isa') != 'PBXFileReference': continue
        name = scalar(body, 'path')
        if name and name.startswith(('App/', 'Sources/JukeboxCore/')) and name.endswith('.swift'):
            source_name(name)
            if name in result: raise ValueError('Duplicate authored source reference')
            field = re.search(r'\bpath\s*=\s*("(?:[^"\\]|\\.)*"|[^;]+);', body)
            result[name] = (identity, definition, field[0])
    return result


def source_membership(text):
    objects = project_objects(text)
    root = scalar(text, 'rootObject')
    if root not in objects or scalar(objects[root][1], 'isa') != 'PBXProject':
        raise ValueError('Missing exact root project')
    project = objects[root][1]
    targets = identifiers(project, 'targets')
    if any(target not in objects for target in targets): raise ValueError('Unresolved project target')
    app = [objects[target][1] for target in targets
           if scalar(objects[target][1], 'isa') == 'PBXNativeTarget'
           and scalar(objects[target][1], 'name') == 'Jukebox'
           and scalar(objects[target][1], 'productType') == 'com.apple.product-type.application']
    if len(app) != 1: raise ValueError('Missing or ambiguous Jukebox app target')
    phases = identifiers(app[0], 'buildPhases')
    if any(phase not in objects for phase in phases): raise ValueError('Unresolved target phase')
    sources = [objects[phase][1] for phase in phases
               if scalar(objects[phase][1], 'isa') == 'PBXSourcesBuildPhase']
    if len(sources) != 1: raise ValueError('Missing or ambiguous app source phase')
    result = {}
    for build in identifiers(sources[0], 'files'):
        if build not in objects or scalar(objects[build][1], 'isa') != 'PBXBuildFile':
            raise ValueError('Unresolved source build reference')
        fid = scalar(objects[build][1], 'fileRef')
        if fid not in objects or scalar(objects[fid][1], 'isa') != 'PBXFileReference':
            raise ValueError('Unresolved source file reference')
        body = objects[fid][1]
        name = source_name(scalar(body, 'path') or '')
        if scalar(body, 'sourceTree') not in ['<group>', 'SOURCE_ROOT']:
            raise ValueError('Source must remain project-relative')
        if name in result: raise ValueError('Source compiled more than once')
        result[name] = (fid, build)
    if set(result) != set(source_objects(text)):
        raise ValueError('Orphan or uncompiled authored source reference')
    return result


def move_references(text, moves):
    pairs = [(source_name(old), source_name(new)) for old, new in moves]
    old_names, new_names = [x[0] for x in pairs], [x[1] for x in pairs]
    if (len(set(old_names)) != len(pairs) or len(set(new_names)) != len(pairs)
            or set(old_names) & set(new_names)):
        raise ValueError('Moves must have distinct non-overlapping source and destination paths')
    membership = source_membership(text) if pairs else {}
    for old, new in pairs:
        objects = source_objects(text)
        if old not in membership or new in objects:
            raise ValueError('Move requires one compiled source and an unused destination')
        _, definition, path_field = objects[old]
        text = text.replace(definition, definition.replace(path_field, 'path = ' + q(new) + ';'), 1)
        text = text.replace('/* ' + old + ' */', '/* ' + new + ' */')
        text = text.replace('/* ' + old + ' in Sources */', '/* ' + new + ' in Sources */')
    if pairs: source_membership(text)
    return text


def safe_path(root, name, *, missing=False):
    path = Path(name)
    if path.is_absolute() or '..' in path.parts or str(path) != name:
        raise ValueError('Source path escapes the repository')
    current = Path(root)
    if current.is_symlink(): raise ValueError('Symlink repository root')
    for part in path.parts:
        current = current / part
        if current.is_symlink(): raise ValueError('Symlink source path or ancestry')
    if not missing and not current.exists(): raise ValueError('Source does not exist')
    return current


def authored_sources(root):
    result = set()
    for folder in ['App', 'Sources/JukeboxCore']:
        start = safe_path(root, folder, missing=True)
        if not start.exists(): continue
        for directory, folders, files in os.walk(start, followlinks=False):
            for child in folders:
                safe_path(root, str((Path(directory)/child).relative_to(root)))
            for name in files:
                if name.endswith('.swift'):
                    path = safe_path(root, str((Path(directory)/name).relative_to(root)))
                    if not path.is_file(): raise ValueError('Source is not a regular file')
                    result.add(str(path.relative_to(root)))
    return result


def validate_membership(root, text):
    expected, membership = authored_sources(root), source_membership(text)
    if set(membership) != expected:
        raise ValueError('Authored source membership mismatch: missing=' + str(sorted(expected - set(membership)))
                         + ', stale=' + str(sorted(set(membership) - expected)))
    return len(expected)


def main(arguments=None):
    parser = argparse.ArgumentParser(description='Owned source-reference edits and parity checks. Never regenerate project/settings.')
    parser.add_argument('--index-patch', type=Path, help='Write only the owned reference diff against HEAD, for selective staging')
    parser.add_argument('--move', action='append', default=[], metavar='OLD=NEW', help='Update one already-moved source reference; does not move files')
    parser.add_argument('--check', action='store_true', help='Read-only source-membership parity check')
    parser.add_argument('names', nargs='*')
    args = parser.parse_args(arguments)
    path = ROOT/PROJECT
    safe_path(ROOT, PROJECT)
    before = path.read_text()
    if args.check:
        if args.names or args.move or args.index_patch:
            parser.error('--check cannot modify references')
        print('Authored source membership: ' + str(validate_membership(ROOT, before)) + ' files, each compiled once')
        return
    moves = []
    for value in args.move:
        if value.count('=') != 1:
            parser.error('--move requires OLD=NEW')
        old, new = value.split('=')
        source_name(old); source_name(new)
        old_path = safe_path(ROOT, old, missing=True)
        new_path = safe_path(ROOT, new)
        if old_path.exists() or not new_path.is_file():
            raise ValueError('Move files first; destination must be one authored regular source')
        moves.append((old, new))
    if not args.names and not moves:
        parser.error('Provide source paths, --move, or --check')
    for name in args.names:
        if name != 'App/Assets.xcassets': source_name(name)
        candidate = safe_path(ROOT, name)
        if not (candidate.is_dir() if name == 'App/Assets.xcassets' else candidate.is_file()):
            raise ValueError('Source does not exist')
    updated = add_references(move_references(before, moves), args.names)
    validate_membership(ROOT, updated)
    if path.read_text() != before:
        raise RuntimeError('Project changed concurrently; refusing to overwrite')
    if args.index_patch:
        committed = subprocess.check_output(['git','show','HEAD:'+PROJECT], cwd=ROOT, text=True)
        owned = add_references(move_references(committed, moves), args.names)
        patch = ''.join(difflib.unified_diff(committed.splitlines(True), owned.splitlines(True), fromfile='a/'+PROJECT, tofile='b/'+PROJECT))
        args.index_patch.write_text(patch)
    path.write_text(updated)


if __name__ == '__main__':
    main()
