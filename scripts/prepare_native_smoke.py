#!/usr/bin/env python3
"""Prepare an independent, owned two-volume native acceptance instance.

Daily indexes are read-only inputs. Logs below are explicitly benchmark captures.
Run scripts/run_native_smoke.py with the returned manifest. Benchmark captures
belong inside the excluded owned cache, or their own writes prevent strict quiet.
Use the app's normal menu Quit, then --restart the manifest for replay testing.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid


def checked_run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def identity(path):
    st = path.lstat()
    return {"inode": st.st_ino, "device": st.st_dev, "uid": st.st_uid}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed-cache", type=Path, default=Path.home()/"Library/Application Support/apfsfind/indexes")
    parser.add_argument("--restart", type=Path, help="existing owned manifest, after the first app has quit")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    if args.restart:
        manifest = json.loads(args.restart.read_text())
        app = Path(manifest["app"])
        assert identity(app) == manifest["app_identity"], "owned bundle identity changed"
        plist = app/"Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        assert info["CFBundleIdentifier"] == manifest["bundle_id"]
        info["APFSFindSmokeRestart"] = True
        plist.write_bytes(plistlib.dumps(info))
        checked_run(["codesign", "--force", "--deep", "--sign", "-", str(app)])
        checked_run(["codesign", "--verify", "--deep", "--strict", str(app)])
        print(app/"Contents/MacOS/APFSFind")
        return
    assert Path("/Volumes/Data 1").is_dir(), "required Data 1 volume is absent"
    token = str(uuid.uuid4()).upper()
    cache = Path("/private/tmp")/("apfsfind-real-cache-"+token)
    report = Path("/private/tmp")/("apfsfind-native-report-"+token)
    cache.mkdir(mode=0o700)
    report.mkdir(mode=0o700)
    fixture = repo/".build"/("apfsfind-fixture-"+token)
    fixture.mkdir(mode=0o700)
    for i in range(1, 13):
        (fixture/("apfsfindv061fixture-base-"+str(i))).write_bytes(b"")
    for source in sorted(args.seed_cache.glob("*.apfsidx")):
        assert source.is_file() and not source.is_symlink(), "invalid seed snapshot"
        destination = cache/source.name
        checked_run(["/bin/cp", "-c", str(source), str(destination)])
        destination.chmod(0o600)
    assert len(list(cache.glob("*.apfsidx"))) == 2, "expected real root and Data 1 snapshots"
    cli = repo/".build/release/apfsfind"
    with (report/"prepare.stdout").open("w") as out, (report/"prepare.stderr").open("w") as err:
        checked_run([str(cli), "_prepare-resource-smoke", str(cache)], stdout=out, stderr=err, cwd=repo)
    app = report/"APFSFindV061Smoke.app"
    shutil.copytree(repo/"dist/APFSFind.app", app, symlinks=True)
    plist = app/"Contents/Info.plist"
    info = plistlib.loads(plist.read_bytes())
    bundle_id = "local.apfsfind.desktop.smoke.v061."+token.lower()
    info.update(CFBundleIdentifier=bundle_id, CFBundleName="APFSFindV061Smoke", CFBundleDisplayName="APFSFindV061Smoke",
                APFSFindResourceSmoke=True, APFSFindTestRoots=["/", "/Volumes/Data 1"],
                APFSFindTestCache=str(cache), APFSFindOwnedFixture=str(fixture))
    plist.write_bytes(plistlib.dumps(info))
    checked_run(["codesign", "--force", "--deep", "--sign", "-", str(app)])
    checked_run(["codesign", "--verify", "--deep", "--strict", str(app)])
    manifest = {"app": str(app), "cache": str(cache), "fixture": str(fixture), "report": str(report), "bundle_id": bundle_id,
                "app_identity": identity(app), "cache_identity": identity(cache), "fixture_identity": identity(fixture),
                "head": checked_run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip(),
                "cli_sha256": hashlib.sha256(cli.read_bytes()).hexdigest(),
                "desktop_sha256": hashlib.sha256((app/"Contents/MacOS/APFSFind").read_bytes()).hexdigest()}
    (report/"manifest.json").write_text(json.dumps(manifest, indent=2))
    print(report/"manifest.json")
    print(app/"Contents/MacOS/APFSFind")


if __name__ == "__main__":
    main()
