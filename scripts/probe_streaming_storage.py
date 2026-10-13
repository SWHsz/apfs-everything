#!/usr/bin/env python3
"""Owned APFS forced removal during production streaming cold/recovery builds."""
import argparse, hashlib, json, queue, subprocess, threading, uuid
from pathlib import Path

def call(args):
    r = subprocess.run(args, capture_output=True, text=True, timeout=60)
    return dict(exit=r.returncode, stdout=r.stdout, stderr=r.stderr)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cli', type=Path, required=True)
    args = parser.parse_args()
    root = Path('/private/tmp') / ('apfsfind-streaming-storage-' + str(uuid.uuid4()))
    root.mkdir(mode=0o700)
    source, mount, image = root/'source', root/'mount', root/'owned.sparseimage'
    source.mkdir(mode=0o700); mount.mkdir(mode=0o700)
    report = dict(source='equivalent paged 65,537-record production coordinator', modes=[])
    def save(): (root/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    report['create'] = call(['hdiutil', 'create', '-size', '1g', '-fs', 'APFS', '-type', 'SPARSE', '-volname', 'APFSFindStreamingProbe', str(image)])
    save()
    if report['create']['exit']: raise RuntimeError('create failed')
    for mode in ('cold', 'recovery'):
        item = dict(mode=mode); report['modes'].append(item)
        item['attach'] = call(['hdiutil', 'attach', str(image), '-mountpoint', str(mount), '-nobrowse', '-noautoopen'])
        child = None; detached = False
        lines = []
        try:
            if item['attach']['exit']: raise RuntimeError('attach failed')
            cache = mount/mode
            events = queue.Queue()
            with (root/(mode+'.stderr')).open('wb') as error:
                child = subprocess.Popen([str(args.cli), '_streaming-storage-probe', mode, str(source), str(cache)], stdout=subprocess.PIPE, stderr=error)
                def read():
                    for line in child.stdout:
                        text = line.decode(errors='replace'); lines.append(text); events.put(text)
                reader = threading.Thread(target=read, daemon=True); reader.start()
                while True:
                    line = events.get(timeout=60)
                    if '"streaming_before_assembly":true' in line.replace(' ', ''): break
                    if child.poll() is not None: raise RuntimeError('child ended before handshake')
                def hashes(): return {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in cache.iterdir() if f.suffix in ('.apfsidx', '.apfsmeta')}
                before = hashes()
                item['immutable_files_before'] = len(before)
                item['detach'] = call(['hdiutil', 'detach', str(mount), '-force'])
                detached = item['detach']['exit'] == 0
                if not detached: raise RuntimeError('forced detach failed')
                child.wait(timeout=30); reader.join(timeout=5)
                item['child_exit'] = child.returncode
                if child.returncode or not any('structured_io_error' in line for line in lines): raise RuntimeError('no safe structured error')
                item['reattach'] = call(['hdiutil', 'attach', str(image), '-mountpoint', str(mount), '-nobrowse', '-noautoopen']); detached = False
                if item['reattach']['exit']: raise RuntimeError('reattach failed')
                item['immutable_hashes_unchanged'] = before == hashes()
                if before != hashes(): raise RuntimeError('incomplete build published')
                if mode == 'cold' and before: raise RuntimeError('cold already had a base')
                if mode == 'recovery' and len(before) != 2: raise RuntimeError('recovery old pair missing')
        except Exception as exc: item['error'] = str(exc)
        finally:
            if child is not None and child.poll() is None: child.kill(); child.wait(timeout=5)
            item['output'] = lines
            if not detached: item['cleanup_detach'] = call(['hdiutil', 'detach', str(mount)])
            save()
    report['passed'] = all(x.get('child_exit') == 0 and x.get('immutable_hashes_unchanged') and not x.get('error') for x in report['modes'])
    save(); print(root/'report.json', flush=True)
    return 0 if report['passed'] else 1
if __name__ == '__main__': raise SystemExit(main())
