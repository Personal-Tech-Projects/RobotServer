<#
Record authoritative Windows netstat ownership for the robot's published ports.
This helper is started and supervised by stability-health.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputPath,
    [Parameter(Mandatory)]
    [string]$ReadyPath,
    [Parameter(Mandatory)]
    [string]$StopPath,
    [ValidateRange(1, 86430)]
    [int]$MaximumSeconds,
    [ValidateRange(100, 5000)]
    [int]$IntervalMilliseconds = 250
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ProcessNameSafely {
    param([int]$ProcessId)

    try {
        return (Get-Process -Id $ProcessId -ErrorAction Stop).ProcessName
    } catch {
        return $null
    }
}
function Get-PortSnapshot {
    $lines = @(& netstat -ano)
    if ($LASTEXITCODE -ne 0) {
        throw "Windows netstat failed with exit code $LASTEXITCODE"
    }

    $requirements = [ordered]@{
        tcp5005 = @{ Protocol = "TCP"; Port = 5005; State = "LISTENING" }
        udp5005 = @{ Protocol = "UDP"; Port = 5005; State = $null }
        udp5006 = @{ Protocol = "UDP"; Port = 5006; State = $null }
        udp8888 = @{ Protocol = "UDP"; Port = 8888; State = $null }
    }

    $ports = [ordered]@{}
    foreach ($name in $requirements.Keys) {
        $requirement = $requirements[$name]
        $owners = @()
        foreach ($line in $lines) {
            if ($requirement.Protocol -eq "TCP") {
                $pattern = "^\s*TCP\s+(\S+:$($requirement.Port))\s+(\S+)\s+$($requirement.State)\s+(\d+)\s*$"
                if ($line -match $pattern) {
                    $pidValue = [int]$Matches[3]
                    $owners += [ordered]@{
                        pid = $pidValue
                        process_name = Get-ProcessNameSafely -ProcessId $pidValue
                        local_address = $Matches[1]
                        remote_address = $Matches[2]
                        state = $requirement.State
                        line = $line.Trim()
                    }
                }
            } else {
                $pattern = "^\s*UDP\s+(\S+:$($requirement.Port))\s+(\*:\*)\s+(\d+)\s*$"
                if ($line -match $pattern) {
                    $pidValue = [int]$Matches[3]
                    $owners += [ordered]@{
                        pid = $pidValue
                        process_name = Get-ProcessNameSafely -ProcessId $pidValue
                        local_address = $Matches[1]
                        remote_address = $Matches[2]
                        state = $null
                        line = $line.Trim()
                    }
                }
            }
        }
        $ports[$name] = [ordered]@{
            present = $owners.Count -gt 0
            owners = $owners
        }
    }
    return $ports
}

$writer = $null
$started = Get-Date
$deadline = $started.AddSeconds($MaximumSeconds)
$sample = 0
$lastTimestamp = $null
try {
    $fullOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $fullOutputPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Output directory does not exist: $parent"
    }
    $stream = [System.IO.FileStream]::new(
        $fullOutputPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read
    )
    $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true

    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $StopPath)) {
        $iterationStarted = Get-Date
        $sample++
        $record = [ordered]@{
            kind = "windows_port_ownership"
            timestamp = $iterationStarted.ToString("o")
            elapsed_s = ($iterationStarted - $started).TotalSeconds
            sample = $sample
            interval_from_previous_s = if ($lastTimestamp) {
                ($iterationStarted - $lastTimestamp).TotalSeconds
            } else {
                $null
            }
            ports = Get-PortSnapshot
        }
        $writer.WriteLine(($record | ConvertTo-Json -Depth 10 -Compress))
        $lastTimestamp = $iterationStarted

        if ($sample -eq 1) {
            $ready = [ordered]@{
                pid = $PID
                started_at = $started.ToString("o")
                interval_ms = $IntervalMilliseconds
                output = $fullOutputPath
            }
            [System.IO.File]::WriteAllText(
                $ReadyPath,
                ($ready | ConvertTo-Json -Compress),
                [System.Text.UTF8Encoding]::new($false)
            )
        }

        $remaining = $IntervalMilliseconds - ((Get-Date) - $iterationStarted).TotalMilliseconds
        if ($remaining -gt 0) {
            Start-Sleep -Milliseconds ([int]$remaining)
        }
    }
} finally {
    if ($writer) {
        $writer.Dispose()
    }
}
