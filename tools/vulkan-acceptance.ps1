param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("run", "recovery-start", "recovery-complete", "report", "self-test")]
    [string]$Action,

    [ValidateSet("local", "rdp", "all")]
    [string]$Session = "all",

    [ValidateSet("d3d11", "opengl", "vulkan", "native-vulkan")]
    [string]$Renderer = "d3d11",

    [ValidateSet("auto", "present_wait_mailbox", "timeline_mailbox", "fifo")]
    [string]$PresentTier = "auto",

    [ValidateSet("reconnect", "session-switch")]
    [string]$RecoveryEvent = "reconnect",

    [string]$OutputDirectory = "tmp\vulkan-acceptance"
)

$ErrorActionPreference = "Stop"
$rendererWasSpecified = $PSBoundParameters.ContainsKey("Renderer")
$projectRoot = Split-Path $PSScriptRoot -Parent
$exePath = Join-Path $projectRoot "zig-out\bin\Mostty.exe"
$diagPath = Join-Path $projectRoot "tmp\mostty-diag.log"
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory
} else {
    Join-Path $projectRoot $OutputDirectory
}

if (-not ("VulkanAcceptanceNative" -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class VulkanAcceptanceNative {
    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lparam);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lparam);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hwnd, StringBuilder className, int maxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int maxCount);
    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr hwnd, EnumWindowsProc callback, IntPtr lparam);
    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern IntPtr GetWindowLongPtrW(IntPtr hwnd, int index);
    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")]
    public static extern bool PostMessageW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll")]
    public static extern IntPtr GetDlgItem(IntPtr hwnd, int id);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);

    public static IntPtr FindDialog(int wantedProcessId) {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr lparam) {
            uint processId;
            GetWindowThreadProcessId(hwnd, out processId);
            if (processId != wantedProcessId) return true;
            var className = new StringBuilder(32);
            GetClassName(hwnd, className, className.Capacity);
            if (className.ToString() == "#32770") { result = hwnd; return false; }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static string DialogText(IntPtr hwnd) {
        var result = new StringBuilder();
        EnumChildWindows(hwnd, delegate(IntPtr child, IntPtr lparam) {
            var text = new StringBuilder(1024);
            GetWindowText(child, text, text.Capacity);
            if (text.Length != 0) {
                if (result.Length != 0) result.Append(" | ");
                result.Append(text);
            }
            return true;
        }, IntPtr.Zero);
        return result.ToString();
    }
}
'@
}

Add-Type -AssemblyName System.Drawing

function Get-ActualSession {
    if ([VulkanAcceptanceNative]::GetSystemMetrics(0x1000) -ne 0) { return "rdp" }
    return "local"
}

function Get-ResultPath {
    param([string]$ActualSession, [string]$CaseRenderer, [string]$Tier, [string]$Scenario)
    return Join-Path $outputRoot "$ActualSession-$CaseRenderer-$Tier-$Scenario.json"
}

function Read-DiagnosticLog {
    if (-not (Test-Path -LiteralPath $diagPath)) { return "" }
    $stream = [IO.File]::Open($diagPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reader = [IO.StreamReader]::new($stream)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Get-DiagnosticTail {
    param([string]$Diagnostic, [int64]$Offset)
    if ($Offset -lt 0) { throw "diagnostic offset cannot be negative" }
    if ($Offset -gt $Diagnostic.Length) { return $Diagnostic }
    return $Diagnostic.Substring([int]$Offset)
}

function Resolve-RecoveryRenderer {
    param([string]$Requested, [bool]$WasSpecified, [string]$Saved)
    if ($WasSpecified -and $Requested -ne $Saved) { throw "recovery renderer does not match saved state" }
    return $Saved
}

function Start-AcceptanceProcess {
    param([string]$CaseRenderer, [string]$Tier)

    if (-not (Test-Path -LiteralPath $exePath)) { throw "Mostty executable not found: $exePath" }
    New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
    $profile = Join-Path $outputRoot "profile-$CaseRenderer-$Tier"
    New-Item -ItemType Directory -Force -Path $profile | Out-Null
    $env:LOCALAPPDATA = $profile
    $env:MOSTTY_DIAG = "1"
    if ($CaseRenderer -eq "native-vulkan" -and $Tier -ne "auto") {
        $env:MOSTTY_VULKAN_PRESENT_TIER = $Tier
    } else {
        Remove-Item Env:MOSTTY_VULKAN_PRESENT_TIER -ErrorAction SilentlyContinue
    }
    return Start-Process -FilePath $exePath -WorkingDirectory $projectRoot -ArgumentList @("--renderer", $CaseRenderer) -PassThru
}

function Wait-AcceptanceWindow {
    param([Diagnostics.Process]$Process)

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 100
        $Process.Refresh()
        if ($Process.HasExited) { throw "Mostty exited during startup with code $($Process.ExitCode)" }
        $dialog = [VulkanAcceptanceNative]::FindDialog($Process.Id)
    } while ($Process.MainWindowHandle -eq [IntPtr]::Zero -and $dialog -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)

    if ($dialog -ne [IntPtr]::Zero) {
        $text = [VulkanAcceptanceNative]::DialogText($dialog)
        $noButton = [VulkanAcceptanceNative]::GetDlgItem($dialog, 7)
        if ($noButton -ne [IntPtr]::Zero) {
            [void][VulkanAcceptanceNative]::SendMessage($noButton, 0x00f5, [IntPtr]::Zero, [IntPtr]::Zero)
        }
        throw "startup fallback dialog appeared: $text"
    }
    if ($Process.MainWindowHandle -eq [IntPtr]::Zero) { throw "Mostty did not create a window" }
    return $Process.MainWindowHandle
}

function Get-ActivePresentTier {
    param([string]$Diagnostic)
    $match = [regex]::Match($Diagnostic, "present tier=([a-z_]+)")
    if ($match.Success) { return $match.Groups[1].Value }
    return "not-applicable"
}

function Invoke-WindowWorkload {
    param(
        [Diagnostics.Process]$Process,
        [IntPtr]$Window,
        [string]$CaseRenderer,
        [string]$CapturePath
    )

    $style = [VulkanAcceptanceNative]::GetWindowLongPtrW($Window, -20).ToInt64()
    $noRedirection = ($style -band 0x00200000) -ne 0
    if ($CaseRenderer -in @("d3d11", "vulkan", "opengl") -and -not $noRedirection) {
        throw "$CaseRenderer did not use the DirectComposition no-redirection path"
    }
    if ($CaseRenderer -eq "native-vulkan" -and $noRedirection) {
        throw "$CaseRenderer unexpectedly used the DirectComposition no-redirection path"
    }

    $cpuStart = $Process.TotalProcessorTime.TotalMilliseconds
    $wall = [Diagnostics.Stopwatch]::StartNew()
    $command = "for /L %i in (1,1,20000) do @echo Mostty acceptance frame %i"
    foreach ($character in $command.ToCharArray()) {
        if (-not [VulkanAcceptanceNative]::PostMessageW($Window, 0x0102, [UIntPtr][int][char]$character, [IntPtr]::Zero)) {
            throw "input injection failed"
        }
    }
    [void][VulkanAcceptanceNative]::PostMessageW($Window, 0x0102, [UIntPtr]13, [IntPtr]::Zero)

    $responseSamples = [Collections.Generic.List[double]]::new()
    $sizes = @(@(900, 600), @(1200, 760), @(1000, 680), @(1344, 822))
    foreach ($size in $sizes) {
        if (-not [VulkanAcceptanceNative]::SetWindowPos($Window, [IntPtr]::Zero, 80, 60, $size[0], $size[1], 0x0014)) {
            throw "move/resize failed for $($size[0])x$($size[1])"
        }
        for ($sample = 0; $sample -lt 4; $sample++) {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $messageResult = [UIntPtr]::Zero
            if ([VulkanAcceptanceNative]::SendMessageTimeoutW($Window, 0, [UIntPtr]::Zero, [IntPtr]::Zero, 0x0002, 1000, [ref]$messageResult) -eq [IntPtr]::Zero) {
                throw "UI thread did not answer within one second"
            }
            $timer.Stop()
            $responseSamples.Add($timer.Elapsed.TotalMilliseconds)
            Start-Sleep -Milliseconds 100
        }
    }
    Start-Sleep -Seconds 2
    $Process.Refresh()
    $wall.Stop()
    $cpuMs = $Process.TotalProcessorTime.TotalMilliseconds - $cpuStart
    $cpuPercent = 100.0 * $cpuMs / ($wall.Elapsed.TotalMilliseconds * [Environment]::ProcessorCount)

    [void][VulkanAcceptanceNative]::SetWindowPos($Window, [IntPtr](-1), 80, 60, 1344, 822, 0x0050)
    Start-Sleep -Milliseconds 400
    $rect = [VulkanAcceptanceNative+RECT]::new()
    if (-not [VulkanAcceptanceNative]::GetWindowRect($Window, [ref]$rect)) { throw "window capture bounds unavailable" }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    $bitmap = [Drawing.Bitmap]::new($width, $height)
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try { $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size) } finally { $graphics.Dispose() }
        $bitmap.Save($CapturePath, [Drawing.Imaging.ImageFormat]::Png)
        $colors = [Collections.Generic.HashSet[int]]::new()
        $lit = 0
        for ($y = 0; $y -lt $height; $y += [Math]::Max(1, [int]($height / 40))) {
            for ($x = 0; $x -lt $width; $x += [Math]::Max(1, [int]($width / 60))) {
                $argb = $bitmap.GetPixel($x, $y).ToArgb()
                [void]$colors.Add($argb)
                if (($argb -band 0x00ffffff) -ne 0) { $lit++ }
            }
        }
        if ($colors.Count -lt 8 -or $lit -lt 20) { throw "captured window appears blank" }
    } finally {
        $bitmap.Dispose()
    }

    $diagnostic = Read-DiagnosticLog
    $renderStats = [regex]::Matches($diagnostic, "render stats: .*?busy ([0-9]+\.[0-9]) ms/s, max ([0-9]+) us, ([0-9]+) PTY byte\(s\)/s")
    if ($renderStats.Count -eq 0) { throw "diagnostic log contains no render statistics" }
    $busy = @($renderStats | ForEach-Object { [double]$_.Groups[1].Value })
    $renderMax = @($renderStats | ForEach-Object { [int64]$_.Groups[2].Value })
    $pty = @($renderStats | ForEach-Object { [int64]$_.Groups[3].Value })
    if (($pty | Measure-Object -Maximum).Maximum -le 0) { throw "diagnostics did not observe sustained PTY output" }
    $dpi = [VulkanAcceptanceNative]::GetDpiForWindow($Window)
    if ($dpi -eq 0) { throw "window DPI could not be observed" }

    return [ordered]@{
        ui_response_avg_ms = [Math]::Round(($responseSamples | Measure-Object -Average).Average, 3)
        ui_response_max_ms = [Math]::Round(($responseSamples | Measure-Object -Maximum).Maximum, 3)
        process_cpu_percent = [Math]::Round($cpuPercent, 3)
        render_busy_avg_ms_per_s = [Math]::Round(($busy | Measure-Object -Average).Average, 3)
        render_max_us = ($renderMax | Measure-Object -Maximum).Maximum
        pty_bytes_per_s_max = ($pty | Measure-Object -Maximum).Maximum
        dpi = $dpi
        width = $width
        height = $height
        sampled_colors = $colors.Count
        lit_samples = $lit
    }
}

function Stop-AcceptanceProcess {
    param([Diagnostics.Process]$Process, [IntPtr]$Window)
    [void][VulkanAcceptanceNative]::PostMessageW($Window, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 50
        $Process.Refresh()
        if ($Process.HasExited) { break }
        $dialog = [VulkanAcceptanceNative]::FindDialog($Process.Id)
    } while ($dialog -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if ($dialog -ne [IntPtr]::Zero) {
        $yesButton = [VulkanAcceptanceNative]::GetDlgItem($dialog, 6)
        if ($yesButton -eq [IntPtr]::Zero) { throw "close confirmation has no affirmative action" }
        [void][VulkanAcceptanceNative]::SendMessage($yesButton, 0x00f5, [IntPtr]::Zero, [IntPtr]::Zero)
    }
    if (-not $Process.WaitForExit(10000)) { throw "confirmed window close did not exit within ten seconds" }
    if ($Process.ExitCode -ne 0) { throw "Mostty exited with code $($Process.ExitCode)" }
}

function New-Result {
    param([string]$ActualSession, [string]$Scenario)
    return [ordered]@{
        schema_version = 1
        recorded_at = [DateTime]::UtcNow.ToString("o")
        session = $ActualSession
        renderer = $Renderer
        requested_present_tier = $PresentTier
        active_present_tier = "unknown"
        scenario = $Scenario
        status = "fail"
        reason = "not completed"
        metrics = $null
        screenshot = $null
    }
}

function Write-Result {
    param([Collections.IDictionary]$Result)
    New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
    $path = Get-ResultPath $Result.session $Result.renderer $Result.requested_present_tier $Result.scenario
    $Result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

function Invoke-BaselineRun {
    $actualSession = Get-ActualSession
    if ($Session -eq "all") { throw "run requires -Session local or -Session rdp" }
    if ($Session -ne $actualSession) { throw "expected $Session session, actual session is $actualSession" }
    if ($Renderer -ne "native-vulkan" -and $PresentTier -ne "auto") {
        throw "present tiers apply only to native-vulkan"
    }
    $result = New-Result $actualSession "baseline"
    $process = $null
    try {
        $process = Start-AcceptanceProcess $Renderer $PresentTier
        $window = Wait-AcceptanceWindow $process
        $capture = Join-Path $outputRoot "$actualSession-$Renderer-$PresentTier-baseline.png"
        $result.metrics = Invoke-WindowWorkload $process $window $Renderer $capture
        $diagnostic = Read-DiagnosticLog
        $result.active_present_tier = Get-ActivePresentTier $diagnostic
        if ($Renderer -eq "native-vulkan" -and $PresentTier -ne "auto" -and $result.active_present_tier -ne $PresentTier) {
            throw "requested present tier $PresentTier but activated $($result.active_present_tier)"
        }
        if ($diagnostic -match "fallback from|runtime failure|startup failed") { throw "diagnostic log reports fallback or renderer failure" }
        Stop-AcceptanceProcess $process $window
        $result.status = "pass"
        $result.reason = "all baseline observations passed"
        $result.screenshot = Split-Path $capture -Leaf
    } catch {
        $diagnostic = Read-DiagnosticLog
        $result.active_present_tier = Get-ActivePresentTier $diagnostic
        $result.reason = $_.Exception.Message
        if ($diagnostic -match "PresentTierUnavailable|WindowEffectsUnsupported|PhysicalDeviceUnavailable|SurfaceUnavailable|SwapchainCapabilitiesUnavailable") {
            $result.status = "unavailable"
        }
    } finally {
        if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id; $process.WaitForExit() }
    }
    $path = Write-Result $result
    Write-Host "$($result.status): $path - $($result.reason)"
    if ($result.status -eq "fail") { throw $result.reason }
}

function Start-RecoveryRun {
    if ($Session -ne "rdp" -or (Get-ActualSession) -ne "rdp") { throw "recovery-start must run inside the target RDP session" }
    if ($Renderer -notin @("vulkan", "native-vulkan")) { throw "recovery scenarios apply only to Vulkan renderers" }
    if ($PresentTier -ne "auto") { throw "recovery scenarios use the renderer's negotiated present tier" }
    $process = Start-AcceptanceProcess $Renderer $PresentTier
    try {
        $window = Wait-AcceptanceWindow $process
        $capture = Join-Path $outputRoot "rdp-$Renderer-auto-$RecoveryEvent-before.png"
        [void](Invoke-WindowWorkload $process $window $Renderer $capture)
        $state = [ordered]@{
            process_id = $process.Id
            renderer = $Renderer
            recovery_event = $RecoveryEvent
            diagnostic_offset = (Read-DiagnosticLog).Length
        }
        $statePath = Join-Path $outputRoot "recovery-state.json"
        $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
        Write-Host "Recovery process $($process.Id) is ready. Perform $RecoveryEvent, return to this RDP session, then run recovery-complete."
    } catch {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id; $process.WaitForExit() }
        throw
    }
}

function Complete-RecoveryRun {
    if ($Session -ne "rdp" -or (Get-ActualSession) -ne "rdp") { throw "recovery-complete must run after returning to the target RDP session" }
    $statePath = Join-Path $outputRoot "recovery-state.json"
    if (-not (Test-Path -LiteralPath $statePath)) { throw "recovery state is missing" }
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    $caseRenderer = Resolve-RecoveryRenderer $Renderer $rendererWasSpecified $state.renderer
    if ($RecoveryEvent -ne $state.recovery_event) { throw "recovery event does not match saved state" }
    $result = New-Result "rdp" $RecoveryEvent
    $result.renderer = $caseRenderer
    $process = Get-Process -Id $state.process_id -ErrorAction Stop
    try {
        $process.Refresh()
        $window = $process.MainWindowHandle
        if ($window -eq [IntPtr]::Zero) { throw "recovered Mostty window is unavailable" }
        $tail = Get-DiagnosticTail (Read-DiagnosticLog) ([int64]$state.diagnostic_offset)
        $codes = @([regex]::Matches($tail, "WTS session change event: ([0-9]+)") | ForEach-Object { [int]$_.Groups[1].Value })
        if ($RecoveryEvent -eq "reconnect") {
            if (4 -notin $codes -or 3 -notin $codes) { throw "diagnostics do not contain an RDP disconnect/reconnect pair" }
        } else {
            $hasDisconnect = ($codes | Where-Object { $_ -in @(2, 4, 7) }).Count -gt 0
            $hasConnect = ($codes | Where-Object { $_ -in @(1, 3, 8) }).Count -gt 0
            if (-not $hasDisconnect -or -not $hasConnect) { throw "diagnostics do not contain a session-switch disconnect/connect pair" }
        }
        $capture = Join-Path $outputRoot "rdp-$caseRenderer-auto-$RecoveryEvent.png"
        $result.metrics = Invoke-WindowWorkload $process $window $caseRenderer $capture
        $diagnostic = Read-DiagnosticLog
        $result.active_present_tier = Get-ActivePresentTier $diagnostic
        if ($diagnostic -match "fallback from|runtime failure|startup failed") { throw "diagnostic log reports fallback or renderer failure" }
        Stop-AcceptanceProcess $process $window
        $result.status = "pass"
        $result.reason = "renderer continued after $RecoveryEvent"
        $result.screenshot = Split-Path $capture -Leaf
    } catch {
        $result.reason = $_.Exception.Message
        if (-not $process.HasExited) { Stop-Process -Id $process.Id; $process.WaitForExit() }
    }
    Remove-Item -LiteralPath $statePath -ErrorAction SilentlyContinue
    $path = Write-Result $result
    Write-Host "$($result.status): $path - $($result.reason)"
    if ($result.status -ne "pass") { throw $result.reason }
}

function Get-AcceptanceProblems {
    param([object[]]$Results, [string]$ExpectedSession)
    $problems = [Collections.Generic.List[string]]::new()
    $sessions = if ($ExpectedSession -eq "all") { @("local", "rdp") } else { @($ExpectedSession) }
    foreach ($caseSession in $sessions) {
        foreach ($caseRenderer in @("d3d11", "opengl", "vulkan")) {
            $record = $Results | Where-Object { $_.session -eq $caseSession -and $_.renderer -eq $caseRenderer -and $_.scenario -eq "baseline" -and $_.requested_present_tier -eq "auto" } | Select-Object -Last 1
            if ($null -eq $record) { $problems.Add("missing $caseSession $caseRenderer baseline") }
            elseif ($record.status -ne "pass") { $problems.Add("$caseSession $caseRenderer baseline is $($record.status)") }
        }
        foreach ($tier in @("present_wait_mailbox", "timeline_mailbox", "fifo")) {
            $record = $Results | Where-Object { $_.session -eq $caseSession -and $_.renderer -eq "native-vulkan" -and $_.scenario -eq "baseline" -and $_.requested_present_tier -eq $tier } | Select-Object -Last 1
            if ($null -eq $record) { $problems.Add("missing $caseSession native-vulkan $tier baseline") }
            elseif ($tier -eq "fifo" -and $record.status -ne "pass") { $problems.Add("$caseSession native-vulkan fifo baseline is $($record.status)") }
            elseif ($tier -ne "fifo" -and $record.status -notin @("pass", "unavailable")) { $problems.Add("$caseSession native-vulkan $tier baseline is $($record.status)") }
        }
    }
    if ($ExpectedSession -in @("rdp", "all")) {
        foreach ($caseRenderer in @("vulkan", "native-vulkan")) {
            foreach ($scenario in @("reconnect", "session-switch")) {
                $record = $Results | Where-Object { $_.session -eq "rdp" -and $_.renderer -eq $caseRenderer -and $_.scenario -eq $scenario } | Select-Object -Last 1
                if ($null -eq $record) { $problems.Add("missing RDP $caseRenderer $scenario evidence") }
                elseif ($record.status -ne "pass") { $problems.Add("RDP $caseRenderer $scenario is $($record.status)") }
            }
        }
    }
    return $problems
}

function Write-AcceptanceReport {
    New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
    $results = @(Get-ChildItem -LiteralPath $outputRoot -Filter "*.json" | Where-Object { $_.Name -ne "recovery-state.json" } | ForEach-Object {
        Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json
    })
    $problems = @(Get-AcceptanceProblems $results $Session)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("# Vulkan acceptance evidence")
    $lines.Add("")
    $lines.Add("| Session | Renderer | Present tier | Scenario | Status | CPU % | UI max ms | Render busy ms/s | Reason |")
    $lines.Add("| --- | --- | --- | --- | --- | ---: | ---: | ---: | --- |")
    foreach ($record in $results | Sort-Object session, renderer, requested_present_tier, scenario) {
        $cpu = if ($null -ne $record.metrics) { $record.metrics.process_cpu_percent } else { "" }
        $ui = if ($null -ne $record.metrics) { $record.metrics.ui_response_max_ms } else { "" }
        $busy = if ($null -ne $record.metrics) { $record.metrics.render_busy_avg_ms_per_s } else { "" }
        $reason = $record.reason -replace "\|", "\\|"
        $lines.Add("| $($record.session) | $($record.renderer) | $($record.requested_present_tier) -> $($record.active_present_tier) | $($record.scenario) | $($record.status) | $cpu | $ui | $busy | $reason |")
    }
    $lines.Add("")
    if ($problems.Count -eq 0) {
        $lines.Add("Acceptance result: PASS")
    } else {
        $lines.Add("Acceptance result: NOT PASSING")
        foreach ($problem in $problems) { $lines.Add("- $problem") }
    }
    $reportPath = Join-Path $outputRoot "report.md"
    $lines | Set-Content -LiteralPath $reportPath -Encoding utf8
    Write-Host $reportPath
    if ($problems.Count -ne 0) { throw "acceptance report has $($problems.Count) blocking problem(s)" }
}

function Invoke-SelfTest {
    function New-TestRecord([string]$CaseSession, [string]$CaseRenderer, [string]$Tier, [string]$Scenario, [string]$Status) {
        return [pscustomobject]@{ session = $CaseSession; renderer = $CaseRenderer; requested_present_tier = $Tier; scenario = $Scenario; status = $Status }
    }
    $complete = [Collections.Generic.List[object]]::new()
    foreach ($caseSession in @("local", "rdp")) {
        foreach ($caseRenderer in @("d3d11", "opengl", "vulkan")) { $complete.Add((New-TestRecord $caseSession $caseRenderer "auto" "baseline" "pass")) }
        $complete.Add((New-TestRecord $caseSession "native-vulkan" "present_wait_mailbox" "baseline" "unavailable"))
        $complete.Add((New-TestRecord $caseSession "native-vulkan" "timeline_mailbox" "baseline" "pass"))
        $complete.Add((New-TestRecord $caseSession "native-vulkan" "fifo" "baseline" "pass"))
    }
    foreach ($caseRenderer in @("vulkan", "native-vulkan")) {
        foreach ($scenario in @("reconnect", "session-switch")) { $complete.Add((New-TestRecord "rdp" $caseRenderer "auto" $scenario "pass")) }
    }
    if ((Get-AcceptanceProblems $complete.ToArray() "all").Count -ne 0) { throw "complete evidence matrix should pass" }
    $missingRdp = @($complete | Where-Object { $_.session -ne "rdp" })
    if ((Get-AcceptanceProblems $missingRdp "all").Count -eq 0) { throw "missing RDP evidence must not pass" }
    $fallback = @($complete)
    ($fallback | Where-Object { $_.session -eq "local" -and $_.renderer -eq "vulkan" -and $_.scenario -eq "baseline" }).status = "fail"
    if ((Get-AcceptanceProblems $fallback "all").Count -eq 0) { throw "fallback/failure evidence must not pass" }
    if ((Get-DiagnosticTail "abcdef" 2) -ne "cdef") { throw "diagnostic tail should start at the saved offset" }
    if ((Get-DiagnosticTail "new-log" 100) -ne "new-log") { throw "truncated diagnostics should be read from the beginning" }
    if ((Resolve-RecoveryRenderer "d3d11" $false "native-vulkan") -ne "native-vulkan") { throw "unspecified recovery renderer should use saved state" }
    if ((Resolve-RecoveryRenderer "vulkan" $true "vulkan") -ne "vulkan") { throw "matching explicit recovery renderer should pass" }
    try {
        [void](Resolve-RecoveryRenderer "vulkan" $true "native-vulkan")
        throw "mismatched explicit recovery renderer should fail"
    } catch {
        if ($_.Exception.Message -ne "recovery renderer does not match saved state") { throw }
    }
    Write-Host "vulkan acceptance self-test: passed"
}

switch ($Action) {
    "run" { Invoke-BaselineRun }
    "recovery-start" { Start-RecoveryRun }
    "recovery-complete" { Complete-RecoveryRun }
    "report" { Write-AcceptanceReport }
    "self-test" { Invoke-SelfTest }
}
