"""Build, run, watch and control the generic native simulator. Python stdlib only."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


class SimulatorError(RuntimeError):
    """The simulator rejected a command or stopped responding."""


class Client:
    def __init__(self, directory, process=None):
        self.directory = Path(directory).resolve()
        self.process = process

    def send(self, op, *, request_id=None, timeout=5, **fields):
        if request_id is not None and not 0 < request_id < 2**64:
            raise ValueError("request_id must be between 1 and 2**64 - 1")
        request = {"id": request_id if request_id is not None else secrets.randbits(63) or 1, "op": op, **fields}
        payload = json.dumps(request, ensure_ascii=False).encode("utf-8")
        if len(payload) > 16 * 1024:
            raise ValueError("Simulator request exceeds 16 KiB")
        lock = self.directory / "client.lock"
        try:
            descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError as error:
            raise SimulatorError("Another client has an in-flight request") from error
        os.close(descriptor)
        try:
            target = self.directory / "request.json"
            if target.exists() and json.loads(target.read_text())["id"] != request["id"]:
                raise SimulatorError("An earlier request is still pending")
            response = self.directory / "response.json"
            response.unlink(missing_ok=True)
            pending = self.directory / "request.pending"
            pending.write_bytes(payload)
            pending.replace(target)
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if response.exists():
                    result = json.loads(response.read_text(encoding="utf-8"))
                    if result["id"] in (0, request["id"]):
                        if not result["ok"]:
                            raise SimulatorError(result["failure"])
                        return result
                if self.process is not None and self.process.poll() is not None:
                    raise SimulatorError(f"Simulator exited with status {self.process.returncode}")
                time.sleep(0.01)
            raise SimulatorError(f"Request {request['id']} timed out; retry with this request_id")
        finally:
            lock.unlink(missing_ok=True)


def source_signature(paths):
    """Watch selected sources, excluding generated outputs and compiler caches."""
    excluded = {".git", ".zig-cache", "zig-cache", "zig-out", "__pycache__", "node_modules"}
    result = []
    for root in paths:
        path = Path(root)
        if path.is_file():
            files = [path]
        else:
            files = []
            for directory, dirs, names in os.walk(path):
                dirs[:] = sorted(d for d in dirs if d not in excluded)
                files.extend(Path(directory) / name for name in sorted(names))
        for file in files:
            stat = file.stat()
            result.append((str(file), stat.st_mtime_ns, stat.st_size))
    return tuple(result)


def start(binary, app, directory, *, headless=False, watch=False):
    command = [str(binary), "--app", str(Path(app).resolve()), "--control-dir", str(directory)]
    if headless:
        command.append("--headless")
    if watch:
        command.append("--watch")
    process = subprocess.Popen(command)
    client = Client(directory, process)
    deadline = time.monotonic() + 5
    while not Path(directory).exists():
        if process.poll() is not None:
            raise SimulatorError(f"Simulator exited with status {process.returncode}")
        if time.monotonic() >= deadline:
            process.terminate()
            process.wait(timeout=5)
            raise SimulatorError("Simulator did not create its control directory")
        time.sleep(0.01)
    try:
        client.send("state")
    except BaseException:
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=5)
        raise
    return process, client


def run(args):
    binary = Path(args.sim).resolve()
    app = Path(args.app).resolve()
    if not binary.is_file():
        raise SimulatorError("Build the simulator first: mise run build-sim")
    watched = [Path(p).resolve() for p in args.watch]
    if watched and not args.build:
        raise SimulatorError("Source watching needs --build followed by an argument list")
    with tempfile.TemporaryDirectory(prefix="gain-sim-run-") as base:
        process = None
        try:
            previous = None
            while True:
                current = source_signature(watched) if watched else ()
                if process is None or current != previous:
                    # Wait for saves to settle before rebuilding. Never execute build text in a shell.
                    if watched:
                        time.sleep(0.1)
                        if source_signature(watched) != current:
                            continue
                    previous = current
                    succeeded = not args.build or subprocess.run(args.build, cwd=args.project, check=False).returncode == 0
                    if succeeded:
                        if process is None:
                            process, client = start(binary, app, Path(base) / "session", watch=not watched)
                        else:
                            try:
                                client.send("reload")
                            except SimulatorError as error:
                                print(f"Reload kept the current app: {error}", flush=True)
                    elif process is None:
                        raise SimulatorError("Initial app build failed")
                if process.poll() is not None:
                    return process.returncode
                time.sleep(0.1)
        except KeyboardInterrupt:
            return 0
        finally:
            if process is not None and process.poll() is None:
                try:
                    client.send("quit", timeout=2)
                    process.wait(timeout=5)
                except (SimulatorError, subprocess.TimeoutExpired):
                    process.terminate()
                    process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    runner = sub.add_parser("run")
    runner.add_argument("--sim", default=ROOT / "zig-out/bin/gain-sim")
    runner.add_argument("--app", required=True)
    runner.add_argument("--project", type=Path, default=Path.cwd())
    runner.add_argument("--watch", action="append", default=[])
    runner.add_argument("--build", nargs=argparse.REMAINDER)
    control = sub.add_parser("control")
    control.add_argument("--directory", required=True)
    control.add_argument("--request-id", type=int)
    control.add_argument("op", choices=["input", "resize", "reload", "load", "capture", "state", "quit"])
    control.add_argument("--button")
    control.add_argument("--phase", choices=["tap", "press", "release", "repeat"], default="tap")
    control.add_argument("--path")
    control.add_argument("--window", action="store_true", help="Capture the window instead of native pixels")
    control.add_argument("--width", type=int)
    control.add_argument("--height", type=int)
    args = parser.parse_args()
    if args.mode == "run":
        raise SystemExit(run(args))
    fields = {}
    if args.op == "input":
        fields.update(button=args.button, phase=args.phase)
    if args.op in ("load", "capture"):
        if args.path is None:
            parser.error("--path is required")
        fields["path"] = str(Path(args.path).resolve())
    if args.op == "capture":
        fields["native"] = not args.window
    for key in ("width", "height"):
        if getattr(args, key) is not None:
            fields[key] = getattr(args, key)
    print(json.dumps(Client(args.directory).send(args.op, request_id=args.request_id, **fields), indent=2))


if __name__ == "__main__":
    main()
