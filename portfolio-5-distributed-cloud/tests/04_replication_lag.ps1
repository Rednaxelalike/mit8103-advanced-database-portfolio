# =====================================================================
# Portfolio 5: Distributed and cloud database
# 04_replication_lag.ps1  Runs the replication lag test: Portfolio 2's
#                         01_seed_large.sql as the load on the primary,
#                         and tests/04_replication_lag.sql sampling the
#                         replica's lag at the same time, as two separate
#                         psql processes.
#
# Usage, from the repo root in PowerShell (the replica must be running,
# see setup-replica.md):
#   .\portfolio-5-distributed-cloud\tests\04_replication_lag.ps1
# Writes logs/04_replication_lag_output.txt (the sampler) and
# logs/04_load_seed_large_output.txt (the load). Takes about 3 minutes.
#
# PGPASSWORD is read from .env when it is not already set (see SETUP.md).
# =====================================================================

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location $repo

if (-not $env:PGPASSWORD) {
    $env:PGPASSWORD = (Get-Content .env | Where-Object { $_ -like 'PGPASSWORD=*' }) -replace '^PGPASSWORD=', ''
}

$folder = 'portfolio-5-distributed-cloud'

$inRecovery = & psql -X -w -U postgres -h localhost -p 5433 -d proclus -At -c 'SELECT pg_is_in_recovery()'
if ($LASTEXITCODE -ne 0 -or $inRecovery -ne 't') { throw 'The replica on port 5433 is not running as a standby (see setup-replica.md).' }

# The load connects with application_name p5_lag_load, which is how the
# sampler finds it in pg_stat_activity.
$runs = @(
    @{ Name = 'load';
       Log  = "$folder/logs/04_load_seed_large_output.txt";
       Psql = 'psql -X -w -U postgres -h localhost -p 5432 -d "dbname=proclus application_name=p5_lag_load" -v ON_ERROR_STOP=1 -f portfolio-2-query-optimisation/sql/01_seed_large.sql' },
    @{ Name = 'sampler';
       Log  = "$folder/logs/04_replication_lag_output.txt";
       Psql = "psql -X -w -U postgres -h localhost -p 5432 -d proclus -v ON_ERROR_STOP=1 -f $folder/tests/04_replication_lag.sql" }
)

# Start the sampler first, so it is already waiting when the load connects.
[array]::Reverse($runs)
$processes = @()
foreach ($run in $runs) {
    $now = Get-Date
    $header = "-- Captured $($now.ToString('yyyy-MM-dd HH:mm')) $($now.ToString('zzz') -replace ':', '') on PostgreSQL 18.6, database proclus (primary 5432, replica 5433)`n" +
              "-- Command: $folder/tests/04_replication_lag.ps1, which runs the $($run.Name) as:`n" +
              "--   $($run.Psql)`n`n"
    [IO.File]::WriteAllText((Join-Path $repo $run.Log), $header, (New-Object Text.UTF8Encoding $false))

    $p = Start-Process cmd.exe -ArgumentList '/c', "$($run.Psql) >> `"$($run.Log)`" 2>&1" -NoNewWindow -PassThru
    $null = $p.Handle   # keeps ExitCode readable after the process ends
    $processes += $p
    Start-Sleep -Seconds 1
}

$processes | ForEach-Object { $_.WaitForExit() }
for ($i = 0; $i -lt $runs.Count; $i++) {
    Write-Host "The $($runs[$i].Name) exited with code $($processes[$i].ExitCode): $($runs[$i].Log)"
}
