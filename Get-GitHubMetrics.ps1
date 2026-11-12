<#
.SYNOPSIS
    Pulls engineering metrics for ONE GitHub handle across one or more
    organisations, using the GitHub REST API. No gh CLI needed.

.DESCRIPTION
    For each date period it reports:
      Code Commits (#s)      Non-merge commits authored by the handle that are on the
                             default branch of any repo in the orgs (by author date).
      Pull Requests (#s)     PRs opened by the handle in the period.
      PR Iterations (Count)  Sum over those PRs of: 1 + number of rework rounds
                             (a reviewer comments / requests changes, then the
                             author pushes new commits).
      PR debt (> N days)     PRs by the handle that were open during the period and
                             had been open more than N days by the end of the period
                             (or by the time they were closed, if closed in the period).
      Code Churn rate %      Lines deleted / lines added * 100, over the commits above.

    All dates are treated as UTC days, both ends inclusive.

.EXAMPLE
    .\Get-GitHubMetrics.ps1 -Handle my-handle -Orgs org-one,org-two

.EXAMPLE
    .\Get-GitHubMetrics.ps1 -Handle my-handle -Orgs org-one,org-two `
        -Periods '2026-11-01..2026-11-07','2026-11-08..2026-11-14'

.NOTES
    Token: looked up in this order:
      1. -Token parameter or $env:GITHUB_TOKEN
      2. the HTTPS login Git already stores for github.com (Git Credential Manager)
      3. a prompt
    If you create one yourself: a classic personal access token with the "repo" and
    "read:org" scopes. If your orgs use SAML single sign-on, click "Configure SSO"
    next to the token on github.com and authorise it for BOTH orgs, otherwise
    results come back empty.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Handle,
    [Parameter(Mandatory = $true)][string[]]$Orgs,
    [string[]]$Periods = @('2026-10-01..2026-10-09', '2026-10-10..2026-10-16', '2026-10-17..2026-10-23'),
    [string]$Token = $env:GITHUB_TOKEN,
    [int]$DebtDays = 5,
    [string]$EngineerType = 'Engineer',
    [string]$ApiBase = 'https://api.github.com',
    [string]$OutDir = '.'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$inv = [Globalization.CultureInfo]::InvariantCulture

# Allow "a,b" passed as one string (happens with powershell.exe -File)
$Orgs    = @($Orgs    | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Periods = @($Periods | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Handle  = $Handle.Trim().TrimStart('@')
$ApiBase = $ApiBase.TrimEnd('/')

# Ask Git's credential helper (Git Credential Manager on Windows) for the login it
# already stores for HTTPS pushes/pulls. Never opens a login window or prompt.
function Get-GitStoredToken {
    param([string]$HostName)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    $ErrorActionPreference = 'SilentlyContinue'
    $oldPrompt = $env:GIT_TERMINAL_PROMPT
    $oldGcm = $env:GCM_INTERACTIVE
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GCM_INTERACTIVE = 'never'
    try {
        $out = "protocol=https`nhost=$HostName`n`n" | & git credential fill 2>$null
        foreach ($line in @($out)) {
            if ("$line" -like 'password=*') { return ("$line".Substring(9).Trim()) }
        }
    }
    catch { }
    finally {
        $env:GIT_TERMINAL_PROMPT = $oldPrompt
        $env:GCM_INTERACTIVE = $oldGcm
    }
    return $null
}

$tokenSource = 'the -Token parameter / GITHUB_TOKEN'
if (-not $Token) {
    # api.github.com -> github.com ; api.acme.ghe.com -> acme.ghe.com ; host/api/v3 -> host
    $gitHost = ([uri]$ApiBase).Host -replace '^api\.', ''
    $Token = Get-GitStoredToken $gitHost
    $tokenSource = "Git's stored login for $gitHost"
}
if (-not $Token) {
    Write-Host 'No GITHUB_TOKEN set and no HTTPS login stored by Git (you may be using SSH).' -ForegroundColor Yellow
    $tokenSource = 'the token you typed'
    $secure = Read-Host -Prompt 'GitHub personal access token' -AsSecureString
    $Token = (New-Object System.Net.NetworkCredential('', $secure)).Password
}
if (-not $Token) { throw 'No token supplied. Set $env:GITHUB_TOKEN or pass -Token.' }

$script:Headers = @{
    'Authorization'        = "Bearer $Token"
    'Accept'               = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'Get-GitHubMetrics.ps1'
}

# ---------------------------------------------------------------- helpers ---

function Invoke-GitHub {
    param([string]$Url)
    for ($try = 1; ; $try++) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -Headers $script:Headers -UseBasicParsing
            return ($resp.Content | ConvertFrom-Json)
        }
        catch {
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            $detail = "$($_.ErrorDetails.Message) $($_.Exception.Message)"
            $rateLimited = ($status -eq 429) -or ($status -eq 403 -and $detail -match 'rate limit')
            if ($rateLimited -and $try -le 5) {
                Write-Host '    Rate limited by GitHub, waiting 60s...' -ForegroundColor Yellow
                Start-Sleep -Seconds 60
                continue
            }
            throw "GitHub API call failed (HTTP $status): $Url`n$detail"
        }
    }
}

# Paged list endpoints (reviews, PR commits)
function Get-GitHubList {
    param([string]$Url)
    $all = @()
    $sep = '?'
    if ($Url.Contains('?')) { $sep = '&' }
    for ($page = 1; $page -le 20; $page++) {
        $batch = @(Invoke-GitHub ($Url + $sep + "per_page=100&page=$page"))
        $all += $batch
        if ($batch.Count -lt 100) { break }
    }
    $all
}

# Search endpoints ('issues' or 'commits'). Search is limited to 30 calls/minute.
function Search-GitHub {
    param([string]$Kind, [string]$Query)
    $items = @()
    for ($page = 1; $page -le 10; $page++) {
        $url = "$ApiBase/search/$Kind" + '?q=' + [uri]::EscapeDataString($Query) + "&per_page=100&page=$page"
        try {
            $r = Invoke-GitHub $url
        }
        catch {
            if ("$_" -match 'HTTP 422') {
                throw ("GitHub rejected the search '$Query'.`n" +
                    "Check the handle and org names, and that the token is SSO-authorised for the org.`n$_")
            }
            throw
        }
        Start-Sleep -Milliseconds 2200
        $batch = @($r.items | Where-Object { $_ })
        $items += $batch
        if ($r.total_count -gt 1000 -and $page -eq 1) {
            Write-Warning "Search '$Query' has $($r.total_count) results; GitHub only returns the first 1000."
        }
        if ($batch.Count -lt 100 -or $items.Count -ge $r.total_count) { break }
    }
    $items
}

# Works whether ConvertFrom-Json left the date as a string (PS 5.1) or parsed it (PS 7)
function ConvertTo-Utc {
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ([string]::IsNullOrEmpty([string]$Value)) { return $null }
    return [DateTimeOffset]::Parse([string]$Value, $inv).UtcDateTime
}

# 1 (initial submission) + number of "review feedback -> author pushes commits" rounds
function Get-PrIterations {
    param($Pr)
    $base = "$ApiBase/repos/$($Pr.Repo)/pulls/$($Pr.Number)"
    $reviews = @(Get-GitHubList "$base/reviews")
    $commits = @(Get-GitHubList "$base/commits")
    $events = @()
    foreach ($r in $reviews) {
        if (-not $r.submitted_at) { continue }
        if ($r.state -ne 'CHANGES_REQUESTED' -and $r.state -ne 'COMMENTED') { continue }
        if (-not $r.user -or $r.user.login -eq $Handle -or $r.user.type -eq 'Bot') { continue }
        $events += [pscustomobject]@{ Time = (ConvertTo-Utc $r.submitted_at); Type = 'R' }
    }
    foreach ($c in $commits) {
        $events += [pscustomobject]@{ Time = (ConvertTo-Utc $c.commit.committer.date); Type = 'C' }
    }
    $iterations = 1
    $awaitingRework = $false
    foreach ($e in ($events | Sort-Object Time)) {
        if ($e.Type -eq 'R') { $awaitingRework = $true }
        elseif ($awaitingRework) { $iterations++; $awaitingRework = $false }
    }
    $iterations
}

# ---------------------------------------------------------------- periods ---

$styles = [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal'
$periodList = @(foreach ($p in $Periods) {
    $parts = @($p -split '\.\.')
    if ($parts.Count -ne 2) { throw "Bad period '$p'. Use yyyy-MM-dd..yyyy-MM-dd" }
    $s = [datetime]::ParseExact($parts[0].Trim(), 'yyyy-MM-dd', $inv, $styles)
    $e = [datetime]::ParseExact($parts[1].Trim(), 'yyyy-MM-dd', $inv, $styles)
    [pscustomobject]@{
        Start        = $s
        EndExclusive = $e.AddDays(1)
        From         = $s.ToString('yyyy-MM-dd', $inv)
        To           = $e.ToString('yyyy-MM-dd', $inv)
        Label        = ('{0} - {1}' -f $s.ToString('d-MMM-yyyy', $inv), $e.ToString('d-MMM-yyyy', $inv))
    }
})
$minFrom = ($periodList | Sort-Object Start | Select-Object -First 1).From
$maxEnd  = ($periodList | Sort-Object EndExclusive | Select-Object -Last 1).EndExclusive.ToString('yyyy-MM-dd', $inv)

# ------------------------------------------------------------------- run ----

$me = Invoke-GitHub "$ApiBase/user"
Write-Host "Using $tokenSource."
Write-Host "Authenticated as $($me.login). Collecting metrics for '$Handle' in: $($Orgs -join ', ')" -ForegroundColor Cyan

# Every PR by the handle that could matter to any period: created before the last
# period ends, and either still open or closed after the first period starts.
$prs = @{}
foreach ($org in $Orgs) {
    Write-Host "[$org] finding pull requests..."
    $queries = @(
        "is:pr author:$Handle org:$org created:<=$maxEnd closed:>=$minFrom",
        "is:pr author:$Handle org:$org created:<=$maxEnd is:open"
    )
    foreach ($q in $queries) {
        foreach ($i in @(Search-GitHub 'issues' $q)) {
            if ($prs.ContainsKey($i.html_url)) { continue }
            $prs[$i.html_url] = [pscustomobject]@{
                Repo    = ($i.repository_url -replace '^.*/repos/', '')
                Number  = $i.number
                Title   = $i.title
                Url     = $i.html_url
                Created = (ConvertTo-Utc $i.created_at)
                Closed  = (ConvertTo-Utc $i.closed_at)
                Merged  = [bool]$i.pull_request.merged_at
            }
        }
    }
}
$allPrs = @($prs.Values)

$row = [ordered]@{ 'GitHub Handle' = $Handle }
$prDetail = @()
$commitDetail = @()

foreach ($period in $periodList) {
    Write-Host "Period $($period.Label)" -ForegroundColor Cyan

    # --- commits + churn ---
    $seen = @{}
    $added = 0
    $deleted = 0
    foreach ($org in $Orgs) {
        $q = "author:$Handle org:$org author-date:$($period.From)..$($period.To) merge:false"
        foreach ($c in @(Search-GitHub 'commits' $q)) {
            if ($seen.ContainsKey($c.sha)) { continue }
            $seen[$c.sha] = $true
            $repo = $c.repository.full_name
            $a = 0
            $d = 0
            try {
                $full = Invoke-GitHub "$ApiBase/repos/$repo/commits/$($c.sha)"
                $a = [int]$full.stats.additions
                $d = [int]$full.stats.deletions
            }
            catch { Write-Warning "Could not read line stats for $repo@$($c.sha): $_" }
            $added += $a
            $deleted += $d
            $commitDetail += [pscustomobject]@{
                Period    = $period.Label
                Repo      = $repo
                Sha       = $c.sha
                Date      = (ConvertTo-Utc $c.commit.author.date).ToString('yyyy-MM-dd HH:mm', $inv)
                Additions = $a
                Deletions = $d
                Message   = (($c.commit.message -split "`n")[0])
                Url       = $c.html_url
            }
        }
    }
    $commitCount = $seen.Count
    $churn = 0
    if ($added -gt 0) { $churn = [math]::Round(($deleted / $added) * 100, 1) }

    # --- PRs opened in the period + iterations ---
    $opened = @($allPrs | Where-Object { $_.Created -ge $period.Start -and $_.Created -lt $period.EndExclusive })
    $iterTotal = 0
    $iterByUrl = @{}
    foreach ($pr in $opened) {
        $n = 1
        try { $n = Get-PrIterations $pr }
        catch { Write-Warning "Could not read reviews for $($pr.Url), counting it as 1 iteration: $_" }
        $iterByUrl[$pr.Url] = $n
        $iterTotal += $n
    }

    # --- PR debt ---
    $debtCount = 0
    $relevant = @($allPrs | Where-Object {
        $_.Created -lt $period.EndExclusive -and ($null -eq $_.Closed -or $_.Closed -ge $period.Start)
    })
    foreach ($pr in ($relevant | Sort-Object Created)) {
        $cutoff = $period.EndExclusive
        if ($null -ne $pr.Closed -and $pr.Closed -lt $cutoff) { $cutoff = $pr.Closed }
        $age = ($cutoff - $pr.Created).TotalDays
        $isDebt = $age -gt $DebtDays
        if ($isDebt) { $debtCount++ }
        $isOpened = $iterByUrl.ContainsKey($pr.Url)
        if (-not $isDebt -and -not $isOpened) { continue }
        $state = 'open'
        if ($pr.Merged) { $state = 'merged' } elseif ($null -ne $pr.Closed) { $state = 'closed' }
        $closedText = ''
        if ($null -ne $pr.Closed) { $closedText = $pr.Closed.ToString('yyyy-MM-dd HH:mm', $inv) }
        $iterText = ''
        if ($isOpened) { $iterText = $iterByUrl[$pr.Url] }
        $prDetail += [pscustomobject]@{
            Period            = $period.Label
            Repo              = $pr.Repo
            PR                = $pr.Number
            Title             = $pr.Title
            OpenedInPeriod    = $isOpened
            Iterations        = $iterText
            Created           = $pr.Created.ToString('yyyy-MM-dd HH:mm', $inv)
            Closed            = $closedText
            StateNow          = $state
            DaysOpenInPeriod  = [math]::Round($age, 1)
            CountedAsDebt     = $isDebt
            Url               = $pr.Url
        }
    }

    $row["Code Commits (#s) $($period.Label)"]              = $commitCount
    $row["Pull Requests (#s) $($period.Label)"]             = $opened.Count
    $row["PR Iterations (Count) $($period.Label)"]          = $iterTotal
    $row["PR debt (> $DebtDays days) $($period.Label)"]     = $debtCount
    $row["Code Churn rate % ( *100) $($period.Label)"]      = $churn
}
$row['Engineer / Non Engineer'] = $EngineerType

# ---------------------------------------------------------------- output ----

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$summaryPath = Join-Path $OutDir "github_metrics_$Handle.csv"
$prPath      = Join-Path $OutDir "github_metrics_${Handle}_pr_detail.csv"
$commitPath  = Join-Path $OutDir "github_metrics_${Handle}_commit_detail.csv"

$summary = [pscustomobject]$row
$summary | Export-Csv -Path $summaryPath -NoTypeInformation -Encoding UTF8
if ($prDetail.Count -gt 0)     { $prDetail     | Export-Csv -Path $prPath     -NoTypeInformation -Encoding UTF8 }
if ($commitDetail.Count -gt 0) { $commitDetail | Export-Csv -Path $commitPath -NoTypeInformation -Encoding UTF8 }

Write-Host ''
foreach ($prop in $summary.PSObject.Properties) {
    Write-Host ('{0,-52} : {1}' -f $prop.Name, $prop.Value)
}
Write-Host ''
Write-Host "Summary row : $summaryPath" -ForegroundColor Green
if ($prDetail.Count -gt 0)     { Write-Host "PR detail   : $prPath" -ForegroundColor Green }
if ($commitDetail.Count -gt 0) { Write-Host "Commit detail: $commitPath" -ForegroundColor Green }
