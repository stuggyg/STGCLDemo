<#
Pages through a cursor-based POST API on an air-gapped network and persists
each returned JSON object into SQL Server, tagged with the cursor GUID it
came from. Built against System.Data.SqlClient (ships with .NET Framework)
and Invoke-RestMethod (built into Windows PowerShell 5.1) so it needs no
module installs.

Tune -CursorRequestField / -CursorResponseField / -DataField to match the
real API's JSON property names once you've seen a live response.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ApiUri,

    # Bearer token. Prefer piping in a SecureString; falls back to
    # $env:API_BEARER_TOKEN so the token never has to appear on the command line.
    [SecureString] $BearerToken,

    [string] $SqlServerInstance = 'localhost',
    [string] $SqlDatabase = 'ApiIngest',

    # JSON property names in the API's request/response bodies.
    [string] $CursorRequestField = 'cursor',
    [string] $CursorResponseField = 'cursor',
    [string] $DataField = 'items',

    # Extra fixed fields to send on every request (filters, page size, etc).
    [hashtable] $BaseRequestBody = @{},

    # Bypasses ALL TLS certificate validation (expired, self-signed, untrusted
    # chain, hostname mismatch) process-wide for the life of the script. Use
    # only when the on-prem endpoint's cert problem can't be fixed.
    [switch] $SkipCertificateValidation,

    [int] $MaxIterations = 100000,
    [int] $RetryCount = 3,
    [int] $RetryDelaySeconds = 5,

    # Resume a previous run using the last successfully logged cursor
    # instead of starting from the beginning.
    [switch] $Resume,

    [string] $LogPath = (Join-Path $PSScriptRoot "Logs\ApiCursorSync_$(Get-Date -Format 'yyyyMMdd_HHmmss').log")
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($SkipCertificateValidation) {
    Add-Type -TypeDefinition @'
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class TrustAllCerts {
    public static void Apply() {
        ServicePointManager.ServerCertificateValidationCallback =
            (object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) => true;
    }
}
'@
    [TrustAllCerts]::Apply()
}

$logDir = Split-Path $LogPath -Parent
if ($logDir -and -not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
Start-Transcript -Path $LogPath -Append | Out-Null

function Get-PlainTextToken {
    param([SecureString] $Secure)
    if (-not $Secure) {
        if (-not $env:API_BEARER_TOKEN) {
            throw 'No bearer token supplied. Pass -BearerToken or set $env:API_BEARER_TOKEN.'
        }
        return $env:API_BEARER_TOKEN
    }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Invoke-ApiPage {
    param(
        [string] $Uri,
        [hashtable] $Headers,
        [hashtable] $Body
    )

    $json = $Body | ConvertTo-Json -Depth 10
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-RestMethod -Uri $Uri -Method Post -Headers $Headers `
                -ContentType 'application/json' -Body $json
        }
        catch {
            if ($attempt -ge $RetryCount) { throw }
            Write-Warning "API call failed (attempt $attempt/$RetryCount): $($_.Exception.Message). Retrying in $RetryDelaySeconds s."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

function New-SqlConnection {
    $connStr = "Server=$SqlServerInstance;Database=$SqlDatabase;Integrated Security=True;TrustServerCertificate=True;"
    $conn = New-Object System.Data.SqlClient.SqlConnection $connStr
    $conn.Open()
    return $conn
}

function Save-ApiBatch {
    param(
        [System.Data.SqlClient.SqlConnection] $Connection,
        [guid] $BatchId,
        [Nullable[guid]] $RequestCursor,
        [Nullable[guid]] $ResponseCursor,
        [object[]] $Items
    )

    $tx = $Connection.BeginTransaction()
    try {
        $cmd = $Connection.CreateCommand()
        $cmd.Transaction = $tx
        $cmd.CommandText = @'
INSERT INTO dbo.ApiCursorResults (BatchId, RequestCursorGuid, ResponseCursorGuid, ItemJson)
VALUES (@BatchId, @RequestCursor, @ResponseCursor, @ItemJson);
'@
        [void]$cmd.Parameters.Add('@BatchId', [Data.SqlDbType]::UniqueIdentifier)
        [void]$cmd.Parameters.Add('@RequestCursor', [Data.SqlDbType]::UniqueIdentifier)
        [void]$cmd.Parameters.Add('@ResponseCursor', [Data.SqlDbType]::UniqueIdentifier)
        [void]$cmd.Parameters.Add('@ItemJson', [Data.SqlDbType]::NVarChar, -1)

        $duplicateCount = 0
        foreach ($item in $Items) {
            $cmd.Parameters['@BatchId'].Value = $BatchId
            $cmd.Parameters['@RequestCursor'].Value = if ($RequestCursor) { $RequestCursor } else { [DBNull]::Value }
            $cmd.Parameters['@ResponseCursor'].Value = if ($ResponseCursor) { $ResponseCursor } else { [DBNull]::Value }
            $cmd.Parameters['@ItemJson'].Value = ($item | ConvertTo-Json -Depth 20 -Compress)
            try {
                [void]$cmd.ExecuteNonQuery()
            }
            catch [System.Data.SqlClient.SqlException] {
                # 2601/2627 = unique index/constraint violation, i.e. this exact
                # item for this cursor was already saved by an earlier attempt.
                if ($_.Exception.Number -in 2601, 2627) {
                    $duplicateCount++
                }
                else {
                    throw
                }
            }
        }

        $tx.Commit()
        if ($duplicateCount -gt 0) {
            Write-Warning "Skipped $duplicateCount duplicate item(s) already saved from a previous attempt at this cursor."
        }
    }
    catch {
        $tx.Rollback()
        throw
    }
}

function Write-CursorLog {
    param(
        [System.Data.SqlClient.SqlConnection] $Connection,
        [guid] $BatchId,
        [Nullable[guid]] $RequestCursor,
        [Nullable[guid]] $ResponseCursor,
        [int] $ItemCount,
        [int] $HttpStatusCode,
        [string] $ErrorMessage
    )

    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = @'
INSERT INTO dbo.ApiCursorLog (BatchId, RequestCursorGuid, ResponseCursorGuid, ItemCount, HttpStatusCode, ErrorMessage)
VALUES (@BatchId, @RequestCursor, @ResponseCursor, @ItemCount, @HttpStatusCode, @ErrorMessage);
'@
    [void]$cmd.Parameters.Add('@BatchId', [Data.SqlDbType]::UniqueIdentifier)
    [void]$cmd.Parameters.Add('@RequestCursor', [Data.SqlDbType]::UniqueIdentifier)
    [void]$cmd.Parameters.Add('@ResponseCursor', [Data.SqlDbType]::UniqueIdentifier)
    [void]$cmd.Parameters.Add('@ItemCount', [Data.SqlDbType]::Int)
    [void]$cmd.Parameters.Add('@HttpStatusCode', [Data.SqlDbType]::Int)
    [void]$cmd.Parameters.Add('@ErrorMessage', [Data.SqlDbType]::NVarChar, -1)

    $cmd.Parameters['@BatchId'].Value = $BatchId
    $cmd.Parameters['@RequestCursor'].Value = if ($RequestCursor) { $RequestCursor } else { [DBNull]::Value }
    $cmd.Parameters['@ResponseCursor'].Value = if ($ResponseCursor) { $ResponseCursor } else { [DBNull]::Value }
    $cmd.Parameters['@ItemCount'].Value = $ItemCount
    $cmd.Parameters['@HttpStatusCode'].Value = if ($HttpStatusCode) { $HttpStatusCode } else { [DBNull]::Value }
    $cmd.Parameters['@ErrorMessage'].Value = if ($ErrorMessage) { $ErrorMessage } else { [DBNull]::Value }
    [void]$cmd.ExecuteNonQuery()
}

function Get-LastGoodCursor {
    param([System.Data.SqlClient.SqlConnection] $Connection)
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = @'
SELECT TOP 1 ResponseCursorGuid
FROM dbo.ApiCursorLog
WHERE ErrorMessage IS NULL
ORDER BY CalledAtUtc DESC;
'@
    $result = $cmd.ExecuteScalar()
    if ($result -and $result -ne [DBNull]::Value) { return [guid]$result }
    return $null
}

# --- main -------------------------------------------------------------

$sqlConn = $null
try {
    $token = Get-PlainTextToken -Secure $BearerToken
    $headers = @{ Authorization = "Bearer $token" }

    $sqlConn = New-SqlConnection

    try {
        $cursor = $null
        if ($Resume) {
            $cursor = Get-LastGoodCursor -Connection $sqlConn
            if ($cursor) { Write-Host "Resuming from cursor $cursor" }
        }

        $seenCursors = New-Object 'System.Collections.Generic.HashSet[string]'
        $iteration = 0

        do {
            $iteration++
            if ($iteration -gt $MaxIterations) {
                Write-Warning "Hit MaxIterations ($MaxIterations) without the API signaling completion. Stopping."
                break
            }

            $requestBody = $BaseRequestBody.Clone()
            if ($cursor) { $requestBody[$CursorRequestField] = $cursor.ToString() }

            $batchId = [guid]::NewGuid()
            $statusCode = $null
            $errorMessage = $null
            $items = @()
            $nextCursor = $null

            try {
                $response = Invoke-ApiPage -Uri $ApiUri -Headers $headers -Body $requestBody
                $statusCode = 200

                $items = @($response.$DataField)
                $rawNext = $response.$CursorResponseField
                if ($rawNext) { $nextCursor = [guid]$rawNext }

                if ($items.Count -gt 0) {
                    Save-ApiBatch -Connection $sqlConn -BatchId $batchId `
                        -RequestCursor $cursor -ResponseCursor $nextCursor -Items $items
                }
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-CursorLog -Connection $sqlConn -BatchId $batchId -RequestCursor $cursor `
                    -ResponseCursor $nextCursor -ItemCount $items.Count -HttpStatusCode $statusCode -ErrorMessage $errorMessage
                throw
            }

            Write-CursorLog -Connection $sqlConn -BatchId $batchId -RequestCursor $cursor `
                -ResponseCursor $nextCursor -ItemCount $items.Count -HttpStatusCode $statusCode -ErrorMessage $errorMessage

            Write-Host "Batch $iteration : cursor=$cursor -> next=$nextCursor, items=$($items.Count)"

            # Stop conditions: no further cursor, no items returned, or the API
            # handed back a cursor we've already processed (loop guard).
            if (-not $nextCursor) { break }
            if ($items.Count -eq 0) { break }
            if (-not $seenCursors.Add($nextCursor.ToString())) {
                Write-Warning "Cursor $nextCursor was already processed. Stopping to avoid an infinite loop."
                break
            }

            $cursor = $nextCursor
        } while ($true)
    }
    finally {
        if ($sqlConn) { $sqlConn.Close() }
    }

    Write-Host 'Sync completed successfully.'
    exit 0
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
