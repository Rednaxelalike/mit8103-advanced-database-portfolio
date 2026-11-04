# =====================================================================
# Portfolio 5: Distributed and cloud database
# 05_failover.ps1  The failover drill: a last transfer on the primary, the
#                  primary crashes, the replica is promoted with
#                  pg_ctl promote, and the promoted replica takes writes.
#
# Usage, from the repo root in PowerShell (the replica must be running and
# streaming, see setup-replica.md):
#   .\portfolio-5-distributed-cloud\tests\05_failover.ps1
# Writes everything to logs/05_failover_output.txt.
#
# Stopping the primary needs administrator rights, because it runs as the
# Windows service postgresql-x64-18 under NetworkService. The script asks
# for them once, with a Windows UAC prompt, to run:
#   pg_ctl stop -D "C:\Program Files\PostgreSQL\18\data" -m immediate
# -m immediate ends the server without a shutdown checkpoint, as a crash
# or power cut would; the next start has to run crash recovery.
#
# The drill leaves port 5433 as a stand-alone primary and port 5432
# stopped. "After the failover drill" in setup-replica.md puts 5432 back
# as the primary and rebuilds the replica.
#
# PGPASSWORD is read from .env when it is not already set (see SETUP.md).
# =====================================================================

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location $repo

if (-not $env:PGPASSWORD) {
    $env:PGPASSWORD = (Get-Content .env | Where-Object { $_ -like 'PGPASSWORD=*' }) -replace '^PGPASSWORD=', ''
}

$folder      = 'portfolio-5-distributed-cloud'
$primaryData = 'C:\Program Files\PostgreSQL\18\data'
$replicaData = 'C:\Users\USER\pg18-replica-5433'
$log         = "$folder/logs/05_failover_output.txt"
$logPath     = Join-Path $repo $log
$utf8        = New-Object Text.UTF8Encoding $false

function Write-Log([string]$text) {
    [IO.File]::AppendAllText($logPath, "$text`n", $utf8)
    Write-Host $text
}

function Write-Step([string]$text) {
    Write-Log ''
    Write-Log "##### $((Get-Date).ToString('HH:mm:ss.fff'))  $text"
}

# Runs psql with output appended to the log; returns psql's exit code.
function Invoke-Psql([string]$arguments) {
    Write-Log "> psql $arguments"
    cmd /c "psql $arguments >> `"$logPath`" 2>&1"
    return $LASTEXITCODE
}

$replicaState = & psql -X -w -U postgres -h localhost -p 5432 -d proclus -At -c "SELECT state FROM pg_stat_replication WHERE application_name = 'replica_5433'"
if ($LASTEXITCODE -ne 0 -or $replicaState -ne 'streaming') {
    throw 'replica_5433 is not streaming from the primary on port 5432 (see setup-replica.md).'
}

$now = Get-Date
[IO.File]::WriteAllText($logPath,
    "-- Captured $($now.ToString('yyyy-MM-dd HH:mm')) $($now.ToString('zzz') -replace ':', '') on PostgreSQL 18.6, database proclus (primary 5432, replica 5433)`n" +
    "-- Command: $folder/tests/05_failover.ps1`n", $utf8)

Write-Step 'Step 1: the last transfer on the primary, replayed on the replica'
if ((Invoke-Psql "-X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -f $folder/tests/05_failover_1_primary.sql") -ne 0) {
    throw "Stage 1 failed; see $log"
}

Write-Step 'Step 2: the primary crashes (pg_ctl stop -m immediate, run as administrator)'
# The crash time is taken when the elevated pg_ctl returns, not when it is
# requested, so the time spent on the UAC prompt is not counted as outage.
$stop = Start-Process (Get-Command pg_ctl).Source -ArgumentList 'stop', '-D', "`"$primaryData`"", '-m', 'immediate', '-w' `
                     -Verb RunAs -WindowStyle Hidden -Wait -PassThru
$crashed = Get-Date
Write-Log ("pg_ctl stop exited with code {0} at {1:HH:mm:ss.fff}" -f $stop.ExitCode, $crashed)
if ($stop.ExitCode -ne 0) { throw "Could not stop the primary; see $log" }
Write-Log "Windows service postgresql-x64-18: $((Get-Service postgresql-x64-18).Status)"
$null = Invoke-Psql '-X -w -U postgres -h localhost -p 5432 -d proclus -c "SELECT 1"'

Write-Step 'Step 3: the replica on its own, before promotion'
$null = Invoke-Psql "-X -w -U postgres -h localhost -p 5433 -d proclus -f $folder/tests/05_failover_2_standby_alone.sql"

Write-Step 'Step 4: promote the replica (pg_ctl promote)'
$promoteStart = Get-Date
$output = & pg_ctl promote -D $replicaData -w 2>&1
$promoteEnd = Get-Date
$output | ForEach-Object { Write-Log "$_" }
if ($LASTEXITCODE -ne 0) { throw "pg_ctl promote failed; see $log" }
Write-Log ("pg_ctl promote took {0:N0} ms" -f ($promoteEnd - $promoteStart).TotalMilliseconds)

Write-Log ''
Write-Log 'The replica''s server log from the crash to the promotion:'
$serverLog = Get-ChildItem "$replicaData\log\*.log" | Sort-Object LastWriteTime | Select-Object -Last 1
Get-Content $serverLog.FullName |
    Where-Object { $_ -match '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)' -and [datetime]$Matches[1] -ge $crashed.AddSeconds(-1) } |
    Where-Object { $_ -notmatch 'waiting for WAL to become available' } |
    ForEach-Object { Write-Log "  $_" }

Write-Step 'Step 5: the promoted replica takes writes'
if ((Invoke-Psql "-X -w -U postgres -h localhost -p 5433 -d proclus -v ON_ERROR_STOP=1 -f $folder/tests/05_failover_3_promoted.sql") -ne 0) {
    throw "Stage 3 failed; see $log"
}
$firstWrite = Get-Date

Write-Step 'Summary'
Write-Log ("Primary crashed at {0:HH:mm:ss.fff}; replica promoted at {1:HH:mm:ss.fff}; first write on it committed by {2:HH:mm:ss.fff}." -f $crashed, $promoteEnd, $firstWrite)
Write-Log ("Writes were impossible for {0:N1} s, from the crash to the end of pg_ctl promote; the promotion itself took {1:N1} s." -f `
    ($promoteEnd - $crashed).TotalSeconds, ($promoteEnd - $promoteStart).TotalSeconds)
Write-Log 'Port 5432 is stopped and port 5433 is now a primary with no replica. Next: "After the failover drill" in setup-replica.md.'
