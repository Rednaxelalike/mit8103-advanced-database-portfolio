# =====================================================================
# Portfolio 3: Transactions and concurrency
# run_two_sessions.ps1  Runs one two-session scenario: session A and
#                       session B as two separate psql processes, started
#                       together and kept in step by a shared start time
#                       (see sql/two_session_clock.sql).
#
# Usage, from the repo root in PowerShell:
#   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 03_lost_update
#       runs sql/03_lost_update_session_a.sql and ..._session_b.sql and
#       writes each session's output to logs/03_lost_update_session_?_output.txt
#   .\portfolio-3-transactions-concurrency\run_two_sessions.ps1 03_lost_update -Show
#       opens the two sessions in two console windows to watch side by side
#       (no log files)
#
# PGPASSWORD is read from .env when it is not already set (see SETUP.md).
# =====================================================================

param(
    [Parameter(Mandatory = $true)][string]$Scenario,
    [switch]$Show,
    [int]$LeadSeconds = 6
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo

if (-not $env:PGPASSWORD) {
    $env:PGPASSWORD = (Get-Content .env | Where-Object { $_ -like 'PGPASSWORD=*' }) -replace '^PGPASSWORD=', ''
}

$folder = 'portfolio-3-transactions-concurrency'
$connect = '-X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1'

foreach ($s in 'a', 'b') {
    if (-not (Test-Path "$folder/sql/${Scenario}_session_$s.sql")) {
        throw "Not found: $folder/sql/${Scenario}_session_$s.sql"
    }
}

# One start time for both sessions, from the server's clock, a few seconds
# ahead so that session A can rebuild the sample data first. Written
# without spaces so it passes through the command line as one argument.
$start = & psql -X -w -U postgres -h localhost -p 5432 -d proclus -At -c `
    "SELECT replace(to_char(now() + interval '$LeadSeconds seconds', 'YYYY-MM-DD HH24:MI:SS.MSOF'), ' ', 'T')"
if ($LASTEXITCODE -ne 0 -or -not $start) { throw 'Could not get a start time from the server.' }

$processes = @()
foreach ($s in 'a', 'b') {
    $sql = "$folder/sql/${Scenario}_session_$s.sql"
    $psql = "psql $connect -v start=$start -f $sql"

    if ($Show) {
        $title = "Session $($s.ToUpper()): $Scenario"
        $processes += Start-Process cmd.exe -ArgumentList '/k', "title $title & psql $connect -P pager=off -v start=$start -f $sql" -PassThru
        continue
    }

    $log = "$folder/logs/${Scenario}_session_${s}_output.txt"
    $now = Get-Date
    $header = "-- Captured $($now.ToString('yyyy-MM-dd HH:mm')) $($now.ToString('zzz') -replace ':', '') on PostgreSQL 18.6, database proclus`n" +
              "-- Command: $folder/run_two_sessions.ps1 $Scenario, which runs session $($s.ToUpper()) as:`n" +
              "--   $($psql -replace "start=$([regex]::Escape($start))", 'start=<shared start time>')`n`n"
    [IO.File]::WriteAllText((Join-Path $repo $log), $header, (New-Object Text.UTF8Encoding $false))

    $p = Start-Process cmd.exe -ArgumentList '/c', "$psql >> `"$log`" 2>&1" -NoNewWindow -PassThru
    $null = $p.Handle   # keeps ExitCode readable after the process ends
    $processes += $p
}

if ($Show) {
    Write-Host "Started both sessions; step 1 runs at $start (server time)."
    return
}

$processes | ForEach-Object { $_.WaitForExit() }
foreach ($i in 0, 1) {
    $s = ('A', 'B')[$i]
    Write-Host "Session $s exited with code $($processes[$i].ExitCode): $folder/logs/${Scenario}_session_$($s.ToLower())_output.txt"
}
