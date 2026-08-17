<#
Run synchronized, bounded stability telemetry without binding production sensor
or webcam ports. Windows netstat is the authority for host socket ownership.

This is an observer only: it does not restart services or send robot commands.
#>
[CmdletBinding()]
param(
    [ValidateRange(2, 86400)]
    [int]$Seconds = 60,
    [Parameter(Mandatory)]
    [string]$OutputDir,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string]$Tag = "health",
    [ValidateRange(100, 5000)]
    [int]$PortSampleMilliseconds = 250,
    [ValidateRange(1, 300)]
    [int]$PiSampleSeconds = 5,
    [ValidateRange(1, 65535)]
    [int]$EspLogPort = 8890,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
    [string]$RosContainer = "robot_brain",
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
    [string]$ServerContainer = "my-robot-server",
    [switch]$SkipPi,
    [switch]$AllowOverwrite,
    [switch]$PreflightOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int[]]$AllowedExitCodes = @(0)
    )

    $lines = @(& $FilePath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($AllowedExitCodes -notcontains $exitCode) {
        $rendered = $Arguments -join " "
        $detail = $lines -join [Environment]::NewLine
        throw "$FilePath $rendered failed with exit code ${exitCode}: $detail"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = [string]($lines -join [Environment]::NewLine)
    }
}

function Invoke-DockerCommand {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0)
    )
    return Invoke-NativeCommand -FilePath "docker" -Arguments $Arguments -AllowedExitCodes $AllowedExitCodes
}

function Assert-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command is not available: $Name"
    }
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Start-ChildCollector {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$ReadyPath,
        [Parameter(Mandatory)][string]$StopPath,
        [Parameter(Mandatory)][string]$StdoutPath,
        [Parameter(Mandatory)][string]$StderrPath,
        [int]$ReadyTimeoutSeconds = 5
    )

    $powerShellPath = Join-Path $PSHOME "pwsh.exe"
    if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
        throw "PowerShell executable is missing: $powerShellPath"
    }
    $processArguments = @(
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-File", $ScriptPath
    ) + $Arguments
    $renderedArguments = @($processArguments | ForEach-Object {
        ConvertTo-ProcessArgument -Value ([string]$_)
    })
    $process = Start-Process `
        -FilePath $powerShellPath `
        -ArgumentList $renderedArguments `
        -WindowStyle Hidden `
        -PassThru `
        -RedirectStandardOutput $StdoutPath `
        -RedirectStandardError $StderrPath

    try {
        $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            $process.Refresh()
            if ($process.HasExited) {
                $stderr = if (Test-Path -LiteralPath $StderrPath) {
                    Get-Content -LiteralPath $StderrPath -Raw
                } else { "" }
                throw "Collector $ScriptPath exited before readiness (exit $($process.ExitCode)): $stderr"
            }
            if (Test-Path -LiteralPath $ReadyPath -PathType Leaf) {
                $ready = Get-Content -LiteralPath $ReadyPath -Raw | ConvertFrom-Json
                if ([int]$ready.pid -ne $process.Id) {
                    throw "Collector readiness PID $($ready.pid) does not match process PID $($process.Id)"
                }
                return [pscustomobject]@{
                    Process = $process
                    Command = @($powerShellPath) + $processArguments
                    Ready = $ready
                }
            }
            Start-Sleep -Milliseconds 100
        }
        throw "Collector $ScriptPath did not become ready within $ReadyTimeoutSeconds seconds"
    } catch {
        if (-not $process.HasExited) {
            [System.IO.File]::WriteAllText($StopPath, (Get-Date).ToString("o"))
            $process.WaitForExit(2000) | Out-Null
            $process.Refresh()
        }
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $process.WaitForExit(2000) | Out-Null
        }
        throw
    }
}

function Stop-ChildCollector {
    param(
        [Parameter(Mandatory)]$Collector,
        [Parameter(Mandatory)][string]$StopPath,
        [int]$TimeoutSeconds = 5
    )

    [System.IO.File]::WriteAllText($StopPath, (Get-Date).ToString("o"))
    $process = $Collector.Process
    if (-not $process.HasExited) {
        $process.WaitForExit($TimeoutSeconds * 1000) | Out-Null
        $process.Refresh()
    }
    $forced = $false
    if (-not $process.HasExited) {
        $forced = $true
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(2000) | Out-Null
        $process.Refresh()
    }
    if (-not $process.HasExited) {
        throw "Collector PID $($process.Id) did not stop"
    }
    return [pscustomobject]@{
        Pid = $process.Id
        ExitCode = $process.ExitCode
        Forced = $forced
    }
}

function Test-ContainerProcess {
    param(
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][int]$ProcessId
    )
    $result = Invoke-DockerCommand -Arguments @(
        "exec", $Container, "kill", "-0", [string]$ProcessId
    ) -AllowedExitCodes @(0, 1)
    return $result.ExitCode -eq 0
}

function Wait-ContainerProcessExit {
    param(
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][int]$ProcessId,
        [int]$TimeoutSeconds = 5
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-ContainerProcess -Container $Container -ProcessId $ProcessId)) {
            return $true
        }
        Start-Sleep -Milliseconds 200
    }
    return -not (Test-ContainerProcess -Container $Container -ProcessId $ProcessId)
}

function Get-ContainerState {
    param([Parameter(Mandatory)][string]$Container)
    $stateResult = Invoke-DockerCommand -Arguments @(
        "inspect", "--format", "{{json .State}}", $Container
    )
    $restartResult = Invoke-DockerCommand -Arguments @(
        "inspect", "--format", "{{.RestartCount}}", $Container
    )
    $state = $stateResult.Output | ConvertFrom-Json
    return [ordered]@{
        running = [bool]$state.Running
        pid = [int]$state.Pid
        started_at = $state.StartedAt
        restart_count = [int]$restartResult.Output.Trim()
        health = if ($state.PSObject.Properties.Name -contains "Health" -and $state.Health) {
            $state.Health.Status
        } else {
            $null
        }
    }
}

function Get-ContainerPids {
    param(
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string[]]$PgrepArguments
    )
    $result = Invoke-DockerCommand -Arguments (@("exec", $Container, "pgrep") + $PgrepArguments) `
        -AllowedExitCodes @(0, 1)
    if ($result.ExitCode -eq 1 -or -not $result.Output.Trim()) {
        return @()
    }
    return @($result.Output -split "\r?\n" | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
}

function Get-PiSnapshot {
    $piCommand = @'
pid=$(systemctl --user show robot-webcam.service -p MainPID --value 2>/dev/null)
restarts=$(systemctl --user show robot-webcam.service -p NRestarts --value 2>/dev/null)
active=$(systemctl --user is-active robot-webcam.service 2>/dev/null)
sub=$(systemctl --user show robot-webcam.service -p SubState --value 2>/dev/null)
stats=$(ps -o rss=,pcpu=,etimes= -p "$pid" 2>/dev/null | xargs)
camera=$([ -e /dev/video0 ] && echo present || echo missing)
camera_id=$(udevadm info --query=property --name=/dev/video0 2>/dev/null | grep -E '^(ID_VENDOR|ID_MODEL)=' | tr '\n' ',' | sed 's/,$//')
throttle=$(vcgencmd get_throttled 2>/dev/null)
temp=$(vcgencmd measure_temp 2>/dev/null)
voltage=$(vcgencmd pmic_read_adc EXT5V_V 2>/dev/null)
cooling=$(for f in /sys/class/thermal/cooling_device*/type; do [ -r "$f" ] || continue; printf '%s=%s,' "$f" "$(cat "$f")"; done | sed 's/,$//')
fan=$(for f in /sys/class/hwmon/hwmon*/fan*_input; do [ -r "$f" ] || continue; printf '%s=%s,' "$f" "$(cat "$f")"; done | sed 's/,$//')
kernel_power_thermal=$(journalctl -k -n 300 --no-pager 2>/dev/null | grep -Ei 'under.?voltage|voltage.*low|throttl|thermal' | tail -n 5 | tr '\n|' ',/' | sed 's/,$//')
camera_log=$(journalctl --user -u robot-webcam.service -n 40 --no-pager 2>/dev/null | grep -E '\[CAM-DIAG\]|\[CAMERA\]|Failed to grab|reopen|Starting video|send.*(fail|error)' | tail -n 1 | tr '|' '/')
printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s' "$active" "$sub" "$pid" "$restarts" "$stats" "$camera" "$camera_id" "$throttle" "$temp" "$voltage" "$cooling" "$fan" "$kernel_power_thermal" "$camera_log"
'@
    $result = Invoke-NativeCommand -FilePath "ssh" -Arguments @(
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=5",
        "robopi", $piCommand
    ) -AllowedExitCodes @(0, 255)
    if ($result.ExitCode -ne 0) {
        return [ordered]@{
            ok = $false
            exit_code = $result.ExitCode
            error = $result.Output
        }
    }
    $fields = @($result.Output -split [char]31)
    if ($fields.Count -ne 14) {
        return [ordered]@{
            ok = $false
            exit_code = 0
            error = "Pi response had $($fields.Count) fields instead of 14"
            raw = $result.Output
        }
    }
    return [ordered]@{
        ok = $true
        service_active = $fields[0]
        service_substate = $fields[1]
        service_pid = $fields[2]
        service_restarts = $fields[3]
        process_stats = $fields[4]
        video0 = $fields[5]
        camera_identity = $fields[6]
        throttle = $fields[7]
        temperature = $fields[8]
        pmic_ext5v = $fields[9]
        cooling_devices = $fields[10]
        fan_inputs = $fields[11]
        kernel_power_thermal = $fields[12]
        latest_camera_log = $fields[13]
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    [System.IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 15),
        [System.Text.UTF8Encoding]::new($false)
    )
}

$portCollectorScript = Join-Path $PSScriptRoot "windows-port-collector.ps1"
$espCollectorScript = Join-Path $PSScriptRoot "esp32-log-collector.ps1"
$resolvedOutputDir = [System.IO.Path]::GetFullPath($OutputDir)
$paths = [ordered]@{
    manifest = Join-Path $resolvedOutputDir "$Tag-manifest.json"
    host = Join-Path $resolvedOutputDir "$Tag-host.jsonl"
    ports = Join-Path $resolvedOutputDir "$Tag-ports.jsonl"
    port_ready = Join-Path $resolvedOutputDir "$Tag-port-ready.json"
    port_stop = Join-Path $resolvedOutputDir "$Tag-port.stop"
    port_stdout = Join-Path $resolvedOutputDir "$Tag-port.stdout.txt"
    port_stderr = Join-Path $resolvedOutputDir "$Tag-port.stderr.txt"
    esp = Join-Path $resolvedOutputDir "$Tag-esp32.jsonl"
    esp_ready = Join-Path $resolvedOutputDir "$Tag-esp32-ready.json"
    esp_stop = Join-Path $resolvedOutputDir "$Tag-esp32.stop"
    esp_stdout = Join-Path $resolvedOutputDir "$Tag-esp32.stdout.txt"
    esp_stderr = Join-Path $resolvedOutputDir "$Tag-esp32.stderr.txt"
    ros = Join-Path $resolvedOutputDir "$Tag-ros.jsonl"
    ros_stdout = Join-Path $resolvedOutputDir "$Tag-ros.stdout.txt"
    ros_stderr = Join-Path $resolvedOutputDir "$Tag-ros.stderr.txt"
    robotserver = Join-Path $resolvedOutputDir "$Tag-robotserver-tail.txt"
    bridges = Join-Path $resolvedOutputDir "$Tag-bridge-tail.txt"
}
$evidencePaths = [ordered]@{
    manifest = $paths.manifest
    host = $paths.host
    ports = $paths.ports
    port_ready = $paths.port_ready
    port_stdout = $paths.port_stdout
    port_stderr = $paths.port_stderr
    esp32 = $paths.esp
    esp32_ready = $paths.esp_ready
    esp32_stdout = $paths.esp_stdout
    esp32_stderr = $paths.esp_stderr
    ros = $paths.ros
    ros_stdout = $paths.ros_stdout
    ros_stderr = $paths.ros_stderr
    robotserver = $paths.robotserver
    bridges = $paths.bridges
}

foreach ($command in @("docker", "netstat")) {
    Assert-CommandAvailable -Name $command
}
if (-not $SkipPi) {
    Assert-CommandAvailable -Name "ssh"
}
foreach ($script in @($portCollectorScript, $espCollectorScript)) {
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        throw "Required committed collector is missing: $script"
    }
}

foreach ($container in @($RosContainer, $ServerContainer)) {
    $state = Get-ContainerState -Container $container
    if (-not $state.running) {
        throw "Required container is not running: $container"
    }
}
$rosScriptCheck = Invoke-DockerCommand -Arguments @(
    "exec", $RosContainer, "test", "-f", "/root/code/tools/stability_ros_collector.py"
) -AllowedExitCodes @(0, 1)
if ($rosScriptCheck.ExitCode -ne 0) {
    throw "ROS collector is missing in ${RosContainer}:/root/code/tools/stability_ros_collector.py"
}
$existingRosCollector = Invoke-DockerCommand -Arguments @(
    "exec", $RosContainer, "pgrep", "-f", "^python3 /root/code/tools/stability_ros_collector.py"
) -AllowedExitCodes @(0, 1)
if ($existingRosCollector.ExitCode -eq 0) {
    throw "A ROS stability collector is already running: $($existingRosCollector.Output)"
}

$existingEspOwner = @(& netstat -ano -p UDP | Where-Object {
    $_ -match "^\s*UDP\s+\S+:$EspLogPort\s+\*:\*\s+\d+\s*$"
})
if ($LASTEXITCODE -ne 0) {
    throw "Windows netstat UDP inspection failed with exit code $LASTEXITCODE"
}
if ($existingEspOwner.Count -gt 0) {
    throw "UDP $EspLogPort is already owned; stop the existing ESP32 diagnostic collector first: $($existingEspOwner -join '; ')"
}

$existingPaths = @($paths.Values | Where-Object { Test-Path -LiteralPath $_ })
if ($existingPaths.Count -gt 0 -and -not $AllowOverwrite) {
    throw "Evidence already exists. Use a new OutputDir/Tag, or explicitly pass -AllowOverwrite: $($existingPaths -join ', ')"
}
if ($PreflightOnly) {
    Write-Host "Preflight passed: dependencies and both containers are available; no ESP32 diagnostic collector owns UDP $EspLogPort."
    if ($existingPaths.Count -gt 0) {
        Write-Warning "The requested evidence names already exist and would be replaced because -AllowOverwrite was supplied."
    }
    return
}

[System.IO.Directory]::CreateDirectory($resolvedOutputDir) | Out-Null
if ($AllowOverwrite) {
    foreach ($path in $existingPaths) {
        Remove-Item -LiteralPath $path -Force
    }
}

$runId = [Guid]::NewGuid().ToString("N")
$rosTemporaryDirectory = "/tmp/stability-health-$runId"
$rosContainerPath = "$rosTemporaryDirectory/ros.jsonl"
$rosStdoutPath = "$rosTemporaryDirectory/ros.stdout.txt"
$rosStderrPath = "$rosTemporaryDirectory/ros.stderr.txt"
$maximumChildSeconds = $Seconds + 30
$portCollector = $null
$espCollector = $null
$rosPid = 0
$hostWriter = $null
$started = $null
$observationEnded = $null
$ended = $null
$primaryError = $null
$cleanupErrors = [System.Collections.Generic.List[string]]::new()
$piSuccesses = 0
$hostSamples = 0
$manifest = [ordered]@{
    kind = "stability_health_manifest"
    run_id = $runId
    tag = $Tag
    requested_seconds = $Seconds
    output_directory = $resolvedOutputDir
    main_pid = $PID
    main_command = $MyInvocation.Line
    status = "starting"
    started_at = $null
    observation_ended_at = $null
    ended_at = $null
    collectors = [ordered]@{}
    files = $evidencePaths
    cleanup_errors = @()
    error = $null
}

try {
    $hostStream = [System.IO.FileStream]::new(
        $paths.host,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read
    )
    $hostWriter = [System.IO.StreamWriter]::new($hostStream, [System.Text.UTF8Encoding]::new($false))
    $hostWriter.AutoFlush = $true

    $portArguments = @(
        "-OutputPath", $paths.ports,
        "-ReadyPath", $paths.port_ready,
        "-StopPath", $paths.port_stop,
        "-MaximumSeconds", [string]$maximumChildSeconds,
        "-IntervalMilliseconds", [string]$PortSampleMilliseconds
    )
    $portCollector = Start-ChildCollector `
        -ScriptPath $portCollectorScript `
        -Arguments $portArguments `
        -ReadyPath $paths.port_ready `
        -StopPath $paths.port_stop `
        -StdoutPath $paths.port_stdout `
        -StderrPath $paths.port_stderr
    $manifest.collectors.windows_ports = [ordered]@{
        pid = $portCollector.Process.Id
        command = $portCollector.Command
        ready = $portCollector.Ready
        maximum_seconds = $maximumChildSeconds
    }

    $espArguments = @(
        "-OutputPath", $paths.esp,
        "-ReadyPath", $paths.esp_ready,
        "-StopPath", $paths.esp_stop,
        "-MaximumSeconds", [string]$maximumChildSeconds,
        "-LogPort", [string]$EspLogPort
    )
    $espCollector = Start-ChildCollector `
        -ScriptPath $espCollectorScript `
        -Arguments $espArguments `
        -ReadyPath $paths.esp_ready `
        -StopPath $paths.esp_stop `
        -StdoutPath $paths.esp_stdout `
        -StderrPath $paths.esp_stderr
    $manifest.collectors.esp32 = [ordered]@{
        pid = $espCollector.Process.Id
        command = $espCollector.Command
        ready = $espCollector.Ready
        maximum_seconds = $maximumChildSeconds
    }

    $null = Invoke-DockerCommand -Arguments @(
        "exec", $RosContainer, "mkdir", "-p", $rosTemporaryDirectory
    )
    $rosDuration = $Seconds
    $rosCommand = 'setsid bash -lc "source /opt/ros/humble/setup.bash && exec python3 /root/code/tools/stability_ros_collector.py --duration {0} --output {1}" > {2} 2> {3} < /dev/null & echo $!' -f `
        $rosDuration, $rosContainerPath, $rosStdoutPath, $rosStderrPath
    $rosStart = Invoke-DockerCommand -Arguments @(
        "exec", $RosContainer, "bash", "-lc", $rosCommand
    )
    if (-not [int]::TryParse($rosStart.Output.Trim(), [ref]$rosPid)) {
        throw "ROS collector launch did not return a PID: $($rosStart.Output)"
    }
    $rosReadyDeadline = (Get-Date).AddSeconds(5)
    $rosReady = $false
    while ((Get-Date) -lt $rosReadyDeadline) {
        $readyCheck = Invoke-DockerCommand -Arguments @(
            "exec", $RosContainer, "bash", "-lc",
            "kill -0 $rosPid 2>/dev/null && test -f $rosContainerPath"
        ) -AllowedExitCodes @(0, 1)
        if ($readyCheck.ExitCode -eq 0) {
            $rosReady = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $rosReady) {
        throw "ROS collector PID $rosPid did not become ready"
    }
    $rosHash = Invoke-DockerCommand -Arguments @(
        "exec", $RosContainer, "sha256sum", "/root/code/tools/stability_ros_collector.py"
    )
    $manifest.collectors.ros = [ordered]@{
        pid = $rosPid
        command = $rosCommand
        container = $RosContainer
        duration_seconds = $rosDuration
        script_sha256 = ($rosHash.Output -split '\s+')[0]
    }

    $started = Get-Date
    $manifest.started_at = $started.ToString("o")
    $manifest.status = "running"
    Write-JsonFile -Path $paths.manifest -Value $manifest
    $deadline = $started.AddSeconds($Seconds)
    $sample = 0
    $lastDockerStats = $null
    $lastPi = $null
    $nextPiSample = $started

    while ((Get-Date) -lt $deadline) {
        $iterationStarted = Get-Date
        $sample++
        $hostSamples++

        $containerStates = [ordered]@{
            $RosContainer = Get-ContainerState -Container $RosContainer
            $ServerContainer = Get-ContainerState -Container $ServerContainer
        }
        $processes = [ordered]@{
            ros_launch = @(Get-ContainerPids -Container $RosContainer -PgrepArguments @("-f", "^/usr/bin/python3 /opt/ros/humble/bin/ros2 launch launch_all.py$"))
            imu_bridge = @(Get-ContainerPids -Container $RosContainer -PgrepArguments @("-f", "^python3 /root/code/imu_bridge.py$"))
            lidar_bridge = @(Get-ContainerPids -Container $RosContainer -PgrepArguments @("-f", "^python3 /root/code/main.py$"))
            rf2o = @(Get-ContainerPids -Container $RosContainer -PgrepArguments @("-x", "rf2o_laser_odom"))
            ekf = @(Get-ContainerPids -Container $RosContainer -PgrepArguments @("-x", "ekf_node"))
            slam = @(Get-ContainerPids -Container $RosContainer -PgrepArguments @("-x", "async_slam_tool"))
            rviz = @(Get-ContainerPids -Container $RosContainer -PgrepArguments @("-x", "rviz2"))
            robotserver = @(Get-ContainerPids -Container $ServerContainer -PgrepArguments @("-x", "ROBOTSERVER"))
            stability_ros_collector = @($rosPid)
            windows_port_collector = @($portCollector.Process.Id)
            esp32_log_collector = @($espCollector.Process.Id)
        }

        if (($sample - 1) % 5 -eq 0) {
            $statsResult = Invoke-NativeCommand -FilePath "docker" -Arguments @(
                "stats", "--no-stream", "--format", "{{json .}}", $RosContainer, $ServerContainer
            )
            $lastDockerStats = @($statsResult.Output -split "\r?\n" | Where-Object { $_ } | ForEach-Object {
                $_ | ConvertFrom-Json
            })
        }
        if (-not $SkipPi -and (Get-Date) -ge $nextPiSample) {
            $lastPi = Get-PiSnapshot
            if ($lastPi.ok) {
                $piSuccesses++
            }
            $nextPiSample = (Get-Date).AddSeconds($PiSampleSeconds)
        }

        $record = [ordered]@{
            kind = "host_health"
            timestamp = $iterationStarted.ToString("o")
            elapsed_s = ((Get-Date) - $started).TotalSeconds
            sample = $sample
            containers = $containerStates
            processes = $processes
            docker_stats = $lastDockerStats
            pi = $lastPi
        }
        $hostWriter.WriteLine(($record | ConvertTo-Json -Depth 12 -Compress))

        $remaining = 1.0 - ((Get-Date) - $iterationStarted).TotalSeconds
        if ($remaining -gt 0) {
            Start-Sleep -Milliseconds ([int]($remaining * 1000))
        }
    }

    # End the Windows observation window before waiting for the independently
    # bounded ROS collector to flush its final record.
    $observationEnded = Get-Date
    $manifest.observation_ended_at = $observationEnded.ToString("o")
    [System.IO.File]::WriteAllText($paths.port_stop, (Get-Date).ToString("o"))
    [System.IO.File]::WriteAllText($paths.esp_stop, (Get-Date).ToString("o"))

    if (-not (Wait-ContainerProcessExit -Container $RosContainer -ProcessId $rosPid -TimeoutSeconds 5)) {
        throw "ROS collector PID $rosPid exceeded its bounded duration"
    }
} catch {
    $primaryError = $_
} finally {
    $ended = Get-Date
    if ($hostWriter) {
        $hostWriter.Dispose()
    }

    foreach ($item in @(
        @{ Name = "windows_ports"; Collector = $portCollector; StopPath = $paths.port_stop },
        @{ Name = "esp32"; Collector = $espCollector; StopPath = $paths.esp_stop }
    )) {
        if ($item.Collector) {
            try {
                $stopped = Stop-ChildCollector -Collector $item.Collector -StopPath $item.StopPath
                $manifest.collectors[$item.Name].exit_code = $stopped.ExitCode
                $manifest.collectors[$item.Name].forced_stop = $stopped.Forced
                if ($stopped.ExitCode -ne 0) {
                    throw "$($item.Name) collector exited with code $($stopped.ExitCode)"
                }
            } catch {
                $cleanupErrors.Add($_.Exception.Message)
            }
        }
    }

    if ($rosPid -gt 0) {
        try {
            if (Test-ContainerProcess -Container $RosContainer -ProcessId $rosPid) {
                $null = Invoke-DockerCommand -Arguments @(
                    "exec", $RosContainer, "kill", "-INT", [string]$rosPid
                ) -AllowedExitCodes @(0, 1)
                if (-not (Wait-ContainerProcessExit -Container $RosContainer -ProcessId $rosPid -TimeoutSeconds 3)) {
                    $null = Invoke-DockerCommand -Arguments @(
                        "exec", $RosContainer, "kill", "-TERM", [string]$rosPid
                    ) -AllowedExitCodes @(0, 1)
                }
            }
            if (Test-ContainerProcess -Container $RosContainer -ProcessId $rosPid) {
                throw "ROS collector PID $rosPid remained after cleanup"
            }
        } catch {
            $cleanupErrors.Add($_.Exception.Message)
        }
    }

    if ($rosTemporaryDirectory) {
        foreach ($copy in @(
            @{ Remote = $rosContainerPath; Local = $paths.ros },
            @{ Remote = $rosStdoutPath; Local = $paths.ros_stdout },
            @{ Remote = $rosStderrPath; Local = $paths.ros_stderr }
        )) {
            try {
                $exists = Invoke-DockerCommand -Arguments @(
                    "exec", $RosContainer, "test", "-f", $copy.Remote
                ) -AllowedExitCodes @(0, 1)
                if ($exists.ExitCode -eq 0) {
                    $null = Invoke-NativeCommand -FilePath "docker" -Arguments @(
                        "cp", "${RosContainer}:$($copy.Remote)", $copy.Local
                    )
                }
            } catch {
                $cleanupErrors.Add("Failed to collect $($copy.Remote): $($_.Exception.Message)")
            }
        }
        try {
            $null = Invoke-DockerCommand -Arguments @(
                "exec", $RosContainer, "rm", "-rf", $rosTemporaryDirectory
            )
        } catch {
            $cleanupErrors.Add("Failed to remove ${rosTemporaryDirectory}: $($_.Exception.Message)")
        }
    }

    try {
        $serverLog = Invoke-DockerCommand -Arguments @(
            "exec", $ServerContainer, "bash", "-lc",
            'pid=$(pgrep -xo ROBOTSERVER); test -n "$pid" && readlink -f /proc/$pid/fd/1'
        ) -AllowedExitCodes @(0, 1)
        if ($serverLog.ExitCode -eq 0 -and $serverLog.Output.Trim().StartsWith("/tmp/")) {
            $tailResult = Invoke-DockerCommand -Arguments @(
                "exec", $ServerContainer, "tail", "-n", "1000", $serverLog.Output.Trim()
            )
            [System.IO.File]::WriteAllText($paths.robotserver, $tailResult.Output)
        }
    } catch {
        $cleanupErrors.Add("Failed to collect bounded RobotServer tail: $($_.Exception.Message)")
    }

    try {
        $bridgeResult = Invoke-DockerCommand -Arguments @(
            "exec", $RosContainer, "bash", "-lc",
            'for p in $(pgrep -f "^python3 /root/code/(imu_bridge.py|main.py)$"); do for f in /root/.ros/log/python3_${p}_*.log; do test -f "$f" || continue; echo FILE=$f; tail -n 120 "$f"; done; done'
        )
        [System.IO.File]::WriteAllText($paths.bridges, $bridgeResult.Output)
    } catch {
        $cleanupErrors.Add("Failed to collect ROS bridge tails: $($_.Exception.Message)")
    }

    foreach ($stopPath in @($paths.port_stop, $paths.esp_stop)) {
        Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
    }
}

if (-not $primaryError -and $cleanupErrors.Count -eq 0) {
    try {
        $portRecords = @(Get-Content -LiteralPath $paths.ports | ForEach-Object { $_ | ConvertFrom-Json })
        $portRecordsInWindow = @($portRecords | Where-Object {
            $timestamp = [DateTimeOffset]::Parse($_.timestamp)
            $timestamp -ge [DateTimeOffset]$started -and $timestamp -le [DateTimeOffset]$observationEnded
        })
        $expectedPortSamples = [Math]::Floor(($Seconds * 1000) / $PortSampleMilliseconds)
        $minimumPortSamples = [Math]::Max(1, [Math]::Floor($expectedPortSamples * 0.75))
        if ($portRecordsInWindow.Count -lt $minimumPortSamples) {
            throw "Port collector produced $($portRecordsInWindow.Count) in-window samples; expected at least $minimumPortSamples"
        }
        $maxPortGap = @($portRecordsInWindow | ForEach-Object { $_.interval_from_previous_s } | Where-Object { $null -ne $_ } | Measure-Object -Maximum).Maximum
        $allowedPortGap = [Math]::Max(1.0, ($PortSampleMilliseconds / 1000.0) * 4)
        if ($null -ne $maxPortGap -and [double]$maxPortGap -gt $allowedPortGap) {
            throw "Port collector maximum sample gap was $maxPortGap seconds; allowed $allowedPortGap"
        }
        if ($hostSamples -lt 1) {
            throw "No host health samples were written"
        }
        if (-not (Test-Path -LiteralPath $paths.ros -PathType Leaf) -or (Get-Item -LiteralPath $paths.ros).Length -eq 0) {
            throw "ROS collector did not produce application-output records"
        }
        $rosLines = @(Get-Content -LiteralPath $paths.ros)
        $rosFirst = $rosLines[0] | ConvertFrom-Json
        if ($rosFirst.kind -ne "ros_health") {
            throw "ROS collector output has an unexpected format"
        }
        $rosLast = $rosLines[-1] | ConvertFrom-Json
        if ([double]$rosLast.elapsed_s -lt ($Seconds * 0.8)) {
            throw "ROS collector ended early at $($rosLast.elapsed_s) seconds for a $Seconds-second request"
        }
        $espRecords = @(Get-Content -LiteralPath $paths.esp | ForEach-Object { $_ | ConvertFrom-Json })
        if (@($espRecords | Where-Object { $_.kind -eq "esp32_collector_summary" }).Count -ne 1) {
            throw "ESP32 collector did not write exactly one completion summary"
        }
        $espDiagnosticsInWindow = @($espRecords | Where-Object {
            $_.kind -eq "esp32_diagnostic" -and
            [DateTimeOffset]::Parse($_.timestamp) -ge [DateTimeOffset]$started -and
            [DateTimeOffset]::Parse($_.timestamp) -le [DateTimeOffset]$observationEnded
        })
        if (-not $SkipPi -and $piSuccesses -eq 0) {
            throw "No Pi status sample succeeded"
        }
        $manifest.validation = [ordered]@{
            host_samples = $hostSamples
            port_samples = $portRecordsInWindow.Count
            port_samples_total = $portRecords.Count
            maximum_port_gap_s = $maxPortGap
            ros_records = $rosLines.Count
            esp32_diagnostics = $espDiagnosticsInWindow.Count
            esp32_diagnostics_total = @($espRecords | Where-Object { $_.kind -eq "esp32_diagnostic" }).Count
            pi_successful_samples = $piSuccesses
        }
    } catch {
        $primaryError = $_
    }
}

if (-not $primaryError -and $cleanupErrors.Count -gt 0) {
    $primaryError = [System.Management.Automation.ErrorRecord]::new(
        [System.Exception]::new("Collector cleanup or artifact capture failed: $($cleanupErrors -join '; ')"),
        "StabilityHealthCleanupFailed",
        [System.Management.Automation.ErrorCategory]::OperationStopped,
        $null
    )
}

$manifest.ended_at = $ended.ToString("o")
$manifest.cleanup_errors = @($cleanupErrors)
if ($primaryError) {
    $manifest.status = "failed"
    $manifest.error = $primaryError.Exception.Message
} else {
    $manifest.status = "complete"
}
Write-JsonFile -Path $paths.manifest -Value $manifest

if ($primaryError) {
    throw $primaryError
}

Write-Host "Collector complete and verified: $resolvedOutputDir" -ForegroundColor Green
Write-Host "Host=$hostSamples Port=$($manifest.validation.port_samples) ROS=$($manifest.validation.ros_records) ESP32=$($manifest.validation.esp32_diagnostics) Pi=$piSuccesses"
