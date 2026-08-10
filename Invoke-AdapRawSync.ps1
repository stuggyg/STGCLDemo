<#
Extracts audit event data from ManageEngine ADAudit Plus by replaying the web
console's internal authenticated calls, and lands each raw JSON response
verbatim into dbo.stg_adap_events_raw.

ADAudit Plus publishes no API. Every path and field name below was taken from
cURL captures of the browser console - nothing here is derived from vendor
documentation, because none exists. They are consequently fragile: a product
upgrade can rename or restructure them without notice. Everything capture-
derived lives in the $Endpoint block immediately after param() so it can be
corrected in one place.

    Captured against ADAudit Plus build: <FILL IN - Help > About in the console>
    Capture date:                        <FILL IN>

This is a RAW LANDING script. It stores each response body exactly as the
server sent it and does not parse, type, dedupe, or MERGE. JSON is deserialized
only to decide when to stop paging; the stored payload is always the original
string. Shredding into typed columns is a separate, later step.

WHERE THE CAPTURES CONTRADICTED THE WRITTEN BRIEF (captures win, per instruction):

  1. Login field names. The brief specified "username, password, domain - three
     fields only". The capture shows 'j_username', 'j_password', 'domainName'.
     Using the capture's names. (j_username/j_password are the standard Java
     container form-login names, consistent with a Tomcat/Struts app, so the
     capture is very likely right.)

  2. Pre-existing session on login. The brief states no pre-GET is needed. The
     login capture nonetheless already carries JSESSIONIDADAP and
     JSESSIONIDADAPSSO, i.e. the browser had visited the console before posting
     credentials. This script follows the brief and posts cold by default; if
     login fails with a fresh session, pass -PreGetLoginPage to fetch the base
     URL first and establish those cookies before authenticating.

  3. Session-expiry detection. The brief suggests probing with
     -MaximumRedirection 0. Windows PowerShell 5.1 raises a terminating
     WebException on an unfollowed 3xx, which makes that awkward to use as a
     probe. Instead the redirect is followed (the default) and the response body
     is inspected: a report call that returns HTML rather than JSON means the
     session was bounced to the login page. Same signal, no extra request, and
     it also catches a 200-with-login-page response.

  4. Response shape. No longer a contradiction - CONFIRMED against a sample
     response. Events arrive in a top-level array named "reportData", so the
     -DataField default is correct. Each element is one event, carrying a
     "columnValues" array of per-column descriptor objects:

         { "reportData": [
             { "columnValues": [
                 { "DISPLAYNAME": "Record Number", "columnValue": "1234567",
                   "columnalias": "RECORD_NUMBER", "visible": true,
                   "isData": true, "bgcolumn": false, "escapehtml": true },
                 { "DISPLAYNAME": "SID", "columnValue": "123456889", ... } ] } ] }

     Counting reportData elements therefore counts events, which is what the
     paging loop needs. Note for the later shred step (NOT done here): fields
     are name/value descriptor objects rather than plain properties, so
     shredding means pivoting columnalias -> columnValue per event, and most of
     each payload is presentation metadata (visible/isData/bgcolumn/escapehtml).
     No total/count property was present in the sample, so -TotalCountField
     stays empty and paging relies on the empty/short-page tests.
#>

[CmdletBinding()]
param(
    # Console base URL, scheme + host + port, no trailing slash. From capture.
    [string] $BaseUrl = 'https://adaudit.corp.local:8444',

    # Console account used to authenticate. Should be a dedicated read-only
    # account. Mandatory so PowerShell prompts rather than the password ever
    # sitting in the script, a scheduled-task argument, or shell history.
    [Parameter(Mandatory)]
    [pscredential] $Credential,

    # Value for the login form's domain field and the report calls' domain
    # field. From capture: 'CORP'.
    [string] $DomainName = 'CORP',

    # From capture: 'UserLogon'. Also stored in stg_adap_events_raw.report_name.
    [string] $ReportType = 'UserLogon',

    # Report window. Supply EITHER -StartTime/-EndTime as ordinary datetimes
    # (converted using -ServerTimeZoneId, see below) OR the two *EpochMs
    # parameters to send exact millisecond values - use the latter to replay a
    # capture verbatim while verifying the endpoint.
    [datetime] $StartTime,
    [datetime] $EndTime,
    [int64]    $StartTimeEpochMs,
    [int64]    $EndTimeEpochMs,

    # ADAudit Plus interprets the epoch-millisecond bounds in the APPLICATION
    # SERVER's timezone, which is not necessarily this machine's. -StartTime and
    # -EndTime are treated as wall-clock times in this zone. Defaults to the
    # local zone; set explicitly (e.g. 'GMT Standard Time', 'UTC') once verified.
    #
    # VERIFY BEFORE TRUSTING A BULK PULL: the captured range was
    # 1735689600000-1738368000000, which is exactly 2025-01-01T00:00:00Z to
    # 2025-02-01T00:00:00Z - clean UTC midnight boundaries. That is consistent
    # with a UTC server, but also with a browser that simply sent UTC midnights.
    # Run a narrow window you can eyeball in the console UI and compare the
    # returned event timestamps before relying on the conversion.
    [string] $ServerTimeZoneId,

    # Paging. From capture: 'page' (1-based) and 'range' (page size = 500).
    [int] $Range = 500,
    [int] $StartPage = 1,
    [int] $MaxPages = 10000,

    # Top-level JSON array holding the events. Used only for the paging stop
    # test - see contradiction note 4 in the header.
    [string] $DataField = 'reportData',

    # Optional top-level total/count property, if this build returns one (none
    # observed in the captures). When set and present in the response, it ends
    # paging as soon as the running total reaches it.
    [string] $TotalCountField = '',

    # A page returning fewer than -Range rows is normally the last one. Disable
    # with -StopOnShortPage:$false if this build ever returns short pages
    # mid-set; paging then continues until a page comes back empty.
    [bool] $StopOnShortPage = $true,

    [string] $SqlServerInstance = 'DEMOSQLINST',

    # <FILL IN> - the brief gave the instance but not the database. Set this to
    # the real landing database (the one Create-AdapRawTables.sql was run
    # against) or pass -SqlDatabase at call time.
    [string] $SqlDatabase = 'ADAuditLanding',

    [string] $SqlTable = 'dbo.stg_adap_events_raw',

    # SqlCommand.CommandTimeout. The ADO.NET default of 30s is tight for a
    # long-running pull against a growing table.
    [int] $SqlCommandTimeoutSeconds = 120,

    # Reuse a previous run's GUID and continue after the highest page already
    # landed for it. Pages already in the table are left untouched.
    [guid] $ResumeRunId,

    # Log in, pull page 1 only, print the raw response, land exactly one row,
    # then stop. Use this for flow steps 2 and 3 before any bulk pull.
    [switch] $TestSinglePage,

    # Every request passes through the console's security filter. Keep a gap
    # between pages so a bulk pull does not look like an attack.
    [int] $DelayMillisecondsBetweenPages = 750,

    [int] $HttpTimeoutSeconds = 300,
    [int] $RetryCount = 3,
    [int] $RetryDelaySeconds = 5,

    # The console commonly runs with a self-signed certificate. This bypasses
    # ALL TLS validation process-wide for the life of the script - use only
    # when the certificate cannot be fixed.
    [switch] $SkipCertificateValidation,

    # See contradiction note 2: fetch the base URL before posting credentials.
    [switch] $PreGetLoginPage,

    [string] $LogPath = (Join-Path $PSScriptRoot "Logs\AdapRawSync_$(Get-Date -Format 'yyyyMMdd_HHmmss').log")
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 still negotiates TLS 1.0 by default; the console will
# refuse that.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- capture-derived endpoint constants -------------------------------------
# EVERYTHING in this block came verbatim from the two cURL captures. If a build
# upgrade breaks the script, re-capture from the browser and correct it here -
# nothing below this block hardcodes a path or a field name.
#
#   Capture 1 (login):
#     POST /j_security_check
#     body: j_username, j_password, domainName
#
#   Capture 2 (report):
#     POST /api/json/report/GetReportData
#     header: X-Requested-With: XMLHttpRequest
#     body: adapcsrf, domainName, reportType, startTime, endTime, page, range
#
$Endpoint = @{
    LoginPath       = '/j_security_check'
    ReportPath      = '/api/json/report/GetReportData'

    FieldUsername   = 'j_username'
    FieldPassword   = 'j_password'
    FieldDomain     = 'domainName'

    FieldCsrf       = 'adapcsrf'
    FieldReportType = 'reportType'
    FieldStartTime  = 'startTime'
    FieldEndTime    = 'endTime'
    FieldPage       = 'page'
    FieldRange      = 'range'

    # Cookies that must both exist before any report call is attempted.
    # JSESSIONIDADAPSSO rides along automatically and is not asserted.
    CookieSession   = 'JSESSIONIDADAP'
    CookieCsrf      = 'adapcsrf'
}

$FormContentType = 'application/x-www-form-urlencoded'

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

# --- helpers ----------------------------------------------------------------

function Get-HttpErrorDetail {
    param($ErrorRecord)

    $statusCode = $null
    $bodyText = $null

    $response = $ErrorRecord.Exception.Response
    if ($response) {
        try { $statusCode = [int]$response.StatusCode } catch { }
        try {
            $stream = $response.GetResponseStream()
            if ($stream) {
                $bodyText = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
            }
        }
        catch { }
    }

    if (-not $bodyText -and $ErrorRecord.ErrorDetails) {
        $bodyText = $ErrorRecord.ErrorDetails.Message
    }

    [pscustomobject]@{ StatusCode = $statusCode; Body = $bodyText }
}

function ConvertTo-EpochMs {
    <#
    Treats $Value as a wall-clock time in the ADAudit Plus server's timezone and
    returns Unix epoch milliseconds. See the -ServerTimeZoneId comment: this
    conversion is the single most likely source of a silently wrong result set.
    #>
    param(
        [datetime] $Value,
        [string]   $TimeZoneId
    )

    $tz = if ($TimeZoneId) {
        [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
    }
    else {
        [TimeZoneInfo]::Local
    }

    # Kind must be Unspecified or ConvertTimeToUtc rejects/reinterprets it.
    $unspecified = [datetime]::SpecifyKind($Value, [DateTimeKind]::Unspecified)
    $utc = [TimeZoneInfo]::ConvertTimeToUtc($unspecified, $tz)
    $epoch = [datetime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)

    [int64][Math]::Round(($utc - $epoch).TotalMilliseconds)
}

function ConvertFrom-EpochMs {
    param([int64] $EpochMs)
    ([datetime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).AddMilliseconds($EpochMs)
}

function Get-SessionCookieValue {
    param(
        [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [string] $BaseUrl,
        [string] $Name
    )

    $matched = @($Session.Cookies.GetCookies([uri]$BaseUrl) | Where-Object { $_.Name -eq $Name })
    if ($matched.Count -gt 0) { return $matched[0].Value }
    return $null
}

function Connect-AdapSession {
    <#
    Posts credentials to the login path and returns the populated
    WebRequestSession. j_security_check answers 302; the redirect is followed
    (5.1's default) and the redirect target is what sets the adapcsrf cookie -
    so no separate call is needed to obtain the CSRF token.
    #>
    param(
        [string] $BaseUrl,
        [pscredential] $Credential,
        [string] $DomainName,
        [switch] $PreGetLoginPage
    )

    $session = $null

    if ($PreGetLoginPage) {
        # Contradiction note 2: establishes JSESSIONIDADAP/JSESSIONIDADAPSSO the
        # way the captured browser already had them.
        Invoke-WebRequest -Uri $BaseUrl -Method Get -SessionVariable session `
            -UseBasicParsing -TimeoutSec $HttpTimeoutSeconds | Out-Null
    }

    $body = @{}
    $body[$Endpoint.FieldUsername] = $Credential.UserName
    $body[$Endpoint.FieldPassword] = $Credential.GetNetworkCredential().Password
    $body[$Endpoint.FieldDomain]   = $DomainName

    $headers = @{
        'Origin'  = $BaseUrl
        'Referer' = "$BaseUrl/"
    }

    $loginUri = "$BaseUrl$($Endpoint.LoginPath)"

    if ($session) {
        Invoke-WebRequest -Uri $loginUri -Method Post -Body $body -Headers $headers `
            -ContentType $FormContentType -WebSession $session `
            -UseBasicParsing -TimeoutSec $HttpTimeoutSeconds | Out-Null
    }
    else {
        Invoke-WebRequest -Uri $loginUri -Method Post -Body $body -Headers $headers `
            -ContentType $FormContentType -SessionVariable session `
            -UseBasicParsing -TimeoutSec $HttpTimeoutSeconds | Out-Null
    }

    return $session
}

function Assert-AdapSession {
    <#
    A wrong domain string, a locked account or a bad password does not
    necessarily produce an HTTP error - the console just serves the login page
    again with a 200. The reliable signal is the cookie jar: no session cookie
    and no CSRF cookie means authentication did not happen. Fail here rather
    than sending report calls that quietly return login HTML.
    #>
    param(
        [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [string] $BaseUrl
    )

    $sessionCookie = Get-SessionCookieValue -Session $Session -BaseUrl $BaseUrl -Name $Endpoint.CookieSession
    $csrfCookie    = Get-SessionCookieValue -Session $Session -BaseUrl $BaseUrl -Name $Endpoint.CookieCsrf

    if (-not $sessionCookie -or -not $csrfCookie) {
        $missing = @()
        if (-not $sessionCookie) { $missing += $Endpoint.CookieSession }
        if (-not $csrfCookie)    { $missing += $Endpoint.CookieCsrf }

        $present = @($Session.Cookies.GetCookies([uri]$BaseUrl) | ForEach-Object { $_.Name }) -join ', '
        if (-not $present) { $present = '(none)' }

        throw ("Login did not establish a usable session. Missing cookie(s): $($missing -join ', '). " +
            "Cookies present: $present. " +
            "Check the username, password and -DomainName ('$DomainName'), and that the account is not locked. " +
            "If the console requires an existing session before accepting credentials, retry with -PreGetLoginPage.")
    }

    return $csrfCookie
}

function Test-LooksLikeJson {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $trimmed = $Text.TrimStart()
    return $trimmed.StartsWith('{') -or $trimmed.StartsWith('[')
}

function Invoke-AdapReportPage {
    <#
    One report POST. CSRF is double-submit: adapcsrf travels as a cookie
    (carried by -WebSession) AND as a form field, read from the cookie jar.
    Returns the raw response string - Invoke-WebRequest, not Invoke-RestMethod,
    so the exact bytes the server sent are what gets landed.
    #>
    param(
        [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [string] $BaseUrl,
        [string] $Csrf,
        [int]    $PageNo,
        [int64]  $StartEpochMs,
        [int64]  $EndEpochMs
    )

    $body = @{}
    $body[$Endpoint.FieldCsrf]       = $Csrf
    $body[$Endpoint.FieldDomain]     = $DomainName
    $body[$Endpoint.FieldReportType] = $ReportType
    $body[$Endpoint.FieldStartTime]  = $StartEpochMs
    $body[$Endpoint.FieldEndTime]    = $EndEpochMs
    $body[$Endpoint.FieldPage]       = $PageNo
    $body[$Endpoint.FieldRange]      = $Range

    $headers = @{
        'X-Requested-With' = 'XMLHttpRequest'
        'Referer'          = "$BaseUrl/"
    }

    $uri = "$BaseUrl$($Endpoint.ReportPath)"

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $response = Invoke-WebRequest -Uri $uri -Method Post -Body $body -Headers $headers `
                -ContentType $FormContentType -WebSession $Session `
                -UseBasicParsing -TimeoutSec $HttpTimeoutSeconds
            return $response.Content
        }
        catch {
            $detail = Get-HttpErrorDetail -ErrorRecord $_
            $message = $_.Exception.Message
            if ($detail.StatusCode) { $message = "[HTTP $($detail.StatusCode)] $message" }
            if ($detail.Body) { $message = "$message Response body: $($detail.Body)" }

            # 4xx other than 429 means the request itself is wrong - a bad CSRF
            # token, a renamed field, an expired session. Retrying an identical
            # malformed request just annoys the security filter.
            $nonRetryable = $detail.StatusCode -ge 400 -and $detail.StatusCode -lt 500 -and $detail.StatusCode -ne 429

            if ($nonRetryable -or $attempt -ge $RetryCount) { throw $message }

            Write-Warning "Report call failed on page $PageNo (attempt $attempt/$RetryCount): $message. Retrying in $RetryDelaySeconds s."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

function Get-AdapReportPage {
    <#
    Wraps Invoke-AdapReportPage with session-expiry recovery. On a long pull the
    console will eventually bounce the session; the redirect lands on the login
    page and returns HTML instead of JSON. That is the cue to re-authenticate
    once and replay the same page.
    #>
    param(
        [int]   $PageNo,
        [int64] $StartEpochMs,
        [int64] $EndEpochMs
    )

    $content = Invoke-AdapReportPage -Session $script:AdapSession -BaseUrl $BaseUrl `
        -Csrf $script:AdapCsrf -PageNo $PageNo -StartEpochMs $StartEpochMs -EndEpochMs $EndEpochMs

    if (Test-LooksLikeJson -Text $content) { return $content }

    Write-Warning "Page $PageNo returned a non-JSON body (session likely expired). Re-authenticating and retrying."

    $script:AdapSession = Connect-AdapSession -BaseUrl $BaseUrl -Credential $Credential `
        -DomainName $DomainName -PreGetLoginPage:$PreGetLoginPage
    $script:AdapCsrf = Assert-AdapSession -Session $script:AdapSession -BaseUrl $BaseUrl

    $content = Invoke-AdapReportPage -Session $script:AdapSession -BaseUrl $BaseUrl `
        -Csrf $script:AdapCsrf -PageNo $PageNo -StartEpochMs $StartEpochMs -EndEpochMs $EndEpochMs

    if (-not (Test-LooksLikeJson -Text $content)) {
        $preview = $content
        if ($preview.Length -gt 500) { $preview = $preview.Substring(0, 500) + '...' }
        throw "Page $PageNo still returned a non-JSON body after re-authenticating. First 500 chars: $preview"
    }

    return $content
}

function Measure-ReportPage {
    <#
    Deserializes ONLY to drive the paging loop. The string handed to SQL is
    always the original response - nothing here touches what gets landed.
    #>
    param(
        [string] $Json,
        [string] $DataField,
        [string] $TotalCountField
    )

    $obj = $null
    try { $obj = $Json | ConvertFrom-Json }
    catch {
        return [pscustomobject]@{ FieldFound = $false; Count = 0; Total = $null; ParseError = $_.Exception.Message }
    }

    $data = $obj.$DataField
    $total = $null
    if ($TotalCountField -and ($null -ne $obj.$TotalCountField)) {
        $total = [int64]$obj.$TotalCountField
    }

    if ($null -eq $data) {
        return [pscustomobject]@{ FieldFound = $false; Count = 0; Total = $total; ParseError = $null }
    }

    [pscustomobject]@{ FieldFound = $true; Count = @($data).Count; Total = $total; ParseError = $null }
}

function New-SqlConnection {
    $connStr = "Server=$SqlServerInstance;Database=$SqlDatabase;Integrated Security=True;TrustServerCertificate=True;"
    $conn = New-Object System.Data.SqlClient.SqlConnection $connStr
    $conn.Open()
    return $conn
}

function Save-AdapPage {
    <#
    One row per page, one autocommitted statement. Deliberately no explicit
    transaction spanning pages: a failure mid-run must leave every page landed
    so far intact and committed, so the run can resume with -ResumeRunId.
    #>
    param(
        [System.Data.SqlClient.SqlConnection] $Connection,
        [guid]   $RunId,
        [string] $ReportName,
        [int]    $PageNo,
        [string] $Payload
    )

    $cmd = $Connection.CreateCommand()
    $cmd.CommandTimeout = $SqlCommandTimeoutSeconds
    $cmd.CommandText = @"
INSERT INTO $SqlTable (run_id, report_name, page_no, payload)
VALUES (@run_id, @report_name, @page_no, @payload);
"@
    [void]$cmd.Parameters.Add('@run_id', [Data.SqlDbType]::UniqueIdentifier)
    [void]$cmd.Parameters.Add('@report_name', [Data.SqlDbType]::NVarChar, 200)
    [void]$cmd.Parameters.Add('@page_no', [Data.SqlDbType]::Int)
    [void]$cmd.Parameters.Add('@payload', [Data.SqlDbType]::NVarChar, -1)

    $cmd.Parameters['@run_id'].Value      = $RunId
    $cmd.Parameters['@report_name'].Value = if ($ReportName) { $ReportName } else { [DBNull]::Value }
    $cmd.Parameters['@page_no'].Value     = $PageNo
    $cmd.Parameters['@payload'].Value     = $Payload

    [void]$cmd.ExecuteNonQuery()
}

function Get-LastLandedPage {
    param(
        [System.Data.SqlClient.SqlConnection] $Connection,
        [guid] $RunId
    )

    $cmd = $Connection.CreateCommand()
    $cmd.CommandTimeout = $SqlCommandTimeoutSeconds
    $cmd.CommandText = "SELECT MAX(page_no) FROM $SqlTable WHERE run_id = @run_id;"
    [void]$cmd.Parameters.Add('@run_id', [Data.SqlDbType]::UniqueIdentifier)
    $cmd.Parameters['@run_id'].Value = $RunId

    $result = $cmd.ExecuteScalar()
    if ($result -and $result -ne [DBNull]::Value) { return [int]$result }
    return 0
}

# --- main -------------------------------------------------------------------

$sqlConn = $null
try {
    # Resolve the report window. Explicit epoch values win, so a capture can be
    # replayed byte-for-byte while verifying the endpoint.
    if ($StartTimeEpochMs -gt 0) {
        $startEpochMs = $StartTimeEpochMs
    }
    elseif ($PSBoundParameters.ContainsKey('StartTime')) {
        $startEpochMs = ConvertTo-EpochMs -Value $StartTime -TimeZoneId $ServerTimeZoneId
    }
    else {
        throw 'Supply a report window: -StartTime/-EndTime, or -StartTimeEpochMs/-EndTimeEpochMs.'
    }

    if ($EndTimeEpochMs -gt 0) {
        $endEpochMs = $EndTimeEpochMs
    }
    elseif ($PSBoundParameters.ContainsKey('EndTime')) {
        $endEpochMs = ConvertTo-EpochMs -Value $EndTime -TimeZoneId $ServerTimeZoneId
    }
    else {
        throw 'Supply a report window: -StartTime/-EndTime, or -StartTimeEpochMs/-EndTimeEpochMs.'
    }

    if ($endEpochMs -le $startEpochMs) {
        throw "End of window ($endEpochMs) is not after the start ($startEpochMs)."
    }

    # Echo both representations so the timezone assumption can be checked
    # against what the console UI shows for the same range.
    $tzLabel = if ($ServerTimeZoneId) { $ServerTimeZoneId } else { "$([TimeZoneInfo]::Local.Id) (local)" }
    Write-Host "Report window: $startEpochMs - $endEpochMs"
    Write-Host "  = $((ConvertFrom-EpochMs $startEpochMs).ToString('yyyy-MM-dd HH:mm:ss')) - $((ConvertFrom-EpochMs $endEpochMs).ToString('yyyy-MM-dd HH:mm:ss')) UTC"
    Write-Host "  interpreted using timezone: $tzLabel"
    Write-Host "  VERIFY these bounds against the same range in the console UI before a bulk pull."

    $runId = if ($ResumeRunId -and $ResumeRunId -ne [guid]::Empty) { $ResumeRunId } else { [guid]::NewGuid() }

    $sqlConn = New-SqlConnection

    try {
        $firstPage = $StartPage
        if ($ResumeRunId -and $ResumeRunId -ne [guid]::Empty) {
            $lastLanded = Get-LastLandedPage -Connection $sqlConn -RunId $runId
            if ($lastLanded -gt 0) {
                $firstPage = $lastLanded + 1
                Write-Host "Resuming run $runId : pages 1-$lastLanded already landed, continuing at page $firstPage."
            }
            else {
                Write-Warning "No pages found for run $runId - starting at page $firstPage."
            }
        }

        # Flow step 1: authenticate, and refuse to continue without both cookies.
        Write-Host "Authenticating to $BaseUrl as $($Credential.UserName) (domain '$DomainName')."
        $script:AdapSession = Connect-AdapSession -BaseUrl $BaseUrl -Credential $Credential `
            -DomainName $DomainName -PreGetLoginPage:$PreGetLoginPage
        $script:AdapCsrf = Assert-AdapSession -Session $script:AdapSession -BaseUrl $BaseUrl
        Write-Host "Session established. Run id: $runId"

        $pageNo = $firstPage
        $pagesLanded = 0
        $rowsSeen = [int64]0

        while ($true) {
            if (($pageNo - $firstPage) -ge $MaxPages) {
                Write-Warning "Reached -MaxPages ($MaxPages) without an empty page. Stopping; resume with -ResumeRunId $runId."
                break
            }

            # Flow step 2: fetch, keeping the response as a raw string.
            $raw = Get-AdapReportPage -PageNo $pageNo -StartEpochMs $startEpochMs -EndEpochMs $endEpochMs

            # Flow step 3: land it verbatim, before anything is inspected.
            Save-AdapPage -Connection $sqlConn -RunId $runId -ReportName $ReportType `
                -PageNo $pageNo -Payload $raw
            $pagesLanded++

            $stats = Measure-ReportPage -Json $raw -DataField $DataField -TotalCountField $TotalCountField
            $rowsSeen += $stats.Count
            Write-Host "Page $pageNo landed: $($stats.Count) row(s) in '$DataField', $($raw.Length) chars. Running total: $rowsSeen."

            if ($TestSinglePage) {
                $preview = $raw
                if ($preview.Length -gt 2000) { $preview = $preview.Substring(0, 2000) + "`n...[truncated, $($raw.Length) chars total]" }
                Write-Host "`n--- raw response, page $pageNo ---`n$preview`n--- end raw response ---`n"
                Write-Host "-TestSinglePage: stopping after one page. Verify with:"
                Write-Host "  SELECT id, run_id, report_name, page_no, LEN(payload) AS payload_chars, ingested_at"
                Write-Host "  FROM $SqlTable WHERE run_id = '$runId';"
                break
            }

            # Stop conditions, most reliable first.
            if (-not $stats.FieldFound) {
                if ($stats.ParseError) {
                    Write-Warning "Page $pageNo was landed but could not be parsed to check for more pages: $($stats.ParseError). Stopping."
                }
                else {
                    Write-Warning ("Page $pageNo was landed but has no top-level '$DataField' property, so paging cannot be driven. " +
                        "Inspect the landed payload and set -DataField to the correct property name. Stopping.")
                }
                break
            }

            if ($stats.Count -eq 0) {
                Write-Host "Page $pageNo was empty - end of result set."
                break
            }

            if ($null -ne $stats.Total -and $rowsSeen -ge $stats.Total) {
                Write-Host "Reached the reported total of $($stats.Total) row(s) - end of result set."
                break
            }

            if ($StopOnShortPage -and $stats.Count -lt $Range) {
                Write-Host "Page $pageNo returned $($stats.Count) row(s), fewer than the page size of $Range - treating as the last page."
                break
            }

            $pageNo++
            if ($DelayMillisecondsBetweenPages -gt 0) {
                Start-Sleep -Milliseconds $DelayMillisecondsBetweenPages
            }
        }

        Write-Host "`nRun $runId complete: $pagesLanded page(s) landed into $SqlTable, $rowsSeen row(s) seen."
    }
    finally {
        if ($sqlConn) { $sqlConn.Close() }
    }

    exit 0
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
