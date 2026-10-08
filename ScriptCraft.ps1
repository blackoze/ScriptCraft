param(
    [string]$McVersion = '',
    [switch]$DryRun,
    [switch]$NoLaunch,
    [switch]$NoFabric,
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $Host.UI.RawUI.WindowTitle = 'ScriptCraft  v15  -  BLACKOZE' } catch {}

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }

$configPath    = Join-Path $scriptRoot 'config.json'
$logDir        = Join-Path $scriptRoot 'logs'
$cacheDir      = Join-Path $scriptRoot 'cache'
$reportDir     = Join-Path $scriptRoot 'reports'
$hashCachePath = Join-Path $cacheDir 'hash-cache.json'

foreach ($d in @($logDir, $cacheDir, $reportDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

function Get-Glyph { param([int]$Code) try { return [char]::ConvertFromUtf32($Code) } catch { return '' } }

$Glyph = @{
    Shield  = (Get-Glyph 0x1F6E1)
    Game    = (Get-Glyph 0x1F3AE)
    Thread  = (Get-Glyph 0x1F9F5)
    Package = (Get-Glyph 0x1F4E6)
    Palette = (Get-Glyph 0x1F3A8)
    Brush   = (Get-Glyph 0x1F58C)
    Chart   = (Get-Glyph 0x1F4CA)
    Broom   = (Get-Glyph 0x1F9F9)
    Move    = (Get-Glyph 0x21AA)   # ↪ move arrow
    Warn    = (Get-Glyph 0x26A0)
    Tick    = [string][char]0x2713
    Cross   = [string][char]0x2717
    Dot     = [string][char]0x00B7
    Tri     = [string][char]0x25B2
    Arrow   = [string][char]0x2192
    HRule   = [string][char]0x2500
    Ellipsis= [string][char]0x2026
}

$C = @{
    Rule='DarkGray'; Title='White'; Subtitle='DarkGray'; Section='White'
    Body='Gray'; Muted='DarkGray'; Emphasis='White'
    Success='Green'; Warning='Yellow'; Error='Red'; Info='Gray'
}

$RuleWidth = 68

$StatusTable = @{
    'ok'       = @{ Tag = 'UPDATED';  Color = $C.Success }
    'same'     = @{ Tag = 'CURRENT';  Color = $C.Muted   }
    'dep'      = @{ Tag = 'DEP';      Color = $C.Info    }
    'warn'     = @{ Tag = 'SKIPPED';  Color = $C.Warning }
    'unknown'  = @{ Tag = 'UNKNOWN';  Color = $C.Muted   }
    'err'      = @{ Tag = 'ERROR';    Color = $C.Error   }
    'plan'     = @{ Tag = 'PENDING';  Color = $C.Warning }
    'info'     = @{ Tag = 'INFO';     Color = $C.Info    }
    'note'     = @{ Tag = 'NOTE';     Color = $C.Muted   }
    'disabled' = @{ Tag = 'KEPT';     Color = $C.Warning }
    'fixed'    = @{ Tag = 'FIXED';    Color = $C.Success }
    'restored' = @{ Tag = 'RESTORED'; Color = $C.Success }
    'cleanup'  = @{ Tag = 'CLEANED';  Color = $C.Success }
}

$DefaultConfig = @{
    Loader                  = 'fabric'
    Backup                  = $true
    KeepBackups             = 5
    Launch                  = $false
    PreferredMcVersion      = ''
    HashCache               = $true
    LogKeep                 = 30
    ReportKeep              = 20
    AutoDisableIncompatible = $true
    OptionsGuard            = $true
    FabricCleanup           = $true
    FabricCleanupMode       = 'global'
    FabricCleanupDelete     = $false
    FabricCleanupProfiles   = $true
}

$Config = @{}
foreach ($k in $DefaultConfig.Keys) { $Config[$k] = $DefaultConfig[$k] }

if (Test-Path -LiteralPath $configPath) {
    try {
        $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) {
            if ($DefaultConfig.ContainsKey($p.Name)) { $Config[$p.Name] = $p.Value }
        }
    } catch {}
} else {
    [ordered]@{
        _readme                = 'FabricCleanupDelete=true removes files permanently. FabricCleanupProfiles=true also removes launcher entries.'
        Loader                 = $Config.Loader
        Backup                 = $Config.Backup
        KeepBackups            = $Config.KeepBackups
        Launch                 = $Config.Launch
        PreferredMcVersion     = $Config.PreferredMcVersion
        HashCache              = $Config.HashCache
        LogKeep                = $Config.LogKeep
        ReportKeep             = $Config.ReportKeep
        AutoDisableIncompatible= $Config.AutoDisableIncompatible
        OptionsGuard           = $Config.OptionsGuard
        FabricCleanup          = $Config.FabricCleanup
        FabricCleanupMode      = $Config.FabricCleanupMode
        FabricCleanupDelete    = $Config.FabricCleanupDelete
        FabricCleanupProfiles  = $Config.FabricCleanupProfiles
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $configPath -Encoding UTF8
}

if ($DryRun)    { $Config.DryRun = $true }
if ($NoLaunch)  { $Config.Launch = $false }
if ($McVersion) { $Config.PreferredMcVersion = $McVersion }

$startTime = Get-Date
$Headers   = @{ 'User-Agent' = 'BLACKOZE/ScriptCraft/15 (personal)' }
$Api       = 'https://api.modrinth.com/v2'
$mcVersion = $null
$fabricLoaderVersion = $null
$BackupUsed = $false
$duplicateWarnings = New-Object System.Collections.Generic.List[string]

$dotMinecraft = Join-Path $env:APPDATA '.minecraft'
$BackupRoot   = Join-Path $dotMinecraft 'sync-backup'
$BackupDir    = Join-Path $BackupRoot (Get-Date -Format 'yyyy-MM-dd_HH-mm')
$modsDisabled = Join-Path $dotMinecraft 'mods-disabled'
$optionsFile  = Join-Path $dotMinecraft 'options.txt'
$versionsDir  = Join-Path $dotMinecraft 'versions'
$profilesFile = Join-Path $dotMinecraft 'launcher_profiles.json'

$Stats = [ordered]@{
    Updated=0; Current=0; Deps=0; Skipped=0; Unknown=0; Errors=0
    Disabled=0; Restored=0; OptionsFixed=0; FabricCleaned=0; ProfilesCleaned=0
}
$ErrorLog = New-Object System.Collections.Generic.List[string]
$incompatibleMods = New-Object System.Collections.Generic.List[System.IO.FileInfo]

# ============================================================
#  HASH CACHE
# ============================================================
$hashCache = @{}
if ($Config.HashCache -and (Test-Path -LiteralPath $hashCachePath)) {
    try {
        $raw = Get-Content -LiteralPath $hashCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $hashCache[$p.Name] = [string]$p.Value }
    } catch {}
}
$hashHits = 0; $hashMiss = 0

function Get-CachedHash {
    param([System.IO.FileInfo]$File)
    $key = '{0}|{1}|{2}' -f $File.FullName, $File.Length, $File.LastWriteTimeUtc.Ticks
    if ($hashCache.ContainsKey($key)) { $script:hashHits++; return $hashCache[$key] }
    $h = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA1 -ErrorAction Stop).Hash.ToLower()
    $hashCache[$key] = $h
    $script:hashMiss++
    return $h
}
function Save-HashCache {
    if (-not $Config.HashCache) { return }
    try { $hashCache | ConvertTo-Json -Compress | Set-Content -LiteralPath $hashCachePath -Encoding UTF8 } catch {}
}

# ============================================================
#  UI
# ============================================================
function Write-Rule { param([string]$Color = $C.Rule); Write-Host ('   ' + ($Glyph.HRule * $RuleWidth)) -ForegroundColor $Color }

function Write-Banner {
    $stamp = Get-Date -Format 'yyyy-MM-dd'
    $right = $stamp + '  ' + $Glyph.Dot + '  v15'
    $left  = 'Fabric-first mod manager'
    Write-Host ''
    Write-Host '   SCRIPTCRAFT' -ForegroundColor $C.Title
    $pad = $RuleWidth - $left.Length - $right.Length
    if ($pad -lt 1) { $pad = 1 }
    Write-Host ('   ' + $left + (' ' * $pad) + $right) -ForegroundColor $C.Subtitle
    Write-Rule
}

function Write-Section {
    param([string]$Icon, [string]$Title, [string]$Meta = '')
    Write-Host ''
    Write-Host ('   ' + $Icon + '  ') -NoNewline -ForegroundColor $C.Muted
    Write-Host $Title -NoNewline -ForegroundColor $C.Section
    if ($Meta) { Write-Host ('  ' + $Glyph.Dot + '  ' + $Meta) -ForegroundColor $C.Muted }
    else { Write-Host '' }
    Write-Rule
    Write-Host ''
}

function Write-Item {
    param([string]$Status, [string]$Name, [string]$Detail = '', $Index = $null, [switch]$Sub)
    $meta = if ($StatusTable.ContainsKey($Status)) { $StatusTable[$Status] } else { $StatusTable['info'] }
    $tag = '[' + $meta.Tag.PadRight(8) + ']'
    $nameWidth = 26
    if ($Name.Length -gt $nameWidth) { $Name = $Name.Substring(0, $nameWidth - 1) + $Glyph.Ellipsis }

    if ($null -ne $Index) {
        $num = ('{0:D2}' -f $Index)
        Write-Host ('       ' + $num + '  ') -NoNewline -ForegroundColor $C.Muted
    } else {
        $indent = if ($Sub) { '           ' } else { '       ' }
        Write-Host $indent -NoNewline
    }

    Write-Host $tag -NoNewline -ForegroundColor $meta.Color
    Write-Host '  ' -NoNewline
    Write-Host $Name.PadRight($nameWidth) -NoNewline -ForegroundColor $C.Body
    if ($Detail) {
        Write-Host '  ' -NoNewline
        Write-Host $Detail -ForegroundColor $meta.Color
    } else { Write-Host '' }
}

function Write-BigWarning {
    param([string]$Title, [string[]]$Lines)
    Write-Host ''
    Write-Host ('   ' + $Glyph.Warn + '  ') -NoNewline -ForegroundColor $C.Error
    Write-Host $Title -ForegroundColor $C.Error
    Write-Rule -Color $C.Error
    Write-Host ''
    foreach ($l in $Lines) { Write-Host ('       ' + $l) -ForegroundColor $C.Error }
    Write-Host ''
}

function Get-ConsoleWidth { $w = 78; try { $w = [math]::Max(40, $Host.UI.RawUI.WindowSize.Width - 4) } catch {}; return $w }
function Write-Activity {
    param([string]$Text, [string]$Color = $C.Info)
    $w = Get-ConsoleWidth
    if ($Text.Length -gt $w) { $Text = $Text.Substring(0, $w) }
    Write-Host ("`r   " + $Text.PadRight($w)) -NoNewline -ForegroundColor $Color
}
function Clear-Activity {
    $w = Get-ConsoleWidth
    Write-Host ("`r" + (' ' * ($w + 2)) + "`r") -NoNewline
}
function Write-ProgressBar {
    param([int]$Current, [int]$Total, [string]$Label)
    $pct = 100
    if ($Total -gt 0) { $pct = [int][math]::Round(($Current / $Total) * 100) }
    $filled = [int][math]::Floor($pct / 5)
    $full = [string][char]0x2588
    $empty = [string][char]0x2591
    $bar = ($full * $filled) + ($empty * (20 - $filled))
    $color = $C.Muted
    if ($pct -ge 100) { $color = $C.Success } elseif ($pct -ge 50) { $color = $C.Info }
    Write-Activity -Text ('{0}  {1,3}%  ({2}/{3})  {4}' -f $bar, $pct, $Current, $Total, $Label) -Color $color
}
function Add-Err { param([string]$Message); $Stats.Errors++; [void]$ErrorLog.Add($Message) }
function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}
function ConvertTo-Date {
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    try {
        $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
        return [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, $styles)
    } catch { return [datetime]::MinValue }
}
function Invoke-Batched {
    param([object[]]$Items, [int]$Size, [scriptblock]$Action)
    for ($i = 0; $i -lt $Items.Count; $i += $Size) {
        $end = [math]::Min($i + $Size, $Items.Count) - 1
        $chunk = @($Items[$i..$end])
        & $Action $chunk
    }
}
function Test-MinecraftRunning {
    $procs = @(Get-Process -Name javaw, java -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like 'Minecraft*' })
    return ($procs.Count -gt 0)
}

# ============================================================
#  MODRINTH API
# ============================================================
function Invoke-Modrinth {
    param([string]$Path, [string]$Method = 'Get', $Body = $null)
    $uri = $Api + $Path
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            if ($null -ne $Body) {
                $json = ConvertTo-Json -InputObject $Body -Depth 5 -Compress
                return Invoke-RestMethod -Uri $uri -Method $Method -Headers $Headers -Body $json -ContentType 'application/json' -ErrorAction Stop
            }
            return Invoke-RestMethod -Uri $uri -Method $Method -Headers $Headers -ErrorAction Stop
        } catch {
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            if ($code -eq 404) { return $null }
            if (($code -eq 429 -or $code -ge 500) -and $attempt -lt 4) {
                Start-Sleep -Seconds (2 * $attempt)
                continue
            }
            throw
        }
    }
}

function Get-BestVersion {
    param([string]$ProjectId, [string]$Type, [bool]$AnyGameVersion = $false)
    $query = @()
    if (-not $AnyGameVersion) {
        $query += 'game_versions=' + [uri]::EscapeDataString('["' + $mcVersion + '"]')
    }
    $loaderFilter = 'minecraft'
    if ($Type -eq 'mod') { $loaderFilter = $Config.Loader }
    $query += 'loaders=' + [uri]::EscapeDataString('["' + $loaderFilter + '"]')
    $path = '/project/' + $ProjectId + '/version'
    if ($query.Count -gt 0) { $path += '?' + ($query -join '&') }
    $list = @(Invoke-Modrinth -Path $path)
    if ($list.Count -eq 0 -or $null -eq $list[0]) { return $null }
    $releases = @($list | Where-Object { $_.version_type -eq 'release' })
    if ($releases.Count -gt 0) { return $releases[0] }
    return $list[0]
}

# Fetch human-readable project info one at a time (reliable)
function Get-ProjectInfo {
    param([string]$ProjectId)
    if (-not $ProjectId) { return $null }
    try {
        $proj = Invoke-Modrinth -Path ('/project/' + $ProjectId)
        if ($proj) { return $proj }
    } catch {}
    return $null
}

function Get-LatestByHash {
    param([string[]]$Hashes, [string]$Type, [bool]$AnyGameVersion = $false)
    $result = @{}
    $loaderFilter = 'minecraft'
    if ($Type -eq 'mod') { $loaderFilter = $Config.Loader }

    Invoke-Batched -Items $Hashes -Size 20 -Action {
        param($chunk)
        $arr = @($chunk)
        $body = @{ hashes = $arr; algorithm = 'sha1'; loaders = @($loaderFilter) }
        if (-not $AnyGameVersion) { $body.game_versions = @($mcVersion) }
        $r = Invoke-Modrinth -Path '/version_files/update' -Method Post -Body $body
        if ($r) { foreach ($p in $r.PSObject.Properties) { $result[$p.Name] = $p.Value } }
    }
    return $result
}

# ============================================================
#  OPTIONS GUARD
# ============================================================
function Repair-OptionsFile {
    param([string]$OptionsPath)
    if (-not (Test-Path -LiteralPath $OptionsPath)) { return @{ Fixed=$false; Reason='not found' } }
    try { $original = Get-Content -LiteralPath $OptionsPath -Raw -Encoding UTF8 }
    catch { return @{ Fixed=$false; Reason='unreadable' } }

    $issues = @()
    if ($original -match ',,')     { $issues += 'double commas' }
    if ($original -match '\[\s*,') { $issues += 'leading comma' }
    if ($original -match ',\s*\]') { $issues += 'trailing comma' }

    if ($issues.Count -eq 0) { return @{ Fixed=$false; Reason='clean' } }
    if ($Config.DryRun) { return @{ Fixed=$false; Reason='would fix: ' + ($issues -join ', ') } }

    try {
        $bdir = Join-Path $BackupDir 'options'
        if (-not (Test-Path -LiteralPath $bdir)) { New-Item -ItemType Directory -Path $bdir -Force | Out-Null }
        Copy-Item -LiteralPath $OptionsPath -Destination (Join-Path $bdir 'options.txt') -Force
        $script:BackupUsed = $true
    } catch {}

    $fixed = $original
    $fixed = $fixed -replace ',,+', ','
    $fixed = $fixed -replace '\[\s*,', '['
    $fixed = $fixed -replace ',\s*\]', ']'
    $fixed = $fixed -replace '\[\s*\]', '[]'

    if ($fixed -eq $original) { return @{ Fixed=$false; Reason='no change needed' } }

    try {
        Set-Content -LiteralPath $OptionsPath -Value $fixed -NoNewline -Encoding UTF8
        return @{ Fixed=$true; Reason=($issues -join ', ') }
    } catch {
        return @{ Fixed=$false; Reason='write failed: ' + $_.Exception.Message }
    }
}

# ============================================================
#  FILE OPS
# ============================================================
function Remove-OldFile {
    param([System.IO.FileInfo]$File, [string]$Type)
    if ($Config.Backup) {
        $dir = Join-Path $BackupDir $Type
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Move-Item -LiteralPath $File.FullName -Destination (Join-Path $dir $File.Name) -Force -ErrorAction Stop
        $script:BackupUsed = $true
    } else {
        Remove-Item -LiteralPath $File.FullName -Force -ErrorAction Stop
    }
}

function Install-ModrinthFile {
    param($Version, [string]$Folder, [string]$Type, [object[]]$Replace = @())
    $primaryFiles = @($Version.files | Where-Object { $_.primary })
    $allFiles = @($Version.files)
    $file = $null
    if ($primaryFiles.Count -gt 0) { $file = $primaryFiles[0] }
    elseif ($allFiles.Count -gt 0) { $file = $allFiles[0] }
    if (-not $file) { throw 'this version has no downloadable file' }

    $name = $file.filename -replace '[\\/:*?"<>|]', '_'
    if ($Config.DryRun) { return $name }

    $dest = Join-Path $Folder $name
    $tmp = $dest + '.part'

    try {
        Write-Activity -Text ($Glyph.Arrow + '  Downloading ' + $name) -Color $C.Info
        Invoke-WebRequest -Uri ([string]$file.url) -OutFile $tmp -UseBasicParsing -Headers $Headers -ErrorAction Stop

        $got = (Get-FileHash -LiteralPath $tmp -Algorithm SHA1).Hash.ToLower()
        if ($file.hashes.sha1 -and $got -ne ([string]$file.hashes.sha1).ToLower()) {
            throw 'checksum mismatch after download'
        }

        foreach ($old in $Replace) {
            try { Remove-OldFile -File $old -Type $Type }
            catch { throw ('cannot replace ' + $old.Name + ' - is Minecraft still running?') }
        }

        Move-Item -LiteralPath $tmp -Destination $dest -Force -ErrorAction Stop
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    } finally { Clear-Activity }
    return $name
}

function Install-Dependencies {
    param($Version, [string]$Folder, $Installed, [string]$Parent, [int]$Depth = 0)
    if ($Depth -ge 4 -or -not $Version.dependencies) { return }
    foreach ($d in @($Version.dependencies)) {
        if ($d.dependency_type -ne 'required' -or -not $d.project_id) { continue }
        if (-not $Installed.Add([string]$d.project_id)) { continue }
        try {
            $dv = Get-BestVersion -ProjectId $d.project_id -Type 'mod'
            $proj = Get-ProjectInfo -ProjectId $d.project_id
            $dName = [string]$d.project_id
            if ($proj -and $proj.title) { $dName = $proj.title }

            if (-not $dv) {
                Write-Item -Status warn -Name $dName -Detail ('no build for ' + $mcVersion) -Sub
                $Stats.Skipped++
                continue
            }

            [void](Install-ModrinthFile -Version $dv -Folder $Folder -Type 'mod')
            $status = 'dep'
            if ($Config.DryRun) { $status = 'plan' }
            Write-Item -Status $status -Name $dName -Detail ([string]$dv.version_number) -Sub
            $Stats.Deps++
            Install-Dependencies -Version $dv -Folder $Folder -Installed $Installed -Parent $dName -Depth ($Depth + 1)
        } catch {
            Add-Err ('dependency ' + $d.project_id + ' of ' + $Parent + ': ' + $_.Exception.Message)
            Write-Item -Status err -Name ([string]$d.project_id) -Detail $_.Exception.Message -Sub
        }
    }
}

# ============================================================
#  JAVA
# ============================================================
function Find-Java {
    $cmd = Get-Command java -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    $roots = @(
        (Join-Path $dotMinecraft 'runtime'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.4297127D64EC6_8wekyb3d8bbwe\LocalCache\Local\runtime'),
        (Join-Path $env:ProgramFiles 'Eclipse Adoptium'),
        (Join-Path $env:ProgramFiles 'Java'),
        (Join-Path $env:ProgramFiles 'Microsoft')
    )
    foreach ($r in $roots) {
        if ($r -and (Test-Path -LiteralPath $r)) {
            $j = Get-ChildItem -LiteralPath $r -Filter 'java.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($j) { return $j.FullName }
        }
    }
    return $null
}

# ============================================================
#  VERSION DETECTION
# ============================================================
function Extract-McVersion {
    param([string]$Vid)
    if (-not $Vid) { return $null }
    if ($Vid -match '^fabric-loader-\d+\.\d+\.\d+[^\-]*-(.+)$') {
        $mc = $Matches[1]
        if ($mc -match '^0\.') { return $null }
        if ($mc -notmatch '^\d') { return $null }
        return $mc
    }
    if ($Vid -match '^(forge|neoforge|quilt|optifine|liteloader)-[^\-]+-(.+)$') { return $Matches[2] }
    if ($Vid -match '^\d') { return $Vid }
    return $null
}

function Get-InstalledVanillaVersions {
    if (-not (Test-Path -LiteralPath $versionsDir)) { return @() }
    $all = @(Get-ChildItem -LiteralPath $versionsDir -Directory -ErrorAction SilentlyContinue)
    $vanilla = @($all | Where-Object {
        $_.Name -notmatch '^(fabric-loader|fabric|forge|neoforge|quilt|optifine|liteloader)-' -and
        $_.Name -match '^\d+\.\d+'
    })
    return @($vanilla | Sort-Object -Property @{ Expression = {
        try { [version]$_.Name } catch { [version]'0.0.0' }
    }; Descending = $true })
}

function Get-McVersion {
    if ($Config.PreferredMcVersion) {
        return @{ Version = [string]$Config.PreferredMcVersion; Source = 'config lock' }
    }
    $vanilla = @(Get-InstalledVanillaVersions)
    if ($vanilla.Count -gt 0) {
        $newest = [string]$vanilla[0].Name
        return @{ Version = $newest; Source = 'newest vanilla installed' }
    }
    Write-Item -Status unknown -Name 'Minecraft version' -Detail 'not detected'
    $default = $null
    try {
        $default = (Invoke-RestMethod -Uri 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json' -Headers $Headers -ErrorAction Stop).latest.release
    } catch {}
    Write-Host ''
    $prompt = '     >> Minecraft version (e.g. 1.21.1): '
    if ($default) { $prompt = '     >> Minecraft version [Enter = ' + $default + ']: ' }
    $answer = (Read-Host $prompt).Trim()
    if (-not $answer) { $answer = $default }
    if (-not $answer) {
        Write-Item -Status err -Name 'No version given' -Detail 'exiting'
        if (-not $NoPause) { Read-Host "`n   Press ENTER to close" | Out-Null }
        exit 1
    }
    return @{ Version = $answer; Source = 'manual entry' }
}

# ============================================================
#  FABRIC
# ============================================================
function Install-Fabric {
    param([string]$McVersion)
    if (-not $McVersion -or $McVersion -match '^0\.' -or $McVersion -notmatch '^\d') {
        Write-Item -Status warn -Name 'Fabric Loader' -Detail 'invalid Minecraft version'
        $Stats.Skipped++; return $false
    }
    Write-Item -Status info -Name 'Targeting' -Detail ('Minecraft ' + $McVersion)

    $loaderUrl = 'https://meta.fabricmc.net/v2/versions/loader/' + [uri]::EscapeDataString($McVersion)
    $loaderList = @()
    try { $loaderList = @(Invoke-RestMethod -Uri $loaderUrl -Headers $Headers -ErrorAction Stop) }
    catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        $reason = 'Fabric meta unreachable (HTTP ' + $code + ')'
        if ($code -eq 404) { $reason = 'no loader published yet for ' + $McVersion + ' (404)' }
        Write-Item -Status warn -Name 'Fabric Loader' -Detail $reason
        $Stats.Skipped++; return $false
    }
    if ($loaderList.Count -eq 0) {
        Write-Item -Status warn -Name 'Fabric Loader' -Detail 'no loader builds available'
        $Stats.Skipped++; return $false
    }
    $stableLoaders = @($loaderList | Where-Object { $_.loader -and $_.loader.stable })
    $entry = $loaderList[0]
    if ($stableLoaders.Count -gt 0) { $entry = $stableLoaders[0] }

    if (-not $entry -or -not $entry.loader -or -not $entry.loader.version) {
        Write-Item -Status warn -Name 'Fabric Loader' -Detail 'no usable loader build'
        $Stats.Skipped++; return $false
    }

    $loaderVer = [string]@($entry.loader.version)[0]
    if ($loaderVer -notmatch '^0\.\d' -or $loaderVer -eq $McVersion) {
        Write-Item -Status warn -Name 'Fabric Loader' -Detail 'unexpected loader version'
        $Stats.Skipped++; return $false
    }

    $verId = 'fabric-loader-' + $loaderVer + '-' + $McVersion
    $verJson = Join-Path (Join-Path $versionsDir $verId) ($verId + '.json')

    if (Test-Path -LiteralPath $verJson) {
        Write-Item -Status same -Name 'Fabric Loader' -Detail ($loaderVer + '  already installed')
        $Stats.Current++
        $script:fabricLoaderVersion = $loaderVer
        return $true
    }
    if ($Config.DryRun) {
        Write-Item -Status plan -Name 'Fabric Loader' -Detail ('would install ' + $loaderVer)
        $Stats.Updated++
        $script:fabricLoaderVersion = $loaderVer
        return $true
    }

    $java = Find-Java
    if (-not $java) {
        Write-Item -Status warn -Name 'Fabric Loader' -Detail 'Java not found'
        $Stats.Skipped++; return $false
    }

    $installerUrl = $null; $installerVer = $null
    try {
        $raw = @(Invoke-RestMethod -Uri 'https://meta.fabricmc.net/v2/versions/installer' -Headers $Headers -ErrorAction Stop)
        $pick = $null
        foreach ($it in $raw) { if ($it -and $it.stable -and $it.url) { $pick = $it; break } }
        if (-not $pick) { foreach ($it in $raw) { if ($it -and $it.url) { $pick = $it; break } } }
        if ($pick) {
            $installerUrl = [string]@($pick.url)[0]
            $installerVer = [string]@($pick.version)[0]
        }
    } catch {}

    if (-not $installerUrl) {
        try {
            $meta = Invoke-WebRequest -Uri 'https://maven.fabricmc.net/net/fabricmc/fabric-installer/maven-metadata.xml' -UseBasicParsing -Headers $Headers -ErrorAction Stop
            $xml = [xml]$meta.Content
            $latest = $xml.metadata.versioning.release
            if (-not $latest) { $latest = $xml.metadata.versioning.latest }
            if ($latest) {
                $installerVer = [string]$latest
                $installerUrl = 'https://maven.fabricmc.net/net/fabricmc/fabric-installer/' + $latest + '/fabric-installer-' + $latest + '.jar'
            }
        } catch {}
    }

    if (-not $installerUrl) {
        Write-Item -Status warn -Name 'Fabric Loader' -Detail 'no installer build found'
        $Stats.Skipped++; return $false
    }

    $jar = Join-Path ([IO.Path]::GetTempPath()) ('fabric-installer-' + $installerVer + '.jar')
    Write-Activity -Text ($Glyph.Arrow + '  Downloading Fabric installer ' + $installerVer) -Color $C.Info
    $jarOk = $false
    try {
        Invoke-WebRequest -Uri $installerUrl -OutFile $jar -UseBasicParsing -Headers $Headers -ErrorAction Stop
        $jarOk = $true
    } catch {
        $mavenUrl = 'https://maven.fabricmc.net/net/fabricmc/fabric-installer/' + $installerVer + '/fabric-installer-' + $installerVer + '.jar'
        if ($mavenUrl -ne $installerUrl) {
            try {
                Invoke-WebRequest -Uri $mavenUrl -OutFile $jar -UseBasicParsing -Headers $Headers -ErrorAction Stop
                $jarOk = $true
            } catch {}
        }
    }
    Clear-Activity

    if (-not $jarOk) {
        Write-Item -Status warn -Name 'Fabric Loader' -Detail 'installer download failed'
        $Stats.Skipped++; return $false
    }

    Write-Host ''
    Write-Host ('   ' + $Glyph.Arrow + '  Running Fabric installer  ') -NoNewline -ForegroundColor $C.Info
    Write-Host ('loader ' + $loaderVer + '  on  Minecraft ' + $McVersion) -ForegroundColor $C.Muted

    $argLine = '-jar "{0}" client -dir "{1}" -mcversion {2} -loader {3}' -f $jar, $dotMinecraft, $McVersion, $loaderVer
    $proc = Start-Process -FilePath $java -ArgumentList $argLine -NoNewWindow -Wait -PassThru
    Remove-Item -LiteralPath $jar -Force -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $verJson) {
        Write-Item -Status ok -Name 'Fabric Loader' -Detail ($loaderVer + '  installed')
        $Stats.Updated++
        $script:fabricLoaderVersion = $loaderVer
        return $true
    }
    $code = '?'
    if ($proc) { $code = $proc.ExitCode }
    Add-Err ('Fabric installer failed (code ' + $code + ')')
    Write-Item -Status err -Name 'Fabric Loader' -Detail ('installer failed (code ' + $code + ')')
    return $false
}

# ============================================================
#  FABRIC CLEANUP (with launcher profile removal)
# ============================================================
function Get-FabricInstalls {
    param([string]$VersionsPath)
    $list = @()
    if (-not (Test-Path -LiteralPath $VersionsPath)) { return $list }
    $dirs = @(Get-ChildItem -LiteralPath $VersionsPath -Directory -ErrorAction SilentlyContinue)
    foreach ($d in $dirs) {
        $name = $d.Name
        if ($name -match '^fabric-loader-(\d+\.\d+\.\d+[^\-]*)-(.+)$') {
            $list += [pscustomobject]@{
                Name = $name; LoaderVer = $Matches[1]; McVersion = $Matches[2]; FullName = $d.FullName
            }
        }
    }
    return $list
}

function Remove-FabricFromLauncherProfiles {
    param([string[]]$VersionNames = @())
    if (-not (Test-Path -LiteralPath $profilesFile)) { return 0 }
    try {
        $json = Get-Content -LiteralPath $profilesFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $json.profiles) { return 0 }

        # احذف أي بروفايل fabric يشير إلى مجلد غير موجود
        $orphans = @()
        foreach ($prop in @($json.profiles.PSObject.Properties)) {
            $key = $prop.Name
            $vid = [string]$prop.Value.lastVersionId
            if (-not $vid) { continue }
            if ($vid -notmatch '^fabric-loader-') { continue }

            $jsonFile = Join-Path (Join-Path $versionsDir $vid) ($vid + '.json')
            if (-not (Test-Path -LiteralPath $jsonFile)) {
                $orphans += $key
            }
        }

        # + أي اسم في القائمة الصريحة
        foreach ($vn in $VersionNames) {
            if ($orphans -notcontains $vn) { $orphans += $vn }
        }

        $removed = 0
        foreach ($key in $orphans) {
            if (@($json.profiles.PSObject.Properties.Name) -contains $key) {
                $json.profiles.PSObject.Properties.Remove($key)
                $removed++
            }
        }

        if ($removed -gt 0) {
            $remaining = @($json.profiles.PSObject.Properties.Name)
            if ($json.selectedProfile -and -not ($remaining -contains $json.selectedProfile)) {
                if ($remaining.Count -gt 0) { $json.selectedProfile = $remaining[0] }
                else { $json.selectedProfile = '' }
            }
            $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $profilesFile -Encoding UTF8
        }
        return $removed
    } catch {
        Add-Err ('launcher_profiles.json: ' + $_.Exception.Message)
        return 0
    }
}

function Invoke-FabricCleanup {
    param(
        [string]$VersionsPath,
        [string]$BackupPath,
        [string]$Mode = 'global',
        [bool]$DeletePermanent = $false,
        [bool]$CleanProfiles = $true,
        [string]$TargetMcVersion = ''
    )

    $installs = @(Get-FabricInstalls -VersionsPath $VersionsPath)
    $result = @{
        Found        = $installs.Count
        Removed      = 0
        Kept         = 0
        RemovedNames = @()
        KeptNames    = @()
        ProfilesClean = 0
    }
    if ($installs.Count -eq 0) { return $result }

    $toRemove = @()
    $toKeep   = @()

    # Helper: parse version safely
    function Get-Ver { param($s) try { return [version]$s } catch { return [version]'0.0.0' } }

    # ============================================================
    #  منطق ذكي:
    #  1. احتفظ دائماً بأحدث Fabric لإصدار MC الحالي (Target)
    #  2. احذف كل Fabric لإصدارات MC الأخرى (إن كان الوضع global)
    #  3. في وضع perMC: احتفظ بأحدث loader لكل إصدار MC
    # ============================================================

    if ($Mode -eq 'global' -and $TargetMcVersion) {
        # افصل: fabric الخاص بإصدار MC الحالي vs البقية
        $currentMc = @($installs | Where-Object { $_.McVersion -eq $TargetMcVersion })
        $otherMc   = @($installs | Where-Object { $_.McVersion -ne $TargetMcVersion })

        # احتفظ بأحدث loader لإصدار MC الحالي
        if ($currentMc.Count -gt 0) {
            $sortedCurrent = @($currentMc | Sort-Object -Property @{ Expression = { Get-Ver $_.LoaderVer }; Descending = $true })
            $toKeep += $sortedCurrent[0]
            # الباقي من نفس MC -> احذف
            for ($i = 1; $i -lt $sortedCurrent.Count; $i++) { $toRemove += $sortedCurrent[$i] }
        }

        # كل fabric لإصدارات MC الأخرى -> احذف
        foreach ($item in $otherMc) { $toRemove += $item }

    } elseif ($Mode -eq 'global') {
        # بدون TargetMcVersion: احتفظ بأحدث loader عموماً
        $sorted = @($installs | Sort-Object -Property @(
            @{ Expression = { Get-Ver $_.LoaderVer }; Descending = $true },
            @{ Expression = { Get-Ver $_.McVersion }; Descending = $true }
        ))
        $toKeep += $sorted[0]
        for ($i = 1; $i -lt $sorted.Count; $i++) { $toRemove += $sorted[$i] }

    } else {
        # perMC: احتفظ بأحدث loader لكل MC
        $byMc = @{}
        foreach ($item in $installs) {
            $mc = $item.McVersion
            if (-not $byMc.ContainsKey($mc)) { $byMc[$mc] = @() }
            $byMc[$mc] += $item
        }
        foreach ($mc in $byMc.Keys) {
            $group = @($byMc[$mc] | Sort-Object -Property @{ Expression = { Get-Ver $_.LoaderVer }; Descending = $true })
            $toKeep += $group[0]
            for ($i = 1; $i -lt $group.Count; $i++) { $toRemove += $group[$i] }
        }
    }

    $result.Kept      = $toKeep.Count
    $result.KeptNames = @($toKeep | ForEach-Object { $_.Name })

    if ($toRemove.Count -eq 0) { return $result }

    # ---- Archive or delete ----
    $fabBackup = $null
    if (-not $DeletePermanent) {
        $fabBackup = Join-Path $BackupPath 'fabric-old'
        if (-not (Test-Path -LiteralPath $fabBackup)) {
            New-Item -ItemType Directory -Path $fabBackup -Force | Out-Null
        }
    }

    $removed = @()
    foreach ($item in $toRemove) {
        try {
            if ($DeletePermanent) {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            } else {
                $dest = Join-Path $fabBackup $item.Name
                if (Test-Path -LiteralPath $dest) {
                    Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
                }
                Move-Item -LiteralPath $item.FullName -Destination $dest -Force -ErrorAction Stop
            }
            $removed += $item.Name
        } catch {
            Add-Err ('fabric cleanup ' + $item.Name + ': ' + $_.Exception.Message)
        }
    }

    $result.Removed      = $removed.Count
    $result.RemovedNames = $removed

    # ---- Clean launcher profiles ----
    if ($CleanProfiles -and $removed.Count -gt 0) {
        $result.ProfilesClean = Remove-FabricFromLauncherProfiles -VersionNames $removed
    }

    return $result
}
# ============================================================
#  MODS-DISABLED
# ============================================================
function Restore-DisabledMods {
    param([string]$ModsDir, [string]$DisabledDir)
    if (-not (Test-Path -LiteralPath $DisabledDir)) { return 0 }
    $stashed = @(Get-ChildItem -LiteralPath $DisabledDir -Filter '*.jar' -File -ErrorAction SilentlyContinue)
    if ($stashed.Count -eq 0) { return 0 }
    if (-not (Test-Path -LiteralPath $ModsDir)) { New-Item -ItemType Directory -Path $ModsDir -Force | Out-Null }
    $count = 0
    foreach ($f in $stashed) {
        try {
            $dest = Join-Path $ModsDir $f.Name
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
            Move-Item -LiteralPath $f.FullName -Destination $dest -Force
            $count++
        } catch { Add-Err ('restore ' + $f.Name + ': ' + $_.Exception.Message) }
    }
    return $count
}

function Disable-IncompatibleMods {
    param([string]$DisabledDir)
    if (-not (Test-Path -LiteralPath $DisabledDir)) {
        New-Item -ItemType Directory -Path $DisabledDir -Force | Out-Null
    }
    foreach ($f in $script:incompatibleMods) {
        try {
            if (-not (Test-Path -LiteralPath $f.FullName)) { continue }
            $dest = Join-Path $DisabledDir $f.Name
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
            Move-Item -LiteralPath $f.FullName -Destination $dest -Force
            Write-Item -Status disabled -Name $f.Name -Detail 'moved to mods-disabled\' -Sub
            $Stats.Disabled++
        } catch { Add-Err ('disable ' + $f.Name + ': ' + $_.Exception.Message) }
    }
}

# ============================================================
#  SYNC FOLDER
# ============================================================
function Sync-Folder {
    param([hashtable]$Spec)
    $folder = $Spec.Path
    $type   = $Spec.Type

    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }

    $files = @(Get-ChildItem -LiteralPath $folder -Filter $Spec.Filter -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        Write-Item -Status unknown -Name '(empty folder)' -Detail ''
        return
    }

    # Fingerprint all files
    $byHash = @{}
    $i = 0
    foreach ($f in $files) {
        $i++
        Write-ProgressBar -Current $i -Total $files.Count -Label 'Fingerprinting files'
        try {
            $h = Get-CachedHash -File $f
            if (-not $byHash.ContainsKey($h)) { $byHash[$h] = @() }
            $byHash[$h] += $f
        } catch { Add-Err ($f.Name + ': cannot read file') }
    }
    Clear-Activity

    $nameGroups = @($files | Group-Object -Property Name | Where-Object { $_.Count -gt 1 })
    foreach ($g in $nameGroups) { [void]$duplicateWarnings.Add('duplicate in ' + $type + ': ' + $g.Name) }

    # Identify files on Modrinth
    $current = @{}
    try {
        Write-Activity -Text ($Glyph.Arrow + '  Querying Modrinth ...') -Color $C.Info
        Invoke-Batched -Items @($byHash.Keys) -Size 20 -Action {
            param($chunk)
            $arr = @($chunk)
            $r = Invoke-Modrinth -Path '/version_files' -Method Post -Body @{ hashes = $arr; algorithm = 'sha1' }
            if ($r) { foreach ($p in $r.PSObject.Properties) { $current[$p.Name] = $p.Value } }
        }
    } catch {
        Clear-Activity
        Add-Err ('Modrinth unreachable: ' + $_.Exception.Message)
        Write-Item -Status err -Name 'Modrinth API' -Detail 'unreachable'
        return
    }
    Clear-Activity

    # Group by project
    $groups = @{}
    $unknown = @()
    foreach ($h in $byHash.Keys) {
        foreach ($f in $byHash[$h]) {
            if ($current.ContainsKey($h)) {
                $v = $current[$h]
                if (-not $groups.ContainsKey($v.project_id)) { $groups[$v.project_id] = @() }
                $groups[$v.project_id] += [pscustomobject]@{ Hash = $h; File = $f; Version = $v }
            } else { $unknown += $f }
        }
    }

    # Fetch project info ONE AT A TIME (reliable)
    Write-Activity -Text ($Glyph.Arrow + '  Fetching project names ...') -Color $C.Info
    $titles = @{}
    foreach ($projId in @($groups.Keys)) {
        $proj = Get-ProjectInfo -ProjectId $projId
        if ($proj -and $proj.title) { $titles[[string]$projId] = $proj.title }
    }
    Clear-Activity

    # Get latest versions
    $latest = @{}
    $anyVer = @{}
    try {
        $latest = Get-LatestByHash -Hashes @($current.Keys) -Type $type
        if ($type -ne 'mod') {
            $missing = @($current.Keys | Where-Object { -not $latest.ContainsKey($_) })
            if ($missing.Count -gt 0) {
                $fallback = Get-LatestByHash -Hashes $missing -Type $type -AnyGameVersion $true
                foreach ($k in $fallback.Keys) { $latest[$k] = $fallback[$k]; $anyVer[$k] = $true }
            }
        }
    } catch {
        Add-Err ('update lookup failed: ' + $_.Exception.Message)
        Write-Item -Status err -Name 'Modrinth API' -Detail 'update lookup failed'
        return
    }

    $installed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $groups.Keys) { [void]$installed.Add([string]$k) }

    $order = @($groups.Keys | Sort-Object { if ($titles[[string]$_]) { $titles[[string]$_] } else { [string]$_ } })
    $n = 0
    foreach ($projId in $order) {
        $n++
        $entries = @($groups[$projId])
        $name = [string]$projId
        if ($titles[[string]$projId]) { $name = $titles[[string]$projId] }

        try {
            $ref = $entries | Sort-Object { ConvertTo-Date $_.Version.date_published } -Descending | Select-Object -First 1
            $stale = @($entries | Where-Object { $_.File.FullName -ne $ref.File.FullName })
            $cur = $ref.Version
            $lat = $latest[$ref.Hash]

            if ($null -eq $lat) {
                if ($type -eq 'mod') {
                    $willDisable = ($Config.AutoDisableIncompatible -and -not $Config.DryRun)
                    $detail = 'no build for ' + $mcVersion
                    if ($willDisable) { $detail = 'no build for ' + $mcVersion + '  ' + $Glyph.Arrow + '  disabling' }
                    Write-Item -Status warn -Name $name -Detail $detail -Index $n
                    $Stats.Skipped++
                    if ($willDisable) {
                        foreach ($entry in $entries) { [void]$script:incompatibleMods.Add($entry.File) }
                    }
                } else {
                    $sizeTxt = Format-Size -Bytes $ref.File.Length
                    Write-Item -Status unknown -Name $name -Detail ($sizeTxt + '  not on Modrinth') -Index $n
                    $Stats.Unknown++
                }
                continue
            }

            if ($lat.version_type -ne 'release') {
                $anyFlag = [bool]$anyVer.ContainsKey($ref.Hash)
                $rel = Get-BestVersion -ProjectId ([string]$projId) -Type $type -AnyGameVersion $anyFlag
                if ($rel -and $rel.version_type -eq 'release') { $lat = $rel }
            }

            $curOk = ($type -ne 'mod')
            if ($type -eq 'mod') {
                $curOk = (($cur.game_versions -contains $mcVersion) -and ($cur.loaders -contains $Config.Loader))
            }
            $isCurrent = ($lat.id -eq $cur.id)
            if (-not $isCurrent -and $curOk) {
                $isCurrent = ((ConvertTo-Date $cur.date_published) -ge (ConvertTo-Date $lat.date_published))
            }

            $note = ''
            if ($anyVer.ContainsKey($ref.Hash)) { $note = '  (fallback)' }

            if ($isCurrent) {
                Write-Item -Status same -Name $name -Detail ([string]$cur.version_number) -Index $n
                $Stats.Current++
                foreach ($s in $stale) {
                    if (-not $Config.DryRun) { Remove-OldFile -File $s.File -Type $type }
                    Write-Item -Status note -Name '' -Detail ('duplicate archived: ' + $s.File.Name) -Sub
                }
                if ($type -eq 'mod') {
                    Install-Dependencies -Version $cur -Folder $folder -Installed $installed -Parent $name
                }
            } else {
                $replace = @($entries | ForEach-Object { $_.File })
                [void](Install-ModrinthFile -Version $lat -Folder $folder -Type $type -Replace $replace)
                $status = 'ok'
                if ($Config.DryRun) { $status = 'plan' }
                $detail = [string]$cur.version_number + ' ' + $Glyph.Arrow + ' ' + [string]$lat.version_number + $note
                Write-Item -Status $status -Name $name -Detail $detail -Index $n
                $Stats.Updated++
                if ($type -eq 'mod') {
                    Install-Dependencies -Version $lat -Folder $folder -Installed $installed -Parent $name
                }
            }
        } catch {
            Add-Err ($name + ': ' + $_.Exception.Message)
            Write-Item -Status err -Name $name -Detail $_.Exception.Message -Index $n
        }
    }

    foreach ($f in $unknown) {
        $n++
        $sizeTxt = Format-Size -Bytes $f.Length
        Write-Item -Status unknown -Name $f.Name -Detail ($sizeTxt + '  not on Modrinth') -Index $n
        $Stats.Unknown++
    }
}

# ============================================================
#  REPORT
# ============================================================
function Write-Report {
    param([string]$Elapsed, [string]$BackupRel)
    Write-Section -Icon $Glyph.Chart -Title 'Report'
    Write-Host ''

    $rows = @()
    $colorUpdated = $C.Muted; if ($Stats.Updated -gt 0) { $colorUpdated = $C.Success }
    $colorDeps = $C.Muted; if ($Stats.Deps -gt 0) { $colorDeps = $C.Info }
    $colorSkipped = $C.Muted; if ($Stats.Skipped -gt 0) { $colorSkipped = $C.Warning }
    $colorErrors = $C.Muted; if ($Stats.Errors -gt 0) { $colorErrors = $C.Error }

    $rows += @{ L = 'Updated';  V = $Stats.Updated; C = $colorUpdated }
    $rows += @{ L = 'Current';  V = $Stats.Current; C = $C.Muted }
    $rows += @{ L = 'Deps';     V = $Stats.Deps;    C = $colorDeps }
    $rows += @{ L = 'Skipped';  V = $Stats.Skipped; C = $colorSkipped }
    $rows += @{ L = 'Unknown';  V = $Stats.Unknown; C = $C.Muted }
    $rows += @{ L = 'Errors';   V = $Stats.Errors;  C = $colorErrors }
    if ($Stats.Disabled -gt 0)      { $rows += @{ L = 'Kept aside'; V = $Stats.Disabled; C = $C.Warning } }
    if ($Stats.Restored -gt 0)      { $rows += @{ L = 'Restored';   V = $Stats.Restored; C = $C.Success } }
    if ($Stats.OptionsFixed -gt 0)  { $rows += @{ L = 'Options fix'; V = $Stats.OptionsFixed; C = $C.Success } }
    if ($Stats.FabricCleaned -gt 0) { $rows += @{ L = 'Fabric old'; V = $Stats.FabricCleaned; C = $C.Success } }
    if ($Stats.ProfilesCleaned -gt 0) { $rows += @{ L = 'Profiles'; V = $Stats.ProfilesCleaned; C = $C.Success } }

    $half = [math]::Ceiling($rows.Count / 2)
    for ($i = 0; $i -lt $half; $i++) {
        $left = $rows[$i]
        $right = $null
        if ($i + $half -lt $rows.Count) { $right = $rows[$i + $half] }
        Write-Host '       ' -NoNewline
        Write-Host $left.L.PadRight(16) -NoNewline -ForegroundColor $C.Muted
        Write-Host ([string]$left.V).PadLeft(3).PadRight(16) -NoNewline -ForegroundColor $left.C
        if ($right) {
            Write-Host $right.L.PadRight(16) -NoNewline -ForegroundColor $C.Muted
            Write-Host ([string]$right.V).PadLeft(3) -ForegroundColor $right.C
        } else { Write-Host '' }
    }

    Write-Host ''
    Write-Host '       ' -NoNewline
    Write-Host 'Minecraft'.PadRight(16) -NoNewline -ForegroundColor $C.Muted
    Write-Host $mcVersion -ForegroundColor $C.Emphasis

    if ($fabricLoaderVersion) {
        Write-Host '       ' -NoNewline
        Write-Host 'Fabric Loader'.PadRight(16) -NoNewline -ForegroundColor $C.Muted
        Write-Host $fabricLoaderVersion -ForegroundColor $C.Emphasis
    }

    Write-Host '       ' -NoNewline
    Write-Host 'Elapsed'.PadRight(16) -NoNewline -ForegroundColor $C.Muted
    Write-Host $Elapsed -ForegroundColor $C.Muted

    if (($hashHits + $hashMiss) -gt 0) {
        Write-Host '       ' -NoNewline
        Write-Host 'Hash cache'.PadRight(16) -NoNewline -ForegroundColor $C.Muted
        Write-Host ($hashHits.ToString() + ' hit  ' + $Glyph.Dot + '  ' + $hashMiss.ToString() + ' new') -ForegroundColor $C.Muted
    }

    if ($BackupRel) {
        Write-Host '       ' -NoNewline
        Write-Host 'Backups'.PadRight(16) -NoNewline -ForegroundColor $C.Muted
        Write-Host $BackupRel -ForegroundColor $C.Muted
    }
}

function Start-Launcher {
    $candidates = @()
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Minecraft Launcher\MinecraftLauncher.exe') }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Minecraft Launcher\MinecraftLauncher.exe') }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { Start-Process -FilePath $c; return $true } }
    try {
        Start-Process 'shell:AppsFolder\Microsoft.4297127D64EC6_8wekyb3d8bbwe!Minecraft' -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Save-Reports {
    param([string]$ReportText)
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
        Set-Content -LiteralPath (Join-Path $reportDir ('report-' + $stamp + '.txt')) -Value $ReportText -Encoding UTF8
        $logFile = Join-Path $logDir ('log-' + (Get-Date -Format 'yyyy-MM-dd') + '.txt')
        $header = "`n===== {0:yyyy-MM-dd HH:mm:ss} | MC {1} | Loader {2} =====`n" -f (Get-Date), $mcVersion, $fabricLoaderVersion
        $summary = 'Updated=' + $Stats.Updated + ' Current=' + $Stats.Current + ' Deps=' + $Stats.Deps + ' Skipped=' + $Stats.Skipped + ' Unknown=' + $Stats.Unknown + ' Errors=' + $Stats.Errors
        Add-Content -LiteralPath $logFile -Value ($header + $summary) -Encoding UTF8

        $old = @(Get-ChildItem -LiteralPath $reportDir -File -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending | Select-Object -Skip $Config.ReportKeep)
        foreach ($r in $old) { Remove-Item -LiteralPath $r.FullName -Force -ErrorAction SilentlyContinue }
        $oldLogs = @(Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending | Select-Object -Skip $Config.LogKeep)
        foreach ($r in $oldLogs) { Remove-Item -LiteralPath $r.FullName -Force -ErrorAction SilentlyContinue }
    } catch {}
}

function Write-Footer {
    Write-Host ''
    Write-Rule
    Write-Host ''
    Write-Host '   Designed & built by ' -NoNewline -ForegroundColor $C.Muted
    Write-Host 'BLACKOZE' -NoNewline -ForegroundColor $C.Emphasis
    $right = 'v15'
    $pad = $RuleWidth - 22 - $right.Length
    if ($pad -lt 1) { $pad = 1 }
    Write-Host ((' ' * $pad) + $right) -ForegroundColor $C.Muted
    Write-Rule
    Write-Host ''
}

# ============================================================
#  MAIN
# ============================================================
$reportBuilder = New-Object System.Text.StringBuilder
try {
    Write-Banner

    if (Test-MinecraftRunning) {
        Write-BigWarning -Title 'MINECRAFT IS RUNNING' -Lines @(
            'Close Minecraft before continuing.',
            'Files in use cannot be replaced, and mods cannot be updated.',
            'The script will continue, but some updates may fail.'
        )
    }

    if ($Config.OptionsGuard) {
        Write-Section -Icon $Glyph.Shield -Title 'Options Guard'
        $repair = Repair-OptionsFile -OptionsPath $optionsFile
        if ($repair.Fixed) {
            $Stats.OptionsFixed++
            Write-Item -Status fixed -Name 'options.txt' -Detail ('repaired: ' + $repair.Reason)
        } elseif ($repair.Reason -match '^would fix') {
            Write-Item -Status plan -Name 'options.txt' -Detail $repair.Reason
        } elseif ($repair.Reason -eq 'clean') {
            Write-Item -Status same -Name 'options.txt' -Detail 'no issues'
        } else {
            Write-Item -Status note -Name 'options.txt' -Detail $repair.Reason
        }
    }

    Write-Section -Icon $Glyph.Game -Title 'Minecraft Version'
    $target = Get-McVersion
    $mcVersion = $target.Version
    Write-Item -Status info -Name 'Target Version' -Detail ($mcVersion + '  (' + $target.Source + ')')

    if (-not $NoFabric) {
        Write-Section -Icon $Glyph.Thread -Title 'Fabric Loader'
        $fabricOk = Install-Fabric -McVersion $mcVersion
        if ($fabricOk -and $fabricLoaderVersion) {
            Write-Item -Status info -Name 'Pinned' -Detail ('loader ' + $fabricLoaderVersion + '  ' + $Glyph.Arrow + '  MC ' + $mcVersion)
        } elseif (-not $fabricOk) {
            Write-Item -Status warn -Name 'Fabric not updated' -Detail ('mods still synced for MC ' + $mcVersion)
        }
    }

    if ($Config.FabricCleanup -and -not $Config.DryRun) {
        Write-Section -Icon $Glyph.Broom -Title 'Fabric Cleanup' -Meta ('mode: ' + $Config.FabricCleanupMode)
        $cleanup = Invoke-FabricCleanup -VersionsPath $versionsDir -BackupPath $BackupDir -Mode $Config.FabricCleanupMode -DeletePermanent $Config.FabricCleanupDelete -CleanProfiles $false -TargetMcVersion $mcVersion

        if ($cleanup.Found -eq 0) {
            Write-Item -Status same -Name 'No Fabric installs found' -Detail 'nothing to clean'
        } elseif ($cleanup.Removed -eq 0) {
            Write-Item -Status same -Name 'Fabric versions' -Detail ($cleanup.Kept.ToString() + ' version(s)  ' + $Glyph.Dot + '  all latest')
        } else {
            foreach ($kn in $cleanup.KeptNames) {
                Write-Item -Status same -Name $kn -Detail 'protected (current MC)'
            }
            foreach ($rn in $cleanup.RemovedNames) {
                Write-Item -Status cleanup -Name $rn -Detail 'archived to backup'
            }
            $sum = $cleanup.Kept.ToString() + ' kept  ' + $Glyph.Dot + '  ' + $cleanup.Removed.ToString() + ' removed'
            if ($cleanup.ProfilesClean -gt 0) { $sum += '  ' + $Glyph.Dot + '  ' + $cleanup.ProfilesClean.ToString() + ' launcher profiles' }
            Write-Item -Status info -Name 'Summary' -Detail $sum
            $Stats.FabricCleaned = $cleanup.Removed
            $Stats.ProfilesCleaned = $cleanup.ProfilesClean
            $script:BackupUsed = $true
        }
    }

    # --- Write Fabric launcher profile (clean slate) ---
    if ($fabricOk -and $fabricLoaderVersion) {
        Write-Section -Icon $Glyph.Package -Title 'Launcher Profile'

        $procNames = @('Minecraft','MinecraftLauncher','minecraft-launcher','Minecraft.Windows')
        $killed = 0
        foreach ($pn in $procNames) {
            foreach ($p in @(Get-Process -Name $pn -ErrorAction SilentlyContinue)) {
                try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $killed++ } catch {}
            }
        }
        if ($killed -gt 0) {
            Start-Sleep -Seconds 2
            Write-Item -Status ok -Name 'Processes closed' -Detail $killed.ToString()
        }

        $profileKey  = 'fabric-loader-' + $mcVersion
        $profileVer  = 'fabric-loader-' + $fabricLoaderVersion + '-' + $mcVersion
        $profileDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        $profileIcon = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAIAAAACABAMAAAAxEHz4AAAAGFBMVEUAAAA4NCrb0LTGvKW8spyAem2uppSakn5SsnMLAAAAAXRSTlMAQObYZgAAAJ5JREFUaIHt1MENgCAMRmFWYAVXcAVXcAVXcH3bhCYNkYjcKO8dSf7v1JASUWdZAlgb0PEmDSMAYYBdGkYApgf8ER3SbwRgesAf0BACMD1gB6S9IbkEEBfwY49oNj4lgLhA64C0o9R9RABTAvp4SX5kB2TA5y8EEAK4pRrxB9QcA4QBWkj3GCAMUCO/xwBhAI/kEsCagCHDY4AwAC3VA6t4zTAMj0OJAAAAAElFTkSuQmCC'

        # Delete MS Store file - launcher will read from main
        $pfMsPath = Join-Path $dotMinecraft 'launcher_profiles_microsoft_store.json'
        if (Test-Path -LiteralPath $pfMsPath) {
            Remove-Item -LiteralPath $pfMsPath -Force -ErrorAction SilentlyContinue
        }

        # Read main file
        $pfMainPath = Join-Path $dotMinecraft 'launcher_profiles.json'
        $profObj = $null
        if (Test-Path -LiteralPath $pfMainPath) {
            try { $profObj = Get-Content -LiteralPath $pfMainPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
        }
        if (-not $profObj) {
            $profObj = [PSCustomObject]@{ profiles=[PSCustomObject]@{}; settings=[PSCustomObject]@{}; version=3 }
        }
        if (-not ($profObj.PSObject.Properties.Name -contains 'profiles') -or -not $profObj.profiles) {
            $profObj | Add-Member -MemberType NoteProperty -Name 'profiles' -Value ([PSCustomObject]@{}) -Force
        }

        # Remove ALL fabric profiles (clean slate)
        $removedCnt = 0
        foreach ($prop in @($profObj.profiles.PSObject.Properties)) {
            if ($prop.Value.lastVersionId -like 'fabric-loader-*' -or $prop.Name -like 'fabric-loader-*') {
                $profObj.profiles.PSObject.Properties.Remove($prop.Name)
                $removedCnt++
            }
        }

        # Add fresh profile
        $newProf = [PSCustomObject]@{
            created       = $profileDate
            icon          = $profileIcon
            lastUsed      = $profileDate
            lastVersionId = $profileVer
            name          = $profileKey
            type          = 'custom'
        }
        $profObj.profiles | Add-Member -MemberType NoteProperty -Name $profileKey -Value $newProf -Force

        # Backup + write
        $pfStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        if (Test-Path -LiteralPath $pfMainPath) {
            Copy-Item -LiteralPath $pfMainPath -Destination ($pfMainPath + '.bak-' + $pfStamp) -Force -ErrorAction SilentlyContinue
        }
        try {
            $jsonText = $profObj | ConvertTo-Json -Depth 20
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($pfMainPath, $jsonText, $utf8)
            $detail = 'profile ' + $profileKey + ' written'
            if ($removedCnt -gt 0) { $detail = $detail + ' (' + $removedCnt + ' old removed)' }
            Write-Item -Status ok -Name 'launcher_profiles.json' -Detail $detail
        } catch {
            Write-Item -Status err -Name 'launcher_profiles.json' -Detail $_.Exception.Message
            Add-Err ('profile write: ' + $_.Exception.Message)
        }

        # Verify
        Start-Sleep -Milliseconds 300
        try {
            $verify = Get-Content -LiteralPath $pfMainPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $fps = @($verify.profiles.PSObject.Properties | Where-Object { $_.Value.lastVersionId -like 'fabric-loader-*' })
            if ($fps.Count -eq 1) {
                Write-Item -Status same -Name 'Verification' -Detail '1 fabric profile'
            } else {
                Write-Item -Status warn -Name 'Verification' -Detail ($fps.Count.ToString() + ' fabric profiles')
            }
        } catch {
            Write-Item -Status warn -Name 'Verification' -Detail 'could not verify'
        }
    }
    $modsDir = Join-Path $dotMinecraft 'mods'
    if ($Config.AutoDisableIncompatible -and -not $Config.DryRun) {
        $restored = Restore-DisabledMods -ModsDir $modsDir -DisabledDir $modsDisabled
        if ($restored -gt 0) {
            Write-Section -Icon $Glyph.Move -Title 'Mods-disabled'
            Write-Item -Status restored -Name 'Restored' -Detail ($restored.ToString() + ' mod(s) for re-evaluation')
            $Stats.Restored = $restored
        }
    }

    $Folders = @(
        @{ Path = $modsDir;                                  Filter = '*.jar'; Type = 'mod';          Icon = $Glyph.Package; Title = 'Mods'          }
        @{ Path = (Join-Path $dotMinecraft 'shaderpacks');   Filter = '*.zip'; Type = 'shader';       Icon = $Glyph.Palette; Title = 'Shaders'       }
        @{ Path = (Join-Path $dotMinecraft 'resourcepacks'); Filter = '*.zip'; Type = 'resourcepack'; Icon = $Glyph.Brush;   Title = 'ResourcePacks' }
    )

    foreach ($spec in $Folders) {
        $files = @(Get-ChildItem -LiteralPath $spec.Path -Filter $spec.Filter -File -ErrorAction SilentlyContinue)
        $meta = 'empty'
        if ($files.Count -gt 0) { $meta = $files.Count.ToString() + ' files' }
        Write-Section -Icon $spec.Icon -Title $spec.Title -Meta $meta
        Sync-Folder -Spec $spec

        if ($spec.Type -eq 'mod' -and $Config.AutoDisableIncompatible -and -not $Config.DryRun) {
            if ($incompatibleMods.Count -gt 0) {
                Write-Section -Icon $Glyph.Move -Title 'Auto-manage' -Meta 'incompatible mods'
                Disable-IncompatibleMods -DisabledDir $modsDisabled
            }
        }
    }

    if ($script:BackupUsed) {
        try {
            $oldBackups = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending | Select-Object -Skip $Config.KeepBackups)
            foreach ($b in $oldBackups) { Remove-Item -LiteralPath $b.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        } catch {}
    }

    $elapsedSeconds = [int][math]::Round(((Get-Date) - $startTime).TotalSeconds)
    $elapsedText = '{0}m {1:00}s' -f ([int][math]::Floor($elapsedSeconds / 60)), ($elapsedSeconds % 60)
    $backupRel = $null
    if ($script:BackupUsed) { $backupRel = $BackupDir.Substring($dotMinecraft.Length).TrimStart('\', '/') }

    Write-Report -Elapsed $elapsedText -BackupRel $backupRel
    Write-Host ''
    Write-Rule
    Write-Host ''

    if ($duplicateWarnings.Count -gt 0) {
        Write-Host ('   ' + $Glyph.Tri + '  Duplicate warnings:') -ForegroundColor $C.Warning
        foreach ($d in $duplicateWarnings) { Write-Host ('      ' + $Glyph.Dot + '  ' + $d) -ForegroundColor $C.Warning }
        Write-Host ''
    }
    if ($ErrorLog.Count -gt 0) {
        Write-Host ('   ' + $Glyph.Cross + '  Errors:') -ForegroundColor $C.Error
        foreach ($err in $ErrorLog) { Write-Host ('      ' + $Glyph.Dot + '  ' + $err) -ForegroundColor $C.Error }
        Write-Host ''
    }
    if ($Stats.Errors -eq 0 -and $duplicateWarnings.Count -eq 0) {
        Write-Host ('   ' + $Glyph.Tick + '  All done.') -ForegroundColor $C.Success
        Write-Host ''
    }

    Save-Reports -ReportText $reportBuilder.ToString()
    Save-HashCache

    if ($Config.Launch -and -not $Config.DryRun) {
        Write-Activity -Text ($Glyph.Arrow + '  Starting Minecraft Launcher ...') -Color $C.Success
        if (Start-Launcher) { Clear-Activity; Write-Item -Status ok -Name 'Launcher' -Detail 'started' }
        else { Clear-Activity; Write-Item -Status warn -Name 'Launcher' -Detail 'executable not found' }
        Write-Host ''
    }

    Write-Footer

    if ($NoPause) { exit 0 }
    Write-Host '   ' -NoNewline
    Read-Host 'Press ENTER to close' | Out-Null
} catch {
    Write-Host ''
    Write-Host ('   ' + $Glyph.Cross + '  FATAL ERROR') -ForegroundColor $C.Error
    Write-Host ('      ' + $_.Exception.Message) -ForegroundColor $C.Error
    Write-Host ''
    try { Save-HashCache } catch {}
    Write-Footer
    if (-not $NoPause) { Read-Host '   Press ENTER to close' | Out-Null }
    exit 1
}
