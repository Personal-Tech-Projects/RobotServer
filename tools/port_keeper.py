#!/usr/bin/env python3
"""Temporarily hold UDP ports during a bounded receiver restart.

This helper preserves an already-present Docker host mapping while the real
receiver is briefly absent. It does not repair a mapping that is already gone
and makes no claim about Docker's internal failure mechanism.
"""

import argparse
import json
import os
import select
import signal
import socket
import sys
import time
from pathlib import Path


MAX_DRAIN_BATCH = 256
STOP_REQUESTED = False


def positive_seconds(value):
    seconds = float(value)
    if seconds <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return seconds


def port_list(value):
    try:
        ports = [int(item.strip()) for item in value.split(",")]
    except ValueError as exc:
        raise argparse.ArgumentTypeError("ports must be integers") from exc
    if not ports or any(port < 1 or port > 65535 for port in ports):
        raise argparse.ArgumentTypeError("ports must be in the range 1-65535")
    if len(set(ports)) != len(ports):
        raise argparse.ArgumentTypeError("ports must not contain duplicates")
    return ports


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=positive_seconds, default=120.0)
    parser.add_argument(
        "--ports", type=port_list, required=True,
        help="comma-separated UDP ports to hold",
    )
    parser.add_argument(
        "--ready-file",
        help="write readiness JSON only after every requested bind succeeds",
    )
    return parser.parse_args()


def request_stop(_signum, _frame):
    global STOP_REQUESTED
    STOP_REQUESTED = True


def bind_all(ports):
    sockets = []
    try:
        for port in ports:
            candidate = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            candidate.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                candidate.bind(("0.0.0.0", port))
            except OSError:
                candidate.close()
                raise
            candidate.setblocking(False)
            sockets.append(candidate)
        return sockets
    except Exception:
        for bound_socket in sockets:
            bound_socket.close()
        raise


def write_ready_file(path, ports):
    if not path:
        return
    ready_path = Path(path)
    temporary_path = ready_path.with_name(
        f"{ready_path.name}.{os.getpid()}.tmp"
    )
    temporary_path.write_text(
        json.dumps({"pid": os.getpid(), "ports": ports}), encoding="utf-8"
    )
    os.replace(temporary_path, ready_path)


def remove_ready_file(path):
    if not path:
        return
    try:
        Path(path).unlink()
    except FileNotFoundError:
        pass


def drain_until_deadline(sockets, seconds):
    deadline = time.monotonic() + seconds
    drained = 0
    while not STOP_REQUESTED:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            readable, _, _ = select.select(
                sockets, [], [], min(0.05, remaining)
            )
        except InterruptedError:
            continue
        for bound_socket in readable:
            for _ in range(MAX_DRAIN_BATCH):
                if STOP_REQUESTED or time.monotonic() >= deadline:
                    return drained
                try:
                    bound_socket.recvfrom(65535)
                    drained += 1
                except BlockingIOError:
                    break
                except OSError:
                    break
    return drained


def main():
    args = parse_args()
    for signal_number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signal_number, request_stop)

    sockets = []
    try:
        try:
            sockets = bind_all(args.ports)
            write_ready_file(args.ready_file, args.ports)
        except (OSError, ValueError) as exc:
            print(f"port_keeper: startup failed: {exc}", file=sys.stderr, flush=True)
            return 1

        print(
            "port_keeper: READY "
            f"pid={os.getpid()} ports={','.join(map(str, args.ports))} "
            f"seconds={args.seconds:g}",
            flush=True,
        )
        drained = drain_until_deadline(sockets, args.seconds)
        print(f"port_keeper: RELEASED drained={drained}", flush=True)
        return 0
    finally:
        remove_ready_file(args.ready_file)
        for bound_socket in sockets:
            bound_socket.close()


if __name__ == "__main__":
    raise SystemExit(main())
