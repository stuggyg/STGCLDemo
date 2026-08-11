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
     Using the capture's names. (j_username/j_password are the stafvzndard Java
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

    # An ENTIRE report cURL command, pasted verbatim from devtools' "Copy as
    # cURL" - including the curl keyword, URL, -H headers and -b cookies.
    #
    # The URL supplies -BaseUrl (unless you pass -BaseUrl explicitly) and the
    # report path, and the --data-raw argument supplies the form body. Headers
    # and cookies are ignored: the script sets its own headers, and captured
    # cookies are dead session tokens that must never be replayed.
    #
    # This is the fastest way to re-point the script after a product upgrade -
    # re-capture in the browser, paste the whole thing, run with -TestSinglePage.
    [string] $ReportCurlCommand = '',

    # The COMPLETE --data-raw value from the report cURL capture, pasted as one
    # string, e.g. 'adapcsrf=...&domainName=CORP&reportType=UserLogon&...'.
    # Use this INSTEAD of -ReportCurlCommand when you only have the body.
    # If both are given, this one wins.
    #
    # Use this when the real console body carries more than the seven fields
    # named in $Endpoint - column selections, filters, sort order, view/tab ids.
    # ADAudit Plus may require them, and anything not sent is simply absent from
    # the request. Paste the capture verbatim: repeated keys and field order are
    # preserved, and the seven fields this script manages (adapcsrf, domainName,
    # reportType, startTime, endTime, page, range) are overwritten with live
    # values afterwards, so stale tokens and dates in the pasted text are inert.
    #
    # Leave empty to send only the seven managed fields, which reproduces the
    # trimmed capture exactly.
    [string] $RawReportFormData = '',

    # An ENTIRE cURL command for the call the console makes BEFORE the report
    # data call - observed as getReportInputParams on this build.
    #
    # The report screen is a two-step flow: this call primes session-scoped
    # server state for the report, and the data call is served against it. Skip
    # it and every report 403s, which looks like an auth or permissions problem
    # and is not. Paste the capture; nothing about this call is assumed.
    #
    # Replayed after login and again after every re-authentication, since a new
    # session has none of the primed state.
    [string] $PreReportCurlCommand = '',

    # Replay the -H headers from -ReportCurlCommand on every report call,
    # instead of the script's inferred X-Requested-With + Referer pair.
    #
    # Reach for this on a 403. The security filter every request passes through
    # can reject on header shape alone - a missing Origin, a non-browser
    # User-Agent - and the captured headers are ground truth for what this build
    # accepts. Cookie is never replayed (dead tokens), nor are headers
    # PowerShell must set itself.
    [switch] $UseCapturedHeaders,

    # Individual header additions or overrides, applied last.
    #   -ExtraHeaders @{ Origin = 'https://adaudit.corp.local:8444' }
    [hashtable] $ExtraHeaders = @{},

    # Individual additions or overrides applied on top of -RawReportFormData.
    # Handy for flipping one field without re-pasting the whole body:
    #   -ExtraReportFields @{ sortColumn = 'LOGON_TIME'; sortOrder = 'desc' }
    # Cannot express repeated keys - use -RawReportFormData for those.
    [hashtable] $ExtraReportFields = @{},

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
    WebRequestSession. j_security_check answers with a redirect - 302 on the
    build originally captured, 303 on a later one. Either is followed
    automatically (5.1 default -MaximumRedirection 5) and .NET issues the
    follow-up as a GET in both cases, so the change is behaviourally inert
    here. The redirect TARGET is what sets the adapcsrf cookie, so no separate
    call is needed to obtain the CSRF token.

    Because the redirect is followed, the status observed below is the FINAL
    one (normally 200), not the 302/303. To see the redirect itself:
        Invoke-WebRequest -Uri "$BaseUrl/j_security_check" -Method Post `
            -Body @{...} -MaximumRedirection 0 -UseBasicParsing
    which throws in 5.1 but exposes the status and Location on the exception's
    Response - see contradiction note 3.
    #>
    param(
        [string] $BaseUrl,
        [pscredential] $Credential,
        [string] $DomainName,
        [switch] $PreGetLoginPage
    )

    # The console takes the domain in its own field, so j_username wants the
    # bare account name. Typing CORP\svc_reader or svc_reader@corp.local at the
    # Get-Credential prompt is easy muscle memory and produces a 200 serving the
    # login page again - which trips the cookie assertion with a message that
    # points at the password rather than the real cause. Warn, don't rewrite:
    # some deployments may genuinely expect a qualified name.
    if ($Credential.UserName -match '[\\@]') {
        Write-Warning ("Username '$($Credential.UserName)' looks domain-qualified. " +
            "The domain goes in the '$($Endpoint.FieldDomain)' field (-DomainName '$DomainName'), " +
            "so '$($Endpoint.FieldUsername)' normally wants just the account name. " +
            "If login fails, retry with the bare username.")
    }

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
        $loginResponse = Invoke-WebRequest -Uri $loginUri -Method Post -Body $body -Headers $headers `
            -ContentType $FormContentType -WebSession $session `
            -UseBasicParsing -TimeoutSec $HttpTimeoutSeconds
    }
    else {
        $loginResponse = Invoke-WebRequest -Uri $loginUri -Method Post -Body $body -Headers $headers `
            -ContentType $FormContentType -SessionVariable session `
            -UseBasicParsing -TimeoutSec $HttpTimeoutSeconds
    }

    # Where the redirect chain actually ended. Worth logging because the whole
    # login flow depends on it: adapcsrf is set by the redirect TARGET, and
    # GetCookies() looks the cookie up by $BaseUrl - so if an upgrade ever
    # redirects to a different host, port or scheme, the cookie lands under a
    # domain the assertion doesn't check and login "fails" for a reason that is
    # otherwise invisible. Also flags a bounce straight back to a login page.
    $finalUri = $null
    try { $finalUri = $loginResponse.BaseResponse.ResponseUri.AbsoluteUri } catch { }
    Write-Verbose "Login POST to $loginUri ended at $finalUri (final status $($loginResponse.StatusCode) after any redirects)."

    if ($finalUri -and $finalUri -notlike "$BaseUrl*") {
        Write-Warning ("Login redirect ended on '$finalUri', outside -BaseUrl '$BaseUrl'. " +
            "Cookies set there will not be found by the session check. " +
            "If login fails, set -BaseUrl to match where the console actually redirects.")
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

    # U+FEFF (BOM) is NOT whitespace to .NET, so TrimStart() leaves it in place
    # and a perfectly good JSON body reads as "not JSON". Java servlet stacks
    # emit one often enough that this is worth stripping explicitly.
    $trimmed = $Text.TrimStart([char]0xFEFF, [char]0x200B).TrimStart()

    return $trimmed.StartsWith('{') -or $trimmed.StartsWith('[')
}

function New-AdapHeaders {
    <#
    Builds the header set for a console call, shared by the report call and any
    prerequisite call so both present identically to the security filter.

    The baseline pair is an INFERENCE from a trimmed capture, not a certainty.
    ManageEngine's filter sits in front of every request and can reject on
    header shape alone - a missing Origin, a non-browser User-Agent - surfacing
    as a 403 that looks nothing like an auth problem. -UseCapturedHeaders
    replays what the browser actually sent, which is how to rule that out.
    #>
    param([hashtable] $CapturedHeaders)

    $headers = @{
        'X-Requested-With' = 'XMLHttpRequest'
        'Referer'          = "$BaseUrl/"
    }

    # Headers PowerShell sets itself, or that must not be replayed from a
    # capture. Cookie above all: those are dead session tokens and would fight
    # the live ones carried by -WebSession.
    $skipHeaders = @(
        'cookie', 'content-length', 'content-type', 'host', 'accept-encoding',
        'connection', 'transfer-encoding', 'expect', 'date', 'if-modified-since',
        'range', 'proxy-connection', 'user-agent'
    )

    $userAgent = $null

    if ($UseCapturedHeaders -and $CapturedHeaders) {
        foreach ($name in $CapturedHeaders.Keys) {
            if ($name.ToLower() -eq 'user-agent') {
                # Restricted on HttpWebRequest - must go via -UserAgent.
                $userAgent = $CapturedHeaders[$name]
                continue
            }
            if ($skipHeaders -contains $name.ToLower()) { continue }
            $headers[$name] = $CapturedHeaders[$name]
        }
    }

    foreach ($name in $ExtraHeaders.Keys) {
        if ($name.ToLower() -eq 'user-agent') {
            $userAgent = $ExtraHeaders[$name]
            continue
        }
        $headers[$name] = $ExtraHeaders[$name]
    }

    [pscustomobject]@{ Headers = $headers; UserAgent = $userAgent }
}

function Save-FailedResponse {
    <#
    Dumps a response that could not be interpreted next to the transcript, so
    the whole body can be read rather than a 500-char console preview. These
    endpoints are undocumented; the body IS the documentation when something
    changes.
    #>
    param(
        [string] $Content,
        [int]    $PageNo
    )

    try {
        $dir = Split-Path $LogPath -Parent
        $file = Join-Path $dir ("AdapFailedResponse_page{0}_{1}.txt" -f $PageNo, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Set-Content -Path $file -Value $Content -Encoding UTF8
        return $file
    }
    catch {
        Write-Warning "Could not write the failed response to disk: $($_.Exception.Message)"
        return $null
    }
}

function ConvertFrom-CurlCommand {
    <#
    Extracts the URL and the request body from a complete cURL command pasted
    verbatim - the "Copy as cURL" output from browser devtools.

    This exists because re-capturing IS the maintenance procedure for this
    script: there are no docs, so every product upgrade is diagnosed by grabbing
    a fresh capture. Making the whole command pasteable removes the hand-editing
    step, which is where transcription mistakes creep in.

    Headers and cookies in the pasted command are IGNORED by design. The script
    sets its own headers, and the captured cookies are dead session tokens that
    must never be reused - live ones come from logging in.

    Known limitation: bash's '\'' idiom for a literal single quote inside a
    single-quoted argument is not reassembled. Rare in these bodies; if a value
    contains an apostrophe, pass the body via -RawReportFormData instead.
    #>
    param([string] $CurlCommand)

    # Join line continuations: '\' (bash), '^' (cmd), '`' (PowerShell).
    $text = $CurlCommand -replace '[\\^`]\s*\r?\n', ' '
    $text = $text -replace '\r?\n', ' '

    # Tokenize honouring single quotes, double quotes and bare words.
    $pattern = '''([^'']*)''|"((?:[^"\\]|\\.)*)"|(\S+)'
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($text, $pattern)) {
        if ($m.Groups[1].Success) {
            [void]$tokens.Add($m.Groups[1].Value)
        }
        elseif ($m.Groups[2].Success) {
            [void]$tokens.Add(($m.Groups[2].Value -replace '\\(.)', '$1'))
        }
        else {
            [void]$tokens.Add($m.Groups[3].Value)
        }
    }

    $url = $null
    $data = $null
    $method = $null
    $headers = @{}
    $dataFlags = @('--data-raw', '--data-binary', '--data-urlencode', '--data', '-d')

    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i]

        if (-not $url -and $token -match '^https?://') {
            $url = $token
            continue
        }

        if (($token -eq '-X' -or $token -eq '--request') -and ($i + 1) -lt $tokens.Count) {
            $method = $tokens[$i + 1]
            $i++
            continue
        }

        if (($token -eq '-H' -or $token -eq '--header') -and ($i + 1) -lt $tokens.Count) {
            $headerText = $tokens[$i + 1]
            $i++
            $colon = $headerText.IndexOf(':')
            if ($colon -gt 0) {
                $headers[$headerText.Substring(0, $colon).Trim()] = $headerText.Substring($colon + 1).Trim()
            }
            continue
        }

        if ($dataFlags -contains $token -and ($i + 1) -lt $tokens.Count) {
            # Last data flag wins, matching how cURL itself would behave for
            # a single body (repeated -d would concatenate, which these
            # captures do not do).
            $data = $tokens[$i + 1]
            $i++
        }
    }

    if (-not $url) {
        throw 'Could not find an http(s) URL in the pasted cURL command.'
    }

    # A body is not required: a prerequisite/priming call may well be a GET.
    # Callers that DO need one validate for themselves.
    if (-not $method) {
        $method = if ($null -ne $data) { 'POST' } else { 'GET' }
    }

    $uri = [uri]$url

    [pscustomobject]@{
        BaseUrl = '{0}://{1}' -f $uri.Scheme, $uri.Authority
        Path    = $uri.AbsolutePath
        Query   = $uri.Query
        Method  = $method.ToUpper()
        Data    = $data
        Headers = $headers
    }
}

function ConvertFrom-FormUrlEncoded {
    <#
    Parses a cURL --data-raw value into an ORDERED list of name/value pairs.

    Deliberately a list, not a hashtable: real console report bodies repeat keys
    (columns=A&columns=B&columns=C is the usual way a multi-select is sent), and
    a hashtable silently keeps only the last one. Order is preserved too, since
    an undocumented Struts action may care about it.
    #>
    param([string] $FormData)

    $pairs = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($FormData)) { return $pairs }

    # Tolerate the whole cURL argument being pasted, not just its value:
    # "--data-raw 'a=1&b=2'" is stripped down to "a=1&b=2". Without this, the
    # flag becomes part of the first field NAME and the request silently goes
    # out malformed - the server answers, just not with the expected data.
    # Also tolerates a leading '?' and surrounding quotes.
    $text = $FormData.Trim()
    $text = $text -replace "^(--data-raw|--data-binary|--data-urlencode|--data|-d)\s+", ''
    $text = $text.Trim().Trim("'", '"').TrimStart('?').Trim()

    foreach ($segment in $text -split '&') {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }

        # Split on the FIRST '=' only - an unencoded '=' inside a value is
        # common in base64-ish or JSON-ish field values.
        $eq = $segment.IndexOf('=')
        if ($eq -lt 0) {
            $name = $segment
            $value = ''
        }
        else {
            $name = $segment.Substring(0, $eq)
            $value = $segment.Substring($eq + 1)
        }

        # WebUtility (not Uri.UnescapeDataString) because form encoding uses
        # '+' for space, which UnescapeDataString would leave as a literal '+'.
        [void]$pairs.Add([pscustomobject]@{
            Name  = [System.Net.WebUtility]::UrlDecode($name)
            Value = [System.Net.WebUtility]::UrlDecode($value)
        })
    }

    return $pairs
}

function Set-FormField {
    <#
    Sets a field to a single value, replacing every existing occurrence.
    Used for the fields this script owns, so a stale value pasted in from a
    capture (expired adapcsrf, page=1, last month's dates) cannot survive.
    #>
    param(
        [System.Collections.Generic.List[object]] $Pairs,
        [string] $Name,
        $Value
    )

    # -ceq: HTTP form field names are case-sensitive.
    $existing = @($Pairs | Where-Object { $_.Name -ceq $Name })

    if ($existing.Count -gt 0) {
        $existing[0].Value = [string]$Value
        for ($i = 1; $i -lt $existing.Count; $i++) { [void]$Pairs.Remove($existing[$i]) }
    }
    else {
        [void]$Pairs.Add([pscustomobject]@{ Name = $Name; Value = [string]$Value })
    }
}

function ConvertTo-FormUrlEncoded {
    param([System.Collections.Generic.List[object]] $Pairs)

    # EscapeDataString percent-encodes everything outside the unreserved set,
    # so a literal '+' in a value becomes %2B rather than being read as a space.
    ($Pairs | ForEach-Object {
        '{0}={1}' -f [uri]::EscapeDataString($_.Name), [uri]::EscapeDataString([string]$_.Value)
    }) -join '&'
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

    # Body is assembled as an ordered pair list and encoded to a string, NOT
    # passed as a hashtable. Two reasons: real console bodies repeat keys
    # (columns=A&columns=B), which a hashtable collapses to one; and a hashtable
    # has no defined ordering, which an undocumented Struts action may care
    # about. Building the string ourselves keeps the request byte-comparable to
    # the capture.
    $pairs = ConvertFrom-FormUrlEncoded -FormData $RawReportFormData

    # Caller-supplied additions/overrides, applied over the pasted capture.
    foreach ($key in $ExtraReportFields.Keys) {
        Set-FormField -Pairs $pairs -Name $key -Value $ExtraReportFields[$key]
    }

    # Fields this script owns are applied LAST and always win, so a stale
    # adapcsrf, page number or date range pasted in via -RawReportFormData
    # cannot leak into the live request.
    Set-FormField -Pairs $pairs -Name $Endpoint.FieldCsrf       -Value $Csrf
    Set-FormField -Pairs $pairs -Name $Endpoint.FieldDomain     -Value $DomainName
    Set-FormField -Pairs $pairs -Name $Endpoint.FieldReportType -Value $ReportType
    Set-FormField -Pairs $pairs -Name $Endpoint.FieldStartTime  -Value $StartEpochMs
    Set-FormField -Pairs $pairs -Name $Endpoint.FieldEndTime    -Value $EndEpochMs
    Set-FormField -Pairs $pairs -Name $Endpoint.FieldPage       -Value $PageNo
    Set-FormField -Pairs $pairs -Name $Endpoint.FieldRange      -Value $Range

    $body = ConvertTo-FormUrlEncoded -Pairs $pairs

    # -Verbose prints the outgoing body with the CSRF token masked, for
    # diffing against the capture when a call misbehaves.
    if ($VerbosePreference -ne 'SilentlyContinue') {
        $masked = ConvertFrom-FormUrlEncoded -FormData $body
        Set-FormField -Pairs $masked -Name $Endpoint.FieldCsrf -Value '<masked>'
        Write-Verbose "POST body (page $PageNo): $(ConvertTo-FormUrlEncoded -Pairs $masked)"
    }

    $headerSet = New-AdapHeaders -CapturedHeaders $script:CapturedHeaders
    $headers = $headerSet.Headers
    $userAgent = $headerSet.UserAgent

    $uri = "$BaseUrl$($Endpoint.ReportPath)"

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $requestArgs = @{
                Uri             = $uri
                Method          = 'Post'
                Body            = $body
                Headers         = $headers
                ContentType     = $FormContentType
                WebSession      = $Session
                UseBasicParsing = $true
                TimeoutSec      = $HttpTimeoutSeconds
            }
            if ($userAgent) { $requestArgs['UserAgent'] = $userAgent }

            $response = Invoke-WebRequest @requestArgs

            # Content-Type and the landed URI are carried alongside the body:
            # when a response is not JSON, those two say why far faster than
            # reading the body does (text/html = an error or login page; a URI
            # under a different path = a redirect somewhere unexpected).
            $responseContentType = $null
            try { $responseContentType = $response.Headers['Content-Type'] } catch { }
            $responseUri = $null
            try { $responseUri = $response.BaseResponse.ResponseUri.AbsoluteUri } catch { }

            return [pscustomobject]@{
                Content     = $response.Content
                ContentType = $responseContentType
                StatusCode  = [int]$response.StatusCode
                ResponseUri = $responseUri
            }
        }
        catch {
            $detail = Get-HttpErrorDetail -ErrorRecord $_
            $message = $_.Exception.Message
            if ($detail.StatusCode) { $message = "[HTTP $($detail.StatusCode)] $message" }
            if ($detail.Body) {
                # The error body is the only documentation these endpoints have.
                # Dump it whole rather than truncating it into the message.
                $dumpPath = Save-FailedResponse -Content $detail.Body -PageNo $PageNo
                $bodyPreview = $detail.Body
                if ($bodyPreview.Length -gt 500) { $bodyPreview = $bodyPreview.Substring(0, 500) + '...' }
                $message = "$message Requested: $uri. Response body: $bodyPreview"
                if ($dumpPath) { $message = "$message (full body: $dumpPath)" }
            }

            if ($detail.StatusCode -eq 403) {
                $message = ("$message`nA 403 here is usually one of: the report path does not exist on this " +
                    "build (this console answers unknown paths with 403, not 404); the security filter is " +
                    "rejecting the request shape (try -UseCapturedHeaders to replay the browser's headers); " +
                    "a stale or missing CSRF field; or the account lacks rights to this report.")
            }

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

function Invoke-AdapPrerequisiteCall {
    <#
    Replays a captured call that the console makes BEFORE the report data call -
    e.g. getReportInputParams. Nothing about it is guessed: the path, method,
    body and headers all come from the pasted capture.

    Why it matters: the console's report screen is a two-step flow. The first
    call primes server-side, session-scoped state for the report; the data call
    is then served against that state. Skipping it makes every report 403,
    because the filter rejects a data call for a report the session never set
    up - which reads exactly like an auth or permissions failure and is not.

    Consequently this must run again after every re-authentication: a new
    session has none of the primed state.

    Returns the response body so it can be inspected. If the priming response
    turns out to carry values the data call needs (a handle, a config id, a
    rotated token), those are NOT wired through yet - that needs a capture of
    the response to do correctly.
    #>
    param(
        [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [string] $Csrf
    )

    if (-not $script:PreReportCall) { return $null }

    $call = $script:PreReportCall
    $uri = "$BaseUrl$($call.Path)$($call.Query)"

    $headerSet = New-AdapHeaders -CapturedHeaders $call.Headers
    $requestArgs = @{
        Uri             = $uri
        Method          = $call.Method
        Headers         = $headerSet.Headers
        WebSession      = $Session
        UseBasicParsing = $true
        TimeoutSec      = $HttpTimeoutSeconds
    }
    if ($headerSet.UserAgent) { $requestArgs['UserAgent'] = $headerSet.UserAgent }

    if ($null -ne $call.Data) {
        # Only the CSRF field is refreshed - everything else is sent exactly as
        # captured, because which fields matter here is unknown.
        $pairs = ConvertFrom-FormUrlEncoded -FormData $call.Data
        $existingCsrf = @($pairs | Where-Object { $_.Name -ceq $Endpoint.FieldCsrf })
        if ($existingCsrf.Count -gt 0) {
            Set-FormField -Pairs $pairs -Name $Endpoint.FieldCsrf -Value $Csrf
        }

        $requestArgs['Body'] = ConvertTo-FormUrlEncoded -Pairs $pairs
        $requestArgs['ContentType'] = $FormContentType

        if ($VerbosePreference -ne 'SilentlyContinue') {
            $masked = ConvertFrom-FormUrlEncoded -FormData $requestArgs['Body']
            if (@($masked | Where-Object { $_.Name -ceq $Endpoint.FieldCsrf }).Count -gt 0) {
                Set-FormField -Pairs $masked -Name $Endpoint.FieldCsrf -Value '<masked>'
            }
            Write-Verbose "Prerequisite $($call.Method) body: $(ConvertTo-FormUrlEncoded -Pairs $masked)"
        }
    }

    Write-Verbose "Prerequisite call: $($call.Method) $uri"

    try {
        $response = Invoke-WebRequest @requestArgs
        Write-Verbose "Prerequisite call returned HTTP $([int]$response.StatusCode), $($response.Content.Length) chars."
        return $response.Content
    }
    catch {
        $detail = Get-HttpErrorDetail -ErrorRecord $_
        $dumpPath = $null
        if ($detail.Body) { $dumpPath = Save-FailedResponse -Content $detail.Body -PageNo 0 }

        $message = "Prerequisite call failed: $($call.Method) $uri"
        if ($detail.StatusCode) { $message = "$message [HTTP $($detail.StatusCode)]" }
        $message = "$message - $($_.Exception.Message)"
        if ($dumpPath) { $message = "$message (response body: $dumpPath)" }

        throw $message
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

    $result = Invoke-AdapReportPage -Session $script:AdapSession -BaseUrl $BaseUrl `
        -Csrf $script:AdapCsrf -PageNo $PageNo -StartEpochMs $StartEpochMs -EndEpochMs $EndEpochMs

    if (Test-LooksLikeJson -Text $result.Content) { return $result.Content }

    Write-Warning ("Page $PageNo returned a non-JSON body (HTTP $($result.StatusCode), " +
        "Content-Type '$($result.ContentType)'). Re-authenticating and retrying.")

    $script:AdapSession = Connect-AdapSession -BaseUrl $BaseUrl -Credential $Credential `
        -DomainName $DomainName -PreGetLoginPage:$PreGetLoginPage
    $script:AdapCsrf = Assert-AdapSession -Session $script:AdapSession -BaseUrl $BaseUrl

    # The new session has none of the report state the previous one was primed
    # with, so the priming call has to be replayed before the data call.
    [void](Invoke-AdapPrerequisiteCall -Session $script:AdapSession -Csrf $script:AdapCsrf)

    $result = Invoke-AdapReportPage -Session $script:AdapSession -BaseUrl $BaseUrl `
        -Csrf $script:AdapCsrf -PageNo $PageNo -StartEpochMs $StartEpochMs -EndEpochMs $EndEpochMs

    if (-not (Test-LooksLikeJson -Text $result.Content)) {
        # A fresh login did not fix it, so this is NOT session expiry. The
        # likely causes, in rough order: the report path or a field name changed
        # (product upgrade), a required field is missing from the body, or the
        # console is returning an HTML error page for the request as sent.
        $dumpPath = Save-FailedResponse -Content $result.Content -PageNo $PageNo

        $preview = $result.Content
        if ($null -eq $preview) { $preview = '(empty response)' }
        elseif ($preview.Length -gt 500) { $preview = $preview.Substring(0, 500) + '...' }

        $lines = @(
            "Page $PageNo returned a non-JSON body even after re-authenticating, so this is not session expiry."
            "  HTTP status:  $($result.StatusCode)"
            "  Content-Type: $($result.ContentType)"
            "  Landed at:    $($result.ResponseUri)"
            "  Requested:    $BaseUrl$($Endpoint.ReportPath)"
            "  Body length:  $(if ($result.Content) { $result.Content.Length } else { 0 }) chars"
        )
        if ($dumpPath) { $lines += "  Full response written to: $dumpPath" }
        $lines += "  First 500 chars: $preview"
        $lines += "Check: does the report path still exist on this build, and does the POST body carry every field the console sends? Re-capture and compare with -Verbose."

        throw ($lines -join [Environment]::NewLine)
    }

    return $result.Content
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
    # A pasted cURL command supplies the endpoint and body. Done before anything
    # else so the rest of the run uses the captured values.
    if ($ReportCurlCommand) {
        $parsedCurl = ConvertFrom-CurlCommand -CurlCommand $ReportCurlCommand

        # An explicit -BaseUrl wins - the capture may name a hostname that only
        # resolves from the workstation the capture was taken on.
        if (-not $PSBoundParameters.ContainsKey('BaseUrl')) {
            $BaseUrl = $parsedCurl.BaseUrl
        }
        elseif ($BaseUrl -ne $parsedCurl.BaseUrl) {
            Write-Warning "Pasted cURL targets '$($parsedCurl.BaseUrl)' but -BaseUrl says '$BaseUrl'. Using -BaseUrl."
        }

        if ($parsedCurl.Path -ne $Endpoint.ReportPath) {
            Write-Warning ("Pasted cURL uses report path '$($parsedCurl.Path)', not the built-in " +
                "'$($Endpoint.ReportPath)'. Using the pasted one - if this is a product upgrade, " +
                'update the $Endpoint block so the default matches.')
        }
        $Endpoint.ReportPath = $parsedCurl.Path

        # The parser allows a body-less command (a prerequisite call may be a
        # GET), so the report command has to insist on one itself.
        if ($null -eq $parsedCurl.Data -and -not $RawReportFormData) {
            throw ('The cURL passed to -ReportCurlCommand has no --data-raw/--data/-d argument. ' +
                'The report call is a POST with a form body - this looks like a different request. ' +
                'If it is the prerequisite call, pass it as -PreReportCurlCommand instead.')
        }

        # -RawReportFormData is the more specific input, so it wins if both given.
        if (-not $RawReportFormData) {
            $RawReportFormData = $parsedCurl.Data
        }
        else {
            Write-Warning 'Both -ReportCurlCommand and -RawReportFormData given; using -RawReportFormData for the body.'
        }

        $script:CapturedHeaders = $parsedCurl.Headers

        Write-Verbose "From pasted cURL: base '$BaseUrl', path '$($Endpoint.ReportPath)', body $($RawReportFormData.Length) chars, $($parsedCurl.Headers.Count) header(s)."

        if ($UseCapturedHeaders -and $parsedCurl.Headers.Count -eq 0) {
            Write-Warning '-UseCapturedHeaders was given but the pasted cURL contained no -H headers.'
        }
    }
    elseif ($UseCapturedHeaders) {
        Write-Warning '-UseCapturedHeaders has no effect without -ReportCurlCommand to take headers from.'
    }

    $script:PreReportCall = $null
    if ($PreReportCurlCommand) {
        $script:PreReportCall = ConvertFrom-CurlCommand -CurlCommand $PreReportCurlCommand
        Write-Verbose ("Prerequisite call parsed: $($script:PreReportCall.Method) " +
            "$($script:PreReportCall.Path)$($script:PreReportCall.Query), " +
            "$(if ($script:PreReportCall.Data) { $script:PreReportCall.Data.Length } else { 0 }) body chars, " +
            "$($script:PreReportCall.Headers.Count) header(s).")

        if ($script:PreReportCall.BaseUrl -ne $BaseUrl) {
            Write-Warning ("Prerequisite cURL targets '$($script:PreReportCall.BaseUrl)' but the run uses " +
                "'$BaseUrl'. The prerequisite call will be sent to '$BaseUrl'.")
        }
    }

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

        if ($script:PreReportCall) {
            Write-Host "Replaying prerequisite call: $($script:PreReportCall.Method) $($script:PreReportCall.Path)"
            [void](Invoke-AdapPrerequisiteCall -Session $script:AdapSession -Csrf $script:AdapCsrf)
        }

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
