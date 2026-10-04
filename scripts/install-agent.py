#!/usr/bin/env python3
"""Install one per-user app LaunchAgent. This never changes calendar/write settings."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

LABEL = "com.belovodie.calendar-bridge.agent"


def generate(app):
    app = Path(app).expanduser().resolve(strict=True)
    executable = app / "Contents/MacOS/BelovodieCalendarBridge"
    if app.suffix != ".app" or not executable.is_file():
        raise ValueError("Provide the reviewed signed application bundle")
    template = Path(__file__).resolve().parent.parent / "packaging/LaunchAgent.plist"
    values = plistlib.loads(template.read_bytes())
    values["ProgramArguments"][0] = str(executable)
    return plistlib.dumps(values)


def atomic_plist(path, payload):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError("Unsafe LaunchAgent destination")
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name, dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(payload); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try: os.fsync(directory)
        finally: os.close(directory)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["generate", "install", "start", "stop", "restart", "uninstall"])
    parser.add_argument("--app", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    destination = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    target = "gui/" + str(os.getuid())
    service = target + "/" + LABEL
    if args.action in {"generate", "install"}:
        if args.app is None: parser.error("--app is required")
        payload = generate(args.app)
        if args.action == "generate":
            if args.output is None: parser.error("--output is required for generation")
            atomic_plist(args.output, payload)
            return 0
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(args.app)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if destination.exists():
            subprocess.run(["/bin/launchctl", "bootout", service], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        atomic_plist(destination, payload)
        subprocess.run(["/bin/launchctl", "bootstrap", target, str(destination)], check=True)
    elif args.action == "start":
        subprocess.run(["/bin/launchctl", "bootstrap", target, str(destination)], check=True)
    elif args.action in {"stop", "uninstall"}:
        subprocess.run(["/bin/launchctl", "bootout", service], check=True)
        if args.action == "uninstall": destination.unlink()
    else:
        subprocess.run(["/bin/launchctl", "kickstart", "-k", service], check=True)
    return 0


if __name__ == "__main__":
    try: sys.exit(main())
    except Exception:
        print("LaunchAgent operation failed", file=sys.stderr)
        sys.exit(1)
