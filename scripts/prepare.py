#!/usr/bin/env python3
"""Assemble the pinned Homarr source plus this extension. Requires Git and Python 3."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", nargs="?", default=str(ROOT / ".build" / "homarr"))
    args = parser.parse_args()
    destination = Path(args.destination).resolve()
    if destination.exists():
        parser.error("Destination already exists; choose a new empty path.")
    upstream = json.loads((ROOT / "homarr" / "upstream.json").read_text())
    run("git", "init", str(destination))
    run("git", "remote", "add", "origin", upstream["repository"], cwd=destination)
    run("git", "fetch", "--depth", "1", "origin", upstream["revision"], cwd=destination)
    run("git", "checkout", "--detach", "FETCH_HEAD", cwd=destination)
    run("git", "apply", "--check", str(ROOT / "homarr" / "registration.patch"), cwd=destination)
    run("git", "apply", str(ROOT / "homarr" / "registration.patch"), cwd=destination)
    shutil.copytree(ROOT / "homarr" / "overlay", destination, dirs_exist_ok=True)
    shutil.copytree(ROOT / "agent", destination / "tools" / "hyperv-agent", dirs_exist_ok=True)
    print(f"Prepared Homarr {upstream['version']} + Hyper-V at {destination}")


if __name__ == "__main__":
    main()
