#Requires -Version 5.1
<#
  PAYCHECK LIVE widget (WPF, PowerShell 5.1) - companion to the Tesla Charging Cost widget.
  Same look (dark #0B0B0B card, red title accent, Segoe UI), same width (288 DIP), 50% taller (720 vs 480 DIP).
  Headline = APPROXIMATE NET (take-home) pay.

  Usage:
    powershell -File PaycheckWidget.ps1                                  # live widget
    powershell -File PaycheckWidget.ps1 -SimulateNow "2026-09-29 19:00"
    powershell -File PaycheckWidget.ps1 -SelfTest                        # math checks, no UI
    powershell -File PaycheckWidget.ps1 -SimulateNow "..." -RenderPng out.png [-RenderScale 2]
  Test-widget build (PaycheckWidgetTest.ps1) is this same file with $TestMode = $true.
#>
param(
    [string]$SimulateNow,
    [string]$RenderPng,
    [double]$RenderScale = 1,
    [switch]$SelfTest,
    [bool]$TestMode = $true,
    # automation hooks for the TEST widget (used for renders / verification only)
    [switch]$TestAutoStart,
    [double]$TestStartOffsetMin = 0,
    [double]$TestAutoStopAfterSec = -1,
    [double]$TestRestartAfterSec = -1,
    [double]$RenderDelaySec = 0,
    [switch]$DisplayOff,         # v1.6.0: start with the display OFF (render/verification only; not saved)
    [string]$FakeLatest = '',    # v1.10.0: render/verification only - pretend this version is published
    [switch]$NoNetwork,          # v1.10.0: skip update checks + install logging
    [string]$RenderSettingsPng = '',   # v1.11.0: render the settings window (full height) to a PNG
    [switch]$SettingsScrollEnd,        # v1.11.0: render the settings window scrolled to the bottom (donate section)
    [switch]$SettingsFirst,      # v1.11.0: ... as the first-run setup wizard
    [switch]$InstallerPreview,   # v1.12.0: "Paycheck Live INSTALLER PREVIEW" window - full install/setup from scratch every open, real profile untouched
    [string]$PunchScript = '',   # v1.12.0: render/verification only - e.g. "in@11:35,lo@15:02:10,li@15:58,bs@17:05,be@17:12" punched on the (sim) day
    [string]$TestClicks = '',    # v1.14.0: render/verification only - punch buttons to click after the TEST start offset, e.g. "out"
    [string]$PreviewName = '',   # v1.12.0: render/verification only - auto-complete the preview setup with this name
    [switch]$AppMode,            # v2.0.0: running inside PaycheckLive.exe (standalone app): data in %APPDATA%\PaycheckLive
    [string]$HostExe = '',       # v2.0.0: full path of PaycheckLive.exe (relaunch after an update)
    [string]$HostVersion = '',   # v2.0.0: version of PaycheckLive.exe (a newer host version is delivered through the Setup exe)
    [string]$AppIcon = ''        # v2.0.0: .ico for the window / taskbar
)

$ErrorActionPreference = 'Stop'
$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
# v1.12.0 installer preview: every file it writes lives in a scratch folder that is wiped on each open (never the real profile)
$dataDir = $scriptDir
if ($InstallerPreview) {
    $TestMode = $false; $NoNetwork = [switch]$true
    $dataDir = Join-Path ([IO.Path]::GetTempPath()) 'PaycheckLiveInstallerPreview'
    try { if (Test-Path -LiteralPath $dataDir) { Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    [void](New-Item -ItemType Directory -Path $dataDir -Force)
}
# v2.0.0 standalone app: user data lives in %APPDATA%\PaycheckLive (TEST: %APPDATA%\PaycheckLive\Test), migrated once from the old widget folder
if ($AppMode -and -not $InstallerPreview) {
    $dataDir = Join-Path $env:APPDATA $(if ($TestMode) { 'PaycheckLive\Test' } else { 'PaycheckLive' })
    if (-not (Test-Path -LiteralPath $dataDir)) { [void](New-Item -ItemType Directory -Path $dataDir -Force) }
    $legacy = Join-Path ([Environment]::GetFolderPath('MyDocuments')) $(if ($TestMode) { 'PaycheckWidgetTest' } else { 'PaycheckWidget' })
    if (-not (Test-Path -LiteralPath (Join-Path $dataDir 'profile.json')) -and (Test-Path -LiteralPath (Join-Path $legacy 'profile.json'))) {
        $moved = @()
        # update-config.json is NOT copied: the old one points at the old server address
        foreach ($fn in 'profile.json','tax-settings.json','paycheck-history.json','punches.json','punches-test.json','display-state.json','display-state-test.json','install-state.json','install-state-test.json') {
            $src = Join-Path $legacy $fn; $dst = Join-Path $dataDir $fn
            if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) { try { Copy-Item -LiteralPath $src -Destination $dst; $moved += $fn } catch {} }
        }
        try { Set-Content -LiteralPath (Join-Path $dataDir 'migrated-from.txt') -Value ('Copied from ' + $legacy + ' on ' + (Get-Date).ToString('yyyy-MM-dd HH:mm') + ' (v2.0.0): ' + ($moved -join ', ') + '. The old folder was left in place as a backup.') } catch {}
    }
}
$cfgDir = $(if ($AppMode -and -not $InstallerPreview) { $dataDir } else { $scriptDir })   # v2.0.0: settings files follow the user data in app mode
$historyPath  = Join-Path $cfgDir 'paycheck-history.json'
$settingsPath = Join-Path $cfgDir 'tax-settings.json'
$displayPath  = Join-Path $dataDir $(if ($TestMode) { 'display-state-test.json' } else { 'display-state.json' })   # v1.6.0 ON/OFF
$ShareUrlDefault = 'https://spoo.me/QrYfV9'    # v2.0.0: short link to the download / landing page (set by publish.py; the version manifest's shareUrl wins)
$UpdateApiDefault = 'https://vanwidick.github.io/paycheck-live/api/'   # v1.10.0: version manifest / release endpoint (set by publish.py; update-config.json overrides)
$AppVersion = '2.0.15'; $AppVersionDate = '2026-10-22'; $AppUpdated = 'OCT 22, 2026 10:52 PM'   # v1.14.1: footer UPDATED stamp (set by publish.py)

# Tesla widget is 288 x 480 DIPs. Same width, 50% taller.
$winW = 288
$winH = 990   # v1.15.0: 768 -> 990 for the bigger punch / break focus area (clamped to the screen work area at placement); v1.14.0: 720 -> 768 for the gross pay breakdown + diff/OT columns; 288 x 720 (Tesla 480 x 1.5); layout tightened so the DESIGN BY VAN footer fits

# ---------------------------------------------------------------- tax settings (defaults; tax-settings.json may override)
$Tax = [ordered]@{
    PayPeriodsPerYear = 26              # v1.9.0: biweekly
    Pretax401kPct     = [decimal]10.0   # traditional pre-tax 401(k): reduces FIT + OK wages, NOT SS/Medicare (v1.10.0: 10%, paystub $245.81 on $2,458.07)
    FedFilingStatus   = 'HeadOfHousehold'
    FedStep2Checked   = $false
    FedStep3Credits   = [decimal]0
    FedStep4aOther    = [decimal]0
    FedStep4bDeduct   = [decimal]0
    FedStep4cExtra    = [decimal]0
    SocialSecurityPct = [decimal]6.2
    MedicarePct       = [decimal]1.45
    OkFilingStatus    = 'Single'        # OK-W-4 has no HOH box; HOH filers use Single tables
    OkAllowances      = 1               # OK-W-4 line 1 (yourself); add dependents here
    OkExtraPerCheck   = [decimal]0
    AfterTaxStockPerCheck = [decimal]50.00   # v1.10.0: after-tax stock purchase per biweekly check (no tax effect)
}
try {
    if (Test-Path -LiteralPath $settingsPath) {
        $js = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($Tax.Keys)) {
            $p = $js.PSObject.Properties[$k]
            if ($null -ne $p -and $null -ne $p.Value) {
                if ($Tax[$k] -is [decimal]) { $Tax[$k] = [decimal]$p.Value }
                elseif ($Tax[$k] -is [int]) { $Tax[$k] = [int]$p.Value }
                elseif ($Tax[$k] -is [bool]) { $Tax[$k] = [bool]$p.Value }
                else { $Tax[$k] = [string]$p.Value }
            }
        }
    }
} catch {}

# IRS Pub 15-T (2026), Percentage Method Tables for Automated Payroll Systems, ANNUAL, STANDARD schedules
# rows: at-least, base tax, rate
$FedTables = @{
    'HeadOfHousehold' = @(@(0,0,0), @(15550,0,0.10), @(33250,1770,0.12), @(83000,7740,0.22), @(121250,16155,0.24), @(217300,39207,0.32), @(271750,56631,0.35), @(656150,191171,0.37))
    'Single'          = @(@(0,0,0), @(7500,0,0.10), @(19900,1240,0.12), @(57900,5800,0.22), @(113200,17966,0.24), @(209275,41024,0.32), @(263725,58448,0.35), @(648100,192979.25,0.37))
    'MarriedJointly'  = @(@(0,0,0), @(19300,0,0.10), @(44100,2480,0.12), @(120100,11600,0.22), @(230700,35932,0.24), @(422850,82048,0.32), @(531750,116896,0.35), @(788000,206583.50,0.37))
}
# IRS Pub 15-T (2026) Percentage Method Tables for MANUAL Payroll Systems (W-4 2020+), BIWEEKLY payroll period
# (Worksheet 4). rows: at-least, tentative amount, rate, excess-over. Step 2 checkbox schedules included.
$FedBiweekly = @{
    'HeadOfHousehold' = @(@(0,0,0,0), @(929,0,0.10,929), @(1610,68.10,0.12,1610), @(3523,297.66,0.22,3523), @(4994,621.28,0.24,4994), @(8688,1507.84,0.32,8688), @(10783,2178.24,0.35,10783), @(25567,7352.64,0.37,25567))
    'Single'          = @(@(0,0,0,0), @(619,0,0.10,619), @(1096,47.70,0.12,1096), @(2558,223.14,0.22,2558), @(4685,691.08,0.24,4685), @(8380,1577.88,0.32,8380), @(10474,2247.96,0.35,10474), @(25258,7422.36,0.37,25258))
    'MarriedJointly'  = @(@(0,0,0,0), @(1238,0,0.10,1238), @(2192,95.40,0.12,2192), @(5115,446.16,0.22,5115), @(9369,1382.04,0.24,9369), @(16760,3155.88,0.32,16760), @(20948,4496.04,0.35,20948), @(30804,7945.64,0.37,30804))
}
$FedBiweeklyStep2 = @{
    'HeadOfHousehold' = @(@(0,0,0,0), @(464,0,0.10,464), @(805,34.10,0.12,805), @(1762,148.94,0.22,1762), @(2497,310.64,0.24,2497), @(4344,753.92,0.32,4344), @(5391,1088.96,0.35,5391), @(12784,3676.51,0.37,12784))
    'Single'          = @(@(0,0,0,0), @(310,0,0.10,310), @(548,23.80,0.12,548), @(1279,111.52,0.22,1279), @(2342,345.38,0.24,2342), @(4190,788.90,0.32,4190), @(5237,1123.94,0.35,5237), @(12629,3711.14,0.37,12629))
    'MarriedJointly'  = @(@(0,0,0,0), @(619,0,0.10,619), @(1096,47.70,0.12,1096), @(2558,223.14,0.22,2558), @(4685,691.08,0.24,4685), @(8380,1577.88,0.32,8380), @(10474,2247.96,0.35,10474), @(25258,7422.36,0.37,25258))
}
# Oklahoma OW-2 (2026) Table 2: BI-WEEKLY payroll period (wages after allowances); allowance $38.46 per biweekly period
$OkBiweekly = @{
    'Single'  = @(@(0,0,0), @(388,0,0.025), @(433,1.11,0.035), @(521,4.20,0.045))
    'Married' = @(@(0,0,0), @(777,0,0.025), @(865,2.21,0.035), @(1042,8.40,0.045))
}
$OkAllowanceBiweekly = [decimal]38.46
# Oklahoma OW-2 (2026) Table 1: WEEKLY payroll period, percentage formula (wages after allowances)
$OkWeekly = @{
    'Single'  = @(@(0,0,0), @(194,0,0.025), @(216,0.55,0.035), @(261,2.10,0.045))
    'Married' = @(@(0,0,0), @(388,0,0.025), @(433,1.11,0.035), @(521,4.20,0.045))
}
$OkAllowanceWeekly = [decimal]19.23

# ---------------------------------------------------------------- v1.11.0 PROFILE (same schema as the phone engine). profile.json next to the script.
# Everything the math needs comes from here; Van's copies are prefilled with his profile (from his real paystub).
$profilePath = Join-Path $dataDir 'profile.json'
$punchPath   = Join-Path $dataDir $(if ($TestMode) { 'punches-test.json' } else { 'punches.json' })   # v1.12.0 manual clock punches per date
$VanPresetJson = '{"name":"Van","rate":26.46,"days":[2,3,4,5,6],"start":"11:30","end":"20:30","breaks":[{"label":"Lunch","start":"15:00","end":"16:00","paid":false}],"diffs":[{"label":"Evening","amount":2,"after":"18:00"}],"wkndDiff":2,"wkndDays":[6,0],"freq":"biweekly","weekStart":6,"nextPayday":"2026-09-30","fs":"hoh","st":"ok","oka":1,"stPct":0,"pretax":[{"label":"401(k)","type":"pct","value":10,"fica":false}],"aftertax":[{"label":"Stock purchase","type":"amt","value":50}]}'
$BlankProfileJson = '{"name":"","rate":20,"days":[1,2,3,4,5],"start":"09:00","end":"17:30","breaks":[{"label":"Lunch","start":"12:00","end":"12:30","paid":false}],"diffs":[],"wkndDiff":0,"wkndDays":[6,0],"freq":"biweekly","weekStart":0,"nextPayday":"","breakPaid":true,"breakLen":15,"otOn":true,"otMult":1.5,"otAfter":40,"fs":"single","st":"none","oka":1,"stPct":0,"pretax":[],"aftertax":[]}'
$DowNames = @('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')
$DonateVenmo  = 'https://venmo.com/u/VanWidick'
$DonatePaypal = 'https://paypal.me/VanWidick/1'
$DonateCashtag = ''   # Cash App stays hidden until a cashtag is provided (never an email)
function ConvertTo-Min($s) {
    if ($null -eq $s) { return $null }
    if ([string]$s -match '^\s*(\d{1,2}):(\d\d)\s*([AaPp])?\.?[Mm]?\.?\s*$') {
        $h = [int]$matches[1]; $mm = [int]$matches[2]
        if ($matches[3]) { if ($h -lt 1 -or $h -gt 12) { return $null }; $h = $h % 12; if ($matches[3] -match '[Pp]') { $h += 12 } }
        if ($h -lt 24 -and $mm -lt 60) { return ($h * 60 + $mm) }
    }
    return $null
}
# v2.0.6 punch editor: forgiving typed times "4", "4pm", "4:00 PM", "1600", "430p"; no AM/PM -> the one nearer $refMin
function ConvertFrom-TypedTime($s, $refMin) {
    if ($null -eq $s) { return $null }; $raw = ([string]$s).Trim()
    if ($raw -notmatch '^(\d{1,2})(?:\s*[:.h]?\s*(\d{2}))?\s*(?:([AaPp])\.?\s*[Mm]?\.?)?$') { return $null }
    $h = [int]$matches[1]; $hs = [string]$matches[1]; $mm = $(if ($matches[2]) { [int]$matches[2] } else { 0 }); $ap = [string]$matches[3]
    if ($mm -gt 59) { return $null }
    if ($ap) { if ($h -lt 1 -or $h -gt 12) { return $null }; $h = $h % 12; if ($ap -match '[Pp]') { $h += 12 }; return ($h * 60 + $mm) }
    if ($null -ne $refMin -and $h -ge 1 -and $h -le 12 -and -not $hs.StartsWith('0') -and -not ($raw -match '^\d{4}$' -and $hs.Length -eq 2)) {
        $a = ($h % 12) * 60 + $mm; $b = $a + 720
        $da = [math]::Abs($a - $refMin) % 1440; $da = [math]::Min($da, 1440 - $da); $db = [math]::Abs($b - $refMin) % 1440; $db = [math]::Min($db, 1440 - $db)
        return $(if ($db -lt $da) { $b } else { $a }) }
    if ($h -lt 24) { return ($h * 60 + $mm) }; return $null
}
function Format-Clock([int]$min) { $h = [math]::Floor($min / 60) % 24; $m = $min % 60; $ap = $(if ($h -ge 12) { 'PM' } else { 'AM' }); $h = $h % 12; if ($h -eq 0) { $h = 12 }; return ('{0}:{1:00} {2}' -f $h, $m, $ap) }
function Format-HHmm([int]$min) { return ('{0:00}:{1:00}' -f [math]::Floor($min / 60), ($min % 60)) }
function Format-Dur([int]$m) { if ($m -ge 60) { return ('{0}h {1:00}m' -f [math]::Floor($m / 60), ($m % 60)) } return ([string]$m + 'm') }
function Format-Amt([decimal]$v) { return $v.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) }
function Read-ProfileFile {
    try { if (Test-Path -LiteralPath $profilePath) { $j = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json; if ($j -and $null -ne $j.rate) { return $j } } } catch {}
    return $null
}
function Set-Profile($p) {
    $script:Profile = $p
    $script:Rules = [pscustomobject]@{ BaseRate = [decimal]$p.rate; WeekendDiff = [decimal]$(if ($null -ne $p.wkndDiff -and "$($p.wkndDiff)" -ne '') { $p.wkndDiff } else { 0 })
                                       ShiftStartMin = [int](ConvertTo-Min $p.start); ShiftEndMin = [int](ConvertTo-Min $p.end); WeekStartDow = [int]$(if ($null -ne $p.weekStart) { $p.weekStart } else { 0 }) }
    $script:Breaks = @(@(foreach ($b in @($p.breaks)) { if ($null -eq $b) { continue }; $s = ConvertTo-Min $b.start; $e = ConvertTo-Min $b.end
        if ($null -ne $s -and $null -ne $e -and $e -gt $s) { [pscustomobject]@{ Label = $(if ($b.label) { [string]$b.label } else { 'Break' }); S = [int]$s; E = [int]$e; Paid = [bool]$b.paid } } }) | Sort-Object S)
    $script:Diffs = @(@(foreach ($d in @($p.diffs)) { if ($null -eq $d) { continue }; $a = ConvertTo-Min $d.after
        if ($null -ne $a -and [decimal]$d.amount -ne 0) { [pscustomobject]@{ Label = $(if ($d.label) { [string]$d.label } else { 'Differential' }); Amt = [decimal]$d.amount; After = [int]$a } } }) | Sort-Object After)
    $script:WorkDays = @(@($p.days) | Where-Object { $null -ne $_ } | ForEach-Object { $DowNames[[int]$_] })
    $script:WeekendDays = @(@($p.wkndDays) | Where-Object { $null -ne $_ } | ForEach-Object { $DowNames[[int]$_] })
    $script:PeriodDays = $(if ($p.freq -eq 'weekly') { 7 } else { 14 })
    $Tax.PayPeriodsPerYear = $(if ($p.freq -eq 'weekly') { 52 } else { 26 })
    $Tax.FedFilingStatus = $(switch ([string]$p.fs) { 'hoh' { 'HeadOfHousehold' } 'mfj' { 'MarriedJointly' } default { 'Single' } })
    $Tax.OkFilingStatus = $(if ($p.fs -eq 'mfj') { 'Married' } else { 'Single' })
    $Tax.OkAllowances = [int]$(if ($null -ne $p.oka -and "$($p.oka)" -ne '') { $p.oka } else { 0 })
    $script:StateMode = $(if ($p.st -eq 'ok' -or $p.st -eq 'flat') { [string]$p.st } else { 'none' })
    $script:StatePct = [decimal]$(if ($null -ne $p.stPct -and "$($p.stPct)" -ne '') { $p.stPct } else { 0 })
    $script:Pretax = @(foreach ($x in @($p.pretax)) { if ($null -ne $x -and [decimal]$x.value -gt 0) { [pscustomobject]@{ Label = $(if ($x.label) { [string]$x.label } else { 'Pre-tax' }); Type = $(if ($x.type -eq 'amt') { 'amt' } else { 'pct' }); Value = [decimal]$x.value; Fica = [bool]$x.fica } } })
    $script:Aftertax = @(foreach ($x in @($p.aftertax)) { if ($null -ne $x -and [decimal]$x.value -gt 0) { [pscustomobject]@{ Label = $(if ($x.label) { [string]$x.label } else { 'After-tax' }); Type = $(if ($x.type -eq 'pct') { 'pct' } else { 'amt' }); Value = [decimal]$x.value } } })
    # pay calendar: a period is PeriodDays long and starts on weekStart; a payday pays the period that ends on the last
    # week-end day before it (Van: Sat-Fri weeks, Wed payday 9/30 -> 9/12..9/25, 5-day lag)
    $pa = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$p.nextPayday, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$pa)) { $pa = [datetime]'2026-09-30' }
    $script:PaydayAnchor = $pa.Date
    $weekEnd = ([int]$p.weekStart + 6) % 7
    $pe = $script:PaydayAnchor.AddDays(-1); while ([int]$pe.DayOfWeek -ne $weekEnd) { $pe = $pe.AddDays(-1) }
    $script:PayLag = ($script:PaydayAnchor - $pe).Days
    $script:PeriodAnchor = $pe.AddDays(-($script:PeriodDays - 1))
    # per-minute masks (fast shift math): paid minute? + differential $/hr in effect at that minute
    $script:PaidMask = New-Object 'bool[]' 1440; $script:DiffAt = New-Object 'decimal[]' 1440; $n = 0
    for ($m = 0; $m -lt 1440; $m++) {
        $dsum = [decimal]0; foreach ($d in $script:Diffs) { if ($m -ge $d.After) { $dsum += $d.Amt } }; $script:DiffAt[$m] = $dsum
        if ($m -lt $script:Rules.ShiftStartMin -or $m -ge $script:Rules.ShiftEndMin) { continue }
        $unpaid = $false; foreach ($b in $script:Breaks) { if (-not $b.Paid -and $m -ge $b.S -and $m -lt $b.E) { $unpaid = $true; break } }
        if (-not $unpaid) { $script:PaidMask[$m] = $true; $n++ }
    }
    $script:PaidMinPerShift = $n
    # v1.12.0: per-weekday schedule (perDay), START/END BREAK paid setting, which break is lunch
    $script:PerDay = @{}
    if ($p.PSObject.Properties['perDay'] -and $p.perDay) { foreach ($pp in $p.perDay.PSObject.Properties) { $ps1 = ConvertTo-Min $pp.Value.start; $pe1 = ConvertTo-Min $pp.Value.end
        if ($null -ne $ps1 -and $null -ne $pe1 -and $pe1 -gt $ps1) { $script:PerDay[[int]$pp.Name] = @([int]$ps1, [int]$pe1) } } }
    $script:BreakPaid = $(if ($p.PSObject.Properties['breakPaid'] -and $null -ne $p.breakPaid) { [bool]$p.breakPaid } else { $true })
    $bl = 15; if ($p.PSObject.Properties['breakLen'] -and $null -ne $p.breakLen) { try { $bl = [int]$p.breakLen } catch { $bl = 15 } }; if ($bl -lt 1 -or $bl -gt 240) { $bl = 15 }
    $script:BreakLen = $bl   # v1.13.0: minutes per START BREAK (for BE BACK BY)
    # v1.14.0 overtime (FLSA default): paid hours over otAfter (40) in the workweek (starts on the pay-week start day) at otMult (1.5x) of base + differentials
    $oOn = $true; if ($p.PSObject.Properties['otOn'] -and $null -ne $p.otOn) { $oOn = [bool]$p.otOn }
    $oMul = 1.5; if ($p.PSObject.Properties['otMult'] -and $p.otMult) { try { $oMul = [double]$p.otMult } catch {} }; if ($oMul -lt 1 -or $oMul -gt 4) { $oMul = 1.5 }
    $oAft = 40; if ($p.PSObject.Properties['otAfter'] -and $p.otAfter) { try { $oAft = [double]$p.otAfter } catch {} }; if ($oAft -le 0 -or $oAft -gt 168) { $oAft = 40 }
    $script:OT = @{ On = $oOn; Mult = [decimal]$oMul; AfterMin = [int][math]::Round($oAft * 60) }
    $script:LunchBreak = @($script:Breaks | Where-Object { $_.Label -match 'lunch' }) | Select-Object -First 1
    if (-not $script:LunchBreak) { $script:LunchBreak = @($script:Breaks | Where-Object { -not $_.Paid }) | Select-Object -First 1 }
    $script:ShiftCache = @{}; $script:StraightCache = @{}
}
function Get-ProfileJson($p) { return ($p | ConvertTo-Json -Depth 6) }
# ---------------------------------------------------------------- v1.12.0 manual clock punches: per date [[kind, secOfDay], ...]; kinds in|lo|li|out|bs|be
$script:Punches = @{}
function Read-Punches {
    $script:Punches = @{}
    try { if (Test-Path -LiteralPath $punchPath) { $j = Get-Content -LiteralPath $punchPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($pr in $j.PSObject.Properties) { $l = New-Object System.Collections.ArrayList; foreach ($e in @($pr.Value)) { [void]$l.Add(@([string]$e[0], [int]$e[1])) }; if ($l.Count) { $script:Punches[$pr.Name] = $l } } } } catch {}
}
function Save-Punches {
    $parts = @(foreach ($k in @($script:Punches.Keys | Sort-Object)) { $l = $script:Punches[$k]; if (-not $l -or $l.Count -eq 0) { continue }
        '"' + $k + '":[' + ((@($l) | ForEach-Object { '["' + $_[0] + '",' + [int]$_[1] + ']' }) -join ',') + ']' })
    try { [IO.File]::WriteAllText($punchPath, ('{' + ($parts -join ',') + '}'), (New-Object Text.UTF8Encoding $false)) } catch {}
    $script:ShiftCache = @{}; $script:StraightCache = @{}
}
# v2.0.11 PTO: hours missed, paid at base rate (no differentials). pto.json = {"2026-10-08":[[690,960]]} (minutes of day)
$script:Pto = @{}
$ptoPath = Join-Path $dataDir $(if ($TestMode) { 'pto-test.json' } else { 'pto.json' })
function Read-Pto { $script:Pto = @{}; try { if (Test-Path -LiteralPath $ptoPath) { $j = Get-Content -LiteralPath $ptoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($pr in $j.PSObject.Properties) { $l = New-Object System.Collections.ArrayList; foreach ($e in @($pr.Value)) { if ([int]$e[1] -gt [int]$e[0]) { [void]$l.Add(@([int]$e[0], [int]$e[1])) } }; if ($l.Count) { $script:Pto[$pr.Name] = $l } } } } catch {} }
function Save-Pto {
    $parts = @(foreach ($k in @($script:Pto.Keys | Sort-Object)) { $l = $script:Pto[$k]; if (-not $l -or $l.Count -eq 0) { continue }; '"' + $k + '":[' + ((@($l) | ForEach-Object { '[' + [int]$_[0] + ',' + [int]$_[1] + ']' }) -join ',') + ']' })
    if (-not $SelfTest) { try { [IO.File]::WriteAllText($ptoPath, ('{' + ($parts -join ',') + '}'), (New-Object Text.UTF8Encoding $false)) } catch {} }
    $script:ShiftCache = @{}; $script:StraightCache = @{}
}
function Get-PtoMin([string]$iso, [int]$upTo = 1440) { $n = 0; if ($script:Pto.ContainsKey($iso)) { foreach ($x in $script:Pto[$iso]) { $n += [math]::Max(0, [math]::Min([int]$x[1], $upTo) - [int]$x[0]) } }; return $n }
function Get-PunchRec([string]$iso) {
    $log = $script:Punches[$iso]; if (-not $log -or $log.Count -eq 0) { return $null }
    # v1.14.1: read the log in order. CLOCK IN never moves the start once the day is under way: after CLOCK OUT it resumes
    # (the gap is unpaid), during an open lunch it = BACK FROM LUNCH, during an open break it = END BREAK, otherwise it is ignored.
    # A forgotten END BREAK closes itself at the next lunch / break / clock punch. A second lunch keeps the first one.
    $r = [pscustomobject]@{ In = $null; Lo = $null; Li = $null; Out = $null; InS = $null; LoS = $null; LiS = $null; OutS = $null; Br = (New-Object System.Collections.ArrayList); Gaps = (New-Object System.Collections.ArrayList); LiAuto = $false }
    $started = $false
    foreach ($e in $log) { $k = [string]$e[0]; $t = [int]$e[1]; $mm = [int][math]::Floor($t / 60)
        $ob = $null; if ($r.Br.Count -and $null -eq $r.Br[$r.Br.Count - 1][1]) { $ob = $r.Br[$r.Br.Count - 1] }   # (direct ref - $() would copy the array)
        $lOpen = ($null -ne $r.Lo -and $null -eq $r.Li)
        if ($k -eq 'in') {
            if (-not $started) { $r.In = $mm; $r.InS = $t }
            elseif ($null -ne $r.Out) { [void]$r.Gaps.Add(@([int]$r.Out, [math]::Max($mm, [int]$r.Out), $r.OutS, $t, 'off')); $r.Out = $null; $r.OutS = $null }
            elseif ($lOpen) { $r.Li = [math]::Max($mm, [int]$r.Lo); $r.LiS = $t }
            elseif ($ob) { $ob[1] = [math]::Max($mm, [int]$ob[0]); $ob[3] = $t; $ob[4] = $true }
            continue }
        $started = $true
        switch ($k) {
            'bs'  { if ($ob) { $ob[1] = [math]::Max($mm, [int]$ob[0]); $ob[3] = $t; $ob[4] = $true }; [void]$r.Br.Add(@($mm, $null, $t, $null, $false)) }
            'be'  { if ($ob) { $ob[1] = [math]::Max($mm, [int]$ob[0]); $ob[3] = $t; $ob[4] = $false } }
            'lo'  { if ($ob) { $ob[1] = [math]::Max($mm, [int]$ob[0]); $ob[3] = $t; $ob[4] = $true }
                    if ($null -ne $r.Lo -and $null -ne $r.Li) { [void]$r.Gaps.Add(@([int]$r.Lo, [int]$r.Li, $r.LoS, $r.LiS, 'lunch')) }
                    $r.Lo = $mm; $r.LoS = $t; $r.Li = $null; $r.LiS = $null }
            'li'  { if ($lOpen) { $r.Li = [math]::Max($mm, [int]$r.Lo); $r.LiS = $t }
                    elseif ($null -ne $r.Out) { [void]$r.Gaps.Add(@([int]$r.Out, [math]::Max($mm, [int]$r.Out), $r.OutS, $t, 'off')); $r.Out = $null; $r.OutS = $null }
                    elseif ($null -ne $r.Lo) { $r.Li = [math]::Max($mm, [int]$r.Lo); $r.LiS = $t } }
            'out' { if ($ob) { $ob[1] = [math]::Max($mm, [int]$ob[0]); $ob[3] = $t; $ob[4] = $true }
                    if ($lOpen) { $r.Li = [math]::Max($mm, [int]$r.Lo); $r.LiS = $t; $r.LiAuto = $true }
                    $r.Out = $mm; $r.OutS = $t }
        } }
    return $r
}
$script:ProfileFromFile = Read-ProfileFile
$script:NeedSetup = ($null -eq $script:ProfileFromFile)
if ($SelfTest) { Set-Profile ($VanPresetJson | ConvertFrom-Json) }
elseif ($InstallerPreview) { Set-Profile ($BlankProfileJson | ConvertFrom-Json); $script:NeedSetup = $true }
elseif ($script:ProfileFromFile) { try { Set-Profile $script:ProfileFromFile } catch { Set-Profile ($BlankProfileJson | ConvertFrom-Json); $script:NeedSetup = $true } }
else { Set-Profile ($BlankProfileJson | ConvertFrom-Json); $script:NeedSetup = $true }   # v2.0.13: shared/installer copies start blank (Van's copies always have profile.json)
if (-not $SelfTest) { Read-Punches; Read-Pto }

# ---------------------------------------------------------------- time
$script:SimOffset = $null
function Get-CentralNow {
    try { return [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::UtcNow, 'Central Standard Time') }
    catch { return [datetime]::Now }
}
if ($SimulateNow) {
    $sim = [datetime]::ParseExact($SimulateNow, [string[]]@('yyyy-MM-dd HH:mm', 'yyyy-MM-dd HH:mm:ss'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
    $script:SimOffset = $sim - (Get-CentralNow)
}
function Get-Now {
    $n = Get-CentralNow
    if ($null -ne $script:SimOffset) { $n = $n + $script:SimOffset }
    return $n
}

# ---------------------------------------------------------------- math
function Test-WorkDay([datetime]$d) { return $WorkDays -contains $d.DayOfWeek.ToString() }
function Round2([decimal]$v) { return [math]::Round($v, 2, [MidpointRounding]::AwayFromZero) }

# v1.12.0 effective day: weekly schedule (perDay) overridden by today's punches. $live: an open lunch/break runs until "now".
$OpenEnd = 100000
function Get-DaySpec([datetime]$day, [bool]$live) {
    $iso = $day.ToString('yyyy-MM-dd'); $pr = Get-PunchRec $iso; $dow = [int]$day.DayOfWeek
    $pd = $script:PerDay[$dow]
    $s0 = $(if ($pd) { $pd[0] } else { $Rules.ShiftStartMin }); $e0 = $(if ($pd) { $pd[1] } else { $Rules.ShiftEndMin })
    $hasIn = ($null -ne $pr -and $null -ne $pr.In); $hasOut = ($null -ne $pr -and $null -ne $pr.Out)
    $work = (Test-WorkDay $day) -or $hasIn
    $s = $(if ($hasIn) { [int]$pr.In } else { $s0 }); $e = $(if ($hasOut) { [math]::Max([int]$pr.Out, $s) } else { $e0 })
    $brs = New-Object System.Collections.ArrayList
    foreach ($b in $script:Breaks) {
        $isL = ($null -ne $script:LunchBreak -and $b -eq $script:LunchBreak)
        if ($isL -and $null -ne $pr -and $null -ne $pr.Lo) { continue }
        if (-not $isL -and $null -ne $pr -and $pr.Br.Count) { continue }
        [void]$brs.Add([pscustomobject]@{ Kind = $(if ($isL) { 'lunch' } else { 'break' }); Label = $b.Label; S = $b.S; E = $b.E; Paid = $b.Paid; Actual = $false; Open = $false; SS = $null; ES = $null })
    }
    if ($null -ne $pr -and $null -ne $pr.Lo) {
        $open = ($null -eq $pr.Li); $plen = $(if ($script:LunchBreak) { $script:LunchBreak.E - $script:LunchBreak.S } else { 60 })
        $le = $(if ($open) { $(if ($live) { $OpenEnd } else { [int]$pr.Lo + $plen }) } else { [math]::Max([int]$pr.Li, [int]$pr.Lo) })
        [void]$brs.Add([pscustomobject]@{ Kind = 'lunch'; Label = $(if ($script:LunchBreak) { $script:LunchBreak.Label } else { 'Lunch' }); S = [int]$pr.Lo; E = $le; Paid = $(if ($script:LunchBreak) { $script:LunchBreak.Paid } else { $false }); Actual = $true; Open = $open; SS = $pr.LoS; ES = $pr.LiS })
    }
    if ($null -ne $pr) { foreach ($g in $pr.Gaps) { $lun = ($g[4] -eq 'lunch')   # v1.14.1: earlier lunch / time clocked out between segments
        [void]$brs.Add([pscustomobject]@{ Kind = 'off'; Label = $(if ($lun) { $(if ($script:LunchBreak) { $script:LunchBreak.Label } else { 'Lunch' }) } else { 'Off the clock' }); S = [int]$g[0]; E = [int]$g[1]
            Paid = $(if ($lun -and $script:LunchBreak) { [bool]$script:LunchBreak.Paid } else { $false }); Actual = $true; Open = $false; SS = $g[2]; ES = $g[3] }) } }
    if ($null -ne $pr) { foreach ($x in $pr.Br) { $open = ($null -eq $x[1])
        [void]$brs.Add([pscustomobject]@{ Kind = 'break'; Label = 'Break'; S = [int]$x[0]; E = $(if ($open) { $(if ($live) { $OpenEnd } else { [int]$x[0] }) } else { [int]$x[1] }); Paid = $script:BreakPaid; Actual = $true; Open = $open; SS = $x[2]; ES = $x[3] }) } }
    $brs = @($brs | Where-Object { -not ($_.Actual -and -not $_.Open -and $_.E -eq $_.S) } | Sort-Object S)   # v1.14.2: zero-length = deleted marker / sub-minute
    return [pscustomobject]@{ Iso = $iso; Work = $work; S = $s; E = $e; S0 = $s0; E0 = $e0; Brs = $brs; Pr = $pr; SIn = $hasIn; SOut = $hasOut }
}

# ---- v1.14.2 punch editor: day model (seconds of day) <-> canonical punch log (same rules as the phone engine)
function Get-DayModel([string]$iso) {
    $d = [datetime]::ParseExact($iso, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture); $sp = Get-DaySpec $d $false; $r = Get-PunchRec $iso
    $m = @{ In = @{ T = $(if ($r -and $null -ne $r.InS) { [int]$r.InS } else { $sp.S0 * 60 }); Auto = -not ($r -and $null -ne $r.InS) }
            Out = @{ T = $(if ($r -and $null -ne $r.OutS) { [int]$r.OutS } else { $sp.E0 * 60 }); Auto = -not ($r -and $null -ne $r.OutS) }
            Segs = (New-Object System.Collections.ArrayList); NoLunch = $false; NoBreaks = $false }
    foreach ($b in $sp.Brs) { if (-not $b.Actual) { [void]$m.Segs.Add(@{ Kind = $(if ($b.Kind -eq 'lunch') { 'lunch' } else { 'break' }); S = $b.S * 60; E = $b.E * 60; Auto = $true; AutoClosed = $false; Open = $false }) } }
    $all = New-Object System.Collections.ArrayList
    if ($r) {
        foreach ($g in $r.Gaps) { [void]$all.Add(@{ Kind = $(if ($g[4] -eq 'lunch') { 'lunch' } else { 'off' }); S = [int]$g[2]; E = [int]$g[3]; Auto = $false; AutoClosed = $false; Open = $false }) }
        if ($null -ne $r.LoS) { [void]$all.Add(@{ Kind = 'lunch'; S = [int]$r.LoS; E = $(if ($null -ne $r.LiS) { [int]$r.LiS } else { $null }); Auto = $false; AutoClosed = [bool]$r.LiAuto; Open = ($null -eq $r.LiS) }) }
        foreach ($x in $r.Br) { [void]$all.Add(@{ Kind = 'break'; S = [int]$x[2]; E = $(if ($null -ne $x[3]) { [int]$x[3] } else { $null }); Auto = $false; AutoClosed = [bool]$x[4]; Open = ($null -eq $x[3]) }) }
    }
    $zero = { param($x) $null -ne $x.E -and $x.E -eq $x.S }
    $m.NoLunch = (@($all | Where-Object { $_.Kind -eq 'lunch' -and (& $zero $_) }).Count -gt 0) -and (@($all | Where-Object { $_.Kind -eq 'lunch' -and -not (& $zero $_) }).Count -eq 0)
    $m.NoBreaks = (@($all | Where-Object { $_.Kind -eq 'break' -and (& $zero $_) }).Count -gt 0) -and (@($all | Where-Object { $_.Kind -eq 'break' -and -not (& $zero $_) }).Count -eq 0)
    foreach ($x in $all) { if (-not (& $zero $x)) { [void]$m.Segs.Add($x) } }
    $sorted = @($m.Segs | Sort-Object { $_.S }); $m.Segs = New-Object System.Collections.ArrayList; foreach ($x in $sorted) { [void]$m.Segs.Add($x) }
    return $m
}
function Format-ClockS([int]$t) { return Format-Clock ([int][math]::Floor($t / 60)) }
function Test-DayModel($m, [bool]$allowOpen = $false) {
    $ok = { param($t) $null -ne $t -and $t -ge 0 -and $t -lt 86400 }
    $nm = { param($x) switch ($x.Kind) { 'off' { 'Off-the-clock time' } 'lunch' { 'Lunch' } default { 'Break' } } }
    if (-not (& $ok $m.In.T) -or -not (& $ok $m.Out.T)) { return 'Clock in and clock out need a time.' }
    if ($m.Out.T -le $m.In.T) { return 'Clock out must be after clock in.' }
    $segs = @($m.Segs | Sort-Object { $_.S })
    for ($i = 0; $i -lt $segs.Count; $i++) { $x = $segs[$i]
        if (-not (& $ok $x.S)) { return ((& $nm $x) + ' needs a start time.') }
        if ($null -eq $x.E) { if (-not ($allowOpen -and $i -eq $segs.Count - 1 -and $m.Out.Auto)) { return ((& $nm $x) + ' at ' + (Format-ClockS $x.S) + ' needs an end time.') } }
        elseif ($x.E -le $x.S) { return ((& $nm $x) + ' must end after it starts (' + (Format-ClockS $x.S) + ').') }
        if ($x.S -lt $m.In.T) { return ((& $nm $x) + ' at ' + (Format-ClockS $x.S) + ' starts before clock in (' + (Format-ClockS $m.In.T) + ').') }
        if ($null -ne $x.E -and $x.E -gt $m.Out.T) { return ((& $nm $x) + ' ends after clock out (' + (Format-ClockS $m.Out.T) + ').') }
        if ($i -gt 0 -and $null -ne $segs[$i - 1].E -and $x.S -lt $segs[$i - 1].E) { return ((& $nm $x) + ' at ' + (Format-ClockS $x.S) + ' overlaps the ' + (& $nm $segs[$i - 1]).ToLower() + ' before it.') }
    }
    return $null
}
function Build-PunchLog($m) {
    $ev = New-Object System.Collections.ArrayList
    if (-not $m.In.Auto) { [void]$ev.Add(@('in', [int]$m.In.T, 0.0)) }
    foreach ($x in $m.Segs) { $k = switch ($x.Kind) { 'lunch' { @('lo', 'li') } 'break' { @('bs', 'be') } default { @('out', 'in') } }
        [void]$ev.Add(@($k[0], [int]$x.S, 2.0)); if ($null -ne $x.E) { [void]$ev.Add(@($k[1], [int]$x.E, 1.0)) } }
    if (-not $m.Out.Auto) { [void]$ev.Add(@('out', [int]$m.Out.T, 3.0)) }
    $t0 = [int]$m.In.T
    if (@($m.Segs | Where-Object { $_.Kind -eq 'lunch' }).Count -eq 0 -and ($m.NoLunch -or $null -ne $script:LunchBreak)) { [void]$ev.Add(@('lo', $t0, 0.5)); [void]$ev.Add(@('li', $t0, 0.6)) }
    if (@($m.Segs | Where-Object { $_.Kind -eq 'break' }).Count -eq 0 -and ($m.NoBreaks -or @($script:Breaks | Where-Object { $_ -ne $script:LunchBreak }).Count -gt 0)) { [void]$ev.Add(@('bs', $t0, 0.7)); [void]$ev.Add(@('be', $t0, 0.8)) }
    $sorted = @($ev | Sort-Object @{ Expression = { $_[1] } }, @{ Expression = { $_[2] } })
    $out = New-Object System.Collections.ArrayList; foreach ($e in $sorted) { [void]$out.Add(@([string]$e[0], [int]$e[1])) }
    return ,$out
}
function Save-DayModel([string]$iso, $m, [bool]$allowOpen) {
    $err = Test-DayModel $m $allowOpen; if ($err) { return $err }
    $log = Build-PunchLog $m
    if ($log.Count) { $script:Punches[$iso] = $log } elseif ($script:Punches.ContainsKey($iso)) { $script:Punches.Remove($iso) }
    if ($SelfTest) { $script:ShiftCache = @{}; $script:StraightCache = @{} } else { Save-Punches }   # self-test never writes the real punch file
    return $null
}

# Gross earnings for the shift on $day counting only minutes strictly before $upToMin (minutes since midnight).
# Profile-driven: unpaid breaks skipped, paid breaks count, every differential adds $/hr from its start time, weekend diff stacks.
# v1.12.0: uses the effective day (per-weekday schedule + manual punches).
# v1.14.0 straight paid minutes of a whole day (for the weekly overtime threshold); days before the TEST reset count 0
$script:StraightCache = @{}; $script:OTZeroBefore = $null
function Get-StraightPaid([datetime]$day) {
    if ($null -ne $script:OTZeroBefore -and $day.Date -lt ([datetime]$script:OTZeroBefore).Date) { return 0 }
    $key = $day.ToString('yyyyMMdd'); if ($script:StraightCache.ContainsKey($key)) { return $script:StraightCache[$key] }
    $sp = Get-DaySpec $day $false; $n = 0
    if ($sp.Work) { $um = New-Object 'bool[]' 1440
        foreach ($b in $sp.Brs) { if ($b.Paid) { continue }; $a = [math]::Max($b.S, 0); $z = [math]::Min($b.E, 1440); for ($m = $a; $m -lt $z; $m++) { $um[$m] = $true } }
        $end = [math]::Min($sp.E, 1440); for ($m = [math]::Max($sp.S, 0); $m -lt $end; $m++) { if (-not $um[$m]) { $n++ } } }
    $script:StraightCache[$key] = $n; return $n
}
function Get-OTWeekStart([datetime]$day) { $d = $day.Date; while ([int]$d.DayOfWeek -ne $Rules.WeekStartDow) { $d = $d.AddDays(-1) }; return $d }
function Get-ShiftCalc([datetime]$day, [int]$upToMin, [bool]$live = $false) {
    $full = ($upToMin -ge 1440 -and -not $live); $key = $day.ToString('yyyyMMdd')
    if ($full -and $script:ShiftCache.ContainsKey($key)) { return $script:ShiftCache[$key] }
    $sp = Get-DaySpec $day $live
    $paid = 0; $eve = 0; $rateSum = [decimal]0; $otMin = 0; $otSum = [decimal]0; $wkSum = [decimal]0; $regMin = 0
    $isWork = $sp.Work
    $isWknd = $WeekendDays -contains $day.DayOfWeek.ToString()
    # paid minutes already worked earlier in this workweek (OT kicks in once the week passes the threshold)
    $prior = 0
    if ($script:OT.On -and $isWork) { $ws = Get-OTWeekStart $day; for ($d = $ws; $d -lt $day.Date; $d = $d.AddDays(1)) { $prior += Get-StraightPaid $d } }
    if ($isWork) {
        $um = New-Object 'bool[]' 1440
        foreach ($b in $sp.Brs) { if ($b.Paid) { continue }; $a = [math]::Max($b.S, 0); $z = [math]::Min($b.E, 1440); for ($m = $a; $m -lt $z; $m++) { $um[$m] = $true } }
        $wk = $(if ($isWknd) { $Rules.WeekendDiff } else { [decimal]0 })
        $base = $Rules.BaseRate + $wk
        $end = [math]::Min([math]::Min($sp.E, $upToMin), 1440)
        for ($m = [math]::Max($sp.S, 0); $m -lt $end; $m++) {
            if ($um[$m]) { continue }
            $rate = $base + $script:DiffAt[$m]
            if ($script:OT.On -and ($prior + $paid) -ge $script:OT.AfterMin) { $otMin++; $otSum += $rate * $script:OT.Mult }
            else { $regMin++; $rateSum += $rate; $wkSum += $wk; if ($script:DiffAt[$m] -ne 0) { $eve++ } }
            $paid++
        }
    }
    $total = Round2 (($rateSum + $otSum) / 60)
    $reg = Round2 ($Rules.BaseRate * $regMin / 60); $otAmt = Round2 ($otSum / 60)
    $diff = $total - $reg - $otAmt; $dWk = [math]::Min($diff, (Round2 ($wkSum / 60))); $dEve = $diff - $dWk
    $ptoMin = Get-PtoMin $day.ToString('yyyy-MM-dd') $upToMin; $ptoAmt = Round2 ($Rules.BaseRate * $ptoMin / 60); $total = $total + $ptoAmt   # v2.0.11 PTO at base rate
    $r = [pscustomobject]@{
        Date = $day.Date; IsWorkDay = $isWork; IsWeekend = $isWknd
        PaidMin = $paid; EveningMin = $eve; WeekendMin = $(if ($isWknd -and $Rules.WeekendDiff -ne 0) { $regMin } else { 0 })
        Base = $reg; Diff = $diff; Total = $total; Spec = $sp
        Reg = $reg; DiffEve = $dEve; DiffWknd = $dWk; OT = $otAmt; OTMin = $otMin; RegMin = $regMin; PriorMin = $prior; PtoMin = $ptoMin; Pto = $ptoAmt
    }
    if ($full) { $script:ShiftCache[$key] = $r }
    return $r
}
function Get-FullShift([datetime]$day) { return Get-ShiftCalc $day (24 * 60) }
function Get-ZeroShift([datetime]$day) { $c = Get-ShiftCalc $day 0; return $c }
function Get-DedAmt($x, [decimal]$gross) {
    if ($gross -le 0) { return [decimal]0 }
    if ($x.Type -eq 'pct') { return (Round2 ($gross * $x.Value / 100)) }
    return [decimal][math]::Min($gross, $x.Value)
}

# Withholding for ONE paycheck of $gross. BIWEEKLY (26/yr): Pub 15-T 2026 Worksheet 4 with the manual BIWEEKLY
# percentage tables + OW-2 Table 2. WEEKLY: Worksheet 1A (annual) + OW-2 weekly. Pre-tax deductions reduce FIT/state
# wages (and FICA wages only when flagged); after-tax deductions just come off the net.
function Get-CheckWithholding([decimal]$gross) {
    $n = [decimal]$Tax.PayPeriodsPerYear
    $pre = @(foreach ($x in $script:Pretax) { [pscustomobject]@{ Label = $x.Label; Type = $x.Type; Value = $x.Value; Fica = $x.Fica; Amt = (Get-DedAmt $x $gross) } })
    $preT = [decimal]0; $preF = [decimal]0; foreach ($x in $pre) { $preT += $x.Amt; if ($x.Fica) { $preF += $x.Amt } }
    $k401 = $preT
    $fitWages = $gross - $preT; if ($fitWages -lt 0) { $fitWages = [decimal]0 }
    if ($n -eq 26) {
        $aaw = $fitWages + ($Tax.FedStep4aOther / $n) - ($Tax.FedStep4bDeduct / $n); if ($aaw -lt 0) { $aaw = [decimal]0 }
        $tbl = $(if ($Tax.FedStep2Checked) { $FedBiweeklyStep2[$Tax.FedFilingStatus] } else { $FedBiweekly[$Tax.FedFilingStatus] }); $row = $tbl[0]
        foreach ($r in $tbl) { if ($aaw -ge [decimal]$r[0]) { $row = $r } }
        $tent = [decimal]$row[1] + ([decimal]$row[2]) * ($aaw - [decimal]$row[3])
        $fed = Round2 $tent
        $fed = $fed - (Round2 ($Tax.FedStep3Credits / $n)); if ($fed -lt 0) { $fed = [decimal]0 }
        $fed = Round2 ($fed + $Tax.FedStep4cExtra)
        $okAllow = $OkAllowanceBiweekly; $okTbls = $OkBiweekly
    } else {
        $annual = $fitWages * $n + $Tax.FedStep4aOther
        $adj = [decimal]0
        if (-not $Tax.FedStep2Checked) { $adj = $(if ($Tax.FedFilingStatus -eq 'MarriedJointly') { [decimal]12900 } else { [decimal]8600 }) }
        $aaw = $annual - ($Tax.FedStep4bDeduct + $adj); if ($aaw -lt 0) { $aaw = [decimal]0 }
        $tbl = $FedTables[$Tax.FedFilingStatus]; $row = $tbl[0]
        foreach ($r in $tbl) { if ($aaw -ge [decimal]$r[0]) { $row = $r } }
        $annualTax = [decimal]$row[1] + ([decimal]$row[2]) * ($aaw - [decimal]$row[0])
        $fed = $annualTax / $n - ($Tax.FedStep3Credits / $n); if ($fed -lt 0) { $fed = [decimal]0 }
        $fed = Round2 ($fed + $Tax.FedStep4cExtra)
        $okAllow = $OkAllowanceWeekly; $okTbls = $OkWeekly
    }
    $ficaWages = $gross - $preF; if ($ficaWages -lt 0) { $ficaWages = [decimal]0 }
    $ss  = Round2 ($ficaWages * $Tax.SocialSecurityPct / 100)
    $med = Round2 ($ficaWages * $Tax.MedicarePct / 100)
    $okWages = [decimal]0; $okRaw = [decimal]0; $ok = [decimal]0
    if ($script:StateMode -eq 'ok') {
        $okWages = $fitWages - ($okAllow * $Tax.OkAllowances); if ($okWages -lt 0) { $okWages = [decimal]0 }
        $ot = $okTbls[$(if ($Tax.OkFilingStatus -eq 'Married') { 'Married' } else { 'Single' })]; $orow = $ot[0]
        foreach ($r in $ot) { if ($okWages -gt [decimal]$r[0]) { $orow = $r } }
        $okRaw = [decimal]$orow[1] + ([decimal]$orow[2]) * ($okWages - [decimal]$orow[0])
        $ok = [decimal]([math]::Round($okRaw, 0, [MidpointRounding]::AwayFromZero)) + $Tax.OkExtraPerCheck
    } elseif ($script:StateMode -eq 'flat') { $ok = Round2 ($fitWages * $script:StatePct / 100) }
    $aft = @(foreach ($x in $script:Aftertax) { [pscustomobject]@{ Label = $x.Label; Type = $x.Type; Value = $x.Value; Amt = (Get-DedAmt $x $gross) } })
    $stock = [decimal]0; foreach ($x in $aft) { $stock += $x.Amt }
    $net = $gross - $k401 - $fed - $ss - $med - $ok - $stock
    if ($net -lt 0) { $stock = $stock + $net; $net = [decimal]0 }
    return [pscustomobject]@{ Gross = $gross; K401 = $k401; Fed = $fed; SS = $ss; Med = $med; OK = [decimal]$ok; Stock = $stock; Net = $net; Pre = $pre; Aft = $aft
                              FitWages = $fitWages; AnnualAdjWage = $aaw; OkWages = $okWages; OkRaw = $okRaw }
}

# Spread a check's deductions proportionally onto a partial gross amount.
function Split-ByCheck([decimal]$gross, $check) {
    if ($check.Gross -le 0 -or $gross -le 0) {
        return [pscustomobject]@{ Gross = $gross; K401 = [decimal]0; Fed = [decimal]0; SS = [decimal]0; Med = [decimal]0; OK = [decimal]0; Stock = [decimal]0; Net = $gross }
    }
    $f = { param($x) Round2 ($gross * $x / $check.Gross) }
    $net = & $f $check.Net
    $k = & $f $check.K401; $ss = & $f $check.SS; $med = & $f $check.Med; $ok = & $f $check.OK; $stk = & $f $check.Stock
    $fed = $gross - $net - $k - $ss - $med - $ok - $stk     # federal absorbs the rounding penny
    return [pscustomobject]@{ Gross = $gross; K401 = $k; Fed = $fed; SS = $ss; Med = $med; OK = $ok; Stock = $stk; Net = $net }
}

function Get-PrevWorkDay([datetime]$d) {
    $p = $d.Date.AddDays(-1); $i = 0
    while (-not (Test-WorkDay $p) -and $i -lt 8) { $p = $p.AddDays(-1); $i++ }
    return $p
}
function Get-NextWorkDay([datetime]$d) {
    $p = $d.Date.AddDays(1); $i = 0
    while (-not (Test-WorkDay $p) -and $i -lt 8) { $p = $p.AddDays(1); $i++ }
    return $p
}
function Get-NextPayday([datetime]$d) {
    $diff = ($d.Date - $PaydayAnchor).Days
    $mod = (($diff % $PeriodDays) + $PeriodDays) % $PeriodDays
    if ($mod -eq 0) { return $d.Date }
    return $d.Date.AddDays($PeriodDays - $mod)
}
# First day of the pay period containing $d (Van: Sat-Fri x2; 9/12-9/25 -> paid 9/30, 9/26-10/9 -> paid 10/14, ...)
function Get-PayPeriodStart([datetime]$d) {
    $diff = ($d.Date - $PeriodAnchor).Days
    $mod = (($diff % $PeriodDays) + $PeriodDays) % $PeriodDays
    return $d.Date.AddDays(-$mod)
}
# TEST mode: days before the simulated start day ($zeroBefore) count as $0; everything after follows the schedule.
function Get-EffShift([datetime]$d, $zeroBefore) {
    if ($null -ne $zeroBefore -and $d.Date -lt ([datetime]$zeroBefore).Date) { return Get-ZeroShift $d }
    return Get-FullShift $d
}
function Get-EffPeriodGross([datetime]$start, $zeroBefore) {
    $g = [decimal]0
    for ($i = 0; $i -lt $PeriodDays; $i++) { $g += (Get-EffShift $start.AddDays($i) $zeroBefore).Total }
    return $g
}
function Get-ScheduledPeriodGross([datetime]$start) {
    $g = [decimal]0
    for ($i = 0; $i -lt $PeriodDays; $i++) { $g += (Get-FullShift $start.AddDays($i)).Total }
    return $g
}
function Get-ScheduledWeekGross([datetime]$weekStart) {
    $g = [decimal]0
    for ($i = 0; $i -lt 7; $i++) { $g += (Get-FullShift $weekStart.AddDays($i)).Total }
    return $g
}
function Get-RateAt([datetime]$day, [int]$m) {
    $r = $Rules.BaseRate
    if ($WeekendDays -contains $day.DayOfWeek.ToString()) { $r += $Rules.WeekendDiff }
    if ($m -ge 0 -and $m -lt 1440) { $r += $script:DiffAt[$m] }
    return $r
}

# TODAY'S SCHEDULE timeline: clock in, breaks/lunch, differential starts, clock out; current segment + next event.
# v1.12.0: built from the effective day (actual punches marked with a check; lunch/break durations; an open one shows a live stopwatch).
function Format-MMSS([int]$sec) { if ($sec -lt 0) { $sec = 0 }; $h = [math]::Floor($sec / 3600); $m = [math]::Floor(($sec % 3600) / 60); $x = $sec % 60
    if ($h -gt 0) { return ('{0}:{1:00}:{2:00}' -f $h, $m, $x) } return ('{0:00}:{1:00}' -f $m, $x) }
function Get-Schedule([datetime]$day, [int]$m, [int]$nowSec = -1) {
    if ($nowSec -lt 0) { $nowSec = $m * 60 }
    $sp = Get-DaySpec $day $true
    $ck = [string][char]0x2713
    $ev = New-Object System.Collections.ArrayList
    [void]$ev.Add([pscustomobject]@{ T = $sp.S; Kind = 'in'; Label = 'Clock in'; End = 0; B = $null; Actual = $sp.SIn })
    foreach ($b in $sp.Brs) {
        [void]$ev.Add([pscustomobject]@{ T = $b.S; Kind = 'bs'; Label = $b.Label; End = $b.E; B = $b; Actual = $b.Actual })
        if ($b.E -lt $OpenEnd) { [void]$ev.Add([pscustomobject]@{ T = $b.E; Kind = 'be'; Label = ('Back from ' + $b.Label.ToLower()); End = 0; B = $b; Actual = $false }) }
    }
    foreach ($d in $script:Diffs) { if ($d.After -gt $sp.S -and $d.After -lt $sp.E) {
        [void]$ev.Add([pscustomobject]@{ T = $d.After; Kind = 'diff'; Label = ('+' + (Format-Amt $d.Amt) + '/hr ' + $d.Label.ToLower() + ' diff starts'); End = 0; B = $null; Actual = $false }) } }
    [void]$ev.Add([pscustomobject]@{ T = $sp.E; Kind = 'out'; Label = 'Clock out'; End = 0; B = $null; Actual = $sp.SOut })
    $ev = @($ev | Sort-Object @{ Expression = { $_.T } }, @{ Expression = { if ($_.Kind -eq 'be') { 0 } else { 1 } } })
    $work = $sp.Work; $next = $null; $br = $null
    foreach ($b in $sp.Brs) { if ($m -ge $b.S -and $m -lt $b.E) { $br = $b; break } }
    if (-not $work) { $seg = [pscustomobject]@{ Kind = 'off'; Label = 'Day off'; B = $null } }
    elseif ($m -lt $sp.S) { $seg = [pscustomobject]@{ Kind = 'before'; Label = 'Before shift'; B = $null }; $next = $ev[0] }
    elseif ($m -ge $sp.E) { $seg = [pscustomobject]@{ Kind = 'done'; Label = 'Shift complete'; B = $null } }
    else {
        if ($br) { $seg = [pscustomobject]@{ Kind = 'break'; Label = ($br.Label + $(if ($br.Paid) { ' (paid)' } else { ' (unpaid)' })); B = $br } }
        else { $seg = [pscustomobject]@{ Kind = 'work'; Label = ('Working' + $(if ($script:DiffAt[$m] -ne 0) { ' + diff' } else { '' })); B = $null } }
        foreach ($e in $ev) { if ($e.T -gt $m -and ($e.Kind -ne 'be' -or ($br -and $e.B -eq $br))) { $next = $e; break } }
        if (-not $next) { foreach ($e in $ev) { if ($e.T -gt $m) { $next = $e; break } } }
    }
    # display rows (break end is folded into the break row; while working after a break a live "Now" row is shown)
    $rows = @()
    for ($i = 0; $i -lt $ev.Count; $i++) {
        $e = $ev[$i]; $segEnd = $(if ($i + 1 -lt $ev.Count) { $ev[$i + 1].T } else { $e.T })
        $state = ''
        if ($work) {
            if ($e.T -le $m -and ($i -eq $ev.Count - 1 -or $m -ge $segEnd)) { $state = 'done' }
            if ($e.T -le $m -and $m -lt $segEnd -and $e.Kind -ne 'out') { $state = $(if ($e.Kind -eq 'bs' -and -not $e.B.Paid) { 'brk' } else { 'cur' }) }
            if ($null -ne $next -and $e -eq $next -and $state -eq '') { $state = 'nxt' }
        }
        if ($e.Kind -eq 'be') {
            if ($state -eq 'cur') { $rows += [pscustomobject]@{ Time = (Format-Clock $m); Label = ('Now' + $dotC + 'working' + $(if ($next) { $dotC + (Format-Dur ($next.T - $m)) + ' left' } else { '' })); X = ''; State = 'cur'; LiveFrom = $null } }
            continue
        }
        $t = $(if ($e.Kind -eq 'bs') { (Format-Clock $e.T) -replace ' [AP]M$', '' } else { Format-Clock $e.T })
        $live = $null
        if ($e.Kind -eq 'bs') {
            if ($e.B.Open) { $t = (Format-Clock $e.T) + [string][char]0x2013 + 'now'; $live = [int]$e.B.SS; $x = (Format-MMSS ($nowSec - $live)) }
            else { $t += [string][char]0x2013 + (Format-Clock $e.End); $x = (Format-Dur ($e.End - $e.T)) }
            $x += $dotC + $(if ($e.B.Paid) { 'paid' } else { 'unpaid' })
        } else { $x = '' }
        if ($e.Actual -and -not ($e.Kind -eq 'bs' -and $e.B.Open)) { $x = $(if ($x) { $x + ' ' + $ck } else { $ck }) }
        $rows += [pscustomobject]@{ Time = $t; Label = $e.Label; X = $x; State = $state; LiveFrom = $live }
    }
    return [pscustomobject]@{ Events = $ev; Seg = $seg; Next = $next; Work = $work; Rows = $rows; Spec = $sp }
}
$dotC = ' ' + [char]0x00B7 + ' '

# $zeroBefore: TEST widget mode - date the simulation started; earlier days count as $0 (fresh start).
function Get-WidgetState([datetime]$now, $zeroBefore = $null) {
    $zbk = $(if ($null -ne $zeroBefore) { ([datetime]$zeroBefore).Date } else { $null })
    if ($zbk -ne $script:OTZeroBefore) { $script:OTZeroBefore = $zbk; $script:ShiftCache = @{}; $script:StraightCache = @{} }   # v1.14.0: OT week context follows the TEST reset
    $today = $now.Date
    $nowMin = $now.Hour * 60 + $now.Minute
    $s = [ordered]@{}
    $s.Now = $now
    $s.DayOff = $false; $s.DayName = $null; $s.OnBreak = $false; $s.BreakPaid = $false; $s.Br = $null
    $sp = Get-DaySpec $today $true; $s.Spec = $sp
    $br = $null; foreach ($b in $sp.Brs) { if ($nowMin -ge $b.S -and $nowMin -lt $b.E) { $br = $b; break } }; $s.Br = $br
    $nd = Get-NextWorkDay $today; $s.NextDay = $nd; $s.NextStart = (Get-DaySpec $nd $false).S
    if (-not $sp.Work) {
        $s.Status = 'OFF DAY'; $s.StatusColor = '#FF888888'
        $s.StatusDetail = 'Next shift ' + $nd.ToString('ddd', [Globalization.CultureInfo]::InvariantCulture) + ' ' + (Format-Clock $s.NextStart)
        $s.HeroDay = Get-PrevWorkDay $today; $s.HeroIsToday = $false
        $s.DayOff = $true; $s.DayName = $today.ToString('dddd', [Globalization.CultureInfo]::InvariantCulture).ToUpper()
    } elseif ($nowMin -lt $sp.S) {
        $s.Status = 'CLOCKED OUT'; $s.StatusColor = '#FF888888'; $s.StatusDetail = 'Shift starts ' + (Format-Clock $sp.S)
        $s.HeroDay = Get-PrevWorkDay $today; $s.HeroIsToday = $false
    } elseif ($nowMin -ge $sp.E) {
        $s.Status = 'CLOCKED OUT'; $s.StatusColor = '#FF888888'; $s.StatusDetail = $(if ($sp.SOut) { 'Clocked out ' + (Format-Clock $sp.E) } else { 'Shift complete' })
        $s.HeroDay = $today; $s.HeroIsToday = $true
    } elseif ($br) {
        $s.Status = 'ON ' + $br.Label.ToUpper(); $s.StatusColor = '#FFFFB020'; $s.OnBreak = $true; $s.BreakPaid = [bool]$br.Paid
        $s.StatusDetail = $(if ($br.E -lt $OpenEnd) { 'Back at ' + (Format-Clock $br.E) + $(if ($br.Paid) { ' (paid)' } else { ' (unpaid)' }) } else { $(if ($br.Paid) { 'paid' } else { 'unpaid' }) + $dotC + 'press ' + $(if ($br.Kind -eq 'lunch') { 'BACK FROM LUNCH' } else { 'END BREAK' }) })
        $s.HeroDay = $today; $s.HeroIsToday = $true
    } else {
        $s.Status = 'CLOCKED IN'; $s.StatusColor = '#FF34C759'
        $nb = $null; foreach ($b in $sp.Brs) { if (-not $b.Paid -and $b.S -gt $nowMin) { $nb = $b; break } }
        $s.StatusDetail = $(if ($nb) { $nb.Label + ' at ' + (Format-Clock $nb.S) } else { 'Until ' + (Format-Clock $sp.E) })
        $s.HeroDay = $today; $s.HeroIsToday = $true
    }
    if ($s.HeroIsToday) { $s.Hero = Get-ShiftCalc $today $nowMin $true } else { $s.Hero = Get-EffShift $s.HeroDay $zeroBefore }
    $s.DayPaidMin = $(if ($sp.Work) { (Get-FullShift $today).PaidMin } else { 0 })

    # Net split basis = the full SCHEDULED check of the hero day's pay period (same ratio in real and TEST widgets)
    # v1.14.0: if extra hours / overtime make the real period bigger than the schedule, use that so taxes include the OT
    $hps = Get-PayPeriodStart $s.HeroDay; $hg = Get-ScheduledPeriodGross $hps; $hge = Get-EffPeriodGross $hps $zeroBefore; if ($hge -gt $hg) { $hg = $hge }
    $heroCheck = Get-CheckWithholding $hg
    $s.HeroNet = Split-ByCheck $s.Hero.Total $heroCheck
    $s.CurrentRate = $null
    if ($s.Status -eq 'CLOCKED IN' -or ($s.OnBreak -and $s.BreakPaid)) { $s.CurrentRate = Get-RateAt $today $nowMin }

    # current pay period
    $ps = Get-PayPeriodStart $today
    $s.WeekStart = $ps                                                    # (kept name) first day of the current period
    $s.PeriodEnd = $ps.AddDays($PeriodDays - 1)
    $s.PeriodPayday = $ps.AddDays($PeriodDays - 1 + $PayLag)
    $s.WeekFull = Get-EffPeriodGross $ps $zeroBefore
    $s.WeekCheck = Get-CheckWithholding (Get-ScheduledPeriodGross $ps)    # split basis
    $s.WeekFullCheck = Get-CheckWithholding $s.WeekFull                   # what this period's check would be
    $days = @(); $soFar = [decimal]0
    for ($i = 0; $i -lt $PeriodDays; $i++) {
        $d = $ps.AddDays($i)
        if ($d -lt $today) {
            $c = Get-EffShift $d $zeroBefore
            $kind = $(if ($null -ne $zeroBefore -and $d -lt ([datetime]$zeroBefore).Date) { 'reset' } else { 'past' })
        }
        elseif ($d -eq $today) { $c = Get-ShiftCalc $d $nowMin $true; $kind = 'today' }
        else { $c = Get-EffShift $d $zeroBefore; $kind = 'future' }
        if ($kind -ne 'future') { $soFar += $c.Total }
        $days += [pscustomobject]@{ Date = $d; Calc = $c; Kind = $kind; Net = (Split-ByCheck $c.Total $s.WeekCheck) }
    }
    $s.WeekDays = $days; $s.WeekSoFar = $soFar
    $s.WeekSoFarNet = Split-ByCheck $soFar $s.WeekCheck

    # next paycheck (covers the period ending PayLag days before payday)
    $pd = Get-NextPayday $today
    $s.Payday = $pd
    $s.DaysUntil = ($pd - $today).Days
    $s.PayPeriodEnd   = $pd.AddDays(-$PayLag)
    $s.PayPeriodStart = $s.PayPeriodEnd.AddDays(-($PeriodDays - 1))
    $s.PaydayEstimate = Get-EffPeriodGross $s.PayPeriodStart $zeroBefore
    $s.PaydayCheck = Get-CheckWithholding $s.PaydayEstimate
    $s.Sched = Get-Schedule $today $nowMin ($nowMin * 60 + $now.Second)
    # v1.12.0 DAILY MONEY MADE: every day of the current period (days off = $0), today = so far (+ projected full day), future = projected.
    # Each day is its own share of this period's check (same as the big number); weeks = sum of their days; total = the approx. paycheck.
    $chk = $s.WeekFullCheck; $daily = @(); $sumProj = [decimal]0
    for ($i = 0; $i -lt $PeriodDays; $i++) {
        $wd = $days[$i]; $pc = $(if ($wd.Kind -eq 'today') { Get-FullShift $wd.Date } else { $wd.Calc })
        $pn = (Split-ByCheck $pc.Total $chk).Net; $sumProj += $pn
        $dn = $(if ($wd.Kind -eq 'today') { (Split-ByCheck $wd.Calc.Total $chk).Net } else { $pn })
        $daily += [pscustomobject]@{ Date = $wd.Date; Kind = $wd.Kind; Off = (-not $wd.Calc.IsWorkDay); Net = $dn; ProjNet = $pn; ProjGross = $pc.Total; PaidMin = $wd.Calc.PaidMin
                                     Punched = ($null -ne (Get-PunchRec $wd.Date.ToString('yyyy-MM-dd')))
                                     Diff = $wd.Calc.Diff; OT = $wd.Calc.OT; OTMin = $wd.Calc.OTMin; Gross = $wd.Calc.Total      # v1.14.0 (today = so far)
                                     ProjDiff = $pc.Diff; ProjOT = $pc.OT; ProjOTMin = $pc.OTMin; ProjReg = $pc.Reg }
    }
    $weeks = @(); for ($k = 0; $k -lt ($PeriodDays / 7); $k++) { $wn = [decimal]0; $wg = [decimal]0; $wdf = [decimal]0; $wot = [decimal]0; $wom = 0; $wrg = [decimal]0
        for ($j = $k * 7; $j -lt $k * 7 + 7; $j++) { $wn += $daily[$j].ProjNet; $wg += $daily[$j].ProjGross; $wdf += $daily[$j].ProjDiff; $wot += $daily[$j].ProjOT; $wom += $daily[$j].ProjOTMin; $wrg += $daily[$j].ProjReg }
        $weeks += [pscustomobject]@{ From = $ps.AddDays($k * 7); To = $ps.AddDays($k * 7 + 6); Net = $wn; Gross = $wg; Diff = $wdf; OT = $wot; OTMin = $wom; Reg = $wrg } }
    $s.PeriodDiff = [decimal]0; $s.PeriodOT = [decimal]0; $s.PeriodOTMin = 0; $s.PeriodReg = [decimal]0
    foreach ($w in $weeks) { $s.PeriodDiff += $w.Diff; $s.PeriodOT += $w.OT; $s.PeriodOTMin += $w.OTMin; $s.PeriodReg += $w.Reg }
    $s.Daily = $daily; $s.Weeks = $weeks; $s.PeriodNet = $chk.Net; $s.PeriodGross = $chk.Gross; $s.Rounding = $chk.Net - $sumProj
    return [pscustomobject]$s
}

# ---------------------------------------------------------------- ADP history
function Read-History {
    $h = [ordered]@{ Ok = $false; Stubs = @(); Basis = 'net'; Error = $null; LastSynced = $null }
    try {
        if (Test-Path -LiteralPath $historyPath) {
            $j = Get-Content -LiteralPath $historyPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.totalsBasis) { $h.Basis = [string]$j.totalsBasis }
            $h.LastSynced = $j.adp.lastSyncedAt
            $stubs = @()
            foreach ($p in @($j.paystubs)) {
                if ($null -eq $p -or -not $p.payDate) { continue }
                $stubs += [pscustomobject]@{
                    PayDate = [datetime]::ParseExact([string]$p.payDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
                    Gross   = $(if ($null -ne $p.grossPay) { [decimal]$p.grossPay } else { $null })
                    Net     = $(if ($null -ne $p.netPay) { [decimal]$p.netPay } else { $null })
                }
            }
            $h.Stubs = @($stubs | Sort-Object PayDate)
            $h.Ok = $true
        } else { $h.Error = 'paycheck-history.json not found' }
    } catch { $h.Error = $_.Exception.Message }
    return [pscustomobject]$h
}

function Get-HistoryTiles([datetime]$today, $hist) {
    $stubs = @($hist.Stubs | Where-Object { $_.PayDate -le $today })
    $amt = { param($p) if ($hist.Basis -eq 'gross') { $p.Gross } else { $p.Net } }
    $sumSince = {
        param([datetime]$since)
        $sel = @($stubs | Where-Object { $_.PayDate -gt $since })
        if ($sel.Count -eq 0) { return $null }
        $t = [decimal]0; foreach ($p in $sel) { $v = & $amt $p; if ($null -ne $v) { $t += $v } }
        return $t
    }
    $tiles = [ordered]@{}
    if ($stubs.Count -eq 0) {
        foreach ($k in 'Last','D30','M3','M6','Y1','YTD') { $tiles[$k] = $null }
        $tiles.Empty = $true
        return [pscustomobject]$tiles
    }
    $last = $stubs[-1]
    $tiles.Last = & $amt $last
    $tiles.LastDate = $last.PayDate
    $tiles.D30 = & $sumSince $today.AddDays(-30)
    $tiles.M3  = & $sumSince $today.AddMonths(-3)
    $tiles.M6  = & $sumSince $today.AddMonths(-6)
    $tiles.Y1  = & $sumSince $today.AddYears(-1)
    $tiles.YTD = & $sumSince ([datetime]::new($today.Year, 1, 1).AddDays(-1))
    $tiles.Empty = $false
    return [pscustomobject]$tiles
}

function Format-Money($v) {
    if ($null -eq $v) { return '$' + [char]0x2014 }
    return ('$' + ([decimal]$v).ToString('N2', [Globalization.CultureInfo]::InvariantCulture))
}
function Format-H([int]$min) { return (([decimal]$min / 60).ToString('0.0#', [Globalization.CultureInfo]::InvariantCulture) + 'h') }   # v1.14.0 compact hours
function Format-OTCell([int]$min, $amt) { if ($min -le 0) { return [string][char]0x2013 }; return ((Format-H $min) + ' ' + [char]0x00B7 + ' ' + (Format-Money $amt)) }
function Get-DiffNoteText($c) {
    # "after 6 PM +$2: $5.00 · weekend +$2: $16.00" (only the parts that apply to this profile)
    $inv = [Globalization.CultureInfo]::InvariantCulture; $dot = ' ' + [char]0x00B7 + ' '; $parts = @()
    if (@($script:Diffs).Count -eq 1) { $d = $script:Diffs[0]; $parts += ('after ' + (Format-Clock $d.After).Replace(':00 ', ' ') + ' ' + (Format-Money $c.DiffEve)) }
    elseif (@($script:Diffs).Count -gt 1) { $parts += ('time diffs: ' + (Format-Money $c.DiffEve)) }
    if ($Rules.WeekendDiff -ne 0) { $parts += ('weekend ' + (Format-Money $c.DiffWknd)) }
    if ($parts.Count -eq 0) { return 'no shift differentials set' }
    return ($parts -join $dot)
}
function Format-Hours([int]$min) { return (([decimal]$min / 60).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) + ' h') }
function Format-Deductions($t) {
    $d = ' ' + [char]0x00B7 + ' '; $parts = @()
    if ($t.PSObject.Properties['Pre'] -and @($t.Pre).Count) { foreach ($x in $t.Pre) { $parts += ($x.Label + ' ' + (Format-Money $x.Amt)) } } elseif ($t.K401 -ne 0) { $parts += ('Pre-tax ' + (Format-Money $t.K401)) }
    $parts += ('Fed ' + (Format-Money $t.Fed)); $parts += ('SS ' + (Format-Money $t.SS)); $parts += ('Med ' + (Format-Money $t.Med))
    if ($script:StateMode -ne 'none') { $parts += ($(if ($script:StateMode -eq 'ok') { 'OK ' } else { 'State ' }) + (Format-Money $t.OK)) }
    if ($t.PSObject.Properties['Aft'] -and @($t.Aft).Count) { foreach ($x in $t.Aft) { $parts += ($x.Label + ' ' + (Format-Money $x.Amt)) } } elseif ($t.Stock -ne 0) { $parts += ('After-tax ' + (Format-Money $t.Stock)) }
    return ($parts -join $d)
}

# ---------------------------------------------------------------- TEST widget simulated clock
$script:TestState = 'idle'           # idle | running | stopped
$script:TestClickReal = $null
$script:TestFrozen = [TimeSpan]::Zero
$script:TestDay = $null
function Get-TestDay {
    # first day of the current work streak (Van: Tuesday of a Tue-Sat week)
    $d = (Get-CentralNow).Date; $i = 0
    while (-not (Test-WorkDay $d) -and $i -lt 7) { $d = $d.AddDays(-1); $i++ }
    $i = 0; while ((Test-WorkDay $d.AddDays(-1)) -and $i -lt 6) { $d = $d.AddDays(-1); $i++ }
    return $d
}
function Get-TestSimNow {
    if ($null -eq $script:TestDay) { $script:TestDay = Get-TestDay }
    $start = $script:TestDay.AddMinutes((Get-DaySpec $script:TestDay $false).S0)
    switch ($script:TestState) {
        'running' { $el = (Get-CentralNow) - $script:TestClickReal }
        'stopped' { $el = $script:TestFrozen }
        default   { $el = [TimeSpan]::Zero }
    }
    return ($start + $el)    # runs continuously across days/weeks
}
function Invoke-TestStart {
    $script:TestDay = Get-TestDay
    $script:TestClickReal = Get-CentralNow
    $script:TestFrozen = [TimeSpan]::Zero
    $script:TestState = 'running'
    if ($script:Punches.Count) { $script:Punches = @{}; if (-not $SelfTest) { Save-Punches } else { $script:ShiftCache = @{}; $script:StraightCache = @{} } }   # v1.12.0: a fresh simulated week starts with no punches
}
function Invoke-TestFfwd([int]$min) {   # v1.13.0: jump the simulated clock forward (to check BE BACK BY / flashing / LATE)
    switch ($script:TestState) {
        'running' { $script:TestClickReal = $script:TestClickReal.AddMinutes(-$min) }
        'stopped' { $script:TestFrozen = $script:TestFrozen + [TimeSpan]::FromMinutes($min) }
    }
}
function Invoke-TestStop {
    if ($script:TestState -eq 'running') {
        $script:TestFrozen = (Get-CentralNow) - $script:TestClickReal
        $script:TestState = 'stopped'
    }
}

# ---------------------------------------------------------------- self test
if ($SelfTest) {
    $fails = 0
    function Assert-Eq($name, $actual, $expected) {
        if ($actual -is [decimal]) { $actual = $actual.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) }
        if ([string]$actual -eq [string]$expected) { Write-Output ("PASS  {0} = {1}" -f $name, $actual) }
        else { Write-Output ("FAIL  {0} = {1} (expected {2})" -f $name, $actual, $expected); $script:fails++ }
    }
    $tue = [datetime]'2026-09-29'; $sat = [datetime]'2026-10-03'
    $t = Get-FullShift $tue; $s = Get-FullShift $sat
    Assert-Eq 'Paid minutes per shift' $t.PaidMin 480
    Assert-Eq 'Tue-Fri shift gross' $t.Total '216.68'
    Assert-Eq 'Tue-Fri shift differential' $t.Diff '5.00'
    Assert-Eq 'Sat shift gross' $s.Total '232.68'
    Assert-Eq 'Sat shift differential' $s.Diff '21.00'
    Assert-Eq 'Sun/Mon earn nothing' ((Get-FullShift ([datetime]'2026-10-04')).Total + (Get-FullShift ([datetime]'2026-10-05')).Total) '0.00'
    $wk = Get-ScheduledWeekGross ([datetime]'2026-09-26')
    Assert-Eq 'Weekly gross' $wk '1099.40'
    $bw = Get-ScheduledPeriodGross ([datetime]'2026-09-26')
    Assert-Eq 'Biweekly gross' $bw '2198.80'
    Assert-Eq 'Period start of Tue 9/29' ((Get-PayPeriodStart ([datetime]'2026-09-29')).ToString('MM/dd')) '09/26'
    Assert-Eq 'Period start of Fri 9/25' ((Get-PayPeriodStart ([datetime]'2026-09-25')).ToString('MM/dd')) '09/12'
    Assert-Eq 'Paydays' (((Get-NextPayday ([datetime]'2026-09-29')), (Get-NextPayday ([datetime]'2026-10-01')), (Get-NextPayday ([datetime]'2026-10-15')) | % { $_.ToString('MM/dd') }) -join ',') '09/30,10/14,10/28'
    $c = Get-CheckWithholding $bw
    Write-Output ("      401k-reduced FIT wages {0}; adjusted wage (biweekly) {1}; OK wages after 1 allowance {2}; OK raw {3}" -f $c.FitWages, $c.AnnualAdjWage, $c.OkWages, $c.OkRaw)
    Assert-Eq 'Check 401k 10%' $c.K401 '219.88'
    Assert-Eq 'Check federal (15-T biweekly HOH)' $c.Fed '112.37'
    Assert-Eq 'Check Social Security' $c.SS '136.33'
    Assert-Eq 'Check Medicare' $c.Med '31.88'
    Assert-Eq 'Check Oklahoma (OW-2 biweekly)' $c.OK '68.00'
    Assert-Eq 'Check stock purchase (after-tax)' $c.Stock '50.00'
    Assert-Eq 'Check approx net' $c.Net '1580.34'
    Assert-Eq 'Paystub 401k 10% of 2458.07' (Get-CheckWithholding ([decimal]2458.07)).K401 '245.81'
    $tn = Split-ByCheck $t.Total $c; $sn = Split-ByCheck $s.Total $c
    Write-Output ("      Tue-Fri shift: gross {0} 401k {1} fed {2} ss {3} med {4} ok {5} net {6}" -f $tn.Gross, $tn.K401, $tn.Fed, $tn.SS, $tn.Med, $tn.OK, $tn.Net)
    Write-Output ("      Sat shift:     gross {0} 401k {1} fed {2} ss {3} med {4} ok {5} net {6}" -f $sn.Gross, $sn.K401, $sn.Fed, $sn.SS, $sn.Med, $sn.OK, $sn.Net)
    Assert-Eq 'Tue-Fri shift approx net' $tn.Net '155.73'
    Assert-Eq 'Sat shift approx net' $sn.Net '167.23'
    Assert-Eq 'Split sums back to gross' ($tn.Net + $tn.K401 + $tn.Fed + $tn.SS + $tn.Med + $tn.OK + $tn.Stock) '216.68'
    $cases = @(
        @{ At = '2026-09-29 12:00'; Status = 'CLOCKED IN';  Gross = '13.23';  Net = '9.51' },
        @{ At = '2026-09-29 15:30'; Status = 'ON LUNCH';    Gross = '92.61';  Net = '66.56' },
        @{ At = '2026-09-29 19:00'; Status = 'CLOCKED IN';  Gross = '173.99'; Net = '125.05' },
        @{ At = '2026-09-29 21:30'; Status = 'CLOCKED OUT'; Gross = '216.68'; Net = '155.73' },
        @{ At = '2026-10-03 19:00'; Status = 'CLOCKED IN';  Gross = '186.99'; Net = '134.40' },
        @{ At = '2026-09-28 12:00'; Status = 'OFF DAY';     Gross = '232.68'; Net = '167.23' },
        @{ At = '2026-10-04 12:00'; Status = 'OFF DAY';     Gross = '232.68'; Net = '167.23' }
    )
    foreach ($cs in $cases) {
        $n = [datetime]::ParseExact($cs.At, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        $st = Get-WidgetState $n
        Write-Output ''
        Write-Output ("== {0} ({1}) ==" -f $cs.At, $n.DayOfWeek)
        Assert-Eq ' status' $st.Status $cs.Status
        Assert-Eq ' hero gross' $st.Hero.Total $cs.Gross
        Assert-Eq ' hero approx net' $st.HeroNet.Net $cs.Net
        if ($cs.Status -eq 'OFF DAY') { Assert-Eq ' day-off hero text' ("{0} / DAY OFF" -f $st.DayName) ($n.DayOfWeek.ToString().ToUpper() + ' / DAY OFF') }
        Write-Output ("      diff {0}; deductions: {1}" -f $st.Hero.Diff, (Format-Deductions $st.HeroNet))
        Write-Output ("      period {0:M/d}-{1:M/d} so far gross {2} / net {3}; next payday {4:ddd M/d} in {5} day(s) covers {6:M/d}-{7:M/d}: gross {8} net {9}" -f `
            $st.WeekStart, $st.PeriodEnd, $st.WeekSoFar, $st.WeekSoFarNet.Net, $st.Payday, $st.DaysUntil, $st.PayPeriodStart, $st.PayPeriodEnd, $st.PaydayCheck.Gross, $st.PaydayCheck.Net)
    }
    # test-widget clock + reset logic
    Write-Output ''
    Write-Output '== TEST widget clock =='
    $script:TestState = 'idle'; $script:TestDay = [datetime]'2026-09-29'
    Assert-Eq ' idle sim clock' ((Get-TestSimNow).ToString('HH:mm')) '11:30'
    $script:TestState = 'running'; $script:TestClickReal = (Get-CentralNow).AddMinutes(-10)
    Assert-Eq ' 10 real min after START' ((Get-TestSimNow).ToString('HH:mm')) '11:40'
    $ts = Get-WidgetState (Get-TestSimNow) $script:TestDay
    Assert-Eq ' test 11:40 gross' $ts.Hero.Total '4.41'
    Assert-Eq ' test week so far = today only' $ts.WeekSoFar '4.41'
    $script:TestClickReal = (Get-CentralNow).AddMinutes(-(19 * 60 + 30 - 11 * 60 - 30))
    $ts = Get-WidgetState (Get-TestSimNow) $script:TestDay
    Assert-Eq ' test 7:30 PM gross' $ts.Hero.Total '188.22'
    Invoke-TestStop; $f1 = Get-TestSimNow; Start-Sleep -Milliseconds 1200; $f2 = Get-TestSimNow
    Assert-Eq ' STOP freezes clock' ($f1 -eq $f2) 'True'
    Invoke-TestStart; $script:TestDay = [datetime]'2026-09-29'
    Assert-Eq ' START again resets to 11:30' ((Get-TestSimNow).ToString('HH:mm')) '11:30'
    Assert-Eq ' START again resets gross' (Get-WidgetState (Get-TestSimNow) $script:TestDay).Hero.Total '0.00'
    $script:TestClickReal = (Get-CentralNow).AddHours(-10)
    $ts = Get-WidgetState (Get-TestSimNow) $script:TestDay
    Assert-Eq ' 10 real hours later: final' "$($ts.Status) $($ts.Hero.Total) $($ts.HeroNet.Net)" 'CLOCKED OUT 216.68 155.73'
    Write-Output ''
    Write-Output '== TEST widget: continuous multi-day clock (START Tue 9/29 11:30) =='
    $script:TestDay = [datetime]'2026-09-29'; $script:TestState = 'running'
    $multi = @(
        @{ H = 24;    Clock = 'Wed 09/30 11:30'; Status = 'CLOCKED IN';  Hero = '0.00';   Week = '216.68'; Pay = 'Wed 09/30 0d 0.00' },
        @{ H = 24.5;  Clock = 'Wed 09/30 12:00'; Status = 'CLOCKED IN';  Hero = '13.23';  Week = '229.91'; Pay = 'Wed 09/30 0d 0.00' },
        @{ H = 105.5; Clock = 'Sat 10/03 21:00'; Status = 'CLOCKED OUT'; Hero = '232.68'; Week = '1099.40'; Pay = 'Wed 10/14 11d 1966.12' },
        @{ H = 120;   Clock = 'Sun 10/04 11:30'; Status = 'OFF DAY';     Hero = '232.68'; Week = '1099.40'; Pay = 'Wed 10/14 10d 1966.12' },
        @{ H = 144;   Clock = 'Mon 10/05 11:30'; Status = 'OFF DAY';     Hero = '232.68'; Week = '1099.40'; Pay = 'Wed 10/14 9d 1966.12' },
        @{ H = 175.5; Clock = 'Tue 10/06 19:00'; Status = 'CLOCKED IN';  Hero = '173.99'; Week = '1273.39'; Pay = 'Wed 10/14 8d 1966.12' },
        @{ H = 192;   Clock = 'Wed 10/07 11:30'; Status = 'CLOCKED IN';  Hero = '0.00';   Week = '1316.08'; Pay = 'Wed 10/14 7d 1966.12' },
        @{ H = 336;   Clock = 'Tue 10/13 11:30'; Status = 'CLOCKED IN';  Hero = '0.00';   Week = '232.68'; Pay = 'Wed 10/14 1d 1966.12' },
        @{ H = 528;   Clock = 'Wed 10/21 11:30'; Status = 'CLOCKED IN';  Hero = '0.00';   Week = '1548.76'; Pay = 'Wed 10/28 7d 2198.80' }
    )
    foreach ($m in $multi) {
        $script:TestClickReal = (Get-CentralNow).AddHours(-$m.H)
        $sn = Get-TestSimNow
        $sn = $sn.AddSeconds(-$sn.Second)   # ignore sub-minute drift from test runtime
        $ts = Get-WidgetState $sn $script:TestDay
        $label = ("+{0}h" -f $m.H)
        Assert-Eq " $label sim clock" ($sn.ToString('ddd MM/dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)) $m.Clock
        Assert-Eq " $label status" $ts.Status $m.Status
        Assert-Eq " $label hero gross" $ts.Hero.Total $m.Hero
        Assert-Eq " $label period so far gross" $ts.WeekSoFar $m.Week
        Assert-Eq " $label payday" ("{0} {1}d {2}" -f $ts.Payday.ToString('ddd MM/dd', [Globalization.CultureInfo]::InvariantCulture), $ts.DaysUntil, $ts.PaydayCheck.Gross.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)) $m.Pay
        if ($ts.DayOff) { Assert-Eq " $label day-off hero" $ts.DayName ($sn.DayOfWeek.ToString().ToUpper()) }
    }
    $c1987 = Get-CheckWithholding ([decimal]1966.12)
    Write-Output ("      1966.12 check (TEST period 9/26-10/9 started Tue 9/29, paid 10/14): 401k {0} fed {1} ss {2} med {3} ok {4} stock {6} net {5}" -f $c1987.K401, $c1987.Fed, $c1987.SS, $c1987.Med, $c1987.OK, $c1987.Net, $c1987.Stock)
    Write-Output ''
    Write-Output '== v1.11 profile, schedule timeline, generic deductions =='
    $en = [string][char]0x2013; $md = ' ' + [char]0x00B7 + ' '
    Assert-Eq ' paycheck lines' (Format-Deductions $c) ('401(k) $219.88' + $md + 'Fed $112.37' + $md + 'SS $136.33' + $md + 'Med $31.88' + $md + 'OK $68.00' + $md + 'Stock purchase $50.00')
    Assert-Eq ' 12:00 status detail' (Get-WidgetState ([datetime]'2026-09-29 12:00')).StatusDetail 'Lunch at 3:00 PM'
    Assert-Eq ' 7:00 PM status detail' (Get-WidgetState ([datetime]'2026-09-29 19:00')).StatusDetail 'Until 8:30 PM'
    Assert-Eq ' Mon status detail' (Get-WidgetState ([datetime]'2026-09-28 12:00')).StatusDetail 'Next shift Tue 11:30 AM'
    $sc = Get-Schedule ([datetime]'2026-09-29') (17 * 60 + 5)
    Assert-Eq ' schedule 5:05 PM' (($sc.Rows | ForEach-Object { $_.State + ':' + $_.Time + ' ' + $_.Label }) -join ' | ') ('done:11:30 AM Clock in | done:3:00' + $en + '4:00 PM Lunch | cur:5:05 PM Now' + $md + 'working' + $md + '55m left | nxt:6:00 PM +2/hr evening diff starts | :8:30 PM Clock out')
    $sc = Get-Schedule ([datetime]'2026-09-29') (15 * 60 + 30)
    Assert-Eq ' schedule 3:30 PM' ($sc.Seg.Label + ' -> ' + $sc.Next.Label + ' in ' + ($sc.Next.T - 930) + 'm; ' + (($sc.Rows | Where-Object { $_.State -eq 'brk' }).Time)) ('Lunch (unpaid) -> Back from lunch in 30m; 3:00' + $en + '4:00 PM')
    Assert-Eq ' schedule day off' (Get-Schedule ([datetime]'2026-09-28') 700).Seg.Label 'Day off'
    Set-Profile ('{"name":"X","rate":20,"days":[1,2,3,4,5],"start":"09:00","end":"17:30","breaks":[{"label":"Lunch","start":"12:00","end":"12:30","paid":false},{"label":"Break","start":"15:00","end":"15:15","paid":true}],"diffs":[{"label":"Late","amount":1,"after":"16:00"},{"label":"Later","amount":0.5,"after":"17:00"}],"wkndDiff":0,"wkndDays":[6,0],"freq":"weekly","weekStart":0,"nextPayday":"2026-10-02","fs":"single","st":"none","oka":0,"stPct":0,"pretax":[{"label":"Health","type":"amt","value":25,"fica":true}],"aftertax":[]}' | ConvertFrom-Json)
    Assert-Eq ' other profile paid min' $PaidMinPerShift 480
    Assert-Eq ' other profile shift gross' (Get-FullShift ([datetime]'2026-09-28')).Total '161.75'
    $ow = Get-CheckWithholding ([decimal]808.75)
    Assert-Eq ' other profile weekly check (state, SS, pre-tax)' ("{0} {1} {2}" -f $ow.OK, $ow.SS, $ow.K401) '0 48.59 25'
    Assert-Eq ' other profile period / payday' ("{0} {1:MM/dd}" -f $PeriodDays, (Get-WidgetState ([datetime]'2026-09-29 10:00')).Payday) '7 10/02'
    Set-Profile ($VanPresetJson | ConvertFrom-Json)
    Assert-Eq ' back to Van profile' (Get-CheckWithholding ([decimal]2198.80)).Net '1580.34'
    Write-Output ''
    Write-Output '== v1.12 manual punches, per-day schedule, daily money list =='
    $iso = '2026-09-29'; $T = { param($h, $m) ($h * 60 + $m) * 60 }
    $setP = { param($map) $script:Punches = @{}; foreach ($k in $map.Keys) { $l = New-Object System.Collections.ArrayList; foreach ($e in $map[$k]) { [void]$l.Add(@($e[0], [int]$e[1])) }; $script:Punches[$k] = $l }; $script:ShiftCache = @{}; $script:StraightCache = @{} }
    & $setP @{ $iso = @(@('in', (& $T 11 40)), @('lo', (& $T 15 10)), @('li', (& $T 15 50)), @('out', (& $T 20 0))) }
    $c = Get-FullShift $tue; Assert-Eq ' punches: paid min / gross' ("{0} {1}" -f $c.PaidMin, $c.Total) '460 206.86'
    $sc = Get-Schedule $tue (16 * 60)
    Assert-Eq ' punches: timeline uses actual times' ((@($sc.Events | Where-Object { $_.Kind -ne 'be' }) | ForEach-Object { $_.Kind + '@' + $_.T + $(if ($_.Actual) { '*' } else { '' }) }) -join ' ') 'in@700* bs@910* diff@1080 out@1200*'
    & $setP @{ $iso = @(, @('lo', (& $T 15 10))) }
    $st = Get-WidgetState ([datetime]'2026-09-29 15:30')
    Assert-Eq ' open lunch (live): status / paid so far / open' ("{0} {1} {2}" -f $st.Status, $st.Hero.PaidMin, $st.Br.Open) 'ON LUNCH 220 True'
    Assert-Eq ' open lunch closes at scheduled length on later days' (Get-FullShift $tue).PaidMin 480
    & $setP @{ $iso = @(@('bs', (& $T 13 0)), @('be', (& $T 13 15))) }
    Assert-Eq ' manual break paid by default' (Get-FullShift $tue).PaidMin 480
    $up = ($VanPresetJson | ConvertFrom-Json); $up | Add-Member -NotePropertyName breakPaid -NotePropertyValue $false -Force; Set-Profile $up
    & $setP @{ $iso = @(@('bs', (& $T 13 0)), @('be', (& $T 13 15))) }
    Assert-Eq ' manual break unpaid when profile says so' ("{0} {1}" -f (Get-FullShift $tue).PaidMin, (Get-FullShift $tue).Total) '465 210.07'
    Set-Profile ($VanPresetJson | ConvertFrom-Json)
    & $setP @{ '2026-09-28' = @(@('in', (& $T 12 0)), @('out', (& $T 14 0))) }
    $c = Get-FullShift ([datetime]'2026-09-28'); Assert-Eq ' clock in on a day off counts' ("{0} {1} {2}" -f $c.IsWorkDay, $c.PaidMin, $c.Total) 'True 120 52.92'
    & $setP @{ $iso = @(@('in', (& $T 11 40)), @('in', (& $T 11 35))) }
    Assert-Eq ' last press wins' (Get-DaySpec $tue $false).S 695
    & $setP @{}
    $s2 = Get-WidgetState ([datetime]'2026-09-29 17:05')
    Assert-Eq ' daily list: 14 days, off days $0' ("{0} {1}" -f @($s2.Daily).Count, ((@($s2.Daily | Where-Object { $_.Off }) | ForEach-Object { $_.Net.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) }) -join ',')) '14 0.00,0.00,0.00,0.00'
    Assert-Eq ' daily list: weeks + rounding = period total = approx. paycheck' ("{0} + {1} + {2} = {3} gross {4}" -f $s2.Weeks[0].Net, $s2.Weeks[1].Net, $s2.Rounding, $s2.PeriodNet, $s2.PeriodGross) '790.15 + 790.15 + 0.04 = 1580.34 gross 2198.80'
    Assert-Eq ' daily list: today so far / projected' ("{0} {1} / {2}" -f $s2.Daily[3].Kind, $s2.Daily[3].Net, $s2.Daily[3].ProjNet) 'today 87.17 / 155.73'
    $pdp = ($VanPresetJson | ConvertFrom-Json); $pdp | Add-Member -NotePropertyName perDay -NotePropertyValue ('{"6":{"start":"10:00","end":"18:00"}}' | ConvertFrom-Json) -Force; Set-Profile $pdp
    $q = Get-DaySpec $sat $false; Assert-Eq ' per-day schedule (Sat 10-6)' ("{0}-{1}" -f $q.S, $q.E) '600-1080'
    Set-Profile ($VanPresetJson | ConvertFrom-Json)
    Assert-Eq ' punch log round-trip (JSON)' ((& { $script:Punches = @{}; $l = New-Object System.Collections.ArrayList; [void]$l.Add(@('in', 41700)); [void]$l.Add(@('lo', 54130)); $script:Punches[$iso] = $l
        $parts = @(foreach ($k in @($script:Punches.Keys)) { '"' + $k + '":[' + ((@($script:Punches[$k]) | ForEach-Object { '["' + $_[0] + '",' + [int]$_[1] + ']' }) -join ',') + ']' }); '{' + ($parts -join ',') + '}' })) '{"2026-09-29":[["in",41700],["lo",54130]]}'
    Write-Output ''
    Write-Output '== v1.13 BE BACK BY =='
    Assert-Eq ' break length default (min)' $script:BreakLen 15
    $bl = ($VanPresetJson | ConvertFrom-Json); $bl | Add-Member -NotePropertyName breakLen -NotePropertyValue 20 -Force; Set-Profile $bl
    Assert-Eq ' break length from profile' $script:BreakLen 20
    Set-Profile ($VanPresetJson | ConvertFrom-Json)
    Assert-Eq ' lunch length from profile (min)' ([int]($script:LunchBreak.E - $script:LunchBreak.S)) 60
    & $setP @{}
    Write-Output ''
    Write-Output '== v1.14 SHIFT DIFF + OVERTIME =='
    $fmt = { param($c) "{0} reg {1} diff {2} (eve {3} wknd {4}) ot {5} {6}m" -f $c.Total, $c.Reg, $c.Diff, $c.DiffEve, $c.DiffWknd, $c.OT, $c.OTMin }
    $fri = [datetime]'2026-10-02'; $null = Get-WidgetState ([datetime]'2026-10-02 12:00')
    Assert-Eq ' normal 40h week: no OT on Fri' (& $fmt (Get-FullShift $fri)) '216.68 reg 211.68 diff 5.00 (eve 5.00 wknd 0) ot 0 0m'
    Assert-Eq ' Sat: eve + weekend diff stack' (& $fmt (Get-FullShift $sat)) '232.68 reg 211.68 diff 21.00 (eve 5.00 wknd 16) ot 0 0m'
    & $setP @{ '2026-09-28' = @(@('in', (& $T 12 0)), @('out', (& $T 14 0))) }
    Assert-Eq ' +2h Mon: OT 2h on Fri at 1.5x(base+eve)' (& $fmt (Get-FullShift $fri)) '245.14 reg 158.76 diff 1.00 (eve 1.00 wknd 0) ot 85.38 120m'
    Assert-Eq ' Thu before the crossing: no OT' (& $fmt (Get-FullShift ([datetime]'2026-10-01'))).EndsWith('ot 0 0m') $true
    $s3 = Get-WidgetState ([datetime]'2026-10-02 19:30')
    Assert-Eq ' live Fri 7:30 PM: OT so far 1h' ("{0} {1}" -f $s3.Hero.OT, $s3.Hero.OTMin) '42.69 60'
    Assert-Eq ' week 1 diff / OT / gross' ("{0} {1} {2}m {3}" -f $s3.Weeks[0].Diff, $s3.Weeks[0].OT, $s3.Weeks[0].OTMin, $s3.Weeks[0].Gross) '37.00 85.38 120m 1180.78'
    Assert-Eq ' hero net taxed on the OT-sized check = daily row' ("{0} {1}" -f $s3.HeroNet.Net, $s3.Daily[6].Net) ("{0} {1}" -f $s3.Daily[6].Net, $s3.Daily[6].Net)
    Assert-Eq ' daily row Fri: diff / OT' ("{0} {1} {2}" -f $s3.Daily[6].Kind, $s3.Daily[6].ProjDiff, $s3.Daily[6].ProjOT) 'today 1.00 85.38'
    $o1 = ($VanPresetJson | ConvertFrom-Json); $o1 | Add-Member -NotePropertyName otOn -NotePropertyValue $false -Force; Set-Profile $o1
    Assert-Eq ' OT switched off: straight time' (& $fmt (Get-FullShift $fri)) '216.68 reg 211.68 diff 5.00 (eve 5.00 wknd 0) ot 0 0m'
    $o2 = ($VanPresetJson | ConvertFrom-Json); $o2 | Add-Member -NotePropertyName otAfter -NotePropertyValue 38 -Force; $o2 | Add-Member -NotePropertyName otMult -NotePropertyValue 2 -Force; Set-Profile $o2
    Assert-Eq ' custom OT: after 38h at 2x' (& $fmt (Get-FullShift $fri)) '327.52 reg 105.84 diff 0.00 (eve 0.00 wknd 0) ot 221.68 240m'
    Set-Profile ($VanPresetJson | ConvertFrom-Json)
    & $setP @{ '2026-10-03' = @(@('in', (& $T 11 30)), @('lo', (& $T 15 0)), @('li', (& $T 16 0)), @('out', (& $T 21 30))) }
    Assert-Eq ' late Sat clock-out (9h): week 2 OT 1h lands on Fri 10/9' (& $fmt (Get-FullShift ([datetime]'2026-10-09'))) '230.91 reg 185.22 diff 3.00 (eve 3.00 wknd 0) ot 42.69 60m'
    Assert-Eq ' TEST reset days count 0h toward 40' (& { $null = Get-WidgetState ([datetime]'2026-10-09 12:00') ([datetime]'2026-10-06'); (Get-FullShift ([datetime]'2026-10-09')).OTMin }) 0
    $null = Get-WidgetState ([datetime]'2026-10-09 12:00')
    & $setP @{}
    Write-Output ''
    Write-Output '== v1.14.1 LUNCH / CLOCK PUNCHES NEVER RESET TODAY =='
    $iv = [Globalization.CultureInfo]::InvariantCulture
    $hold = { param($lab, $map, $lo, $li, $want)
        & $setP $map; $d0 = [datetime]'2026-10-02'
        $at = { param($mn) Get-WidgetState ($d0.AddMinutes($mn)) }
        $a = & $at $lo; $b = & $at ($li - 1); $c = & $at $li; $d = & $at ($li + 5); $e = & $at (20 * 60 + 45)
        $txt = (@($a, $b, $c, $d, $e) | ForEach-Object { '$' + $_.Hero.Total.ToString('0.00', $iv) }) -join ' '
        Assert-Eq (' lunch hold: ' + $lab) ($txt + ' ' + ($a.HeroIsToday -and $b.HeroIsToday -and $c.HeroIsToday -and $d.HeroIsToday)) $want
        Assert-Eq (' lunch hold: ' + $lab + ' (never drops)') (($a.Hero.Total -eq $b.Hero.Total) -and ($b.Hero.Total -eq $c.Hero.Total) -and ($d.Hero.Total -gt $c.Hero.Total)) $true }
    $f = '2026-10-02'; $ok = '$92.61 $92.61 $92.61 $94.82 $216.68 True'
    & $hold 'auto schedule' @{} 900 960 $ok
    & $hold 'manual lunch only (auto 11:30 start)' @{ $f = @(@('lo', (& $T 15 0)), @('li', (& $T 16 0))) } 900 960 $ok
    & $hold 'full manual punches' @{ $f = @(@('in', (& $T 11 30)), @('lo', (& $T 15 0)), @('li', (& $T 16 0)), @('out', (& $T 20 30))) } 900 960 $ok
    & $hold 'paid breaks during the shift' @{ $f = @(@('bs', (& $T 13 0)), @('be', (& $T 13 15)), @('lo', (& $T 15 0)), @('li', (& $T 16 0)), @('bs', (& $T 17 30)), @('be', (& $T 17 45))) } 900 960 $ok
    & $hold 'late lunch 3:10-4:20' @{ $f = @(@('lo', (& $T 15 10)), @('li', (& $T 16 20))) } 910 980 '$97.02 $97.02 $97.02 $99.23 $212.27 True'
    & $hold 'early lunch 2:30-3:20 (+10 min = 10 min OT)' @{ $f = @(@('lo', (& $T 14 30)), @('li', (& $T 15 20))) } 870 920 '$79.38 $79.38 $79.38 $81.59 $223.46 True'
    & $hold 'CLOCK IN pressed to come back from lunch' @{ $f = @(@('lo', (& $T 15 0)), @('in', (& $T 16 0))) } 900 960 $ok
    & $hold 'CLOCK OUT / CLOCK IN used for lunch' @{ $f = @(@('out', (& $T 15 0)), @('in', (& $T 16 0))) } 900 960 $ok
    & $hold 'extra CLOCK IN after lunch keeps 11:30 start' @{ $f = @(@('lo', (& $T 15 0)), @('li', (& $T 16 0)), @('in', (& $T 16 1))) } 900 960 $ok
    & $hold 'forgotten END BREAK closes at OUT TO LUNCH' @{ $f = @(@('bs', (& $T 13 0)), @('lo', (& $T 15 0)), @('li', (& $T 16 0))) } 900 960 $ok
    & $setP @{}
    Write-Output ''
    Write-Output '== v1.14.2 EDIT PUNCHES =='
    $T3 = { param($h, $m, $x) ($h * 60 + $m) * 60 + $x }
    $f2 = '2026-10-02'; $fd = [datetime]$f2
    & $setP @{ $f2 = @(@('bs', (& $T3 13 3 20)), @('lo', (& $T 15 0)), @('li', (& $T 16 0))) }
    $em = Get-DayModel $f2; $eb = @($em.Segs | Where-Object { $_.Kind -eq 'break' })[0]
    Assert-Eq ' editor: forgotten break shows as auto-closed' ("{0} {1} {2} {3}" -f $eb.AutoClosed, $eb.S, $eb.E, $em.In.Auto) 'True 47000 54000 True'
    $eb.E = $eb.S + $script:BreakLen * 60; Assert-Eq ' editor: valid after 15 MIN' ([string](Test-DayModel $em)) ''
    $elog = Build-PunchLog $em
    Assert-Eq ' editor: rebuilt log (same as phone)' ((@($elog) | ForEach-Object { $_[0] + '@' + $_[1] }) -join ' ') 'bs@47000 be@47900 lo@54000 li@57600'
    [void](Save-DayModel $f2 $em $true); $em2 = Get-DayModel $f2; $eb2 = @($em2.Segs | Where-Object { $_.Kind -eq 'break' })[0]
    Assert-Eq ' editor: break now 15:00, not auto-closed' ("{0} {1}" -f (($eb2.E - $eb2.S) / 60), $eb2.AutoClosed) '15 False'
    Assert-Eq ' editor: paid break fixed -> full day total' (Get-FullShift $fd).Total 216.68
    Assert-Eq ' editor: live after fix (4:30 PM)' ("{0} {1}" -f (Get-WidgetState ($fd.AddMinutes(990))).Hero.Total, (Get-WidgetState ($fd.AddMinutes(990))).Status) '105.84 CLOCKED IN'
    $up2 = ($VanPresetJson | ConvertFrom-Json); $up2 | Add-Member -NotePropertyName breakPaid -NotePropertyValue $false -Force; Set-Profile $up2
    & $setP @{ $f2 = @(@('bs', (& $T 13 0)), @('lo', (& $T 15 0)), @('li', (& $T 16 0))) }
    Assert-Eq ' unpaid breaks: forgotten break loses 2h' (Get-FullShift $fd).Total 163.76
    $mu = Get-DayModel $f2; @($mu.Segs | Where-Object { $_.Kind -eq 'break' })[0].E = (& $T 13 15); [void](Save-DayModel $f2 $mu $false)
    Assert-Eq ' unpaid breaks: forgotten break fixed to 15 min -> right total' (Get-FullShift $fd).Total 210.07
    Set-Profile ($VanPresetJson | ConvertFrom-Json); & $setP @{ $f2 = @(@('bs', (& $T3 13 3 20)), @('be', (& $T3 13 18 20)), @('lo', (& $T 15 0)), @('li', (& $T 16 0))) }
    $v = Get-DayModel $f2; $v.Segs[0].E = $v.Segs[0].S - 60; Assert-Eq ' validate: end before start' ([string](Test-DayModel $v) -match 'must end after') $true
    $v = Get-DayModel $f2; $v.Segs[0].E = (& $T 15 30); Assert-Eq ' validate: overlap' ([string](Test-DayModel $v) -match 'overlaps') $true
    $v = Get-DayModel $f2; $v.In = @{ T = (& $T 14 0); Auto = $false }; Assert-Eq ' validate: segment before clock in' ([string](Test-DayModel $v) -match 'before clock in') $true
    $v = Get-DayModel $f2; $v.Out = @{ T = (& $T 11 0); Auto = $false }; Assert-Eq ' validate: clock out before clock in' ([string](Test-DayModel $v) -match 'after clock in') $true
    & $setP @{}; $a = Get-DayModel '2026-09-29'
    Assert-Eq ' editor: auto day shows schedule' ("{0} {1} {2} {3}" -f $a.In.Auto, $a.Segs.Count, $a.Segs[0].Kind, $a.Segs[0].Auto) 'True 1 lunch True'
    [void]$a.Segs.Add(@{ Kind = 'break'; S = (& $T 17 0); E = (& $T 17 15); Auto = $false }); $a.In = @{ T = (& $T 11 40); Auto = $false }; $a.Out = @{ T = (& $T 20 0); Auto = $false }
    Assert-Eq ' editor: add break + clock in/out (earlier day)' ("{0} {1}" -f [string](Save-DayModel '2026-09-29' $a $false), (Get-FullShift ([datetime]'2026-09-29')).Total) ' 198.04'
    $a2 = Get-DayModel '2026-09-29'; $keep = @($a2.Segs | Where-Object { $_.Kind -ne 'lunch' }); $a2.Segs = New-Object System.Collections.ArrayList; foreach ($x in $keep) { [void]$a2.Segs.Add($x) }; $a2.NoLunch = $true
    [void](Save-DayModel '2026-09-29' $a2 $false)
    Assert-Eq ' editor: delete lunch -> paid through / stays deleted' ("{0} {1}" -f (Get-FullShift ([datetime]'2026-09-29')).PaidMin, (Get-DayModel '2026-09-29').NoLunch) '500 True'
    $pt0 = (Get-FullShift ([datetime]'2026-10-06')).Total; $script:Pto['2026-10-06'] = New-Object System.Collections.ArrayList; [void]$script:Pto['2026-10-06'].Add(@(690, 960)); Save-Pto
    $pt1 = Get-FullShift ([datetime]'2026-10-06'); Assert-Eq ' PTO 11:30 AM-4 PM: 4.5 h at base rate added to the day' ("{0} {1}" -f $pt1.PtoMin, ($pt1.Total - $pt0)) ("270 " + (Round2 ($Rules.BaseRate * 4.5)))
    $script:Pto.Remove('2026-10-06'); Save-Pto
    & $setP @{}
    Write-Output ''
    Write-Output ("RESULT: {0} failure(s)" -f $fails)
    exit $fails
}

# ---------------------------------------------------------------- v1.11.0 SETTINGS / first-run SETUP (gear button) + tip jar
function Open-Url([string]$u) { try { Start-Process $u } catch {} }
function Format-BreakLines($p) { return ((@($p.breaks) | Where-Object { $_ } | ForEach-Object { '{0}, {1}, {2}, {3}' -f $_.label, (Format-Clock (ConvertTo-Min $_.start)), (Format-Clock (ConvertTo-Min $_.end)), $(if ($_.paid) { 'paid' } else { 'unpaid' }) }) -join "`r`n") }
function Format-DiffLines($p) { return ((@($p.diffs) | Where-Object { $_ } | ForEach-Object { '{0}, {1}, {2}' -f $_.label, (Format-Amt ([decimal]$_.amount)), (Format-Clock (ConvertTo-Min $_.after)) }) -join "`r`n") }
function Format-DedLines($list, [bool]$pre) { return ((@($list) | Where-Object { $_ } | ForEach-Object { $v = $(if ($_.type -eq 'pct') { (Format-Amt ([decimal]$_.value)) + '%' } else { '$' + (Format-Amt ([decimal]$_.value)) }); '{0}, {1}{2}' -f $_.label, $v, $(if ($pre -and $_.fica) { ', fica' } else { '' }) }) -join "`r`n") }
function Split-Lines([string]$t) { return @($t -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
function Read-SettingsForm($f) {
    # returns @{ Profile = ...; Error = '...' }
    $err = $null; $inv2 = [Globalization.CultureInfo]::InvariantCulture
    $name = $f.FName.Text.Trim()
    $rate = [decimal]0; [void][decimal]::TryParse(($f.FRate.Text -replace '[\$,\s]', ''), [Globalization.NumberStyles]::Number, $inv2, [ref]$rate)
    $days = @(0..6 | Where-Object { $f.("FD$_").IsChecked })
    $wdays = @(0..6 | Where-Object { $f.("FW$_").IsChecked })
    $perDay = [ordered]@{}; $dayErr = $null
    foreach ($i in $days) { $a1 = ConvertTo-Min $f["FS$i"].Text; $b1 = ConvertTo-Min $f["FE$i"].Text
        if ($null -eq $a1 -or $null -eq $b1 -or $b1 -le $a1) { if (-not $dayErr) { $dayErr = $DowNames[$i] + ': shift end must be after shift start (same day), e.g. 11:30 AM and 8:30 PM.' } }
        else { $perDay[[string]$i] = [ordered]@{ start = (Format-HHmm $a1); end = (Format-HHmm $b1) } } }
    $st = $null; $en = $null; if ($days.Count -and $perDay.Contains([string]$days[0])) { $st = ConvertTo-Min $perDay[[string]$days[0]].start; $en = ConvertTo-Min $perDay[[string]$days[0]].end }
    $breaks = @(); foreach ($ln in (Split-Lines $f.FBreaks.Text)) { $a = @($ln -split ',' | ForEach-Object { $_.Trim() })
        if ($a.Count -lt 3) { $err = 'Each break line needs: label, start, end (e.g. Lunch, 3:00 PM, 4:00 PM, unpaid)'; break }
        $bs = ConvertTo-Min $a[1]; $be = ConvertTo-Min $a[2]
        if ($null -eq $bs -or $null -eq $be -or $be -le $bs) { $err = "Break '" + $a[0] + "' needs a start and a later end time."; break }
        $breaks += [ordered]@{ label = $a[0]; start = (Format-HHmm $bs); end = (Format-HHmm $be); paid = ($a.Count -ge 4 -and $a[3] -match '^paid') } }
    $diffs = @(); foreach ($ln in (Split-Lines $f.FDiffs.Text)) { $a = @($ln -split ',' | ForEach-Object { $_.Trim() })
        $amt = [decimal]0; $ok1 = ($a.Count -ge 3) -and [decimal]::TryParse(($a[1] -replace '[\$\s]|/hr', ''), [Globalization.NumberStyles]::Number, $inv2, [ref]$amt); $af = $(if ($a.Count -ge 3) { ConvertTo-Min $a[2] } else { $null })
        if (-not $ok1 -or $null -eq $af) { $err = 'Each differential line needs: label, $/hr, start time (e.g. Evening, 2.00, 6:00 PM)'; break }
        $diffs += [ordered]@{ label = $a[0]; amount = [double]$amt; after = (Format-HHmm $af) } }
    $ded = { param([string]$text, [bool]$pre)
        $out = @(); foreach ($ln in (Split-Lines $text)) { $a = @($ln -split ',' | ForEach-Object { $_.Trim() })
            if ($a.Count -lt 2) { return $null }
            $v = $a[1]; $isPct = $v.EndsWith('%'); $num = [decimal]0
            if (-not [decimal]::TryParse(($v -replace '[\$%\s]', ''), [Globalization.NumberStyles]::Number, $inv2, [ref]$num)) { return $null }
            $o = [ordered]@{ label = $a[0]; type = $(if ($isPct) { 'pct' } else { 'amt' }); value = [double]$num }
            if ($pre) { $o.fica = ($a.Count -ge 3 -and $a[2] -match 'fica') }
            $out += $o }
        return ,$out }
    $pretax = & $ded $f.FPre.Text $true; $aftertax = & $ded $f.FAft.Text $false
    $pd = [datetime]::MinValue
    $pdOk = [datetime]::TryParse($f.FPayday.Text.Trim(), [Globalization.CultureInfo]::GetCultureInfo('en-US'), [Globalization.DateTimeStyles]::None, [ref]$pd)
    $wsSel = @(0..6 | Where-Object { $f.("FWS$_").IsChecked }); $ws = $(if ($wsSel.Count) { $wsSel[0] } else { 0 })
    $oka = 0; [void][int]::TryParse($f.FOka.Text.Trim(), [ref]$oka)
    $stPct = [decimal]0; [void][decimal]::TryParse(($f.FStPct.Text -replace '[%\s]', ''), [Globalization.NumberStyles]::Number, $inv2, [ref]$stPct)
    $wk = [decimal]0; [void][decimal]::TryParse(($f.FWknd.Text -replace '[\$\s]|/hr', ''), [Globalization.NumberStyles]::Number, $inv2, [ref]$wk)
    if (-not $err) {
        if (-not $name) { $err = 'Enter your name.' }
        elseif ($rate -le 0) { $err = 'Enter your hourly rate.' }
        elseif ($days.Count -eq 0) { $err = 'Pick at least one work day.' }
        elseif ($dayErr) { $err = $dayErr }
        elseif (-not ($f.FBrkLen.Text.Trim() -match '^\d{1,3}$') -or [int]$f.FBrkLen.Text.Trim() -lt 1 -or [int]$f.FBrkLen.Text.Trim() -gt 240) { $err = 'Break length must be a number of minutes (1-240), e.g. 15.' }
        elseif (-not ($f.FOtAfter.Text.Trim() -match '^\d{1,3}(\.\d+)?$') -or [double]$f.FOtAfter.Text.Trim() -le 0 -or [double]$f.FOtAfter.Text.Trim() -gt 168) { $err = 'Overtime hours must be a number of hours per week (e.g. 40).' }
        elseif (-not ($f.FOtMult.Text.Trim() -match '^\d(\.\d+)?$') -or [double]$f.FOtMult.Text.Trim() -lt 1 -or [double]$f.FOtMult.Text.Trim() -gt 4) { $err = 'Overtime multiplier must be between 1 and 4 (e.g. 1.5).' }
        elseif ($null -eq $pretax -or $null -eq $aftertax) { $err = 'Each deduction line needs: label, amount (e.g. 401(k), 10%  or  Stock purchase, $50).' }
        elseif (-not $pdOk) { $err = 'Enter your next payday, e.g. 9/30/2026.' }
    }
    if ($err) { return @{ Error = $err } }
    $p = [ordered]@{ name = $name; rate = [double]$rate; days = $days; start = (Format-HHmm $st); end = (Format-HHmm $en); perDay = $perDay; breakPaid = [bool]$f.FBpP.IsChecked; breakLen = $(if ($f.FBrkLen.Text.Trim() -match '^\d{1,3}$') { [int]$f.FBrkLen.Text.Trim() } else { 15 }); breaks = $breaks; diffs = $diffs
        wkndDiff = [double]$wk; wkndDays = $wdays; freq = $(if ($f.FFreqW.IsChecked) { 'weekly' } else { 'biweekly' }); weekStart = [int]$ws; nextPayday = $pd.ToString('yyyy-MM-dd', $inv2)
        fs = $(if ($f.FFsH.IsChecked) { 'hoh' } elseif ($f.FFsM.IsChecked) { 'mfj' } else { 'single' }); st = $(if ($f.FStOk.IsChecked) { 'ok' } elseif ($f.FStFlat.IsChecked) { 'flat' } else { 'none' })
        oka = $oka; stPct = [double]$stPct; pretax = @($pretax); aftertax = @($aftertax)
        otOn = [bool]$f.FOtOn.IsChecked; otAfter = $(try { [double]$f.FOtAfter.Text.Trim() } catch { 40 }); otMult = $(try { [double]$f.FOtMult.Text.Trim() } catch { 1.5 }) }
    return @{ Profile = $p }
}
function New-SettingsWindow([bool]$first) {
    $days7 = 'Sun','Mon','Tue','Wed','Thu','Fri','Sat'
    $chk = { param($pfx) (0..6 | ForEach-Object { '<CheckBox x:Name="' + $pfx + $_ + '" Content="' + $days7[$_] + '"/>' }) -join '' }
    $rad = (0..6 | ForEach-Object { '<RadioButton x:Name="FWS' + $_ + '" GroupName="ws" Content="' + $days7[$_] + '"/>' }) -join ''
    $sx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Paycheck settings" Width="392" Height="690" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ResizeMode="NoResize" ShowInTaskbar="True" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI">
  <Window.Resources>
    <Style x:Key="L" TargetType="TextBlock"><Setter Property="Foreground" Value="#FFAAAAAA"/><Setter Property="FontSize" Value="11"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,8,0,2"/><Setter Property="TextWrapping" Value="Wrap"/></Style>
    <Style x:Key="H" TargetType="TextBlock"><Setter Property="Foreground" Value="#FFE82127"/><Setter Property="FontSize" Value="11"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="Margin" Value="0,14,0,0"/></Style>
    <Style x:Key="Hint" TargetType="TextBlock"><Setter Property="Foreground" Value="#FF666666"/><Setter Property="FontSize" Value="9.5"/><Setter Property="Margin" Value="0,2,0,0"/><Setter Property="TextWrapping" Value="Wrap"/></Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#FF0D0D0D"/><Setter Property="Foreground" Value="#FFFFFFFF"/><Setter Property="BorderBrush" Value="#FF333333"/><Setter Property="Padding" Value="5,3"/><Setter Property="FontSize" Value="12"/><Setter Property="CaretBrush" Value="#FFFFFFFF"/></Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#FFCCCCCC"/><Setter Property="Margin" Value="0,2,9,2"/><Setter Property="FontSize" Value="11"/></Style>
    <Style TargetType="RadioButton"><Setter Property="Foreground" Value="#FFCCCCCC"/><Setter Property="Margin" Value="0,2,9,2"/><Setter Property="FontSize" Value="11"/></Style>
    <ControlTemplate x:Key="Btn" TargetType="Button"><Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="7" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
      <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger></ControlTemplate.Triggers></ControlTemplate>
  </Window.Resources>
  <Border x:Name="SRoot" Background="#FF151515" BorderBrush="#FF3A3A3A" BorderThickness="1" CornerRadius="10">
    <DockPanel>
      <Border x:Name="SBar" DockPanel.Dock="Top" Background="#FF101010" Height="32" CornerRadius="10,10,0,0" Cursor="SizeAll">
        <Grid Margin="14,0,8,0"><TextBlock x:Name="STitle" Foreground="#FFE82127" FontSize="12.5" FontWeight="Bold" VerticalAlignment="Center"/>
          <Button x:Name="SClose" Content="&#x2715;" HorizontalAlignment="Right" Width="24" Height="24" Background="Transparent" Foreground="#FF888888" BorderThickness="0" Cursor="Hand"/></Grid>
      </Border>
      <StackPanel DockPanel.Dock="Bottom" Margin="14,6,14,12">
        <TextBlock x:Name="SErr" Foreground="#FFFF6B6B" FontSize="11" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,0,0,6"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="SCancel" Template="{StaticResource Btn}" Background="#FF2A2A2A" Padding="16,7" Cursor="Hand"><TextBlock Text="Cancel" Foreground="#FFFFFFFF" FontWeight="SemiBold"/></Button>
          <Button x:Name="SSave" Template="{StaticResource Btn}" Background="#FF1F9D45" Padding="20,7" Margin="8,0,0,0" Cursor="Hand"><TextBlock x:Name="SSaveTxt" Text="Save" Foreground="#FFFFFFFF" FontWeight="Bold"/></Button>
        </StackPanel>
      </StackPanel>
      <ScrollViewer x:Name="SScroll" VerticalScrollBarVisibility="Auto" Padding="14,2,10,4">
        <StackPanel x:Name="SPanel">
          <TextBlock x:Name="SIntro" Foreground="#FF888888" FontSize="10.5" TextWrapping="Wrap" Margin="0,6,0,0"/>
          <TextBlock Style="{StaticResource L}" Text="Your name"/><TextBox x:Name="FName"/>
          <TextBlock Style="{StaticResource H}" Text="PAY &amp; SCHEDULE"/>
          <TextBlock Style="{StaticResource L}" Text="Hourly rate ($/hr)"/><TextBox x:Name="FRate"/>
          <TextBlock Style="{StaticResource L}" Text="Weekly schedule (check the days you work; unchecked = day off)"/>
__WEEK__
          <TextBlock x:Name="FOff" Style="{StaticResource Hint}"/>
          <TextBlock Style="{StaticResource L}" Text="Lunch &amp; breaks (one per line: label, start, end, paid or unpaid)"/>
          <TextBox x:Name="FBreaks" AcceptsReturn="True" Height="46" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto"/>
          <TextBlock Style="{StaticResource L}" Text="Extra breaks you clock with START / END BREAK are"/>
          <WrapPanel><RadioButton x:Name="FBpP" GroupName="bp" Content="Paid (keep earning)"/><RadioButton x:Name="FBpU" GroupName="bp" Content="Unpaid (pay stops)"/></WrapPanel>
          <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition/></Grid.ColumnDefinitions>
            <StackPanel><TextBlock Style="{StaticResource L}" Text="Break length (min)"/><TextBox x:Name="FBrkLen"/></StackPanel>
            <TextBlock Grid.Column="1" Style="{StaticResource Hint}" VerticalAlignment="Bottom" Margin="10,0,0,4" Text="Used for BE BACK BY after START BREAK. Lunch uses your lunch length above."/></Grid>
          <TextBlock Style="{StaticResource L}" Text="Shift differentials (one per line: label, +$/hr, starts at)"/>
          <TextBox x:Name="FDiffs" AcceptsReturn="True" Height="46" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto"/>
          <TextBlock Style="{StaticResource Hint}" Text="Each differential adds its $/hr to every minute worked after its start time. They stack."/>
          <TextBlock Style="{StaticResource L}" Text="Weekend differential (+$/hr) and weekend days"/>
          <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="70"/><ColumnDefinition/></Grid.ColumnDefinitions><TextBox x:Name="FWknd"/><WrapPanel Grid.Column="1" Margin="10,0,0,0">__WDAYS__</WrapPanel></Grid>
          <TextBlock Style="{StaticResource L}" Text="Overtime"/>
          <WrapPanel><CheckBox x:Name="FOtOn" Content="Overtime: after" VerticalAlignment="Center"/><TextBox x:Name="FOtAfter" Width="40" Margin="6,0,4,0"/><TextBlock Text="hrs/week at" VerticalAlignment="Center"/><TextBox x:Name="FOtMult" Width="40" Margin="6,0,4,0"/><TextBlock Text="x" VerticalAlignment="Center"/></WrapPanel>
          <TextBlock Style="{StaticResource Hint}" Text="Paid hours past the limit in each workweek (starts on your pay-week start day) pay this multiple of base + any shift differential. Default 40 hrs at 1.5x (federal FLSA)."/>
          <TextBlock Style="{StaticResource H}" Text="PAYDAY"/>
          <TextBlock Style="{StaticResource L}" Text="Pay frequency"/>
          <WrapPanel><RadioButton x:Name="FFreqW" GroupName="freq" Content="Weekly"/><RadioButton x:Name="FFreqB" GroupName="freq" Content="Every 2 weeks"/></WrapPanel>
          <TextBlock Style="{StaticResource L}" Text="Pay week starts on"/><WrapPanel>__WS__</WrapPanel>
          <TextBlock Style="{StaticResource L}" Text="Next payday (M/D/YYYY)"/><TextBox x:Name="FPayday"/>
          <TextBlock x:Name="FCover" Style="{StaticResource Hint}"/>
          <TextBlock Style="{StaticResource H}" Text="TAXES &amp; DEDUCTIONS"/>
          <TextBlock Style="{StaticResource L}" Text="Federal filing status"/>
          <WrapPanel><RadioButton x:Name="FFsS" GroupName="fs" Content="Single"/><RadioButton x:Name="FFsH" GroupName="fs" Content="Head of household"/><RadioButton x:Name="FFsM" GroupName="fs" Content="Married jointly"/></WrapPanel>
          <TextBlock Style="{StaticResource L}" Text="State income tax"/>
          <WrapPanel><RadioButton x:Name="FStOk" GroupName="st" Content="Oklahoma"/><RadioButton x:Name="FStNone" GroupName="st" Content="None"/><RadioButton x:Name="FStFlat" GroupName="st" Content="Other (flat %)"/></WrapPanel>
          <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="10"/><ColumnDefinition/></Grid.ColumnDefinitions>
            <StackPanel><TextBlock Style="{StaticResource L}" Text="OK-W-4 allowances"/><TextBox x:Name="FOka"/></StackPanel>
            <StackPanel Grid.Column="2"><TextBlock Style="{StaticResource L}" Text="Other state: % withheld"/><TextBox x:Name="FStPct"/></StackPanel></Grid>
          <TextBlock Style="{StaticResource L}" Text="Pre-tax deductions (one per line: label, 10% or $25; add &quot;, fica&quot; if it also lowers SS/Medicare, e.g. health insurance)"/>
          <TextBox x:Name="FPre" AcceptsReturn="True" Height="46" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto"/>
          <TextBlock Style="{StaticResource L}" Text="After-tax deductions (one per line: label, $50 or 5%; e.g. stock purchase, Roth)"/>
          <TextBox x:Name="FAft" AcceptsReturn="True" Height="46" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto"/>
          <StackPanel x:Name="SAppBox">
            <TextBlock Style="{StaticResource H}" Text="APP &amp; SHARING"/>
            <TextBlock x:Name="SRelease" Foreground="#FFFFFFFF" FontSize="12" FontWeight="Bold" TextWrapping="Wrap" Margin="0,4,0,0"/>
            <TextBlock x:Name="SAppInfo" Foreground="#FF999999" FontSize="10.5" TextWrapping="Wrap" Margin="0,2,0,0"/>
            <Button x:Name="SShare" Template="{StaticResource Btn}" Background="#FF2A2A2A" Padding="10,8" Margin="0,7,0,4" Cursor="Hand">
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Center"><TextBlock Text="&#xE72D;" FontFamily="Segoe MDL2 Assets" Foreground="#FFFFFFFF" FontSize="13" VerticalAlignment="Center"/>
                <TextBlock Text="  Share Paycheck Live" Foreground="#FFFFFFFF" FontWeight="Bold" FontSize="12.5" VerticalAlignment="Center"/></StackPanel>
            </Button>
          </StackPanel>
          <StackPanel x:Name="SSupport">
            <TextBlock Style="{StaticResource H}" Text="SUPPORT THE CREATOR"/>
            <TextBlock Foreground="#FFAAAAAA" FontSize="11" TextWrapping="Wrap" Margin="0,3,0,0"><Run Text="Paycheck Live is free. If it helps you, a "/><Run Text="$1" Foreground="#FFFFFFFF" FontWeight="Bold"/><Run Text=" tip is appreciated, totally optional."/></TextBlock>
            <Grid Margin="0,7,0,4"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/><ColumnDefinition x:Name="CashCol" Width="0"/></Grid.ColumnDefinitions>
              <Button x:Name="DVenmo" Template="{StaticResource Btn}" Background="#FF008CFF" Padding="6,7" Cursor="Hand"><StackPanel><TextBlock Text="Venmo" Foreground="#FFFFFFFF" FontWeight="Bold" FontSize="13" HorizontalAlignment="Center"/><TextBlock Text="suggested $1" Foreground="#FFE6F3FF" FontSize="9.5" HorizontalAlignment="Center"/></StackPanel></Button>
              <Button x:Name="DPaypal" Grid.Column="2" Template="{StaticResource Btn}" Background="#FF003087" Padding="6,7" Cursor="Hand"><StackPanel><TextBlock Text="PayPal" Foreground="#FFFFFFFF" FontWeight="Bold" FontSize="13" HorizontalAlignment="Center"/><TextBlock Text="$1" Foreground="#FFDDE6FF" FontSize="9.5" HorizontalAlignment="Center"/></StackPanel></Button>
            </Grid>
          </StackPanel>
        </StackPanel>
      </ScrollViewer>
    </DockPanel>
  </Border>
</Window>
'@
    $week = (0..6 | ForEach-Object { '<Grid Margin="0,1,0,1"><Grid.ColumnDefinitions><ColumnDefinition Width="62"/><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/></Grid.ColumnDefinitions>' +
        '<CheckBox x:Name="FD' + $_ + '" Content="' + $days7[$_] + '" VerticalAlignment="Center"/><TextBox x:Name="FS' + $_ + '" Grid.Column="1"/><TextBox x:Name="FE' + $_ + '" Grid.Column="3"/>' +
        '<TextBlock x:Name="FX' + $_ + '" Grid.Column="1" Grid.ColumnSpan="3" Text="Day off" Foreground="#FF555555" FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center" Margin="4,0,0,0"/></Grid>' }) -join "`n"
    $sx = $sx.Replace('__WEEK__', $week).Replace('__WDAYS__', (& $chk 'FW')).Replace('__WS__', $rad)
    $w = [Windows.Markup.XamlReader]::Parse($sx)
    $f = @{ Window = $w }
    foreach ($n in 'SRoot','SBar','STitle','SClose','SErr','SCancel','SSave','SSaveTxt','SScroll','SPanel','SIntro','FName','FRate','FStart','FEnd','FBreaks','FDiffs','FWknd','FFreqW','FFreqB','FPayday','FCover',
                   'FFsS','FFsH','FFsM','FStOk','FStNone','FStFlat','FOka','FStPct','FPre','FAft','SSupport','DVenmo','DPaypal','SAppBox','SRelease','SAppInfo','SShare','FOff','FBpP','FBpU','FBrkLen','FOtOn','FOtAfter','FOtMult') { $f[$n] = $w.FindName($n) }
    foreach ($i in 0..6) { foreach ($pfx in 'FD','FW','FWS','FS','FE','FX') { $f["$pfx$i"] = $w.FindName("$pfx$i") } }
    # fill from the current profile (Van's copies: his profile)
    $p = $script:Profile
    $f.STitle.Text = $(if ($first) { 'WELCOME ' + [char]0x2014 + ' SET UP PAYCHECK LIVE' } else { 'SETTINGS ' + [char]0x00B7 + ' PROFILE' })
    $f.SIntro.Text = $(if ($first) { 'Everything the math needs. Change any of it later with the gear button. Your profile stays on this PC; only your name and version go to the Users list.' } else { 'Edit your pay, schedule, taxes and deductions. Changes apply right away.' })
    $f.SSaveTxt.Text = $(if ($first) { 'Save & start' } else { 'Save' })
    # v2.0.0 release channel + share
    try {
        $f.SRelease.Text = 'Release channel: ' + $(if ($ReleaseRole -eq 'master') { 'MASTER (this PC)' } elseif ($TestMode) { 'TEST' } else { 'LIVE' })
        $f.SAppInfo.Text = $(if ($ReleaseRole -eq 'master') { 'This desktop is the main development / release copy. Other installs and phones update from its releases.' } else { 'Updates come from DESIGN BY VAN releases (UPDATE button / pop-up).' }) +
            "`nv" + $AppVersion + $(if ($AppMode) { ' ' + [char]0x00B7 + ' app ' + $HostVersion + ' ' + [char]0x00B7 + ' data: ' + $dataDir } else { ' ' + [char]0x00B7 + ' script ' + $PSCommandPath })
        $f.SShare.Add_Click({ Show-ShareSheet $w }.GetNewClosure())
        if ($first) { $f.SAppBox.Visibility = [System.Windows.Visibility]::Collapsed }
    } catch {}
    $f.FName.Text = $(if ($first -and -not $script:Inst.name -and $p.name -eq 'Van' -and $env:USERNAME -notmatch 'van') { '' } elseif ($script:Inst.name -and $first) { [string]$script:Inst.name } else { [string]$p.name })
    $f.FRate.Text = (Format-Amt ([decimal]$p.rate))
    foreach ($i in 0..6) { $f["FD$i"].IsChecked = (@($p.days) -contains $i); $f["FW$i"].IsChecked = (@($p.wkndDays) -contains $i); $f["FWS$i"].IsChecked = ([int]$p.weekStart -eq $i)
        $pdx = $null; if ($p.PSObject.Properties['perDay'] -and $p.perDay -and $p.perDay.PSObject.Properties[[string]$i]) { $pdx = $p.perDay.([string]$i) }
        $f["FS$i"].Text = Format-Clock (ConvertTo-Min $(if ($pdx) { $pdx.start } else { $p.start })); $f["FE$i"].Text = Format-Clock (ConvertTo-Min $(if ($pdx) { $pdx.end } else { $p.end })) }
    $bp = $(if ($p.PSObject.Properties['breakPaid'] -and $null -ne $p.breakPaid) { [bool]$p.breakPaid } else { $true }); $f.FBpP.IsChecked = $bp; $f.FBpU.IsChecked = (-not $bp)
    $f.FOtOn.IsChecked = $(if ($p.PSObject.Properties['otOn'] -and $null -ne $p.otOn) { [bool]$p.otOn } else { $true })
    $f.FOtAfter.Text = $(if ($p.PSObject.Properties['otAfter'] -and $p.otAfter) { ([double]$p.otAfter).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) } else { '40' })
    $f.FOtMult.Text = $(if ($p.PSObject.Properties['otMult'] -and $p.otMult) { ([double]$p.otMult).ToString('0.0#', [Globalization.CultureInfo]::InvariantCulture) } else { '1.5' })
    $f.FBrkLen.Text = $(if ($p.PSObject.Properties['breakLen'] -and $p.breakLen) { [string][int]$p.breakLen } else { '15' })
    $offUpd = { $off = @(0..6 | Where-Object { -not $f["FD$_"].IsChecked } | ForEach-Object { $days7[$_] })
        foreach ($i in 0..6) { $on = [bool]$f["FD$i"].IsChecked; $vis = $(if ($on) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Hidden })
            $f["FS$i"].Visibility = $vis; $f["FE$i"].Visibility = $vis; $f["FX$i"].Visibility = $(if ($on) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }) }
        $f.FOff.Text = 'Days off: ' + $(if ($off.Count) { $off -join ', ' } else { 'none' }) }
    & $offUpd
    foreach ($i in 0..6) { $f["FD$i"].Add_Checked($offUpd); $f["FD$i"].Add_Unchecked($offUpd) }
    $f.FBreaks.Text = Format-BreakLines $p; $f.FDiffs.Text = Format-DiffLines $p; $f.FWknd.Text = (Format-Amt ([decimal]$p.wkndDiff))
    $f.FFreqW.IsChecked = ($p.freq -eq 'weekly'); $f.FFreqB.IsChecked = ($p.freq -ne 'weekly')
    $pd0 = [datetime]::MinValue; if ([datetime]::TryParseExact([string]$p.nextPayday, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$pd0)) { $f.FPayday.Text = $pd0.ToString('M/d/yyyy', [Globalization.CultureInfo]::InvariantCulture) }
    $f.FFsS.IsChecked = ($p.fs -ne 'hoh' -and $p.fs -ne 'mfj'); $f.FFsH.IsChecked = ($p.fs -eq 'hoh'); $f.FFsM.IsChecked = ($p.fs -eq 'mfj')
    $f.FStOk.IsChecked = ($p.st -eq 'ok'); $f.FStFlat.IsChecked = ($p.st -eq 'flat'); $f.FStNone.IsChecked = ($p.st -ne 'ok' -and $p.st -ne 'flat')
    $f.FOka.Text = [string]$p.oka; $f.FStPct.Text = (Format-Amt ([decimal]$p.stPct))
    $f.FPre.Text = Format-DedLines $p.pretax $true; $f.FAft.Text = Format-DedLines $p.aftertax $false
    if ($first) {   # v2.0.13: first-run setup starts completely blank (no pay rate, hours, breaks, deductions or personal settings)
        $f.FName.Text = ''; $f.FRate.Text = ''; $f.FWknd.Text = ''; $f.FBreaks.Text = ''; $f.FDiffs.Text = ''; $f.FPre.Text = ''; $f.FAft.Text = ''; $f.FPayday.Text = ''
        foreach ($i in 0..6) { $f["FD$i"].IsChecked = $false; $f["FS$i"].Text = ''; $f["FE$i"].Text = '' }
        $f.FFsS.IsChecked = $true; $f.FFsH.IsChecked = $false; $f.FFsM.IsChecked = $false; $f.FStNone.IsChecked = $true; $f.FStOk.IsChecked = $false; $f.FStFlat.IsChecked = $false
        & $offUpd
    }
    $f.SSupport.Visibility = $(if ($first) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible })
    $upd = { $r = Read-SettingsForm $f
        if ($r.Profile) { try { $pp = $r.Profile; $pdx = [datetime]::ParseExact($pp.nextPayday, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            $we = ($pp.weekStart + 6) % 7; $pe = $pdx.AddDays(-1); while ([int]$pe.DayOfWeek -ne $we) { $pe = $pe.AddDays(-1) }
            $len = $(if ($pp.freq -eq 'weekly') { 7 } else { 14 }); $ps2 = $pe.AddDays(-($len - 1))
            $f.FCover.Text = 'That check covers ' + $ps2.ToString('ddd M/d', [Globalization.CultureInfo]::InvariantCulture) + ' ' + [char]0x2013 + ' ' + $pe.ToString('ddd M/d', [Globalization.CultureInfo]::InvariantCulture) + ' (then every ' + $(if ($len -eq 7) { 'week' } else { '2 weeks' }) + ')' } catch { $f.FCover.Text = '' } }
        else { $f.FCover.Text = '' } }
    & $upd
    $f.FPayday.Add_TextChanged($upd); foreach ($i in 0..6) { $f["FWS$i"].Add_Checked($upd) }; $f.FFreqW.Add_Checked($upd); $f.FFreqB.Add_Checked($upd)
    $f.DVenmo.Add_Click({ Open-Url $DonateVenmo }); $f.DPaypal.Add_Click({ Open-Url $DonatePaypal })
    $f.SBar.Add_MouseLeftButtonDown({ param($s0, $e0) try { [System.Windows.Window]::GetWindow($s0).DragMove() } catch {} })
    return $f
}
function Save-ProfileFile($p) {
    try { [IO.File]::WriteAllText($profilePath, (Get-ProfileJson $p), (New-Object Text.UTF8Encoding $false)); return $true } catch { return $false }
}
# Shows the settings window (modal). $first = first-run setup. Returns $true when saved.
function Show-Settings([bool]$first) {
    $f = New-SettingsWindow $first
    $w = $f.Window
    if (-not $first) { try { $w.Owner = $window } catch {} }
    elseif ($wa) {   # v1.12.0: first-run / installer-preview wizard opens on the widget display (not wherever the mouse is)
        try { $w.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
              if ($InstallerPreview) { $w.Left = $wa.Right - 1281; $w.Top = $wa.Top + 42; $w.Title = 'Paycheck Live INSTALLER PREVIEW - setup' } else { $w.Left = $wa.Left + [math]::Max(0, ($wa.Width - $w.Width) / 2); $w.Top = $wa.Top + [math]::Max(0, ($wa.Height - $w.Height) / 2) } } catch {} }
    $script:SettingsSaved = $false
    $f.SSave.Add_Click({
        $r = Read-SettingsForm $f
        if ($r.Error) { $f.SErr.Text = $r.Error; return }
        $pj = ($r.Profile | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
        if (-not (Save-ProfileFile $r.Profile)) { $f.SErr.Text = 'Could not save profile.json next to the widget.'; return }
        Set-Profile $pj
        $script:SettingsSaved = $true; $w.Close()
    })
    $cancel = { $w.Close() }
    $f.SCancel.Add_Click($cancel); $f.SClose.Add_Click($cancel)
    if ($first) { $f.SCancel.Visibility = [System.Windows.Visibility]::Collapsed }
    [void]$w.ShowDialog()
    return $script:SettingsSaved
}

# ---------------------------------------------------------------- UI
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$titleText = $(if ($TestMode) { 'PAYCHECK TEST' } else { 'PAYCHECK LIVE' })
$winTitle = $(if ($InstallerPreview) { 'Paycheck Live INSTALLER PREVIEW' } else { $titleText })

$dayRows = ''
for ($i = 0; $i -lt 14; $i++) {
    $dayRows += @"
            <Border x:Name="DL$i" CornerRadius="3" Padding="3,0,3,0" Height="11.25">
              <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="58"/><ColumnDefinition Width="44"/><ColumnDefinition Width="74"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock x:Name="DL${i}Name" Text="-" Foreground="#FFAAAAAA" FontFamily="Segoe UI" FontSize="10" VerticalAlignment="Center"/>
                <TextBlock x:Name="DL${i}Note" Grid.Column="1" Grid.ColumnSpan="2" Text="" Foreground="#FF555555" FontFamily="Segoe UI" FontSize="8" Margin="2,0,2,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                <TextBlock x:Name="DL${i}Diff" Grid.Column="1" Text="" Foreground="#FFFFB020" FontFamily="Segoe UI" FontSize="9" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                <TextBlock x:Name="DL${i}OT" Grid.Column="2" Text="" Foreground="#FFFF7A45" FontFamily="Segoe UI" FontSize="9" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                <TextBlock x:Name="DL${i}Amt" Grid.Column="1" Grid.ColumnSpan="3" Text="-" Foreground="#FFFFFFFF" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold" HorizontalAlignment="Right" VerticalAlignment="Center"/>
              </Grid>
            </Border>

"@
    if ($i -eq 6 -or $i -eq 13) { $k = [int](($i + 1) / 7) - 1
        $dayRows += @"
            <Border x:Name="WS$k" BorderBrush="#FF2A2A2A" BorderThickness="0,1,0,0" Margin="0,0,0,1" Padding="3,0,3,0">
              <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="58"/><ColumnDefinition Width="44"/><ColumnDefinition Width="74"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock x:Name="WS${k}Lab" Text="" Foreground="#FFAAAAAA" FontFamily="Segoe UI" FontSize="9" FontWeight="Bold" VerticalAlignment="Center"/>
                <TextBlock x:Name="WS${k}Diff" Grid.Column="1" Text="" Foreground="#FFFFB020" FontFamily="Segoe UI" FontSize="9" FontWeight="Bold" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                <TextBlock x:Name="WS${k}OT" Grid.Column="2" Text="" Foreground="#FFFF7A45" FontFamily="Segoe UI" FontSize="9" FontWeight="Bold" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                <TextBlock x:Name="WS${k}Amt" Grid.Column="3" Text="" Foreground="#FFCCCCCC" FontFamily="Segoe UI" FontSize="10" FontWeight="Bold" HorizontalAlignment="Right"/></Grid>
            </Border>

"@ }
}
# v1.12.0 manual clock buttons; v1.15.0: big 2-column buttons + BREAK 1 / BREAK 2
# v2.0.10 labels: BREAK 1 / BREAK 1 BACK, LUNCH START / LUNCH BACK, BREAK 2 / BREAK 2 BACK; CLOCK OUT red
$pbDefs = @(@('in','CLOCK IN','#FF2FBF5A','#FF0F3B1D'), @('lo','LUNCH START','#FFFFB020','#FF33270A'), @('li','LUNCH BACK','#FFFFB020','#FF33270A'), @('out','CLOCK OUT','#FFFF4D55','#FFB3141C'),
            @('bs1','BREAK 1','#FFFFB020','#FF33270A'), @('bs2','BREAK 2','#FFFFB020','#FF33270A'), @('be1','BREAK 1 BACK','#FFFFB020','#FF33270A'), @('be2','BREAK 2 BACK','#FFFFB020','#FF33270A'))
$pb = @{}
foreach ($d in $pbDefs) { $pb[$d[0]] = @"

<Button x:Name="PB_$($d[0])" Template="{StaticResource PunchBtn}" Background="$($d[3])" BorderBrush="$($d[2])" BorderThickness="1.5" Margin="3,2,3,2" Height="35" Cursor="Hand" ToolTip="Record the current time as $($d[1].ToLower()) for today">
  <StackPanel VerticalAlignment="Center"><TextBlock x:Name="PL_$($d[0])" Text="$($d[1])" Foreground="#FFFFFFFF" FontFamily="Segoe UI" FontSize="10.5" FontWeight="Black" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis"/>
  <TextBlock x:Name="PT_$($d[0])" Text="" Foreground="#FFCFCFCF" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,-1,0,0"/></StackPanel>
</Button>
"@ }

$TLMax = 7
$tlRows = ''
for ($i = 0; $i -lt $TLMax; $i++) {
    $tlRows += @"
          <Border x:Name="TL$i" CornerRadius="4" Padding="3,0,3,0" Height="14" Visibility="Collapsed">
            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="12"/><ColumnDefinition Width="84"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <Ellipse x:Name="TL${i}Dot" Width="7" Height="7" Fill="#FF333333" Stroke="#FF555555" StrokeThickness="1" HorizontalAlignment="Left" VerticalAlignment="Center"/>
              <TextBlock x:Name="TL${i}Time" Grid.Column="1" Text="" FontFamily="Segoe UI" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
              <TextBlock x:Name="TL${i}Lab" Grid.Column="2" Text="" FontFamily="Segoe UI" FontSize="10.5" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
              <TextBlock x:Name="TL${i}X" Grid.Column="3" Text="" Foreground="#FF555555" FontFamily="Segoe UI" FontSize="8.5" VerticalAlignment="Center"/>
            </Grid>
          </Border>

"@
}

$tileDefs = @(
    @{ Key = 'Last'; Label = 'Last paycheck';  Row = 0; Col = 0 },
    @{ Key = 'D30';  Label = '30 days';        Row = 0; Col = 1 },
    @{ Key = 'M3';   Label = '3 months';       Row = 0; Col = 2 },
    @{ Key = 'M6';   Label = '6 months';       Row = 1; Col = 0 },
    @{ Key = 'Y1';   Label = 'Yearly (12 mo)'; Row = 1; Col = 1 },
    @{ Key = 'YTD';  Label = 'Year to date';   Row = 1; Col = 2 }
)
$tiles = ''
foreach ($t in $tileDefs) {
    $m = if ($t.Col -eq 0) { '0,0,3,3' } elseif ($t.Col -eq 1) { '3,0,3,3' } else { '3,0,0,3' }
    $tiles += @"
          <Border Grid.Row="$($t.Row)" Grid.Column="$($t.Col)" Background="#FF141414" BorderBrush="#FF222222" BorderThickness="1" CornerRadius="6" Padding="6,1,6,1" Margin="$m">
            <StackPanel>
              <Grid><TextBlock Text="$($t.Label)" Foreground="#FF888888" FontFamily="Segoe UI" FontSize="8.5"/>
              <TextBlock x:Name="T$($t.Key)Sub" Text="" Foreground="#FF555555" FontFamily="Segoe UI" FontSize="8" HorizontalAlignment="Right"/></Grid>
              <TextBlock x:Name="T$($t.Key)Val" Text="-" Foreground="#FFFFFFFF" FontFamily="Segoe UI" FontSize="11.5" FontWeight="SemiBold" Margin="0,-2,0,0"/>
            </StackPanel>
          </Border>
"@
}

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="__WINTITLE__"
        Width="__W__" Height="__H__"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ResizeMode="NoResize" ShowInTaskbar="True" WindowStartupLocation="Manual">
  <Window.Resources>
    <ControlTemplate x:Key="PillBtn" TargetType="Button">
      <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="5">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.65"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <ControlTemplate x:Key="PunchBtn" TargetType="Button">
      <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7" Padding="1,1,1,1">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.6"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.35"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
  </Window.Resources>
  <Border x:Name="Root" Background="#FF0B0B0B" BorderBrush="#FF333333" BorderThickness="1" CornerRadius="10" Padding="0">
    <DockPanel LastChildFill="True">
      <Border x:Name="TitleBar" DockPanel.Dock="Top" Background="#FF141414" Height="28" Cursor="SizeAll" CornerRadius="10,10,0,0">
        <Grid Margin="10,0,6,0">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
            <TextBlock Text="__TITLE__" Foreground="#FFE82127" FontFamily="Segoe UI" FontSize="11" FontWeight="Bold" VerticalAlignment="Center"/>
            <Button x:Name="GearBtn" Template="{StaticResource PillBtn}" Background="#01000000" Width="24" Height="24" Margin="3,0,0,0" Cursor="Hand" ToolTip="Settings / profile">
              <TextBlock Text="&#x2699;" Foreground="#FFBBBBBB" FontFamily="Segoe UI Symbol" FontSize="14" Margin="0,-2,0,0"/>
            </Button>
            <Button x:Name="ShareBtn" Template="{StaticResource PillBtn}" Background="#01000000" Width="24" Height="24" Margin="0,0,0,0" Cursor="Hand" ToolTip="Share Paycheck Live (Messenger, text, email, phone)">
              <TextBlock Text="&#xE72D;" Foreground="#FFBBBBBB" FontFamily="Segoe MDL2 Assets" FontSize="12.5"/>
            </Button>
          </StackPanel>
          <TextBlock x:Name="SimTag" Text="" Foreground="#FFFFB020" FontFamily="Segoe UI" FontSize="9" FontWeight="Bold" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="0,0,70,0"/>
          <Button x:Name="ToggleBtn" Template="{StaticResource PillBtn}" Background="#FFE82127" Width="38" Height="18" HorizontalAlignment="Right" Margin="0,0,27,0" Cursor="Hand" ToolTip="Display ON/OFF (OFF blurs the numbers)">
            <TextBlock x:Name="ToggleTxt" Text="ON" Foreground="#FFFFFFFF" FontFamily="Segoe UI" FontSize="9.5" FontWeight="Bold"/>
          </Button>
          <Button x:Name="CloseBtn" Content="&#x2715;" HorizontalAlignment="Right" Width="22" Height="22"
                  Background="Transparent" Foreground="#FF888888" BorderThickness="0" FontSize="11" Cursor="Hand" ToolTip="Close"/>
        </Grid>
      </Border>

      <!-- v1.6.0: DESIGN BY VAN footer (stays sharp when the display is OFF) -->
      <StackPanel x:Name="FootPanel" DockPanel.Dock="Bottom" Margin="0,0,0,7" HorizontalAlignment="Center">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
          <TextBlock Text="&#x25C6;" Foreground="#FFD0282E" FontSize="7" VerticalAlignment="Center" Margin="0,0,7,0"/>
          <TextBlock Text="D&#x200A;E&#x200A;S&#x200A;I&#x200A;G&#x200A;N&#x2002;B&#x200A;Y&#x2002;V&#x200A;A&#x200A;N" FontFamily="Impact, Bahnschrift SemiBold Condensed, Arial Black" FontSize="15" VerticalAlignment="Center">
            <TextBlock.Foreground>
              <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                <GradientStop Color="#FFFFFFFF" Offset="0"/><GradientStop Color="#FFC9C9C9" Offset="0.38"/><GradientStop Color="#FF7C7C7C" Offset="0.52"/>
                <GradientStop Color="#FFE6E6E6" Offset="0.7"/><GradientStop Color="#FF9A9A9A" Offset="1"/>
              </LinearGradientBrush>
            </TextBlock.Foreground>
          </TextBlock>
          <TextBlock Text="&#x25C6;" Foreground="#FFD0282E" FontSize="7" VerticalAlignment="Center" Margin="7,0,0,0"/>
        </StackPanel>
        <Border Height="1.5" Background="#FFD0282E" Margin="6,1,6,0"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,2,0,0">
          <TextBlock x:Name="VersionText" Text="v__VER__ &#183; UPDATED __VUPD__" Foreground="#FFA8A8A8" FontFamily="Segoe UI" FontSize="9.5" FontWeight="SemiBold" VerticalAlignment="Center" Cursor="Hand" ToolTip="__PNAME__ v__VER__ - show version history"/>
          <Button x:Name="UpdateBtn" Template="{StaticResource PillBtn}" Background="#FF222222" Height="15" Margin="7,0,0,0" Padding="0" Cursor="Hand" ToolTip="Check for updates">
            <TextBlock x:Name="UpdateTxt" Text="UPDATE" Foreground="#FF777777" FontFamily="Segoe UI" FontSize="8" FontWeight="Bold" Margin="7,0,7,0"/>
          </Button>
        </StackPanel>
        <TextBlock x:Name="TipRow" HorizontalAlignment="Center" FontFamily="Segoe UI" FontSize="8" Foreground="#FF555555" Margin="0,2,0,0"><Run Text="&#x2665; Support the creator ($1): "/><Hyperlink x:Name="TipVenmo" Foreground="#FF8A8A8A" TextDecorations="None" Cursor="Hand" ToolTip="Venmo @VanWidick (suggested $1)">Venmo</Hyperlink><Run Text=" &#183; "/><Hyperlink x:Name="TipPaypal" Foreground="#FF8A8A8A" TextDecorations="None" Cursor="Hand" ToolTip="PayPal.me/VanWidick ($1)">PayPal</Hyperlink></TextBlock>
      </StackPanel>

      <Grid x:Name="ContentGrid" Margin="16,8,16,4">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0">
          <TextBlock x:Name="DateLabel" Text="-" Foreground="#FF888888" FontFamily="Segoe UI" FontSize="11" VerticalAlignment="Center"/>
          <StackPanel x:Name="TestControls" Orientation="Horizontal" HorizontalAlignment="Right" Visibility="Collapsed">
            <Button x:Name="StartBtn" Template="{StaticResource PillBtn}" Background="#FF1F9D45" Width="46" Height="20" Cursor="Hand" ToolTip="Reset to the first shift of the week and start">
              <TextBlock Text="START" Foreground="#FFFFFFFF" FontFamily="Segoe UI" FontSize="10" FontWeight="Bold"/>
            </Button>
            <Button x:Name="StopBtn" Template="{StaticResource PillBtn}" Background="#FFD0282E" Width="40" Height="20" Margin="3,0,0,0" Cursor="Hand" ToolTip="Freeze">
              <TextBlock Text="STOP" Foreground="#FFFFFFFF" FontFamily="Segoe UI" FontSize="10" FontWeight="Bold"/>
            </Button>
            <Button x:Name="FfwdBtn" Template="{StaticResource PillBtn}" Background="#FF3A3A3A" Width="34" Height="20" Margin="3,0,0,0" Cursor="Hand" ToolTip="Fast-forward the simulated clock 5 minutes (right-click: +15 min, +1 hour, +1 day)">
              <TextBlock Text="+5m" Foreground="#FFFFFFFF" FontFamily="Segoe UI" FontSize="10" FontWeight="Bold"/>
            </Button>
          </StackPanel>
        </Grid>

        <!-- 1. Hero: live running total (approx. net) -->
        <StackPanel Grid.Row="1" Margin="0,4,0,0">
          <!-- v2.0.15: TessDesk-style UPDATE tab (always visible): red NO UPDATE = current (tap checks now); green YES UPDATE = newer version out (tap installs + restarts) -->
          <Border x:Name="UpdBig" CornerRadius="0,9,9,0" HorizontalAlignment="Left" MinWidth="118" MaxWidth="160" Background="#FFE82127" BorderBrush="#FFE82127" BorderThickness="1,1.5,1.5,1.5" Padding="7,2,10,3" Margin="-16,0,0,4" Cursor="Hand" ToolTip="NO UPDATE · tap to check now">
            <TextBlock x:Name="UpdBigTxt" Text="NO UPDATE" Foreground="#FFFFFFFF" FontFamily="Segoe UI" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center"/>
          </Border>
          <TextBlock x:Name="HeroLabel" Text="" Foreground="#FF777777" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold" HorizontalAlignment="Center"/>
          <Viewbox StretchDirection="DownOnly" Stretch="Uniform" HorizontalAlignment="Center" Height="48" Margin="0,-3,0,0">
            <TextBlock x:Name="HeroAmt" Text="-" Foreground="#FFFFFFFF" FontFamily="Segoe UI" FontSize="37" FontWeight="Bold"/>
          </Viewbox>
          <TextBlock x:Name="HeroSub" Text="" Foreground="#FF777777" FontFamily="Segoe UI" FontSize="10" HorizontalAlignment="Center" Margin="0,-4,0,0"/>
        </StackPanel>

        <!-- v1.15.0 FOCUS: big status + clock-in time -->
        <Border Grid.Row="2" Background="#FF151515" BorderBrush="#FF333333" BorderThickness="1" CornerRadius="9" Padding="10,4,10,4" Margin="0,4,0,0">
          <StackPanel>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel Orientation="Horizontal" Grid.Column="0" ClipToBounds="True">
                <Ellipse x:Name="StatusDot" Width="11" Height="11" Fill="#FF888888" VerticalAlignment="Center"/>
                <TextBlock x:Name="StatusText" Text="-" Foreground="#FFFFFFFF" FontFamily="Segoe UI" FontSize="15" FontWeight="Black" Margin="7,0,0,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
              <TextBlock x:Name="StatusIn" Grid.Column="1" Text="" Foreground="#FFFFFFFF" FontFamily="Segoe UI" FontSize="11" FontWeight="Bold" Margin="6,0,0,0" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
            <TextBlock x:Name="StatusDetail" Text="" Foreground="#FFBBBBBB" FontFamily="Segoe UI" FontSize="10.5" FontWeight="SemiBold" Margin="18,0,0,0" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </Border>

        <Grid Grid.Row="3" Margin="0,4,0,0">
          <Border Height="4" Background="#FF222222" CornerRadius="2"/>
          <Border x:Name="ProgressFill" Height="4" Background="#FFE82127" CornerRadius="2" HorizontalAlignment="Left" Width="0"/>
        </Grid>

        <!-- v1.12.0 manual clock buttons; v1.15.0 FOCUS: big buttons, BREAK 1 / BREAK 2, BE BACK BY, card stopwatches, today's punches -->
        <Border Grid.Row="4" Background="#FF111111" BorderBrush="#FF2E2E2E" BorderThickness="1" CornerRadius="10" Padding="4,4,4,3" Margin="0,5,0,0">
          <StackPanel>
            <!-- v2.0.10: CLOCK IN (full) / BREAK 1 | BREAK 1 BACK / LUNCH START | LUNCH BACK / BREAK 2 | BREAK 2 BACK / CLOCK OUT (full, red) -->
__PB_in__            <UniformGrid Columns="2">
__PB_bs1____PB_be1____PB_lo____PB_li____PB_bs2____PB_be2__            </UniformGrid>
__PB_out__
            <!-- v1.13.0 BE BACK BY (full width while away; flashes in the final minutes, solid red LATE once overdue) -->
            <Border x:Name="BackBox" Visibility="Collapsed" Background="#FF2A1F08" BorderBrush="#FFFFB020" BorderThickness="2" CornerRadius="10" Margin="3,5,3,0" Padding="9,3,9,4">
              <StackPanel>
                <Grid><TextBlock x:Name="BackLab" Text="BE BACK BY" Foreground="#FFF2D9A6" FontFamily="Segoe UI" FontSize="9.5" FontWeight="Black" VerticalAlignment="Center"/>
                  <Border HorizontalAlignment="Right" Background="#59000000" BorderBrush="#24FFFFFF" BorderThickness="1" CornerRadius="8" Padding="7,0,7,1">
                    <TextBlock x:Name="BackLeft" Text="" Foreground="#FFFFFFFF" FontFamily="Segoe UI" FontSize="10" FontWeight="Bold"/></Border></Grid>
                <Viewbox StretchDirection="DownOnly" Stretch="Uniform" Height="46" Margin="0,-2,0,-2" HorizontalAlignment="Center">
                  <TextBlock FontFamily="Cascadia Mono, Consolas" FontWeight="Bold"><Run x:Name="BackTime" Text="--:--" Foreground="#FFFFB020" FontSize="54"/><Run x:Name="BackAmPm" Text="" Foreground="#FFFFB020" FontSize="17"/>
                    <TextBlock.Effect><DropShadowEffect x:Name="BackGlow" Color="#FFFFB020" BlurRadius="14" ShadowDepth="0" Opacity="0.8"/></TextBlock.Effect></TextBlock>
                </Viewbox>
                <TextBlock x:Name="BackSub" Text="" Foreground="#FFD8C8A8" FontFamily="Segoe UI" FontSize="9.5" FontWeight="SemiBold" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
            </Border>
            <!-- v1.15.0 stopwatch cards: BREAK 1 | BREAK 2, LUNCH full width -->
            <Grid Margin="0,5,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="BrkBox" Background="#FF161616" BorderBrush="#FF2C2C2C" BorderThickness="1.5" CornerRadius="9" Margin="3,0,3,0" Padding="7,3,7,3">
                <StackPanel>
                  <Grid><TextBlock x:Name="BrkLab" Text="BREAK 1" Foreground="#FF9A9A9A" FontFamily="Segoe UI" FontSize="9" FontWeight="Black"/>
                    <TextBlock x:Name="BrkTot" Text="" Foreground="#FF8A8A8A" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                  <Viewbox StretchDirection="DownOnly" Stretch="Uniform" Height="34" HorizontalAlignment="Center" Margin="0,-2,0,-1">
                    <TextBlock x:Name="BrkLive" Text="--:--" Foreground="#FFFFFFFF" FontFamily="Cascadia Mono, Consolas" FontSize="30" FontWeight="Bold">
                      <TextBlock.Effect><DropShadowEffect x:Name="BrkGlow" Color="#FFFFB020" BlurRadius="12" ShadowDepth="0" Opacity="0"/></TextBlock.Effect></TextBlock>
                  </Viewbox>
                  <TextBlock x:Name="BrkFoot" Text="" Foreground="#FF9A9A9A" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
              <Border x:Name="Brk2Box" Grid.Column="1" Background="#FF161616" BorderBrush="#FF2C2C2C" BorderThickness="1.5" CornerRadius="9" Margin="3,0,3,0" Padding="7,3,7,3">
                <StackPanel>
                  <Grid><TextBlock x:Name="Brk2Lab" Text="BREAK 2" Foreground="#FF9A9A9A" FontFamily="Segoe UI" FontSize="9" FontWeight="Black"/>
                    <TextBlock x:Name="Brk2Sub" Text="" Foreground="#FF8A8A8A" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                  <Viewbox StretchDirection="DownOnly" Stretch="Uniform" Height="34" HorizontalAlignment="Center" Margin="0,-2,0,-1">
                    <TextBlock x:Name="Brk2Live" Text="--:--" Foreground="#FFFFFFFF" FontFamily="Cascadia Mono, Consolas" FontSize="30" FontWeight="Bold">
                      <TextBlock.Effect><DropShadowEffect x:Name="Brk2Glow" Color="#FFFFB020" BlurRadius="12" ShadowDepth="0" Opacity="0"/></TextBlock.Effect></TextBlock>
                  </Viewbox>
                  <TextBlock x:Name="Brk2Foot" Text="" Foreground="#FF9A9A9A" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
            </Grid>
            <Grid Margin="0,5,0,0">
              <Border x:Name="LunBox" Background="#FF161616" BorderBrush="#FF2C2C2C" BorderThickness="1.5" CornerRadius="9" Margin="3,0,3,0" Padding="7,3,7,3">
                <StackPanel>
                  <Grid><TextBlock x:Name="LunLab" Text="LUNCH" Foreground="#FF9A9A9A" FontFamily="Segoe UI" FontSize="9" FontWeight="Black"/>
                    <TextBlock x:Name="LunSub" Text="" Foreground="#FF8A8A8A" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                  <Viewbox StretchDirection="DownOnly" Stretch="Uniform" Height="34" HorizontalAlignment="Center" Margin="0,-2,0,-1">
                    <TextBlock x:Name="LunLive" Text="--:--" Foreground="#FFFFFFFF" FontFamily="Cascadia Mono, Consolas" FontSize="30" FontWeight="Bold">
                      <TextBlock.Effect><DropShadowEffect x:Name="LunGlow" Color="#FFFFB020" BlurRadius="12" ShadowDepth="0" Opacity="0"/></TextBlock.Effect></TextBlock>
                  </Viewbox>
                  <TextBlock x:Name="LunFoot" Text="" Foreground="#FF9A9A9A" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
            </Grid>
            <!-- v2.0.4: today's time away (Break 1 + Break 2 + lunch, from the day's punches incl. editor fixes; live while one runs) -->
            <Grid x:Name="DayTot" Margin="3,4,3,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="1.15*"/></Grid.ColumnDefinitions>
              <Border x:Name="DtBBox" Grid.Column="0" Background="#FF141414" BorderBrush="#FF2C2C2C" BorderThickness="1" CornerRadius="7" Margin="0,0,2,0" Padding="2,2,2,3">
                <StackPanel>
                  <TextBlock Text="BREAKS" Foreground="#FF9A9A9A" FontFamily="Segoe UI" FontSize="8" FontWeight="Bold" HorizontalAlignment="Center"/>
                  <Viewbox StretchDirection="DownOnly" Stretch="Uniform" Height="20" HorizontalAlignment="Center">
                    <TextBlock x:Name="DtB" Text="00:00" Foreground="#FFFFFFFF" FontFamily="Cascadia Mono, Consolas" FontSize="17" FontWeight="Bold"/>
                  </Viewbox>
                </StackPanel>
              </Border>
              <Border x:Name="DtLBox" Grid.Column="1" Background="#FF141414" BorderBrush="#FF2C2C2C" BorderThickness="1" CornerRadius="7" Margin="2,0,2,0" Padding="2,2,2,3">
                <StackPanel>
                  <TextBlock Text="LUNCH" Foreground="#FF9A9A9A" FontFamily="Segoe UI" FontSize="8" FontWeight="Bold" HorizontalAlignment="Center"/>
                  <Viewbox StretchDirection="DownOnly" Stretch="Uniform" Height="20" HorizontalAlignment="Center">
                    <TextBlock x:Name="DtL" Text="00:00" Foreground="#FFFFFFFF" FontFamily="Cascadia Mono, Consolas" FontSize="17" FontWeight="Bold"/>
                  </Viewbox>
                </StackPanel>
              </Border>
              <Border x:Name="DtABox" Grid.Column="2" Background="#FF1D1606" BorderBrush="#FF5A4410" BorderThickness="1" CornerRadius="7" Margin="2,0,0,0" Padding="2,2,2,3">
                <StackPanel>
                  <TextBlock Text="TOTAL TODAY" Foreground="#FF9A9A9A" FontFamily="Segoe UI" FontSize="8" FontWeight="Bold" HorizontalAlignment="Center"/>
                  <Viewbox StretchDirection="DownOnly" Stretch="Uniform" Height="20" HorizontalAlignment="Center">
                    <TextBlock x:Name="DtA" Text="00:00" Foreground="#FFFFB020" FontFamily="Cascadia Mono, Consolas" FontSize="17" FontWeight="Bold"/>
                  </Viewbox>
                </StackPanel>
              </Border>
            </Grid>
            <TextBlock x:Name="BrkTotal" Text="" Foreground="#FF8A8A8A" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,2,0,0"/>
            <!-- v1.15.0 today's punch times (click a line to edit) -->
            <Border Background="#FF121212" BorderBrush="#FF2A2A2A" BorderThickness="1" CornerRadius="8" Margin="3,4,3,0" Padding="7,2,7,3">
              <StackPanel>
                <TextBlock Text="TODAY'S PUNCHES &#183; CLICK TO EDIT" Foreground="#FF888888" FontFamily="Segoe UI" FontSize="8" FontWeight="Bold" Margin="0,0,0,1"/>
                <StackPanel x:Name="TodayList"/>
              </StackPanel>
            </Border>
            <Grid Margin="2,1,2,0">
              <TextBlock x:Name="PunchNote" Text="" Foreground="#FF666666" FontFamily="Segoe UI" FontSize="8" VerticalAlignment="Center"/>
              <TextBlock HorizontalAlignment="Right" FontFamily="Segoe UI" FontSize="8.5" Foreground="#FF555555"><Hyperlink x:Name="PEdit" Foreground="#FFFFB020" TextDecorations="None" Cursor="Hand" ToolTip="Fix a forgotten END BREAK, change/add/delete breaks and lunch, edit clock in/out">Edit</Hyperlink><Run Text=" &#183; "/><Hyperlink x:Name="PPto" Foreground="#FF5AC8FA" TextDecorations="None" Cursor="Hand" ToolTip="Add PTO hours (paid at base rate) for any day">PTO</Hyperlink><Run Text=" &#183; "/><Hyperlink x:Name="PUndo" Foreground="#FFE82127" TextDecorations="None" Cursor="Hand" ToolTip="Remove today's last punch">Undo</Hyperlink><Run Text=" &#183; "/><Hyperlink x:Name="PReset" Foreground="#FFE82127" TextDecorations="None" Cursor="Hand" ToolTip="Clear today's punches and go back to the automatic schedule">Reset to auto</Hyperlink></TextBlock>
            </Grid>
          </StackPanel>
        </Border>

        <!-- v1.15.0: TODAY GROSS breakdown + schedule moved below the focus area -->
        <StackPanel Grid.Row="5" Margin="0,6,0,0">
          <TextBlock Text="TODAY GROSS &amp; SCHEDULE" Foreground="#FF666666" FontFamily="Segoe UI" FontSize="8" FontWeight="Bold" Margin="2,0,0,2"/>
          <!-- v1.14.0 today's GROSS pay breakdown (live): regular / shift diff / overtime / total -->
          <Border x:Name="HBBox" Background="#FF101010" BorderBrush="#FF262626" BorderThickness="1" CornerRadius="7" Padding="4,1,4,2" Margin="0,0,0,0">
            <StackPanel>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <TextBlock Text="REGULAR" Foreground="#FF777777" FontFamily="Segoe UI" FontSize="7.5" FontWeight="Bold" HorizontalAlignment="Center"/>
                <TextBlock Grid.Column="1" Text="SHIFT DIFF" Foreground="#FF777777" FontFamily="Segoe UI" FontSize="7.5" FontWeight="Bold" HorizontalAlignment="Center"/>
                <TextBlock Grid.Column="2" Text="OVERTIME" Foreground="#FF777777" FontFamily="Segoe UI" FontSize="7.5" FontWeight="Bold" HorizontalAlignment="Center"/>
                <TextBlock Grid.Column="3" Text="TOTAL GROSS" Foreground="#FF999999" FontFamily="Segoe UI" FontSize="7.5" FontWeight="Bold" HorizontalAlignment="Center"/>
                <TextBlock x:Name="HBReg" Grid.Row="1" Text="-" Foreground="#FFE6E6E6" FontFamily="Segoe UI" FontSize="11.5" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,-2,0,0"/>
                <TextBlock x:Name="HBDiff" Grid.Row="1" Grid.Column="1" Text="-" Foreground="#FFFFB020" FontFamily="Segoe UI" FontSize="11.5" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,-2,0,0"/>
                <TextBlock x:Name="HBOT" Grid.Row="1" Grid.Column="2" Text="-" Foreground="#FFFF7A45" FontFamily="Segoe UI" FontSize="11.5" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,-2,0,0"/>
                <TextBlock x:Name="HBTot" Grid.Row="1" Grid.Column="3" Text="-" Foreground="#FF34C759" FontFamily="Segoe UI" FontSize="11.5" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,-2,0,0"/>
                <TextBlock x:Name="HBRegH" Grid.Row="2" Text="" Foreground="#FF666666" FontFamily="Segoe UI" FontSize="7.5" HorizontalAlignment="Center" Margin="0,-2,0,0"/>
                <TextBlock x:Name="HBDiffH" Grid.Row="2" Grid.Column="1" Text="" Foreground="#FF666666" FontFamily="Segoe UI" FontSize="7.5" HorizontalAlignment="Center" Margin="0,-2,0,0"/>
                <TextBlock x:Name="HBOTH" Grid.Row="2" Grid.Column="2" Text="" Foreground="#FF666666" FontFamily="Segoe UI" FontSize="7.5" HorizontalAlignment="Center" Margin="0,-2,0,0"/>
                <TextBlock x:Name="HBTotH" Grid.Row="2" Grid.Column="3" Text="" Foreground="#FF666666" FontFamily="Segoe UI" FontSize="7.5" HorizontalAlignment="Center" Margin="0,-2,0,0"/>
              </Grid>
              <TextBlock x:Name="HBPto" Text="" Visibility="Collapsed" Foreground="#FF5AC8FA" FontFamily="Segoe UI" FontSize="9" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,1,0,0"/>
              <TextBlock x:Name="HBNote" Text="" Foreground="#FF808080" FontFamily="Segoe UI" FontSize="7.5" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,0,0"/>
            </StackPanel>
          </Border>
        <!-- 2. v1.11.0 TODAY'S SCHEDULE timeline (replaces the shift breakdown) -->
          <Border Background="#FF101010" BorderBrush="#FF232323" BorderThickness="1" CornerRadius="7" Padding="7,2,7,2" Margin="0,4,0,0">
            <StackPanel>
              <Grid>
                <TextBlock x:Name="SchedHead" Text="TODAY'S SCHEDULE" Foreground="#FFE82127" FontFamily="Segoe UI" FontSize="10" FontWeight="Bold"/>
                <TextBlock x:Name="SchedHours" Text="" Foreground="#FF888888" FontFamily="Segoe UI" FontSize="9.5" FontWeight="SemiBold" HorizontalAlignment="Right" VerticalAlignment="Center"/>
              </Grid>
              <TextBlock x:Name="SchedNext" Text="" Foreground="#FFDDDDDD" FontFamily="Segoe UI" FontSize="10.5" FontWeight="SemiBold" Margin="0,1,0,2" TextTrimming="CharacterEllipsis"/>
__TLROWS__          </StackPanel>
          </Border>
        </StackPanel>

        <Border Grid.Row="6" Height="1" Background="#FF2A2A2A" Margin="0,3,0,2" Visibility="Collapsed"/>

        <!-- v2.0.15: 2-week DAILY MONEY MADE section removed (Van) -->
      </Grid>
    </DockPanel>
  </Border>
</Window>
'@
foreach ($k in @($pb.Keys)) { $xamlText = $xamlText.Replace('__PB_' + $k + '__', $pb[$k]) }
$xamlText = $xamlText.Replace('__WINTITLE__', $winTitle).Replace('__TITLE__', $titleText).Replace('__W__', [string]$winW).Replace('__H__', [string]$winH).Replace('__DAYROWS__', $dayRows).Replace('__TLROWS__', $tlRows).Replace('__TILES__', $tiles).Replace('__PNAME__', $(if ($TestMode) { 'Paycheck Test' } else { 'Paycheck Live' })).Replace('__VER__', $AppVersion).Replace('__VDATE__', $AppVersionDate).Replace('__VUPD__', $AppUpdated)
[xml]$xaml = $xamlText
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
if ($AppIcon -and (Test-Path -LiteralPath $AppIcon)) { try { $icoMs = New-Object IO.MemoryStream(,[IO.File]::ReadAllBytes($AppIcon)); $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($icoMs, [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad) } catch {} }   # v2.0.0 app icon (taskbar / Alt+Tab)

$ui = @{}
foreach ($n in @('Root','TitleBar','CloseBtn','SimTag','DateLabel','TestControls','StartBtn','StopBtn','HeroLabel','HeroAmt','HeroSub',
                 'StatusDot','StatusText','StatusDetail','ProgressFill','SchedHead','SchedHours','SchedNext','GearBtn','TipVenmo','TipPaypal',
                 'ToggleBtn','ToggleTxt','PEdit','PPto','HBPto','ShareBtn','ContentGrid','VersionText','UpdateBtn','UpdateTxt','UpdBig','UpdBigTxt','BrkLive','BrkTot','DtB','DtL','DtA','DtBBox','DtLBox','DtABox','LunLive','LunSub','BrkBox','LunBox','BrkGlow','LunGlow','BackBox','BackLab','BackLeft','BackTime','BackAmPm','BackGlow','BackSub','Brk2Box','Brk2Lab','Brk2Sub','Brk2Live','Brk2Glow','BrkFoot','Brk2Foot','LunFoot','BrkTotal','TodayList','StatusIn','FfwdBtn','BrkLab','LunLab','PunchNote','PUndo','PReset','DailyHead','DailyRange','PeriodNet','PeriodGross','DailyScroll','HBBox','HBReg','HBDiff','HBOT','HBTot','HBRegH','HBDiffH','HBOTH','HBTotH','HBNote','PeriodBrk')) {
    $ui[$n] = $window.FindName($n)
}
for ($i = 0; $i -lt 14; $i++) { foreach ($p in '','Name','Note','Amt','Diff','OT') { $ui["DL$i$p"] = $window.FindName("DL$i$p") } }
foreach ($k in 0, 1) { foreach ($p in '','Lab','Amt','Diff','OT') { $ui["WS$k$p"] = $window.FindName("WS$k$p") } }
foreach ($d in $pbDefs) { $ui['PB_' + $d[0]] = $window.FindName('PB_' + $d[0]); $ui['PT_' + $d[0]] = $window.FindName('PT_' + $d[0]); $ui['PL_' + $d[0]] = $window.FindName('PL_' + $d[0]) }
for ($i = 0; $i -lt $TLMax; $i++) { foreach ($p in '','Dot','Time','Lab','X') { $ui["TL$i$p"] = $window.FindName("TL$i$p") } }


$bc = [System.Windows.Media.BrushConverter]::new()
function Brush([string]$hex) { return $bc.ConvertFromString($hex) }
$inv = [Globalization.CultureInfo]::InvariantCulture
$emDash = [string][char]0x2014
$dot = ' ' + [char]0x00B7 + ' '
$enDash = [string][char]0x2013
$minus = [string][char]0x2212

function Format-TaxOnly($t) {
    return ('Fed ' + (Format-Money $t.Fed) + $dot + 'SS ' + (Format-Money $t.SS) + $dot + 'Med ' + (Format-Money $t.Med) + $(if ($script:StateMode -ne 'none') { $dot + $(if ($script:StateMode -eq 'ok') { 'OK ' } else { 'State ' }) + (Format-Money $t.OK) } else { '' }))
}

function Update-Ui {
    if ($TestMode) { $now = Get-TestSimNow } else { $now = Get-Now }
    $st = Get-WidgetState $now $(if ($TestMode) { $script:TestDay } else { $null })
    $h = $st.Hero; $hn = $st.HeroNet

    if ($TestMode) {
        $ui.TestControls.Visibility = [System.Windows.Visibility]::Visible
        $ui.SimTag.Text = switch ($script:TestState) { 'running' { 'TEST ' + [char]0x25CF + ' RUNNING' } 'stopped' { 'TEST ' + [char]0x25A0 + ' STOPPED' } default { 'TEST ' + $emDash + ' READY' } }
        $ui.SimTag.Foreground = Brush $(switch ($script:TestState) { 'running' { '#FF34C759' } 'stopped' { '#FFE82127' } default { '#FFFFB020' } })
        $ui.DateLabel.Text = 'SIM ' + $now.ToString('ddd', $inv) + ' ' + $now.ToString('h:mm:ss tt', $inv)
        $ui.DateLabel.Foreground = Brush '#FFFFFFFF'
        $ui.DateLabel.FontWeight = [System.Windows.FontWeights]::Bold
        $ui.DateLabel.FontSize = 11
    } else {
        $ui.SimTag.Text = $(if ($InstallerPreview) { 'INSTALLER PREVIEW' } elseif ($null -ne $script:SimOffset) { 'SIMULATED' } else { '' })
        $ui.DateLabel.Text = $now.ToString('dddd, MMM d', $inv) + $dot + $now.ToString('h:mm tt', $inv)
    }

    if ($st.HeroIsToday) {
        $ui.HeroLabel.Text = "TODAY" + $dot + "APPROX. NET"
    } else {
        $ui.HeroLabel.Text = 'LAST SHIFT' + $dot + $st.HeroDay.ToString('ddd MMM d', $inv).ToUpper() + $dot + 'APPROX. NET'
    }
    $ui.HeroAmt.Text = Format-Money $hn.Net
    $ui.HeroSub.FontSize = 10; $ui.HeroSub.FontWeight = [System.Windows.FontWeights]::Normal; $ui.HeroSub.Foreground = Brush '#FF777777'
    $sub = 'gross ' + (Format-Money $h.Total)
    if ($null -ne $st.CurrentRate) { $sub += $dot + ('earning ${0}/hr gross' -f $st.CurrentRate.ToString('0.00', $inv)) } else { $sub += $dot + 'est. from schedule' }
    if ($TestMode -and $script:TestState -eq 'idle') { $sub = 'gross ' + (Format-Money 0) + $dot + 'press START' }
    $ui.HeroSub.Text = $sub
    $ui.HeroAmt.Foreground = Brush $(if ($st.Status -eq 'CLOCKED IN') { '#FFFFFFFF' } elseif ($hn.Net -gt 0) { '#FFE6E6E6' } else { '#FF888888' })
    if ($st.DayOff -and -not ($TestMode -and $script:TestState -eq 'idle')) {
        # Sunday / Monday: day name replaces the dollar amount
        $ui.HeroLabel.Text = 'TODAY' + $dot + $now.ToString('MMM d', $inv).ToUpper()
        $ui.HeroAmt.Text = $st.DayName
        $ui.HeroAmt.Foreground = Brush '#FFFFFFFF'
        $ui.HeroSub.Text = 'DAY OFF'
        $ui.HeroSub.FontSize = 15; $ui.HeroSub.FontWeight = [System.Windows.FontWeights]::Bold; $ui.HeroSub.Foreground = Brush '#FFE82127'
    }
    # v1.14.0 GROSS breakdown for the hero day (live, ticks with the big number): regular + shift diff (evening + weekend, stacking) + overtime = total gross
    $hb = $h; $hbZero = (($TestMode -and $script:TestState -eq 'idle') -or $st.DayOff)
    if ($hbZero) { $hb = [pscustomobject]@{ Reg = [decimal]0; Diff = [decimal]0; DiffEve = [decimal]0; DiffWknd = [decimal]0; OT = [decimal]0; OTMin = 0; RegMin = 0; PaidMin = 0; Total = [decimal]0; PriorMin = 0 } }
    $ui.HBReg.Text = Format-Money $hb.Reg; $ui.HBDiff.Text = Format-Money $hb.Diff; $ui.HBOT.Text = Format-Money $hb.OT; $ui.HBTot.Text = Format-Money $hb.Total
    if ($hb.PtoMin -gt 0) { $ui.HBPto.Text = 'PTO ' + (Format-H $hb.PtoMin) + ' h @ $' + $Rules.BaseRate.ToString('0.00', $inv) + ' = ' + (Format-Money $hb.Pto) + ' (base rate, in TOTAL GROSS)'; $ui.HBPto.Visibility = 'Visible' } else { $ui.HBPto.Visibility = 'Collapsed' }
    $ui.HBRegH.Text = (Format-H $hb.RegMin) + ' @ $' + $Rules.BaseRate.ToString('0.00', $inv)
    $ui.HBDiffH.Text = $(if ($hb.DiffEve -gt 0 -and $hb.DiffWknd -gt 0) { 'eve + wknd stack' } elseif ($hb.DiffWknd -gt 0) { 'weekend' } elseif ($hb.DiffEve -gt 0) { 'evening' } else { 'none yet' })
    $ui.HBOTH.Text = $(if (-not $script:OT.On) { 'OT off' } elseif ($hb.OTMin -gt 0) { (Format-H $hb.OTMin) + ' @ ' + $script:OT.Mult.ToString('0.0#', $inv) + 'x' } else { 'wk ' + (Format-H ($hb.PriorMin + $hb.PaidMin)) + ' / ' + (Format-H $script:OT.AfterMin) })
    $ui.HBTotH.Text = (Format-H $hb.PaidMin) + ' paid'
    $ui.HBOT.Foreground = Brush $(if ($hb.OTMin -gt 0) { '#FFFF7A45' } else { '#FF8A5A48' })
    $ui.HBDiff.Foreground = Brush $(if ($hb.Diff -gt 0) { '#FFFFB020' } else { '#FF8A7040' })
    $ui.HBNote.Text = $(if ($st.HeroIsToday -or $hbZero) { 'TODAY' } else { 'LAST SHIFT' }) + ' GROSS, before tax' + $dot + 'diff: ' + (Get-DiffNoteText $hb)

    $status = $st.Status; $detail = $st.StatusDetail; $color = $st.StatusColor
    if ($TestMode -and $script:TestState -eq 'idle') { $td0 = Get-TestDay; $status = 'READY'; $detail = 'Press START (sim ' + $td0.ToString('ddd', $inv) + ' ' + (Format-Clock (Get-DaySpec $td0 $false).S0) + ')'; $color = '#FFFFB020' }
    elseif ($TestMode -and $script:TestState -eq 'stopped') { $detail = 'Frozen' + $dot + $detail }
    $ui.StatusText.Text = $status
    $ui.StatusDot.Fill = Brush $color
    $ui.StatusText.Foreground = Brush $(if ($status -eq 'CLOCKED IN') { '#FF34C759' } elseif ($st.OnBreak -or $status -eq 'READY') { '#FFFFB020' } else { '#FFCCCCCC' })
    $ui.StatusDetail.Text = $detail

    $trackW = $winW - 32 - 2
    $ui.ProgressFill.Width = $(if ($st.DayPaidMin -gt 0 -and $st.HeroIsToday) { [math]::Round([math]::Min(1, $h.PaidMin / $st.DayPaidMin) * $trackW, 1) } elseif (-not $st.HeroIsToday -and $h.PaidMin -gt 0) { $trackW } else { 0 })
    $ui.ProgressFill.Background = Brush $(if ($st.HeroIsToday) { '#FFE82127' } else { '#FF444444' })

    # v1.11.0 TODAY'S SCHEDULE (replaces the shift breakdown): clock times, current segment highlighted, countdown to the next event
    $sc = $st.Sched; $idle = ($TestMode -and $script:TestState -eq 'idle'); $nm = $now.Hour * 60 + $now.Minute
    $ui.SchedHead.Text = "TODAY'S SCHEDULE" + $dot + $now.ToString('ddd M/d', $inv).ToUpper()
    $ui.SchedHours.Text = $(if ($sc.Work) { (Format-Hours $(if ($st.HeroIsToday -and -not $idle) { $h.PaidMin } else { 0 })) + ' / ' + (Format-Hours $st.DayPaidMin) } else { '' })
    $ui.SchedNext.Inlines.Clear()
    $addRun = { param($t, $c) $r = New-Object System.Windows.Documents.Run($t); if ($c) { $r.Foreground = Brush $c; $r.FontWeight = [System.Windows.FontWeights]::Bold }; $ui.SchedNext.Inlines.Add($r) }
    if ($idle) { & $addRun 'Press START to run the simulated day' $null }
    elseif (-not $sc.Work) { & $addRun ('Day off' + $dot + 'next shift ') $null; & $addRun ($st.NextDay.ToString('ddd', $inv) + ' ' + (Format-Clock $st.NextStart)) '#FFFFB020' }
    elseif ($sc.Seg.Kind -eq 'done') { & $addRun ('Shift complete' + $dot + 'clocked out ' + (Format-Clock $sc.Spec.E)) $null }
    elseif ($sc.Seg.Kind -eq 'break' -and $sc.Seg.B.Open) { & $addRun ($sc.Seg.Label + $dot) $null; $script:NextLiveRun = New-Object System.Windows.Documents.Run((Format-MMSS (($nm * 60 + $now.Second) - [int]$sc.Seg.B.SS))); $script:NextLiveRun.Foreground = Brush '#FFFFB020'; $script:NextLiveRun.FontWeight = [System.Windows.FontWeights]::Bold; $ui.SchedNext.Inlines.Add($script:NextLiveRun); & $addRun ' so far' $null }
    elseif ($sc.Next) { & $addRun ($sc.Seg.Label + $dot) $null; & $addRun (Format-Dur ($sc.Next.T - $nm)) '#FFFFB020'; & $addRun (' until ' + $sc.Next.Label.ToLower()) $null }
    else { & $addRun $sc.Seg.Label $null }
    $script:NextLiveFrom = $(if ($sc.Seg.Kind -eq 'break' -and $sc.Seg.B -and $sc.Seg.B.Open -and -not $idle) { [int]$sc.Seg.B.SS } else { $null })
    $script:LiveTL = @()
    $rows = @($sc.Rows); if (-not $sc.Work -and -not $idle) { $rows = @([pscustomobject]@{ Time = $emDash; Label = 'No shift today'; X = ''; State = '' }) }
    for ($i = 0; $i -lt $TLMax; $i++) {
        $bd = $ui["TL$i"]
        if ($i -ge $rows.Count) { $bd.Visibility = [System.Windows.Visibility]::Collapsed; continue }
        $r = $rows[$i]; $stt = $(if ($idle) { '' } else { [string]$r.State }); $bd.Visibility = [System.Windows.Visibility]::Visible
        $ui["TL${i}Time"].Text = $r.Time; $ui["TL${i}Lab"].Text = $r.Label; $ui["TL${i}X"].Text = $r.X
        if ($null -ne $r.LiveFrom -and -not $idle) { $script:LiveTL += , @($i, [int]$r.LiveFrom, ($r.X -replace '^[0-9:]+', '')) }
        switch ($stt) {
            'done'  { $fg = '#FF5A5A5A'; $df = '#FF2C5E3A'; $ds = '#FF2C5E3A'; $bg = '#00000000' }
            'cur'   { $fg = '#FFFFFFFF'; $df = '#FF34C759'; $ds = '#FF34C759'; $bg = '#2E34C759' }
            'brk'   { $fg = '#FFFFFFFF'; $df = '#FFFFB020'; $ds = '#FFFFB020'; $bg = '#2EFFB020' }
            'nxt'   { $fg = '#FFDDDDDD'; $df = '#FF333333'; $ds = '#FF888888'; $bg = '#00000000' }
            default { $fg = '#FF777777'; $df = '#FF333333'; $ds = '#FF555555'; $bg = '#00000000' }
        }
        $ui["TL${i}Time"].Foreground = Brush $fg; $ui["TL${i}Lab"].Foreground = Brush $fg; $ui["TL${i}Dot"].Fill = Brush $df; $ui["TL${i}Dot"].Stroke = Brush $ds; $bd.Background = Brush $bg
    }

    # v2.0.15: 2-week DAILY MONEY MADE list removed (Van)
    Update-PunchUi $now $st
    $script:LastKey = $now.ToString('yyyyMMddHHmm') + $script:TestState
}

# ---------------------------------------------------------------- v1.12.0 manual clock buttons + live break / lunch stopwatches
function Get-PunchNow { if ($TestMode) { return Get-TestSimNow } return Get-Now }
function Format-Late([int]$sec) { if ($sec -lt 0) { $sec = 0 }; $m = [math]::Floor($sec / 60); return ('{0}:{1:00}' -f $m, ($sec % 60)) }   # m:ss (no leading zero), e.g. +2:18
function Update-PunchUi($now, $st) {
    $sp = $st.Spec; $r = $sp.Pr; $idle = ($TestMode -and $script:TestState -eq 'idle')
    $lb = @($sp.Brs | Where-Object { $_.Kind -eq 'lunch' }) | Select-Object -First 1
    $clk = { param($sec) Format-Clock ([int][math]::Floor($sec / 60)) }
    $set = { param($k, $txt, $on) $ui['PT_' + $k].Text = $txt; $ui['PT_' + $k].Foreground = Brush $(if ($on) { '#FFFFFFFF' } else { '#FFCFCFCF' }); $ui['PL_' + $k].Foreground = Brush '#FFFFFFFF'
             $ui['PB_' + $k].Background = Brush $(if ($on) { switch ($k) { 'in' { '#FF17592B' } 'out' { '#FFD0282E' } default { '#FF4D3A0E' } } } else { switch ($k) { 'in' { '#FF0F3B1D' } 'out' { '#FFB3141C' } default { '#FF33270A' } } })
             $ui['PB_' + $k].BorderBrush = Brush $(switch ($k) { 'in' { '#FF2FBF5A' } 'out' { '#FFFF4D55' } default { '#FFFFB020' } }) }
    $act = { param($k) $ui['PB_' + $k].Background = Brush '#FFFFB020'; $ui['PB_' + $k].BorderBrush = Brush '#FFFFE2A3'; $ui['PL_' + $k].Foreground = Brush '#FF111111'; $ui['PT_' + $k].Foreground = Brush '#FF111111' }
    $live = { param($k) $ui['PB_' + $k].Background = Brush '#FF6B4A06'; $ui['PB_' + $k].BorderBrush = Brush '#FFFFD27A'; $ui['PT_' + $k].Foreground = Brush '#FFFFE2A3' }
    & $set 'in'  $(if ($r -and $null -ne $r.In) { & $clk $r.InS } else { 'auto ' + (Format-Clock $sp.S0) }) ($r -and $null -ne $r.In)
    & $set 'lo'  $(if ($r -and $null -ne $r.Lo) { & $clk $r.LoS } elseif ($lb) { 'auto ' + (Format-Clock $lb.S) } else { $emDash }) ($r -and $null -ne $r.Lo)
    & $set 'li'  $(if ($r -and $null -ne $r.Li) { & $clk $r.LiS } elseif ($r -and $null -ne $r.Lo) { 'click when back' } elseif ($lb -and -not $lb.Actual) { 'auto ' + (Format-Clock $lb.E) } else { $emDash }) ($r -and $null -ne $r.Li)
    & $set 'out' $(if ($r -and $null -ne $r.Out) { & $clk $r.OutS } else { 'auto ' + (Format-Clock $sp.E0) }) ($r -and $null -ne $r.Out)
    $ob = $null; $nbr = 0; $closed = 0
    if ($r) { $nbr = $r.Br.Count; if ($nbr -and $null -eq $r.Br[$nbr - 1][1]) { $ob = $r.Br[$nbr - 1] }; foreach ($x in $r.Br) { if ($null -ne $x[1]) { $closed += ([int]$x[3] - [int]$x[2]) } } }
    # v1.15.0 BREAK 1 / BREAK 2: Br[0] = Break 1, Br[1..] = Break 2 (a 3rd+ break shows on the Break 2 card)
    $B1 = $(if ($nbr -ge 1) { $r.Br[0] } else { $null }); $B2 = $(if ($nbr -ge 2) { $r.Br[$nbr - 1] } else { $null })
    & $set 'bs1' $(if ($B1) { & $clk $B1[2] } else { [string]$script:BreakLen + ' min' }) ($null -ne $B1)
    & $set 'be1' $(if ($B1 -and $null -ne $B1[1]) { & $clk $B1[3] } elseif ($B1) { 'click when back' } else { '' }) ($B1 -and $null -ne $B1[1])
    & $set 'bs2' $(if ($B2) { & $clk $B2[2] } elseif ($B1) { [string]$script:BreakLen + ' min' } else { '' }) ($null -ne $B2)
    & $set 'be2' $(if ($B2 -and $null -ne $B2[1]) { & $clk $B2[3] } elseif ($B2) { 'click when back' } else { '' }) ($B2 -and $null -ne $B2[1])
    $lunchOpen = ($r -and $null -ne $r.Lo -and $null -eq $r.Li)
    if ($lunchOpen) { & $live 'lo'; & $act 'li' }
    if ($ob) { if ($nbr -eq 1) { & $live 'bs1'; & $act 'be1' } else { & $live 'bs2'; & $act 'be2' } }
    $ui.PB_bs1.IsEnabled = (-not $idle -and $nbr -eq 0); $ui.PB_be1.IsEnabled = (-not $idle -and $null -ne $ob -and $nbr -eq 1)
    $ui.PB_bs2.IsEnabled = (-not $idle -and $nbr -ge 1 -and $null -eq $ob); $ui.PB_be2.IsEnabled = (-not $idle -and $null -ne $ob -and $nbr -ge 2)
    $ui.PB_li.IsEnabled = ($r -and $null -ne $r.Lo -and -not $idle); foreach ($k in 'in','lo','out') { $ui['PB_' + $k].IsEnabled = (-not $idle) }
    $ui.PUndo.IsEnabled = ($null -ne $r); $ui.PReset.IsEnabled = ($null -ne $r)
    foreach ($hl in $ui.PUndo, $ui.PReset) { $hl.Foreground = Brush $(if ($null -ne $r) { '#FFE82127' } else { '#FF444444' }) }
    $ui.PunchNote.Text = $(if ($idle) { 'Press START first' } elseif ($r) { 'Actual times for ' + $now.ToString('ddd M/d', $inv) } else { 'Auto schedule' + $dot + 'tap to record actual times' })
    # v1.13.0 BE BACK BY: due = left + break length (profile, default 15) or + lunch length (profile lunch, default 60)
    $lunLen = $(if ($script:LunchBreak) { [int]($script:LunchBreak.E - $script:LunchBreak.S) } else { 60 }); if ($lunLen -le 0) { $lunLen = 60 }
    $away = $null
    if ($ob -and -not $idle) { $away = @{ Kind = 'break'; No = $(if ($nbr -ge 2) { 2 } else { 1 }); Left = [int]$ob[2]; Due = [int]$ob[2] + $script:BreakLen * 60; Warn = 5 * 60 } }
    elseif ($lunchOpen -and -not $idle) { $away = @{ Kind = 'lunch'; Left = [int]$r.LoS; Due = [int]$r.LoS + $lunLen * 60; Warn = 15 * 60 } }
    $clkS = { param($sec) Format-Clock ([int][math]::Floor($sec / 60)) }
    if ($away) { $tn = $now.Hour * 3600 + $now.Minute * 60 + $now.Second
        $ui.StatusDetail.Text = $(if ($tn -gt $away.Due) { 'LATE' + $dot + 'was due ' + (& $clkS $away.Due) } else { 'back by ' + (& $clkS $away.Due) + $dot + 'left ' + (& $clkS $away.Left) }) }
    # last finished break / lunch: small left -> back note (on time or late)
    $last = $null
    if ($r) { $cands = @(); $bi = 0; foreach ($x in $r.Br) { $bi++; if ($null -ne $x[1]) { $cands += , @(('Break ' + [math]::Min($bi, 2)), [int]$x[2], [int]$x[3], ($script:BreakLen * 60)) } }
              if ($null -ne $r.Lo -and $null -ne $r.Li) { $cands += , @('Lunch', [int]$r.LoS, [int]$r.LiS, ($lunLen * 60)) }
              if ($cands.Count) { $last = ($cands | Sort-Object { $_[2] } | Select-Object -Last 1) } }
    if ($last -and -not $idle -and -not $away) {
        $late = $last[2] - ($last[1] + $last[3])
        $ui.PunchNote.Text = $last[0] + ' ' + ((& $clkS $last[1]) -replace ' [AP]M$', '') + [string][char]0x2013 + (& $clkS $last[2]) + $dot + $(if ($late -gt 59) { (Format-Late $late) + ' late' } else { 'on time' })
    }
    # v1.14.2: a forgotten END BREAK (auto-closed) shows clearly; click the note or Edit to fix it
    $script:PunchWarn = $false; $ui.PunchNote.Foreground = Brush '#FF666666'; $ui.PunchNote.Cursor = $null
    if ($r -and -not $idle) { $fbx = @($r.Br | Where-Object { $_[4] }) | Select-Object -First 1
        if ($fbx) { $script:PunchWarn = $true; $ui.PunchNote.Text = [string][char]0x26A0 + ' Break ' + (& $clkS ([int]$fbx[2])) + ': END BREAK not pressed ' + $dot + 'click to fix'; $ui.PunchNote.Foreground = Brush '#FFFFB020'; $ui.PunchNote.Cursor = [Windows.Input.Cursors]::Hand } }
    $script:PL = @{ Ob = $ob; LunchOpen = $lunchOpen; R = $r; Closed = $closed; Away = $away; LunLen = $lunLen }
    # v1.15.0 FOCUS: clock-in time beside the status + today's punch list (click a line to edit)
    try { $ui.StatusIn.Text = $(if ($idle -or ($st.DayOff -and -not $r)) { '' } elseif ($r -and $null -ne $r.InS) { 'IN ' + (& $clk $r.InS) } else { 'IN ' + (Format-Clock $sp.S0) + ' auto' })
          Update-TodayList $now $idle ($st.DayOff -and -not $r) $lunLen } catch {}
    Update-PunchTick $now
}
function Update-TodayList($now, [bool]$idle, [bool]$hide, [int]$lunLen) {
    $tl = $ui.TodayList; if (-not $tl) { return }; $tl.Children.Clear()
    if ($idle -or $hide) { $tl.Parent.Parent.Visibility = [System.Windows.Visibility]::Collapsed; return }
    $tl.Parent.Parent.Visibility = [System.Windows.Visibility]::Visible
    $m = Get-DayModel $now.ToString('yyyy-MM-dd'); $t = $now.Hour * 3600 + $now.Minute * 60 + $now.Second
    $row = { param($k, $kc, $tx, $d, $dc, [bool]$auto, [bool]$warn)
        $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,1,0,1'; $g.Cursor = [System.Windows.Input.Cursors]::Hand; $g.Background = Brush $(if ($warn) { '#FF2A2108' } else { '#01000000' })
        foreach ($w in 72, -1, -2) { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $(if ($w -eq -1) { New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) } elseif ($w -eq -2) { [System.Windows.GridLength]::Auto } else { New-Object System.Windows.GridLength($w) }); $g.ColumnDefinitions.Add($cd) }
        $c = 0; foreach ($p in @(@($k, $kc, 10, 'Black'), @($tx, '#FFFFFFFF', 11.5, 'Bold'), @($d, $dc, 10, 'Bold'))) {
            $b = New-Object System.Windows.Controls.TextBlock; $b.Text = $p[0]; $b.Foreground = Brush $p[1]; $b.FontFamily = 'Segoe UI'; $b.FontSize = $p[2]; $b.FontWeight = [System.Windows.FontWeights]::($p[3]); $b.VerticalAlignment = 'Center'
            if ($auto -and $c -lt 2) { $b.Opacity = 0.55 }; if ($c -eq 2) { $b.HorizontalAlignment = 'Right' }; [System.Windows.Controls.Grid]::SetColumn($b, $c); [void]$g.Children.Add($b); $c++ }
        $g.Add_MouseLeftButtonUp({ Show-PunchEditor }); [void]$tl.Children.Add($g) }
    & $row 'CLOCK IN' '#FF34C759' ((Format-ClockS $m.In.T) + $(if ($m.In.Auto) { ' auto' } else { '' })) $(if ($m.In.Auto) { '' } else { [string][char]0x2713 }) '#FF34C759' $m.In.Auto $false
    $bn = 0
    foreach ($x in $m.Segs) {
        if ($x.Kind -eq 'break') { $bn++ }
        $nm = switch ($x.Kind) { 'lunch' { 'LUNCH' } 'off' { 'OFF CLOCK' } default { 'BREAK ' + $bn } }
        $len = $(if ($x.Kind -eq 'lunch') { $lunLen } else { $script:BreakLen }) * 60
        $tx = (Format-ClockS $x.S) + ' ' + [char]0x2013 + ' ' + $(if ($null -eq $x.E) { 'now' } else { Format-ClockS $x.E })
        if ($x.AutoClosed) { $d = [string][char]0x26A0 + ' fix'; $dc = '#FFFFCE6B' }
        elseif ($null -eq $x.E) { $d = [string][char]0x25CF + ' running'; $dc = '#FFFFB020' }
        elseif ($x.Auto) { $d = 'auto'; $dc = '#FF777777' }
        else { $du = $x.E - $x.S; $late = $du - $len; $d = (Format-MMSS $du) + $(if ($x.Kind -eq 'off') { '' } elseif ($late -gt 59) { ' late' } else { ' ' + [char]0x2713 }); $dc = $(if ($x.Kind -eq 'off') { '#FFCCCCCC' } elseif ($late -gt 59) { '#FFFF6B70' } else { '#FF34C759' }) }
        & $row $nm $(if ($x.Kind -eq 'off') { '#FFAAAAAA' } else { '#FFFFB020' }) $tx $d $dc ([bool]$x.Auto) ([bool]$x.AutoClosed)
    }
    & $row 'CLOCK OUT' '#FFFF6B70' ((Format-ClockS $m.Out.T) + $(if ($m.Out.Auto) { ' auto' } else { '' })) $(if ($m.Out.Auto) { '' } else { [string][char]0x2713 }) '#FF34C759' $m.Out.Auto $false
}
function Update-PunchTick($now) {
    if ($null -eq $script:PL) { return }
    if ($null -eq $now) { $now = Get-PunchNow }
    $t = $now.Hour * 3600 + $now.Minute * 60 + $now.Second; $pl = $script:PL; $r = $pl.R
    $V = [System.Windows.Visibility]
    $clk = { param($sec) Format-Clock ([int][math]::Floor($sec / 60)) }
    # v1.15.0 card style: idle = dim digits, running = amber card + glow, done = white digits + on time / late
    $on = { param($box, $txt, $glow, [string]$state) $txt.Foreground = Brush $(switch ($state) { 'run' { '#FFFFB020' } 'idle' { '#FF4A4A4A' } default { '#FFFFFFFF' } }); $glow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString('#FFFFB020'); $glow.Opacity = $(if ($state -eq 'run') { 0.85 } else { 0 })
            $box.BorderBrush = Brush $(if ($state -eq 'run') { '#FFFFB020' } else { '#FF2C2C2C' }); $box.Background = Brush $(if ($state -eq 'run') { '#FF2A1F08' } else { '#FF161616' }) }
    $nb = $(if ($r) { $r.Br.Count } else { 0 }); $bl = $script:BreakLen * 60
    $card = { param($n, $b, [int]$no)
        $live = $ui[$n + 'Live']; $sub = $(if ($n -eq 'Brk') { $ui.BrkTot } else { $ui[$n + 'Sub'] }); $foot = $ui[$n + 'Foot']; $sub.Foreground = Brush '#FF8A8A8A'
        if ($null -eq $b) { $live.Text = '--:--'; $sub.Text = [string]$script:BreakLen + ' min'; $foot.Text = $(if ($no -eq 2 -and $nb -lt 1) { 'after break 1' } else { 'not taken yet' }); & $on $ui[$n + 'Box'] $live $ui[$n + 'Glow'] 'idle' }
        elseif ($null -eq $b[1]) { $live.Text = Format-MMSS ($t - [int]$b[2]); $sub.Text = [string][char]0x25CF + ' running'; $foot.Text = 'LEFT ' + (& $clk $b[2]) + "`nBACK BY " + (& $clk ([int]$b[2] + $bl)); & $on $ui[$n + 'Box'] $live $ui[$n + 'Glow'] 'run' }
        else { $du = [int]$b[3] - [int]$b[2]; $late = $du - $bl; $live.Text = Format-MMSS $du
               if ($b[4]) { $sub.Text = [string][char]0x26A0 + ' END not pressed'; $sub.Foreground = Brush '#FFFF6B70' }
               elseif ($late -gt 59) { $sub.Text = '+' + (Format-Late $late) + ' late'; $sub.Foreground = Brush '#FFFF6B70' } else { $sub.Text = 'on time'; $sub.Foreground = Brush '#FF34C759' }
               $foot.Text = ((& $clk $b[2]) -replace ' [AP]M$', '') + [string][char]0x2013 + (& $clk $b[3]) + $(if ($no -eq 2 -and $nb -gt 2) { $dot + ($nb - 1) + ' breaks' } else { '' }); & $on $ui[$n + 'Box'] $live $ui[$n + 'Glow'] 'done' } }
    & $card 'Brk' $(if ($nb -ge 1) { $r.Br[0] } else { $null }) 1
    & $card 'Brk2' $(if ($nb -ge 2) { $r.Br[$nb - 1] } else { $null }) 2
    $brTot = $pl.Closed + $(if ($pl.Ob) { $t - [int]$pl.Ob[2] } else { 0 })
    $ll = [int]$pl.LunLen * 60; $ui.LunSub.Foreground = Brush '#FF8A8A8A'
    # v2.0.4 today's totals: breaks (Break 1 + Break 2 + more), lunch, combined; amber while one is running
    $dtLDone = ($r -and $null -ne $r.Lo -and $null -ne $r.Li)
    $dtLun = $(if ($pl.LunchOpen) { $t - [int]$r.LoS } elseif ($dtLDone) { [int]$r.LiS - [int]$r.LoS } else { 0 })
    $ui.DtB.Text = Format-MMSS $brTot; $ui.DtL.Text = Format-MMSS $dtLun; $ui.DtA.Text = Format-MMSS $brTot   # v2.0.11: TOTAL TODAY = breaks only (Break 1 + Break 2 + extras), lunch has its own box
    foreach ($dtP in @(@('B', [bool]$pl.Ob), @('L', [bool]$pl.LunchOpen))) { $dtBx = $ui['Dt' + $dtP[0] + 'Box']; $dtTx = $ui['Dt' + $dtP[0]]
        $dtBx.BorderBrush = Brush $(if ($dtP[1]) { '#FFFFB020' } else { '#FF2C2C2C' }); $dtBx.Background = Brush $(if ($dtP[1]) { '#FF2A1F08' } else { '#FF141414' }); $dtTx.Foreground = Brush $(if ($dtP[1]) { '#FFFFB020' } else { '#FFFFFFFF' }) }
    $ui.BrkTotal.Text = $(if ($nb) { [string]$nb + ' break' + $(if ($nb -gt 1) { 's' } else { '' }) } else { 'no breaks yet' }) + ' (' + $(if ($script:BreakPaid) { 'paid' } else { 'unpaid' }) + ')' + $dot + $(if ($pl.LunchOpen) { 'lunch running' } elseif ($dtLDone) { 'lunch done' } else { 'no lunch yet' })
    if ($pl.LunchOpen) { $ui.LunLive.Text = Format-MMSS ($t - [int]$r.LoS); $ui.LunSub.Text = [string][char]0x25CF + ' running'; $ui.LunFoot.Text = 'LEFT ' + (& $clk $r.LoS) + $dot + 'BACK BY ' + (& $clk ([int]$r.LoS + $ll)); & $on $ui.LunBox $ui.LunLive $ui.LunGlow 'run' }
    elseif ($r -and $null -ne $r.Lo -and $null -ne $r.Li) { $du = [int]$r.LiS - [int]$r.LoS; $late = $du - $ll; $ui.LunLive.Text = Format-MMSS $du
        if ($late -gt 59) { $ui.LunSub.Text = '+' + (Format-Late $late) + ' late'; $ui.LunSub.Foreground = Brush '#FFFF6B70' } else { $ui.LunSub.Text = 'on time'; $ui.LunSub.Foreground = Brush '#FF34C759' }
        $ui.LunFoot.Text = ((& $clk $r.LoS) -replace ' [AP]M$', '') + [string][char]0x2013 + (& $clk $r.LiS); & $on $ui.LunBox $ui.LunLive $ui.LunGlow 'done' }
    else { $ui.LunLive.Text = '--:--'; $ui.LunSub.Text = [string]$pl.LunLen + ' min'; $ui.LunFoot.Text = $(if ($script:LunchBreak) { 'scheduled ' + (Format-Clock ([int]$script:LunchBreak.S)) } else { 'not taken yet' }); & $on $ui.LunBox $ui.LunLive $ui.LunGlow 'idle' }
    $aw = $pl.Away
    if ($aw) {
        $nmA = $(if ($aw.Kind -eq 'break') { 'BREAK ' + $aw.No } else { 'LUNCH' }); $cn = $(if ($aw.Kind -eq 'break') { $(if ($aw.No -eq 2) { 'Brk2' } else { 'Brk' }) } else { 'Lun' })
        $runBox = $ui[$cn + 'Box']; $runTxt = $ui[$cn + 'Live']; $runGlow = $ui[$cn + 'Glow']; $ui.BackBox.Visibility = $V::Visible
        $rem = $aw.Due - $t; $ui.BackLeft.Text = 'LEFT ' + (Format-Clock ([int][math]::Floor($aw.Left / 60)))
        $phase = $(if ($script:FlashForce) { $true } else { ($t % 2) -eq 0 })
        if ($rem -lt 0) {   # overdue: solid red LATE +m:ss
            $ui.BackLab.Text = $nmA + $dot + 'LATE'; $ui.BackLeft.Text = 'DUE ' + (Format-Clock ([int][math]::Floor($aw.Due / 60))); $ui.BackTime.Text = '+' + (Format-Late (-$rem)); $ui.BackAmPm.Text = ''
            $ui.BackSub.Text = 'left ' + (Format-Clock ([int][math]::Floor($aw.Left / 60))) + $dot + 'press ' + $(if ($aw.Kind -eq 'break') { 'END BREAK ' + $aw.No } else { 'BACK FROM LUNCH' })
            $fg = '#FFFFFFFF'; $bg = '#FFB3121B'; $bd = '#FFFF3B30'; $gl = '#FFFF3B30'; $go = 0.9
            $runTxt.Foreground = Brush '#FFFF453A'; $runGlow.Color = [System.Windows.Media.Color]::FromRgb(255, 59, 48); $runGlow.Opacity = 0.9; $runBox.Background = Brush '#FF3A0C0E'; $runBox.BorderBrush = Brush '#FFFF3B30'
        } else {
            $dueTxt = Format-Clock ([int][math]::Floor($aw.Due / 60)); $ui.BackLab.Text = $nmA + $dot + 'TIME LEFT'; $ui.BackTime.Text = Format-MMSS $rem; $ui.BackAmPm.Text = ''   # v2.0.12: the countdown is the biggest number on screen
            $ui.BackSub.Text = 'be back by ' + $dueTxt + $(if ($rem -le $aw.Warn) { $dot + 'almost time' } else { '' })
            if ($rem -le $aw.Warn) {   # final window: strong amber / red pulse every second
                if ($phase) { $fg = '#FFFFFFFF'; $bg = '#FFC2410C'; $bd = '#FFFF3B30'; $gl = '#FFFF3B30'; $go = 1.0; $tc = '#FFFF453A'; $tb = '#FF4A0E0E' }
                else        { $fg = '#FF1A1A1A'; $bg = '#FFFFB020'; $bd = '#FFFFD27A'; $gl = '#FFFFB020'; $go = 1.0; $tc = '#FFFFB020'; $tb = '#FF3A2A08' }
                $runTxt.Foreground = Brush $tc; $runBox.Background = Brush $tb; $runBox.BorderBrush = Brush $bd; $runGlow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($gl); $runGlow.Opacity = 1.0
            } else { $fg = '#FFFFB020'; $bg = '#FF2A1F08'; $bd = '#FFFFB020'; $gl = '#FFFFB020'; $go = 0.8 }
        }
        $ui.BackTime.Foreground = Brush $fg; $ui.BackAmPm.Foreground = Brush $fg; $ui.BackLab.Foreground = Brush $(if ($fg -eq '#FF1A1A1A') { '#FF1A1A1A' } else { '#FFFFFFFF' }); $ui.BackSub.Foreground = $ui.BackLab.Foreground
        $ui.BackBox.Background = Brush $bg; $ui.BackBox.BorderBrush = Brush $bd; $ui.BackGlow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($gl); $ui.BackGlow.Opacity = $go
        $sub = $(if ($cn -eq 'Brk') { $ui.BrkTot } else { $ui[$cn + 'Sub'] }); $sub.Text = $(if ($rem -lt 0) { 'LATE' } else { (Format-MMSS $rem) + ' left' }); $sub.Foreground = Brush $(if ($rem -lt 0) { '#FFFF6B70' } else { '#FFFFB020' })
    } else { $ui.BackBox.Visibility = $V::Collapsed }
    foreach ($lt in @($script:LiveTL)) { if ($lt) { $ui["TL$($lt[0])X"].Text = (Format-MMSS ($t - $lt[1])) + $lt[2] } }
    if ($null -ne $script:NextLiveFrom -and $script:NextLiveRun) { $script:NextLiveRun.Text = Format-MMSS ($t - $script:NextLiveFrom) }
}
function Invoke-Punch([string]$k) {
    if ($TestMode -and $script:TestState -eq 'idle') { return }
    $n = Get-PunchNow; $iso = $n.ToString('yyyy-MM-dd'); $t = $n.Hour * 3600 + $n.Minute * 60 + $n.Second
    $r = Get-PunchRec $iso; $openBr = ($r -and $r.Br.Count -and $null -eq $r.Br[$r.Br.Count - 1][1])
    $nbk = $(if ($r) { $r.Br.Count } else { 0 })   # v1.15.0 BREAK 1 / BREAK 2 buttons -> the same bs / be punches (1st = Break 1, 2nd = Break 2)
    switch ($k) { 'bs1' { if ($nbk -gt 0 -or $openBr) { return }; $k = 'bs' } 'bs2' { if ($nbk -lt 1 -or $openBr) { return }; $k = 'bs' }
                  'be1' { if (-not ($openBr -and $nbk -eq 1)) { return }; $k = 'be' } 'be2' { if (-not ($openBr -and $nbk -ge 2)) { return }; $k = 'be' } }
    if ($k -eq 'be' -and -not $openBr) { return }; if ($k -eq 'bs' -and $openBr) { return }; if ($k -eq 'li' -and -not ($r -and $null -ne $r.Lo)) { return }
    if (-not $script:Punches.ContainsKey($iso)) { $script:Punches[$iso] = New-Object System.Collections.ArrayList }
    $lst = $script:Punches[$iso]; if ($lst.Count -and [string]$lst[$lst.Count - 1][0] -eq $k -and ($t - [int]$lst[$lst.Count - 1][1]) -lt 2) { return }   # double-click guard
    [void]$lst.Add(@($k, $t)); Save-Punches; Update-Ui
}
function Invoke-PunchUndo { $iso = (Get-PunchNow).ToString('yyyy-MM-dd'); $l = $script:Punches[$iso]
    if ($l -and $l.Count) { $l.RemoveAt($l.Count - 1); if ($l.Count -eq 0) { $script:Punches.Remove($iso) }; Save-Punches; Update-Ui } }
function Invoke-PunchReset { $iso = (Get-PunchNow).ToString('yyyy-MM-dd')
    if ($script:Punches.ContainsKey($iso)) {
        $ans = [System.Windows.MessageBox]::Show("Reset today's punches to the automatic schedule?", 'Paycheck Live', [System.Windows.MessageBoxButton]::YesNo)
        if ($ans -eq [System.Windows.MessageBoxResult]::Yes) { $script:Punches.Remove($iso); Save-Punches; Update-Ui } } }
$script:FlashForce = [bool]$RenderPng
$script:PL = $null; $script:LiveTL = @(); $script:NextLiveFrom = $null; $script:NextLiveRun = $null; $script:LastScrollDay = $null

function Update-TestClock {
    $now = Get-TestSimNow
    $ui.DateLabel.Text = 'SIM ' + $now.ToString('ddd', $inv) + ' ' + $now.ToString('h:mm:ss tt', $inv)
    Update-PunchTick $now
}

# ---------------------------------------------------------------- v1.6.0 display ON/OFF (Gaussian blur over the content) + changelog
$script:DisplayOn = $true
try { if (Test-Path -LiteralPath $displayPath) { $script:DisplayOn = [bool]((Get-Content -LiteralPath $displayPath -Raw | ConvertFrom-Json).on) } } catch {}
function Set-DisplayUi {
    if ($script:DisplayOn) {
        $ui.ContentGrid.Effect = $null; $ui.ContentGrid.IsHitTestVisible = $true
        $ui.ToggleTxt.Text = 'ON'; $ui.ToggleBtn.Background = Brush '#FFE82127'
    } else {
        $fx = New-Object System.Windows.Media.Effects.BlurEffect
        $fx.Radius = 44; $fx.KernelType = [System.Windows.Media.Effects.KernelType]::Gaussian; $fx.RenderingBias = [System.Windows.Media.Effects.RenderingBias]::Quality
        $ui.ContentGrid.Effect = $fx; $ui.ContentGrid.IsHitTestVisible = $false
        $ui.ToggleTxt.Text = 'OFF'; $ui.ToggleBtn.Background = Brush '#FF333333'
    }
}
$ui.ToggleBtn.Add_Click({
    $script:DisplayOn = -not $script:DisplayOn
    try { Set-Content -LiteralPath $displayPath -Value ('{"on": ' + $(if ($script:DisplayOn) { 'true' } else { 'false' }) + '}') -Encoding ASCII } catch {}
    Set-DisplayUi
})
$Changelog = @'
v2.0.15  (2026-10-22 22:46 CT)
  * 2-week Daily money made list removed
  * UPDATE works like TessDesk: green YES UPDATE (pulsing, tap installs) / red NO UPDATE (tap checks now)
  * Android app (APK) and fresh Windows Setup on the download page; phone app works offline

v2.0.14  (2026-10-16 14:25 CT)
  * Paycheck Live now lives at a permanent address (vanwidick.github.io/paycheck-live): the phone app and PC updates never change address again.
  * Phones move over automatically with their profile, punches and PTO; the UPDATE button keeps working.

v2.0.13  (2026-10-16 10:55 CT)
  * Shared copies (Share link / installer) now start blank: no pay rate, hours, punches, PTO or personal settings prefilled.
  * New UPDATE button: shows only when a newer version is out; tap it to install/refresh right away. Hidden when up to date.

v2.0.12  (2026-10-15 23:29 CT)
  * While a break or lunch is running, the countdown (time left) is now the biggest number on screen; 'be back by' time is shown under it.

v2.0.11  (2026-10-15 12:15 CT)
  * PTO: pick a day and the hours you missed (e.g. 11:30 AM to 4 PM); paid at base rate with no differentials, added to that day and the pay period, shown as its own PTO line (PC: PTO link next to Edit; phone: PTO section under the schedule).
  * TOTAL TODAY under the timers now counts breaks only (Break 1 + Break 2 + extras); lunch keeps its own box.

v2.0.10  (2026-10-10 21:38 CT)
  * Punch buttons in a 2-column grid: CLOCK IN (full width) / BREAK 1 | BREAK 1 BACK / LUNCH START | LUNCH BACK / BREAK 2 | BREAK 2 BACK / CLOCK OUT (full width, red). Same punch logic.

v2.0.9  (2026-10-10 21:23 CT)
  * DESIGN BY VAN footer back at the bottom: the window is full height again (the v2.0.8 fit-to-content height cap moved the footer up). The 2-week DAILY MONEY MADE section stays removed.

v2.0.8  (2026-10-10 20:04 CT)
  * Removed the DAILY MONEY MADE 2-week daily list and period total (everything from that heading down to the DESIGN BY VAN footer); the PC window now fits its content. Edit punches: new -1 / +1 minute buttons next to -15 / -5 / +5 / +15 (each saves right away).

v2.0.7  (2026-10-08 16:22 CT)
  * Edit punches: a late clock in (or early clock out) now saves even when the schedule lunch/break falls outside the shift: that line is dropped and the day is marked No lunch (late start = no lunch). Typed times like 4, 4pm, 4:00 PM or 1600 pick the sensible AM/PM; -15/-5/+5/+15 save in one tap; Enter / Go / Done saves; SAVED check shows; NO LUNCH button on the lunch line.

v2.0.6  (2026-10-08 16:18 CT)
  * Edit punches: type times the easy way (4, 4pm, 4:00 PM, 1600 — picks AM/PM for you), -15 / -5 / +5 / +15 buttons that save in one tap (clock in too), big green SAVE stays visible, Enter / Done saves, 'SAVED ✓' confirmation, and a NO LUNCH button.

v2.0.5  (2026-10-08 13:55 CT)
  * Today's break + lunch totals next to the timers: BREAKS (Break 1 + Break 2), LUNCH and TOTAL TODAY, from your punches (including fixes in Edit punches), counting up live while a break or lunch runs. Includes the v2.0.4 X (close) on the OFF card.

v2.0.4  (2026-10-04 17:00 CT)
  * PC: X (close) on the OFF / mini card too: closes the window and exits, same as the title-bar X.

v2.0.3  (2026-10-04 00:56 CT)
  * PC: only the gray Restore / Remember pair (top right, fades in on hover) — the green pills under the footer are gone; the OFF card snapshot no longer shows the Restore / Remember buttons.

v2.0.2  (2026-10-04 00:27 CT)
  * PC: OFF button (hover, top-left) shrinks the window to a small card like TessDesk; ON brings it back, Restore moves it to its saved place. REMEMBER / RESTORE pills under the DESIGN BY VAN footer (same as TessDesk).

v2.0.1  (2026-10-03 11:54 CT)
  * Edit punches: big green SAVE + CANCEL pinned at the bottom (stays above the phone keyboard); Enter saves; 'Saved' confirmation; -5/+5/END = NOW save in one tap; typed times like 3:05 PM work everywhere; fixed the PC punch editor not opening

v2.0.0  (2026-10-03 03:14 CT)
  * Paycheck Live is now a real Windows app: PaycheckLive.exe with its own icon, Setup installer (no admin), Start menu + Desktop shortcuts, optional start with Windows, listed in Settings > Apps
  * Your data now lives in %APPDATA%\PaycheckLive (copied from the old widget folder, nothing removed)
  * Update now downloads, replaces and relaunches the app by itself
  * New Share button (by the gear and in Settings): Messenger, Text, Email, Copy link, Send to a phone (QR)
  * Restore / Remember buttons (top right, show on hover) save and restore the window's place and size
  * Phone: Share button + installable app (add to home screen)

v1.15.0  (2026-10-02 17:08 CT)
  * New layout: today's clock in/out, breaks and lunch are the focus. Smaller net amount on top; bigger status, buttons, LEFT / BE BACK BY and stopwatches.
  * BREAK 1 and BREAK 2: separate START / END buttons, each with its own stopwatch, LEFT / BACK BY time and on-time/late. Total break time kept.
  * Today's punch list (tap a line to edit). Gross breakdown + schedule below; DAILY MONEY MADE at the bottom.

v1.14.2  (2026-10-02 16:30 CT)
  * EDIT PUNCHES: fix a forgotten END BREAK with one tap (15 MIN), change/add/delete breaks and lunch, edit clock in/out, today or earlier days this pay period.
  * A break whose END BREAK was not pressed now shows an orange warning; tap it to fix.

v1.14.1  (2026-10-02 16:07 CT)
  * Fix: today's money no longer resets after lunch. CLOCK IN after lunch (or CLOCK OUT / CLOCK IN used for lunch) now resumes from the pre-lunch amount instead of restarting the day; the 11:30 start always counts.
  * A forgotten END BREAK now closes itself at the next lunch / break / clock punch.

v1.14.0  (2026-10-02 11:06 CT)
  * Today's GROSS pay breakdown under the big total: Regular, Shift diff (after 6 PM + weekend, stacking), Overtime (with hours) and Total gross - live.
  * DAILY MONEY MADE now shows each day's shift diff and OT (hours + $), and week / period totals of shift diff, OT and gross.
  * Overtime: hours over 40 in the Sat-Fri workweek pay 1.5x (base + diff); taxes and net include it. Settings: Overtime after [40] hrs/week at [1.5]x.
  * TEST: right-click +5m for +15 min / +1 hour / +1 day (phone: +1h, +1d) to check overtime.

v1.13.0  (2026-10-02 10:40 CT)
  * BE BACK BY: when you press START BREAK or OUT TO LUNCH the widget shows the time you LEFT and a big BE BACK BY time (break = your break length, default 15 min; lunch = your profile lunch length, 60 min for Van). It's the most prominent thing on the panel and also shows in the status line.
  * Flashing warning: the break timer and BE BACK BY flash amber/red during the last 5 minutes of a break and the last 15 minutes of lunch. Once you're overdue it turns solid red: LATE +m:ss.
  * After a break or lunch ends, a small note keeps the left -> back times and whether you were on time or late; the break and lunch totals stay as before.
  * New Break length (min) setting (default 15) in Settings and the first-run setup.
  * PAYCHECK TEST: new +5m fast-forward button next to START / STOP to check BE BACK BY, the flashing and LATE.

v1.12.2  (2026-10-02 10:22 CT)
  * Clock panel: START BREAK and END BREAK now sit side by side on one line, with two large BREAK and LUNCH timers underneath (about 3x bigger). The running timer glows amber; when idle, BREAK shows today's total and LUNCH shows the final lunch length. Spacing elsewhere tightened slightly so everything still fits in 288x720.

v1.12.1  (2026-10-01 15:29 CT)
  * The first-time setup wizard (and the INSTALLER PREVIEW setup) now opens on the widget display instead of wherever the mouse is; the preview wizard opens right at the preview window.

v1.12.0  (2026-10-01 15:24 CT)
  * DAILY MONEY MADE replaces the pay period / next paycheck / pay history section: every day of the current pay period (days off show Day off - $0.00), today marked, future days projected, Sat-Fri week subtotals and the period total = approx. paycheck (net, gross small).
  * Manual clock buttons: CLOCK IN, OUT TO LUNCH, BACK FROM LUNCH, CLOCK OUT record your actual times for today and override the automatic schedule; Undo and Reset to auto.
  * START BREAK / END BREAK with a live mm:ss break timer and today's break total; OUT TO LUNCH starts a live lunch stopwatch that shows the final lunch length after BACK FROM LUNCH. Breaks are paid or unpaid per your profile (default paid).
  * Pay, the live total, the schedule timeline and the daily list all use your punches; break and lunch lengths show in the timeline and are saved per date.
  * Settings gear now sits right next to the PAYCHECK LIVE heading; setup and settings ask for the full weekly schedule (per-day times, days off) and whether extra breaks are paid.
  * New Paycheck Live INSTALLER PREVIEW (PC window + phone page) runs the full first-time setup fresh every time it opens without touching your real profile.
  * Release channel is now LIVE; PAYCHECK TEST is built from LIVE and is identical except the START/STOP simulator.

v1.11.0  (2026-09-29 16:12 CT)
  * First-run SETUP WIZARD: name, hourly rate, work days and shift times, lunch/breaks (paid or unpaid), differentials, weekly or every-2-weeks pay, pay-week start, next payday, filing status, state, pre-tax (e.g. 401(k) %) and after-tax (e.g. stock purchase) deductions. Your setup name is what shows in the Users list.
  * Gear-icon SETTINGS / PROFILE page to edit everything after install.
  * TODAY'S SCHEDULE timeline replaces the shift breakdown under the big net amount: clock in, breaks, lunch, differential start and clock out, with the current segment highlighted and a countdown to the next event.
  * Full paycheck lines: every pre-tax and after-tax deduction plus federal, state, Social Security and Medicare.
  * Support the creator (optional, suggested $1): Venmo and PayPal in Settings, plus a small link by the footer.
  * Profile-driven pay and tax engine (no hardcoded pay); Van's profile is the default on his copies.

v1.10.2  (2026-09-29 15:45 CT)
  * Release-channel test of the phone update flow (no pay changes).

v1.10.1  (2026-09-29 15:42 CT)
  * PC: fixed first-run install registration (HTTP assembly now loads before the install log is sent).

v1.10.0  (2026-09-29 ~16:00 CT)
  * Pay corrected from Van's real paystub: base rate $26.46/hr (was $26.75); differentials unchanged (+$2 after 6 PM, +$2 weekends, stacking).
  * 401(k) pre-tax is 10% of gross (was 7%).
  * New $50.00 AFTER-TAX stock purchase deduction per biweekly check, shown on its own line and spread across shifts.
  * UPDATE button next to the version: checks the published version manifest, lights up when a newer version exists, pop-up with changelog (Update now / Later); one-tap self-update with backup + restart.
  * First-run install registration (name, version, platform) to Van's Users sheet.

v1.9.0  (2026-09-29 ~04:15 CT)
  * BIWEEKLY pay: Wednesday paydays every 2 weeks (9/30, 10/14, 10/28, ...); each check covers the two Sat-Fri weeks ending the Friday before payday.
  * Pay period section shows both weeks day by day; countdown + expected paycheck are the 2-week amount.
  * Withholding from the Pub 15-T 2026 BIWEEKLY HOH table and Oklahoma OW-2 Table 2 (bi-weekly), 401(k) 7% pre-tax.
  * TEST widget: simulated paydays follow the same biweekly pattern.

v1.8.0  (2026-09-29 ~04:00 CT)
  * Desktop placement pinned to Van's left-screen lineup on DISPLAY1: LIVE at WorkArea.Right-681, TEST at WorkArea.Right-981, tops at +42 (survives restarts).
  * Widget height back to 288x720 with the DESIGN BY VAN footer (layout tightened, nothing clipped).

v1.7.0  (2026-09-29 ~03:45 CT)
  * Dani edition: first-run setup wizard (rate, pay frequency + next payday, work days, start/end, lunch, hours/week, federal filing status, Oklahoma yes/no + allowances, optional 401(k)); nothing personal built in.
  * Tap any day to enter start/end time, lunch, or extra overtime hours; live counter follows the entered times.
  * Overtime: shift hours over 40 in the work week and manually entered extra hours are paid at 1.5x (each hour counted once).
  * Settings: re-run setup, or reset everything and start over. "Private by design" note; all data stays on the device.

v1.6.0  (2026-09-29 ~03:40 CT)
  * Display ON/OFF toggle: OFF applies a heavy blur over the numbers (toggle stays sharp); state is remembered.
  * "DESIGN BY VAN" footer with version + date; tap the version to see this changelog.

v1.5.0  (2026-09-29 02:32 CT)
  * Hosted phone pages (public-safe build): home-screen install (web app manifest + icons), offline service worker, tax profile carried in the link fragment instead of the file.

v1.4.0  (2026-09-29 02:27 CT)
  * Android phone pages: LIVE (real Central clock) and TEST (START/STOP simulated clock).

v1.3.0  (2026-09-29 02:21 CT)
  * TEST clock runs continuously across days and weeks; days before START count $0.
  * Day-off hero: on days off the headline shows the day name with "DAY OFF".

v1.2.0  (2026-09-29 02:17 CT)
  * TEST widget with START (reset) / STOP (freeze) simulated clock and its own desktop shortcut.

v1.1.0  (2026-09-29 02:08 CT)
  * Headline switched to approximate NET pay: IRS Pub 15-T 2026 federal withholding, Social Security, Medicare, Oklahoma OW-2 withholding, pre-tax deductions; editable tax-settings file. (Gross-only build kept as a .bak.)

v1.0.0  (2026-09-29 01:49 CT)
  * First release: desktop Paycheck Live widget (WPF) - live shift earnings from the schedule, shift differentials, pay week, next paycheck, pay-history tiles; desktop + startup shortcut installer.
'@
$ui.VersionText.Add_MouseLeftButtonUp({ [void][System.Windows.MessageBox]::Show($Changelog, ('Paycheck Live v' + $AppVersion + ' - version history')) })
if ($DisplayOff) { $script:DisplayOn = $false }   # render/verification hook
Set-DisplayUi

$ui.TitleBar.Add_MouseLeftButtonDown({ param($sender, $e) try { $window.DragMove() } catch {} })
$ui.CloseBtn.Add_Click({ $window.Close() })
$ui.GearBtn.Add_Click({
    $oldName = [string]$script:Profile.name
    if (Show-Settings $false) {
        $script:Inst.name = [string]$script:Profile.name; Save-Inst
        if ($TestMode) { $script:TestDay = $null }
        Update-Ui
        if ($oldName -ne $script:Inst.name) { Send-Log 'profile' }
    }
})
foreach ($d in $pbDefs) { $kk = $d[0]; $ui['PB_' + $kk].Tag = $kk; $ui['PB_' + $kk].Add_Click({ param($sender, $e) Invoke-Punch ([string]$sender.Tag) }) }
$ui.PUndo.Add_Click({ Invoke-PunchUndo }); $ui.PReset.Add_Click({ Invoke-PunchReset })

# ---------------------------------------------------------------- v2.0.0 SHARE sheet: Messenger, Text/SMS (QR), Email, Copy link, Send to a phone (QR + install steps)
function Get-SiteBase { if ($UpdateApi) { return ($UpdateApi -replace '/api.*$', '') } return '' }
function Get-ShareUrl { if ($script:Latest -and $script:Latest.shareUrl) { return [string]$script:Latest.shareUrl }; if ($ShareUrlDefault -notlike '__*') { return $ShareUrlDefault }; $b = Get-SiteBase; if ($b) { return $b + '/get' }; return '' }
function Get-PhoneUrl { if ($script:Latest -and $script:Latest.phoneUrl) { return [string]$script:Latest.phoneUrl }; return (Get-ShareUrl) }
function Get-QrImage([string]$data) {
    try { $b = Get-SiteBase; if ($b -and -not $NoNetwork) {
            $bytes = (Get-Http).GetByteArrayAsync($b + '/qr.png?d=' + [Uri]::EscapeDataString($data)).GetAwaiter().GetResult()
            $ms = New-Object IO.MemoryStream(, $bytes); $bi = New-Object System.Windows.Media.Imaging.BitmapImage; $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.StreamSource = $ms; $bi.EndInit(); $bi.Freeze(); return $bi } } catch {}
    try { $f = Join-Path $scriptDir 'share-qr.png'; if (Test-Path -LiteralPath $f) { return (New-Object System.Windows.Media.Imaging.BitmapImage([Uri]$f)) } } catch {}
    return $null
}
function Show-ShareSheet($owner) {
  try {
    $link = Get-ShareUrl; $phone = Get-PhoneUrl
    $msg = 'Check out Paycheck Live: watch your paycheck grow in real time, track clock in/out, breaks and lunch, and see your take-home pay. Free from DESIGN BY VAN. Get it here: ' + $link
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Share Paycheck Live" Width="380" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI">
  <Window.Resources>
    <ControlTemplate x:Key="SB" TargetType="Button"><Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="#FF333333" BorderThickness="1" CornerRadius="10" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border>
      <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#FFE82127"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.7"/></Trigger></ControlTemplate.Triggers></ControlTemplate>
  </Window.Resources>
  <Border Background="#FF111111" BorderBrush="#FF3A3A3A" BorderThickness="1" CornerRadius="12" Padding="16,12,16,14">
    <StackPanel>
      <Grid><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72D;" FontFamily="Segoe MDL2 Assets" Foreground="#FFE82127" FontSize="15" VerticalAlignment="Center"/>
          <TextBlock Text="  SHARE PAYCHECK LIVE" Foreground="#FFFFFFFF" FontSize="14" FontWeight="Black" VerticalAlignment="Center"/></StackPanel>
        <Button x:Name="XClose" HorizontalAlignment="Right" Content="&#x2715;" Background="Transparent" Foreground="#FF888888" BorderThickness="0" FontSize="12" Width="24" Cursor="Hand"/></Grid>
      <TextBlock Text="Send the free download link to a friend, or put Paycheck Live on your phone." Foreground="#FF999999" FontSize="11" TextWrapping="Wrap" Margin="0,4,0,10"/>
      <UniformGrid Columns="2">
        <Button x:Name="XMsgr" Template="{StaticResource SB}" Background="#FF0A2A5C" Padding="10,8" Margin="0,0,4,6" Cursor="Hand"><StackPanel><TextBlock Text="&#xE8BD;  Messenger" FontFamily="Segoe UI, Segoe MDL2 Assets" Foreground="#FFFFFFFF" FontSize="13" FontWeight="Bold"/><TextBlock Text="Facebook Messenger" Foreground="#FF9EC2FF" FontSize="10"/></StackPanel></Button>
        <Button x:Name="XSms" Template="{StaticResource SB}" Background="#FF0F3B1D" Padding="10,8" Margin="4,0,0,6" Cursor="Hand"><StackPanel><TextBlock Text="&#xE8BD;  Text / SMS" FontFamily="Segoe UI, Segoe MDL2 Assets" Foreground="#FFFFFFFF" FontSize="13" FontWeight="Bold"/><TextBlock Text="scan the QR to text it" Foreground="#FF9EE6B4" FontSize="10"/></StackPanel></Button>
        <Button x:Name="XMail" Template="{StaticResource SB}" Background="#FF2A2A2A" Padding="10,8" Margin="0,0,4,6" Cursor="Hand"><StackPanel><TextBlock Text="&#xE715;  Email" FontFamily="Segoe UI, Segoe MDL2 Assets" Foreground="#FFFFFFFF" FontSize="13" FontWeight="Bold"/><TextBlock Text="opens your mail app" Foreground="#FFAAAAAA" FontSize="10"/></StackPanel></Button>
        <Button x:Name="XCopy" Template="{StaticResource SB}" Background="#FF2A2A2A" Padding="10,8" Margin="4,0,0,6" Cursor="Hand"><StackPanel><TextBlock Text="&#xE8C8;  Copy link" FontFamily="Segoe UI, Segoe MDL2 Assets" Foreground="#FFFFFFFF" FontSize="13" FontWeight="Bold"/><TextBlock x:Name="XLinkSmall" Text="" Foreground="#FFAAAAAA" FontSize="10" TextTrimming="CharacterEllipsis"/></StackPanel></Button>
      </UniformGrid>
      <Button x:Name="XPhone" Template="{StaticResource SB}" Background="#FF3B0F12" Padding="10,8" Cursor="Hand"><StackPanel><TextBlock Text="&#xE8EA;  Send to a phone" FontFamily="Segoe UI, Segoe MDL2 Assets" Foreground="#FFFFFFFF" FontSize="13" FontWeight="Bold"/><TextBlock Text="big QR code + install steps for Android / iPhone" Foreground="#FFFFB3B3" FontSize="10"/></StackPanel></Button>
      <Border Background="#FF181818" BorderBrush="#FF2A2A2A" BorderThickness="1" CornerRadius="10" Padding="10" Margin="0,10,0,0">
        <StackPanel>
          <TextBlock x:Name="XQrHead" Foreground="#FFFFFFFF" FontSize="12.5" FontWeight="Bold" HorizontalAlignment="Center"/>
          <Border Background="#FFFFFFFF" CornerRadius="8" Padding="8" HorizontalAlignment="Center" Margin="0,8,0,6"><Image x:Name="XQr" Width="190" Height="190" RenderOptions.BitmapScalingMode="NearestNeighbor"/></Border>
          <TextBlock x:Name="XLink" Foreground="#FFFFB020" FontSize="13" FontWeight="Bold" HorizontalAlignment="Center" Cursor="Hand" TextDecorations="Underline"/>
          <TextBlock x:Name="XSteps" Foreground="#FFBBBBBB" FontSize="10.5" TextWrapping="Wrap" Margin="0,6,0,0"/>
        </StackPanel>
      </Border>
      <TextBlock x:Name="XStatus" Foreground="#FF34C759" FontSize="11" FontWeight="SemiBold" TextWrapping="Wrap" HorizontalAlignment="Center" Margin="0,8,0,0"/>
    </StackPanel>
  </Border>
</Window>
'@
    $d = [Windows.Markup.XamlReader]::Parse($x)
    try { if ($owner) { $d.Owner = $owner } else { $d.Owner = $window } } catch {}
    $g = @{}; foreach ($n in 'XClose','XMsgr','XSms','XMail','XCopy','XLinkSmall','XPhone','XQrHead','XQr','XLink','XSteps','XStatus') { $g[$n] = $d.FindName($n) }
    $g.XLinkSmall.Text = $link
    $copy = { param($t) try { [System.Windows.Clipboard]::SetText($t); return $true } catch { return $false } }
    $qr = { param($head, $data, $shown, $steps) $g.XQrHead.Text = $head; $g.XQr.Source = Get-QrImage $data; $g.XLink.Text = $shown; $g.XSteps.Text = $steps }
    $phoneSteps = '1. Scan with the phone camera and open the link in Chrome (Android) or Safari (iPhone).' + "`n" + '2. Android: tap Install app (or menu > Add to Home screen). iPhone: tap Share > Add to Home Screen.' + "`n" + '3. Open Paycheck Live from the home screen; it works like an app.'
    $g.XPhone.Add_Click({ & $qr 'SEND TO A PHONE' $phone $phone $phoneSteps; $g.XStatus.Text = '' })
    $g.XSms.Add_Click({ & $qr 'TEXT IT FROM YOUR PHONE' ('SMSTO::' + $msg) $link 'Scan with your phone: it opens a new text message with the link filled in. Pick who to send it to. (The link is also copied, to paste anywhere.)'
                       if (& $copy $msg) { $g.XStatus.Text = 'Message with the link copied to the clipboard.' } })
    $g.XCopy.Add_Click({ if (& $copy $link) { $g.XStatus.Text = 'Link copied: ' + $link } else { $g.XStatus.Text = 'Could not copy. The link is ' + $link } })
    $g.XMail.Add_Click({ $u = 'mailto:?subject=' + [Uri]::EscapeDataString('Paycheck Live: see your paycheck grow in real time') + '&body=' + [Uri]::EscapeDataString("Hi,`r`n`r`nI've been using Paycheck Live. It shows your take-home pay growing live while you work, and tracks clock in/out, breaks and lunch.`r`n`r`nIt's free (DESIGN BY VAN). Windows PC or phone:`r`n" + $link + "`r`n")
                        Open-Url $u; $g.XStatus.Text = 'Opening your email app' + [char]0x2026 })
    $g.XMsgr.Add_Click({ [void](& $copy $msg)
        $hasApp = $false; try { $hasApp = Test-Path 'Registry::HKEY_CLASSES_ROOT\fb-messenger' } catch {}
        if ($hasApp) { Open-Url ('fb-messenger://share?link=' + [Uri]::EscapeDataString($link)) } else { Open-Url 'https://www.messenger.com/new' }
        $g.XStatus.Text = 'Message copied. Pick a chat in Messenger and press Ctrl+V to paste it.' })
    $g.XLink.Add_MouseLeftButtonUp({ Open-Url $g.XLink.Text })
    $g.XClose.Add_Click({ param($s0, $e0) [System.Windows.Window]::GetWindow($s0).Close() }); $d.Add_MouseLeftButtonDown({ param($s0, $e0) try { $s0.DragMove() } catch {} })   # v2.0.0: close via the sender (no scope lookup)
    $d.Add_KeyDown({ param($s2, $e2) if ($e2.Key -eq 'Escape') { $s2.Close() } })
    & $qr 'SEND TO A PHONE' $phone $phone $phoneSteps
    if (-not $link) { $g.XStatus.Foreground = Brush '#FFFFB020'; $g.XStatus.Text = 'The share link is not available right now (update server offline).' }
    [void]$d.ShowDialog()
  } catch { try { [System.Windows.MessageBox]::Show('Share hit a problem: ' + $_.Exception.Message, 'Paycheck Live') | Out-Null } catch {} }
}
$ui.ShareBtn.Add_Click({ Show-ShareSheet $window })
# v1.14.2 EDIT PUNCHES dialog: fix a forgotten END BREAK (one click 15 MIN), change/add/delete breaks and lunch, edit clock in/out; today or earlier days this pay period
function Show-PunchEditor([string]$iso) {
  # v2.0.1: big green SAVE + CANCEL pinned at the bottom, Enter saves, Esc cancels, 'Saved' flash, -5/+5/END = NOW save in one click.
  # Every name here is unique on purpose (PowerShell names are case-insensitive: $b vs $B, $e vs $E broke v2.0.0).
  try {
    $peToday = (Get-PunchNow).Date; if (-not $iso) { $iso = $peToday.ToString('yyyy-MM-dd') }
    $peMinD = Get-PayPeriodStart $peToday
    if ($TestMode -and $script:TestDay) { try { $peTd = ([datetime]$script:TestDay).Date; if ($peTd -gt $peMinD) { $peMinD = $peTd } } catch {} }
    $PEST = @{ Iso = $iso; M = $null; Sel = $null }
    $peMkBtn = { param($qTxt, $qBg, $qFg, $qWid) $qBtn = New-Object Windows.Controls.Button; $qBtn.Content = $qTxt; $qBtn.Background = Brush $qBg; $qBtn.Foreground = Brush $qFg; $qBtn.BorderBrush = Brush '#FF3A3A3A'
           $qBtn.FontFamily = 'Segoe UI'; $qBtn.FontSize = 13; $qBtn.FontWeight = [System.Windows.FontWeights]::Bold; $qBtn.Height = 38; $qBtn.Margin = '3'; $qBtn.Cursor = 'Hand'; if ($qWid) { $qBtn.Width = $qWid }; return $qBtn }
    $peMkLbl = { param($qTxt, $qSz, $qFg) $qTb = New-Object Windows.Controls.TextBlock; $qTb.Text = $qTxt; $qTb.FontFamily = 'Segoe UI'; $qTb.FontSize = $qSz; $qTb.Foreground = Brush $qFg; $qTb.TextWrapping = 'Wrap'; return $qTb }
    $peWin = New-Object Windows.Window; $peWin.Title = 'Edit punches'; $peWin.Width = 410; $peWin.Height = 680; $peWin.WindowStartupLocation = 'CenterScreen'; $peWin.Background = Brush '#FF0E0E0E'; $peWin.Topmost = $true; $peWin.ResizeMode = 'NoResize'
    try { $peWin.Owner = $window } catch {}
    $peDock = New-Object Windows.Controls.DockPanel; $peDock.LastChildFill = $true; $peWin.Content = $peDock
    # sticky footer: CANCEL + big green SAVE (only while a line is open)
    $peFoot = New-Object Windows.Controls.Border; $peFoot.Background = Brush '#FF141414'; $peFoot.BorderBrush = Brush '#FF2A2A2A'; $peFoot.BorderThickness = '0,1,0,0'; $peFoot.Padding = '10,8,10,10'; $peFoot.Visibility = 'Collapsed'
    [Windows.Controls.DockPanel]::SetDock($peFoot, 'Bottom')
    $peFootG = New-Object Windows.Controls.Grid
    $peC1 = New-Object Windows.Controls.ColumnDefinition; $peC1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $peC2 = New-Object Windows.Controls.ColumnDefinition; $peC2.Width = New-Object System.Windows.GridLength(2, [System.Windows.GridUnitType]::Star)
    [void]$peFootG.ColumnDefinitions.Add($peC1); [void]$peFootG.ColumnDefinitions.Add($peC2); $peFoot.Child = $peFootG
    $peBtnCancel = & $peMkBtn 'CANCEL' '#FF222222' '#FFDDDDDD' $null; $peBtnCancel.Height = 54; $peBtnCancel.FontSize = 15
    $peBtnSave = & $peMkBtn ([string][char]0x2713 + ' SAVE') '#FF1FA34A' '#FFFFFFFF' $null; $peBtnSave.Height = 54; $peBtnSave.FontSize = 20; $peBtnSave.BorderBrush = Brush '#FF34C85E'; $peBtnSave.IsDefault = $false
    $peBtnSave.ToolTip = 'Save this change (Enter)'; $peBtnCancel.ToolTip = 'Undo unsaved changes (Esc)'
    [Windows.Controls.Grid]::SetColumn($peBtnCancel, 0); [Windows.Controls.Grid]::SetColumn($peBtnSave, 1); [void]$peFootG.Children.Add($peBtnCancel); [void]$peFootG.Children.Add($peBtnSave)
    [void]$peDock.Children.Add($peFoot)
    # 'Saved' flash (sits just above the footer / at the bottom)
    $peToast = New-Object Windows.Controls.Border; $peToast.Background = Brush '#FF1FA34A'; $peToast.CornerRadius = '14'; $peToast.Padding = '14,5'; $peToast.Margin = '0,4,0,6'; $peToast.HorizontalAlignment = 'Center'; $peToast.Visibility = 'Collapsed'
    $peToastT = & $peMkLbl ([string][char]0x2713 + ' Saved') 14 '#FFFFFFFF'; $peToastT.FontWeight = [System.Windows.FontWeights]::Bold; $peToast.Child = $peToastT
    [Windows.Controls.DockPanel]::SetDock($peToast, 'Bottom'); [void]$peDock.Children.Add($peToast)
    $peTimer = New-Object System.Windows.Threading.DispatcherTimer; $peTimer.Interval = [TimeSpan]::FromMilliseconds(1600)
    $peTimer.Add_Tick({ param($zSnd, $zArg) $zSnd.Stop(); $peToast.Visibility = 'Collapsed' })
    $peFlash = { param($qMsg) $peToastT.Text = $qMsg + ' ' + [string][char]0x2713; $peToast.Visibility = 'Visible'; $peTimer.Stop(); $peTimer.Start() }
    $peSv = New-Object Windows.Controls.ScrollViewer; $peSv.VerticalScrollBarVisibility = 'Auto'; $peRoot = New-Object Windows.Controls.StackPanel; $peRoot.Margin = '12'; $peSv.Content = $peRoot; [void]$peDock.Children.Add($peSv)
    $peNav = New-Object Windows.Controls.DockPanel; $peBPrev = & $peMkBtn ([string][char]0x2039) '#FF1A1A1A' '#FFFFFFFF' 46; $peBNext = & $peMkBtn ([string][char]0x203A) '#FF1A1A1A' '#FFFFFFFF' 46
    [Windows.Controls.DockPanel]::SetDock($peBPrev, 'Left'); [Windows.Controls.DockPanel]::SetDock($peBNext, 'Right'); $peDayT = & $peMkLbl '' 15 '#FFFFFFFF'; $peDayT.FontWeight = [System.Windows.FontWeights]::Bold; $peDayT.TextAlignment = 'Center'; $peDayT.VerticalAlignment = 'Center'
    [void]$peNav.Children.Add($peBPrev); [void]$peNav.Children.Add($peBNext); [void]$peNav.Children.Add($peDayT); [void]$peRoot.Children.Add($peNav)
    $peHint = & $peMkLbl 'Click a line to change it. Type a time (4, 4pm, 4:00 PM or 1600) or use -15 / -5 / -1 / +1 / +5 / +15, then press the green SAVE (or Enter).' 11 '#FF888888'; $peHint.Margin = '3,4,3,6'; [void]$peRoot.Children.Add($peHint)
    $peList = New-Object Windows.Controls.StackPanel; [void]$peRoot.Children.Add($peList)
    $peForm = New-Object Windows.Controls.Border; $peForm.Background = Brush '#FF181818'; $peForm.BorderBrush = Brush '#FFFFB020'; $peForm.BorderThickness = '1'; $peForm.CornerRadius = '6'; $peForm.Padding = '8'; $peForm.Margin = '0,6,0,6'; $peForm.Visibility = 'Collapsed'
    $peFp = New-Object Windows.Controls.StackPanel; $peForm.Child = $peFp; [void]$peRoot.Children.Add($peForm)
    $peFt = & $peMkLbl '' 13 '#FFFFB020'; $peFt.FontWeight = [System.Windows.FontWeights]::Bold; [void]$peFp.Children.Add($peFt)
    $peMkRow = { param($qLab) $qOut = New-Object Windows.Controls.StackPanel; $qOut.Margin = '0,4,0,0'
               $qG = New-Object Windows.Controls.DockPanel; $qL = & $peMkLbl $qLab 13 '#FFCCCCCC'; $qL.Width = 60; $qL.VerticalAlignment = 'Center'; [Windows.Controls.DockPanel]::SetDock($qL, 'Left')
               $qTx = New-Object Windows.Controls.TextBox; $qTx.FontSize = 17; $qTx.Height = 38; $qTx.Background = Brush '#FF0E0E0E'; $qTx.Foreground = Brush '#FFFFFFFF'; $qTx.BorderBrush = Brush '#FF555555'; $qTx.VerticalContentAlignment = 'Center'; $qTx.Padding = '6,0'; $qTx.CaretBrush = Brush '#FFFFFFFF'
               [void]$qG.Children.Add($qL); [void]$qG.Children.Add($qTx); [void]$qOut.Children.Add($qG)
               # v2.0.8: nudge buttons on their own line under the time box: -15 -5 -1 +1 +5 +15 (each saves right away)
               $qU = New-Object Windows.Controls.Primitives.UniformGrid; $qU.Columns = 6; $qU.Margin = '57,2,-3,0'; $qR = @{ Row = $qOut; Tb = $qTx; Lab = $qL }
               foreach ($qD in @(-15, -5, -1, 1, 5, 15)) { $qTxt = $(if ($qD -lt 0) { [string][char]0x2212 + [string](-$qD) } else { '+' + $qD }); $qB = & $peMkBtn $qTxt '#FF1A1A1A' '#FFFFFFFF' $null; $qB.Height = 34
                 $qB.ToolTip = ([string][math]::Abs($qD)) + $(if ([math]::Abs($qD) -eq 1) { ' minute ' } else { ' minutes ' }) + $(if ($qD -lt 0) { 'earlier' } else { 'later' }) + ' (saves right away)'; $qB.Tag = $qD; [void]$qU.Children.Add($qB); $qR['N' + $(if ($qD -lt 0) { 'm' + (-$qD) } else { 'p' + $qD })] = $qB }
               [void]$qOut.Children.Add($qU); [void]$peFp.Children.Add($qOut); return $qR }
    $peRS = & $peMkRow 'START'; $peRE = & $peMkRow 'END'
    $peFq = New-Object Windows.Controls.WrapPanel; $peFq.Margin = '0,6,0,0'; [void]$peFp.Children.Add($peFq)
    $peBQuick = & $peMkBtn '15 MIN' '#FFFFB020' '#FF111111' 150; $peBQuick.FontSize = 16; $peBQuick.Height = 46; $peBNow = & $peMkBtn 'END = NOW' '#FF1A1A1A' '#FFFFFFFF' 110; $peBSched = & $peMkBtn 'USE SCHEDULE' '#FF1A1A1A' '#FFFFFFFF' 130
    $peBDel = & $peMkBtn 'DELETE' '#FF2A0E0E' '#FFFF6B6B' 100
    foreach ($peFqBtn in @($peBQuick, $peBNow, $peBSched, $peBDel)) { [void]$peFq.Children.Add($peFqBtn) }
    $peErr = & $peMkLbl '' 12 '#FFFF6B6B'; $peErr.Margin = '0,4,0,0'; [void]$peFp.Children.Add($peErr)
    $peAdds = New-Object Windows.Controls.WrapPanel; $peBAddB = & $peMkBtn '+ ADD BREAK' '#FF1A1A1A' '#FFFFFFFF' 170; $peBAddL = & $peMkBtn '+ ADD LUNCH' '#FF1A1A1A' '#FFFFFFFF' 170; [void]$peAdds.Children.Add($peBAddB); [void]$peAdds.Children.Add($peBAddL); [void]$peRoot.Children.Add($peAdds)
    $peSum = & $peMkLbl '' 12 '#FFAAAAAA'; $peSum.Margin = '3,8,3,8'; [void]$peRoot.Children.Add($peSum)
    $peBDone = & $peMkBtn 'DONE' '#FFE82127' '#FFFFFFFF' $null; $peBDone.Height = 44; [void]$peRoot.Children.Add($peBDone)
    $peParse = { param($qTxt, $qOld) $qRef = $(if ($null -ne $qOld) { [int][math]::Floor($qOld / 60) } elseif ($PEST.M) { [int][math]::Floor($PEST.M.In.T / 60) } else { $null }); $qMn = ConvertFrom-TypedTime $qTxt $qRef; if ($null -eq $qMn) { return $null }; if ($null -ne $qOld -and [math]::Floor($qOld / 60) -eq $qMn) { return [int]$qOld }; return [int]($qMn * 60) }
    $peLenOf = { param($qK) if ($qK -eq 'lunch') { $qLl = $(if ($script:LunchBreak) { [int]($script:LunchBreak.E - $script:LunchBreak.S) } else { 60 }); if ($qLl -le 0) { 60 } else { $qLl } } else { [int]$script:BreakLen } }
    $pePaint = $null; $peOpen = $null
    # write the model; on success flash 'Saved', recalc the widget, repaint (and reopen the same line if asked)
    $peSave = { param($qM, $qKeep) $qMsg = Save-DayModel $PEST.Iso $qM ($PEST.Iso -eq $peToday.ToString('yyyy-MM-dd'))
              if ($qMsg) { $peErr.Text = $qMsg; return $false }
              $qSel = $PEST.Sel; $PEST.Sel = $null; try { Update-Ui } catch {}; & $pePaint; & $peFlash 'SAVED'
              if ($qKeep -and $null -ne $qSel) { $qOk = $true; if ($qSel -isnot [string]) { $qOk = ([int]$qSel -lt $PEST.M.Segs.Count) }; if ($qOk) { & $peOpen $qSel } }
              return $true }
    # commit what is typed in the open line (SAVE button / Enter / one-click buttons)
    $peCommit = { param($qKeep) $qM = $PEST.M; $qSel = $PEST.Sel; $qNote = ''; if ($null -eq $qSel) { return $false }
      if ($qSel -is [string]) { $qKey = $(if ($qSel -eq 'in') { 'In' } else { 'Out' }); $qT = & $peParse $peRS.Tb.Text $qM[$qKey].T; if ($null -eq $qT) { $peErr.Text = 'Type a time like 1:03 PM.'; $peRS.Tb.Focus() | Out-Null; return $false }; $qM[$qKey] = @{ T = $qT; Auto = $false }
        # v2.0.7: a late clock in / early clock out drops schedule-only lunch/breaks outside the shift instead of blocking the save (late start = no lunch)
        $qLost = @($qM.Segs | Where-Object { $_.Auto -and ($_.S -lt $qM.In.T -or ($null -ne $_.E -and $_.E -gt $qM.Out.T)) })
        if ($qLost.Count) { $qLeft = @($qM.Segs | Where-Object { $qLost -notcontains $_ }); $qM.Segs = New-Object System.Collections.ArrayList; foreach ($qY in $qLeft) { [void]$qM.Segs.Add($qY) }
          $qNote = $(if (@($qLost | Where-Object { $_.Kind -eq 'lunch' }).Count) { 'No lunch today (the schedule lunch was outside the shift).' } else { 'Schedule break outside the shift skipped.' }) } }
      else { $qX = $qM.Segs[[int]$qSel]; $qS = & $peParse $peRS.Tb.Text $qX.S; if ($null -eq $qS) { $peErr.Text = 'Type a start time like 1:03 PM.'; $peRS.Tb.Focus() | Out-Null; return $false }
             if ($peRE.Tb.Text.Trim() -eq '') { $qEnd = $null } else { $qEnd = & $peParse $peRE.Tb.Text $(if ($qX.AutoClosed) { $null } else { $qX.E }); if ($null -eq $qEnd) { $peErr.Text = 'Type an end time like 1:18 PM.'; $peRE.Tb.Focus() | Out-Null; return $false } }
             $qX.S = $qS; $qX.E = $qEnd; $qX.Auto = $false; $qX.AutoClosed = $false }
      $qR = & $peSave $qM $qKeep; if ($qR -and $qNote) { $peErr.Foreground = Brush '#FF34C759'; $peErr.Text = $qNote }; return $qR }
    $peOpen = { param($qSel) $PEST.Sel = $qSel; $peErr.Text = ''; $peErr.Foreground = Brush '#FFFF6B6B'; $qM = $PEST.M; $qIsT = ($PEST.Iso -eq $peToday.ToString('yyyy-MM-dd'))
      if ($qSel -is [string]) { $qX = $qM[$(if ($qSel -eq 'in') { 'In' } else { 'Out' })]; $peFt.Text = $(if ($qSel -eq 'in') { 'CLOCK IN' } else { 'CLOCK OUT' })
          $peRS.Lab.Text = 'TIME'; $peRS.Tb.Text = (Format-ClockS $qX.T); $peRE.Row.Visibility = 'Collapsed'; $peBQuick.Visibility = 'Collapsed'; $peBNow.Visibility = 'Collapsed'; $peBDel.Visibility = 'Collapsed'; $peBSched.Visibility = 'Visible' }
      else { $qX = $qM.Segs[[int]$qSel]; $qLn = & $peLenOf $qX.Kind; $peFt.Text = $(switch ($qX.Kind) { 'lunch' { 'LUNCH' } 'off' { 'OFF THE CLOCK' } default { 'BREAK ' + (@($qM.Segs | Select-Object -First ([int]$qSel + 1) | Where-Object { $_.Kind -eq 'break' })).Count } })
          $peRS.Lab.Text = 'START'; $peRS.Tb.Text = (Format-ClockS $qX.S); $peRE.Row.Visibility = 'Visible'; $peRE.Tb.Text = $(if ($null -ne $qX.E -and -not $qX.AutoClosed) { Format-ClockS $qX.E } else { '' })
          $peBQuick.Content = $(if ($qX.Kind -eq 'lunch' -and $qLn -eq 60) { '1 HOUR' } else { "$qLn MIN" }); $peBQuick.Visibility = $(if ($qX.Kind -eq 'off') { 'Collapsed' } else { 'Visible' })
          $peBNow.Visibility = $(if ($qIsT) { 'Visible' } else { 'Collapsed' }); $peBDel.Visibility = 'Visible'; $peBDel.Content = $(if ($qX.Kind -eq 'lunch') { 'NO LUNCH' } else { 'DELETE' }); $peBDel.Width = $(if ($qX.Kind -eq 'lunch') { 120 } else { 100 }); $peBSched.Visibility = 'Collapsed' }
      $peForm.Visibility = 'Visible'; $peFoot.Visibility = 'Visible'; $peBDone.Visibility = 'Collapsed'
      try { $peForm.BringIntoView() } catch {}; $peRS.Tb.Focus() | Out-Null; $peRS.Tb.SelectAll() }
    $pePaint = {
      $qDay = [datetime]::ParseExact($PEST.Iso, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture); $PEST.M = Get-DayModel $PEST.Iso; $qM = $PEST.M
      $peDayT.Text = $qDay.ToString('dddd M/d', [Globalization.CultureInfo]::InvariantCulture) + $(if ($qDay -eq $peToday) { ' (today)' } else { '' })
      $peBPrev.IsEnabled = ($qDay -gt $peMinD); $peBNext.IsEnabled = ($qDay -lt $peToday); $peList.Children.Clear(); $peForm.Visibility = 'Collapsed'; $peFoot.Visibility = 'Collapsed'; $peBDone.Visibility = 'Visible'; $peErr.Text = ''
      $qRow = { param($rLab, $rTxt, $rSub, $rWarn, $rSel) $rB = New-Object Windows.Controls.Button; $rB.HorizontalContentAlignment = 'Stretch'; $rB.Margin = '0,2'; $rB.Padding = '8,6'; $rB.Cursor = 'Hand'
               $rB.Background = Brush $(if ($rWarn) { '#FF3A2A08' } else { '#FF161616' }); $rB.BorderBrush = Brush $(if ($rWarn) { '#FFFFB020' } else { '#FF2A2A2A' })
               $rSp = New-Object Windows.Controls.StackPanel; $rDp = New-Object Windows.Controls.DockPanel; $rA = & $peMkLbl $rLab 13 $(if ($rWarn) { '#FFFFB020' } else { '#FFCCCCCC' }); $rA.FontWeight = [System.Windows.FontWeights]::Bold; [Windows.Controls.DockPanel]::SetDock($rA, 'Left')
               $rT = & $peMkLbl $rTxt 14 '#FFFFFFFF'; $rT.TextAlignment = 'Right'; [void]$rDp.Children.Add($rA); [void]$rDp.Children.Add($rT); [void]$rSp.Children.Add($rDp)
               if ($rSub) { [void]$rSp.Children.Add((& $peMkLbl $rSub 11 $(if ($rWarn) { '#FFFFB020' } else { '#FF888888' }))) }
               $rB.Content = $rSp; $rB.Tag = $rSel; $rB.Add_Click({ param($zSnd, $zArg) & $peOpen $zSnd.Tag }); [void]$peList.Children.Add($rB) }
      & $qRow 'CLOCK IN' (Format-ClockS $qM.In.T) $(if ($qM.In.Auto) { 'from schedule' } else { $null }) $false 'in'
      $qNb = 0
      for ($qI = 0; $qI -lt $qM.Segs.Count; $qI++) { $qX = $qM.Segs[$qI]; $qLn = & $peLenOf $qX.Kind; if ($qX.Kind -eq 'break') { $qNb++ }; $qNm = $(switch ($qX.Kind) { 'lunch' { 'LUNCH' } 'off' { 'OFF THE CLOCK' } default { 'BREAK ' + $qNb } })
        $qTx = (Format-ClockS $qX.S) + ' ' + [char]0x2013 + ' ' + $(if ($null -ne $qX.E) { Format-ClockS $qX.E } else { '...' })
        if ($qX.AutoClosed) { $qSub = [string][char]0x26A0 + ' END ' + $qNm + ' was not pressed (closed at ' + $(if ($null -ne $qX.E) { Format-ClockS $qX.E } else { '?' }) + '). Click to fix.' ; $qWr = $true }
        elseif ($null -eq $qX.E) { $qSub = 'still open'; $qWr = $false }
        else { $qDu = $qX.E - $qX.S; $qLate = $qDu - $qLn * 60; $qWr = $false
               $qSub = (Format-Late $qDu) + $(if ($qX.Auto) { ' ' + [char]0x00B7 + ' from schedule' } elseif ($qX.Kind -ne 'off') { ' ' + [char]0x00B7 + ' ' + $(if ($qLate -gt 59) { 'late +' + (Format-Late $qLate) } else { 'on time' }) } else { '' }) }
        & $qRow $qNm $qTx $qSub $qWr $qI }
      & $qRow 'CLOCK OUT' (Format-ClockS $qM.Out.T) $(if ($qM.Out.Auto) { 'from schedule' } else { $null }) $false 'out'
      try { $qFs = Get-FullShift $qDay; $peSum.Text = 'Paid ' + [math]::Floor($qFs.PaidMin / 60) + 'h ' + ($qFs.PaidMin % 60) + 'm ' + [char]0x00B7 + ' ' + (Format-Money $qFs.Total) + ' gross this day' } catch { $peSum.Text = '' }
    }
    # -5 / +5: change the time and save right away (line stays open)
    $peNudge = { param($qTb, $qDm) $qMn = ConvertFrom-TypedTime $qTb.Text $(if ($PEST.M) { [int][math]::Floor($PEST.M.In.T / 60) } else { $null }); if ($null -eq $qMn) { $peErr.Text = 'Type a time first, like 1:03 PM.'; return }; $qMn = ($qMn + $qDm + 1440) % 1440; $qTb.Text = Format-Clock $qMn; [void](& $peCommit $true) }
    foreach ($qK in 'Nm15','Nm5','Nm1','Np1','Np5','Np15') { $peRS[$qK].Add_Click({ param($zSnd, $zArg) & $peNudge $peRS.Tb ([int]$zSnd.Tag) }); $peRE[$qK].Add_Click({ param($zSnd, $zArg) & $peNudge $peRE.Tb ([int]$zSnd.Tag) }) }
    $peKeys = { param($zSnd, $zArg) if ($zArg.Key -eq 'Return' -or $zArg.Key -eq 'Enter') { $zArg.Handled = $true; [void](& $peCommit $false) } elseif ($zArg.Key -eq 'Escape') { $zArg.Handled = $true; $PEST.Sel = $null; & $pePaint } }
    $peRS.Tb.Add_KeyDown($peKeys); $peRE.Tb.Add_KeyDown($peKeys)
    $peBtnSave.Add_Click({ [void](& $peCommit $false) })
    $peBtnCancel.Add_Click({ $PEST.Sel = $null; & $pePaint })   # repaint reloads the saved day = unsaved edits are dropped
    $peBQuick.Add_Click({ $qM = $PEST.M; $qX = $qM.Segs[[int]$PEST.Sel]; $qS = & $peParse $peRS.Tb.Text $qX.S; if ($null -eq $qS) { $peErr.Text = 'Type a start time like 1:03 PM.'; return }
      $qX.S = $qS; $qX.E = $qS + (& $peLenOf $qX.Kind) * 60; $qX.Auto = $false; $qX.AutoClosed = $false; [void](& $peSave $qM $false) })
    $peBNow.Add_Click({ $qN = Get-PunchNow; $peRE.Tb.Text = Format-Clock ($qN.Hour * 60 + $qN.Minute); [void](& $peCommit $true) })
    $peBSched.Add_Click({ $qM = $PEST.M; $qDay = [datetime]::ParseExact($PEST.Iso, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture); $qSp = Get-DaySpec $qDay $false
      if ($PEST.Sel -eq 'in') { $qM.In = @{ T = $qSp.S0 * 60; Auto = $true } } else { $qM.Out = @{ T = $qSp.E0 * 60; Auto = $true } }; [void](& $peSave $qM $false) })
    $peBDel.Add_Click({ $qM = $PEST.M; $qX = $qM.Segs[[int]$PEST.Sel]
      $qAsk = $(if ($qX.Kind -eq 'lunch') { 'No lunch on this day? (removes the lunch ' + (Format-ClockS $qX.S) + ')' } else { 'Delete this ' + $(if ($qX.Kind -eq 'off') { 'off-the-clock time' } else { $qX.Kind }) + ' (' + (Format-ClockS $qX.S) + ')?' })
      if ([Windows.MessageBox]::Show($qAsk, 'Edit punches', 'YesNo', 'Question') -ne 'Yes') { return }
      $qM.Segs.RemoveAt([int]$PEST.Sel)
      if ($qX.Kind -eq 'lunch' -and @($qM.Segs | Where-Object { $_.Kind -eq 'lunch' }).Count -eq 0) { $qM.NoLunch = $true }
      if ($qX.Kind -eq 'break' -and @($qM.Segs | Where-Object { $_.Kind -eq 'break' }).Count -eq 0) { $qM.NoBreaks = $true }
      [void](& $peSave $qM $false) })
    $peAdd = { param($qK) $qM = $PEST.M; $qLn = & $peLenOf $qK; $qIsT = ($PEST.Iso -eq $peToday.ToString('yyyy-MM-dd')); $qN = Get-PunchNow
      $qS = $(if ($qIsT) { [math]::Max($qM.In.T, ($qN.Hour * 60 + $qN.Minute) * 60 - $qLn * 60) } else { $qM.In.T + 120 * 60 }); $qS = [int]([math]::Floor($qS / 300) * 300)
      $qI = $qM.Segs.Add(@{ Kind = $qK; S = $qS; E = $qS + $qLn * 60; Auto = $false; AutoClosed = $false; Open = $false })
      if ($qK -eq 'lunch') { $qM.NoLunch = $false } else { $qM.NoBreaks = $false }
      & $peOpen $qI; $peErr.Foreground = Brush '#FFFFB020'; $peErr.Text = 'Set the times, then press the green SAVE (or ' + $peBQuick.Content + ').' }
    $peBAddB.Add_Click({ & $peAdd 'break' }); $peBAddL.Add_Click({ & $peAdd 'lunch' })
    $peBPrev.Add_Click({ $PEST.Iso = ([datetime]::ParseExact($PEST.Iso, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)).AddDays(-1).ToString('yyyy-MM-dd'); $PEST.Sel = $null; & $pePaint })
    $peBNext.Add_Click({ $PEST.Iso = ([datetime]::ParseExact($PEST.Iso, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)).AddDays(1).ToString('yyyy-MM-dd'); $PEST.Sel = $null; & $pePaint })
    $peBDone.Add_Click({ param($zSnd, $zArg) [System.Windows.Window]::GetWindow($zSnd).Close() })
    $peWin.Add_Closed({ try { $peTimer.Stop() } catch {} })
    & $pePaint
    $peFb = @($PEST.M.Segs) | Where-Object { $_.AutoClosed } | Select-Object -First 1; if ($peFb) { & $peOpen ([int]$PEST.M.Segs.IndexOf($peFb)) }
    if ($script:PeAutoTest) { & $script:PeAutoTest $peWin }   # self-test hook (unset in normal use)
    [void]$peWin.ShowDialog()
  } catch { try { [Windows.MessageBox]::Show('Edit punches hit a problem: ' + $_.Exception.Message, 'Paycheck Widget') | Out-Null } catch {} }
  try { Update-Ui } catch {}
}
$ui.PEdit.Add_Click({ Show-PunchEditor })
# v2.0.11 PTO window: pick a day, enter the hours missed (from / to), paid at base rate with no differentials
function Show-PtoWindow {
  try {
    $vNow = (Get-PunchNow).Date; $vW = New-Object Windows.Window; $vW.Title = 'PTO'; $vW.Width = 400; $vW.Height = 560; $vW.WindowStartupLocation = 'CenterScreen'; $vW.Background = Brush '#FF0E0E0E'; $vW.Topmost = $true; $vW.ResizeMode = 'NoResize'
    $vSp = New-Object Windows.Controls.StackPanel; $vSp.Margin = '16'; $vW.Content = $vSp
    $vLbl = { param($vT, $vSz, $vC) $vX = New-Object Windows.Controls.TextBlock; $vX.Text = $vT; $vX.FontSize = $vSz; $vX.Foreground = Brush $vC; $vX.FontFamily = 'Segoe UI'; $vX.TextWrapping = 'Wrap'; $vX.Margin = '0,4,0,0'; return $vX }
    $vH = & $vLbl 'PTO (PAID TIME OFF)' 17 '#FF5AC8FA'; $vH.FontWeight = 'Black'; [void]$vSp.Children.Add($vH)
    [void]$vSp.Children.Add((& $vLbl ('Pick the day and the hours you missed. Paid at base rate $' + $Rules.BaseRate.ToString('0.00', $inv) + '/hr, no differentials. Added to that day and the pay period.') 11 '#FF999999'))
    $vDp = New-Object Windows.Controls.DatePicker; $vDp.SelectedDate = $vNow; $vDp.FontSize = 15; $vDp.Margin = '0,10,0,0'; [void]$vSp.Children.Add($vDp)
    $vRow = New-Object Windows.Controls.Grid; $vRow.Margin = '0,8,0,0'; foreach ($vI in 0..3) { $vCd = New-Object Windows.Controls.ColumnDefinition; $vCd.Width = $(if ($vI % 2) { '*' } else { 'Auto' }); [void]$vRow.ColumnDefinitions.Add($vCd) }
    $vMkTb = { param($vT) $vX = New-Object Windows.Controls.TextBox; $vX.Text = $vT; $vX.FontSize = 16; $vX.Height = 36; $vX.Margin = '6,0,8,0'; $vX.VerticalContentAlignment = 'Center'; $vX.Background = Brush '#FF161616'; $vX.Foreground = Brush '#FFFFFFFF'; $vX.CaretBrush = Brush '#FFFFFFFF'; $vX.BorderBrush = Brush '#FF555555'; return $vX }
    $vL1 = & $vLbl 'FROM' 12 '#FFCCCCCC'; $vL1.VerticalAlignment = 'Center'; $vT1 = & $vMkTb '11:30 AM'; $vL2 = & $vLbl 'TO' 12 '#FFCCCCCC'; $vL2.VerticalAlignment = 'Center'; $vT2 = & $vMkTb '4:00 PM'
    [Windows.Controls.Grid]::SetColumn($vT1, 1); [Windows.Controls.Grid]::SetColumn($vL2, 2); [Windows.Controls.Grid]::SetColumn($vT2, 3); foreach ($vX in $vL1, $vT1, $vL2, $vT2) { [void]$vRow.Children.Add($vX) }; [void]$vSp.Children.Add($vRow)
    $vAdd = New-Object Windows.Controls.Button; $vAdd.Content = '+ ADD PTO'; $vAdd.Height = 44; $vAdd.Margin = '0,10,0,0'; $vAdd.FontSize = 16; $vAdd.FontWeight = 'Bold'; $vAdd.Background = Brush '#FF0A5A8A'; $vAdd.Foreground = Brush '#FFFFFFFF'; $vAdd.BorderBrush = Brush '#FF5AC8FA'; $vAdd.Cursor = 'Hand'; [void]$vSp.Children.Add($vAdd)
    $vMsg = & $vLbl '' 12 '#FF34C759'; [void]$vSp.Children.Add($vMsg)
    $vSum = & $vLbl '' 12 '#FFDDDDDD'; $vSum.FontWeight = 'SemiBold'; $vSum.Margin = '0,10,0,2'; [void]$vSp.Children.Add($vSum)
    $vSv = New-Object Windows.Controls.ScrollViewer; $vSv.Height = 190; $vSv.VerticalScrollBarVisibility = 'Auto'; $vList = New-Object Windows.Controls.StackPanel; $vSv.Content = $vList; [void]$vSp.Children.Add($vSv)
    $vDone = New-Object Windows.Controls.Button; $vDone.Content = 'DONE'; $vDone.Height = 40; $vDone.Margin = '0,8,0,0'; $vDone.FontSize = 14; $vDone.FontWeight = 'Bold'; $vDone.Background = Brush '#FF222222'; $vDone.Foreground = Brush '#FFFFFFFF'; [void]$vSp.Children.Add($vDone)
    $vPaint = {
      $vList.Children.Clear(); $vPs = Get-PayPeriodStart $vNow; $vPm = 0
      for ($vI = 0; $vI -lt $PeriodDays; $vI++) { $vPm += Get-PtoMin ($vPs.AddDays($vI).ToString('yyyy-MM-dd')) }
      $vSum.Text = 'This pay period (' + $vPs.ToString('M/d', $inv) + ' - ' + $vPs.AddDays($PeriodDays - 1).ToString('M/d', $inv) + '): PTO ' + (Format-H $vPm) + ' h = ' + (Format-Money (Round2 ($Rules.BaseRate * $vPm / 60))) + ' | period gross ' + (Format-Money (Get-EffPeriodGross $vPs $null))
      foreach ($vK in @($script:Pto.Keys | Sort-Object -Descending)) { $vD = [datetime]::ParseExact($vK, 'yyyy-MM-dd', $inv)
        for ($vJ = 0; $vJ -lt $script:Pto[$vK].Count; $vJ++) { $vX = $script:Pto[$vK][$vJ]; $vM = [int]$vX[1] - [int]$vX[0]
          $vG = New-Object Windows.Controls.DockPanel; $vG.Margin = '0,3,0,0'
          $vRm = New-Object Windows.Controls.Button; $vRm.Content = 'REMOVE'; $vRm.Width = 74; $vRm.Height = 28; $vRm.Background = Brush '#FF2A1012'; $vRm.Foreground = Brush '#FFFF6B6B'; $vRm.Tag = @($vK, $vJ); $vRm.Cursor = 'Hand'; [Windows.Controls.DockPanel]::SetDock($vRm, 'Right')
          $vRm.Add_Click({ param($vSnd, $vArg) $vTg = $vSnd.Tag; $vLst = $script:Pto[[string]$vTg[0]]; $vLst.RemoveAt([int]$vTg[1]); if ($vLst.Count -eq 0) { $script:Pto.Remove([string]$vTg[0]) }; Save-Pto; try { Update-Ui } catch {}; $vMsg.Foreground = Brush '#FFFFB020'; $vMsg.Text = 'PTO removed.'; & $vPaint })
          $vTx = & $vLbl ($vD.ToString('ddd M/d/yyyy', $inv) + '   ' + (Format-Clock ([int]$vX[0])) + ' - ' + (Format-Clock ([int]$vX[1])) + '   ' + (Format-H $vM) + ' h  ' + (Format-Money (Round2 ($Rules.BaseRate * $vM / 60)))) 12 '#FF5AC8FA'; $vTx.VerticalAlignment = 'Center'; $vTx.Margin = '0'
          [void]$vG.Children.Add($vRm); [void]$vG.Children.Add($vTx); [void]$vList.Children.Add($vG) } }
      if ($vList.Children.Count -eq 0) { [void]$vList.Children.Add((& $vLbl 'No PTO yet.' 12 '#FF777777')) } }
    $vDoAdd = {
      $vMsg.Foreground = Brush '#FFFF6B6B'; if (-not $vDp.SelectedDate) { $vMsg.Text = 'Pick a day.'; return }
      $vA = ConvertFrom-TypedTime $vT1.Text 690; $vB = ConvertFrom-TypedTime $vT2.Text $(if ($null -ne $vA) { $vA + 240 } else { 960 })
      if ($null -eq $vA -or $null -eq $vB) { $vMsg.Text = 'Type times like 11:30 AM and 4:00 PM.'; return }
      if ($vB -le $vA) { $vMsg.Text = 'TO must be after FROM.'; return }
      $vK = ([datetime]$vDp.SelectedDate).ToString('yyyy-MM-dd'); if (-not $script:Pto.ContainsKey($vK)) { $script:Pto[$vK] = New-Object System.Collections.ArrayList }
      foreach ($vX in $script:Pto[$vK]) { if ($vA -lt [int]$vX[1] -and $vB -gt [int]$vX[0]) { $vMsg.Text = 'Overlaps PTO already on that day.'; return } }
      [void]$script:Pto[$vK].Add(@([int]$vA, [int]$vB)); Save-Pto; try { Update-Ui } catch {}
      $vMsg.Foreground = Brush '#FF34C759'; $vMsg.Text = 'SAVED ' + [string][char]0x2713 + '  PTO ' + ([datetime]$vDp.SelectedDate).ToString('ddd M/d', $inv) + ' ' + (Format-Clock $vA) + ' - ' + (Format-Clock $vB) + ' (' + (Format-H ($vB - $vA)) + ' h = ' + (Format-Money (Round2 ($Rules.BaseRate * ($vB - $vA) / 60))) + ')'; & $vPaint }
    $vAdd.Add_Click({ & $vDoAdd }); $vT2.Add_KeyDown({ param($vSnd, $vArg) if ($vArg.Key -eq 'Return') { $vArg.Handled = $true; & $vDoAdd } }); $vT1.Add_KeyDown({ param($vSnd, $vArg) if ($vArg.Key -eq 'Return') { $vArg.Handled = $true; & $vDoAdd } })
    $vDone.Add_Click({ param($vSnd, $vArg) [System.Windows.Window]::GetWindow($vSnd).Close() }); $vW.Add_KeyDown({ param($vSnd, $vArg) if ($vArg.Key -eq 'Escape') { $vSnd.Close() } })
    & $vPaint
    if ($script:PtoAutoTest) { & $script:PtoAutoTest $vW }
    [void]$vW.ShowDialog()
  } catch { try { [Windows.MessageBox]::Show('PTO hit a problem: ' + $_.Exception.Message, 'Paycheck Live') | Out-Null } catch {} }
  try { Update-Ui } catch {}
}
$ui.PPto.Add_Click({ Show-PtoWindow })
$ui.PunchNote.Add_MouseLeftButtonUp({ if ($script:PunchWarn) { Show-PunchEditor } })
$ui.TipVenmo.Add_Click({ Open-Url $DonateVenmo })
$ui.TipPaypal.Add_Click({ Open-Url $DonatePaypal })
if ($TestMode) {
    $ui.StartBtn.Add_Click({ Invoke-TestStart; Update-Ui })
    $ui.StopBtn.Add_Click({ Invoke-TestStop; Update-Ui })
    $ui.FfwdBtn.Add_Click({ Invoke-TestFfwd 5; Update-Ui })
    # v1.14.0 right-click for bigger jumps (e.g. +1 day x4 to Saturday, then a late CLOCK OUT pushes the week past 40 hrs -> overtime)
    $ffm = New-Object System.Windows.Controls.ContextMenu
    foreach ($j in @(@('+15 minutes', 15), @('+1 hour', 60), @('+1 day (same time)', 1440))) {
        $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = $j[0]; $mi.Tag = [int]$j[1]
        $mi.Add_Click({ param($sender, $e) Invoke-TestFfwd ([int]$sender.Tag); Update-Ui }); [void]$ffm.Items.Add($mi) }
    $ui.FfwdBtn.ContextMenu = $ffm
}


# ---------------------------------------------------------------- v1.10.0 UPDATE channel + install registration
# API (same contract for the Apps Script web app and the box test server):
#   GET  <api>?api=version            -> {"version","date","changelog":[...]}
#   GET  <api>?file=<name>.ps1        -> raw script text of the published build
#   POST <api>  {"action":"log",...}  -> registers/updates this install in Van's Users sheet
$updateCfgPath   = Join-Path $cfgDir 'update-config.json'
$updateStatePath = Join-Path $dataDir $(if ($TestMode) { 'install-state-test.json' } else { 'install-state.json' })
$UpdateApi = $UpdateApiDefault
$ReleaseRole = 'client'   # v2.0.0: 'master' = Van's desktop (the dev / release copy everyone else updates from)
try { if (Test-Path -LiteralPath $updateCfgPath) { $uc = Get-Content -LiteralPath $updateCfgPath -Raw | ConvertFrom-Json; if ($uc.api) { $UpdateApi = [string]$uc.api }; if ($uc.role) { $ReleaseRole = [string]$uc.role } } } catch {}
if ($UpdateApi -like '__*') { $UpdateApi = '' }
$Channel  = $(if ($TestMode) { 'test' } else { 'live' })
$RelFile  = $(if ($TestMode) { 'PaycheckWidgetTest.ps1' } else { 'PaycheckWidget.ps1' })   # v2.0.0 app: LIVE = PaycheckLive.ps1, TEST = its own PaycheckLiveTest.ps1 (a TEST update never touches LIVE)
$script:Latest = $null; $script:UpdState = 'unknown'; $script:VerTask = $null; $script:LogTask = $null
$script:NextCheck = [datetime]::MinValue; $script:PromptShown = $false; $script:GlowSb = $null
$script:Inst = [ordered]@{ clientId = ''; name = ''; installedAt = ''; logged = $false; version = ''; dismissed = ''; folderUrl = '' }
try { if (Test-Path -LiteralPath $updateStatePath) { $j = Get-Content -LiteralPath $updateStatePath -Raw | ConvertFrom-Json
        foreach ($k in @($script:Inst.Keys)) { if ($null -ne $j.PSObject.Properties[$k]) { $script:Inst[$k] = $j.$k } } } } catch {}
$updLogPath = Join-Path $cfgDir 'update-log.txt'
function Write-UpdLog([string]$m) { try { Add-Content -LiteralPath $updLogPath -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $m) -Encoding UTF8 } catch {} }
function Save-Inst { try { ($script:Inst | ConvertTo-Json) | Set-Content -LiteralPath $updateStatePath -Encoding UTF8 } catch {} }
function Compare-Ver([string]$a, [string]$b) {
    $x = @($a.TrimStart('v').Split('.') | ForEach-Object { [int]($_ -replace '\D', '') }); $y = @($b.TrimStart('v').Split('.') | ForEach-Object { [int]($_ -replace '\D', '') })
    for ($i = 0; $i -lt [math]::Max($x.Count, $y.Count); $i++) { $p = $(if ($i -lt $x.Count) { $x[$i] } else { 0 }); $q = $(if ($i -lt $y.Count) { $y[$i] } else { 0 }); if ($p -ne $q) { return [math]::Sign($p - $q) } }
    return 0
}
function Get-ApiUrl([string]$query) {   # v2.0.14: an api ending in '/' is the permanent static host (GitHub Pages): <api>version.json / <api><file>
    if ($UpdateApi.EndsWith('/')) { $qq = @{}; foreach ($kv in ($query -split '&')) { $pp = $kv -split '=', 2; $qq[$pp[0]] = $(if ($pp.Count -gt 1) { $pp[1] } else { '' }) }
        if ($qq['file']) { return $UpdateApi + $qq['file'] + '?t=' + $qq['t'] }; return $UpdateApi + 'version.json?t=' + $qq['t'] }
    return ($UpdateApi + $(if ($UpdateApi.Contains('?')) { '&' } else { '?' }) + $query) }
$script:Http = $null
function Get-Http {
    if ($null -eq $script:Http) {
        Add-Type -AssemblyName System.Net.Http
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
        $script:Http = New-Object System.Net.Http.HttpClient; $script:Http.Timeout = [TimeSpan]::FromSeconds(30)
    }
    return $script:Http
}
function Send-Log([string]$event) {
    if (-not $UpdateApi -or $NoNetwork -or $UpdateApi.EndsWith('/')) { return }   # static permanent host has no log endpoint
    $body = [ordered]@{ action = 'log'; event = $event; clientId = $script:Inst.clientId; name = $script:Inst.name; platform = 'PC'; channel = $Channel
                        version = $AppVersion; latestSeen = $(if ($script:Latest) { [string]$script:Latest.version } else { '' }); installedAt = $script:Inst.installedAt }
    try { $hc = Get-Http; $c = New-Object System.Net.Http.StringContent(($body | ConvertTo-Json -Compress), [Text.Encoding]::UTF8, 'text/plain'); $script:LogTask = $hc.PostAsync($UpdateApi, $c); $script:LogEvent = $event; Write-UpdLog ('log ' + $event + ' sent') } catch { Write-UpdLog ('log ' + $event + ' ERROR ' + $_.Exception.Message) }
}
function Set-UpdateUi {
    $b = $ui.UpdateBtn; $t = $ui.UpdateTxt
    $isAv = ($script:UpdState -eq 'available')   # v2.0.13: big UPDATE button only while a newer version exists; footer pill hidden when up to date
    # v2.0.15 TessDesk-style tab (TessDesk v4.3.38 Render-Update): always visible; YES UPDATE green + pulse when newer, NO UPDATE red otherwise
    $ub = $ui.UpdBig; $ut = $ui.UpdBigTxt; $ub.Visibility = 'Visible'
    if ($isAv) { $ut.Text = 'YES UPDATE'; $ut.Foreground = Brush '#FF06210F'; $ub.Background = Brush '#FF49DF93'; $ub.BorderBrush = Brush '#FF49DF93'; $ub.ToolTip = 'YES UPDATE v' + $script:Latest.version + ' is out ' + [char]0x00B7 + ' tap to install'
        if (-not $script:UpdPulse) { $pa = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.45, (New-Object System.Windows.Duration([TimeSpan]::FromSeconds(0.8)))); $pa.AutoReverse = $true; $pa.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever; $ub.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pa); $script:UpdPulse = $true } }
    else { if ($script:UpdPulse) { $ub.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $ub.Opacity = 1; $script:UpdPulse = $false }
        $ut.Text = 'NO UPDATE'; $ut.Foreground = Brush '#FFFFFFFF'; $ub.Background = Brush '#FFE82127'; $ub.BorderBrush = Brush '#FFE82127'
        $ub.ToolTip = $(switch ($script:UpdState) { 'current' { 'NO UPDATE ' + [char]0x00B7 + ' already on v' + $AppVersion + ' ' + [char]0x00B7 + ' tap to check now' } 'checking' { 'NO UPDATE ' + [char]0x00B7 + ' checking' + [char]0x2026 } 'offline' { 'NO UPDATE ' + [char]0x00B7 + ' check failed ' + [char]0x00B7 + ' tap to retry' } default { 'NO UPDATE ' + [char]0x00B7 + ' tap to check now' } }) }
    $b.Visibility = 'Collapsed'   # one UPDATE control, like TessDesk
    if ($script:UpdState -eq 'available') {
        $t.Text = 'UPDATE v' + $script:Latest.version; $t.Foreground = Brush '#FFFFFFFF'; $b.Background = Brush '#FFE82127'
        $b.ToolTip = 'New version v' + $script:Latest.version + ' is published - click to update'
        if ($null -eq $b.Effect) {
            $fx = New-Object System.Windows.Media.Effects.DropShadowEffect; $fx.Color = [System.Windows.Media.Color]::FromRgb(255, 60, 60); $fx.ShadowDepth = 0; $fx.BlurRadius = 14; $fx.Opacity = 1
            $b.Effect = $fx
            $an = New-Object System.Windows.Media.Animation.DoubleAnimation(0.25, 1.0, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(900))))
            $an.AutoReverse = $true; $an.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            $fx.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $an)
        }
    } else {
        $b.Effect = $null; $b.Background = Brush '#FF222222'; $t.Foreground = Brush '#FF777777'
        $t.Text = $(switch ($script:UpdState) { 'current' { 'UP TO DATE' } 'checking' { 'CHECKING' + [char]0x2026 } 'offline' { 'UPDATE' } 'off' { 'UPDATE' } default { 'UPDATE' } })
        $b.ToolTip = $(switch ($script:UpdState) { 'current' { 'You have the latest version (v' + $AppVersion + ')' } 'offline' { 'Could not reach the update server - click to retry' } 'off' { 'Update server not configured' } default { 'Check for updates' } })
    }
}
function Start-UpdateCheck {
    if ($NoNetwork) { return }
    if (-not $UpdateApi) { $script:UpdState = 'off'; Set-UpdateUi; return }
    try { $script:VerTask = (Get-Http).GetStringAsync((Get-ApiUrl ('api=version&c=' + $Channel + '&t=' + [DateTime]::UtcNow.Ticks))); if ($script:UpdState -ne 'available') { $script:UpdState = 'checking'; Set-UpdateUi } } catch { $script:UpdState = 'offline'; Set-UpdateUi }
    $script:NextCheck = (Get-Date).AddMinutes(30)
}
function Format-Changelog($cl) { if ($null -eq $cl) { return '' }; if ($cl -is [string]) { return $cl }; return ((@($cl) | ForEach-Object { [char]0x2022 + ' ' + $_ }) -join "`n") }
function Show-UpdateDialog {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Update available" Width="300" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner">
  <Border Background="#FF111111" BorderBrush="#FFE82127" BorderThickness="1.5" CornerRadius="10" Padding="16,14,16,14">
    <StackPanel>
      <TextBlock Text="UPDATE AVAILABLE" Foreground="#FFE82127" FontFamily="Segoe UI" FontSize="11" FontWeight="Bold"/>
      <TextBlock x:Name="DTitle" Foreground="#FFFFFFFF" FontFamily="Segoe UI" FontSize="17" FontWeight="Bold" Margin="0,4,0,0" TextWrapping="Wrap"/>
      <TextBlock x:Name="DSub" Foreground="#FF888888" FontFamily="Segoe UI" FontSize="10" Margin="0,1,0,8"/>
      <ScrollViewer MaxHeight="190" VerticalScrollBarVisibility="Auto"><TextBlock x:Name="DLog" Foreground="#FFCCCCCC" FontFamily="Segoe UI" FontSize="10.5" TextWrapping="Wrap"/></ScrollViewer>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
        <Button x:Name="DLater" Width="70" Height="26" Background="#FF2A2A2A" Foreground="#FFCCCCCC" BorderThickness="0" FontFamily="Segoe UI" FontWeight="SemiBold" Cursor="Hand" Content="Later"/>
        <Button x:Name="DNow" Width="100" Height="26" Margin="8,0,0,0" Background="#FFE82127" Foreground="#FFFFFFFF" BorderThickness="0" FontFamily="Segoe UI" FontWeight="Bold" Cursor="Hand" Content="Update now"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
    $d = [Windows.Markup.XamlReader]::Parse($x)
    try { $d.Owner = $window } catch {}
    $d.FindName('DTitle').Text = $(if ($TestMode) { 'Paycheck Test' } else { 'Paycheck Live' }) + ' v' + $script:Latest.version + ' is ready'
    $d.FindName('DSub').Text = 'You have v' + $AppVersion + $(if ($script:Latest.date) { '  ' + [char]0x00B7 + '  published ' + $script:Latest.date } else { '' })
    $d.FindName('DLog').Text = (Format-Changelog $script:Latest.changelog) + $(if ($AppMode) { "`n`n" + $(if ($script:Latest.hostVersion -and (Compare-Ver ([string]$script:Latest.hostVersion) $(if ($HostVersion) { $HostVersion } else { '0' })) -gt 0) { 'Update now downloads the new PaycheckLive setup, closes the app, installs it and reopens it. Your punches and settings stay.' } else { 'Update now downloads the update, closes Paycheck Live and reopens it. Your punches and settings stay.' }) } else { '' })
    $script:DlgResult = 'later'
    $d.FindName('DNow').Add_Click({ param($s0, $e0) $script:DlgResult = 'now'; [System.Windows.Window]::GetWindow($s0).Close() })
    $d.FindName('DLater').Add_Click({ param($s0, $e0) $script:DlgResult = 'later'; [System.Windows.Window]::GetWindow($s0).Close() })
    $d.Add_MouseLeftButtonDown({ param($s0, $e0) try { $s0.DragMove() } catch {} })
    [void]$d.ShowDialog()
    if ($script:DlgResult -eq 'now') { Invoke-SelfUpdate } else { $script:Inst.dismissed = [string]$script:Latest.version; Save-Inst }
}
function Invoke-SetupUpdate {   # v2.0.0: a newer PaycheckLive.exe ships inside the Setup exe: download, close, silent install, relaunch
    $ui.UpdateTxt.Text = 'DOWNLOADING' + [char]0x2026
    $bytes = (Get-Http).GetByteArrayAsync((Get-ApiUrl ('file=' + [string]$script:Latest.setup + '&t=' + [DateTime]::UtcNow.Ticks))).GetAwaiter().GetResult()
    if ($bytes.Length -lt 100000 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw 'The downloaded setup is not a Windows program.' }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ([string]$script:Latest.setup); [IO.File]::WriteAllBytes($tmp, $bytes)
    Write-UpdLog ('setup update ' + $script:Latest.version + ' -> ' + $tmp)
    $timer.Stop()
    $sa = @('/S', '/relaunch', '/waitpid', [string]$PID); if ($TestMode) { $sa += '/relaunchtest' }
    Start-Process -FilePath $tmp -ArgumentList $sa
    $window.Close()
}
function Invoke-SelfUpdate {
    try {
        if ($AppMode -and $script:Latest.setup -and $script:Latest.hostVersion -and (Compare-Ver ([string]$script:Latest.hostVersion) $(if ($HostVersion) { $HostVersion } else { '0' })) -gt 0) { Invoke-SetupUpdate; return }
        $ui.UpdateTxt.Text = 'UPDATING' + [char]0x2026
        $code = (Get-Http).GetStringAsync((Get-ApiUrl ('file=' + $RelFile + '&t=' + [DateTime]::UtcNow.Ticks))).GetAwaiter().GetResult()
        $code = $code.TrimStart([char]0xFEFF)
        $m = [regex]::Match($code, "\`$AppVersion = '([0-9.]+)'")
        if (-not $m.Success) { throw 'Downloaded file is not a Paycheck widget build.' }
        $errs = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$errs)
        if ($errs -and $errs.Count -gt 0) { throw ('Downloaded build has ' + $errs.Count + ' syntax error(s); not installed.') }
        if ((Compare-Ver $m.Groups[1].Value $AppVersion) -le 0) { throw ('Server build v' + $m.Groups[1].Value + ' is not newer than v' + $AppVersion + '.') }
        $me = $PSCommandPath
        $bak = $me + '.bak-v' + $AppVersion + '-' + (Get-Date).ToString('yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $me -Destination $bak -Force
        [IO.File]::WriteAllText($me, $code, (New-Object Text.UTF8Encoding $true))
        $timer.Stop()
        if ($AppMode -and $HostExe -and (Test-Path -LiteralPath $HostExe)) {   # v2.0.0: relaunch the app exe (it waits for this process to exit)
            $ha = @('--wait-pid', [string]$PID); if ($TestMode) { $ha += '--test' }
            Start-Process -FilePath $HostExe -ArgumentList $ha
        } else { Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $me + '"')) -WindowStyle Hidden }
        $window.Close()
    } catch {
        [void][System.Windows.MessageBox]::Show(('Update failed: ' + $_.Exception.Message + "`n`nYour current version was left in place."), 'Paycheck update')
        Set-UpdateUi
    }
}
function Poll-Update {
    if ($null -ne $script:VerTask -and $script:VerTask.IsCompleted) {
        $t = $script:VerTask; $script:VerTask = $null
        if ($t.IsFaulted -or $t.IsCanceled) { if ($script:UpdState -ne 'available') { $script:UpdState = 'offline' } }
        else {
            try {
                $v = $t.Result | ConvertFrom-Json
                if ($v.version) {
                    $first = ($null -eq $script:Latest)
                    $script:Latest = $v
                    $script:UpdState = $(if ((Compare-Ver ([string]$v.version) $AppVersion) -gt 0) { 'available' } else { 'current' })
                    if ($first) { Send-Log 'open' }
                }
            } catch { $script:UpdState = 'offline' }
        }
        Set-UpdateUi
        if ($script:UpdState -eq 'available' -and -not $script:PromptShown -and [string]$script:Inst.dismissed -ne [string]$script:Latest.version) { $script:PromptShown = $true; Show-UpdateDialog }
    }
    if ($null -ne $script:LogTask -and $script:LogTask.IsCompleted) {
        $t = $script:LogTask; $script:LogTask = $null
        if (-not $t.IsFaulted -and -not $t.IsCanceled -and $t.Result.IsSuccessStatusCode) {
            try { $r = $t.Result.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json; if ($r.folderUrl) { $script:Inst.folderUrl = [string]$r.folderUrl } } catch {}
            if (-not $script:Inst.logged) { $script:Inst.logged = $true }
            $script:Inst.version = $AppVersion; Save-Inst
        }
    }
    if ((Get-Date) -ge $script:NextCheck -and $null -eq $script:VerTask) { Start-UpdateCheck }
}
$ui.UpdBig.Add_MouseLeftButtonUp({ if ($script:UpdState -eq 'available') { $ui.UpdBigTxt.Text = 'UPDATING'; $ui.UpdBig.Cursor = [System.Windows.Input.Cursors]::Wait; Invoke-SelfUpdate } else { Start-UpdateCheck } })   # v2.0.15: YES UPDATE installs, NO UPDATE checks at once
$ui.UpdateBtn.Add_Click({
    if ($script:UpdState -eq 'available') { Show-UpdateDialog } else { Start-UpdateCheck }
})

# Placement: Van's left-screen arrangement (2026-09-29), all tops at WorkArea.Top + 42, 12 DIP gaps,
# on the primary/left display (\\.\DISPLAY1, 1920x1080 @ 100%), NOT the screen under the mouse:
#   INSTALLER PREVIEW Left = WorkArea.Right - 1281 (639,42)  (v1.12.0)
#   PAYCHECK TEST  Left = WorkArea.Right - 981  (939,42)
#   PAYCHECK LIVE  Left = WorkArea.Right - 681  (1239,42)
#   TESLA          Left = WorkArea.Right - 381  (1539,42)
function Get-LeftDisplayWorkArea {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $scr = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -match 'DISPLAY1$' } | Select-Object -First 1
        if (-not $scr) { $scr = [System.Windows.Forms.Screen]::PrimaryScreen }
        # device px -> WPF DIP (system DPI; DISPLAY1 is 100% so this is 1.0)
        $k = 1.0
        try { $k = [System.Windows.SystemParameters]::PrimaryScreenWidth / [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width } catch {}
        if ($k -le 0) { $k = 1.0 }
        $w = $scr.WorkingArea
        return New-Object System.Windows.Rect(($w.X * $k), ($w.Y * $k), ($w.Width * $k), ($w.Height * $k))
    } catch { return [System.Windows.SystemParameters]::WorkArea }
}
try {
    $wa = Get-LeftDisplayWorkArea
    $window.Left = $(if ($InstallerPreview) { $wa.Right - 1281 } elseif ($TestMode) { $wa.Right - 981 } else { $wa.Right - 681 })
    $window.Top  = $wa.Top + 42
    $maxH = [math]::Floor($wa.Bottom - $window.Top - 6); if ($maxH -ge 600 -and $window.Height -gt $maxH) { $window.Height = $maxH }   # v1.15.0: keep the taller widget on screen
} catch { $window.Left = 40; $window.Top = 40 }
if ($InstallerPreview) { $ui.SimTag.Text = 'INSTALLER PREVIEW'
    if ($PreviewName) { $pp = ($BlankProfileJson | ConvertFrom-Json); $pp.name = $PreviewName; $pp.nextPayday = (Get-Now).Date.AddDays(8).ToString('yyyy-MM-dd'); [void](Save-ProfileFile $pp); Set-Profile $pp; $script:NeedSetup = $false } }

# ---------------- 2026-10-03: RESTORE / REMEMBER window position (same look + behavior as the stream windows' Restore / Remember buttons) ----------------
# Buttons fade in at the top-right when the mouse moves over the window (hide again 2.2 s after the mouse stops), like the stream windows.
#   Restore  = snap this window back to its remembered size and place (stays on top). Nothing remembered yet -> the built-in startup place.
#   Remember = save this window's current size and place (used by Restore and at startup).
# Saved places: C:\Users\<you>\desk_window_layout.json (one entry per window, WPF units; only THIS window's entry is ever rewritten).
$script:DWL_File = Join-Path $env:USERPROFILE 'desk_window_layout.json'
$script:DWL_Name = $(if ($InstallerPreview) { 'PAYCHECK_INSTALLER_PREVIEW' } elseif ($TestMode) { 'PAYCHECK_TEST' } else { 'PAYCHECK_LIVE' })
$script:DWL_Default = $null
function DeskWin-Rect {
    $dwW = $window.ActualWidth; if (-not ($dwW -gt 0)) { $dwW = $window.Width }
    $dwH = $window.ActualHeight; if (-not ($dwH -gt 0)) { $dwH = $window.Height }
    return [ordered]@{ x = [int][math]::Round($window.Left); y = [int][math]::Round($window.Top); w = [int][math]::Round($dwW); h = [int][math]::Round($dwH) }
}
function DeskWin-ReadDoc { try { if (Test-Path -LiteralPath $script:DWL_File) { return (Get-Content -LiteralPath $script:DWL_File -Raw | ConvertFrom-Json) } } catch {}; return $null }
function DeskWin-GetSaved {
    $dwDoc = DeskWin-ReadDoc
    if ($dwDoc -and $dwDoc.windows) {
        $dwE = @($dwDoc.windows | Where-Object { [string]$_.name -eq $script:DWL_Name }) | Select-Object -First 1
        if ($dwE -and $null -ne $dwE.x -and $null -ne $dwE.y -and [int]$dwE.w -ge 100 -and [int]$dwE.h -ge 60) { return $dwE }
    }
    return $null
}
function DeskWin-Apply($dwE) {
    if ($window.WindowState -ne [System.Windows.WindowState]::Normal) { $window.WindowState = [System.Windows.WindowState]::Normal }
    $window.Topmost = $true
    $window.Left = [double]$dwE.x; $window.Top = [double]$dwE.y; $window.Width = [double]$dwE.w; $window.Height = [double]$dwE.h
}
function DeskWin-Restore {
    $dwE = DeskWin-GetSaved; $dwFrom = 'layout'
    if (-not $dwE) { $dwE = $script:DWL_Default; $dwFrom = 'default' }
    if (-not $dwE) { return @{ ok = $false; error = 'no saved place' } }
    if ($dwFrom -eq 'default') {
        # nothing remembered yet: back to the built-in startup place; keep the size the app chose itself (TessDesk / Paycheck size themselves after start)
        if ($window.WindowState -ne [System.Windows.WindowState]::Normal) { $window.WindowState = [System.Windows.WindowState]::Normal }
        $window.Topmost = $true; $window.Left = [double]$dwE.x; $window.Top = [double]$dwE.y
    } else { DeskWin-Apply $dwE }
    try { $window.UpdateLayout(); [void]$window.Activate() } catch {}
    $dwGot = DeskWin-Rect
    $dwOk = ([math]::Abs($dwGot.x - [int]$dwE.x) -le 1 -and [math]::Abs($dwGot.y - [int]$dwE.y) -le 1)
    return @{ ok = $dwOk; from = $dwFrom; rect = $dwGot }
}
function DeskWin-Remember {
    if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) { return @{ ok = $false; error = 'minimized - not saved' } }
    if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) { return @{ ok = $false; error = 'maximized - not saved' } }
    $dwGot = DeskWin-Rect
    $vl = [System.Windows.SystemParameters]::VirtualScreenLeft; $vt = [System.Windows.SystemParameters]::VirtualScreenTop
    $vw = [System.Windows.SystemParameters]::VirtualScreenWidth; $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
    $dwOn = ($dwGot.x + $dwGot.w -gt $vl + 40) -and ($dwGot.x -lt $vl + $vw - 40) -and ($dwGot.y + 30 -gt $vt) -and ($dwGot.y -lt $vt + $vh - 40)
    if (-not $dwOn) { return @{ ok = $false; error = 'offscreen - not saved'; rect = $dwGot } }
    if ($dwGot.w -lt 100 -or $dwGot.h -lt 60 -or $dwGot.w -gt $vw -or $dwGot.h -gt $vh) { return @{ ok = $false; error = 'implausible size - not saved'; rect = $dwGot } }
    # Update ONLY this entry; keep every other entry exactly as it is
    $dwDoc = DeskWin-ReadDoc
    $dwList = New-Object System.Collections.Generic.List[object]; $dwFound = $false
    if ($dwDoc -and $dwDoc.windows) {
        foreach ($dwE in @($dwDoc.windows)) {
            if ([string]$dwE.name -eq $script:DWL_Name) {
                $dwE.x = $dwGot.x; $dwE.y = $dwGot.y; $dwE.w = $dwGot.w; $dwE.h = $dwGot.h
                if ($dwE.PSObject.Properties['source']) { $dwE.source = 'remembered' } else { $dwE | Add-Member -NotePropertyName source -NotePropertyValue 'remembered' }
                $dwFound = $true
            }
            $dwList.Add($dwE)
        }
    }
    if (-not $dwFound) { $dwList.Add([pscustomobject][ordered]@{ name = $script:DWL_Name; script = [string]$MyInvocation.ScriptName; x = $dwGot.x; y = $dwGot.y; w = $dwGot.w; h = $dwGot.h; source = 'remembered' }) }
    $dwNew = [ordered]@{ saved = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); note = 'Written by the Remember button of Paycheck Live / TessDesk / TimeClock Live; read by their Restore button and at startup'; windows = $dwList.ToArray() }
    $dwTmp = $script:DWL_File + '.tmp'
    $dwNew | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $dwTmp -Encoding UTF8
    Move-Item -LiteralPath $dwTmp -Destination $script:DWL_File -Force
    return @{ ok = $true; saved = $true; rect = $dwGot }
}
function DeskWin-Fade([double]$dwTo) {
    $dwA = New-Object System.Windows.Media.Animation.DoubleAnimation
    $dwA.To = $dwTo; $dwA.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(150))
    $script:DWL_Row.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $dwA)
    $script:DWL_Row.IsHitTestVisible = ($dwTo -gt 0)
}
function DeskWin-Show { try { if (-not $script:DWL_Row.IsHitTestVisible) { DeskWin-Fade 0.95 }; $script:DWL_Hide.Stop(); $script:DWL_Hide.Start() } catch {} }
function DeskWin-Action($dwBtn, [string]$dwAct, [string]$dwOkText) {
    if (-not $dwBtn.IsEnabled) { return }
    $dwLabel = [string]$dwBtn.Content
    $dwBtn.IsEnabled = $false
    $dwD = $null
    try { if ($dwAct -eq 'restore') { $dwD = DeskWin-Restore } else { $dwD = DeskWin-Remember } } catch { $dwD = @{ ok = $false; error = $_.Exception.Message } }
    $dwBtn.Content = $(if ($dwD -and $dwD.ok) { $dwOkText } else { 'failed' })
    $dwBtn.ToolTip = $(if ($dwD -and $dwD.rect) { $dwAct + ': ' + $dwD.rect.x + ',' + $dwD.rect.y + ' ' + $dwD.rect.w + 'x' + $dwD.rect.h + $(if ($dwD.error) { ' (' + $dwD.error + ')' } else { '' }) } elseif ($dwD -and $dwD.error) { [string]$dwD.error } else { 'failed' })
    $dwT = New-Object System.Windows.Threading.DispatcherTimer
    $dwT.Interval = [TimeSpan]::FromMilliseconds(1400)
    $dwT.Tag = @($dwBtn, $dwLabel)
    $dwT.Add_Tick({ param($s, $ev) try { $s.Stop(); $s.Tag[0].Content = $s.Tag[1]; $s.Tag[0].IsEnabled = $true } catch {} })
    $dwT.Start()
    DeskWin-Show
}
function DeskWin-Attach($dwRootBorder, [string]$dwMargin) {
    $dwX = @'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
            Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="__M__" Opacity="0" IsHitTestVisible="False" Panel.ZIndex="50">
  <StackPanel.Resources>
    <ControlTemplate x:Key="WinPosBtn" TargetType="Button">
      <Border x:Name="bd" Background="#FF444444" CornerRadius="4" Padding="6,0,6,0" Height="16">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#FF666666"/><Setter Property="Foreground" Value="#FFFFFFFF"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
  </StackPanel.Resources>
  <Button Template="{StaticResource WinPosBtn}" Content="&#x27F2; Restore" Foreground="#FFDDDDDD" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold" Cursor="Hand" Focusable="False"
          ToolTip="Restore this window to its saved size and place (stays on top)"/>
  <Button Template="{StaticResource WinPosBtn}" Content="Remember" Margin="3,0,0,0" Foreground="#FFDDDDDD" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold" Cursor="Hand" Focusable="False"
          ToolTip="Remember this window's current size and place (used by Restore and startup)"/>
</StackPanel>
'@
    $script:DWL_Row = [Windows.Markup.XamlReader]::Parse($dwX.Replace('__M__', $dwMargin))
    $dwChild = $dwRootBorder.Child
    if ($dwChild -is [System.Windows.Controls.Grid]) { [void]$dwChild.Children.Add($script:DWL_Row) }
    else { $dwRootBorder.Child = $null; $dwG = New-Object System.Windows.Controls.Grid; [void]$dwG.Children.Add($dwChild); [void]$dwG.Children.Add($script:DWL_Row); $dwRootBorder.Child = $dwG }
    $script:DWL_Restore = $script:DWL_Row.Children[0]; $script:DWL_Remember = $script:DWL_Row.Children[1]
    $script:DWL_Restore.Add_Click({ param($s, $ev) try { $ev.Handled = $true; DeskWin-Action $s 'restore' 'restored' } catch {} })
    $script:DWL_Remember.Add_Click({ param($s, $ev) try { $ev.Handled = $true; DeskWin-Action $s 'remember' 'saved' } catch {} })
    $script:DWL_Hide = New-Object System.Windows.Threading.DispatcherTimer
    $script:DWL_Hide.Interval = [TimeSpan]::FromMilliseconds(2200)
    $script:DWL_Hide.Add_Tick({ try { if ($script:DWL_Row.IsMouseOver) { return }; $script:DWL_Hide.Stop(); DeskWin-Fade 0 } catch {} })
    $window.Add_PreviewMouseMove({ DeskWin-Show })
    $window.Add_PreviewMouseDown({ DeskWin-Show })
}
# ---------------- end RESTORE / REMEMBER ----------------
try {
    $script:DWL_Default = DeskWin-Rect
    if (-not $RenderPng -and -not $RenderSettingsPng) { $dwS = DeskWin-GetSaved; if ($dwS) { DeskWin-Apply $dwS } }
    DeskWin-Attach $ui.Root '0,34,14,0'
} catch {}

Update-Ui

function Save-Render([string]$path) {
    $root = $ui.Root
    $root.UpdateLayout()
    $pw = [int][math]::Ceiling($winW * $RenderScale); $ph = [int][math]::Ceiling($winH * $RenderScale)
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($pw, $ph, (96 * $RenderScale), (96 * $RenderScale), [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($root)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [System.IO.File]::Create($path); $enc.Save($fs); $fs.Close()
}

if ($RenderSettingsPng) {
    $f = New-SettingsWindow ([bool]$SettingsFirst)
    $w = $f.Window
    $w.SizeToContent = [System.Windows.SizeToContent]::Height; $w.Left = -10000; $w.Top = -10000; $w.ShowInTaskbar = $false
    $w.Add_ContentRendered({
        try {
            if ($SettingsScrollEnd) { $sv = $w.FindName('SScroll'); if ($sv) { $sv.UpdateLayout(); $sv.ScrollToEnd(); $sv.UpdateLayout() } }
            $rt2 = $f.SRoot; $rt2.UpdateLayout()
            $pw = [int][math]::Ceiling($rt2.ActualWidth * $RenderScale); $ph = [int][math]::Ceiling($rt2.ActualHeight * $RenderScale)
            $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($pw, $ph, (96 * $RenderScale), (96 * $RenderScale), [System.Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($rt2)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $fs = [System.IO.File]::Create($RenderSettingsPng); $enc.Save($fs); $fs.Close()
            $chk = Read-SettingsForm $f
            Set-Content -LiteralPath ($RenderSettingsPng + '.log.txt') -Value ('form parse: ' + $(if ($chk.Error) { 'ERROR ' + $chk.Error } else { ($chk.Profile | ConvertTo-Json -Depth 6 -Compress) })) -Encoding UTF8
        } catch { Set-Content -LiteralPath ($RenderSettingsPng + '.log.txt') -Value ('RenderError: ' + $_.Exception.Message) -Encoding UTF8 }
        $w.Close()
    })
    [void]$w.ShowDialog()
    return
}
# v2.0.9: height fit removed again (Van wants DESIGN BY VAN at the bottom of the full-height window, where it always was)
if ($RenderPng) {
    $logPath = $RenderPng + '.log.txt'
    Set-Content -LiteralPath $logPath -Value ('render log ' + (Get-CentralNow).ToString('s')) -Encoding UTF8
    function Log([string]$m) { Add-Content -LiteralPath $logPath -Value ((Get-CentralNow).ToString('HH:mm:ss.fff') + '  ' + $m) -Encoding UTF8 }
    $window.Left = -10000; $window.Top = -10000; $window.ShowInTaskbar = $false
    if ($FakeLatest) { $script:Latest = [pscustomobject]@{ version = $FakeLatest; date = '2026-09-29'; changelog = @('Render preview') }; $script:UpdState = 'available'; Set-UpdateUi }
    $click = { param($btn) $btn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
    if ($PunchScript) {   # e.g. in@11:35,lo@15:02:10 -> punches on today's (sim) date, written to the punch file of this copy
        $pd0 = $(if ($TestMode) { (Get-TestSimNow).Date } else { (Get-Now).Date }); $iso0 = $pd0.ToString('yyyy-MM-dd'); $l0 = New-Object System.Collections.ArrayList
        foreach ($tok in ($PunchScript -split ',')) { if ($tok -match '^\s*(in|lo|li|out|bs|be)@(\d{1,2}):(\d\d)(?::(\d\d))?\s*$') { [void]$l0.Add(@($matches[1], ([int]$matches[2] * 3600 + [int]$matches[3] * 60 + $(if ($matches[4]) { [int]$matches[4] } else { 0 })))) } }
        $script:Punches[$iso0] = $l0; $script:ShiftCache = @{}; $script:StraightCache = @{}; Update-Ui
    }
    $script:RenderT0 = $null; $script:Stopped = $false; $script:Restarted = $false
    $window.Add_ContentRendered({
        try {
            $script:RenderT0 = Get-CentralNow
            if ($TestMode -and $TestAutoStart) {
                & $click $ui.StartBtn
                Log ("clicked START -> sim " + (Get-TestSimNow).ToString('HH:mm:ss') + " state=" + $script:TestState + " hero=" + $ui.HeroAmt.Text)
                if ($TestStartOffsetMin -ne 0) { $script:TestClickReal = $script:TestClickReal.AddMinutes(-$TestStartOffsetMin); Update-Ui
                    Log ("offset start by -$TestStartOffsetMin min -> sim " + (Get-TestSimNow).ToString('ddd MM/dd HH:mm:ss')) }
                foreach ($tc in @($TestClicks -split ',' | Where-Object { $_ })) { & $click $ui["PB_$tc"]; Update-Ui
                    Log ("clicked $tc at sim " + (Get-TestSimNow).ToString('ddd MM/dd HH:mm:ss') + " hero=" + $ui.HeroAmt.Text + " ot=" + $ui.HBOT.Text + " period=" + $ui.PeriodNet.Text) }
            }
            $script:RT = New-Object System.Windows.Threading.DispatcherTimer
            $rt = $script:RT
            $rt.Interval = [TimeSpan]::FromMilliseconds(250)
            $rt.Add_Tick({
                $el = ((Get-CentralNow) - $script:RenderT0).TotalSeconds
                if ($TestMode -and $TestAutoStopAfterSec -ge 0 -and -not $script:Stopped -and $el -ge $TestAutoStopAfterSec) {
                    & $click $ui.StopBtn; $script:Stopped = $true
                    Log ("clicked STOP -> sim " + (Get-TestSimNow).ToString('HH:mm:ss') + " state=" + $script:TestState + " hero=" + $ui.HeroAmt.Text)
                }
                if ($TestMode -and $TestRestartAfterSec -ge 0 -and -not $script:Restarted -and $el -ge $TestRestartAfterSec) {
                    & $click $ui.StartBtn; $script:Restarted = $true
                    Log ("clicked START again -> sim " + (Get-TestSimNow).ToString('HH:mm:ss') + " hero=" + $ui.HeroAmt.Text + " period=" + $ui.PeriodNet.Text)
                }
                if ($el -ge $RenderDelaySec) {
                    $script:RT.Stop()
                    Update-Ui
                    Save-Render $RenderPng
                    Log ("rendered at sim " + $(if ($TestMode) { (Get-TestSimNow).ToString('HH:mm:ss') } else { (Get-Now).ToString('HH:mm') }) + " status=" + $ui.StatusText.Text +
                         " hero=" + $ui.HeroAmt.Text + " sub=" + $ui.HeroSub.Text + " detail=" + $ui.StatusDetail.Text + " period=" + $ui.PeriodNet.Text + " brk=" + $ui.BrkLive.Text + " lunch=" + $ui.LunLive.Text + (" fit=extent {0:0.0} / viewport {1:0.0}" -f $ui.DailyScroll.ExtentHeight, $ui.DailyScroll.ViewportHeight) + " -> " + $RenderPng)
                    $window.Close()
                }
            })
            $rt.Start()
        } catch { Log ("RenderError: " + $_.Exception.Message); $window.Close() }
    })
    [void]$window.ShowDialog()
    return
}

# Real widget: 5 s poll, repaint when the minute changes (so it refreshes every minute, on the minute).
# TEST widget: 1 s poll so the simulated clock visibly runs; numbers repaint on each simulated minute.
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)   # v1.12.0: 1 s so the break / lunch stopwatches run; numbers repaint on each minute
$timer.Add_Tick({
    try {
        if ($TestMode) {
            $n = Get-TestSimNow
            if (($n.ToString('yyyyMMddHHmm') + $script:TestState) -ne $script:LastKey) { Update-Ui } else { Update-TestClock }
        } elseif ((Get-Now).ToString('yyyyMMddHHmm') -ne $script:LastKey.Substring(0, 12)) { Update-Ui } else { Update-PunchTick $null }
    } catch {}
})
$timer.Add_Tick({ try { Poll-Update } catch {} })
# v1.11.0 first run: SETUP wizard (everything the math needs; the name from setup is what logs to Users).
# Existing installs (v1.10.x, already registered) keep going with Van's profile under their registered name.
if ($InstallerPreview) {
    # v1.12.0 INSTALLER PREVIEW: the full first-run setup exactly as a brand-new user sees it, every time this window opens.
    # Everything it saves goes to a scratch folder (wiped on each open); no install log, no update checks, Van's real profile untouched.
    $ui.SimTag.Text = 'INSTALLER PREVIEW'; $ui.SimTag.Foreground = Brush '#FFFFB020'
    if (-not $PreviewName -and -not (Show-Settings $true)) { $window.Close(); return }
    $script:Inst.name = [string]$script:Profile.name
    Update-Ui
} elseif ($script:NeedSetup) {
    if ($false) {
    } else {   # v2.0.13: always the blank first-run setup; nothing of Van's is prefilled
        if (-not (Show-Settings $true)) { $pp = ($BlankProfileJson | ConvertFrom-Json); $pp.name = [string]$env:USERNAME; [void](Save-ProfileFile $pp); Set-Profile $pp }
        $script:Inst.name = [string]$script:Profile.name
    }
    Update-Ui
}
# register this install, then report updates by version change
if (-not $NoNetwork) {
    if (-not $script:Inst.clientId) { $script:Inst.clientId = [guid]::NewGuid().ToString(); $script:Inst.installedAt = (Get-CentralNow).ToString('yyyy-MM-dd HH:mm') }
    if (-not $script:Inst.name) { $script:Inst.name = [string]$script:Profile.name }
    Save-Inst
    if (-not $script:Inst.logged) { Send-Log 'install' }
    elseif ([string]$script:Inst.version -and (Compare-Ver $AppVersion ([string]$script:Inst.version)) -ne 0) { Send-Log 'update' }
    Start-UpdateCheck
} else { $script:UpdState = 'off' }
Set-UpdateUi
$timer.Start()
$window.Add_Closed({ try { $timer.Stop() } catch {} })
if ($InstallerPreview) { $ui.UpdateTxt.Text = 'PREVIEW'; $ui.UpdateBtn.ToolTip = 'Installer preview: updates are off'
    $ui.VersionText.ToolTip = 'Installer preview - close and reopen "Paycheck Live Installer Preview" to run the install again' }

# v2.0.2: OFF (compact) mode from STREAMING WINDOWS' add-on, same hook as TessDesk / TIMECLOCK LIVE. OFF shrinks the window to a
# small card (snapshot + ON / Restore + DESIGN BY VAN); ON brings the full window back. -Name = this window's entry in cb_window_layout.json.
# Only when the add-on exists on this PC (other installs skip it); never in the installer preview.
if (-not $InstallerPreview) {
    try { $cbAddon = Join-Path $env:USERPROFILE 'cb_compact_addon.ps1'
          if (Test-Path -LiteralPath $cbAddon) { . $cbAddon; Enable-CbCompactMode -Window $window -Name $(if ($TestMode) { 'PAYCHECK_TEST' } else { 'PAYCHECK_LIVE' }) -Version $AppVersion -OffMargin '8,40,0,0'
              # v2.0.3: hide the gray hover Restore / Remember pair before the add-on takes the OFF card snapshot (press fires before Click)
              try { $script:CbCompact.OffBtn.Add_PreviewMouseLeftButtonDown({ try { $script:DWL_Hide.Stop(); $script:DWL_Row.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $script:DWL_Row.Opacity = 0; $script:DWL_Row.IsHitTestVisible = $false } catch {} }) } catch {} } } catch { }
}
# v2.0.4 (Oct 4, 2026): X (close) on the OFF / mini card too, same as the title-bar X: closes the window and exits the app
try { if ($script:CbCompact -and $script:CbCompact.Window -eq $window) { $cbXp = $script:CbCompact.Card.Child.Children[1]; $cbXbc = New-Object System.Windows.Media.BrushConverter
      $cbX = New-Object System.Windows.Controls.Button; $cbX.Template = $cbXp.Children[0].Template; $cbX.Background = $cbXbc.ConvertFromString('#FF444444'); $cbX.Foreground = $cbXbc.ConvertFromString('#FFDDDDDD')
      $cbX.Content = [string][char]0x2715; $cbX.FontFamily = 'Segoe UI'; $cbX.FontSize = 10; $cbX.FontWeight = [System.Windows.FontWeights]::Bold; $cbX.Margin = '4,0,0,0'
      $cbX.Cursor = [System.Windows.Input.Cursors]::Hand; $cbX.Focusable = $false; $cbX.ToolTip = 'Close'; [System.Windows.Automation.AutomationProperties]::SetName($cbX, 'Close')
      $cbX.Add_Click({ param($s9, $e9) $e9.Handled = $true; $window.Close() }); [void]$cbXp.Children.Add($cbX) } } catch { }
[void]$window.ShowDialog()
