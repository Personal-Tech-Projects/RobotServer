# RobotServer operational tools

## Protected RobotServer restart

`restart-robotserver.ps1` restarts only the `ROBOTSERVER` process while a
short-lived `port_keeper.py` holds container UDP 5005. It preserves an
already-present Windows Docker mapping; it deliberately refuses to repair a
mapping that is already absent.

The command sends `MOTOR, STOP` before and after the restart. It never sends a
movement command. By default it also requires a real ESP32 handshake and new
webcam chunk-set output after the keeper has been removed.

Run a read-only preflight first:

```powershell
.\tools\restart-robotserver.ps1 -PreflightOnly
```

Run the protected restart while exactly one webcam sender is active:

```powershell
.\tools\restart-robotserver.ps1
```

If no webcam sender is intentionally available, the application-output check
can be skipped explicitly. The command will warn that output was not proved:

```powershell
.\tools\restart-robotserver.ps1 -SkipWebcamOutputCheck
```

The helper requires all of these preconditions:

- `my-robot-server` is running.
- Exactly one `ROBOTSERVER` exists.
- No other port keeper is running.
- Windows `netstat` shows TCP 5005, UDP 5005, UDP 5006, and UDP 8888 with the
  expected Docker/WSL owners.
- A live container X display is available.
- UDP 5005 is already present. If it is absent, stop the webcam sender and use
  a separately controlled container-recovery procedure before retrying.

For bounded output verification the new server receives these environment
variables:

- `ROBOTSERVER_WEBCAM_DIAG_INTERVAL_MS=1000`
- `ROBOTSERVER_WEBCAM_DIAG_MAX_REPORTS=20`

The keeper is copied from this directory into a unique container `/tmp`
directory on every run. Readiness is reported only after every requested port
has actually bound. A `finally` cleanup stops the keeper and removes the
temporary directory on both success and failure.
