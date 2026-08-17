<#
Restart only ROBOTSERVER while preserving an already-present Docker UDP 5005
host mapping. The keeper bridges the receiver gap; this script deliberately
refuses to claim it can repair a mapping that is already absent.
#>
[CmdletBinding()]
param(
    [switch]$Autonomous,
    [switch]$SkipWebcamOutputCheck,
    [switch]$PreflightOnly,
    [ValidateRange(10, 300)]
    [int]$KeeperSeconds = 60,
    [ValidateRange(5, 60)]
    [int]$StartupTimeoutSeconds = 15,
    [ValidateRange(2, 60)]
    [int]$OutputTimeoutSeconds = 12,
    [string]$Container = "my-robot-server"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-DockerCommand {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0)
    )

    $lines = @(& docker @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($AllowedExitCodes -notcontains $exitCode) {
        $rendered = $Arguments -join " "
        $detail = $lines -join [Environment]::NewLine
        throw "docker $rendered failed with exit code ${exitCode}: $detail"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = [string]($lines -join [Environment]::NewLine)
    }
}

function Get-HostMappingSnapshot {
    $lines = @(& netstat -ano)
    if ($LASTEXITCODE -ne 0) {
        throw "Windows netstat failed with exit code $LASTEXITCODE"
    }

    $requirements = [ordered]@{
        Tcp5005 = @{ Protocol = "TCP"; Port = 5005; State = "LISTENING" }
        Udp5005 = @{ Protocol = "UDP"; Port = 5005; State = $null }
        Udp5006 = @{ Protocol = "UDP"; Port = 5006; State = $null }
        Udp8888 = @{ Protocol = "UDP"; Port = 8888; State = $null }
    }
    $snapshot = [ordered]@{}
    foreach ($name in $requirements.Keys) {
        $requirement = $requirements[$name]
        $owners = foreach ($line in $lines) {
            if ($requirement.Protocol -eq "TCP") {
                if ($line -match "^\s*TCP\s+\S+:$($requirement.Port)\s+\S+\s+$($requirement.State)\s+(\d+)\s*$") {
                    [int]$Matches[1]
                }
            } elseif ($line -match "^\s*UDP\s+\S+:$($requirement.Port)\s+\*:\*\s+(\d+)\s*$") {
                [int]$Matches[1]
            }
        }
        $snapshot[$name] = @($owners | Sort-Object -Unique)
    }
    return [pscustomobject]$snapshot
}

function Assert-RequiredHostMappings {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][string]$Context
    )

    if (@($Snapshot.Udp5005).Count -eq 0) {
        throw "Windows UDP 5005 is already absent during $Context. Stop the webcam sender, restart only my-robot-server to recreate the mapping, and rerun this protected restart after confirming the mapping."
    }

    foreach ($name in @("Tcp5005", "Udp5005", "Udp5006", "Udp8888")) {
        $owners = @($Snapshot.$name)
        if ($owners.Count -eq 0) {
            throw "$name is absent during $Context"
        }
        $observedNames = @()
        foreach ($owner in $owners) {
            $process = Get-Process -Id $owner -ErrorAction Stop
            $observedNames += $process.ProcessName
            $allowedNames = if ($name -eq "Tcp5005") {
                @("com.docker.backend", "wslrelay")
            } else {
                @("com.docker.backend")
            }
            if ($allowedNames -notcontains $process.ProcessName) {
                throw "$name is owned by unexpected PID $owner ($($process.ProcessName)) during $Context"
            }
        }
        if ($observedNames -notcontains "com.docker.backend") {
            throw "$name has no Docker backend owner during $Context"
        }
    }
}

function Get-MappingSignature {
    param([Parameter(Mandatory)]$Snapshot)
    return (@("Tcp5005", "Udp5005", "Udp5006", "Udp8888") | ForEach-Object {
        "$_=$(@($Snapshot.$_) -join ',')"
    }) -join ";"
}

function Get-ContainerPids {
    param([Parameter(Mandatory)][string]$ProcessName)
    $result = Invoke-DockerCommand -Arguments @(
        "exec", $Container, "pgrep", "-x", $ProcessName
    ) -AllowedExitCodes @(0, 1)
    if ($result.ExitCode -eq 1 -or -not $result.Output.Trim()) {
        return @()
    }
    return @($result.Output -split "\s+" | Where-Object { $_ } | ForEach-Object {
        [int]$_
    })
}

function Get-KeeperPids {
    $result = Invoke-DockerCommand -Arguments @(
        "exec", $Container, "bash", "-lc",
        "pgrep -f '[p]ort_keeper.py.*--ports 5005' || true"
    )
    if (-not $result.Output.Trim()) { return @() }
    return @($result.Output -split "\s+" | Where-Object { $_ } | ForEach-Object {
        [int]$_
    })
}

function Get-RobotServerInputKeeperPids {
    $result = Invoke-DockerCommand -Arguments @(
        "exec", $Container, "bash", "-lc",
        "pgrep -f '^tail -f /dev/null$' || true"
    )
    if (-not $result.Output.Trim()) { return @() }
    return @($result.Output -split "\s+" | Where-Object { $_ } | ForEach-Object {
        [int]$_
    })
}

function Test-ContainerPid {
    param([Parameter(Mandatory)][int]$ProcessId)
    $result = Invoke-DockerCommand -Arguments @(
        "exec", $Container, "kill", "-0", [string]$ProcessId
    ) -AllowedExitCodes @(0, 1)
    return $result.ExitCode -eq 0
}

function Test-ProcessOwnsUdpPort {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][int]$Port
    )

    $probe = @'
pid="$1"
port_hex=$(printf '%04X' "$2")
for fd in /proc/"$pid"/fd/*; do
    link=$(readlink "$fd" 2>/dev/null || true)
    inode=$(printf '%s\n' "$link" | sed -n 's/^socket:\[\([0-9][0-9]*\)\]$/\1/p')
    [ -n "$inode" ] || continue
    if awk -v suffix=":$port_hex" -v inode="$inode" \
        '$2 ~ suffix "$" && $10 == inode {found=1} END {exit(found ? 0 : 1)}' \
        /proc/net/udp /proc/net/udp6 2>/dev/null; then
        exit 0
    fi
done
exit 1
'@
    $null = $probe | & docker exec -i $Container bash -s -- $ProcessId $Port 2>$null
    return $LASTEXITCODE -eq 0
}

function Get-ContainerSessionId {
    param([Parameter(Mandatory)][int]$ProcessId)
    $result = Invoke-DockerCommand -Arguments @(
        "exec", $Container, "ps", "-o", "sid=", "-p", [string]$ProcessId
    )
    $sessionId = 0
    if (-not [int]::TryParse($result.Output.Trim(), [ref]$sessionId) -or $sessionId -le 1) {
        throw "Unsafe or missing session ID for container PID $ProcessId"
    }
    return $sessionId
}

function Stop-ContainerSession {
    param([Parameter(Mandatory)][int]$SessionId)

    $null = Invoke-DockerCommand -Arguments @(
        "exec", $Container, "bash", "-lc", "kill -TERM -- -$SessionId"
    ) -AllowedExitCodes @(0, 1)
    $deadline = (Get-Date).AddSeconds(3)
    do {
        $members = Invoke-DockerCommand -Arguments @(
            "exec", $Container, "bash", "-lc",
            "ps -eo sid= | awk '`$1 == $SessionId {count++} END {print count+0}'"
        )
        if ([int]$members.Output.Trim() -eq 0) { return }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)

    $null = Invoke-DockerCommand -Arguments @(
        "exec", $Container, "bash", "-lc", "kill -KILL -- -$SessionId"
    ) -AllowedExitCodes @(0, 1)
    Start-Sleep -Milliseconds 250
}

function Get-ContainerDisplay {
    param([int]$ServerPid)

    if ($ServerPid) {
        $result = Invoke-DockerCommand -Arguments @(
            "exec", $Container, "bash", "-lc",
            "tr '\0' '\n' < /proc/$ServerPid/environ | sed -n 's/^DISPLAY=//p'"
        )
        if ($result.Output.Trim()) { return $result.Output.Trim() }
    }

    $probe = @'
import os, socket
directory = "/tmp/.X11-unix"
if os.path.isdir(directory):
    sockets = sorted(
        (name for name in os.listdir(directory)
         if name.startswith("X") and name[1:].isdigit()),
        key=lambda name: os.path.getmtime(os.path.join(directory, name)),
        reverse=True,
    )
    for name in sockets[:10]:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(1)
        try:
            connection.connect(os.path.join(directory, name))
            connection.sendall(b'l\x00\x0b\x00\x00\x00\x00\x00\x00\x00\x00\x00')
            reply = connection.recv(8)
            if reply and reply[0] == 1:
                print(name[1:])
                break
        except Exception:
            pass
        finally:
            connection.close()
'@
    $result = $probe | & docker exec -i $Container python3 - 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    if ($result) { return ":$([string]$result).Trim()" }
    return $null
}

function Get-Esp32Ip {
    $counts = @{}
    foreach ($line in (& netstat -ano -p TCP)) {
        if ($line -match '^\s*TCP\s+\S+:5005\s+(\d{1,3}(?:\.\d{1,3}){3}):\d+\s+\S+') {
            $ip = $Matches[1]
            if ($ip -ne "0.0.0.0" -and $ip -ne "127.0.0.1") {
                if (-not $counts.ContainsKey($ip)) { $counts[$ip] = 0 }
                $counts[$ip]++
            }
        }
    }
    if ($counts.Count -eq 0) { return $null }
    return ($counts.GetEnumerator() |
        Sort-Object Value -Descending |
        Select-Object -First 1).Key
}

function Send-MotorStop {
    param([string]$Esp32Ip)
    if (-not $Esp32Ip) {
        Write-Warning "ESP32 peer is unavailable; the firmware command timeout remains the backstop"
        return
    }

    $payload = [Text.Encoding]::ASCII.GetBytes("MOTOR, STOP")
    $udp = [Net.Sockets.UdpClient]::new()
    try {
        $sent = $udp.Send($payload, $payload.Length, $Esp32Ip, 4210)
        Write-Host "Submitted MOTOR, STOP to $Esp32Ip ($sent bytes; protocol has no ACK)"
    } finally {
        $udp.Close()
    }
}

function Wait-ForCondition {
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [int]$PollMilliseconds = 200
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds $PollMilliseconds
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-LatestChunkSetCount {
    param([Parameter(Mandatory)][string]$LogPath)
    $result = Invoke-DockerCommand -Arguments @(
        "exec", $Container, "bash", "-lc", "tail -n 200 '$LogPath' 2>/dev/null || true"
    )
    $matches = [regex]::Matches(
        $result.Output,
        '(?:complete_chunk_sets|complete)=(\d+)'
    )
    if ($matches.Count -eq 0) { return 0L }
    return [long]$matches[$matches.Count - 1].Groups[1].Value
}

function Start-RobotServerDetached {
    param(
        [Parameter(Mandatory)][string]$Display,
        [Parameter(Mandatory)][int]$AutonomousAllowed,
        [Parameter(Mandatory)][bool]$EnableBoundedDiagnostics,
        [Parameter(Mandatory)][string]$LogPath
    )

    $diagnosticEnvironment = ""
    if ($EnableBoundedDiagnostics) {
        $diagnosticEnvironment = " ROBOTSERVER_WEBCAM_DIAG_INTERVAL_MS=1000 ROBOTSERVER_WEBCAM_DIAG_MAX_REPORTS=20"
    }
    $command = "cd /root/code/RobotServer && exec setsid env DISPLAY=$Display ROBOT_AUTONOMOUS_ALLOWED=$AutonomousAllowed$diagnosticEnvironment bash -c 'tail -f /dev/null | ./build/bin/ROBOTSERVER' > '$LogPath' 2>&1 < /dev/null"
    $null = Invoke-DockerCommand -Arguments @(
        "exec", "-d", $Container, "bash", "-lc", $command
    )
}

function Stop-Keeper {
    param(
        [int]$KeeperPid,
        [string]$TemporaryDirectory
    )

    $keeperStillRunning = $false
    try {
        if ($KeeperPid -and (Test-ContainerPid -ProcessId $KeeperPid)) {
            $null = Invoke-DockerCommand -Arguments @(
                "exec", $Container, "kill", "-TERM", [string]$KeeperPid
            ) -AllowedExitCodes @(0, 1)
            $stopped = Wait-ForCondition -TimeoutSeconds 3 -Condition {
                -not (Test-ContainerPid -ProcessId $KeeperPid)
            }
            if (-not $stopped) {
                $null = Invoke-DockerCommand -Arguments @(
                    "exec", $Container, "kill", "-KILL", [string]$KeeperPid
                ) -AllowedExitCodes @(0, 1)
                Start-Sleep -Milliseconds 250
            }
            $keeperStillRunning = Test-ContainerPid -ProcessId $KeeperPid
        }
    } finally {
        if ($TemporaryDirectory) {
            if ($TemporaryDirectory -notmatch '^/tmp/robotserver-restart-[a-f0-9]+$') {
                throw "Refusing to remove unexpected temporary path $TemporaryDirectory"
            }
            $null = Invoke-DockerCommand -Arguments @(
                "exec", $Container, "rm", "-rf", "--", $TemporaryDirectory
            )
        }
    }
    if ($keeperStillRunning) {
        throw "Keeper PID $KeeperPid remained after TERM and KILL"
    }
}

$keeperPid = 0
$temporaryDirectory = $null
$faultInjectionStarted = $false
$esp32Ip = $null
$oldServerPid = 0
$newServerPid = 0
$newSessionId = 0
$display = $null
$robotServerLog = "/tmp/robotserver.log"
$autonomousValue = if ($Autonomous) { 1 } else { 0 }

try {
    $containerState = Invoke-DockerCommand -Arguments @(
        "inspect", "--format", "{{.State.Running}}", $Container
    )
    if ($containerState.Output.Trim() -ne "true") {
        throw "$Container is not running"
    }

    $baselineMappings = Get-HostMappingSnapshot
    Assert-RequiredHostMappings -Snapshot $baselineMappings -Context "precondition"
    $baselineMappingSignature = Get-MappingSignature -Snapshot $baselineMappings

    $existingKeepers = @(Get-KeeperPids)
    if ($existingKeepers.Count -ne 0) {
        throw "A UDP port keeper is already running: $($existingKeepers -join ',')"
    }

    $oldServers = @(Get-ContainerPids -ProcessName "ROBOTSERVER")
    if ($oldServers.Count -ne 1) {
        throw "Expected exactly one ROBOTSERVER before restart; found $($oldServers.Count): $($oldServers -join ',')"
    }
    $oldServerPid = $oldServers[0]
    $oldSessionId = Get-ContainerSessionId -ProcessId $oldServerPid
    $oldInputKeepers = @(Get-RobotServerInputKeeperPids)
    if ($oldInputKeepers.Count -ne 1 -or
        (Get-ContainerSessionId -ProcessId $oldInputKeepers[0]) -ne $oldSessionId) {
        throw "Expected exactly one RobotServer stdin keeper in session $oldSessionId; found $($oldInputKeepers -join ',')"
    }

    $display = Get-ContainerDisplay -ServerPid $oldServerPid
    if (-not $display -or $display -notmatch '^:\d+(?:\.\d+)?$') {
        throw "No valid live X display was found for RobotServer"
    }

    $keeperSource = Join-Path $PSScriptRoot "port_keeper.py"
    if (-not (Test-Path -LiteralPath $keeperSource -PathType Leaf)) {
        throw "Missing committed keeper $keeperSource"
    }

    if ($PreflightOnly) {
        Write-Host "Preflight passed: one ROBOTSERVER PID $oldServerPid, no keeper, required mappings owned by Docker, DISPLAY=$display"
        return
    }

    $esp32Ip = Get-Esp32Ip
    Send-MotorStop -Esp32Ip $esp32Ip
    $faultInjectionStarted = $true

    $runId = [Guid]::NewGuid().ToString("N")
    $temporaryDirectory = "/tmp/robotserver-restart-$runId"
    $keeperRemote = "$temporaryDirectory/port_keeper.py"
    $readyRemote = "$temporaryDirectory/ready.json"
    $keeperLog = "$temporaryDirectory/keeper.log"

    $null = Invoke-DockerCommand -Arguments @(
        "exec", $Container, "mkdir", "-p", $temporaryDirectory
    )
    $copyOutput = @(& docker cp $keeperSource "${Container}:$keeperRemote" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to copy committed keeper into ${Container}: $($copyOutput -join [Environment]::NewLine)"
    }

    $keeperCommand = "setsid nohup python3 '$keeperRemote' --seconds $KeeperSeconds --ports 5005 --ready-file '$readyRemote' > '$keeperLog' 2>&1 < /dev/null & echo " + '$!'
    $keeperStart = Invoke-DockerCommand -Arguments @(
        "exec", $Container, "bash", "-lc", $keeperCommand
    )
    if (-not [int]::TryParse($keeperStart.Output.Trim(), [ref]$keeperPid)) {
        throw "Keeper launch did not return a PID: $($keeperStart.Output)"
    }

    $keeperReady = Wait-ForCondition -TimeoutSeconds 5 -Condition {
        $ready = Invoke-DockerCommand -Arguments @(
            "exec", $Container, "test", "-f", $readyRemote
        ) -AllowedExitCodes @(0, 1)
        $ready.ExitCode -eq 0
    }
    if (-not $keeperReady) {
        $log = Invoke-DockerCommand -Arguments @(
            "exec", $Container, "bash", "-lc", "cat '$keeperLog' 2>/dev/null || true"
        )
        throw "UDP 5005 keeper did not become ready: $($log.Output)"
    }

    $readyJson = Invoke-DockerCommand -Arguments @(
        "exec", $Container, "cat", $readyRemote
    )
    $readyState = $readyJson.Output | ConvertFrom-Json
    if ([int]$readyState.pid -ne $keeperPid) {
        throw "Keeper launch PID $keeperPid did not match readiness PID $($readyState.pid)"
    }
    if (@($readyState.ports).Count -ne 1 -or
        [int]$readyState.ports[0] -ne 5005) {
        throw "Keeper PID $keeperPid reported unexpected readiness ports: $($readyState.ports -join ',')"
    }
    $keeperOwnsPort = Wait-ForCondition -TimeoutSeconds 3 -Condition {
        Test-ProcessOwnsUdpPort -ProcessId $keeperPid -Port 5005
    }
    if (-not $keeperOwnsPort) {
        throw "Keeper readiness file was valid, but PID $keeperPid did not prove ownership of UDP 5005 within 3 seconds"
    }

    Stop-ContainerSession -SessionId $oldSessionId
    if (@(Get-ContainerPids -ProcessName "ROBOTSERVER").Count -ne 0) {
        throw "Old ROBOTSERVER process did not stop cleanly"
    }

    Start-RobotServerDetached `
        -Display $display `
        -AutonomousAllowed $autonomousValue `
        -EnableBoundedDiagnostics (-not $SkipWebcamOutputCheck) `
        -LogPath $robotServerLog

    $serverStarted = Wait-ForCondition -TimeoutSeconds $StartupTimeoutSeconds -Condition {
        $servers = @(Get-ContainerPids -ProcessName "ROBOTSERVER")
        $servers.Count -eq 1
    }
    if (-not $serverStarted) {
        throw "Exactly one new ROBOTSERVER did not appear within $StartupTimeoutSeconds seconds"
    }
    $newServers = @(Get-ContainerPids -ProcessName "ROBOTSERVER")
    if ($newServers.Count -ne 1 -or $newServers[0] -eq $oldServerPid) {
        throw "ROBOTSERVER PID validation failed: old=$oldServerPid current=$($newServers -join ',')"
    }
    $newServerPid = $newServers[0]
    $observedSessionId = Get-ContainerSessionId -ProcessId $newServerPid
    if ($observedSessionId -eq $oldSessionId) {
        throw "New ROBOTSERVER PID $newServerPid reused the old session $oldSessionId"
    }
    $newSessionId = $observedSessionId

    $handshakeReturned = Wait-ForCondition -TimeoutSeconds $StartupTimeoutSeconds -Condition {
        $result = Invoke-DockerCommand -Arguments @(
            "exec", $Container, "grep", "-q", "Handshake Successful", $robotServerLog
        ) -AllowedExitCodes @(0, 1, 2)
        $result.ExitCode -eq 0
    }
    if (-not $handshakeReturned) {
        throw "The new ROBOTSERVER did not record a real ESP32 handshake"
    }

    $chunkSetsBeforeKeeperRemoval = Get-LatestChunkSetCount -LogPath $robotServerLog
    Stop-Keeper -KeeperPid $keeperPid -TemporaryDirectory $temporaryDirectory
    $keeperPid = 0
    $temporaryDirectory = $null

    if (@(Get-KeeperPids).Count -ne 0) {
        throw "A port keeper remained after cleanup"
    }

    for ($sample = 0; $sample -lt 12; $sample++) {
        $snapshot = Get-HostMappingSnapshot
        Assert-RequiredHostMappings -Snapshot $snapshot -Context "post-keeper sample $sample"
        if ((Get-MappingSignature -Snapshot $snapshot) -ne $baselineMappingSignature) {
            throw "Host mapping ownership changed during post-keeper sample $sample"
        }
        Start-Sleep -Milliseconds 250
    }

    if (-not (Test-ProcessOwnsUdpPort -ProcessId $newServerPid -Port 5005)) {
        throw "New ROBOTSERVER PID $newServerPid does not own container UDP 5005"
    }

    if (-not $SkipWebcamOutputCheck) {
        $outputReturned = Wait-ForCondition -TimeoutSeconds $OutputTimeoutSeconds -Condition {
            (Get-LatestChunkSetCount -LogPath $robotServerLog) -gt $chunkSetsBeforeKeeperRemoval
        }
        if (-not $outputReturned) {
            throw "No new webcam chunk set was observed after keeper removal"
        }
    }

    $finalServers = @(Get-ContainerPids -ProcessName "ROBOTSERVER")
    if ($finalServers.Count -ne 1 -or $finalServers[0] -ne $newServerPid) {
        throw "Final ROBOTSERVER process count or identity changed unexpectedly"
    }
    $finalInputKeepers = @(Get-RobotServerInputKeeperPids)
    if ($finalInputKeepers.Count -ne 1 -or
        (Get-ContainerSessionId -ProcessId $finalInputKeepers[0]) -ne $newSessionId) {
        throw "Final RobotServer stdin keeper count or session is incorrect"
    }

    Write-Host "ROBOTSERVER protected restart passed: old=$oldServerPid new=$newServerPid session=$newSessionId DISPLAY=$display"
    Write-Host "Windows TCP 5005, UDP 5005, UDP 5006, and UDP 8888 retained their Docker owners"
    if ($SkipWebcamOutputCheck) {
        Write-Warning "Webcam application output was not required for this run"
    } else {
        Write-Host "New webcam chunk sets were observed after the keeper was removed"
    }
} catch {
    $originalError = $_
    if ($faultInjectionStarted) {
        $serversAfterFailure = @(Get-ContainerPids -ProcessName "ROBOTSERVER")
        if ($serversAfterFailure.Count -eq 0 -and $display) {
            Write-Warning "Restart failed with no ROBOTSERVER; attempting one bounded fallback launch while the keeper is still active"
            try {
                Start-RobotServerDetached `
                    -Display $display `
                    -AutonomousAllowed $autonomousValue `
                    -EnableBoundedDiagnostics $false `
                    -LogPath $robotServerLog
                $fallbackStarted = Wait-ForCondition `
                    -TimeoutSeconds $StartupTimeoutSeconds `
                    -Condition { @(Get-ContainerPids -ProcessName "ROBOTSERVER").Count -eq 1 }
                if ($fallbackStarted) {
                    $fallbackPids = @(Get-ContainerPids -ProcessName "ROBOTSERVER")
                    $fallbackPid = $fallbackPids[0]
                    $fallbackSession = Get-ContainerSessionId -ProcessId $fallbackPid
                    Write-Warning "Fallback restored ROBOTSERVER PID $fallbackPid in session $fallbackSession"
                } else {
                    Write-Warning "Fallback did not restore exactly one ROBOTSERVER"
                }
            } catch {
                Write-Warning "Fallback launch failed: $($_.Exception.Message)"
            }
        }
    }
    throw $originalError
} finally {
    try {
        if ($keeperPid -or $temporaryDirectory) {
            Stop-Keeper -KeeperPid $keeperPid -TemporaryDirectory $temporaryDirectory
        }
    } finally {
        if ($faultInjectionStarted) {
            Send-MotorStop -Esp32Ip $esp32Ip
        }
    }
}
