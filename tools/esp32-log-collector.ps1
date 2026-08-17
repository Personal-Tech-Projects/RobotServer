<#
Collect the ESP32's mirrored diagnostic stream without opening serial/resetting
the controller. This helper is started and supervised by stability-health.ps1.
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
    [ValidateRange(1, 65535)]
    [int]$LogPort = 8890
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$udp = $null
$writer = $null
$started = Get-Date
$deadline = $started.AddSeconds($MaximumSeconds)
$count = 0
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

    $udp = [System.Net.Sockets.UdpClient]::new($LogPort)
    $udp.Client.ReceiveTimeout = 250
    $endpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
    $ready = [ordered]@{
        pid = $PID
        started_at = $started.ToString("o")
        udp_port = $LogPort
        output = $fullOutputPath
    }
    [System.IO.File]::WriteAllText(
        $ReadyPath,
        ($ready | ConvertTo-Json -Compress),
        [System.Text.UTF8Encoding]::new($false)
    )

    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $StopPath)) {
        try {
            $bytes = $udp.Receive([ref]$endpoint)
            $count++
            $record = [ordered]@{
                kind = "esp32_diagnostic"
                timestamp = (Get-Date).ToString("o")
                sequence = $count
                remote_endpoint = $endpoint.ToString()
                text = [System.Text.Encoding]::ASCII.GetString($bytes)
            }
            $writer.WriteLine(($record | ConvertTo-Json -Compress))
        } catch [System.Net.Sockets.SocketException] {
            if ($_.Exception.SocketErrorCode -ne [System.Net.Sockets.SocketError]::TimedOut) {
                throw
            }
        }
    }

    $summary = [ordered]@{
        kind = "esp32_collector_summary"
        timestamp = (Get-Date).ToString("o")
        received = $count
    }
    $writer.WriteLine(($summary | ConvertTo-Json -Compress))
} finally {
    if ($udp) {
        $udp.Dispose()
    }
    if ($writer) {
        $writer.Dispose()
    }
}
