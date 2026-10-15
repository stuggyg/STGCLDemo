$FailTime = Get-Date '2026-10-15 14:30'   # <-- when it broke (local time)
$Before   = 60    # minutes before
$After    = 15    # minutes after
$Dest     = 'C:\Temp\ClusterLogs'

# Generate logs covering the window
$span = [int]((Get-Date) - $FailTime.AddMinutes(-$Before)).TotalMinutes + 5
Get-ClusterLog -Destination $Dest -TimeSpan $span -UseLocalTime | Out-Null

$from = $FailTime.AddMinutes(-$Before)
$to   = $FailTime.AddMinutes($After)

# Cluster log line format: xxxxxxxx.xxxxxxxx::2026/10/15-14:23:45.123 ERR  [RES] ...
Get-ChildItem $Dest\*_cluster.log | ForEach-Object {
    $node = $_.BaseName -replace '_cluster$'
    Select-String -Path $_.FullName -Pattern ' ERR ', ' WARN ', 'failed', 'offline', 'NOT_SYNCHRONIZING', 'lease' |
    ForEach-Object {
        if ($_.Line -match '::(\d{4}/\d{2}/\d{2}-\d{2}:\d{2}:\d{2})') {
            $t = [datetime]::ParseExact($matches[1], 'yyyy/MM/dd-HH:mm:ss', $null)
            if ($t -ge $from -and $t -le $to) {
                [pscustomobject]@{ Time = $t; Node = $node; Line = $_.Line.Trim() }
            }
        }
    }
} | Sort-Object Time | Export-Csv "$Dest\ClusterErrors_Window.csv" -NoTypeInformation

Import-Csv "$Dest\ClusterErrors_Window.csv" | Out-GridView