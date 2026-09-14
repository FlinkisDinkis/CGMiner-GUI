Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ param($sender,$e) try { if($script:logBox){ $script:logBox.AppendText("Unhandled UI error: " + $e.Exception.Message + "`r`n") } } catch {} })

# Bring the GUI back to the front after the miner console starts.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class WindowFocus {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@

$script:minerProcess = $null
$script:selectedBat = $null
$script:apiPort = 4028
$script:closing = $false
$script:lastError = ""
$script:deviceCache = @()
$script:lastDeviceName = ""
$script:autoStarted = $false
$script:lastProfileRefresh = Get-Date
$script:updatingProfiles = $false
$script:lastSelectedProfile = $null
$script:lastLogSize = 0
$script:hashHistory = New-Object System.Collections.Generic.List[object]
$script:minerCards = @{}
$script:logFile = Join-Path (Split-Path -Parent $PSCommandPath) "cgminer_gui.log"

function Log([string]$Message) {
    if ($null -eq $script:logBox -or $script:logBox.IsDisposed) { return }
    $script:logBox.AppendText($Message + "`r`n")
    $script:logBox.SelectionStart = $script:logBox.TextLength
    $script:logBox.ScrollToCaret()
}

function Reset-LogSession {
    # Safely end the current GUI log session and create a fresh empty log.
    # This is intentionally non-throwing so a locked file cannot crash the GUI.
    try {
        $script:lastLogSize = 0
        if ($null -ne $script:logBox -and -not $script:logBox.IsDisposed) {
            try { $script:logBox.Clear() } catch {}
        }

        $folder = Split-Path -Parent $script:logFile
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force -ErrorAction SilentlyContinue | Out-Null
        }

        $created = $false
        for ($attempt = 0; $attempt -lt 8 -and -not $created; $attempt++) {
            try {
                if (Test-Path -LiteralPath $script:logFile) {
                    Remove-Item -LiteralPath $script:logFile -Force -ErrorAction Stop
                }
                $fs = [System.IO.File]::Open(
                    $script:logFile,
                    [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::ReadWrite
                )
                $fs.Dispose()
                $created = $true
            } catch {
                if ($attempt -lt 7) { Start-Sleep -Milliseconds 150 }
            }
        }

        if (-not $created) {
            # Do not throw. The GUI can continue even if another process still owns the file.
            try { Set-State "Log reset pending" ([System.Drawing.Color]::Goldenrod) } catch {}
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

function Refresh-LogFile {
    try {
        if (-not (Test-Path -LiteralPath $script:logFile)) { return }
        $info = Get-Item -LiteralPath $script:logFile -ErrorAction Stop
        if ($info.Length -lt $script:lastLogSize) { $script:lastLogSize = 0 }
        if ($info.Length -eq $script:lastLogSize) { return }
        $bytes = [Math]::Max(0, [int64]$script:lastLogSize)
        $fs = [System.IO.File]::Open($script:logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $fs.Seek($bytes, [System.IO.SeekOrigin]::Begin) | Out-Null
            $reader = New-Object System.IO.StreamReader($fs)
            $newText = $reader.ReadToEnd()
            $reader.Dispose()
        } finally { $fs.Dispose() }
        $script:lastLogSize = $info.Length
        if (-not [string]::IsNullOrEmpty($newText)) { Log $newText.TrimEnd("`r","`n") }
    } catch {}
}

function Set-State([string]$Text, [System.Drawing.Color]$Color) {
    if ($null -eq $script:state -or $script:state.IsDisposed) { return }
    $script:state.Text = $Text
    $script:state.ForeColor = $Color
}

function Get-Field($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-HashrateGH($Object) {
    $g = [double](Get-Field $Object "GHS 5s" 0)
    if ($g -le 0) { $g = [double](Get-Field $Object "GHS av" 0) }
    if ($g -gt 0) { return $g }

    $m = [double](Get-Field $Object "MHS 5s" 0)
    if ($m -le 0) { $m = [double](Get-Field $Object "MHS av" 0) }
    if ($m -gt 0) { return ($m / 1000.0) }

    $k = [double](Get-Field $Object "KHS 5s" 0)
    if ($k -le 0) { $k = [double](Get-Field $Object "KHS av" 0) }
    if ($k -gt 0) { return ($k / 1000000.0) }

    $h = [double](Get-Field $Object "HS 5s" 0)
    if ($h -le 0) { $h = [double](Get-Field $Object "HS av" 0) }
    if ($h -gt 0) { return ($h / 1000000000.0) }

    return 0
}

function Format-Hashrate([double]$Ghs) {
    if ($Ghs -le 0) { return "0 H/s" }
    $h = $Ghs * 1000000000.0
    if ($h -ge 1000000000000.0) { return ("{0:N2} TH/s" -f ($h / 1000000000000.0)) }
    if ($h -ge 1000000000.0) { return ("{0:N2} GH/s" -f ($h / 1000000000.0)) }
    if ($h -ge 1000000.0) { return ("{0:N2} MH/s" -f ($h / 1000000.0)) }
    if ($h -ge 1000.0) { return ("{0:N2} kH/s" -f ($h / 1000.0)) }
    return ("{0:N2} H/s" -f $h)
}

function Get-CgminerApi {
    param([string]$Command)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect("127.0.0.1", $script:apiPort, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(1200)) {
            throw "API connection timed out"
        }
        $client.EndConnect($async)

        $stream = $client.GetStream()
        $stream.ReadTimeout = 1500
        $stream.WriteTimeout = 1500

        $request = '{"command":"' + $Command + '"}'
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($request)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()

        $memory = New-Object System.IO.MemoryStream
        $buffer = New-Object byte[] 4096
        $done = $false

        while (-not $done) {
            $count = $stream.Read($buffer, 0, $buffer.Length)
            if ($count -le 0) { break }

            $nulIndex = -1
            for ($i = 0; $i -lt $count; $i++) {
                if ($buffer[$i] -eq 0) {
                    $nulIndex = $i
                    break
                }
            }

            if ($nulIndex -ge 0) {
                if ($nulIndex -gt 0) { $memory.Write($buffer, 0, $nulIndex) }
                $done = $true
            } else {
                $memory.Write($buffer, 0, $count)
            }
        }

        $text = [System.Text.Encoding]::UTF8.GetString($memory.ToArray()).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw "cgminer returned an empty API response"
        }

        try { return ($text | ConvertFrom-Json) }
        catch { throw "Invalid cgminer JSON response" }
    }
    finally {
        if ($null -ne $client) { $client.Close() }
    }
}

function Refresh-Profiles {
    try {
        $folder = Split-Path -Parent $PSCommandPath
        $guiLauncherName = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath) + ".bat"
        $files = @(Get-ChildItem -LiteralPath $folder -Filter *.bat -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -ne $guiLauncherName -and
                $_.Name -notlike "Launch_cgminer_GUI*" -and
                $_.Name -notlike "cgminer_GUI_v*"
            } |
            Sort-Object Name)
        $names = @($files | ForEach-Object { $_.Name })

        $currentNames = @($script:profileBox.Items | ForEach-Object { [string]$_ })
        $same = ($currentNames.Count -eq $names.Count)
        if($same){
            for($i=0; $i -lt $names.Count; $i++){
                if($currentNames[$i] -ne $names[$i]) { $same=$false; break }
            }
        }

        $oldName = $null
        if($script:selectedBat){ $oldName = [IO.Path]::GetFileName($script:selectedBat) }

        if(-not $same){
            $script:updatingProfiles = $true
            try {
                $script:profileBox.Items.Clear()
                foreach($name in $names){ [void]$script:profileBox.Items.Add($name) }
            } finally { $script:updatingProfiles = $false }
        }

        if($names.Count -eq 0){
            $script:selectedBat = $null
            if($script:profileBox.Items.Count -gt 0){ $script:profileBox.SelectedIndex = -1 }
            Set-State "No mining .bat files found in GUI folder" ([System.Drawing.Color]::IndianRed)
            $script:lastProfileRefresh = Get-Date
            return
        }

        $targetIndex = 0
        if($oldName -and $names -contains $oldName){ $targetIndex = [Array]::IndexOf($names,$oldName) }
        if($script:profileBox.SelectedIndex -ne $targetIndex){
            $script:updatingProfiles = $true
            try { $script:profileBox.SelectedIndex = $targetIndex } finally { $script:updatingProfiles = $false }
        }
        $script:selectedBat = Join-Path $folder $names[$targetIndex]
        $script:lastSelectedProfile = $script:selectedBat
        $script:lastProfileRefresh = Get-Date
    } catch {
        try { Set-State "Profile scan error" ([System.Drawing.Color]::IndianRed) } catch {}
    }
}

function Stop-ExistingCgminer {
    $existing = @(Get-Process -Name cgminer -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        Log "Stopping $($existing.Count) existing cgminer process(es)..."
        foreach ($process in $existing) {
            try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch {}
        }
        Start-Sleep -Milliseconds 500
    }
}

function Bring-GuiToFront {
    try {
        $form.WindowState = 'Maximized'
        $form.TopMost = $true
        $form.Activate()
        $form.BringToFront()
        [WindowFocus]::SetForegroundWindow($form.Handle) | Out-Null
        Start-Sleep -Milliseconds 120
        $form.TopMost = $false
        $form.Activate()
    } catch {}
}

function Start-Mining {
    if (-not $script:selectedBat -or -not (Test-Path -LiteralPath $script:selectedBat)) {
        [System.Windows.Forms.MessageBox]::Show(
            "No mining .bat profile is selected.",
            "No mining profile",
            "OK",
            "Warning"
        ) | Out-Null
        return
    }

    if ($script:minerProcess -and -not $script:minerProcess.HasExited) {
        return
    }

    Reset-LogSession | Out-Null

    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $env:ComSpec
        $startInfo.Arguments = '/d /c call "' + $script:selectedBat + '" > "' + $script:logFile + '" 2>&1'
        $startInfo.WorkingDirectory = Split-Path -Parent $script:selectedBat
        $startInfo.UseShellExecute = $true
        $startInfo.CreateNoWindow = $true

        $script:minerProcess = New-Object System.Diagnostics.Process
        $script:minerProcess.StartInfo = $startInfo
        [void]$script:minerProcess.Start()

        $script:stopButton.Enabled = $true
        Log "Started: $([IO.Path]::GetFileName($script:selectedBat))"
        Log "cgminer start"
        Set-State "cgminer start" ([System.Drawing.Color]::Orange)

        Start-Sleep -Milliseconds 650
        Bring-GuiToFront
    }
    catch {
        Log "Start failed: $($_.Exception.Message)"
        Set-State "Start failed" ([System.Drawing.Color]::IndianRed)
    }
}

function Stop-Mining([bool]$CloseGui = $true) {
    try {
        if ($script:minerProcess -and -not $script:minerProcess.HasExited) {
            Start-Process taskkill.exe -ArgumentList "/PID $($script:minerProcess.Id) /T /F" -Wait -PassThru -WindowStyle Hidden | Out-Null
        }
    } catch {}

    foreach ($process in @(Get-Process -Name cgminer -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
    }

    $script:minerProcess = $null
    $script:stopButton.Enabled = $false
    Reset-LogSession | Out-Null
    Log "cgminer stopped - all mining processes shut down"
    Set-State "cgminer stopped - everything shut down" ([System.Drawing.Color]::Goldenrod)

    # A normal STOP closes the GUI too. Profile switching calls this with $false so the GUI stays open.
    if ($CloseGui -and $null -ne $script:form -and -not $script:closing -and -not $script:form.IsDisposed) {
        $script:closing = $true
        $script:form.Close()
    }
}

function New-MinerCard($Device) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Width = 945
    $panel.Height = 58
    $panel.Margin = New-Object System.Windows.Forms.Padding(0,0,0,6)
    $panel.BackColor = [System.Drawing.Color]::FromArgb(28,28,34)

    $name = New-Object System.Windows.Forms.Label
    $name.Text = [string]$Device.Name
    $name.Location = New-Object System.Drawing.Point(14,10)
    $name.AutoSize = $true
    $name.Font = New-Object System.Drawing.Font("Segoe UI Semibold",11)
    $name.ForeColor = [System.Drawing.Color]::White
    $panel.Controls.Add($name)

    $quick = New-Object System.Windows.Forms.Label
    $quick.Text = ""
    $quick.Location = New-Object System.Drawing.Point(260,11)
    $quick.AutoSize = $true
    $quick.ForeColor = [System.Drawing.Color]::Silver
    $panel.Controls.Add($quick)

    $status = New-Object System.Windows.Forms.Label
    $status.Text = ""
    $status.Location = New-Object System.Drawing.Point(820,11)
    $status.AutoSize = $true
    $status.ForeColor = [System.Drawing.Color]::Silver
    $panel.Controls.Add($status)

    $panel.Tag = [pscustomobject]@{
        Name = [string]$Device.Name
        Panel = $panel
        NameLabel = $name
        QuickLabel = $quick
        StatusLabel = $status
    }
    return $panel
}

function Update-MinerCard($Panel, $DeviceModel) {
    $tag = $Panel.Tag
    $tag.Name = $DeviceModel.Name
    $tag.NameLabel.Text = [string]$DeviceModel.Name
    $tag.QuickLabel.Text = "{0}    A:{1:N0}    R:{2:N0}    HW:{3:N0}" -f (Format-Hashrate $DeviceModel.Hashrate),$DeviceModel.Accepted,$DeviceModel.Rejected,$DeviceModel.HW
    $tag.StatusLabel.Text = $DeviceModel.Status
}

function Refresh-MinerCards([array]$Devices) {
    if($null -eq $script:minerFlow){ return }
    $models = [ordered]@{}
    $fallbackIndex = 0
    $deviceList = @($Devices | Select-Object -First 25)
    foreach($device in $deviceList){
        if($null -eq $device){ continue }

        # Display the device name exactly as cgminer reports it.
        $name = [string](Get-Field $device "Name" "?")

        # Use cgminer's device ID when available so identical device names
        # remain separate while still displaying the exact cgminer Name.
        $deviceId = [string](Get-Field $device "ID" "")
        if([string]::IsNullOrWhiteSpace($deviceId)){
            $deviceId = [string](Get-Field $device "Device ID" "")
        }
        if([string]::IsNullOrWhiteSpace($deviceId)){
            $key = "name:{0}|{1}" -f $name,$fallbackIndex
        } else {
            $key = "id:{0}|{1}" -f $deviceId,$fallbackIndex
        }
        $fallbackIndex++

        $models[$key] = [pscustomobject]@{
            Name=$name
            Hashrate=(Get-HashrateGH $device)
            Accepted=[double](Get-Field $device "Accepted" 0)
            Rejected=[double](Get-Field $device "Rejected" 0)
            HW=[double](Get-Field $device "Hardware Errors" 0)
            Temp=[double](Get-Field $device "Temperature" 0)
            Status=[string](Get-Field $device "Status" "--")
        }
    }

    $script:minerFlow.SuspendLayout()
    try {
        foreach($key in @($script:minerCards.Keys)){
            if(-not $models.Contains($key)){
                $panel = $script:minerCards[$key]
                $script:minerFlow.Controls.Remove($panel)
                $panel.Dispose()
                $script:minerCards.Remove($key)
            }
        }

        $ordered = @()
        foreach($key in $models.Keys){
            if(-not $script:minerCards.ContainsKey($key)){
                $panel = New-MinerCard $models[$key]
                $script:minerCards[$key] = $panel
                [void]$script:minerFlow.Controls.Add($panel)
            }
            Update-MinerCard $script:minerCards[$key] $models[$key]
            $ordered += $script:minerCards[$key]
        }
        for($i=0;$i -lt $ordered.Count;$i++){
            $script:minerFlow.Controls.SetChildIndex($ordered[$i], $i)
        }
    } finally {
        $script:minerFlow.ResumeLayout()
    }
}

function Get-HashAverage([int]$Seconds) {
    $now = Get-Date
    $cutoff = $now.AddSeconds(-$Seconds)
    $values = @($script:hashHistory | Where-Object { $_.Time -ge $cutoff } | ForEach-Object { [double]$_.Hashrate })
    if($values.Count -eq 0){ return 0 }
    return [double](($values | Measure-Object -Average).Average)
}

function Refresh-Stats {
    if ($script:closing) { return }

    try {
        $summaryResponse = Get-CgminerApi "summary"
        $devResponse = Get-CgminerApi "devs"
        $poolResponse = Get-CgminerApi "pools"

        $summary = @($summaryResponse.SUMMARY)[0]
        $pool = @($poolResponse.POOLS)[0]
        $devices = @($devResponse.DEVS)

        $avgHash = Get-HashrateGH $summary
        $fiveSecondHash = [double](Get-Field $summary "GHS 5s" 0)
        if($fiveSecondHash -le 0){ $fiveSecondHash = $avgHash }
        $avgReported = [double](Get-Field $summary "GHS av" 0)
        if($avgReported -le 0){ $avgReported = $avgHash }

        $now = Get-Date
        [void]$script:hashHistory.Add([pscustomobject]@{Time=$now; Hashrate=$fiveSecondHash})
        $oldest = $now.AddHours(-5).AddSeconds(-2)
        while($script:hashHistory.Count -gt 0 -and $script:hashHistory[0].Time -lt $oldest){ $script:hashHistory.RemoveAt(0) }

        $script:avgHashLabel.Text = Format-Hashrate $avgReported
        $script:fiveSecLabel.Text = Format-Hashrate $fiveSecondHash

        $fiveMinSamples = @($script:hashHistory | Where-Object { $_.Time -ge $now.AddSeconds(-300) })
        $fiveHourSamples = @($script:hashHistory | Where-Object { $_.Time -ge $now.AddSeconds(-18000) })
        $fiveMinValue = if($fiveMinSamples.Count -gt 0){ [double](($fiveMinSamples.Hashrate | Measure-Object -Average).Average) } else { 0 }
        $fiveHourValue = if($fiveHourSamples.Count -gt 0){ [double](($fiveHourSamples.Hashrate | Measure-Object -Average).Average) } else { 0 }
        $script:fiveMinLabel.Text = if($fiveMinSamples.Count -lt 5){ "Warming..." } else { Format-Hashrate $fiveMinValue }
        $script:fiveHourLabel.Text = if($fiveHourSamples.Count -lt 60){ "Warming..." } else { Format-Hashrate $fiveHourValue }
        $script:acceptedLabel.Text = "{0:N0}" -f [double](Get-Field $summary "Accepted" 0)
        $script:rejectedLabel.Text = "{0:N0}" -f [double](Get-Field $summary "Rejected" 0)
        $script:hwLabel.Text = "{0:N0}" -f [double](Get-Field $summary "Hardware Errors" 0)
        $script:utilityLabel.Text = "{0:N2}" -f [double](Get-Field $summary "Utility" 0)
        $script:bestShareLabel.Text = [string](Get-Field $summary "Best Share" "0")

        $elapsed = [double](Get-Field $summary "Elapsed" 0)
        if($elapsed -gt 0){ $script:uptimeLabel.Text = ([TimeSpan]::FromSeconds($elapsed)).ToString("dd\.hh\:mm\:ss") } else { $script:uptimeLabel.Text = "--" }
        $script:poolLabel.Text = "$(Get-Field $pool 'Status' '--')  $(Get-Field $pool 'URL' '--')"

        Refresh-MinerCards $devices
        $script:lastError = ""
        Set-State "cgminer API connected" ([System.Drawing.Color]::FromArgb(70,190,100))
    }
    catch {
        if($script:closing){ return }
        $message=$_.Exception.Message
        if($message -ne $script:lastError){ Log "API: $message"; $script:lastError=$message }
        if($script:minerProcess -and -not $script:minerProcess.HasExited){ Set-State "Mining process running - API offline" ([System.Drawing.Color]::Orange) }
        else { Set-State "cgminer API offline" ([System.Drawing.Color]::IndianRed) }
    }
}

# -------------------- UI --------------------
$form = New-Object System.Windows.Forms.Form
$script:form = $form
$form.Text = "cgminer GUI v8.0"
$form.StartPosition = "CenterScreen"
$form.WindowState = "Maximized"
$form.MinimumSize = New-Object System.Drawing.Size(900,650)
$form.BackColor = [System.Drawing.Color]::FromArgb(18,18,22)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font("Segoe UI",10)
$form.KeyPreview = $true
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $true
$form.MinimizeBox = $true

# Header
$header = New-Object System.Windows.Forms.Panel
$header.Dock = "Top"
$header.Height = 78
$header.Padding = New-Object System.Windows.Forms.Padding(24,10,24,8)
$header.BackColor = [System.Drawing.Color]::FromArgb(18,18,22)
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = "CGMINER"
$title.Font = New-Object System.Drawing.Font("Segoe UI Semibold",22)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(24,10)
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "v8.0  -  cgminer GUI"
$subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(27,47)
$subtitle.ForeColor = [System.Drawing.Color]::Silver
$header.Controls.Add($subtitle)

# Profile bar
$profilePanel = New-Object System.Windows.Forms.GroupBox
$profilePanel.Text = "Mining Profile"
$profilePanel.Dock = "Top"
$profilePanel.Height = 82
$profilePanel.Padding = New-Object System.Windows.Forms.Padding(12,10,12,8)
$form.Controls.Add($profilePanel)
$form.Controls.SetChildIndex($profilePanel,0)

$profileText = New-Object System.Windows.Forms.Label
$profileText.Text = "BAT file:"
$profileText.Location = New-Object System.Drawing.Point(16,24)
$profileText.AutoSize = $true
$profilePanel.Controls.Add($profileText)

$script:profileBox = New-Object System.Windows.Forms.ComboBox
$profileBox.DropDownStyle = "DropDownList"
$profileBox.BackColor = $form.BackColor
$profileBox.ForeColor = [System.Drawing.Color]::Gainsboro
$profileBox.FlatStyle = "Flat"
$profileBox.Location = New-Object System.Drawing.Point(82,20)
$profileBox.Anchor = "Top,Left"
$profileBox.Width = 450
$profileBox.Height = 24
$profilePanel.Controls.Add($profileBox)

$script:stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = "STOP"
$stopButton.Location = New-Object System.Drawing.Point(548,18)
$stopButton.Size = New-Object System.Drawing.Size(90,28)
$stopButton.Anchor = "Top,Left"
$stopButton.Enabled = $false
$stopButton.TabStop = $false
$profilePanel.Controls.Add($stopButton)

$script:state = New-Object System.Windows.Forms.Label
$state.Text = "Starting..."
$state.Location = New-Object System.Drawing.Point(16,52)
$state.AutoSize = $true
$state.ForeColor = [System.Drawing.Color]::Goldenrod
$profilePanel.Controls.Add($state)

# Stats strip
$statsFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$statsFlow.Dock = "Top"
$statsFlow.Height = 106
$statsFlow.Padding = New-Object System.Windows.Forms.Padding(20,8,20,8)
$statsFlow.WrapContents = $false
$statsFlow.AutoScroll = $true
$statsFlow.BackColor = [System.Drawing.Color]::FromArgb(18,18,22)
$form.Controls.Add($statsFlow)
$form.Controls.SetChildIndex($statsFlow,0)

foreach ($caption in @("Avg Hash","5 Sec Hash","5 Min Hash","5 Hour Hash","Accepted","Rejected","HW Errors","Utility","Uptime","Best Share")) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Width = 170
    $panel.Height = 84
    $panel.Margin = New-Object System.Windows.Forms.Padding(4)
    $panel.BackColor = [System.Drawing.Color]::FromArgb(28,28,34)
    $statsFlow.Controls.Add($panel)

    $cap = New-Object System.Windows.Forms.Label
    $cap.Text = $caption
    $cap.Location = New-Object System.Drawing.Point(12,8)
    $cap.AutoSize = $true
    $cap.ForeColor = [System.Drawing.Color]::Silver
    $panel.Controls.Add($cap)

    $val = New-Object System.Windows.Forms.Label
    $val.Text = "--"
    $val.Location = New-Object System.Drawing.Point(12,34)
    $val.AutoSize = $true
    $val.Font = New-Object System.Drawing.Font("Segoe UI Semibold",16)
    $panel.Controls.Add($val)

    switch ($caption) {
        "Avg Hash"    { $script:avgHashLabel = $val }
        "5 Sec Hash"  { $script:fiveSecLabel = $val }
        "5 Min Hash"  { $script:fiveMinLabel = $val }
        "5 Hour Hash" { $script:fiveHourLabel = $val }
        "Accepted"  { $script:acceptedLabel = $val }
        "Rejected"  { $script:rejectedLabel = $val }
        "HW Errors" { $script:hwLabel = $val }
        "Utility"   { $script:utilityLabel = $val }
        "Uptime"    { $script:uptimeLabel = $val }
        "Best Share" { $script:bestShareLabel = $val }
    }
}

# Pool panel
$poolPanel = New-Object System.Windows.Forms.GroupBox
$poolPanel.Text = "Current Pool"
$poolPanel.Dock = "Top"
$poolPanel.Height = 58
$poolPanel.Padding = New-Object System.Windows.Forms.Padding(12,8,12,8)
$form.Controls.Add($poolPanel)
$form.Controls.SetChildIndex($poolPanel,0)

$script:poolLabel = New-Object System.Windows.Forms.Label
$poolLabel.Text = "--"
$poolLabel.Dock = "Fill"
$poolLabel.AutoEllipsis = $true
$poolPanel.Controls.Add($poolLabel)

# Resizable miners + logs split.
$mainSplit = New-Object System.Windows.Forms.SplitContainer
$mainSplit.Dock = "Fill"
$mainSplit.Orientation = "Horizontal"
$mainSplit.SplitterWidth = 7
$mainSplit.IsSplitterFixed = $false
$mainSplit.Panel1MinSize = 170
$mainSplit.Panel2MinSize = 110
$form.Controls.Add($mainSplit)
$form.Controls.SetChildIndex($mainSplit,0)

$devicePanel = New-Object System.Windows.Forms.GroupBox
$devicePanel.Text = "Miners"
$devicePanel.Dock = "Fill"
$devicePanel.Padding = New-Object System.Windows.Forms.Padding(12,8,12,8)
$mainSplit.Panel1.Controls.Add($devicePanel)

$script:minerFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$minerFlow.Dock = "Fill"
$minerFlow.FlowDirection = "TopDown"
$minerFlow.WrapContents = $false
$minerFlow.AutoScroll = $true
$minerFlow.Padding = New-Object System.Windows.Forms.Padding(2,2,8,2)
$minerFlow.BackColor = [System.Drawing.Color]::FromArgb(20,20,24)
$devicePanel.Controls.Add($minerFlow)

$activityPanel = New-Object System.Windows.Forms.GroupBox
$activityPanel.Text = "Activity (drag the divider above to resize)"
$activityPanel.Dock = "Fill"
$activityPanel.Padding = New-Object System.Windows.Forms.Padding(12,8,12,8)
$mainSplit.Panel2.Controls.Add($activityPanel)

$script:logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = "Both"
$logBox.WordWrap = $false
$logBox.Dock = "Fill"
$logBox.BackColor = [System.Drawing.Color]::FromArgb(10,10,12)
$logBox.ForeColor = [System.Drawing.Color]::LightGray
$logBox.Font = New-Object System.Drawing.Font("Consolas",9)
$activityPanel.Controls.Add($logBox)

# Events
$profileBox.Add_SelectedIndexChanged({
    try {
        if ($script:updatingProfiles) { return }
        if (-not $profileBox.SelectedItem) { return }

        $folder = Split-Path -Parent $PSCommandPath
        $newBat = Join-Path $folder ([string]$profileBox.SelectedItem)
        $changed = ($script:selectedBat -ne $newBat)
        if (-not $changed) { return }

        $script:selectedBat = $newBat
        $selectedName = [IO.Path]::GetFileName($script:selectedBat)
        Log "Profile changed: $selectedName"
        Set-State "Switching to $selectedName..." ([System.Drawing.Color]::Silver)

        # Defer the stop/start work until the selection event has fully returned.
        # This keeps the WinForms message loop responsive and prevents the API timer
        # and GUI from being disrupted by synchronous process control.
        $null = $form.BeginInvoke([Action]{
            try {
                if ($script:closing) { return }
                if ($script:minerProcess -and -not $script:minerProcess.HasExited) {
                    Stop-Mining $false
                } else {
                    Reset-LogSession | Out-Null
                }
                if (-not $script:closing -and $script:selectedBat) {
                    Start-Mining
                }
            } catch {
                try {
                    Log "Profile switch failed: $($_.Exception.Message)"
                    Set-State "Profile switch failed" ([System.Drawing.Color]::IndianRed)
                } catch {}
            }
        })
    } catch {
        try { Log "Profile selector error: $($_.Exception.Message)" } catch {}
    }
})

$stopButton.Add_Click({
    try { Stop-Mining } catch { Log "Stop handler: $($_.Exception.Message)" }
})


# Refresh timer
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    if ($script:closing) { return }
    try {
        Refresh-LogFile
        Refresh-Stats
        if (((Get-Date) - $script:lastProfileRefresh).TotalSeconds -ge 10) {
            Refresh-Profiles
        }
    } catch {
        try {
            Log "Refresh error: $($_.Exception.Message)"
            Set-State "GUI refresh error" ([System.Drawing.Color]::IndianRed)
        } catch {}
    }
})
$timer.Start()

$form.Add_Shown({
    try {
        $available = $mainSplit.ClientSize.Height
        $min1 = $mainSplit.Panel1MinSize
        $min2 = $mainSplit.Panel2MinSize
        $target = 300
        $max = $available - $min2
        if ($max -lt $min1) { $target = $min1 } else { $target = [Math]::Min($target, $max) }
        $mainSplit.SplitterDistance = [Math]::Max($min1, $target)
    } catch {}
    try {
        Refresh-Profiles
        try {
            if (Test-Path -LiteralPath $script:logFile) { Remove-Item -LiteralPath $script:logFile -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType File -Path $script:logFile -Force | Out-Null
        } catch {}
        $script:lastLogSize = 0
        Log "v8.0 ready. Mining profile is selected automatically from this folder."
        if (-not $script:autoStarted -and $script:selectedBat) {
            $script:autoStarted = $true
            Start-Mining
        } else {
            Refresh-Stats
        }
    } catch {
        try { Log "Startup error: $($_.Exception.Message)" } catch {}
    }
})

$form.Add_FormClosing({
    $script:closing = $true
    try { $timer.Stop(); $timer.Dispose() } catch {}
    try {
        if ($script:minerProcess -and -not $script:minerProcess.HasExited) {
            Start-Process taskkill.exe -ArgumentList "/PID $($script:minerProcess.Id) /T /F" -Wait -PassThru -WindowStyle Hidden | Out-Null
        }
    } catch {}
    foreach ($process in @(Get-Process -Name cgminer -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    try { if (Test-Path -LiteralPath $script:logFile) { Remove-Item -LiteralPath $script:logFile -Force -ErrorAction SilentlyContinue } } catch {}
})

[void]$form.ShowDialog()
