#Requires -Version 5
<#
.SYNOPSIS
    Find-VpnGate.ps1 (v1.1) - finds working VPN Gate servers for SoftEther VPN Client.

.DESCRIPTION
    1. Downloads the current VPN Gate server list (official CDN download.vpngate.jp first,
       then vpngate.net, then the local cache).
    2. Fast parallel TCP-probe of every server:port -> filters out dead ones, measures latency.
       If nothing is reachable and a VPN session is active, the session is disconnected
       and the probe is retried directly (unless -KeepTunnel).
    3. Shows a table of ALL servers - live ones with measured latency, dead ones marked DEAD.
    4. After the table - interactive menu: type a VPN number to connect to it,
       A = sweep all live servers one by one, B = rescan, D = test the current session, C = exit.
       The connection is verified: the Internet must really go through the tunnel.
    5. -Watchdog mode keeps your VPN alive: connects automatically and re-connects
       whenever the session drops (handy when the network opens and closes in waves).

.EXAMPLES
    .\Find-VpnGate.ps1                        # scan, then type a VPN number to connect
    .\Find-VpnGate.ps1 -Watchdog                 # keep your VPN alive: auto-restore/rescan
    .\Find-VpnGate.ps1 -Country US,JP         # scan only selected countries
    .\Find-VpnGate.ps1 -Connect               # scan and auto-connect to the first working one
    .\Find-VpnGate.ps1 -Connect -Index 3      # connect to row #3 from the table
    .\Find-VpnGate.ps1 -Connect -DisconnectAfter   # test and disconnect after success
    .\Find-VpnGate.ps1 -ProbeTimeoutMs 5000   # for slow / lossy networks
    .\Find-VpnGate.ps1 -Exclude none          # do not skip RU/BY/UA servers
    .\Find-VpnGate.ps1 -CsvPath C:\temp\servers.csv  # use a manually saved CSV
#>
param(
    [string[]]$Country = @(),          # country filter: US,JP,RU ...
    [string[]]$CountryPriority = @(),  # sweep order: these countries first, then the rest
    [string[]]$Exclude = @(),          # hide these countries from the list (codes: RU,TH,...)
    [int]$Top = 0,                     # probe only the top-N servers by VPN Gate score (0 = all)
    [string]$CsvPath = '',             # use local CSV file instead of downloading
    [switch]$Connect,                  # after scan - try to actually connect
    [int]$ConnectTries = 0,            # cap for auto-connect candidates (0 = sweep ALL servers)
    [int]$Index = 0,                   # connect to specific row number from the scan table
    [int]$ProbeTimeoutMs = 2000,       # TCP probe timeout
    [int]$ProbeConcurrency = 64,       # parallel probe threads
    [int]$ConnectWaitSec = 6,          # seconds per attempt (SoftEther's own connect timeout is ~5-6 s)
    [switch]$DisconnectAfter,          # disconnect+delete the test account even on success
    [switch]$KeepTunnel,               # do not auto-disconnect a (half-dead) active session on retry
    [switch]$Watchdog,                 # keep your VPN alive: auto-restore/rescan when the session drops
    [switch]$NoCache,                  # do not use the cached server list
    [string]$VpncmdPath = ''           # path to vpncmd.exe (auto-detected by default)
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# safety net: any unexpected error -> readable message instead of a silently closing window
trap {
    Write-Host ''
    Write-Host '=== UNEXPECTED SCRIPT ERROR ===' -ForegroundColor Red
    Write-Host ("Type:    {0}" -f $_.Exception.GetType().FullName) -ForegroundColor Red
    Write-Host ("Message: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ("Stack:   {0}" -f $_.ScriptStackTrace) -ForegroundColor Red
    exit 1
}

$Urls = @(
    # official CDN on a separate domain - reachable from RU even without an active VPN
    'https://download.vpngate.jp/api/iphone/',
    'http://www.vpngate.net/api/iphone/',
    'https://www.vpngate.net/api/iphone/'
)
$CacheFile    = Join-Path $env:TEMP 'vpngate_cache.csv'
$ResultFile   = Join-Path $env:TEMP 'vpgate_scan.csv'
$DefaultPorts = @(443, 992, 1194, 5555)
$TestAccount  = 'VGAutoTest'   # no spaces: the account is created via stdin batch
$TemplateFile = Join-Path $env:TEMP 'vg_template.vpn'   # the app's account exported with all hidden settings
$Hub          = 'VPNGATE'
$User         = 'VPN'
$Password     = 'VPN'
$NicName      = 'VPN'

# ---------------------------------------------------------------- helpers

function Invoke-VpnCmd {
    param([string[]]$Tokens, [int]$TimeoutSec = 20, [string[]]$StdIn = $null)
    # runs vpncmd as a watched process: if the client service is stuck (e.g. its
    # reconnect loop / error dialog), we get a visible timeout instead of a hang.
    # With -StdIn several commands run in ONE process (much faster than one spawn per call).
    if ($StdIn) {
        $argLine = '/CLIENT localhost /CMD'
    } else {
        $argLine = '/CLIENT localhost /CMD ' + (($Tokens | ForEach-Object {
                    if ($_ -match '\s') { '"' + ($_ -replace '"', '') + '"' } else { $_ }
                }) -join ' ')
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:VpncmdPath
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = ($null -ne $StdIn)
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($StdIn) {
        $si = $p.StandardInput
        foreach ($l in $StdIn) { $si.WriteLine($l) }
        $si.WriteLine('quit')
        $si.Close()
    }
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        return ("VPNCMD_TIMEOUT after {0}s: {1}" -f $TimeoutSec, ($Tokens -join ' '))
    }
    return (($so.Result + $se.Result) | Out-String)
}

function Get-PublicIp {
    foreach ($u in @('http://api.ipify.org/', 'http://checkip.amazonaws.com/')) {
        try {
            $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 8
            if ($r.Content) { return ([string]$r.Content).Trim() }
        } catch { }
    }
    return $null
}

function To-Num($v, [double]$def = 0) {
    try { return [double]$v } catch { return $def }
}

function Format-Uptime([long]$sec) {
    if ($sec -le 0) { return '-' }
    $t = [TimeSpan]::FromSeconds($sec)
    return ('{0}d {1:D2}h' -f [int]$t.TotalDays, $t.Hours)
}

function Get-ConnectedAccount {
    $txt = Invoke-VpnCmd @('AccountList')
    $name = $null; $res = $null
    foreach ($line in ($txt -split "`r?`n")) {
        if ($line -match 'VPN Connection Setting Name\s*\|\s*(.+?)\s*$') { $name = $Matches[1].Trim() }
        elseif ($name -and $line -match '^\s*Status\s*\|\s*(.+?)\s*$') {
            if ($Matches[1] -match 'Connected') { $res = $name }
            $name = $null
        }
    }
    return $res
}

# status of one account from AccountList: 'Connected' / 'Connecting' / 'Offline'
function Get-AccountStatus([string]$name) {
    $lt = Invoke-VpnCmd @('AccountList') -TimeoutSec 4
    $lines = $lt -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'VPN Connection Setting Name\s*\|\s*(.+?)\s*$' -and $Matches[1].Trim() -eq $name) {
            for ($j = $i + 1; $j -lt [Math]::Min($i + 6, $lines.Count); $j++) {
                if ($lines[$j] -match '^\s*Status\s*\|\s*(.+?)\s*$') { return $Matches[1].Trim() }
            }
        }
    }
    return ''
}

function Read-VpnGateCsv([string]$path) {
    $p = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($path)
    $p.HasFieldsEnclosedInQuotes = $true
    $p.SetDelimiters(',')
    $rows = @()
    try {
        while (-not $p.EndOfData) { $rows += , ($p.ReadFields()) }
    } finally { $p.Close() }

    $hi = -1
    for ($i = 0; $i -lt $rows.Count; $i++) {
        if ($rows[$i].Count -gt 0 -and $rows[$i][0] -like '#HostName*') { $hi = $i; break }
    }
    if ($hi -lt 0) { throw 'CSV header (#HostName,...) not found' }

    $hdr = @($rows[$hi] | ForEach-Object { $_.TrimStart('#') })
    $list = New-Object System.Collections.Generic.List[object]
    for ($i = $hi + 1; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        if ($r.Count -eq 0 -or $r[0] -match '^[\*#]') { continue }
        if ($r.Count -lt $hdr.Count) { continue }
        $o = @{ }
        for ($j = 0; $j -lt $hdr.Count; $j++) { $o[$hdr[$j]] = $r[$j] }
        # if the row has extra trailing columns, the last field is still the OVPN blob
        if ($r.Count -gt $hdr.Count) { $o[$hdr[$hdr.Count - 1]] = $r[$r.Count - 1] }
        $list.Add([pscustomobject]$o)
    }
    # NB: this machine's PS 5.1 has a broken @() operator for List[object] with PSCustomObject
    # elements ("ArgumentException: argument types do not match"), so return a plain object[]
    return ,$list.ToArray()
}

function Invoke-Probe {
    param([object[]]$ServerList, [int]$TimeoutMs)

    $jobList = New-Object System.Collections.Generic.List[object]
    foreach ($s in $ServerList) {
        foreach ($pt in $s.Ports) {
            $jobList.Add([pscustomobject]@{ IP = $s.IP; Port = $pt })
        }
    }
    if ($jobList.Count -eq 0) { return @() }
    Write-Host ("Probing {0} addresses (timeout {1} ms, {2} threads)..." -f $jobList.Count, $TimeoutMs, $ProbeConcurrency) -ForegroundColor Gray

    $probeCode = @'
param($ip, $port, $timeoutMs)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$tcp = New-Object System.Net.Sockets.TcpClient
try {
    $ar = $tcp.BeginConnect($ip, $port, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne($timeoutMs) -and $tcp.Connected) {
        $tcp.EndConnect($ar)
        $sw.Stop()
        return @{ IP = $ip; Port = $port; OK = $true; MS = [int]$sw.ElapsedMilliseconds }
    }
    return @{ IP = $ip; Port = $port; OK = $false; MS = 0 }
} catch {
    return @{ IP = $ip; Port = $port; OK = $false; MS = 0 }
} finally { try { $tcp.Close() } catch {} }
'@

    $pool = [runspacefactory]::CreateRunspacePool(1, $ProbeConcurrency)
    $pool.Open()
    $jobs  = @()
    $alive = @()
    foreach ($j in $jobList) {
        $pi = [powershell]::Create()
        $pi.RunspacePool = $pool
        [void]$pi.AddScript($probeCode).AddArgument($j.IP).AddArgument($j.Port).AddArgument($TimeoutMs)
        $jobs += @{ PS = $pi; Handle = $pi.BeginInvoke() }
    }
    $pending = $jobs
    $done = 0
    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()
    while ($pending.Count -gt 0) {
        Start-Sleep -Milliseconds 100
        $still = @()
        foreach ($jb in $pending) {
            if ($jb.Handle.IsCompleted) {
                try {
                    $res = $jb.PS.EndInvoke($jb.Handle)
                    if ($res -and $res.Count -gt 0 -and $res[0].OK) { $alive += , $res[0] }
                } catch { }
                $jb.PS.Dispose()
                $done++
            } else { $still += , $jb }
        }
        $pending = $still
        Write-Progress -Activity 'TCP probe of servers' -Status ("{0} / {1}" -f $done, $jobs.Count) -PercentComplete ([int](100 * $done / $jobs.Count))
    }
    Write-Progress -Activity 'TCP probe of servers' -Completed
    $pool.Close()
    Write-Host ("Probe finished in {0:n1} s, {1} alive endpoints found" -f $swTotal.Elapsed.TotalSeconds, $alive.Count) -ForegroundColor Gray
    return ,$alive
}

# ---------------------------------------------------------------- connect helpers

$script:lastSeenConnected = $null   # account that was up before our first attempt (for restore)
$script:directIpCache = $null       # "direct" reference IP, valid while no session switch happens
$script:triedKeys = @{ }           # candidates already tried in this scan (90 walks forward)
$script:templateCaptured = $false   # template exported from the app's own account

# capture the app's own account as a template (export keeps ALL hidden fields:
# HostUniqueKey, AuthType Anonymous+vpn, PortUDP, DisableQoS ... - these are what make
# the plugin's connections succeed where a from-scratch account gets refused)
function Get-TemplateText {
    if ($script:templateCaptured -and (Test-Path $TemplateFile)) { return (Get-Content $TemplateFile -Raw) }
    $cur = Get-ConnectedAccount
    if ($cur) {
        $r = Invoke-VpnCmd @('AccountExport', $cur, "/SAVEPATH:$TemplateFile")
        if ($r -match 'completed successfully') {
            $script:templateCaptured = $true
            return (Get-Content $TemplateFile -Raw)
        }
    }
    if (Test-Path $TemplateFile) { return (Get-Content $TemplateFile -Raw) }   # template from a previous run
    return $null
}

# write the template as a test-account import file pointed at the given server
function Write-ImportFile([string]$ip, [int]$port) {
    $txt = Get-TemplateText
    if (-not $txt) { return $false }
    $txt = $txt -replace '(string\s+AccountName\s+)[^\r\n]+', '$1 VGAutoTest'
    $txt = $txt -replace '(string\s+Hostname\s+)[^\r\n]+', ('${1} ' + $ip)
    $txt = $txt -replace '(uint\s+Port\s+)\d+', ('${1} ' + $port)
    $txt = $txt -replace '(string\s+DeviceName\s+)[^\r\n]+', '$1 VPN'
    [IO.File]::WriteAllText("$env:TEMP\vg_import.vpn", $txt, (New-Object Text.UTF8Encoding($false)))
    return $true
}

# one full connection attempt: free the adapter, create+connect the test account, verify traffic
function Test-Candidate {
    param($c, [switch]$SkipDisconnectCheck)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # capture the template while the session (and its account) still exists
    $null = Get-TemplateText

    # free the virtual adapter: drop the active session right before the attempt
    if (-not $SkipDisconnectCheck) {
        $cur = Get-ConnectedAccount
        if ($cur) {
            if (-not $script:lastSeenConnected) { $script:lastSeenConnected = $cur }
            Write-Host "The virtual adapter 'VPN' is busy by account '$cur' - disconnecting it..." -ForegroundColor Yellow
            # hide its error plates too: this account may have "infinite retries" set,
            # and without this a failed attempt pops a blocking "Connect Error" window
            [void](Invoke-VpnCmd @('AccountStatusHide', $cur))
            [void](Invoke-VpnCmd @('AccountDisconnect', $cur))
            $script:directIpCache = $null   # routes changed, the reference IP must be re-measured
            Start-Sleep -Seconds 1
        }
    }
    if (-not $script:directIpCache) { $script:directIpCache = Get-PublicIp }

    # (re)create the test account FROM THE APP'S TEMPLATE, then connect - all in ONE
    # vpncmd process. /NUM:0 disables hidden retries; the leading Disconnect/Delete kill
    # any attempt still running from the previous candidate
    [void](Invoke-VpnCmd -StdIn @("AccountDisconnect $TestAccount", "AccountDelete $TestAccount") -TimeoutSec 10)
    if ($script:useTemplate) {
        if (-not (Write-ImportFile $c.IP $c.Port)) { $script:useTemplate = $false }
    }
    if ($script:useTemplate) {
        $batch = @(
            "AccountImport $env:TEMP\vg_import.vpn",
            "AccountStatusHide $TestAccount",
            "AccountRetrySet $TestAccount /NUM:0 /INTERVAL:5",
            "AccountConnect $TestAccount"
        )
    } else {
        # no template available - fall back to a from-scratch anonymous account
        $batch = @(
            "AccountCreate $TestAccount /SERVER:$($c.IP):$($c.Port) /HUB:$Hub /USERNAME:$User /NICNAME:$NicName",
            "AccountStatusHide $TestAccount",
            "AccountAnonymousSet $TestAccount",
            "AccountUsernameSet $TestAccount /USERNAME:vpn",
            "AccountRetrySet $TestAccount /NUM:0 /INTERVAL:5",
            "AccountConnect $TestAccount"
        )
    }
    $out = Invoke-VpnCmd -StdIn $batch -TimeoutSec 10
    $idx = $out.LastIndexOf('AccountConnect command')
    $tail = if ($idx -ge 0) { $out.Substring($idx) } else { $out }
    if ($tail -match 'Error occurred') {
        Write-Host ("  the connection attempt was rejected immediately ({0:n1} s)." -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkYellow
        return $null
    }

    # poll the account status: Connecting -> Connected (win) / Offline (dead)
    $ok = $false
    $everConnecting = $false
    $deadline = (Get-Date).AddSeconds($ConnectWaitSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $st = Get-AccountStatus $TestAccount
        if ($st -match 'Connected') { $ok = $true; break }
        if ($st -match 'Connecting') { $everConnecting = $true; continue }
        if ($st -match 'Offline' -and ($everConnecting -or ((Get-Date) -gt $deadline.AddSeconds(-4)))) { break }
    }

    if ($ok) {
        Start-Sleep -Seconds 1   # let the routing settle
        $newIp = Get-PublicIp
        if ($newIp -and -not ($script:directIpCache -and $newIp -eq $script:directIpCache)) {
            Write-Host ("  CONNECTED: session established, traffic goes through the tunnel. Public IP: {0}" -f $newIp) -ForegroundColor Green
            return @{ NewIp = $newIp }
        }
        Write-Host ("  session is established but there is no Internet (IP: {0}) - not suitable." -f $(if ($newIp) { $newIp } else { 'no answer' })) -ForegroundColor DarkYellow
    } else {
        Write-Host ("  failed to establish the session ({0:n1} s)." -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkYellow
    }
    return $null
}

function Finish-Success {
    param($c, [string]$newIp)
    if ($DisconnectAfter) {
        [void](Invoke-VpnCmd @('AccountDisconnect', $TestAccount))
        Start-Sleep -Seconds 2
        [void](Invoke-VpnCmd @('AccountDelete', $TestAccount))
        Write-Host 'The test connection is disconnected, the test account is deleted.' -ForegroundColor Gray
    } else {
        # if this success came from the from-scratch fallback, save it as the new template
        if (-not $script:templateCaptured) {
            [void](Invoke-VpnCmd @('AccountExport', $TestAccount, "/SAVEPATH:$TemplateFile"))
            $script:templateCaptured = $true
        }
        $newName = ('VG {0} {1}' -f $c.Country, $c.IP)
        [void](Invoke-VpnCmd @('AccountRename', $TestAccount, "/NEW:$newName"))
        Write-Host ("Done. Working server: {0}:{1} ({2}), your IP now: {3}. Account in the client: '{4}'." -f $c.IP, $c.Port, $c.CountryFull, $newIp, $newName) -ForegroundColor Green
    }
}

function Test-AccountExists([string]$name) {
    $lt = Invoke-VpnCmd @('AccountList') -TimeoutSec 6
    return ($lt -match ('VPN Connection Setting Name\s*\|\s*' + [regex]::Escape($name) + '\s*\r?$'))
}

function Exit-Script([int]$code) {
    try {
        $cur = Get-ConnectedAccount
        if (-not $cur) {
            # our attempts dropped the user's previous session - bring it back.
            # NOTE: the VPN Gate plugin DELETES its account on disconnect, so plain
            # AccountConnect may have nothing to connect - restore via the template then.
            if ($script:lastSeenConnected -and (Test-AccountExists $script:lastSeenConnected)) {
                Write-Host "Restoring the previous connection '$script:lastSeenConnected'..." -ForegroundColor Yellow
                [void](Invoke-VpnCmd @('AccountConnect', $script:lastSeenConnected))
            } elseif (Test-Path $TemplateFile) {
                Write-Host 'Restoring your connection from the captured account template...' -ForegroundColor Yellow
                [void](Invoke-VpnCmd -StdIn @("AccountDisconnect $TestAccount", "AccountDelete $TestAccount") -TimeoutSec 10)
                [void](Invoke-VpnCmd @('AccountImport', $TemplateFile))
                Start-Sleep -Seconds 1
                [void](Invoke-VpnCmd @('AccountConnect', 'VPN Gate Connection'))
            }
        }
    } catch { }
    # remove the test account if it is still around (after success it has a different name)
    [void](Invoke-VpnCmd @('AccountDelete', $TestAccount))
    exit $code
}

# sweep ALL candidates one by one (-Connect behavior); returns $true on success
function Invoke-AutoConnect {
    param([switch]$Quiet)
    # THE DOOR CHECK: the server of the user's current session is known-reachable when
    # the path is open. If even its TCP connect times out, the network is dropping NEW
    # VPN handshakes right now - warn instead of sweeping in vain.
    $tplText = Get-TemplateText
    if ($tplText) {
        $h = [regex]::Match($tplText, 'string\s+Hostname\s+([^\r\n]+)').Groups[1].Value.Trim()
        $pp = [regex]::Match($tplText, 'uint\s+Port\s+(\d+)').Groups[1].Value.Trim()
        if ($h -and $pp -and $pp -match '^\d+$') {
            $t = New-Object Net.Sockets.TcpClient
            $swp = [System.Diagnostics.Stopwatch]::StartNew()
            $doorOpen = $false
            try {
                $ar = $t.BeginConnect($h, [int]$pp, $null, $null)
                if ($ar.AsyncWaitHandle.WaitOne(3000) -and $t.Connected) { $t.EndConnect($ar); $doorOpen = $true }
            } catch { $doorOpen = $false } finally { $t.Close() }
            if (-not $doorOpen) {
                Write-Host ("WARNING: TCP to {0}:{1} (the server of your current session) does not connect right now." -f $h, $pp) -ForegroundColor Yellow
                Write-Host 'The network is dropping NEW VPN handshakes. Your existing session keeps working, but every new attempt will fail until this window opens again.' -ForegroundColor Yellow
                if ($Quiet) { return $false }   # watchdog: no prompts, just skip the sweep
                $ans = Read-Host 'Try the sweep anyway? (y/N)'
                if ($ans -notmatch '^(y|yes|д|Д)$') { return $false }
            }
        }
    }

    if ($Index -gt 0) {
        if ($Index -gt $live.Count) { Write-Host "Row #$Index does not exist (total $($live.Count))" -ForegroundColor Red; return $false }
        $pool = [object[]]$live[$Index - 1]
    } else {
        # order servers by country priority (TH first by default), then by ping
        $prio = @{ }
        for ($i = 0; $i -lt $CountryPriority.Count; $i++) { $prio[$CountryPriority[$i].ToUpper()] = $i }
        $aliveOnly = [object[]]($live | Where-Object { $_.Alive })
        $pool = [object[]]($aliveOnly | Sort-Object `
                @{ Expression = { if ($prio.ContainsKey($_.Country)) { $prio[$_.Country] } else { 999 } } }, `
                @{ Expression = 'Ping' })
    }
    # prepare the dial template (the app's account with its hidden fields), captured
    # while the user's session still exists; then free the adapter ONCE for the sweep
    $null = Get-TemplateText
    $script:useTemplate = (Test-Path $TemplateFile)
    if (-not $Index) {
        $cur = Get-ConnectedAccount
        if ($cur) {
            Write-Host "The virtual adapter 'VPN' is busy by account '$cur' - disconnecting it for the sweep..." -ForegroundColor Yellow
            [void](Invoke-VpnCmd @('AccountStatusHide', $cur))
            [void](Invoke-VpnCmd @('AccountDisconnect', $cur))
            $script:directIpCache = $null
            Start-Sleep -Seconds 1
        }
    }

    if ($ConnectTries -gt 0) { $pool = [object[]]($pool | Select-Object -First $ConnectTries) }
    $todo = [object[]]($pool | Where-Object { -not $script:triedKeys.ContainsKey(('{0}:{1}' -f $_.IP, $_.Port)) })
    if (-not $todo -or $todo.Count -eq 0) {
        Write-Host 'Every candidate from the current scan has been tried already - press 91 to rescan for a fresh list.' -ForegroundColor Yellow
        return $false
    }
    # the server from the captured template is PROVEN working (the app used it) -
    # TCP probes are unreliable during blocking waves, so always try it first
    $tplText = Get-TemplateText
    if ($tplText) {
        $h = [regex]::Match($tplText, 'string\s+Hostname\s+([^\r\n]+)').Groups[1].Value.Trim()
        $pp = [regex]::Match($tplText, 'uint\s+Port\s+(\d+)').Groups[1].Value.Trim()
        if ($h -and $pp -match '^\d+$') {
            $key = '{0}:{1}' -f $h, $pp
            if (-not $script:triedKeys.ContainsKey($key)) {
                $known = $live | Where-Object { $_.IP -eq $h }
                $first = [pscustomobject]@{
                    IP         = $h
                    Port       = [int]$pp
                    Ping       = $(if ($known) { $known[0].Ping } else { 0 })
                    Alive      = $true
                    Country    = $(if ($known) { $known[0].Country } else { '??' })
                    CountryFull= $(if ($known) { $known[0].CountryFull } else { 'your previous server' })
                    SpeedMbps  = $(if ($known) { $known[0].SpeedMbps } else { 0 })
                    Score      = $(if ($known) { $known[0].Score } else { 0 })
                    Sessions   = $(if ($known) { $known[0].Sessions } else { 0 })
                    Uptime     = $(if ($known) { $known[0].Uptime } else { '-' })
                    Host       = $(if ($known) { $known[0].Host } else { '' })
                }
                $todo = @($first) + @($todo | Where-Object { $_.IP -ne $h })
            }
        }
    }

    $total = $todo.Count
    $n = 0
    foreach ($c in $todo) {
        $n++
        [void]($script:triedKeys[('{0}:{1}' -f $c.IP, $c.Port)] = $true)
        Write-Host ("[{0}/{1}] Try: {2}:{3}  [{4}]  ping {5} ms, {6} sessions ..." -f $n, $total, $c.IP, $c.Port, $c.CountryFull, $c.Ping, $c.Sessions) -ForegroundColor White
        $res = Test-Candidate $c -SkipDisconnectCheck
        if ($res) { Finish-Success $c $res.NewIp; return $true }
    }
    # sweep finished: clean up the last attempt (its batch is never run again)
    [void](Invoke-VpnCmd -StdIn @("AccountDisconnect $TestAccount", "AccountDelete $TestAccount") -TimeoutSec 10)
    Write-Host ("Swept all {0} candidates - none accepted the connection." -f $total) -ForegroundColor Red
    Write-Host 'VPN Gate servers often refuse clients (country restrictions / server is full). Press 91 to rescan for a fresh list, or pick rows manually.' -ForegroundColor Yellow
    return $false
}

function Show-MenuHint {
    Write-Host ''
    Write-Host ("Type a VPN number (1..{0}) to connect to it, or a letter:" -f $live.Count) -ForegroundColor Cyan
    Write-Host ('  A = sweep ALL live servers automatically (~5-6 s per attempt)') -ForegroundColor Cyan
    Write-Host ('  B = rescan: fresh server list and new probes') -ForegroundColor Cyan
    Write-Host ('  D = test the current session (is traffic really going through it?)') -ForegroundColor Cyan
    Write-Host ('  C = exit (or just press Enter)') -ForegroundColor Cyan
}

# ---------------------------------------------------------------- locate vpncmd

if (-not $VpncmdPath) {
    foreach ($p in @(
        "$env:ProgramFiles\SoftEther VPN Client\vpncmd.exe",
        "${env:ProgramFiles(x86)}\SoftEther VPN Client\vpncmd.exe"
    )) {
        if (Test-Path $p) { $VpncmdPath = $p; break }
    }
}
if (-not $VpncmdPath -or -not (Test-Path $VpncmdPath)) {
    Write-Host 'vpncmd.exe not found. Specify the path via -VpncmdPath.' -ForegroundColor Red
    exit 1
}

# client service alive?
$ping = Invoke-VpnCmd @('AccountList')
if ($ping -notmatch 'The command completed successfully') {
    Write-Host 'The SoftEther VPN Client service is not responding (is vpnclient running?).' -ForegroundColor Red
    exit 1
}

# NIC present? (needed for any attempt; checked once)
$nicTxt = Invoke-VpnCmd @('NicList')
if ($nicTxt -notmatch ('Virtual Network Adapter Name\s*\|\s*' + $NicName)) {
    Write-Host "Virtual adapter '$NicName' not found - creating..." -ForegroundColor Yellow
    [void](Invoke-VpnCmd @('NicCreate', $NicName))
}

# clear stuck reconnect loops left by previous failed attempts (they keep the
# client busy, block vpncmd and pop up endless "Connect Error" plates)
$stuckNames = @()
foreach ($line in ((Invoke-VpnCmd @('AccountList') -TimeoutSec 15) -split "`r?`n")) {
    if ($line -match 'VPN Connection Setting Name\s*\|\s*(.+?)\s*$') { $stuckNames += $Matches[1].Trim() }
}
foreach ($name in $stuckNames) {
    $st = Invoke-VpnCmd @('AccountStatusGet', $name) -TimeoutSec 15
    if ($st -match '(?i)connecting|waiting for|retry') {
        Write-Host ("Account '{0}' is stuck in a reconnect loop - stopping it and hiding its error plates..." -f $name) -ForegroundColor Yellow
        [void](Invoke-VpnCmd @('AccountStatusHide', $name))
        [void](Invoke-VpnCmd @('AccountDisconnect', $name))
    }
}
# legacy test account from older script versions (name with a space)
[void](Invoke-VpnCmd @('AccountDelete', 'VG AutoTest'))

Add-Type -AssemblyName Microsoft.VisualBasic | Out-Null

# =====================================================================
# main loop: the whole scan can be repeated from the menu (command 91)
# =====================================================================
while ($true) {

    $script:triedKeys = @{ }   # a fresh (re)scan resets the "already tried" memory

    # ---------------------------------------------------------------- 1. server list

    $servers = $null
    $source  = ''

    if ($CsvPath) {
        if (-not (Test-Path $CsvPath)) { Write-Host "File not found: $CsvPath" -ForegroundColor Red; exit 1 }
        $servers = Read-VpnGateCsv $CsvPath
        $source  = "file $CsvPath"
    }
    else {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

        foreach ($u in $Urls) {
            try {
                Write-Host "Downloading server list: $u ..."
                $csv = (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 20).Content
                if ($csv -and $csv.Length -gt 1000) {
                    [IO.File]::WriteAllText($CacheFile, $csv, (New-Object Text.UTF8Encoding($false)))
                    $servers = Read-VpnGateCsv $CacheFile
                    $source = $u
                    break
                }
            } catch {
                Write-Host "  download failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }
        if (-not $servers -and -not $NoCache -and (Test-Path $CacheFile)) {
            Write-Host "Using the cached list: $CacheFile" -ForegroundColor Yellow
            $servers = Read-VpnGateCsv $CacheFile
            $source  = 'cache, from {0}' -f (Get-Item $CacheFile).LastWriteTime
        }
    }
    if (-not $servers) {
        Write-Host 'Failed to get the server list (the script already tries the official CDN download.vpngate.jp as well).' -ForegroundColor Red
        Write-Host 'As a last resort: open http://www.vpngate.net/api/iphone/ in a browser (through VPN), save the file and run the script with -CsvPath.' -ForegroundColor Yellow
        exit 1
    }
    if (-not $servers -or $servers.Count -eq 0) {
        Write-Host 'The server list is empty (CSV format may have changed).' -ForegroundColor Red
        exit 1
    }
    Write-Host ("Servers in the list: {0}  (source: {1})" -f $servers.Count, $source) -ForegroundColor Gray

    # if a session is already active, the probes go through the tunnel and the latency is exaggerated
    $scanThroughTunnel = Get-ConnectedAccount
    if ($scanThroughTunnel) {
        Write-Host ("Note: the connection '{0}' is active now - latencies will be measured through it. For accurate ping, run the scan while disconnected." -f $scanThroughTunnel) -ForegroundColor DarkYellow
    }

    # candidate ports: ports from the embedded OpenVPN config + standard SoftEther ports
    foreach ($s in $servers) {
        $ports = New-Object System.Collections.Generic.List[int]
        if ($s.OpenVPN_ConfigData_Base64) {
            try {
                $o = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s.OpenVPN_ConfigData_Base64))
                foreach ($m in [regex]::Matches($o, 'remote\s+\d{1,3}(?:\.\d{1,3}){3}\s+(\d+)')) {
                    $pt = [int]$m.Groups[1].Value
                    if ($pt -gt 0 -and $pt -le 65535 -and -not $ports.Contains($pt)) { [void]$ports.Add($pt) }
                }
            } catch { }
        }
        foreach ($pt in $DefaultPorts) { if (-not $ports.Contains($pt)) { [void]$ports.Add($pt) } }
        Add-Member -InputObject $s -NotePropertyName Ports -NotePropertyValue $ports -Force
    }

    # exclude countries whose servers are mostly blocked by European sites (RU/BY/UA by default)
    $excludeList = [object[]]($Exclude | Where-Object { $_ -and $_.Trim().ToLower() -ne 'none' })
    if ($excludeList) {
        $pat = ($excludeList | ForEach-Object { [regex]::Escape($_.Trim().ToUpper()) }) -join '|'
        $before = $servers.Count
        $servers = [object[]]($servers | Where-Object { $_.CountryShort -notmatch "^($pat)$" -and $_.CountryLong -notmatch "^($pat)" })
        Write-Host ("Excluded ({0}): {1} servers skipped" -f ($excludeList -join ','), ($before - $servers.Count)) -ForegroundColor Gray
    }

    if ($Country) {
        $pat = ($Country | ForEach-Object { [regex]::Escape($_.Trim().ToUpper()) }) -join '|'
        $servers = [object[]]($servers | Where-Object { $_.CountryShort -match "^($pat)$" -or $_.CountryLong -match "^($pat)" })
        Write-Host ("Country filter ({0}): {1} servers left" -f ($Country -join ','), $servers.Count) -ForegroundColor Gray
        if (-not $servers -or $servers.Count -eq 0) {
            Write-Host 'No servers match the country filter.' -ForegroundColor Yellow
            exit 2
        }
    }
    if ($Top -gt 0) {
        $servers = [object[]]($servers | Sort-Object { To-Num $_.Score } -Descending | Select-Object -First $Top)
        Write-Host ("Top-{0} by score selected" -f $Top) -ForegroundColor Gray
    }
    if (-not $servers -or $servers.Count -eq 0) {
        Write-Host 'No servers left after the country filters.' -ForegroundColor Yellow
        exit 2
    }

    # ---------------------------------------------------------------- 2. parallel TCP probe

    $alive = Invoke-Probe -ServerList $servers -TimeoutMs $ProbeTimeoutMs

    # if nothing answers and a session is active, the probes went through a (half-dead) tunnel:
    # disconnect it and retry directly - this is the normal "VPN just died" scenario
    if ($alive.Count -eq 0 -and $scanThroughTunnel -and -not $KeepTunnel) {
        Write-Host ("Not a single server answered - the probes went through the session '{0}' and it is barely alive." -f $scanThroughTunnel) -ForegroundColor Yellow
        Write-Host 'Disconnecting it and retrying the probes directly...' -ForegroundColor Yellow
        [void](Invoke-VpnCmd @('AccountDisconnect', $scanThroughTunnel))
        Start-Sleep -Seconds 3
        $alive = Invoke-Probe -ServerList $servers -TimeoutMs ([Math]::Max($ProbeTimeoutMs, 5000))
    }

    # best port per server
    $best = @{ }
    foreach ($a in $alive) {
        if (-not $best.ContainsKey($a.IP) -or $a.MS -lt $best[$a.IP].MS) { $best[$a.IP] = $a }
    }

    $live = @()
    foreach ($s in $servers) {
        $b = $null
        if ($best.ContainsKey($s.IP)) { $b = $best[$s.IP] }
        # every server gets a row; TCP-dead ones are shown marked and skipped by the sweep
        $live += [pscustomobject]@{
            IP         = $s.IP
            Port       = $(if ($b) { $b.Port } else { $s.Ports[0] })
            Ping       = $(if ($b) { $b.MS } else { 0 })
            Alive      = [bool]$b
            Country    = $s.CountryShort
            CountryFull= $s.CountryLong
            SpeedMbps  = [math]::Round((To-Num $s.Speed) / 1000000, 1)
            Score      = [int64](To-Num $s.Score)
            Sessions   = [int](To-Num $s.NumVpnSessions)
            Uptime     = Format-Uptime ([int64](To-Num $s.Uptime))
            Host       = $s.HostName
        }
    }
    $aliveRows = [object[]]($live | Where-Object { $_.Alive } | Sort-Object Ping, @{ Expression = 'Score'; Descending = $true })
    $deadRows  = [object[]]($live | Where-Object { -not $_.Alive } | Sort-Object { To-Num $_.Score } -Descending)
    $live = [object[]]($aliveRows + $deadRows)

    # ---------------------------------------------------------------- 3. report

    $aliveCount = @($live | Where-Object { $_.Alive }).Count

    Write-Host ''
    Write-Host ("SERVERS SHOWN: {0}  ({1} live + {2} dead - dead rows are marked DEAD and skipped by the sweep)" -f $live.Count, $aliveCount, ($live.Count - $aliveCount)) -ForegroundColor Green

    $table = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($a in $live) {
        $i++
        $table.Add([pscustomobject]@{
            '#'        = $i
            'IP:port'  = ('{0}:{1}' -f $a.IP, $a.Port)
            'Ping,ms'  = $(if ($a.Alive) { $a.Ping } else { 'DEAD' })
            'Country'  = $a.Country
            'Speed'    = ('{0:n1} Mb' -f $a.SpeedMbps)
            'Score'    = $a.Score
            'Sessions' = $a.Sessions
            'Uptime'   = $a.Uptime
        })
    }
    $table | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Write-Host $_ }

    try {
        $live | Export-Csv -Path $ResultFile -NoTypeInformation -Encoding UTF8
        Write-Host "Full list saved to: $ResultFile" -ForegroundColor Gray
    } catch {
        Write-Host ("Could not save CSV ({0}) - the file may be open in Excel." -f $_.Exception.Message) -ForegroundColor DarkYellow
    }

    if ($aliveCount -eq 0) {
        Write-Host 'No live servers found (all TCP probes failed).' -ForegroundColor Red
        Write-Host 'Try again later, without -Country/-Top, or increase the timeout: vg.bat -ProbeTimeoutMs 5000' -ForegroundColor Yellow
        exit 2
    }

    # ---------------------------------------------------------------- 4. menu / connect

    # watchdog: connect automatically, then keep the session alive indefinitely
    if ($Watchdog) {
        if (Invoke-AutoConnect -Quiet) {
            Write-Host ("[{0}] Connected. Watching the session (Ctrl+C to stop)..." -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Green
            while ($true) {
                Start-Sleep -Seconds 30
                if (Get-ConnectedAccount) { continue }
                break
            }
            Write-Host ("[{0}] Session dropped - rescanning and reconnecting..." -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Yellow
            continue   # fresh scan + sweep
        }
        Write-Host ("[{0}] No server accepted the connection - new attempt in 60 s (Ctrl+C to stop)..." -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Yellow
        Start-Sleep -Seconds 60
        continue   # fresh scan + sweep
    }

    # -Connect: auto-connect first; whatever the result, the numeric menu follows
    if ($Connect) {
        if (Invoke-AutoConnect) { Exit-Script 0 }
    }

    # interactive menu (also reached after a failed -Connect run)
    while ($true) {
        Show-MenuHint
        $pick = Read-Host 'Your choice (VPN number, or A / B / C / D)'
        if ([string]::IsNullOrWhiteSpace($pick)) { Exit-Script 0 }
        $t = $pick.Trim().ToUpper()

        if ($t -eq 'C' -or $t -eq '0' -or $t -match '^(EXIT|QUIT|Q)$') { Exit-Script 0 }

        if ($t -eq 'B' -or $t -eq '91' -or $t -match '^(RESCAN|REFRESH)$') {
            Write-Host 'Rescanning...' -ForegroundColor Cyan
            break   # back to the top of the main loop
        }

        if ($t -eq 'A' -or $t -eq '90' -or $t -match '^(-?CONNECT)$') {
            if (Invoke-AutoConnect) { Exit-Script 0 }
            continue
        }

        if ($t -eq 'D' -or $t -match '^(TEST|CHECK)$') {
            $cur = Get-ConnectedAccount
            if (-not $cur) {
                Write-Host 'No active session right now - press A to sweep or B to rescan.' -ForegroundColor Yellow
                continue
            }
            $sg = Invoke-VpnCmd @('AccountStatusGet', $cur) -TimeoutSec 10
            $est = ($sg -match 'Session Established')
            $ip = Get-PublicIp
            $color = if ($est -and $ip) { 'Green' } else { 'Yellow' }
            Write-Host ("Session '{0}': {1}; public IP now: {2}" -f $cur, $(if ($est) { 'established' } else { 'NOT established' }), $(if ($ip) { $ip } else { 'no answer' })) -ForegroundColor $color
            if ($est -and -not $ip) { Write-Host '  the tunnel is up but the Internet is unreachable - pick another server (A or a number).' -ForegroundColor Yellow }
            continue
        }

        $n = 0
        if (-not [int]::TryParse($t, [ref]$n) -or $n -lt 1 -or $n -gt $live.Count) {
            Write-Host ("No such choice: '{0}' (1..{1}, or A / B / C)" -f $t, $live.Count) -ForegroundColor Yellow
            continue
        }

        $c = $live[$n - 1]
        if (-not $c.Alive) {
            Write-Host '  note: this server did not answer TCP probes - the attempt will most likely fail.' -ForegroundColor DarkYellow
        }
        Write-Host ("Try: {0}:{1}  [{2}]  ping {3} ms, {4} sessions ..." -f $c.IP, $c.Port, $c.CountryFull, $c.Ping, $c.Sessions) -ForegroundColor White
        $res = Test-Candidate $c
        if ($res) { Finish-Success $c $res.NewIp; Exit-Script 0 }
        Write-Host 'Failed. Pick another number, A/B, or press Enter to exit.' -ForegroundColor Yellow
    }

    # rescan requested -> go back to the top of the main loop
}
