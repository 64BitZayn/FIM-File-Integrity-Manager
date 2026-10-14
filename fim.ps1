<#
.SYNOPSIS
    File Integrity Monitor: baseline a folder with SHA-512 hashes, then watch it for
    created, modified and deleted files.

.DESCRIPTION
    Mode "Baseline" hashes every file under -Path and writes path|hash pairs to a baseline file.
    Mode "Monitor" re-hashes the folder every -Interval seconds and compares against that baseline.
    Each change is reported once (not every polling cycle). Run without -Mode for the interactive menu.

.EXAMPLE
    ./fim.ps1 -Mode Baseline -Path ./tests
    ./fim.ps1 -Mode Monitor  -Path ./tests -Interval 2 -LogFile ./fim-alerts.log
#>
[CmdletBinding()]
param(
    [ValidateSet('Baseline', 'Monitor')]
    [string]$Mode,
    [string]$Path = (Join-Path $PSScriptRoot 'tests'),
    [string]$BaselineFile = (Join-Path $PSScriptRoot 'baseline.txt'),
    [ValidateRange(1, 3600)]
    [int]$Interval = 1,
    [switch]$Recurse,
    [string]$LogFile,
    # Stop after N polling cycles (0 = run forever). Useful for testing.
    [int]$MaxCycles = 0
)

$Separator = '|'

function Get-TargetFiles {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Folder not found: $Path"
    }
    # -File skips sub-directories, which Get-FileHash cannot hash
    Get-ChildItem -LiteralPath $Path -File -Recurse:$Recurse
}

function Get-HashTable {
    $table = @{}
    foreach ($file in Get-TargetFiles) {
        try {
            $table[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA512).Hash
        } catch {
            # File locked or removed mid-scan: skip it this cycle
            Write-Verbose "Could not hash $($file.FullName): $_"
        }
    }
    return $table
}

function Write-Alert([string]$Message, [string]$Color) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $line }
}

function New-Baseline {
    $hashes = Get-HashTable
    $lines = foreach ($entry in $hashes.GetEnumerator() | Sort-Object Key) {
        "$($entry.Key)$Separator$($entry.Value)"
    }
    # UTF-8 so the baseline diffs cleanly in Git and reads the same on Windows, Linux and macOS
    Set-Content -LiteralPath $BaselineFile -Value $lines -Encoding utf8
    Write-Host "Baseline saved: $($hashes.Count) file(s) -> $BaselineFile" -ForegroundColor Cyan
}

function Read-Baseline {
    if (-not (Test-Path -LiteralPath $BaselineFile)) {
        throw "No baseline at $BaselineFile. Run with -Mode Baseline first."
    }
    $table = @{}
    foreach ($line in Get-Content -LiteralPath $BaselineFile) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # Split on the LAST separator so paths are never cut in half
        $i = $line.LastIndexOf($Separator)
        $table[$line.Substring(0, $i)] = $line.Substring($i + 1)
    }
    return $table
}

function Start-Monitor {
    $baseline = Read-Baseline
    Write-Host "Monitoring $Path ($($baseline.Count) file(s) in baseline). Ctrl+C to stop." -ForegroundColor Cyan

    # Remember what was already reported so each event is alerted once, not every second
    $reported = @{}
    $cycle = 0
    while ($MaxCycles -eq 0 -or $cycle -lt $MaxCycles) {
        $cycle++
        $current = Get-HashTable

        foreach ($file in $current.Keys) {
            if (-not $baseline.ContainsKey($file)) {
                $state = "created:$($current[$file])"
                if ($reported[$file] -ne $state) { Write-Alert "CREATED   $file" 'Green'; $reported[$file] = $state }
            } elseif ($baseline[$file] -ne $current[$file]) {
                $state = "modified:$($current[$file])"
                if ($reported[$file] -ne $state) { Write-Alert "MODIFIED  $file" 'Yellow'; $reported[$file] = $state }
            } elseif ($reported.ContainsKey($file)) {
                Write-Alert "RESTORED  $file (matches baseline again)" 'Cyan'
                $reported.Remove($file)
            }
        }

        foreach ($file in $baseline.Keys) {
            if (-not $current.ContainsKey($file) -and $reported[$file] -ne 'deleted') {
                Write-Alert "DELETED   $file" 'Red'
                $reported[$file] = 'deleted'
            }
        }

        Start-Sleep -Seconds $Interval
    }
}

if (-not $Mode) {
    Write-Host ''
    Write-Host 'What would you like to do?'
    Write-Host '  A) Collect a new baseline'
    Write-Host '  B) Begin monitoring files with the saved baseline'
    $answer = Read-Host -Prompt "Enter 'A' or 'B'"
    switch ($answer.Trim().ToUpper()) {
        'A' { $Mode = 'Baseline' }
        'B' { $Mode = 'Monitor' }
        default { Write-Host "Unknown option '$answer'." -ForegroundColor Red; exit 1 }
    }
}

if ($Mode -eq 'Baseline') { New-Baseline } else { Start-Monitor }
