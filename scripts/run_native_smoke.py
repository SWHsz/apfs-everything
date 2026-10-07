#!/usr/bin/env python3
"""Capture an owned native acceptance run until the app's normal UI Quit.

Usage: python3 scripts/run_native_smoke.py MANIFEST --label first
No timeout extension, automatic kill, or daily cache mutation is performed.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import threading
import time


def identity(path):
    stat = path.lstat()
    return {"inode": stat.st_ino, "device": stat.st_dev, "uid": stat.st_uid}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--label", default="first")
    args = parser.parse_args()
    assert re.fullmatch(r"[A-Za-z0-9-]+", args.label), "invalid capture label"
    manifest = json.loads(args.manifest.read_text())
    app, cache, fixture = (Path(manifest[key]) for key in ("app", "cache", "fixture"))
    for path, key in ((app, "app_identity"), (cache, "cache_identity"), (fixture, "fixture_identity")):
        assert not path.is_symlink() and identity(path) == manifest[key], "owned identity changed"
        assert identity(path)["uid"] == os.getuid(), "foreign owner"
    info = plistlib.loads((app/"Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == manifest["bundle_id"]
    assert info["CFBundleIdentifier"].startswith("local.apfsfind.desktop.smoke.")
    assert info["APFSFindResourceSmoke"] and info["APFSFindTestCache"] == str(cache)
    assert info["APFSFindOwnedFixture"] == str(fixture)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    stdout = cache/(args.label+".native.stdout")
    stderr = cache/(args.label+".native.stderr")
    pid_path = cache/(args.label+".native.pid.json")
    exit_path = cache/(args.label+".native.exit.json")
    assert not any(p.exists() or p.is_symlink() for p in (stdout,stderr,pid_path,exit_path)), "capture already exists"
    start = time.monotonic()
    # Pipes keep the smoke app's own diagnostic capture out of its measured
    # filesystem I/O. Only this parent writes inside the excluded owned cache.
    def capture(stream, destination):
        for line in iter(stream.readline, b""):
            destination.write(line)
            destination.flush()
        stream.close()

    with stdout.open("xb") as out, stderr.open("xb") as err:
        process = subprocess.Popen([str(app/"Contents/MacOS/APFSFind")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        readers = [threading.Thread(target=capture,args=(process.stdout,out)),threading.Thread(target=capture,args=(process.stderr,err))]
        for reader in readers: reader.start()
        pid_path.write_text(json.dumps({"pid":process.pid,"started_epoch":time.time(),"label":args.label}))
        print(json.dumps({"pid":process.pid,"cache":str(cache),"label":args.label}), flush=True)
        code = process.wait()
        for reader in readers: reader.join()
    result = {"exit":code,"seconds":time.monotonic()-start,"finished_epoch":time.time(),"pid":process.pid,"label":args.label}
    exit_path.write_text(json.dumps(result, indent=2))
    print(json.dumps(result), flush=True)
    raise SystemExit(code)


if __name__ == "__main__":
    main()
