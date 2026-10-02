# SoftwareDimmer.ps1 — optimized emergency software dimmer
# Launch: double-click SoftwareDimmer.exe (same folder; no console). Do not delete .ps1/.ico.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- DPI awareness (must run before ANY window/handle is created) ----------
# Without this, mixed-DPI multi-monitor setups can make SystemInformation.VirtualScreen
# disagree with actual physical pixels, so the dim overlay doesn't fully cover every monitor.
if (-not ('SoftDim.Dpi' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace SoftDim {
    public static class Dpi {
        [DllImport("user32.dll")]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        public static readonly IntPtr PER_MONITOR_AWARE_V2 = new IntPtr(-4);
    }
}
"@
}
try { [void][SoftDim.Dpi]::SetProcessDpiAwarenessContext([SoftDim.Dpi]::PER_MONITOR_AWARE_V2) } catch {}

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ---------- paths / settings ----------
# Moved here (was originally after the single-instance check) so Write-DimLog
# is available in time to log a failure from the mutex creation below.
$script:selfPath = $PSCommandPath
if (-not $script:selfPath) { $script:selfPath = $MyInvocation.MyCommand.Path }
$script:cfgDir  = Join-Path $env:APPDATA 'SoftwareDimmer'
$script:cfgPath = Join-Path $script:cfgDir 'settings.json'
$script:logPath = Join-Path $script:cfgDir 'error.log'
if (-not (Test-Path $script:cfgDir)) { New-Item -ItemType Directory -Path $script:cfgDir -Force | Out-Null }

# Best-effort diagnostic trail for the try{}catch{} paths that swallow errors
# on purpose (they must not crash the UI thread) — previously those failures
# left zero trace, so a long-running instance behaving oddly gave no clue why.
# Capped so a repeating failure (e.g. every 4s timer tick) can't grow unbounded.
function Write-DimLog {
    param([string]$Message)
    try {
        if ((Test-Path -LiteralPath $script:logPath) -and
            (Get-Item -LiteralPath $script:logPath).Length -gt 512KB) {
            Remove-Item -LiteralPath $script:logPath -Force -ErrorAction SilentlyContinue
        }
        $line = "[{0}] {1}" -f (Get-Date).ToString('s'), $Message
        Add-Content -LiteralPath $script:logPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

# ---------- IPC: 再次启动 → 让已运行实例弹出主窗口 ----------
# 旧行为：进程已在运行时再点图标，只会弹一个"已在运行"提示框然后退出。
# 现在：本实例通过命名管道向已运行实例发一个 show 信号，由对方在自己的
# UI 线程上把主窗口弹出来。服务端跑在后台线程，绝不在 UI 线程上阻塞。
# 第二次启动走的也是同一份脚本，所以要在这里（单实例锁判断之前）就把
# 管道客户端的类型定义好——锁判断里要调用它。
if (-not ('SoftDim.Ipc' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.IO.Pipes;
using System.Threading;

namespace SoftDim {
    public static class Ipc {
        public const string PipeName = "SoftwareDimmer_SoftDim_v2_show";
        // 后台管道线程只允许写这个标志（volatile 保证 UI 线程读到最新值）。
        // 真正的弹窗动作由 UI 线程上的轻量轮询定时器执行——PowerShell 脚本块
        // 不能在没有任何 runspace 的裸 .NET 线程上运行（会抛
        // PSInvalidOperationException），所以这里绝不做任何 PowerShell 调用，
        // 只置位一个 bool。
        public static volatile bool ShowPending;

        public static void StartServer() {
            Thread t = new Thread(ServerLoop);
            t.IsBackground = true;
            t.Name = "SoftDim.ShowPipe";
            t.Start();
        }

        private static void ServerLoop() {
            while (true) {
                try {
                    // 单实例常驻 + Disconnect 后继续 WaitForConnection 的标准用法。
                    // 不要每个连接销毁再重建同名管道：Windows 上"上一个客户端端点
                    // 尚未回收就创建同名实例"会一直失败（跨进程客户端时尤其明显），
                    // 服务端会卡在无限重试里、再也收不到后续信号。
                    using (var pipe = new NamedPipeServerStream(
                        PipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.None)) {
                        while (true) {
                            pipe.WaitForConnection();
                            try {
                                var b = new byte[1];
                                pipe.Read(b, 0, 1);
                            } catch {}
                            ShowPending = true;
                            try { pipe.Disconnect(); } catch {}
                        }
                    }
                } catch {
                    // 管道实例故障/初始化失败（例如旧客户端端点尚未回收）——稍后重建重试
                    Thread.Sleep(200);
                }
            }
        }

        // 成功则返回 true（信号已交给已运行实例）；服务端未就绪则返回 false
        public static bool SignalShow() {
            try {
                using (var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.Out)) {
                    pipe.Connect(600);
                    pipe.WriteByte(1);
                    pipe.Flush();
                    return true;
                }
            } catch {
                return false;
            }
        }
    }
}
"@
}

# ---------- single instance ----------
$script:mutex = $null
try {
    $script:mutex = New-Object System.Threading.Mutex($false, 'Local\SoftwareDimmer_SoftDim_v2')
    if (-not $script:mutex.WaitOne(0)) {
        # 已在运行：发 show 信号让已运行实例弹出主窗口，而不是弹"已在运行"提示框。
        # 服务端在实例拿到锁后立刻启动（见下方），通常第一次就连上；短重试覆盖
        # 两种窗口期：①对方服务端还没开始监听（启动初期），②Restart 时旧实例
        # 已释放锁但同名管道尚未销毁。
        $signaled = $false
        for ($i = 0; $i -lt 4 -and -not $signaled; $i++) {
            try { $signaled = [SoftDim.Ipc]::SignalShow() } catch { $signaled = $false }
            if (-not $signaled) { Start-Sleep -Milliseconds 400 }
        }
        if (-not $signaled) {
            [System.Windows.Forms.MessageBox]::Show(
                "Software Dimmer 已在运行中。`n请查看系统托盘图标。",
                "Software Dimmer",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
        exit 0
    }
} catch {
    # Previously silently swallowed: if Mutex creation itself throws (rare —
    # e.g. permissions), single-instance protection was skipped with zero
    # trace, so "why are there two instances running" was unanswerable.
    Write-DimLog "Single-instance mutex creation failed: $($_.Exception.Message)"
}

# 拿到锁（或加锁失败）后立即启动 show 信号服务端，尽量缩短"已持锁但服务端未
# 就绪"的窗口期。服务端只把 ShowPending 置位（后台线程写一个 bool，安全且不
# 需要 runspace），真正的弹窗由 UI 线程上的轻量轮询定时器消费（见脚本末尾）。
# 极早期到达的信号（定时器还没启动）由 Add_Shown 兜底弹出。
[SoftDim.Ipc]::StartServer()

if (-not ('SoftDim.Native' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace SoftDim {
    public delegate void WinEventDelegate(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);
    public static class Native {
        public const int GWL_EXSTYLE = -20;
        public const int WS_EX_LAYERED = 0x80000;
        public const int WS_EX_TRANSPARENT = 0x20;
        public const int WS_EX_TOOLWINDOW = 0x80;
        public const int WS_EX_NOACTIVATE = 0x08000000;
        public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
        public const uint SWP_NOMOVE = 0x0002;
        public const uint SWP_NOSIZE = 0x0001;
        public const uint SWP_NOACTIVATE = 0x0010;
        public const uint SWP_SHOWWINDOW = 0x0040;
        public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

        [DllImport("user32.dll", SetLastError = true)]
        public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
        [DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr hIcon);
        [DllImport("user32.dll")]
        public static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc, WinEventDelegate lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);
        [DllImport("user32.dll")]
        public static extern bool UnhookWinEvent(IntPtr hWinEventHook);
    }

    // Full-desktop dim (covers Start menu / IME); used instead of topmost overlay when available.
    [StructLayout(LayoutKind.Sequential)]
    public struct MagColorEffect {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 25)]
        public float[] transform;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct GammaRamp {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
        public ushort[] Red;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
        public ushort[] Green;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
        public ushort[] Blue;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DisplayDevice {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceKey;
    }

    public static class ScreenFx {
        const int DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 0x1;

        [DllImport("Magnification.dll")] public static extern bool MagInitialize();
        [DllImport("Magnification.dll")] public static extern bool MagUninitialize();
        [DllImport("Magnification.dll")] public static extern bool MagSetFullscreenTransform(float magLevel, int xOffset, int yOffset);
        [DllImport("Magnification.dll")] public static extern bool MagSetFullscreenColorEffect(ref MagColorEffect pEffect);

        [DllImport("gdi32.dll")] public static extern bool SetDeviceGammaRamp(IntPtr hDC, ref GammaRamp lpRamp);
        [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
        [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr CreateDC(string lpszDriver, string lpszDevice, string lpszOutput, IntPtr lpInitData);
        [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DisplayDevice lpDisplayDevice, uint dwFlags);

        static bool _magReady;
        static bool _magFailed;

        public static bool EnsureMag() {
            if (_magReady) return true;
            if (_magFailed) return false;
            try {
                if (!MagInitialize()) { _magFailed = true; return false; }
                MagSetFullscreenTransform(1.0f, 0, 0);
                _magReady = true;
                return true;
            } catch { _magFailed = true; return false; }
        }

        static MagColorEffect BuildMag(float scale) {
            if (scale < 0.05f) scale = 0.05f;
            if (scale > 1f) scale = 1f;
            var e = new MagColorEffect();
            e.transform = new float[25];
            e.transform[0] = scale; e.transform[6] = scale; e.transform[12] = scale;
            e.transform[18] = 1f; e.transform[24] = 1f;
            return e;
        }

        public static bool SetMag(float scale) {
            if (!EnsureMag()) return false;
            try {
                MagSetFullscreenTransform(1.0f, 0, 0);
                var e = BuildMag(scale);
                return MagSetFullscreenColorEffect(ref e);
            } catch { return false; }
        }

        public static void ResetMag() {
            if (!_magReady) return;
            try {
                var e = BuildMag(1f);
                MagSetFullscreenColorEffect(ref e);
                MagSetFullscreenTransform(1.0f, 0, 0);
            } catch {}
        }

        public static void ShutdownMag() {
            if (!_magReady) return;
            try { ResetMag(); MagUninitialize(); } catch {}
            _magReady = false;
        }

        static GammaRamp BuildRamp(float scale) {
            if (scale < 0.08f) scale = 0.08f;
            if (scale > 1f) scale = 1f;
            var r = new GammaRamp();
            r.Red = new ushort[256]; r.Green = new ushort[256]; r.Blue = new ushort[256];
            for (int i = 0; i < 256; i++) {
                // 257 (not 256) so i=255 maps to exactly 65535 at scale=1.0
                // (0xFF * 257 = 0xFFFF); 256 undershot full-white by ~0.4%.
                int v = (int)(i * 257 * scale);
                if (v < 0) v = 0; if (v > 65535) v = 65535;
                ushort u = (ushort)v;
                r.Red[i] = u; r.Green[i] = u; r.Blue[i] = u;
            }
            return r;
        }

        public static bool SetGamma(float scale) {
            try {
                var ramp = BuildRamp(scale);
                bool any = false;
                // primary virtual screen
                IntPtr hdcScreen = GetDC(IntPtr.Zero);
                if (hdcScreen != IntPtr.Zero) {
                    if (SetDeviceGammaRamp(hdcScreen, ref ramp)) any = true;
                    ReleaseDC(IntPtr.Zero, hdcScreen);
                }
                // each attached display device
                var dd = new DisplayDevice();
                dd.cb = Marshal.SizeOf(typeof(DisplayDevice));
                for (uint i = 0; EnumDisplayDevices(null, i, ref dd, 0); i++) {
                    if ((dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) == 0) continue;
                    IntPtr hdc = CreateDC("DISPLAY", dd.DeviceName, null, IntPtr.Zero);
                    if (hdc == IntPtr.Zero) continue;
                    try {
                        if (SetDeviceGammaRamp(hdc, ref ramp)) any = true;
                    } finally { DeleteDC(hdc); }
                    dd.cb = Marshal.SizeOf(typeof(DisplayDevice));
                }
                return any;
            } catch { return false; }
        }

        public static void ResetGamma() {
            try { SetGamma(1f); } catch {}
        }

        public static void ShutdownAll() {
            try { ResetGamma(); } catch {}
            try { ShutdownMag(); } catch {}
        }
    }
}
"@
}

# ClientSize floors must match $script:ui.MinimumSize (outer frame is larger than client)
$script:minClientW = 500
$script:minClientH = 520

function Normalize-DimMode([string]$Mode) {
    switch -Regex ($Mode) {
        '^(?i)mag'     { return 'Mag' }
        '^(?i)gamma'   { return 'Gamma' }
        '^(?i)overlay|遮罩' { return 'Overlay' }
        default        { return 'Mag' }
    }
}

function Get-DimSettings {
    $defaults = @{
        Brightness         = 70
        CloseToTray        = $true
        AlwaysOnTop        = $true
        MaxOpacity         = 0.88
        WindowWidth        = $script:minClientW
        WindowHeight       = $script:minClientH
        RangeModeExtreme   = $false
        DimMode            = 'Mag'
    }
    try {
        if (Test-Path $script:cfgPath) {
            $j = Get-Content -LiteralPath $script:cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            # allow Brightness=0 (0 is falsy in PowerShell)
            if ($null -ne $j.Brightness) { $defaults.Brightness = [int]$j.Brightness }
            if ($null -ne $j.CloseToTray) { $defaults.CloseToTray = [bool]$j.CloseToTray }
            if ($null -ne $j.AlwaysOnTop) { $defaults.AlwaysOnTop = [bool]$j.AlwaysOnTop }
            # allow MaxOpacity=0 (0 is falsy in PowerShell), same fix as Brightness above
            if ($null -ne $j.MaxOpacity) { $defaults.MaxOpacity = [double]$j.MaxOpacity }
            if ($j.WindowWidth -and [int]$j.WindowWidth -ge $script:minClientW)  { $defaults.WindowWidth  = [int]$j.WindowWidth }
            if ($j.WindowHeight -and [int]$j.WindowHeight -ge $script:minClientH) { $defaults.WindowHeight = [int]$j.WindowHeight }
            if ($null -ne $j.RangeModeExtreme) { $defaults.RangeModeExtreme = [bool]$j.RangeModeExtreme }
            if ($j.DimMode) { $defaults.DimMode = Normalize-DimMode ([string]$j.DimMode) }
        }
    } catch {}
    if ($defaults.Brightness -lt 0) { $defaults.Brightness = 0 }
    if ($defaults.Brightness -gt 100) { $defaults.Brightness = 100 }
    return $defaults
}

function Save-DimSettings {
    param([int]$Brightness, [bool]$CloseToTray, [bool]$AlwaysOnTop)
    try {
        $ww = $script:minClientW; $wh = $script:minClientH
        if ($script:ui -and -not $script:ui.IsDisposed -and $script:ui.WindowState -eq 'Normal') {
            $ww = [Math]::Max($script:minClientW, $script:ui.ClientSize.Width)
            $wh = [Math]::Max($script:minClientH, $script:ui.ClientSize.Height)
            # keep in-memory settings in sync so maximize/minimize saves don't
            # overwrite disk with the stale size loaded at startup
            if ($script:settings) {
                $script:settings.WindowWidth  = $ww
                $script:settings.WindowHeight = $wh
            }
        } elseif ($script:settings) {
            if ($script:settings.WindowWidth)  { $ww = [int]$script:settings.WindowWidth }
            if ($script:settings.WindowHeight) { $wh = [int]$script:settings.WindowHeight }
        }
        $obj = [ordered]@{
            Brightness       = $Brightness
            CloseToTray      = $CloseToTray
            AlwaysOnTop      = $AlwaysOnTop
            MaxOpacity       = $script:maxOpacity
            WindowWidth      = $ww
            WindowHeight     = $wh
            RangeModeExtreme = [bool]$script:rangeModeExtreme
            DimMode          = [string]$script:dimMode
            SavedAt          = (Get-Date).ToString('s')
        }
        ($obj | ConvertTo-Json) | Set-Content -LiteralPath $script:cfgPath -Encoding UTF8
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "保存设置失败：`n$($_.Exception.Message)",
            "Software Dimmer — 保存出错",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

$script:settings   = Get-DimSettings
$script:rangeModeExtreme = [bool]$script:settings.RangeModeExtreme
$script:dimMode    = Normalize-DimMode ([string]$script:settings.DimMode)
$script:dimModeActive = $null   # engine actually applied (may differ from preference on fallback)
$script:maxOpacity = [double]$script:settings.MaxOpacity
$script:lastHwOk   = $null
$script:hwTimerSec = [datetime]::UtcNow
$script:exiting    = $false
$script:iconHandle = [IntPtr]::Zero
$script:cimSession = $null
$script:powerCfgAsync = $null   # in-flight powercfg helper (BeginInvoke)
$script:lastReassertUtc     = [datetime]::MinValue
$script:reassertMinMs       = 180   # coalesce WinEvent storms
$script:reassertQueued      = $false
$script:reassertPendingKind = $null
$script:reassertTimer       = $null

# Throttle for the actual dim ENGINE call (Mag/Gamma/Overlay syscalls + tray
# tooltip). MagSetFullscreenColorEffect / SetDeviceGammaRamp are real
# driver/DWM round-trips — each one can cost a few ms. A fast fader drag can
# raise MouseMove (and therefore ValueChanged) at well over 100/sec, so
# calling the engine on every single one of those events is what causes the
# stutter. The label text + fader handle redraw stay instant (pure in-process
# GDI, effectively free); only the expensive backend call is capped to
# ~50/sec, with a trailing timer so the final value is never dropped.
$script:lastDimApplyUtc      = [datetime]::MinValue
$script:dimApplyMinMs        = 20
$script:dimApplyQueued       = $false
$script:dimApplyPendingPct   = $null
$script:dimApplyTimer        = $null

# ---------- palette (instrument-panel theme) ----------
$bg      = [System.Drawing.Color]::FromArgb(18, 17, 16)
$card    = [System.Drawing.Color]::FromArgb(23, 22, 20)
$panel   = [System.Drawing.Color]::FromArgb(27, 26, 24)
$accent  = [System.Drawing.Color]::FromArgb(214, 90, 40)
$accent2 = [System.Drawing.Color]::FromArgb(150, 58, 24)
$text    = [System.Drawing.Color]::FromArgb(237, 233, 222)
$muted   = [System.Drawing.Color]::FromArgb(120, 116, 104)
$okGreen = [System.Drawing.Color]::FromArgb(55, 120, 75)
$warnOr  = [System.Drawing.Color]::FromArgb(224, 138, 46)
$btnBg   = [System.Drawing.Color]::FromArgb(38, 37, 34)
$btnHov  = [System.Drawing.Color]::FromArgb(50, 48, 44)
$trackBg = [System.Drawing.Color]::FromArgb(14, 14, 13)
$lcdBg   = [System.Drawing.Color]::FromArgb(184, 180, 140)
$lcdBg2  = [System.Drawing.Color]::FromArgb(166, 162, 120)
$lcdInk  = [System.Drawing.Color]::FromArgb(43, 42, 34)

function New-RoundedPath {
    param([Drawing.Rectangle]$Rect, [int]$Radius)
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    if ($d -gt $Rect.Width)  { $d = $Rect.Width }
    if ($d -gt $Rect.Height) { $d = $Rect.Height }
    if ($d -lt 2) {
        $path.AddRectangle($Rect)
        $path.CloseFigure()
        return $path
    }
    $path.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $path.AddArc(($Rect.Right - $d), $Rect.Y, $d, $d, 270, 90)
    $path.AddArc(($Rect.Right - $d), ($Rect.Bottom - $d), $d, $d, 0, 90)
    $path.AddArc($Rect.X, ($Rect.Bottom - $d), $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

# Owner-drawn rounded button: standard WinForms Button/FlatStyle can't do
# rounded corners, so we clear to the parent bg then paint a rounded fill +
# border + centered text ourselves. Reads Text/ForeColor/BackColor live off
# the control each repaint, so existing code that does $btn.Text = "..." or
# $btn.ForeColor = $accent (e.g. Update-RangeButton) keeps working untouched.
function Enable-RoundedButton {
    param([Windows.Forms.Button]$Btn, [int]$Radius = 8, [Drawing.Color]$HoverFill, [Drawing.Color]$ClearColor = $bg)
    $Btn.FlatStyle = 'Flat'
    $Btn.FlatAppearance.BorderSize = 0
    Enable-DoubleBuffer $Btn
    $Btn | Add-Member -NotePropertyName IsHover -NotePropertyValue $false -Force
    $Btn | Add-Member -NotePropertyName BorderColor -NotePropertyValue ([Drawing.Color]::FromArgb(46, 44, 40)) -Force
    $Btn | Add-Member -NotePropertyName ClearColor -NotePropertyValue $ClearColor -Force
    $Btn | Add-Member -NotePropertyName Radius -NotePropertyValue $Radius -Force
    if ($HoverFill) { $Btn | Add-Member -NotePropertyName HoverFill -NotePropertyValue $HoverFill -Force }
    $Btn.Add_MouseEnter({ param($s,$e); $s.IsHover = $true; $s.Invalidate() })
    $Btn.Add_MouseLeave({ param($s,$e); $s.IsHover = $false; $s.Invalidate() })
    $Btn.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($s.ClearColor)
        $rect = New-Object Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
        $path = New-RoundedPath $rect $s.Radius
        $fillColor = $s.BackColor
        if ($s.IsHover -and ($s.PSObject.Properties.Name -contains 'HoverFill')) { $fillColor = $s.HoverFill }
        $brush = New-Object Drawing.SolidBrush $fillColor
        $g.FillPath($brush, $path)
        $pen = New-Object Drawing.Pen($s.BorderColor, 1)
        $g.DrawPath($pen, $path)
        $flags = [Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::VerticalCenter
        [Windows.Forms.TextRenderer]::DrawText($g, $s.Text, $s.Font, $rect, $s.ForeColor, $flags)
        $brush.Dispose(); $pen.Dispose(); $path.Dispose()
    })
}

# WinForms Panel does not double-buffer by default: any Invalidate() (e.g. the
# percent Label's Text changing while dragging the slider) first erases the
# control to the raw background color, THEN runs the custom Paint handler —
# that erase-then-repaint gap is the visible flicker. DoubleBuffered is a
# protected Control property, so it's flipped on via reflection.
$script:__dbProp = [Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance, NonPublic')
function Enable-DoubleBuffer {
    param([Windows.Forms.Control]$Control)
    try { $script:__dbProp.SetValue($Control, $true, $null) } catch {}
}

# By default a Panel does NOT repaint itself when its size changes — WinForms
# only invalidates the newly-exposed sliver, not the whole client area. During
# a live window-drag (which fires Resize continuously), that stale, un-cleared
# backbuffer content can briefly show alongside the freshly-painted content at
# the new bounds — visible as a "duplicated"/torn fader bar while dragging.
# ControlStyles.ResizeRedraw forces a full Invalidate on every resize, which
# fixes it; SetStyle is protected, so it's flipped via reflection.
$script:__setStyleMethod = [Windows.Forms.Control].GetMethod('SetStyle', [Reflection.BindingFlags]'Instance, NonPublic')
function Enable-ResizeRedraw {
    param([Windows.Forms.Control]$Control)
    try { $script:__setStyleMethod.Invoke($Control, @([Windows.Forms.ControlStyles]::ResizeRedraw, $true)) } catch {}
}

# ---------- hardware lock (throttled) ----------
function Get-DimCimSession {
    # Reuse one session with a bounded operation timeout, instead of an
    # unbounded Get-CimInstance/Invoke-CimMethod call on the UI thread.
    if (-not $script:cimSession) {
        try {
            $opt = New-CimSessionOption -OperationTimeoutSec 3
            $script:cimSession = New-CimSession -SessionOption $opt -ErrorAction Stop
        } catch { $script:cimSession = $null }
    }
    return $script:cimSession
}

function Invoke-WithTimeout {
    # Sync primitive: start a process, wait up to $Ms, kill if hung.
    # Used by Start-PowerCfgBrightness100Async (off UI thread).
    param([string]$Exe, [string]$Args, [int]$Ms = 3000)
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $Args -WindowStyle Hidden -PassThru
        if (-not $p.WaitForExit($Ms)) {
            try { $p.Kill() } catch {}
            return $false
        }
        return ($p.ExitCode -eq 0)
    } catch { return $false }
}

function Set-HardwareBrightness100 {
    param([switch]$Force)
    $now = [datetime]::UtcNow
    # Throttle purely by elapsed time — NOT by whether the last call succeeded.
    # Bug fix: the previous condition also required $script:lastHwOk -eq $true,
    # so on machines without WmiMonitorBrightnessMethods (external monitors /
    # desktops), every call fails, lastHwOk stays $false, and throttling never
    # engages — Apply-Dim then does a full New-CimSession/Get-CimInstance/
    # Invoke-CimMethod round trip synchronously on every slider ValueChanged
    # (i.e. every pixel of drag), causing UI stutter. Throttle on time alone
    # and report the last known result instead.
    if (-not $Force -and ($now - $script:hwTimerSec).TotalMilliseconds -lt 15000) {
        return [bool]$script:lastHwOk
    }
    try {
        $ciArgs = @{ Namespace = 'root\wmi'; ClassName = 'WmiMonitorBrightnessMethods'; ErrorAction = 'Stop' }
        $sess = Get-DimCimSession
        if ($sess) { $ciArgs['CimSession'] = $sess }
        $methods = Get-CimInstance @ciArgs
        foreach ($m in $methods) {
            Invoke-CimMethod -InputObject $m -MethodName WmiSetBrightness -Arguments @{ Timeout = 1; Brightness = 100 } | Out-Null
        }
        # powercfg can take seconds; run off UI thread so slider/timer never stall
        Start-PowerCfgBrightness100Async
        $script:lastHwOk = $true
        $script:hwTimerSec = $now
        return $true
    } catch {
        $script:lastHwOk = $false
        $script:hwTimerSec = $now
        return $false
    }
}

function Start-PowerCfgBrightness100Async {
    # Off UI thread + timeout via Invoke-WithTimeout so stuck cmd/powercfg is killed
    try {
        $arg = '/c powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEONORMALLEVEL 100 & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_VIDEO VIDEONORMALLEVEL 100 & powercfg.exe /setactive SCHEME_CURRENT'
        # dispose previous completed helper to avoid runspace leaks.
        # If the previous call is still in flight, leave it alone (and skip
        # starting a new one below) instead of dropping the reference —
        # nulling it here would orphan the PowerShell instance/runspace
        # since EndInvoke/Dispose would never get called on it.
        if ($script:powerCfgAsync) {
            if ($script:powerCfgAsync.Handle.IsCompleted) {
                try {
                    $script:powerCfgAsync.PS.EndInvoke($script:powerCfgAsync.Handle) | Out-Null
                    $script:powerCfgAsync.PS.Dispose()
                } catch {}
                $script:powerCfgAsync = $null
            } else {
                return
            }
        }
        # run Invoke-WithTimeout body in a nested pipeline (UI stays free)
        $ps = [powershell]::Create().AddScript(${function:Invoke-WithTimeout}).AddParameters(@{
            Exe = 'cmd.exe'
            Args = $arg
            Ms  = 8000
        })
        $handle = $ps.BeginInvoke()
        $script:powerCfgAsync = @{ PS = $ps; Handle = $handle }
    } catch {}
}

function Enable-ClickThrough([System.Windows.Forms.Form]$Form) {
    $hwnd = $Form.Handle
    $ex = [SoftDim.Native]::GetWindowLong($hwnd, [SoftDim.Native]::GWL_EXSTYLE)
    $ex = $ex -bor [SoftDim.Native]::WS_EX_LAYERED -bor [SoftDim.Native]::WS_EX_TRANSPARENT `
              -bor [SoftDim.Native]::WS_EX_TOOLWINDOW -bor [SoftDim.Native]::WS_EX_NOACTIVATE
    [void][SoftDim.Native]::SetWindowLong($hwnd, [SoftDim.Native]::GWL_EXSTYLE, $ex)
    [void][SoftDim.Native]::SetWindowPos(
        $hwnd, [SoftDim.Native]::HWND_TOPMOST, 0, 0, 0, 0,
        ([SoftDim.Native]::SWP_NOMOVE -bor [SoftDim.Native]::SWP_NOSIZE -bor [SoftDim.Native]::SWP_NOACTIVATE -bor [SoftDim.Native]::SWP_SHOWWINDOW)
    )
}

function Enable-DarkTitleBar([System.Windows.Forms.Form]$Form) {
    try {
        $v = 1
        [void][SoftDim.Native]::DwmSetWindowAttribute($Form.Handle, [SoftDim.Native]::DWMWA_USE_IMMERSIVE_DARK_MODE, [ref]$v, 4)
    } catch {}
}

function New-AppIcon {
    # prefer launcher icon next to the script (same art as SoftwareDimmer.exe)
    try {
        $icoFile = $null
        if ($script:selfPath) {
            $icoFile = Join-Path (Split-Path -Parent $script:selfPath) 'SoftwareDimmer.ico'
        }
        if (-not $icoFile -or -not (Test-Path -LiteralPath $icoFile)) {
            $icoFile = Join-Path $PSScriptRoot 'SoftwareDimmer.ico'
        }
        if ($icoFile -and (Test-Path -LiteralPath $icoFile)) {
            $loaded = New-Object System.Drawing.Icon($icoFile, 32, 32)
            $clone = $loaded.Clone()
            $loaded.Dispose()
            $script:iconHandle = [IntPtr]::Zero
            return $clone
        }
    } catch {}

    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::FromArgb(23, 22, 20))
    $brush = New-Object Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(214, 90, 40))
    $g.FillEllipse($brush, 4, 4, 24, 24)
    $brush2 = New-Object Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(23, 22, 20))
    $g.FillEllipse($brush2, 12, 2, 20, 20)
    $g.Dispose(); $brush.Dispose(); $brush2.Dispose()
    $h = $bmp.GetHicon()
    $script:iconHandle = $h
    $ico = [System.Drawing.Icon]::FromHandle($h)
    $bmp.Dispose()
    return $ico
}

# ---------- overlay ----------
$script:overlay = New-Object Windows.Forms.Form
$script:overlay.FormBorderStyle = 'None'
$script:overlay.ShowInTaskbar = $false
$script:overlay.StartPosition = 'Manual'
$script:overlay.BackColor = [System.Drawing.Color]::Black
$script:overlay.TopMost = $true
$script:overlay.Opacity = 0
$script:overlay.Bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen

function Get-DimScale([int]$Percent) {
    # match old overlay feel: black veil opacity = (100-P)/100 * maxOpacity
    $scale = 1.0 - ((100 - $Percent) / 100.0 * $script:maxOpacity)
    if ($scale -lt 0.05) { $scale = 0.05 }
    if ($scale -gt 1.0) { $scale = 1.0 }
    return [float]$scale
}

function Hide-DimOverlay {
    try {
        if ($script:overlay -and -not $script:overlay.IsDisposed) {
            $script:overlay.Opacity = 0
            if ($script:overlay.Visible) { $script:overlay.Hide() }
        }
    } catch {}
}

function Show-DimOverlay([int]$Percent) {
    $opacity = [math]::Round((100 - $Percent) / 100.0 * $script:maxOpacity, 3)
    if ($opacity -lt 0) { $opacity = 0 }
    if ($opacity -gt $script:maxOpacity) { $opacity = $script:maxOpacity }
    $script:overlay.Bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($opacity -le 0.01) {
        Hide-DimOverlay
        return
    }
    if (-not $script:overlay.Visible) {
        $script:overlay.Show()
        Enable-ClickThrough $script:overlay
        $script:overlay.TopMost = $true
    }
    # click-through/topmost only need (re)asserting once, on show — not on
    # every brightness update — the 4s timer and WinEvent hooks already
    # reassert them if something knocks the overlay out of place later.
    $script:overlay.Opacity = $opacity
}

function Set-DimModeActive([string]$Active) {
    $a = Normalize-DimMode $Active
    if ($script:dimModeActive -eq $a) { return }
    $script:dimModeActive = $a
    Update-DimModeButton
}

function Set-OverlayBrightness([int]$Percent) {
    # Preference DimMode: Mag | Gamma | Overlay. dimModeActive = what actually stuck.
    # ResetGamma()/ResetMag() call into SetDeviceGammaRamp / the Magnification
    # API's reset path — real driver-level calls, not cheap. The old code ran
    # the "clear the other engine" reset on EVERY call, i.e. on every single
    # mouse-move while dragging the fader, which is what caused the stutter
    # when dragging fast. They only need to run once, at the moment the
    # active engine actually changes — not on every repeated frame while it
    # stays the same.
    $scale = Get-DimScale $Percent
    $mode = Normalize-DimMode $script:dimMode
    $script:dimMode = $mode
    $wasActive = $script:dimModeActive

    switch ($mode) {
        'Mag' {
            if ($wasActive -ne 'Mag') { try { [SoftDim.ScreenFx]::ResetGamma() } catch {} }
            $ok = $false
            try { $ok = [SoftDim.ScreenFx]::SetMag($scale) } catch { $ok = $false }
            if ($ok) {
                Hide-DimOverlay
                Set-DimModeActive 'Mag'
                return
            }
            # soft-fallback so screen still dims; button shows Mag→…
            try {
                if ([SoftDim.ScreenFx]::SetGamma($scale)) {
                    Hide-DimOverlay
                    Set-DimModeActive 'Gamma'
                    return
                }
            } catch {}
            try { [SoftDim.ScreenFx]::ResetMag() } catch {}
            try { [SoftDim.ScreenFx]::ResetGamma() } catch {}
            Show-DimOverlay $Percent
            Set-DimModeActive 'Overlay'
        }
        'Gamma' {
            if ($wasActive -ne 'Gamma') { try { [SoftDim.ScreenFx]::ResetMag() } catch {} }
            $ok = $false
            try { $ok = [SoftDim.ScreenFx]::SetGamma($scale) } catch { $ok = $false }
            if ($ok) {
                Hide-DimOverlay
                Set-DimModeActive 'Gamma'
                return
            }
            try { [SoftDim.ScreenFx]::ResetGamma() } catch {}
            Show-DimOverlay $Percent
            Set-DimModeActive 'Overlay'
        }
        default {
            if ($wasActive -ne 'Overlay') {
                try { [SoftDim.ScreenFx]::ResetMag() } catch {}
                try { [SoftDim.ScreenFx]::ResetGamma() } catch {}
            }
            Show-DimOverlay $Percent
            Set-DimModeActive 'Overlay'
        }
    }
}

function Apply-DimEngine([int]$Percent) {
    # The actual "heavy" work for one dim frame: engine syscall + tray tip.
    # Kept separate from Apply-Dim so the throttle below only has to wrap
    # this part — the label/fader repaint stay unthrottled and instant.
    try {
        Set-OverlayBrightness $Percent
        $script:tray.Text = "软件调暗 — $Percent%"
    } catch {}
}

function Ensure-DimApplyTimer {
    if ($script:dimApplyTimer -and -not $script:dimApplyTimer.Disposed) { return }
    $script:dimApplyTimer = New-Object Windows.Forms.Timer
    $script:dimApplyTimer.Add_Tick({
        param($s, $e)
        try { $s.Stop() } catch {}
        $script:dimApplyQueued = $false
        if ($null -ne $script:dimApplyPendingPct) {
            $p = [int]$script:dimApplyPendingPct
            $script:dimApplyPendingPct = $null
            $script:lastDimApplyUtc = [datetime]::UtcNow
            Apply-DimEngine $p
        }
    })
}

function Request-DimApply([int]$Percent) {
    # Same coalescing shape as Request-DimReassert: run immediately if we're
    # past the minimum spacing, otherwise remember the latest value and let
    # a single trailing timer tick apply it once the window opens up. This
    # way a fast drag settles at whatever rate the engine can actually keep
    # up with, but the last value the user let go on is never skipped.
    $now = [datetime]::UtcNow
    $ms = ($now - $script:lastDimApplyUtc).TotalMilliseconds
    if ($ms -ge $script:dimApplyMinMs) {
        $script:lastDimApplyUtc = $now
        Apply-DimEngine $Percent
        return
    }
    $script:dimApplyPendingPct = $Percent
    if (-not $script:dimApplyQueued) {
        $script:dimApplyQueued = $true
        Ensure-DimApplyTimer
        $delay = [Math]::Max(1, [int]($script:dimApplyMinMs - $ms))
        $script:dimApplyTimer.Interval = $delay
        $script:dimApplyTimer.Stop()
        $script:dimApplyTimer.Start()
    }
}

function Reset-ScreenFx {
    try { [SoftDim.ScreenFx]::ShutdownAll() } catch {}
    Hide-DimOverlay
    $script:dimModeActive = $null
}

function Invoke-OnUi {
    param([scriptblock]$Action)
    if (-not $script:ui -or $script:ui.IsDisposed) {
        try { & $Action } catch {}
        return
    }
    if ($script:ui.InvokeRequired) {
        try {
            [void]$script:ui.BeginInvoke($Action)
        } catch {
            # never run WinForms work on the WinEvent thread
        }
    } else {
        try { & $Action } catch {}
    }
}

function Apply-DimReassertCore {
    param(
        [ValidateSet('Full', 'OverlayOnly')]
        [string]$Kind = 'Full'
    )
    # MUST run on UI thread only
    try {
        if ($Kind -eq 'OverlayOnly') {
            if ($script:overlay -and -not $script:overlay.IsDisposed -and $script:overlay.Visible) {
                Enable-ClickThrough $script:overlay
                $script:overlay.TopMost = $true
            }
            return
        }
        if ($script:slider -and -not $script:slider.IsDisposed) {
            Set-OverlayBrightness ([int]$script:slider.Value)
        }
    } catch {}
}

function Ensure-ReassertThrottleTimer {
    if ($script:reassertTimer -and -not $script:reassertTimer.Disposed) { return }
    $script:reassertTimer = New-Object Windows.Forms.Timer
    $script:reassertTimer.Add_Tick({
        param($s, $e)
        try { $s.Stop() } catch {}
        $script:reassertQueued = $false
        $k = if ($script:reassertPendingKind) { $script:reassertPendingKind } else { 'Full' }
        $script:lastReassertUtc = [datetime]::UtcNow
        Apply-DimReassertCore -Kind $k
    })
}

function Request-DimReassert {
    param(
        [switch]$Force,
        [ValidateSet('Full', 'OverlayOnly')]
        [string]$Kind = 'Full'
    )
    # Always hop to UI first — WinEvent is out-of-context / other thread
    $forceLocal = [bool]$Force
    $kindLocal  = $Kind
    Invoke-OnUi {
        try {
            if ($script:exiting) { return }
            $now = [datetime]::UtcNow
            if (-not $forceLocal) {
                $ms = ($now - $script:lastReassertUtc).TotalMilliseconds
                if ($ms -ge 0 -and $ms -lt $script:reassertMinMs) {
                    # prefer Full if any pending event needs full reapply
                    if ($kindLocal -eq 'Full' -or -not $script:reassertPendingKind) {
                        $script:reassertPendingKind = $kindLocal
                    } elseif ($script:reassertPendingKind -eq 'OverlayOnly' -and $kindLocal -eq 'Full') {
                        $script:reassertPendingKind = 'Full'
                    }
                    if (-not $script:reassertQueued) {
                        $script:reassertQueued = $true
                        Ensure-ReassertThrottleTimer
                        $delay = [Math]::Max(50, [int]($script:reassertMinMs - $ms))
                        $script:reassertTimer.Interval = $delay
                        $script:reassertTimer.Stop()
                        $script:reassertTimer.Start()
                    }
                    return
                }
            }
            $script:lastReassertUtc = $now
            $script:reassertQueued = $false
            $script:reassertPendingKind = $null
            try { if ($script:reassertTimer) { $script:reassertTimer.Stop() } } catch {}
            Apply-DimReassertCore -Kind $kindLocal
        } catch {}
    }
}

# ---------- main UI ----------
$script:ui = New-Object Windows.Forms.Form
$script:ui.Text = "Software Dimmer — 软件调暗"
$script:ui.ClientSize = New-Object Drawing.Size([int]$script:settings.WindowWidth, [int]$script:settings.WindowHeight)
# outer min size — must stay <= default ClientSize so saved WindowWidth/Height actually apply
$script:ui.MinimumSize = New-Object Drawing.Size($script:minClientW, $script:minClientH)
$script:ui.StartPosition = 'CenterScreen'
$script:ui.FormBorderStyle = 'Sizable'
$script:ui.MaximizeBox = $true
$script:ui.MinimizeBox = $true
$script:ui.TopMost = [bool]$script:settings.AlwaysOnTop
$script:ui.BackColor = $bg
$script:ui.ForeColor = $text
$script:ui.Font = New-Object Drawing.Font('Microsoft YaHei', 9)
$script:ui.KeyPreview = $true
$script:ui.ShowInTaskbar = $true
$script:ui.Padding = New-Object Windows.Forms.Padding(0)

$script:appIcon = New-AppIcon
$script:ui.Icon = $script:appIcon

# body first (Dock Fill, bottom of z-order), then header (Dock Top) — WinForms dock order
$script:body = New-Object Windows.Forms.Panel
$script:body.Dock = 'Fill'
$script:body.BackColor = $bg
$script:ui.Controls.Add($script:body)

$script:header = New-Object Windows.Forms.Panel
$script:header.Dock = 'Top'
$script:header.Height = 72
$script:header.BackColor = $card
$script:ui.Controls.Add($script:header)
$script:header.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $rivetBrush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(52, 50, 46))
    $rivetR = 2
    $g.FillEllipse($rivetBrush, (10 - $rivetR), (10 - $rivetR), ($rivetR * 2), ($rivetR * 2))
    $g.FillEllipse($rivetBrush, (10 - $rivetR), ($s.Height - 10 - $rivetR), ($rivetR * 2), ($rivetR * 2))
    $rivetBrush.Dispose()
})

$lblApp = New-Object Windows.Forms.Label
$lblApp.Text = "Software Dimmer 软件调暗"
$lblApp.Font = New-Object Drawing.Font('Microsoft YaHei', 12.5, [Drawing.FontStyle]::Bold)
$lblApp.ForeColor = $text
$lblApp.Location = New-Object Drawing.Point(28, 12)
$lblApp.AutoSize = $true
$script:header.Controls.Add($lblApp)

$lblSub = New-Object Windows.Forms.Label
$lblSub.Text = "Grok Build"
$lblSub.Font = New-Object Drawing.Font('Microsoft YaHei', 8.5)
$lblSub.ForeColor = $muted
$lblSub.Location = New-Object Drawing.Point(28, 42)
$lblSub.AutoSize = $true
$script:header.Controls.Add($lblSub)

# 重启 UI — 标题栏右上角（对应标注红框位置）
$script:btnRestart = New-Object Windows.Forms.Button
$script:btnRestart.Text = "重启"
$script:btnRestart.BackColor = $btnBg
$script:btnRestart.ForeColor = $text
$script:btnRestart.Cursor = 'Hand'
$script:btnRestart.Font = New-Object Drawing.Font('Microsoft YaHei', 9, [Drawing.FontStyle]::Bold)
$script:btnRestart.Size = New-Object Drawing.Size(72, 32)
Enable-RoundedButton -Btn $script:btnRestart -Radius 8 -HoverFill $btnHov -ClearColor $card
$script:btnRestart.Add_Click({ Restart-DimmerUI })
$script:header.Controls.Add($script:btnRestart)
# restart button position is owned by Update-UiLayout (body + header resize)

# LCD-style readout panel (recessed cream face, dark ink digits)
$script:lcdPanel = New-Object Windows.Forms.Panel
$script:lcdPanel.BackColor = $bg
Enable-DoubleBuffer $script:lcdPanel
Enable-ResizeRedraw $script:lcdPanel
$script:body.Controls.Add($script:lcdPanel)
$script:lcdPanel.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    # LinearGradientBrush throws on a zero/negative-size rect, which briefly
    # happens while the form is docking/resizing (Width or Height hits 0 for
    # one layout pass). Clamp instead of letting that exception skip the
    # Dispose calls below and leak the GDI path/brush/pen each time it fires.
    $w = [Math]::Max(1, $s.Width - 1)
    $h = [Math]::Max(1, $s.Height - 1)
    $rect = New-Object Drawing.Rectangle(0, 0, $w, $h)
    $path = $null; $grad = $null; $edgePen = $null
    try {
        $path = New-RoundedPath $rect 14
        $grad = New-Object Drawing.Drawing2D.LinearGradientBrush($rect, $lcdBg, $lcdBg2, 90)
        $g.FillPath($grad, $path)
        $edgePen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(55, 0, 0, 0), 1)
        $g.DrawPath($edgePen, $path)
    } finally {
        if ($grad) { $grad.Dispose() }
        if ($edgePen) { $edgePen.Dispose() }
        if ($path) { $path.Dispose() }
    }
})

$script:lblValue = New-Object Windows.Forms.Label
$script:lblValue.Text = "$($script:settings.Brightness)%"
$script:lblValue.Font = New-Object Drawing.Font('Consolas', 34, [Drawing.FontStyle]::Bold)
$script:lblValue.ForeColor = $accent
$script:lblValue.BackColor = [Drawing.Color]::Transparent
$script:lblValue.TextAlign = 'MiddleCenter'
$script:lblValue.AutoSize = $false
$script:lblValue.Dock = 'Fill'
$script:lcdPanel.Controls.Add($script:lblValue)

# custom-ish track area — a hidden TrackBar keeps all existing value/keyboard/save
# logic exactly as before; a custom-painted fader panel drives it visually + by mouse.
$script:trackPanel = New-Object Windows.Forms.Panel
$script:trackPanel.BackColor = $bg
Enable-ResizeRedraw $script:trackPanel
$script:body.Controls.Add($script:trackPanel)

$script:slider = New-Object Windows.Forms.TrackBar
$script:slider.TickStyle = 'None'
$script:slider.SmallChange = 1
$script:slider.Visible = $false
$script:slider.TabStop = $false
$script:slider.Size = New-Object Drawing.Size(1, 1)
$script:slider.Location = New-Object Drawing.Point(0, 0)
# range mode already restored from settings; clamp brightness to active range
if ($script:rangeModeExtreme) {
    $script:slider.Minimum = 0
    $script:slider.Maximum = 25
    $script:slider.LargeChange = 5
} else {
    $script:slider.Minimum = 10
    $script:slider.Maximum = 100
    $script:slider.LargeChange = 10
}
$bv = [int]$script:settings.Brightness
if ($bv -lt [int]$script:slider.Minimum) { $bv = [int]$script:slider.Minimum }
if ($bv -gt [int]$script:slider.Maximum) { $bv = [int]$script:slider.Maximum }
$script:slider.Value = $bv
$script:trackPanel.Controls.Add($script:slider)
# keep percent label in sync with clamped slider (avoids 5% → 10% flash)
$script:lblValue.Text = "$bv%"

# fader visual: knurled handle on a recessed rail
$script:faderTrack = New-Object Windows.Forms.Panel
$script:faderTrack.BackColor = $bg
$script:faderTrack.Cursor = 'Hand'
Enable-DoubleBuffer $script:faderTrack
Enable-ResizeRedraw $script:faderTrack
$script:trackPanel.Controls.Add($script:faderTrack)
$script:faderTrack.Dock = 'Fill'
$script:faderDragging = $false
# belt-and-braces: explicitly invalidate on every resize tick during a live
# window-drag, in case ResizeRedraw alone doesn't cover a particular resize path
$script:faderTrack.Add_Resize({ $script:faderTrack.Invalidate() })

function Get-FaderHandleD([int]$H) {
    # handle (and by extension rail) thickness scales with the actual panel
    # height so a taller slider (bigger window) reads as a chunkier control
    # instead of a thin bar floating inside a much taller empty box.
    $d = [int]($H * 0.55)
    if ($d -lt 22) { $d = 22 }
    if ($d -gt 64) { $d = 64 }
    return $d
}

function Get-FaderValueAtX([int]$X) {
    $handleD = Get-FaderHandleD $script:faderTrack.Height
    $margin = [int]($handleD / 2)
    $usableW = [Math]::Max(1, $script:faderTrack.Width - ($handleD))
    $rel = $X - $margin
    if ($rel -lt 0) { $rel = 0 }
    if ($rel -gt $usableW) { $rel = $usableW }
    $spanR = [int]$script:slider.Maximum - [int]$script:slider.Minimum
    $v = [int]$script:slider.Minimum + [Math]::Round(($rel / $usableW) * $spanR)
    return [int]$v
}

$script:faderTrack.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $h = $s.Height
    $w = $s.Width
    $handleD = Get-FaderHandleD $h
    $railH = [Math]::Max(10, [int]($handleD * 0.56))
    $margin = [int]($handleD / 2)
    $railY = [int](($h - $railH) / 2)
    $railRect = New-Object Drawing.Rectangle($margin, $railY, ([Math]::Max(1, $w - ($margin * 2))), $railH)
    $railPath = New-RoundedPath $railRect ([int]($railH / 2))
    $railBrush = New-Object Drawing.SolidBrush $trackBg
    $g.FillPath($railBrush, $railPath)

    $usableW = [Math]::Max(1, $w - $handleD)
    $spanR = [int]$script:slider.Maximum - [int]$script:slider.Minimum
    if ($spanR -lt 1) { $spanR = 1 }
    $pct = ([int]$script:slider.Value - [int]$script:slider.Minimum) / $spanR
    $fillW = [int]($usableW * $pct)
    if ($fillW -gt 0) {
        $fillRect = New-Object Drawing.Rectangle($margin, $railY, ($fillW + $margin), $railH)
        $fillPath = New-RoundedPath $fillRect ([int]($railH / 2))
        $fillBrush = New-Object Drawing.Drawing2D.LinearGradientBrush($fillRect, $accent2, $accent, 0)
        $g.FillPath($fillBrush, $fillPath)
        $fillBrush.Dispose(); $fillPath.Dispose()
    }

    $hx = $margin + $fillW - [int]($handleD / 2)
    $hy = [int](($h - $handleD) / 2)
    $handleRect = New-Object Drawing.Rectangle($hx, $hy, $handleD, $handleD)
    $handlePath = New-RoundedPath $handleRect ([Math]::Max(4, [int]($handleD * 0.23)))
    $handleBrush = New-Object Drawing.Drawing2D.LinearGradientBrush($handleRect, [Drawing.Color]::FromArgb(56, 54, 50), [Drawing.Color]::FromArgb(30, 29, 27), 90)
    $g.FillPath($handleBrush, $handlePath)
    $handlePen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(70, 68, 62), 1)
    $g.DrawPath($handlePen, $handlePath)
    $gripPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(80, 78, 70), 1.4)
    $gripSpacing = [Math]::Max(3, [int]($handleD * 0.15))
    for ($i = -1; $i -le 1; $i++) {
        $gx = $hx + [int]($handleD / 2) + ($i * $gripSpacing)
        $g.DrawLine($gripPen, $gx, ($hy + 6), $gx, ($hy + $handleD - 6))
    }
    $railBrush.Dispose(); $railPath.Dispose()
    $handleBrush.Dispose(); $handlePath.Dispose(); $handlePen.Dispose(); $gripPen.Dispose()
})

$script:faderTrack.Add_MouseDown({
    param($s, $e)
    $script:faderDragging = $true
    $script:slider.Value = Get-FaderValueAtX $e.X
})
$script:faderTrack.Add_MouseMove({
    param($s, $e)
    if ($script:faderDragging) {
        $script:slider.Value = Get-FaderValueAtX $e.X
    }
})
$script:faderTrack.Add_MouseUp({
    param($s, $e)
    if ($script:faderDragging) {
        $script:faderDragging = $false
        Save-DimSettings -Brightness ([int]$script:slider.Value) -CloseToTray $script:chkTray.Checked -AlwaysOnTop $script:chkTop.Checked
    }
})
$script:faderTrack.Add_MouseWheel({
    param($s, $e)
    $r = Get-DimRange
    $delta = if ($e.Delta -gt 0) { 5 } else { -5 }
    $v = [Math]::Min([int]$r.Max, [Math]::Max([int]$r.Min, [int]$script:slider.Value + $delta))
    $script:slider.Value = $v
    Save-DimSettings -Brightness $v -CloseToTray $script:chkTray.Checked -AlwaysOnTop $script:chkTop.Checked
})

# presets — 一般 / 极暗两套
$script:presetsNormal = @(
    @{ T = '18%';  V = 18 },
    @{ T = '35%';  V = 35 },
    @{ T = '45%';  V = 45 },
    @{ T = '100%'; V = 100 }
)
$script:presetsExtreme = @(
    @{ T = '0%';  V = 0 },
    @{ T = '5%';  V = 5 },
    @{ T = '10%'; V = 10 },
    @{ T = '25%'; V = 25 }
)
$script:presetButtons = @()
foreach ($p in $script:presetsNormal) {
    $btn = New-Object Windows.Forms.Button
    $btn.Text = $p.T
    $btn.Tag = $p.V
    $btn.BackColor = $btnBg
    $btn.ForeColor = $text
    $btn.Cursor = 'Hand'
    $btn.Font = New-Object Drawing.Font('Consolas', 11, [Drawing.FontStyle]::Bold)
    Enable-RoundedButton -Btn $btn -Radius 8 -HoverFill $btnHov
    $btn.Add_Click({
        param($s, $e)
        Set-BrightnessValue ([int]$s.Tag) -Save
    })
    $script:body.Controls.Add($btn)
    $script:presetButtons += $btn
}

# two bars under presets: 范围(一般/极暗) | 模式(Mag/Gamma/遮罩)
function Update-RangeButton {
    if (-not $script:btnRange -or $script:btnRange.IsDisposed) { return }
    if ($script:rangeModeExtreme) {
        $script:btnRange.Text = "范围：极暗"
        $script:btnRange.ForeColor = $warnOr
    } else {
        $script:btnRange.Text = "范围：一般"
        $script:btnRange.ForeColor = $text
    }
}

function Get-DimModeLabel([string]$Mode) {
    switch (Normalize-DimMode $Mode) {
        'Mag'   { return 'Mag' }
        'Gamma' { return 'Gamma' }
        default { return '遮罩' }
    }
}

function Update-DimModeButton {
    if (-not $script:btnDimMode -or $script:btnDimMode.IsDisposed) { return }
    $pref = Normalize-DimMode $script:dimMode
    $act  = if ($script:dimModeActive) { Normalize-DimMode $script:dimModeActive } else { $pref }
    $prefL = Get-DimModeLabel $pref
    $actL  = Get-DimModeLabel $act
    if ($pref -eq $act) {
        $script:btnDimMode.Text = "模式: $prefL"
        switch ($pref) {
            'Mag'   { $script:btnDimMode.ForeColor = $accent }
            'Gamma' { $script:btnDimMode.ForeColor = $warnOr }
            default { $script:btnDimMode.ForeColor = $text }
        }
    } else {
        # preference vs actual engine (fallback) — keep honest
        $script:btnDimMode.Text = "模式: $prefL→$actL"
        $script:btnDimMode.ForeColor = $warnOr
    }
}

function Set-DimMode {
    param([string]$Mode, [switch]$Save)
    $script:dimMode = Normalize-DimMode $Mode
    $script:dimModeActive = $null
    Update-DimModeButton
    Apply-Dim ([int]$script:slider.Value)
    if ($Save) {
        Save-DimSettings -Brightness ([int]$script:slider.Value) -CloseToTray $script:chkTray.Checked -AlwaysOnTop $script:chkTop.Checked
    }
}

function Cycle-DimMode {
    $cur = Normalize-DimMode $script:dimMode
    $next = switch ($cur) {
        'Mag'   { 'Gamma' }
        'Gamma' { 'Overlay' }
        default { 'Mag' }
    }
    Set-DimMode $next -Save
}

$script:btnRange = New-Object Windows.Forms.Button
$script:btnRange.BackColor = $panel
$script:btnRange.Cursor = 'Hand'
$script:btnRange.Font = New-Object Drawing.Font('Microsoft YaHei', 9, [Drawing.FontStyle]::Bold)
Enable-RoundedButton -Btn $script:btnRange -Radius 8 -HoverFill $btnHov
$script:btnRange.Add_Click({
    Set-RangeMode -Extreme:(-not $script:rangeModeExtreme)
})
$script:body.Controls.Add($script:btnRange)
Update-RangeButton

$script:btnDimMode = New-Object Windows.Forms.Button
$script:btnDimMode.BackColor = $panel
$script:btnDimMode.Cursor = 'Hand'
$script:btnDimMode.Font = New-Object Drawing.Font('Microsoft YaHei', 9, [Drawing.FontStyle]::Bold)
Enable-RoundedButton -Btn $script:btnDimMode -Radius 8 -HoverFill $btnHov
$script:btnDimMode.Add_Click({ Cycle-DimMode })
$script:body.Controls.Add($script:btnDimMode)
Update-DimModeButton

# options — custom-drawn checkboxes for dark theme visibility
function New-DarkCheckBox([string]$Label, [bool]$Checked, [scriptblock]$OnChange) {
    $chk = New-Object Windows.Forms.CheckBox
    $chk.Text = $Label
    $chk.AutoSize = $false
    $chk.Size = New-Object Drawing.Size(140, 28)
    $chk.Checked = $Checked
    $chk.TabStop = $true
    $chk.FlatStyle = 'Standard'
    $chk.UseVisualStyleBackColor = $false
    $chk.BackColor = $bg
    $chk.ForeColor = $text
    $chk.Font = New-Object Drawing.Font('Microsoft YaHei', 9.5)
    # custom paint: draw a rocker-style toggle switch on dark bg
    $chk.Add_Paint({
        param($s, $e)
        $cb = $s -as [Windows.Forms.CheckBox]
        $g = $e.Graphics
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($bg)
        [int]$rw = 34
        [int]$rh = 18
        [int]$rx = 0
        [int]$ry = [Math]::Floor(($cb.Height - $rh) / 2)
        $trackRect = New-Object Drawing.Rectangle($rx, $ry, $rw, $rh)
        $trackPath = New-RoundedPath $trackRect ([int]($rh / 2))
        if ($cb.Checked) {
            $trackBrush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(60, 30, 16))
        } else {
            $trackBrush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(14, 14, 13))
        }
        $g.FillPath($trackBrush, $trackPath)
        $borderPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(60, 0, 0, 0), 1)
        $g.DrawPath($borderPen, $trackPath)

        [int]$thumbD = $rh - 4
        [int]$thumbY = $ry + 2
        [int]$thumbX = if ($cb.Checked) { $rx + $rw - $thumbD - 2 } else { $rx + 2 }
        $thumbRect = New-Object Drawing.Rectangle($thumbX, $thumbY, $thumbD, $thumbD)
        if ($cb.Checked) {
            $thumbBrush = New-Object Drawing.SolidBrush $accent
        } else {
            $thumbBrush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(74, 71, 65))
        }
        $g.FillEllipse($thumbBrush, $thumbRect)

        # text
        [int]$txtX = $rw + 10
        [int]$txtW = $cb.Width - $txtX
        $textRect = New-Object Drawing.Rectangle($txtX, 0, $txtW, $cb.Height)
        $flags = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::Left
        [System.Windows.Forms.TextRenderer]::DrawText($g, $cb.Text, $cb.Font, $textRect, $text, $flags)

        $trackBrush.Dispose(); $borderPen.Dispose(); $thumbBrush.Dispose(); $trackPath.Dispose()
    })
    $chk.Add_Click({ param($s,$e); $OnChange.InvokeReturnAsIs($s.Checked) })
    return $chk
}

$script:chkTray = New-DarkCheckBox '关闭到托盘' ([bool]$script:settings.CloseToTray) {
    param($v)
    Save-DimSettings -Brightness ([int]$script:slider.Value) -CloseToTray $v -AlwaysOnTop $script:chkTop.Checked
}
$script:body.Controls.Add($script:chkTray)

$script:chkTop = New-DarkCheckBox '窗口置顶' ([bool]$script:settings.AlwaysOnTop) {
    param($v)
    $script:ui.TopMost = $v
    Save-DimSettings -Brightness ([int]$script:slider.Value) -CloseToTray $script:chkTray.Checked -AlwaysOnTop $v
}
$script:body.Controls.Add($script:chkTop)

$script:btnExit = New-Object Windows.Forms.Button
$script:btnExit.Text = "退出"
$script:btnExit.BackColor = [System.Drawing.Color]::FromArgb(58, 28, 20)
$script:btnExit.ForeColor = [System.Drawing.Color]::FromArgb(232, 202, 190)
$script:btnExit.Cursor = 'Hand'
$script:btnExit.Font = New-Object Drawing.Font('Microsoft YaHei', 9.5, [Drawing.FontStyle]::Bold)
Enable-RoundedButton -Btn $script:btnExit -Radius 8 -HoverFill ([System.Drawing.Color]::FromArgb(74, 36, 26))
$script:btnExit.BorderColor = [System.Drawing.Color]::FromArgb(90, 44, 30)
$script:btnExit.Add_Click({ Exit-Dimmer })
$script:body.Controls.Add($script:btnExit)

$script:lblKeys = New-Object Windows.Forms.Label
$script:lblKeys.Text = "快捷键：← →  ±5%    1-4 预设    Esc 隐藏"
$script:lblKeys.Font = New-Object Drawing.Font('Microsoft YaHei', 8)
$script:lblKeys.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$script:lblKeys.TextAlign = 'MiddleLeft'
$script:lblKeys.AutoSize = $false
$script:body.Controls.Add($script:lblKeys)

# responsive layout — always fits inside body; shrinks gaps/percent when short, breathes when tall
function Update-UiLayout {
    if (-not $script:body -or $script:body.IsDisposed) { return }
    $padX = 28
    $padTop = 20
    $padBot = 20
    # single horizontal gap used for spacing items *within* a row (preset buttons,
    # range/mode pair, checkbox pair) so the row rhythm feels consistent throughout —
    # previously these were three different values (12 / 10 / 16).
    $itemGap = 16
    $w = [Math]::Max(200, $script:body.ClientSize.Width)
    $h = [Math]::Max(240, $script:body.ClientSize.Height)
    $rawInnerW = [Math]::Max(160, $w - ($padX * 2))
    # cap the content width — on a very wide (e.g. maximized) window, stretching
    # the slider/buttons edge-to-edge just makes them long, flat, and awkward.
    # Past this width the card stays a comfortable size and centers horizontally
    # instead of stretching further.
    $maxCardW = 880
    $innerW = [Math]::Min($rawInnerW, $maxCardW)
    $left = $padX + [int](($rawInnerW - $innerW) / 2)
    $avail = [Math]::Max(200, $h - $padTop - $padBot)

    # preferred sizes at a comfortable height (~420px body)
    $valueH = 80
    $trackH = 48
    $btnH   = 40
    $rangeH = 38
    $optH   = 36
    $keysH  = 22
    # gaps: value->track, track->presets, presets->range, range->options, options->keys
    $g1 = 12; $g2 = 14; $g3 = 12; $g4 = 16; $g5 = 16

    $sum = {
        param($vh,$th,$bh,$rh,$a,$b,$c,$d,$e)
        return ($vh + $th + $bh + $rh + ($optH * 2.6) + $keysH + $a + $b + $c + $d + $e)
    }
    $total = & $sum $valueH $trackH $btnH $rangeH $g1 $g2 $g3 $g4 $g5

    if ($total -lt $avail) {
        # grow into free space: bigger, more visible elements (readout, slider
        # rail, buttons, rows) grow first — with generous caps — so a maximized
        # window reads as "a bigger, comfortable UI", not "the same small card
        # floating in a mostly-empty canvas". Gaps grow too, but capped tighter
        # than the controls so spacing never outpaces the things it separates.
        # Anything left after every cap is hit centers the whole cluster
        # vertically rather than ballooning one gap further.
        $free = $avail - $total
        $valueH = [Math]::Min(200, $valueH + [int]($free * 0.28))
        $trackH = [Math]::Min(120, $trackH + [int]($free * 0.12))
        $btnH   = [Math]::Min(100, $btnH   + [int]($free * 0.10))
        $rangeH = [Math]::Min(90,  $rangeH + [int]($free * 0.07))
        $optH   = [Math]::Min(80,  $optH   + [int]($free * 0.06))
        $keysH  = [Math]::Min(40,  $keysH  + [int]($free * 0.03))
        $free2 = $avail - (& $sum $valueH $trackH $btnH $rangeH $g1 $g2 $g3 $g4 $g5)
        if ($free2 -gt 0) {
            $g1cap = 50; $g2cap = 56; $g3cap = 50; $g4cap = 64; $g5cap = 64
            $g1 = [Math]::Min($g1cap, $g1 + [int]($free2 * 0.14))
            $g2 = [Math]::Min($g2cap, $g2 + [int]($free2 * 0.16))
            $g3 = [Math]::Min($g3cap, $g3 + [int]($free2 * 0.14))
            $g4 = [Math]::Min($g4cap, $g4 + [int]($free2 * 0.24))
            $g5 = [Math]::Min($g5cap, $g5 + [int]($free2 * 0.32))
            $used = (& $sum $valueH $trackH $btnH $rangeH $g1 $g2 $g3 $g4 $g5)
            $leftover = $avail - $used
            if ($leftover -gt 0) { $padTop += [int]($leftover / 2) }
        }
    } elseif ($total -gt $avail) {
        # shrink to fit: first compress gaps, then track/buttons/range, then percent height
        $over = $total - $avail
        $gapPool = $g1 + $g2 + $g3 + $g4 + $g5
        if ($over -gt 0 -and $gapPool -gt 0) {
            $keep = [Math]::Max(0, $gapPool - $over)
            $gs = if ($gapPool -gt 0) { $keep / $gapPool } else { 0 }
            $g1 = [Math]::Max(4, [int]($g1 * $gs))
            $g2 = [Math]::Max(4, [int]($g2 * $gs))
            $g3 = [Math]::Max(4, [int]($g3 * $gs))
            $g4 = [Math]::Max(4, [int]($g4 * $gs))
            $g5 = [Math]::Max(6, [int]($g5 * $gs))
            $over = (& $sum $valueH $trackH $btnH $rangeH $g1 $g2 $g3 $g4 $g5) - $avail
        }
        if ($over -gt 0) {
            $cut = [Math]::Min($over, $trackH - 36)
            $trackH -= $cut
            $over -= $cut
        }
        if ($over -gt 0) {
            $cut = [Math]::Min($over, $btnH - 32)
            $btnH -= $cut
            $over -= $cut
        }
        if ($over -gt 0) {
            $cut = [Math]::Min($over, $rangeH - 30)
            $rangeH -= $cut
            $over -= $cut
        }
        if ($over -gt 0) {
            $valueH = [Math]::Max(52, $valueH - $over)
        }
        $final = & $sum $valueH $trackH $btnH $rangeH $g1 $g2 $g3 $g4 $g5
        if ($final -gt $avail) {
            $valueH = [Math]::Max(48, $valueH - ($final - $avail))
        }
    }

    # percent font must fit inside valueH (avoid clipping tops/bottoms of glyphs)
    $fontSize = 44
    if ($valueH -lt 58) { $fontSize = 28 }
    elseif ($valueH -lt 68) { $fontSize = 32 }
    elseif ($valueH -lt 78) { $fontSize = 36 }
    elseif ($valueH -lt 90) { $fontSize = 40 }
    elseif ($valueH -ge 170) { $fontSize = 72 }
    elseif ($valueH -ge 145) { $fontSize = 62 }
    elseif ($valueH -ge 120) { $fontSize = 52 }
    elseif ($valueH -ge 105) { $fontSize = 48 }
    if (-not $script:lblValue.Font -or [math]::Abs($script:lblValue.Font.Size - $fontSize) -gt 0.1) {
        $oldFont = $script:lblValue.Font
        $script:lblValue.Font = New-Object Drawing.Font('Consolas', $fontSize, [Drawing.FontStyle]::Bold)
        if ($oldFont) { $oldFont.Dispose() }
    }

    # scale the rest of the control fonts along with their row heights — so a
    # bigger card (larger window) reads as "bigger, comfortable UI", not
    # "same tiny text floating in bigger boxes".
    $presetFontSize = 11
    if ($btnH -ge 85) { $presetFontSize = 20 }
    elseif ($btnH -ge 70) { $presetFontSize = 17 }
    elseif ($btnH -ge 58) { $presetFontSize = 15 }
    elseif ($btnH -ge 50) { $presetFontSize = 13 }
    elseif ($btnH -ge 44) { $presetFontSize = 12 }
    foreach ($btn in $script:presetButtons) {
        if (-not $btn.Font -or [math]::Abs($btn.Font.Size - $presetFontSize) -gt 0.1) {
            $oldFont = $btn.Font
            $btn.Font = New-Object Drawing.Font('Consolas', $presetFontSize, [Drawing.FontStyle]::Bold)
            if ($oldFont) { $oldFont.Dispose() }
        }
    }

    $rangeFontSize = 9
    if ($rangeH -ge 78) { $rangeFontSize = 16 }
    elseif ($rangeH -ge 64) { $rangeFontSize = 13 }
    elseif ($rangeH -ge 50) { $rangeFontSize = 11 }
    elseif ($rangeH -ge 44) { $rangeFontSize = 10.5 }
    elseif ($rangeH -ge 40) { $rangeFontSize = 9.5 }
    if ($script:btnRange -and -not $script:btnRange.IsDisposed -and (-not $script:btnRange.Font -or [math]::Abs($script:btnRange.Font.Size - $rangeFontSize) -gt 0.1)) {
        $oldFont = $script:btnRange.Font
        $script:btnRange.Font = New-Object Drawing.Font('Microsoft YaHei', $rangeFontSize, [Drawing.FontStyle]::Bold)
        if ($oldFont) { $oldFont.Dispose() }
    }
    if ($script:btnDimMode -and -not $script:btnDimMode.IsDisposed -and (-not $script:btnDimMode.Font -or [math]::Abs($script:btnDimMode.Font.Size - $rangeFontSize) -gt 0.1)) {
        $oldFont = $script:btnDimMode.Font
        $script:btnDimMode.Font = New-Object Drawing.Font('Microsoft YaHei', $rangeFontSize, [Drawing.FontStyle]::Bold)
        if ($oldFont) { $oldFont.Dispose() }
    }

    $chkFontSize = 9.5
    if ($optH -ge 68) { $chkFontSize = 15 }
    elseif ($optH -ge 56) { $chkFontSize = 12.5 }
    elseif ($optH -ge 42) { $chkFontSize = 10.5 }
    elseif ($optH -ge 38) { $chkFontSize = 10 }
    if ($script:chkTray -and -not $script:chkTray.IsDisposed -and (-not $script:chkTray.Font -or [math]::Abs($script:chkTray.Font.Size - $chkFontSize) -gt 0.1)) {
        $oldFont = $script:chkTray.Font
        $script:chkTray.Font = New-Object Drawing.Font('Microsoft YaHei', $chkFontSize)
        if ($oldFont) { $oldFont.Dispose() }
    }
    if ($script:chkTop -and -not $script:chkTop.IsDisposed -and (-not $script:chkTop.Font -or [math]::Abs($script:chkTop.Font.Size - $chkFontSize) -gt 0.1)) {
        $oldFont = $script:chkTop.Font
        $script:chkTop.Font = New-Object Drawing.Font('Microsoft YaHei', $chkFontSize)
        if ($oldFont) { $oldFont.Dispose() }
    }
    if ($script:btnExit -and -not $script:btnExit.IsDisposed -and (-not $script:btnExit.Font -or [math]::Abs($script:btnExit.Font.Size - $chkFontSize) -gt 0.1)) {
        $oldFont = $script:btnExit.Font
        $script:btnExit.Font = New-Object Drawing.Font('Microsoft YaHei', $chkFontSize, [Drawing.FontStyle]::Bold)
        if ($oldFont) { $oldFont.Dispose() }
    }

    $keysFontSize = 8
    if ($keysH -ge 34) { $keysFontSize = 11 }
    elseif ($keysH -ge 26) { $keysFontSize = 9 }
    if ($script:lblKeys -and -not $script:lblKeys.IsDisposed -and (-not $script:lblKeys.Font -or [math]::Abs($script:lblKeys.Font.Size - $keysFontSize) -gt 0.1)) {
        $oldFont = $script:lblKeys.Font
        $script:lblKeys.Font = New-Object Drawing.Font('Microsoft YaHei', $keysFontSize)
        if ($oldFont) { $oldFont.Dispose() }
    }

    $y = $padTop

    $script:lcdPanel.SetBounds($left, $y, $innerW, $valueH)
    $y += $valueH + $g1

    $script:trackPanel.SetBounds($left - 4, $y, $innerW + 8, $trackH)
    $y += $trackH + $g2

    # preset row sits right under the slider (hw status line removed)
    $gap = $itemGap
    $n = $script:presetButtons.Count
    if ($n -lt 1) { $n = 1 }
    $btnW = [Math]::Max(64, [int](($innerW - $gap * ($n - 1)) / $n))
    $bx = $left
    foreach ($btn in $script:presetButtons) {
        $btn.SetBounds($bx, $y, $btnW, $btnH)
        $bx += $btnW + $gap
    }
    $y += $btnH + $g3

    # two half-width bars: 范围 | 模式
    $midGap = $itemGap
    $halfW = [Math]::Max(80, [int](($innerW - $midGap) / 2))
    $rightW = [Math]::Max(80, $innerW - $halfW - $midGap)
    if ($script:btnRange -and -not $script:btnRange.IsDisposed) {
        $script:btnRange.SetBounds($left, $y, $halfW, $rangeH)
    }
    if ($script:btnDimMode -and -not $script:btnDimMode.IsDisposed) {
        $script:btnDimMode.SetBounds($left + $halfW + $midGap, $y, $rightW, $rangeH)
    }
    $y += $rangeH + $g4

    # options: two toggles stacked top-to-bottom (关闭到托盘 / 窗口置顶),
    # Exit as its own full-width row below — matches the approved mockup.
    $chkH = [Math]::Min(40, 24 + [int](($optH - 36) * 0.45))
    $rowGap = 8
    $stackGap = 12
    $exitH = [Math]::Min(58, $optH)
    $script:chkTray.SetBounds($left, $y, $innerW, $chkH)
    $y += $chkH + $rowGap
    $script:chkTop.SetBounds($left, $y, $innerW, $chkH)
    $y += $chkH + $stackGap
    $script:btnExit.SetBounds($left, $y, $innerW, $exitH)
    $y += $exitH + $g5

    $script:lblKeys.SetBounds($left, $y, $innerW, $keysH)

    # header restart button docked top-right (single place; no header.Add_Resize duplicate)
    if ($script:btnRestart -and -not $script:btnRestart.IsDisposed -and $script:header -and -not $script:header.IsDisposed) {
        $rw = $script:btnRestart.Width
        $rh = $script:btnRestart.Height
        $script:btnRestart.Location = New-Object Drawing.Point(
            [Math]::Max(8, $script:header.ClientSize.Width - $rw - 28),
            [Math]::Max(8, [int](($script:header.ClientSize.Height - $rh) / 2))
        )
    }

    # force a clean repaint of the custom-drawn panels every layout pass — during
    # a live window-drag SetBounds/Dock changes alone can leave stale pixels from
    # the previous size on screen for a frame or two (looks like a duplicated /
    # split fader bar); an explicit Invalidate() guarantees a full redraw.
    if ($script:lcdPanel -and -not $script:lcdPanel.IsDisposed) { $script:lcdPanel.Invalidate() }
    if ($script:trackPanel -and -not $script:trackPanel.IsDisposed) { $script:trackPanel.Invalidate() }
    if ($script:faderTrack -and -not $script:faderTrack.IsDisposed) { $script:faderTrack.Invalidate() }
}

# body resize covers form width/height changes (header is docked); restart btn laid out here only
$script:body.Add_Resize({ Update-UiLayout })
$script:ui.Add_ResizeEnd({
    if ($script:ui.WindowState -eq 'Normal') {
        Save-DimSettings -Brightness ([int]$script:slider.Value) -CloseToTray $script:chkTray.Checked -AlwaysOnTop $script:chkTop.Checked
    }
})

# ---------- tray ----------
$script:tray = New-Object Windows.Forms.NotifyIcon
$script:tray.Icon = $script:appIcon
$script:tray.Text = "Software Dimmer"
$script:tray.Visible = $true

$menu = New-Object Windows.Forms.ContextMenuStrip
$menu.BackColor = $card
$menu.ForeColor = $text
$menu.ShowImageMargin = $false

function Add-MenuItem([string]$Label, [scriptblock]$Action) {
    $i = New-Object Windows.Forms.ToolStripMenuItem $Label
    $i.ForeColor = $text
    $i.Add_Click($Action)
    [void]$menu.Items.Add($i)
    return $i
}

Add-MenuItem '显示窗口' { Show-MainWindow }
$script:trayPresetItems = @()
foreach ($p in $script:presetsNormal) {
    # presets always carry their own "N%" label in T
    $item = Add-MenuItem $p.T {
        param($s, $e)
        Set-BrightnessValue ([int]$s.Tag) -Save
    }
    $item.Tag = $p.V
    $script:trayPresetItems += $item
}
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
Add-MenuItem '重新锁定硬件亮度' { [void](Set-HardwareBrightness100 -Force); Update-StatusLabel }
Add-MenuItem '重启' { Restart-DimmerUI }
Add-MenuItem '退出' { Exit-Dimmer }
$script:tray.ContextMenuStrip = $menu

$script:tray.Add_DoubleClick({ Show-MainWindow })

function Show-MainWindow {
    $script:ui.Show()
    $script:ui.WindowState = 'Normal'
    $script:ui.Activate()
    $script:ui.TopMost = $script:chkTop.Checked
}

function Hide-ToTray {
    # persist brightness before hide (Esc / close-to-tray both land here)
    try {
        Save-DimSettings -Brightness ([int]$script:slider.Value) -CloseToTray $script:chkTray.Checked -AlwaysOnTop $script:chkTop.Checked
    } catch {}
    $script:ui.Hide()
}

function Stop-DimmerRuntime {
    # shared teardown for exit / restart (settings already saved by caller)
    # restore Mag/Gamma first so the desktop is not left dimmed after exit
    try {
        if ($script:reassertTimer) {
            $script:reassertTimer.Stop()
            $script:reassertTimer.Dispose()
            $script:reassertTimer = $null
        }
    } catch {}
    $script:reassertQueued = $false
    $script:reassertPendingKind = $null
    try {
        if ($script:dimApplyTimer) {
            $script:dimApplyTimer.Stop()
            $script:dimApplyTimer.Dispose()
            $script:dimApplyTimer = $null
        }
    } catch {}
    $script:dimApplyQueued = $false
    $script:dimApplyPendingPct = $null
    try {
        if ($script:showTimer) {
            $script:showTimer.Stop()
            $script:showTimer.Dispose()
            $script:showTimer = $null
        }
    } catch {}
    try { Reset-ScreenFx } catch {
        try { [SoftDim.ScreenFx]::ShutdownAll() } catch {}
    }
    # Start-PowerCfgBrightness100Async intentionally leaves an in-flight call
    # alone (see its own comment) so it never orphans the runspace mid-flight.
    # But that means if one is still running when we tear down, nobody ever
    # calls EndInvoke/Dispose on it — the PowerShell instance, its runspace,
    # and the cmd.exe/powercfg.exe child it's tracking would leak silently.
    # Stop() cancels the pipeline (killing the tracked child too) so cleanup
    # here is bounded instead of blocking exit on a slow powercfg call.
    try {
        if ($script:powerCfgAsync) {
            $ps = $script:powerCfgAsync.PS
            try {
                if (-not $script:powerCfgAsync.Handle.IsCompleted) { $ps.Stop() }
                $ps.EndInvoke($script:powerCfgAsync.Handle) | Out-Null
            } catch {}
            try { $ps.Dispose() } catch {}
            $script:powerCfgAsync = $null
        }
    } catch { Write-DimLog "powerCfgAsync cleanup failed: $($_.Exception.Message)" }
    try {
        if ($script:tray) {
            $script:tray.Visible = $false
            $script:tray.Dispose()
        }
    } catch {}
    try {
        if ($script:overlay -and -not $script:overlay.IsDisposed) {
            $script:overlay.Hide(); $script:overlay.Close(); $script:overlay.Dispose()
        }
    } catch {}
    try {
        if ($script:iconHandle -ne [IntPtr]::Zero) {
            [void][SoftDim.Native]::DestroyIcon($script:iconHandle)
            $script:iconHandle = [IntPtr]::Zero
        }
    } catch {}
    try {
        foreach ($h in $script:winEventHooks) { [void][SoftDim.Native]::UnhookWinEvent($h) }
        $script:winEventHooks = @()
    } catch {}
    try {
        if ($script:displayChangedHandler) {
            [Microsoft.Win32.SystemEvents]::remove_DisplaySettingsChanged($script:displayChangedHandler)
            $script:displayChangedHandler = $null
        }
    } catch {}
    try { if ($script:cimSession) { Remove-CimSession $script:cimSession; $script:cimSession = $null } } catch {}
    try {
        if ($script:mutex) {
            $script:mutex.ReleaseMutex() | Out-Null
            $script:mutex.Dispose()
            $script:mutex = $null
        }
    } catch {}
}

function Exit-Dimmer {
    $script:exiting = $true
    Save-DimSettings -Brightness ([int]$script:slider.Value) -CloseToTray $script:chkTray.Checked -AlwaysOnTop $script:chkTop.Checked
    Stop-DimmerRuntime
    [System.Windows.Forms.Application]::Exit()
}

function Restart-DimmerUI {
    if ($script:exiting) { return }
    $script:exiting = $true
    Save-DimSettings -Brightness ([int]$script:slider.Value) -CloseToTray $script:chkTray.Checked -AlwaysOnTop $script:chkTop.Checked

    $ps1 = $script:selfPath
    if (-not $ps1 -or -not (Test-Path -LiteralPath $ps1)) {
        [System.Windows.Forms.MessageBox]::Show(
            "找不到脚本文件，无法重启。`n$ps1",
            "Software Dimmer",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        $script:exiting = $false
        return
    }

    # release single-instance lock before spawning the new process — the new
    # process does a non-blocking WaitOne(0) on the same mutex name, so it MUST
    # be free before Start-Process, or the replacement will see "already
    # running" and exit immediately. This ordering is required, not optional.
    try {
        if ($script:mutex) {
            $script:mutex.ReleaseMutex() | Out-Null
            $script:mutex.Dispose()
            $script:mutex = $null
        }
    } catch {}

    try {
        $argList = @(
            '-NoProfile'
            '-ExecutionPolicy', 'Bypass'
            '-WindowStyle', 'Hidden'
            '-STA'
            '-File', $ps1
        )
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "重启失败：`n$($_.Exception.Message)",
            "Software Dimmer",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        # Start-Process failed, so no replacement instance exists. We already
        # released the lock above — re-acquire it so this (still-running)
        # instance keeps single-instance protection instead of silently
        # losing it for the rest of the session.
        try {
            $script:mutex = New-Object System.Threading.Mutex($false, 'Local\SoftwareDimmer_SoftDim_v2')
            [void]$script:mutex.WaitOne(0)
        } catch { $script:mutex = $null }
        $script:exiting = $false
        return
    }

    Stop-DimmerRuntime
    [System.Windows.Forms.Application]::Exit()
}

function Update-StatusLabel {
    # hardware status line removed from UI; keep hook for callers
}

function Get-DimRange {
    if ($script:rangeModeExtreme) {
        return @{ Min = 0; Max = 25 }
    }
    return @{ Min = 10; Max = 100 }
}

function Get-ActivePresets {
    if ($script:rangeModeExtreme) { return $script:presetsExtreme }
    return $script:presetsNormal
}

function Update-PresetOptions {
    $defs = Get-ActivePresets
    for ($i = 0; $i -lt $script:presetButtons.Count; $i++) {
        if ($i -ge $defs.Count) { break }
        $script:presetButtons[$i].Text = $defs[$i].T
        $script:presetButtons[$i].Tag  = $defs[$i].V
    }
    if ($script:trayPresetItems) {
        for ($i = 0; $i -lt $script:trayPresetItems.Count; $i++) {
            if ($i -ge $defs.Count) { break }
            $p = $defs[$i]
            # presets always carry their own "N%" label in T
            $script:trayPresetItems[$i].Text = $p.T
            $script:trayPresetItems[$i].Tag  = $p.V
        }
    }
}

# apply restored range mode to UI + tray preset labels (buttons start as 一般 defaults)
Update-PresetOptions

function Limit-Brightness([int]$Percent) {
    $r = Get-DimRange
    if ($Percent -lt [int]$r.Min) { return [int]$r.Min }
    if ($Percent -gt [int]$r.Max) { return [int]$r.Max }
    return $Percent
}

function Set-RangeMode {
    param([switch]$Extreme)
    $script:rangeModeExtreme = [bool]$Extreme
    $cur = [int]$script:slider.Value

    if ($script:rangeModeExtreme) {
        # 极暗：0%–25%，预设 0 / 5 / 10 / 25
        if ($cur -gt 25) { $script:slider.Value = 25 }
        $script:slider.Minimum = 0
        $script:slider.Maximum = 25
        $script:slider.LargeChange = 5
        $cur = Limit-Brightness $cur
    } else {
        # 一般：10%–100%，预设 深夜/柔和/白天/全亮
        $script:slider.Maximum = 100
        if ($cur -lt 10) { $script:slider.Value = 10; $cur = 10 }
        $script:slider.Minimum = 10
        $script:slider.LargeChange = 10
        $cur = Limit-Brightness $cur
    }
    Update-RangeButton

    Update-PresetOptions

    if ($script:slider.Value -ne $cur) { $script:slider.Value = $cur }
    if ($script:faderTrack -and -not $script:faderTrack.IsDisposed) { $script:faderTrack.Invalidate() }
    Apply-Dim $cur
    Save-DimSettings -Brightness $cur -CloseToTray $script:chkTray.Checked -AlwaysOnTop $script:chkTop.Checked
}

function Set-BrightnessValue {
    param([int]$Percent, [switch]$Save)
    $v = Limit-Brightness $Percent
    if ($script:slider.Value -ne $v) {
        $script:slider.Value = $v
    } else {
        Apply-Dim $v
    }
    if ($Save) {
        Save-DimSettings -Brightness $v -CloseToTray $script:chkTray.Checked -AlwaysOnTop $script:chkTop.Checked
    }
}

function Apply-Dim([int]$Percent) {
    $Percent = Limit-Brightness $Percent
    $script:lblValue.Text = "$Percent%"
    if ($Percent -le 35) {
        $script:lblValue.ForeColor = [System.Drawing.Color]::FromArgb(255, 168, 80)
    } elseif ($Percent -le 75) {
        $script:lblValue.ForeColor = $accent
    } else {
        $script:lblValue.ForeColor = $okGreen
    }
    try {
        [void](Set-HardwareBrightness100)
    } catch {
        # overlay/hw errors are non-fatal; keep last good display
    }
    # engine call (Mag/Gamma/Overlay + tray tip) is throttled — see Request-DimApply
    Request-DimApply $Percent
}

# slider events: live overlay; persist on mouse up / key up / mouse wheel
$script:slider.Add_ValueChanged({
    Apply-Dim ([int]$script:slider.Value)
    if ($script:faderTrack -and -not $script:faderTrack.IsDisposed) { $script:faderTrack.Invalidate() }
})
$script:slider.Add_MouseUp({
    Save-DimSettings -Brightness ([int]$script:slider.Value) -CloseToTray $script:chkTray.Checked -AlwaysOnTop $script:chkTop.Checked
})
$script:slider.Add_KeyUp({
    Save-DimSettings -Brightness ([int]$script:slider.Value) -CloseToTray $script:chkTray.Checked -AlwaysOnTop $script:chkTop.Checked
})
# TrackBar wheel changes Value (→ ValueChanged) but not MouseUp/KeyUp; persist here too
$script:slider.Add_MouseWheel({
    Save-DimSettings -Brightness ([int]$script:slider.Value) -CloseToTray $script:chkTray.Checked -AlwaysOnTop $script:chkTop.Checked
})

# Form.KeyPreview does NOT guarantee arrow keys reach KeyDown: WinForms treats
# Left/Right/Up/Down as "dialog navigation keys" first (used to move focus
# between controls, e.g. inside a GroupBox), and that check happens before
# KeyDown is ever raised — regardless of KeyPreview. PreviewKeyDown is the
# officially supported way to opt back in: setting IsInputKey = $true here
# tells WinForms "treat this as a normal key", so it falls through to the
# KeyDown pipeline instead of being silently consumed as navigation.
# (The bypass itself is registered once, on the form AND every descendant
# control, via Register-ArrowKeyBypass $script:ui further down — registering
# it here too was redundant duplication and has been removed.)

# keyboard
$script:ui.Add_KeyDown({
    param($s, $e)
    $r = Get-DimRange
    $v = [int]$script:slider.Value
    switch ($e.KeyCode) {
        'Left'  { Set-BrightnessValue ([Math]::Max([int]$r.Min, $v - 5)) -Save; $e.Handled = $true }
        'Right' { Set-BrightnessValue ([Math]::Min([int]$r.Max, $v + 5)) -Save; $e.Handled = $true }
        'Down'  { Set-BrightnessValue ([Math]::Max([int]$r.Min, $v - 5)) -Save; $e.Handled = $true }
        'Up'    { Set-BrightnessValue ([Math]::Min([int]$r.Max, $v + 5)) -Save; $e.Handled = $true }
        'D1'    { $ps = Get-ActivePresets; Set-BrightnessValue ([int]$ps[0].V) -Save; $e.Handled = $true }
        'D2'    { $ps = Get-ActivePresets; Set-BrightnessValue ([int]$ps[1].V) -Save; $e.Handled = $true }
        'D3'    { $ps = Get-ActivePresets; Set-BrightnessValue ([int]$ps[2].V) -Save; $e.Handled = $true }
        'D4'    { $ps = Get-ActivePresets; Set-BrightnessValue ([int]$ps[3].V) -Save; $e.Handled = $true }
        'NumPad1' { $ps = Get-ActivePresets; Set-BrightnessValue ([int]$ps[0].V) -Save; $e.Handled = $true }
        'NumPad2' { $ps = Get-ActivePresets; Set-BrightnessValue ([int]$ps[1].V) -Save; $e.Handled = $true }
        'NumPad3' { $ps = Get-ActivePresets; Set-BrightnessValue ([int]$ps[2].V) -Save; $e.Handled = $true }
        'NumPad4' { $ps = Get-ActivePresets; Set-BrightnessValue ([int]$ps[3].V) -Save; $e.Handled = $true }
        'Escape' {
            if ($script:chkTray.Checked) { Hide-ToTray } else { Exit-Dimmer }
            $e.Handled = $true
        }
    }
})

# close -> tray or exit
$script:ui.Add_FormClosing({
    param($s, $e)
    if ($script:exiting) { return }
    if ($script:chkTray.Checked) {
        $e.Cancel = $true
        # Hide-ToTray already saves settings
        Hide-ToTray
    } else {
        $script:exiting = $true
        Save-DimSettings -Brightness ([int]$script:slider.Value) -CloseToTray $false -AlwaysOnTop $script:chkTop.Checked
        Stop-DimmerRuntime
    }
})

# maintain overlay bounds + re-lock HW periodically; keep UI above overlay
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 4000
$timer.Add_Tick({
    try {
        # Mag/Gamma: re-apply (shell/apps may clear). Overlay: only re-top the veil.
        $mode = Normalize-DimMode $script:dimMode
        if ($mode -eq 'Overlay') {
            if ($script:overlay -and -not $script:overlay.IsDisposed -and $script:overlay.Visible) {
                $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
                if ($script:overlay.Bounds -ne $b) { $script:overlay.Bounds = $b }
                Enable-ClickThrough $script:overlay
                $script:overlay.TopMost = $true
            }
        } else {
            if ($script:slider -and -not $script:slider.IsDisposed) {
                Set-OverlayBrightness ([int]$script:slider.Value)
            }
        }
        if ($script:ui.Visible -and $script:chkTop.Checked) {
            $script:ui.TopMost = $true
            [void][SoftDim.Native]::SetWindowPos(
                $script:ui.Handle, [SoftDim.Native]::HWND_TOPMOST, 0, 0, 0, 0,
                ([SoftDim.Native]::SWP_NOMOVE -bor [SoftDim.Native]::SWP_NOSIZE -bor [SoftDim.Native]::SWP_NOACTIVATE)
            )
        }
        [void](Set-HardwareBrightness100)
        if ($script:ui.Visible) { Update-StatusLabel }
    } catch {}
})
$timer.Start()

# ---------- instant re-assert on menu popups / foreground (desktop) changes ----------
# WinEvent callbacks are NOT guaranteed on the UI thread — always marshal via BeginInvoke.
# Also throttle: shell can fire many FOREGROUND events in a burst.
$EVENT_SYSTEM_FOREGROUND     = 0x0003
$EVENT_SYSTEM_MENUPOPUPSTART = 0x0006
$WINEVENT_OUTOFCONTEXT       = 0x0000
$WINEVENT_SKIPOWNPROCESS     = 0x0002

function Reassert-Overlay {
    $mode = Normalize-DimMode $script:dimMode
    if ($mode -eq 'Overlay') {
        Request-DimReassert -Kind OverlayOnly
    } else {
        Request-DimReassert -Kind Full
    }
}

# keep the delegate referenced at script scope so it isn't garbage-collected
$script:winEventDelegate = [SoftDim.WinEventDelegate]{
    param($hWinEventHook, $eventType, $hwnd, $idObject, $idChild, $dwEventThread, $dwmsEventTime)
    Reassert-Overlay
}

$script:winEventHooks = @()
foreach ($evt in @($EVENT_SYSTEM_FOREGROUND, $EVENT_SYSTEM_MENUPOPUPSTART)) {
    $h = [SoftDim.Native]::SetWinEventHook(
        $evt, $evt, [IntPtr]::Zero, $script:winEventDelegate, 0, 0,
        ($WINEVENT_OUTOFCONTEXT -bor $WINEVENT_SKIPOWNPROCESS)
    )
    if ($h -ne [IntPtr]::Zero) { $script:winEventHooks += $h }
}

# Monitor plug/unplug or resolution/DPI change: previously only the 4s poll
# noticed a stale VirtualScreen, so a newly attached monitor (or one that
# just changed resolution) could sit undimmed, or the overlay could leave a
# gap, for up to 4 seconds. SystemEvents fires this immediately.
# NOTE: SystemEvents is process-static — the handler MUST be unregistered
# (done in Stop-DimmerRuntime) or it stays rooted for the life of the
# process even after the form is disposed.
$script:displayChangedHandler = [System.EventHandler]{
    param($s, $e)
    Reassert-Overlay
}
try {
    [Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged($script:displayChangedHandler)
} catch { Write-DimLog "SystemEvents subscribe failed: $($_.Exception.Message)" }

$script:ui.Add_Shown({
    Enable-DarkTitleBar $script:ui
    Update-UiLayout
    [void]$script:overlay.Handle
    Apply-Dim ([int]$script:slider.Value)
    [void](Set-HardwareBrightness100 -Force)
    Update-StatusLabel
    # form was created with opacity 0 (set in Load) to avoid white flash; now reveal
    $script:ui.Opacity = 1
    # 启动早期（轮询定时器尚未启动）到达的第二次启动信号，在这里兜底弹出
    if ([SoftDim.Ipc]::ShowPending) {
        [SoftDim.Ipc]::ShowPending = $false
        Show-MainWindow
    }
})

$script:ui.Add_FormClosed({
    try { $timer.Stop(); $timer.Dispose() } catch {}
    # safety net if teardown skipped a path (Stop-DimmerRuntime is idempotent enough)
    try { Reset-ScreenFx } catch {
        try { [SoftDim.ScreenFx]::ShutdownAll() } catch {}
    }
})

# run message loop (needed for tray when form hidden)
$script:ui.Add_Load({
    Enable-DarkTitleBar $script:ui
    $script:ui.Opacity = 0
})
# The PreviewKeyDown hook on the Form alone is not enough: WinForms decides
# whether Left/Right/Up/Down are "dialog navigation keys" at the level of
# whichever control currently HAS FOCUS (a Button, CheckBox, etc.) — if that
# control consumes them there, the message never bubbles up to the Form at
# all, so the Form's own PreviewKeyDown/KeyDown handlers never even run.
# D1-D4 work because digits are never treated as navigation keys, so they
# always reach the Form's KeyDown — arrows are the special case. Fix: walk
# every focusable control (buttons, checkboxes, ...) and force IsInputKey
# there too, so the key always falls through to normal KeyDown handling
# instead of being silently absorbed as focus-navigation.
function Register-ArrowKeyBypass([System.Windows.Forms.Control]$Control) {
    $Control.Add_PreviewKeyDown({
        param($s, $e)
        switch ($e.KeyCode) {
            { $_ -in 'Left','Right','Up','Down' } { $e.IsInputKey = $true }
        }
    })
    foreach ($child in $Control.Controls) {
        Register-ArrowKeyBypass $child
    }
}
Register-ArrowKeyBypass $script:ui

# 第二次启动信号的消费端：一个 150ms 的轻量 UI 定时器轮询 ShowPending 标志。
# 定时器 Tick 运行在 UI 线程上（因此能正常执行 PowerShell 脚本块），真正的
# 弹窗动作在这里做。150ms 轮询开销可忽略，点图标后窗口约 100–200ms 内弹出。
# 弹窗总是在 UI 线程上，不需要跨线程 marshal。
$script:showTimer = New-Object Windows.Forms.Timer
$script:showTimer.Interval = 150
$script:showTimer.Add_Tick({
    # 退出竞态保护：退出路径上 Stop-DimmerRuntime 会停掉这个定时器，但两者之间
    # 可能还有一次 tick 撞上正在销毁的窗体——直接 return / try-catch 兜住，
    # 避免在已 Dispose 的 Form 上调用 Show() 抛未处理异常把进程带崩。
    if ($script:exiting) { return }
    if ([SoftDim.Ipc]::ShowPending) {
        [SoftDim.Ipc]::ShowPending = $false
        try {
            if ($script:ui -and -not $script:ui.IsDisposed) { Show-MainWindow }
        } catch {}
    }
})
$script:showTimer.Start()

[System.Windows.Forms.Application]::Run($script:ui)