from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / '.tmp/native-dev'
BUNDLE = 'dev.jukebox.ios'


def fixture_work(parent, run_id):
    import json
    import os
    import uuid
    parent = Path(parent)
    parent.mkdir(parents=True, exist_ok=True)
    run_id = str(uuid.UUID(run_id))
    work = parent / run_id
    work.mkdir(mode=0o700, exist_ok=False)
    descriptor = os.open(work / 'checkpoint.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump({'version': 1, 'run_id': run_id, 'state': 'active'}, stream)
    return work


def finish_fixture_work(work, run_id, report, *, cleanup_failed=False, resources=None):
    import json
    import os
    import shutil
    import stat
    import uuid
    canonical = str(uuid.UUID(run_id))
    work = Path(work)
    if work.name != canonical or work.is_symlink():
        raise RuntimeError('Unknown fixture workspace ownership')
    descriptor = os.open(work / 'checkpoint.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor) as stream:
        attributes = os.fstat(stream.fileno())
        if not stat.S_ISREG(attributes.st_mode) or not 0 < attributes.st_size <= 4096:
            raise RuntimeError('Unknown fixture checkpoint')
        checkpoint = json.loads(stream.read(4097))
    if checkpoint != {'version': 1, 'run_id': canonical, 'state': 'active'}:
        raise RuntimeError('Unknown fixture checkpoint')
    if cleanup_failed:
        report['cleanup_failed'] = True
        report['passed'] = False
        checkpoint.update(state='cleanup_uncertain', resources=resources or {})
        (work / 'checkpoint.json').write_text(json.dumps(checkpoint))
    else:
        shutil.rmtree(work)
    pending = work.parent / (canonical + '.result.pending')
    descriptor = os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(report, stream, indent=2, sort_keys=True)
    pending.replace(work.parent / 'result.json')
