
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ("TrayNativeMethods" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class TrayNativeMethods {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
"@
}

$baseDir = $PSScriptRoot
$statusFile = Join-Path $baseDir "tray-status.txt"

$script:trayStatus = "idle"
$script:icons = @{}

function New-StatusIcon([System.Drawing.Color]$color) {
    $bitmap = New-Object System.Drawing.Bitmap(32, 32)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $brush = New-Object System.Drawing.SolidBrush($color)
    $handle = [IntPtr]::Zero

    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.FillEllipse($brush, 5, 5, 22, 22)

        $handle = $bitmap.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($handle).Clone()
        return ,([System.Drawing.Icon]$icon)
    } finally {
        $brush.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()

        if ($handle -ne [IntPtr]::Zero) {
            [void][TrayNativeMethods]::DestroyIcon($handle)
        }
    }
}

$script:icons["uploading"] = New-StatusIcon ([System.Drawing.Color]::LimeGreen)
$script:icons["idle"]      = New-StatusIcon ([System.Drawing.Color]::Gray)
$script:icons["error"]     = New-StatusIcon ([System.Drawing.Color]::Tomato)

# Prevent duplicate tray icons when setup or Startup launches more than once.
$script:trayMutex = New-Object System.Threading.Mutex($false, "Local\PhotoRelayTray")
$script:ownsTrayMutex = $false
try {
    $script:ownsTrayMutex = $script:trayMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $script:ownsTrayMutex = $true
}
if (-not $script:ownsTrayMutex) {
    foreach ($icon in $script:icons.Values) { $icon.Dispose() }
    $script:trayMutex.Dispose()
    return
}

$script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:notifyIcon.Icon = $script:icons["idle"]
$script:notifyIcon.Text = "PhotoRelay: Idle"
$script:notifyIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$showItem = $menu.Items.Add("Show upload status")
$exitItem = $menu.Items.Add("Exit tray")

$showItem.add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        "PhotoRelay uploader status: $script:trayStatus",
        "PhotoRelay",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
})

$exitItem.add_Click({
    $script:timer.Stop()
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$script:notifyIcon.ContextMenuStrip = $menu

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 1000

$script:timer.add_Tick({
    $newStatus = "idle"

    try {
        if (Test-Path -LiteralPath $statusFile) {
            $value = (Get-Content -LiteralPath $statusFile -Raw -ErrorAction Stop).Trim().ToLowerInvariant()

            if ($value -in @("uploading", "idle", "error")) {
                $newStatus = $value
            }
        }
    } catch {
        $newStatus = "error"
    }

    $script:trayStatus = $newStatus
    $script:notifyIcon.Icon = $script:icons[$newStatus]

    switch ($newStatus) {
        "uploading" { $script:notifyIcon.Text = "PhotoRelay: Uploading" }
        "error"     { $script:notifyIcon.Text = "PhotoRelay: Upload error" }
        default     { $script:notifyIcon.Text = "PhotoRelay: Idle" }
    }
})

try {
    $script:timer.Start()
    [System.Windows.Forms.Application]::Run()
} finally {
    $script:timer.Stop()
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
    $script:timer.Dispose()
    $menu.Dispose()

    foreach ($icon in $script:icons.Values) {
        $icon.Dispose()
    }
    if ($script:ownsTrayMutex) {
        try { $script:trayMutex.ReleaseMutex() } catch {}
    }
    $script:trayMutex.Dispose()
}
