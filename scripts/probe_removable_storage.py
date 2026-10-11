#!/usr/bin/env python3
"""Child-process experiment against an owned APFS image, never a user disk.

Build StorageMMapProbe.swift against the release Core first; pass its executable
with --helper. The image and raw captures are retained for reproducibility.
An unsuccessful detach is recorded as unsuccessful, never as removal safety.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time
import uuid


def command(arguments, timeout=60):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
    return {"arguments": arguments, "exit": result.returncode,
            "stdout": result.stdout, "stderr": result.stderr}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--backing", choices=["mmap", "pread"], default="mmap")
    args = parser.parse_args()
    root = Path("/private/tmp") / ("apfsfind-storage-probe-" + str(uuid.uuid4()))
    root.mkdir(mode=0o700)
    source, mount = root / "source", root / "mount"
    source.mkdir(mode=0o700)
    mount.mkdir(mode=0o700)
    image = root / "owned.sparseimage"
    report = {"started_epoch": time.time(), "owned_root": str(root), "experiments": []}
    def save():
        (root / "report.json").write_text(json.dumps(report, indent=2))
    created = command(["hdiutil", "create", "-size", "128m", "-fs", "APFS",
                       "-type", "SPARSE", "-volname", "APFSFindOwnedProbe", str(image)])
    report["create"] = created
    save()
    if created["exit"]:
        print(root / "report.json", flush=True)
        raise SystemExit(1)
    for mode in ("safe", "forced"):
        experiment = {"mode": mode}
        report["experiments"].append(experiment)
        attached = command(["hdiutil", "attach", str(image), "-mountpoint", str(mount),
                            "-nobrowse", "-noautoopen"])
        experiment["attach"] = attached
        save()
        if attached["exit"]:
            break
        child = None
        detached = False
        try:
            storage = mount / "indexes"
            if mode == "safe":
                prepared = command([str(args.helper), "prepare", str(source), str(storage)])
                experiment["prepare"] = prepared
                if prepared["exit"]:
                    raise RuntimeError("index preparation failed")
            observed = queue.Queue()
            with (root / (mode + ".stdout")).open("wb") as out, (root / (mode + ".stderr")).open("wb") as err:
                child = subprocess.Popen([str(args.helper), "query" if args.backing == "mmap" else "pread", str(source), str(storage)],
                                         stdout=subprocess.PIPE, stderr=err)
                def capture():
                    for line in iter(child.stdout.readline, b""):
                        out.write(line)
                        out.flush()
                        observed.put(line)
                reader = threading.Thread(target=capture, daemon=True)
                reader.start()
                deadline = time.monotonic() + 30
                queries = 0
                while queries < 2:
                    if child.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("child did not reach continuous namespace/metadata queries")
                    try:
                        line = observed.get(timeout=0.2)
                        if b'"query_hits":50' in line.replace(b" ", b"") or b'"pread_pass":true' in line.replace(b" ", b""):
                            queries += 1
                    except queue.Empty:
                        pass
                experiment["queries_before_detach"] = queries
                detach = command(["hdiutil", "detach", str(mount)] + (["-force"] if mode == "forced" else []))
                experiment["detach_while_querying"] = detach
                detached = detach["exit"] == 0
                # Never interpret a busy mount as successful surprise removal.
                if detached:
                    try:
                        child.wait(timeout=8)
                        experiment["post_detach"] = "child_exited"
                    except subprocess.TimeoutExpired:
                        experiment["post_detach"] = "child_still_running"
                        experiment["post_detach_query_lines"] = observed.qsize()
                else:
                    experiment["post_detach"] = "detach_failed"
                experiment["child_exit_before_cleanup"] = child.poll()
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=5)
                reader.join(timeout=5)
                experiment["child_final_exit"] = child.returncode
        except Exception as error:
            experiment["error"] = str(error)
        finally:
            if child is not None and child.poll() is None:
                child.kill()
                child.wait(timeout=5)
            if not detached:
                experiment["cleanup_detach"] = command(["hdiutil", "detach", str(mount)])
            save()
    print(root / "report.json", flush=True)


if __name__ == "__main__":
    main()
