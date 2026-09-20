# ===========================================================================
# ZZZ Sunna PerfMonitor v1.0 - anime desktop pet monitoring FPS / CPU / GPU / MEM
# ---------------------------------------------------------------------------
# PowerShell 5.1 + WPF, zero dependency.
#
# WHY THIS FILE IS PURE ASCII
#   Windows PowerShell 5.1 decodes a .ps1 file as ANSI unless it carries a UTF-8
#   BOM, so any Chinese literal written by a BOM-less editor would be corrupted.
#   This file is deliberately ASCII-only: it is encoding-proof and relocatable.
#   All Chinese UI text lives in assets/ui.json (read as UTF-8); the Chinese
#   docs live in docs/.
#
# ARCHITECTURE (v5)
#   1. Process DPI awareness (PER_MONITOR_AWARE_V2) is set BEFORE any geometry
#      is read, so every coordinate below is a real physical pixel. In v4 the
#      screen list was read while the process was still DPI-unaware and the
#      process was switched to system-aware later by WPF, which made all layout
#      math wrong by the DPI ratio on mixed-DPI desktops.
#   2. One small borderless layered window per component instead of a single
#      giant canvas. Cross-monitor dragging becomes trivial, each window is
#      rendered at its own monitor DPI, and the DWM surface stays tiny.
#   3. Windows are positioned/sized with Win32 SetWindowPos in physical pixels;
#      WPF content is sized in DIPs by dividing by the target monitor scale.
#   4. Emotion is data driven (state machine + hysteresis), not random.
#   5. Component paths are derived from $PSScriptRoot: no hard-coded drive.
#
# AUTOMATION HOOK
#   Writing one line to runtime/petcmd.txt makes the running pet execute it:
#     quit | say | state | diag | shot | reload | reset | menu | linetest | geom |
#     monrefresh | rtss | saytext:<t> | sayfrom:<pool> | pose:<name> | screen:<idx> |
#     uclick:<comp> | udrag:<comp>:<dx>:<dy> | uwheel:<delta> | hittest:<comp>
#   Used by tools/smoke_test.ps1 and usable for manual checks.
# ===========================================================================
param()
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# 0. DPI awareness must be established before ANY screen geometry is queried.
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class WpmDpi {
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
  [DllImport("shcore.dll")] public static extern int GetProcessDpiAwareness(IntPtr h, out int v);
  [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr m, int t, out uint x, out uint y);
  [DllImport("shcore.dll")] public static extern int GetDpiForWindow(IntPtr h);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT p, uint f);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool EnumWindows(Cb c, IntPtr d);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);

  public delegate bool Cb(IntPtr h, IntPtr d);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }

  public const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010;

  public static string Awareness() {
    int a; GetProcessDpiAwareness(GetCurrentProcess(), out a);
    return a == 0 ? "UNAWARE" : (a == 1 ? "SYSTEM" : "PERMON");
  }
  // effective DPI scale of the monitor nearest to a physical point
  public static double ScaleAt(int x, int y) {
    IntPtr m = MonitorFromPoint(new POINT { X = x, Y = y }, 2);
    if (m == IntPtr.Zero) return 1.0;
    uint dx, dy;
    if (GetDpiForMonitor(m, 0, out dx, out dy) != 0 || dx == 0) return 1.0;
    return dx / 96.0;
  }
  public static int[] Cursor() {
    POINT p;
    if (!GetCursorPos(out p)) return new int[] { 0, 0 };
    return new int[] { p.X, p.Y };
  }
  // physical move/resize, never activating the window
  public static void Move(IntPtr h, int x, int y, int w, int h2) {
    if (h == IntPtr.Zero) return;
    SetWindowPos(h, IntPtr.Zero, x, y, w, h2, SWP_NOZORDER | SWP_NOACTIVATE);
  }
  public static void Top(IntPtr h) {
    if (h == IntPtr.Zero) return;
    SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE);
  }
  public static IntPtr FindByTitlePrefix(string prefix) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr d) {
      if (!IsWindowVisible(h)) return true;
      StringBuilder sb = new StringBuilder(256);
      GetWindowTextW(h, sb, 256);
      if (sb.Length > 0 && sb.ToString().StartsWith(prefix)) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static void Raise(IntPtr h) {
    if (h == IntPtr.Zero) return;
    SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE);
    SetForegroundWindow(h);
  }
  // WS_EX_TOOLWINDOW: keep the component windows out of the taskbar and Alt+Tab
  public static void NoTaskbar(IntPtr h) {
    if (h == IntPtr.Zero) return;
    try {
      int ex = GetWindowLong(h, -20);
      if ((ex & 0x80) == 0) SetWindowLong(h, -20, ex | 0x80);
    } catch { }
  }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT rc);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT rc);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  public static string RectInfo(IntPtr h) {
    if (h == IntPtr.Zero) return "no-hwnd";
    RECT w, c;
    if (!GetWindowRect(h, out w)) return "rect-fail";
    GetClientRect(h, out c);
    return string.Format("win={0},{1} {2}x{3} client={4}x{5}",
      w.Left, w.Top, w.Right - w.Left, w.Bottom - w.Top, c.Right - c.Left, c.Bottom - c.Top);
  }
}
'@

$dpiCtx = [IntPtr](-4)   # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
$dpiOk = $false
try { $dpiOk = [WpmDpi]::SetProcessDpiAwarenessContext($dpiCtx) } catch { $dpiOk = $false }
if (-not $dpiOk) {
  try {
    if ([WpmDpi]::SetProcessDpiAwareness(2) -ne 0) { [void][WpmDpi]::SetProcessDpiAwareness(1) }
  } catch { }
}
$script:DpiState = [WpmDpi]::Awareness()

# ---------------------------------------------------------------------------
# 1. paths (derived, no hard coded drive), logging, pid file
# ---------------------------------------------------------------------------
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script:Root   = $Root
$script:Assets = Join-Path $Root 'assets'
$script:WpmD   = Join-Path $script:Assets 'wpm'
$script:SprD   = Join-Path $script:Assets 'sprites'
$script:Run    = Join-Path $Root 'runtime'
$script:Log    = Join-Path $script:Run 'pet.log'
$script:PidF   = Join-Path $script:Run 'pet.pid'
$script:CfgF   = Join-Path $Root 'config.json'
$script:CmdF   = Join-Path $script:Run 'petcmd.txt'
$script:ShotD  = Join-Path $script:Run 'shots'
$script:LinesF = Join-Path $script:Assets 'lines.json'
$script:UiF    = Join-Path $script:Assets 'ui.json'

foreach ($d in @($script:Run, $script:ShotD)) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Log([string]$m) {
  try { Add-Content -Path $script:Log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8 } catch { }
}
# log rotation: keep one previous generation
if (Test-Path $script:Log) {
  try {
    if ((Get-Item $script:Log -ErrorAction Stop).Length -gt 1MB) {
      Move-Item -Path $script:Log -Destination ($script:Log + '.old') -Force
    }
  } catch { }
}

# ---------------------------------------------------------------------------
# 2. single instance
#    Take the mutex, then ALWAYS reap every other instance of this project.
#    Holding the mutex means no other instance can still be legitimate, so the
#    reap is unconditionally correct -- and it closes the hole that let two
#    instances coexist (two live instances fight over the 5s topmost re-assert,
#    so a click's down and up land on different windows and NOTHING reacts).
#    The polite path (ask it to quit) is still tried first so a normal restart
#    is graceful.
# ---------------------------------------------------------------------------
$script:MutexName = 'Global\ZZZSunnaPerfMon_Mutex_v1'
$mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
$acquired = $false
$asked = $false
for ($i = 0; $i -lt 30 -and -not $acquired; $i++) {
  try { $acquired = $mutex.WaitOne(200, $false) }
  catch [System.Threading.AbandonedMutexException] { $acquired = $true; Log 'mutex was abandoned by a crashed instance -> acquired' }
  if (-not $acquired -and -not $asked) {
    $asked = $true
    Log 'another instance is running -> asking it to quit (double launch = restart)'
    try { Set-Content -Path $script:CmdF -Value 'quit' -Encoding UTF8 } catch { }
  }
}
if (-not $acquired) {
  Log 'running instance did not quit -> forcing it down'
}
for ($j = 0; $j -lt 15 -and -not $acquired; $j++) {
  Start-Sleep -Milliseconds 300
  try { $acquired = $mutex.WaitOne(200, $false) }
  catch [System.Threading.AbandonedMutexException] { $acquired = $true }
}
if (-not $acquired) {
  Log 'could not take over after a forced shutdown -> raising the existing windows and exiting'
  [WpmDpi]::Raise([WpmDpi]::FindByTitlePrefix('WpmV1|pet'))
  exit 0
}
# mutex held: any other pet.ps1 of this project is stale by definition
Start-Sleep -Milliseconds 200
$reaped = 0
try {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.ProcessId -ne $PID -and $_.CommandLine -like '*pet.ps1*' -and
      ($_.CommandLine -like ('*' + $Root + '*') -or $_.CommandLine -like '*C:\wpm\pet.ps1*')
    } |
    ForEach-Object {
      Log ("reaping other pet instance pid=" + $_.ProcessId)
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
      $reaped++
    }
} catch { }
if ($reaped -gt 0) {
  Start-Sleep -Milliseconds 600
  $left = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*pet.ps1*' -and ($_.CommandLine -like ('*' + $Root + '*') -or $_.CommandLine -like '*C:\wpm\pet.ps1*') })
  Log ("reaped {0} stale instance(s); remaining others = {1}" -f $reaped, $left.Count)
}
try { Set-Content -Path $script:PidF -Value ([string]$PID) -Encoding ASCII } catch { }

# ---------------------------------------------------------------------------
# 3. WPF assemblies, UI text pack, config
# ---------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:UI = @{}
if (Test-Path $script:UiF) {
  try {
    $uj = Get-Content $script:UiF -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $uj.PSObject.Properties) { $script:UI[$p.Name] = $p.Value }
  } catch { Log ("ui.json parse fail: " + $_.Exception.Message) }
}
function U([string]$key, [string]$fallback) {
  if ($script:UI.ContainsKey($key)) { return [string]$script:UI[$key] }
  return $fallback
}
function UArr([string]$key, [string[]]$fallback) {
  if ($script:UI.ContainsKey($key)) {
    $v = @($script:UI[$key])
    if ($v.Count -gt 0) { return $v }
  }
  return $fallback
}

function C([string]$hex) { return [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString($hex) }
function New-Text([string]$t, [double]$size, [string]$fg, [string]$weight) {
  $tb = New-Object System.Windows.Controls.TextBlock
  $tb.Text = $t
  $tb.FontSize = $size
  $tb.FontFamily = New-Object System.Windows.Media.FontFamily("Microsoft YaHei UI")
  $tb.Foreground = (C $fg)
  $tb.HorizontalAlignment = 'Center'
  if ($weight) { $tb.FontWeight = $weight }
  return $tb
}
function New-Image() {
  $im = New-Object System.Windows.Controls.Image
  $im.Stretch = 'Fill'
  $im.Cursor = 'Hand'
  return $im
}
function Load-Bmp([string]$path, [int]$decodeW) {
  if (-not (Test-Path $path)) { return $null }
  try {
    $b = New-Object System.Windows.Media.Imaging.BitmapImage
    $b.BeginInit()
    $b.CacheOption = 'OnLoad'
    if ($decodeW -gt 0) { $b.DecodePixelWidth = $decodeW }
    $b.UriSource = New-Object Uri($path)
    $b.EndInit()
    $b.Freeze()
    return $b
  } catch { return $null }
}
function Pick-Random($arr) {
  $a = @($arr)
  if ($a.Count -eq 0) { return '' }
  return [string]$a[(Get-Random -Maximum $a.Count)]
}

# ---------------------------------------------------------------------------
# 4. C# engine: RTSS / CPU / MEM / GPU(NVML) / monitors
# ---------------------------------------------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class WhalePerf {
  // ---- Win32 ----
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern IntPtr OpenFileMapping(uint acc, bool inh, string name);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern IntPtr MapViewOfFile(IntPtr h, uint acc, uint hi, uint lo, uint size);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool UnmapViewOfFile(IntPtr p);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user);
  [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern IntPtr LoadLibraryW(string name);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr GetProcAddress(IntPtr h, string proc);
  [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonProc proc, IntPtr data);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetMonitorInfoW(IntPtr hMon, ref MONITORINFOEXW mi);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplaySettingsW(string deviceName, int modeNum, ref DEVMODEW dm);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc proc, IntPtr data);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, ref RECTS rect);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();

  public delegate bool MonProc(IntPtr hMon, IntPtr hdc, IntPtr rect, IntPtr data);
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr data);

  [StructLayout(LayoutKind.Sequential)] public struct FILETIME { public uint lo; public uint hi; }
  [StructLayout(LayoutKind.Sequential)] public struct RECTS { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential)]
  public struct MEMORYSTATUSEX {
    public uint dwLength; public uint dwMemoryLoad; public ulong ullTotalPhys; public ulong ullAvailPhys;
    public ulong ullTotalPageFile; public ulong ullAvailPageFile; public ulong ullTotalVirtual;
    public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct MONITORINFOEXW {
    public uint cbSize; public RECTS rcMonitor; public RECTS rcWork; public uint dwFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DEVMODEW {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public ushort dmSpecVersion; public ushort dmDriverVersion; public ushort dmSize; public ushort dmDriverExtra;
    public uint dmFields; public int dmPositionX; public int dmPositionY; public uint dmDisplayOrientation; public uint dmDisplayFixedOutput;
    public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public ushort dmLogPixels; public uint dmBitsPerPel; public uint dmPelsWidth; public uint dmPelsHeight;
    public uint dmDisplayFlags; public uint dmDisplayFrequency;
    public uint dmICMMethod; public uint dmICMIntent; public uint dmMediaType; public uint dmDitherType;
    public uint dmReserved1; public uint dmReserved2; public uint dmPanningWidth; public uint dmPanningHeight;
  }
  // ---- NVML ----
  [StructLayout(LayoutKind.Sequential)] public struct NVML_UTIL { public uint gpu; public uint memory; }
  delegate int dNvInit();
  delegate int dNvHandle(uint idx, out IntPtr dev);
  delegate int dNvUtil(IntPtr dev, ref NVML_UTIL u);

  static ulong ft64(FILETIME f) { return ((ulong)f.hi << 32) | f.lo; }

  // ---- published state ----
  public static double Fps = -1;
  public static double Cpu = 0;
  public static double Gpu = 0;
  public static int Mem = 0;
  public static bool RtssOk = false;
  public static bool InGame = false;
  public static string FpsApp = "";
  public static string GpuSrc = "none";
  public static bool NvmlOk = false;
  public static int ScreenIndex = 0;
  public static int DetectHow = 0;        // 1 = foreground app, 2 = coverage fallback, 0 = desktop mode
  public static int RtssVer = 0, RtssEntrySize = 0, RtssCount = 0, RtssFgPid = 0;
  public static int MonCount = 0;
  public static int[] MonX = new int[8];  public static int[] MonY = new int[8];
  public static int[] MonW = new int[8];  public static int[] MonH = new int[8];
  public static int[] MonWX = new int[8]; public static int[] MonWY = new int[8];
  public static int[] MonWW = new int[8]; public static int[] MonWH = new int[8];
  public static int[] MonPrim = new int[8];
  public static double[] MonHz = new double[8];
  public static string[] MonName = new string[8];

  // ---- RTSS app entries (sorted by fps desc) ----
  static int[] sPid = new int[256];
  static double[] sFps = new double[256];
  static string[] sPath = new string[256];
  static int sCount = 0;
  static ulong pi = 0, pk = 0, pu = 0;
  static int gpuBusy = 0;
  static IntPtr nvmlLib = IntPtr.Zero, nvmlDev = IntPtr.Zero;
  static int nvmlState = 0;   // 0 untried, 1 up, 2 unavailable
  static dNvInit fInit; static dNvHandle fHandle; static dNvUtil fUtil;
  static Timer fastT, gpuT;

  static bool IsBrowser(string p) {
    string s = (p == null ? "" : p.ToLowerInvariant());
    return s.Contains("msedge") || s.Contains("chrome") || s.Contains("firefox") || s.Contains("opera")
        || s.Contains("brave") || s.Contains("vivaldi") || s.Contains("browser");
  }

  // ------------------------------------------------------------------
  // monitors: ordered primary-first then by physical X ascending.
  // Because the process is per-monitor DPI aware these rects are physical.
  // ------------------------------------------------------------------
  static MONITORINFOEXW[] sMi = new MONITORINFOEXW[8];
  static IntPtr[] sMonH = new IntPtr[8];
  static int sMonN = 0;
  static readonly MonProc sMonCb = new MonProc(MonCb);

  static bool MonCb(IntPtr hMon, IntPtr hdc, IntPtr rect, IntPtr data) {
    if (sMonN < 8) {
      MONITORINFOEXW mi = new MONITORINFOEXW();
      mi.cbSize = (uint)Marshal.SizeOf(typeof(MONITORINFOEXW));
      if (GetMonitorInfoW(hMon, ref mi)) {
        sMi[sMonN] = mi; sMonH[sMonN] = hMon; sMonN++;
      }
    }
    return true;
  }

  static double RefreshOf(string device) {
    try {
      DEVMODEW dm = new DEVMODEW();
      dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODEW));
      if (EnumDisplaySettingsW(device, -1, ref dm) && dm.dmDisplayFrequency > 20) return dm.dmDisplayFrequency;
    } catch { }
    return -1;
  }

  public static void EnumMonitors() {
    // called both from the sampling timer and from the UI thread at startup:
    // without the lock the shared static monitor arrays tear and a monitor can
    // be counted twice (observed: "3 physical screens" reported as 5).
    lock (monLock) { EnumMonitorsLocked(); }
  }
  static readonly object monLock = new object();
  public static string[] MonSnapshot() {
    lock (monLock) {
      string[] o = new string[MonCount];
      for (int k = 0; k < MonCount; k++) {
        o[k] = string.Format("{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}",
          MonName[k], MonX[k], MonY[k], MonW[k], MonH[k], MonWX[k], MonWY[k], MonWW[k], MonWH[k], MonPrim[k], MonHz[k]);
      }
      return o;
    }
  }
  static void EnumMonitorsLocked() {
    try {
      sMonN = 0;
      EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, sMonCb, IntPtr.Zero);
      int[] order = new int[8]; int n = 0;
      for (int i = 0; i < sMonN; i++) if ((sMi[i].dwFlags & 1) != 0) order[n++] = i;   // primary first
      int primCount = n;
      for (int i = 0; i < sMonN; i++) {
        if ((sMi[i].dwFlags & 1) != 0) continue;
        int pos = n;
        while (pos > primCount && sMi[order[pos - 1]].rcMonitor.Left > sMi[i].rcMonitor.Left) { order[pos] = order[pos - 1]; pos--; }
        if (pos < 8) { order[pos] = i; n++; }
      }
      if (n > sMonN) { n = sMonN; }   // never report more monitors than were enumerated
      MonCount = n;
      // sMonH is filled in ENUMERATION order but every info array below is
      // read via order[].  Reorder the handles too, or DetectMode compares the
      // game window against the WRONG monitor whenever enumeration does not
      // start with the primary (observed 2026-09-17: game on primary shown as
      // daily 160 on idx0 while idx2 tested positive - EnumDisplayMonitors
      // returned left, right, primary).
      IntPtr[] tmpH = new IntPtr[8];
      for (int k = 0; k < n; k++) tmpH[k] = sMonH[order[k]];
      for (int k = 0; k < n; k++) sMonH[k] = tmpH[k];
      for (int k = 0; k < n; k++) {
        MONITORINFOEXW m = sMi[order[k]];
        MonX[k] = m.rcMonitor.Left; MonY[k] = m.rcMonitor.Top;
        MonW[k] = m.rcMonitor.Right - m.rcMonitor.Left; MonH[k] = m.rcMonitor.Bottom - m.rcMonitor.Top;
        MonWX[k] = m.rcWork.Left; MonWY[k] = m.rcWork.Top;
        MonWW[k] = m.rcWork.Right - m.rcWork.Left; MonWH[k] = m.rcWork.Bottom - m.rcWork.Top;
        MonPrim[k] = ((m.dwFlags & 1) != 0) ? 1 : 0;
        MonName[k] = m.szDevice;
        MonHz[k] = RefreshOf(m.szDevice);
      }
    } catch { }
  }
  public static IntPtr MonHandle(int idx) {
    try { if (idx >= 0 && idx < MonCount) return sMonH[idx]; } catch { }
    return IntPtr.Zero;
  }

  // ------------------------------------------------------------------
  // RTSS shared memory.  Offsets verified against the vendor SDK header
  // (RTSSSharedMemory.h, shipped with RTSS in SDK/Include):
  //   header : +0 signature 'RTSS', +4 version, +8 appEntrySize,
  //            +12 appArrOffset, +16 appArrSize, +68 lastForegroundPid
  //   entry  : +0 pid, +4 char szName[260], +264 flags,
  //            +268 time0, +272 time1, +276 frames
  //   fps    = 1000 * frames / (time1 - time0)
  // ------------------------------------------------------------------
  static void ReadRtss() {
    sCount = 0; RtssFgPid = 0;
    IntPtr h = OpenFileMapping(0x0004, false, "RTSSSharedMemoryV2");
    if (h == IntPtr.Zero) { RtssOk = false; return; }
    IntPtr p = MapViewOfFile(h, 0x0004, 0, 0, 0);
    if (p == IntPtr.Zero) { CloseHandle(h); RtssOk = false; return; }
    try {
      if (Marshal.ReadInt32(p, 0) != 0x52545353) { RtssOk = false; return; }
      RtssOk = true;
      RtssVer = Marshal.ReadInt32(p, 4);
      RtssEntrySize = Marshal.ReadInt32(p, 8);
      int aoff = Marshal.ReadInt32(p, 12);
      RtssCount = Marshal.ReadInt32(p, 16);
      RtssFgPid = Marshal.ReadInt32(p, 68);
      if (RtssFgPid < 0) RtssFgPid = 0;
      if (RtssEntrySize < 300 || RtssEntrySize > 65536 || aoff <= 0) { RtssOk = false; return; }
      for (int i = 0; i < RtssCount && i < 256; i++) {
        IntPtr e = (IntPtr)((long)p + aoff + (long)i * RtssEntrySize);
        int pid = Marshal.ReadInt32(e, 0);
        if (pid <= 0) continue;
        int t0 = Marshal.ReadInt32(e, 268);
        int t1 = Marshal.ReadInt32(e, 272);
        int fr = Marshal.ReadInt32(e, 276);
        if (t1 <= t0 || t1 - t0 > 100000) continue;
        double fps = 1000.0 * fr / (t1 - t0);
        if (fps <= 0 || fps >= 2000) continue;
        StringBuilder nm = new StringBuilder(64);
        for (int c = 0; c < 259; c++) {
          byte b = Marshal.ReadByte(e, 4 + c);
          if (b == 0) break;
          if (b >= 0x20 && b < 0x7F) nm.Append((char)b);
        }
        if (sCount < 256) { sPid[sCount] = pid; sFps[sCount] = fps; sPath[sCount] = nm.ToString(); sCount++; }
      }
      // sort by fps desc: candidate picking must not depend on RTSS slot order
      for (int a = 0; a < sCount - 1; a++) {
        for (int b = a + 1; b < sCount; b++) {
          if (sFps[b] > sFps[a]) {
            double tf = sFps[a]; sFps[a] = sFps[b]; sFps[b] = tf;
            int tp = sPid[a]; sPid[a] = sPid[b]; sPid[b] = tp;
            string ts = sPath[a]; sPath[a] = sPath[b]; sPath[b] = ts;
          }
        }
      }
    } catch { RtssOk = false; }
    finally { UnmapViewOfFile(p); CloseHandle(h); }
  }

  static uint sTargetPid = 0;
  static IntPtr sBestWin = IntPtr.Zero;
  static int sBestArea = 0;
  static readonly EnumWindowsProc sWinCb = new EnumWindowsProc(WinCb);

  static bool WinCb(IntPtr hWnd, IntPtr data) {
    uint pid; GetWindowThreadProcessId(hWnd, out pid);
    if ((int)pid == sTargetPid && IsWindowVisible(hWnd)) {
      RECTS r = new RECTS();
      if (GetWindowRect(hWnd, ref r)) {
        int wd = r.Right - r.Left, ht = r.Bottom - r.Top;
        int area = wd * ht;
        if (area > sBestArea && wd >= 200 && ht >= 200) { sBestArea = area; sBestWin = hWnd; }
      }
    }
    return true;
  }
  static IntPtr LargestWindow(uint pid) {
    sTargetPid = pid; sBestWin = IntPtr.Zero; sBestArea = 0;
    EnumWindows(sWinCb, IntPtr.Zero);
    return sBestWin;
  }

  // ------------------------------------------------------------------
  // mode: is the selected monitor driven by a hooked 3D application?
  //  1. trust RTSS lastForegroundPid when that process has a window on it
  //  2. otherwise first entry (fps desc) whose window is foreground or
  //     covers >= 35% of the monitor
  // ------------------------------------------------------------------
  public static void DetectMode() {
    try {
      EnumMonitors();
      int idx = ScreenIndex;
      if (idx < 0 || idx >= MonCount) idx = 0;
      IntPtr target = MonHandle(idx);
      bool inGame = false; double gf = -1; string app = ""; int how = 0;
      if (target != IntPtr.Zero) {
        if (RtssFgPid > 0) {
          for (int i = 0; i < sCount; i++) {
            if (sPid[i] != RtssFgPid) continue;
            if (!IsBrowser(sPath[i])) {
              IntPtr w = LargestWindow((uint)sPid[i]);
              if (w != IntPtr.Zero && MonitorFromWindow(w, 2) == target) { inGame = true; gf = sFps[i]; app = sPath[i]; how = 1; }
            }
            break;
          }
        }
        if (!inGame) {
          double monArea = (double)MonW[idx] * MonH[idx];
          IntPtr fg = GetForegroundWindow();
          for (int i = 0; i < sCount; i++) {
            if (IsBrowser(sPath[i])) continue;
            IntPtr w = LargestWindow((uint)sPid[i]);
            if (w == IntPtr.Zero || MonitorFromWindow(w, 2) != target) continue;
            RECTS r = new RECTS();
            if (!GetWindowRect(w, ref r)) continue;
            double area = (double)(r.Right - r.Left) * (r.Bottom - r.Top);
            if (w == fg || (monArea > 0 && area >= 0.35 * monArea)) { inGame = true; gf = sFps[i]; app = sPath[i]; how = 2; break; }
          }
        }
      }
      InGame = inGame; FpsApp = app; DetectHow = how;
      // honest data: when RTSS is down the refresh rate is NOT a measured
      // framerate - report -1 so the panel shows '--' and lines pick 'nortss'
      Fps = !RtssOk ? -1 : (inGame ? Math.Round(gf, 0) : MonHz[idx]);
    } catch { InGame = false; DetectHow = 0; }
  }

  public static void SetScreenIndex(int i) { ScreenIndex = i; }

  // ---- CPU / MEM ----
  static void FastTick(object o) {
    try {
      ReadRtss();
      DetectMode();
      FILETIME i, k, u;
      if (GetSystemTimes(out i, out k, out u)) {
        ulong ci = ft64(i), ck = ft64(k), cu = ft64(u);
        if (pi != 0) {
          ulong dk = ck - pk, du = cu - pu, di = ci - pi;
          ulong total = dk + du;
          if (total > 0) Cpu = Math.Round(100.0 * (total - di) / total, 0);
        }
        pi = ci; pk = ck; pu = cu;
      }
      MEMORYSTATUSEX m = new MEMORYSTATUSEX();
      m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
      if (GlobalMemoryStatusEx(ref m)) Mem = (int)m.dwMemoryLoad;
    } catch { }
  }

  // ---- GPU: NVML first (no process spawn), nvidia-smi as fallback ----
  static bool NvmlUp() {
    if (nvmlState == 1) return true;
    if (nvmlState == 2) return false;
    try {
      IntPtr h = LoadLibraryW("nvml.dll");
      if (h == IntPtr.Zero) h = LoadLibraryW("C:\\Program Files\\NVIDIA Corporation\\NVSMI\\nvml.dll");
      if (h == IntPtr.Zero) { nvmlState = 2; return false; }
      IntPtr pInit = GetProcAddress(h, "nvmlInit_v2");
      if (pInit == IntPtr.Zero) pInit = GetProcAddress(h, "nvmlInit");
      IntPtr pHandle = GetProcAddress(h, "nvmlDeviceGetHandleByIndex_v2");
      IntPtr pUtil = GetProcAddress(h, "nvmlDeviceGetUtilizationRates");
      if (pInit == IntPtr.Zero || pHandle == IntPtr.Zero || pUtil == IntPtr.Zero) { nvmlState = 2; return false; }
      fInit = (dNvInit)Marshal.GetDelegateForFunctionPointer(pInit, typeof(dNvInit));
      fHandle = (dNvHandle)Marshal.GetDelegateForFunctionPointer(pHandle, typeof(dNvHandle));
      fUtil = (dNvUtil)Marshal.GetDelegateForFunctionPointer(pUtil, typeof(dNvUtil));
      if (fInit() != 0) { nvmlState = 2; return false; }
      IntPtr dev;
      if (fHandle(0, out dev) != 0) { nvmlState = 2; return false; }
      nvmlDev = dev; nvmlLib = h; nvmlState = 1;
      return true;
    } catch { nvmlState = 2; return false; }
  }

  static void GpuTick(object o) {
    if (Interlocked.Exchange(ref gpuBusy, 1) == 1) return;   // never overlap samples
    try {
      if (NvmlUp()) {
        NVML_UTIL u = new NVML_UTIL();
        if (fUtil(nvmlDev, ref u) == 0) { Gpu = u.gpu; GpuSrc = "nvml"; NvmlOk = true; return; }
        nvmlState = 2; NvmlOk = false;
      }
      ProcessStartInfo psi = new ProcessStartInfo();
      psi.FileName = "nvidia-smi.exe";
      psi.Arguments = "--query-gpu=utilization.gpu --format=csv,noheader,nounits";
      psi.UseShellExecute = false;
      psi.RedirectStandardOutput = true;
      psi.CreateNoWindow = true;
      Process p = Process.Start(psi);
      if (p == null) return;
      string outp = "";
      System.Threading.Tasks.Task<string> t = p.StandardOutput.ReadToEndAsync();
      if (t.Wait(2500)) outp = t.Result;
      if (!p.WaitForExit(500)) { try { p.Kill(); } catch { } }
      int v;
      if (Int32.TryParse(outp.Trim().Split(',')[0], out v)) { Gpu = v; GpuSrc = "smi"; }
    } catch { }
    finally { Interlocked.Exchange(ref gpuBusy, 0); }
  }

  public static void Start(int fastMs, int gpuMs) {
    fastT = new Timer(FastTick, null, 0, fastMs);
    gpuT = new Timer(GpuTick, null, 200, gpuMs);
  }
  public static void Stop() {
    if (fastT != null) fastT.Dispose();
    if (gpuT != null) gpuT.Dispose();
  }
}
'@

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;

public class WpmClip {
  public BitmapSource[] Frames;
  public int Width; public int Height; public int Fps;
  public static int[] Peek(string path) {
    try {
      byte[] d = new byte[20];
      using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read)) {
        if (fs.Read(d, 0, 20) < 20) return null;
      }
      if (d[0] != (byte)87 || d[1] != (byte)80 || d[2] != (byte)77 || d[3] != (byte)86) return null;
      return new int[] { BitConverter.ToInt32(d, 4), BitConverter.ToInt32(d, 8), BitConverter.ToInt32(d, 12), BitConverter.ToInt32(d, 16) };
    } catch { return null; }
  }
  public static WpmClip Load(string path) {
    try {
      byte[] d = File.ReadAllBytes(path);
      if (d.Length < 20) return null;
      if (d[0] != (byte)87 || d[1] != (byte)80 || d[2] != (byte)77 || d[3] != (byte)86) return null;
      int fps = BitConverter.ToInt32(d, 4);
      int n = BitConverter.ToInt32(d, 8);
      int w = BitConverter.ToInt32(d, 12);
      int h = BitConverter.ToInt32(d, 16);
      if (n <= 0 || w <= 0 || h <= 0) return null;
      WpmClip c = new WpmClip();
      c.Fps = fps; c.Width = w; c.Height = h;
      int stride = w * 4;
      int frameBytes = stride * h;
      int avail = (d.Length - 20) / frameBytes;
      if (avail < n) n = avail;
      c.Frames = new BitmapSource[n];
      GCHandle gh = GCHandle.Alloc(d, GCHandleType.Pinned);
      try {
        IntPtr basePtr = gh.AddrOfPinnedObject();
        for (int i = 0; i < n; i++) {
          IntPtr p2 = new IntPtr(basePtr.ToInt64() + 20 + i * frameBytes);
          BitmapSource bs = BitmapSource.Create(w, h, 96, 96, PixelFormats.Bgra32, null, p2, frameBytes, stride);
          bs.Freeze();
          c.Frames[i] = bs;
        }
      } finally { gh.Free(); }
      return c;
    } catch { return null; }
  }
}
'@ -ReferencedAssemblies PresentationCore, WindowsBase, System

# ---------------------------------------------------------------------------
# 5. config (v5 schema) + one-shot migration from the v4 layout space
# ---------------------------------------------------------------------------
# component rosters: Comps5 = positioned by the layout system, CompsAll adds
# the bubble (which follows the pet and is never dragged/scaled directly)
$script:Comps5 = @('pet', 'panel', 'guitar', 'easel', 'bchan')
$script:CompsAll = @('pet', 'panel', 'guitar', 'easel', 'bchan', 'bubble')
$script:Def = [ordered]@{
  pet    = @{ h = 300.0;  ar = 0.0;    labelMinW = 0.0 }
  panel  = @{ h = 79.07;  ar = 4.5529; labelMinW = 0.0 }
  guitar = @{ h = 150.0;  ar = 0.7247; labelMinW = 0.0 }
  easel  = @{ h = 200.0;  ar = 0.5783; labelMinW = 0.0 }
  bchan  = @{ h = 95.0;   ar = 0.75;   labelMinW = 72.0; extra = 26.0 }
  # bubble.ins = the art's inner (writable) box measured from bubble_fill.png:
  # left 10.3% / right 10.0% / top 16.1% / bottom 10.9% of 2912x1440, converted
  # to design px at s=1 and padded a little on the bottom to clear the tail.
  bubble = @{ h = 106.26; ar = 2.0222; labelMinW = 0.0; ins = @{ l = 20.0; t = 15.0; r = 19.0; b = 17.0 } }
}
# Layout model (v6): $script:Base holds the persisted arrangement (each
# component's absolute position and its own scale), $script:GroupScale is the
# single global scale the wheel drives, and $script:Layout is the derived
# runtime geometry. Positions are FIXED: dragging moves the whole arrangement
# as one rigid body, the wheel scales it about the pet's top-left corner. There
# is deliberately no per-component move/scale and no lock toggle any more.
$script:Layout = @{}
$script:Base = @{}
foreach ($k in $script:CompsAll) {
  $script:Layout[$k] = @{ x = 0.0; y = 0.0; s = 1.0 }
  $script:Base[$k] = @{ x = 0.0; y = 0.0; s = 1.0 }
}
$script:GroupScale = 1.0
$script:UntopInGame = $false   # opt-in: drop topmost while a game is detected
$script:AppliedTop = $null     # last topmost state actually applied to windows
$script:BubbleDy = 105.0
$script:Side = 'R'
$script:Topmost = $true
$script:ScreenIdx = 0
$script:RotateSec = 60
$script:Emo = [ordered]@{
  celebrateFps = 90; worriedGpu = 85; worriedCpu = 88; worriedMem = 92;
  thinkFpsMax = 35; thinkLoad = 55; busyLoad = 60; idleLoad = 15;
  nightStart = 23; nightEnd = 7; holdTicks = 3; minDwellSec = 20; evalSec = 2
}
$script:StatePoses = @{
  happy    = @('celebrate', 'cheer')
  worried  = @('surprised')
  thinking = @('thinking')
  idle     = @('idle')
  sleepy   = @('sleepy')
  asleep   = @('sleeping')
}
$script:CfgVer = 6
# manual pose selection: a click on the character cycles this list and the
# emotion machine leaves the choice alone until the emotion state itself changes
$script:PoseList = @('idle', 'celebrate', 'cheer', 'thinking', 'surprised', 'sleepy', 'sleeping')
$script:ManualPose = $false
$script:ManualAt = 0

function Get-DefaultBox {
  # design box: 1400x1000, centred on the primary monitor's working area
  $w = 1400.0; $h = 1000.0
  $bx = [double]$script:Mon[0].wx + ([double]$script:Mon[0].ww - $w) / 2
  $by = [double]$script:Mon[0].wy + ([double]$script:Mon[0].wh - $h) / 2
  return @{ x = $bx; y = $by; w = $w; h = $h }
}
function Get-DefaultPositions {
  # the arrangement the project has always used, inside Get-DefaultBox
  $s = 1.0
  $box = Get-DefaultBox
  $bx = $box.x; $by = $box.y; $w = $box.w; $h = $box.h
  $cx = $w / 2
  $petH = 300.0 * $s; $petW = $petH * $script:PetArIdle
  $petX = $bx + $cx - $petW / 2
  $petY = $by + $h - $petH - 30.0 * $s
  $out = @{}
  $out.pet    = @{ x = [int]$petX; y = [int]$petY; s = $s }
  $out.panel  = @{ x = [int]($bx + $cx - 360.0 * $s / 2); y = [int]($petY - 79.07 * $s - 6.0 * $s); s = $s }
  $out.guitar = @{ x = [int]($petX - 150.0 * $s * 0.7247 + 24.0 * $s); y = [int]($petY + $petH - 150.0 * $s - 4.0 * $s); s = $s }
  $out.easel  = @{ x = [int]($petX + $petW + 2.0 * $s);    y = [int]($petY + $petH - 200.0 * $s - 4.0 * $s); s = $s }
  $out.bchan  = @{ x = [int]($petX - 95.0 * $s * 0.75 + 30.0 * $s);       y = [int]($petY + 2.0 * $s); s = $s }
  return $out
}

$script:PetAr = 0.693   # idle.wpm aspect, replaced as soon as a clip is known
$p0 = [WpmClip]::Peek((Join-Path $script:WpmD 'idle.wpm'))
if ($p0 -and $p0[3] -gt 0) { $script:PetAr = [double]$p0[2] / [double]$p0[3] }
# frozen aspect for the DEFAULT layout only: the live PetAr follows the current
# pose, and computing defaults from it made reset placement depend on which pose
# happened to be showing (reset twice with different poses gave different spots)
$script:PetArIdle = $script:PetAr

[WhalePerf]::Start(2000, 5000)
[WhalePerf]::EnumMonitors()
function Refresh-Mon {
  # read one consistent snapshot (the C# side locks while enumerating); without
  # this the PS list could disagree with the C# table and the screen pick would
  # then map to a different physical monitor than the label suggests
  $script:Mon = @()
  foreach ($mln in [WhalePerf]::MonSnapshot()) {
    $mf = $mln.Split('|')
    $script:Mon += [ordered]@{
      name = $mf[0]; x = [int]$mf[1]; y = [int]$mf[2]; w = [int]$mf[3]; h = [int]$mf[4]
      wx = [int]$mf[5]; wy = [int]$mf[6]; ww = [int]$mf[7]; wh = [int]$mf[8]
      prim = [int]$mf[9]; hz = [double]$mf[10]
    }
  }
}
Refresh-Mon
if ($script:Mon.Count -eq 0) {
  # never leave the pet without geometry
  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $script:Mon = @([ordered]@{ x = $vs.X; y = $vs.Y; w = $vs.Width; h = $vs.Height; wx = $vs.X; wy = $vs.Y; ww = $vs.Width; wh = $vs.Height; prim = 1; hz = -1; name = 'virtual' })
}
# virtual desktop bounds in physical pixels (for keeping components reachable).
# Recomputed by Update-VBounds whenever the monitor set changes (monitors can be
# unplugged at any time - hard-coded startup values went stale and left the pet
# off-screen with no way back, surviving restarts because the bad coordinates
# were persisted).
$script:MonSig = ''
function Update-VBounds {
  $script:VLeft = ($script:Mon | ForEach-Object { $_.x } | Measure-Object -Minimum).Minimum
  $script:VTop = ($script:Mon | ForEach-Object { $_.y } | Measure-Object -Minimum).Minimum
  $script:VRight = ($script:Mon | ForEach-Object { $_.x + $_.w } | Measure-Object -Maximum).Maximum
  $script:VBottom = ($script:Mon | ForEach-Object { $_.y + $_.h } | Measure-Object -Maximum).Maximum
}
Update-VBounds

$rd0 = Get-DefaultPositions
foreach ($k in $script:Comps5) {
  $script:Base[$k].x = [double]$rd0[$k].x
  $script:Base[$k].y = [double]$rd0[$k].y
  $script:Base[$k].s = [double]$rd0[$k].s
}
$script:HasSavedLayout = $false

if (Test-Path $script:CfgF) {
  try {
    $j = Get-Content $script:CfgF -Raw -Encoding UTF8 | ConvertFrom-Json
    $ver = 0
    if ($j.PSObject.Properties['cfgVer']) { $ver = [int]$j.cfgVer }
    if ($j.rotateSec -ne $null) { $script:RotateSec = [int]$j.rotateSec }
    if ($j.topmost -ne $null) { $script:Topmost = [bool]$j.topmost }
    if ($j.screenIdx -ne $null) { $script:ScreenIdx = [int]$j.screenIdx }
    if ($j.bubbleDy -ne $null) { $script:BubbleDy = [double]$j.bubbleDy }
    if ($j.side -ne $null) { $script:Side = [string]$j.side }
    if ($j.groupScale -ne $null) { $script:GroupScale = [Math]::Min(2.0, [Math]::Max(0.3, [double]$j.groupScale)) }
    if ($j.untopInGame -ne $null) { $script:UntopInGame = [bool]$j.untopInGame }
    if ($j.emo) { foreach ($p in $j.emo.PSObject.Properties) { if ($script:Emo.Contains($p.Name)) { $script:Emo[$p.Name] = [int]$p.Value } } }
    if ($j.statePoses) { foreach ($p in $j.statePoses.PSObject.Properties) { $script:StatePoses[$p.Name] = @($p.Value) } }
    if ($j.layout) {
      if ($ver -ge 5) {
        # v5/v6: layout is already an absolute physical arrangement, it simply
        # becomes the fixed base for the group scale
        $script:HasSavedLayout = $true
        foreach ($k in $script:Comps5) {
          if ($j.layout.$k) {
            $script:Base[$k].x = [double]$j.layout.$k.x
            $script:Base[$k].y = [double]$j.layout.$k.y
            if ($j.layout.$k.s -ne $null) {
              $sv = [double]$j.layout.$k.s
              $script:Base[$k].s = [Math]::Min(2.2, [Math]::Max(0.35, $sv))
            }
          }
        }
      } else {
        # v4 -> v6 migration.  The v4 "board" was a 1400x1000 physical window
        # whose canvas coordinates were already relative to its own top-left
        # corner, so the arrangement is preserved by placing those same
        # relative offsets inside the new primary-centred design box.
        $box = Get-DefaultBox
        $script:HasSavedLayout = $true
        foreach ($k in $script:Comps5) {
          if ($j.layout.$k) {
            $script:Base[$k].x = [double]$box.x + [double]$j.layout.$k.x
            $script:Base[$k].y = [double]$box.y + [double]$j.layout.$k.y
            if ($j.layout.$k.s -ne $null) {
              $sv = [double]$j.layout.$k.s
              $script:Base[$k].s = [Math]::Min(2.2, [Math]::Max(0.35, $sv))
            }
          }
        }
        Log ("config migrated v4 -> v6 (relative arrangement kept, new box origin {0},{1})" -f [int]$box.x, [int]$box.y)
      }
    }
  } catch { Log ("config parse fail: " + $_.Exception.Message) }
}
[WhalePerf]::SetScreenIndex($script:ScreenIdx)

function Sync-Layout {
  # derive the runtime geometry from the fixed base arrangement + global scale
  $k = [double]$script:GroupScale
  $bx = [double]$script:Base.pet.x
  $by = [double]$script:Base.pet.y
  foreach ($c in $script:Comps5) {
    $script:Layout[$c].x = $bx + ([double]$script:Base[$c].x - $bx) * $k
    $script:Layout[$c].y = $by + ([double]$script:Base[$c].y - $by) * $k
    $script:Layout[$c].s = [double]$script:Base[$c].s * $k
  }
}

function Save-Cfg {
  try {
    $lay = @{}
    foreach ($k in $script:Comps5) {
      $lay[$k] = @{ x = [Math]::Round([double]$script:Base[$k].x, 1); y = [Math]::Round([double]$script:Base[$k].y, 1); s = [Math]::Round([double]$script:Base[$k].s, 4) }
    }
    @{
      cfgVer = 6; screenIdx = $script:ScreenIdx; topmost = $script:Topmost
      untopInGame = $script:UntopInGame
      groupScale = [Math]::Round([double]$script:GroupScale, 4)
      rotateSec = $script:RotateSec; bubbleDy = [Math]::Round($script:BubbleDy, 1); side = $script:Side
      emo = $script:Emo; statePoses = $script:StatePoses; layout = $lay
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $script:CfgF -Encoding UTF8
  } catch { Log ("save cfg fail: " + $_.Exception.Message) }
}

# ---------------------------------------------------------------------------
# 6. component windows
# ---------------------------------------------------------------------------
$script:Wins = @{}
$script:Hwnd = @{}
$script:Elems = @{}
$script:Size = @{}
$script:WinDpi = @{}
$script:KeyOf = @{}
$script:PanelTxt = @{}
$script:PanelLbl = @{}

function New-CompWindow([string]$k) {
  $w = New-Object System.Windows.Window
  $w.WindowStyle = 'None'
  $w.ResizeMode = 'NoResize'
  $w.AllowsTransparency = $true
  $w.Background = [System.Windows.Media.Brushes]::Transparent
  $w.Topmost = $script:Topmost
  $w.ShowInTaskbar = $false
  $w.ShowActivated = $false
  $w.Focusable = $false
  $w.WindowStartupLocation = 'Manual'
  $w.Title = 'WpmV1|' + $k
  # Width/Height are deliberately left unset: SetWindowPos (physical pixels) is
  # the single authority for window geometry, WPF only fills the client area.
  $script:Wins[$k] = $w
  $script:KeyOf[$w] = $k
  return $w
}

# --- pet ---
$petWin = New-CompWindow 'pet'
$petImg = New-Image
$petImg.Tag = 'pet'
$petWin.Content = $petImg
$script:Elems.pet = $petImg

# --- panel ---
$panelWin = New-CompWindow 'panel'
$panelRoot = New-Object System.Windows.Controls.Grid
$panelRoot.Tag = 'panel'
# a Grid with a null Background is NOT hit-testable, so the whole component used
# to be dead to clicks/wheel (they fell through to the desktop).  A transparent
# background makes the component's rectangle interactive; the layered window
# still passes through at fully transparent pixels.
$panelRoot.Background = [System.Windows.Media.Brushes]::Transparent
$panelBg = New-Image
$panelBg.IsHitTestVisible = $false
$panelRoot.Children.Add($panelBg) | Out-Null
$panelInner = New-Object System.Windows.Controls.Grid
for ($i = 0; $i -lt 4; $i++) {
  $cd = New-Object System.Windows.Controls.ColumnDefinition
  $cd.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
  $panelInner.ColumnDefinitions.Add($cd) | Out-Null
}
$metricKeys = @('fps', 'cpu', 'gpu', 'mem')
$metricTitles = @((U 'labelFpsModeShort' 'FPS'), 'CPU', 'GPU', 'MEM')
for ($i = 0; $i -lt 4; $i++) {
  $sp = New-Object System.Windows.Controls.StackPanel
  $sp.VerticalAlignment = 'Center'
  $val = New-Text '--' 21 '#2E5D4E' 'Bold'
  $lbl = New-Text $metricTitles[$i] 10 '#6B9B8A' ''
  $sp.Children.Add($val) | Out-Null
  $sp.Children.Add($lbl) | Out-Null
  [System.Windows.Controls.Grid]::SetColumn($sp, $i)
  $panelInner.Children.Add($sp) | Out-Null
  $script:PanelTxt[$metricKeys[$i]] = $val
  $script:PanelLbl[$metricKeys[$i]] = $lbl
}
$panelRoot.Children.Add($panelInner) | Out-Null
# decorative children must not swallow mouse input: every component's ROOT
# element carries the Tag the handlers need, and hit-testable children without
# a Tag silently ate clicks and wheel events (v5 bug)
$panelInner.IsHitTestVisible = $false
$panelWin.Content = $panelRoot
$script:Elems.panel = $panelRoot

# --- accessories ---
foreach ($k in 'guitar', 'easel') {
  $w = New-CompWindow $k
  $im = New-Image
  $im.Tag = $k
  $w.Content = $im
  $script:Elems[$k] = $im
}

# --- bchan (icon + name label) ---
$bchanWin = New-CompWindow 'bchan'
$bchanRoot = New-Object System.Windows.Controls.Grid
$bchanRoot.Tag = 'bchan'
$bchanRoot.Background = [System.Windows.Media.Brushes]::Transparent   # see the panel note
$rd1 = New-Object System.Windows.Controls.RowDefinition
$rd1.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
$rd2 = New-Object System.Windows.Controls.RowDefinition
$rd2.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
$bchanRoot.RowDefinitions.Add($rd1) | Out-Null
$bchanRoot.RowDefinitions.Add($rd2) | Out-Null
$bchanImg = New-Image
$bchanImg.Stretch = 'Uniform'
$bchanImg.IsHitTestVisible = $false
$bchanRoot.Children.Add($bchanImg) | Out-Null
$accName = New-Text (U 'defaultName' 'pet') 11 '#2E5D4E' 'SemiBold'
$accName.IsHitTestVisible = $false
[System.Windows.Controls.Grid]::SetRow($accName, 1)
$bchanRoot.Children.Add($accName) | Out-Null
$bchanWin.Content = $bchanRoot
$script:Elems.bchan = $bchanRoot

# --- bubble ---
$bubbleWin = New-CompWindow 'bubble'
$bubbleRoot = New-Object System.Windows.Controls.Grid
$bubbleRoot.Tag = 'bubble'
$bubbleImg = New-Image
$bubbleImg.Stretch = 'Uniform'
$bubbleImg.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
$bubbleFlip = New-Object System.Windows.Media.ScaleTransform
$bubbleImg.RenderTransform = $bubbleFlip
$bubbleRoot.Children.Add($bubbleImg) | Out-Null
$bubbleText = New-Text '' 13 '#2E5D4E' ''
$bubbleText.IsHitTestVisible = $false
$bubbleText.TextWrapping = 'Wrap'
$bubbleText.LineHeight = 18
$bubbleText.VerticalAlignment = 'Center'
$bubbleText.TextAlignment = 'Center'
$bubbleRoot.Children.Add($bubbleText) | Out-Null
$bubbleWin.Content = $bubbleRoot
$script:Elems.bubble = $bubbleRoot

# ---- assets ----
$panelBmp = Load-Bmp (Join-Path $script:Assets 'panel\panel.png') 1440
if ($panelBmp) { $panelBg.Source = $panelBmp }
$bubbleBmp = Load-Bmp (Join-Path $script:Assets 'bubble\bubble_fill.png') 860
if (-not $bubbleBmp) { $bubbleBmp = Load-Bmp (Join-Path $script:Assets 'bubble\bubble.png') 860 }
if ($bubbleBmp) { $bubbleImg.Source = $bubbleBmp }
$accImg = @{ guitar = $script:Elems.guitar; easel = $script:Elems.easel; bchan = $bchanImg }
foreach ($a in @(@{ k = 'guitar'; f = 'guitar.png'; w = 300 }, @{ k = 'easel'; f = 'easel.png'; w = 300 }, @{ k = 'bchan'; f = 'bubblechan.png'; w = 200 })) {
  $b = Load-Bmp (Join-Path $script:Assets ('accessory\' + $a.f)) $a.w
  if ($b) { $accImg[$a.k].Source = $b }
}

# ---- sizing helpers (all values physical) ----
function Get-CompPhys([string]$k) {
  $s = [double]$script:Layout[$k].s
  $d = $script:Def[$k]
  if ($k -eq 'pet') {
    $h = $d.h * $s
    $w = $h * $script:PetAr
  } elseif ($k -eq 'bchan') {
    $h = ($d.h + $d.extra) * $s
    $w = $d.h * $s * $d.ar
    $lw = $d.labelMinW * $s
    if ($lw -gt $w) { $w = $lw }
  } else {
    $h = $d.h * $s
    $w = $h * $d.ar
  }
  return @{ w = [int][Math]::Round($w); h = [int][Math]::Round($h) }
}

function Move-Comp([string]$k) {
  $cwin = $script:Wins[$k]
  if (-not $cwin) { return }
  $L = $script:Layout[$k]
  $sz = Get-CompPhys $k
  $script:Size[$k] = $sz
  # physical geometry is owned by SetWindowPos only
  $h = $script:Hwnd[$k]
  if ($h -ne [IntPtr]::Zero) { [WpmDpi]::Move($h, [int]$L.x, [int]$L.y, [int]$sz.w, [int]$sz.h) }
  # DIP conversions must use the scale WPF itself reports for this window: it
  # can legitimately differ from the monitor scale, and mixing the two is what
  # made v4's geometry wrong on mixed-DPI desktops.
  $wp = 1.0
  try {
    $d = [System.Windows.Media.VisualTreeHelper]::GetDpi($cwin)
    if ($d.DpiScaleX -gt 0) { $wp = [double]$d.DpiScaleX }
  } catch { }
  $script:WinDpi[$k] = $wp
}

function Apply-Comp([string]$k) {
  $s = [double]$script:Layout[$k].s
  Move-Comp $k
  $dpi = [double]$script:WinDpi[$k]
  if ($dpi -le 0) { $dpi = 1.0 }
  switch ($k) {
    'panel' {
      # font sizes follow the panel scale (v4 only scaled the frame)
      $script:PanelTxt.fps.FontSize = 21.0 * $s / $dpi
      foreach ($mk in 'cpu', 'gpu', 'mem') { $script:PanelTxt[$mk].FontSize = 16.0 * $s / $dpi }
      foreach ($mk in 'fps', 'cpu', 'gpu', 'mem') { $script:PanelLbl[$mk].FontSize = 10.0 * $s / $dpi }
      $panelInner.Margin = New-Object System.Windows.Thickness ([int](80.0 * $s / $dpi)), ([int](22.0 * $s / $dpi)), ([int](60.0 * $s / $dpi)), ([int](14.0 * $s / $dpi))
    }
    'bchan' {
      $accName.FontSize = 11.0 * $s / $dpi
    }
    'bubble' {
      # insets come from the art itself; the font auto-fit in Show-Bubble then
      # guarantees the text never spills over the bubble
      $ins = $script:Def.bubble.ins
      $il = [double]$ins.l * $s / $dpi
      $it = [double]$ins.t * $s / $dpi
      $ir = [double]$ins.r * $s / $dpi
      $ib = [double]$ins.b * $s / $dpi
      $bubbleText.Margin = New-Object System.Windows.Thickness $il, $it, $ir, $ib
      $script:BubFontBase = 13.0 * $s / $dpi
      $bubbleText.LineHeight = [Math]::Round($script:BubFontBase * 1.32, 1)
      $bubbleText.FontSize = $script:BubFontBase
      $bsz = $script:Size.bubble
      $script:BubAvailW = [Math]::Max(20.0, ([double]$bsz.w / $dpi) - $il - $ir)
      $script:BubAvailH = [Math]::Max(12.0, ([double]$bsz.h / $dpi) - $it - $ib)
    }
  }
}

function Set-BubblePos {
  $Lp = $script:Layout.pet
  $ps = Get-CompPhys 'pet'
  $bs = Get-CompPhys 'bubble'
  $bd = $script:BubbleDy * [double]$Lp.s
  if ($script:Side -eq 'L') { $bx = [double]$Lp.x - $bs.w + 14.0 * [double]$Lp.s } else { $bx = [double]$Lp.x + $ps.w - 14.0 * [double]$Lp.s }
  $script:Layout.bubble.x = $bx
  $script:Layout.bubble.y = [double]$Lp.y + $bd
  $script:Layout.bubble.s = [double]$Lp.s
  Move-Comp 'bubble'
}

function Get-GroupBBox {
  $bl = [double]::MaxValue; $bt = [double]::MaxValue; $br = [double]::MinValue; $bg = [double]::MinValue
  foreach ($k in $script:Comps5) {
    $lay = $script:Layout[$k]; $csz = Get-CompPhys $k
    $bl = [Math]::Min($bl, [double]$lay.x); $bt = [Math]::Min($bt, [double]$lay.y)
    $br = [Math]::Max($br, [double]$lay.x + $csz.w); $bg = [Math]::Max($bg, [double]$lay.y + $csz.h)
  }
  return @{ l = $bl; t = $bt; r = $br; b = $bg }
}

function Ensure-PetOnScreen {
  # The virtual desktop can be NON-CONTIGUOUS (close the middle of three
  # screens and the left/right pair leaves a hole).  Rectangle clamping cannot
  # see a hole, so the anchor gets an absolute invariant instead: its centre
  # must lie ON a real monitor.  When it does not (screen unplugged, stale
  # coordinates), the whole group moves rigidly so the pet lands on the nearest
  # monitor's working area, arrangement intact.
  $psz = Get-CompPhys 'pet'
  $cx = [double]$script:Layout.pet.x + $psz.w / 2
  $cy = [double]$script:Layout.pet.y + $psz.h / 2
  $best = $null; $bestD = [double]::MaxValue
  foreach ($m in $script:Mon) {
    if ($cx -ge $m.x -and $cx -lt ($m.x + $m.w) -and $cy -ge $m.y -and $cy -lt ($m.y + $m.h)) { return $false }
    $nx = [Math]::Max([double]$m.x, [Math]::Min([double]($m.x + $m.w), $cx))
    $ny = [Math]::Max([double]$m.y, [Math]::Min([double]($m.y + $m.h), $cy))
    $d = [Math]::Abs($nx - $cx) + [Math]::Abs($ny - $cy)
    if ($d -lt $bestD) { $bestD = $d; $best = $m }
  }
  if (-not $best) { return $false }
  # same relative position inside the nearest monitor, clamped so the pet fits
  $tx = [double]$best.wx + ([double]$best.ww - $psz.w) / 2
  $ty = [double]$best.wy + ([double]$best.wh - $psz.h) / 2
  if ($tx -lt [double]$best.wx) { $tx = [double]$best.wx }
  if ($ty -lt [double]$best.wy) { $ty = [double]$best.wy }
  $dx = $tx - ([double]$script:Layout.pet.x)
  $dy = $ty - ([double]$script:Layout.pet.y)
  foreach ($k in $script:Comps5) {
    $script:Base[$k].x = [double]$script:Base[$k].x + $dx
    $script:Base[$k].y = [double]$script:Base[$k].y + $dy
  }
  Sync-Layout
  Log ("pet centre ({0},{1}) is on no monitor -> group moved to {2} (delta {3},{4})" -f [int]$cx, [int]$cy, $best.name, [int]$dx, [int]$dy)
  return $true
}

function Clamp-Group([string]$reason = '') {
  # $reason: only startup/monitor-change/reset pass one; those adjustments are
  # logged so a mystery position shift can always be attributed (real mouse
  # drags stay silent on purpose).
  $clampLog = {
    param($why, $ddx, $ddy, $bbox)
    if ($reason) {
      if ($bbox) {
        Log ("clamp ({0}) moved group by ({1},{2}) | bb=({3},{4})-({5},{6}) vdesk=({7},{8})-({9},{10})" -f `
          $why, [int]$ddx, [int]$ddy, [int]$bbox.l, [int]$bbox.t, [int]$bbox.r, [int]$bbox.b, `
          $script:VLeft, $script:VTop, $script:VRight, $script:VBottom)
      } else {
        Log ("clamp ({0}) moved group by ({1},{2})" -f $why, [int]$ddx, [int]$ddy)
      }
    }
  }
  # Rule 1: the ANCHOR (pet) itself must stay reachable - at least 160 px of it
  # inside the desktop.  (A bbox-only rule lets the anchor dangle far off-screen
  # while some other component satisfies the visibility margin.)
  $psz = Get-CompPhys 'pet'
  $keep = 160.0
  $dx = 0.0; $dy = 0.0
  $px = [double]$script:Layout.pet.x; $py = [double]$script:Layout.pet.y
  $cx = [Math]::Max($script:VLeft - $psz.w + $keep, [Math]::Min($script:VRight - $keep, $px))
  $cy = [Math]::Max($script:VTop - $psz.h + $keep, [Math]::Min($script:VBottom - $keep, $py))
  if ([Math]::Abs($cx - $px) -gt 0.5 -or [Math]::Abs($cy - $py) -gt 0.5) {
    $dx = $cx - $px; $dy = $cy - $py
    foreach ($k in $script:Comps5) {
      $script:Base[$k].x = [double]$script:Base[$k].x + $dx
      $script:Base[$k].y = [double]$script:Base[$k].y + $dy
    }
    Sync-Layout
    & $clampLog 'anchor' $dx $dy $null
  }
  # Rule 2: keep the whole-group bounding box reachable - at least 160 px of the
  # box stays inside, and the group always moves as one rigid body so the
  # relative placement survives being pushed against a screen edge.
  $bb = Get-GroupBBox
  $newL = [Math]::Max($script:VLeft - ($bb.r - $bb.l) + $keep, [Math]::Min($script:VRight - $keep, [double]$bb.l))
  $newT = [Math]::Max($script:VTop - ($bb.b - $bb.t) + $keep, [Math]::Min($script:VBottom - $keep, [double]$bb.t))
  $ax = $newL - $bb.l; $ay = $newT - $bb.t
  if ([Math]::Abs($ax) -gt 0.5 -or [Math]::Abs($ay) -gt 0.5) {
    foreach ($k in $script:Comps5) {
      $script:Base[$k].x = [double]$script:Base[$k].x + $ax
      $script:Base[$k].y = [double]$script:Base[$k].y + $ay
    }
    Sync-Layout
    & $clampLog 'group-bbox' $ax $ay $bb
    return $true
  }
  return ([Math]::Abs($dx) + [Math]::Abs($dy)) -gt 0.5
}

function Apply-All {
  if (-not $script:HasSavedLayout) {
    $rd = Get-DefaultPositions
    foreach ($k in $script:Comps5) {
      $script:Base[$k].x = [double]$rd[$k].x
      $script:Base[$k].y = [double]$rd[$k].y
    }
  }
  # Pull an out-of-bounds saved layout back into the CURRENT virtual desktop.
  # Without this, coordinates persisted while a monitor existed put the pet
  # off-screen forever once that monitor was unplugged - including after every
  # restart (bug: the pet vanished off-screen and survived restarts).
  # Order matters: the visibility rules read the DERIVED layout, so sync first
  # (clamping before the first sync reads zeros and silently does nothing - the
  # exact bug this fix shipped with first).  Ensure-PetOnScreen runs before the
  # rectangle clamp on purpose: the virtual desktop can be NON-CONTIGUOUS and
  # the clamp cannot see a hole, while the anchor-on-a-real-monitor check can.
  Sync-Layout
  [void](Ensure-PetOnScreen)
  Sync-Layout
  [void](Clamp-Group 'startup')
  Sync-Layout
  [void](Clamp-Group)
  Sync-Layout
  foreach ($k in $script:Comps5) { Apply-Comp $k }
  Set-BubblePos
  # the bubble derives its position/size from the pet, so its text metrics must
  # be applied AFTER Set-BubblePos (this call was missing in v5/v6 and the
  # bubble text therefore had no margins at all, spilling over the art)
  Apply-Comp 'bubble'
}

# ---- create handles, place the components while still hidden, then show ----
foreach ($k in $script:CompsAll) {
  $chw = (New-Object System.Windows.Interop.WindowInteropHelper $script:Wins[$k]).EnsureHandle()
  $script:Hwnd[$k] = $chw
}
Apply-All
foreach ($k in $script:Comps5) {
  $cwin = $script:Wins[$k]
  try { $cwin.Add_DpiChanged({ param($s, $e) try { Move-Comp $script:KeyOf[$s] } catch { } }) } catch { }
  $cwin.Add_MouseRightButtonUp({ & $script:ShowMenu })
  # the pet window itself is shown (non-modally) at the bottom of this file
  if ($k -ne 'pet') { $cwin.Show(); [WpmDpi]::NoTaskbar($script:Hwnd[$k]) }
}
try { $petWin.Add_ContentRendered({ try { Apply-All } catch { } }) } catch { }
try { $bubbleWin.Add_DpiChanged({ param($s, $e) try { Move-Comp 'bubble' } catch { } }) } catch { }
$bubbleWin.Show()
$bubbleWin.Hide()
Apply-All
$script:BubFontBase = 13.0

# ---------------------------------------------------------------------------
# 7. animation clips (lazy, no forced GC)
# ---------------------------------------------------------------------------
$script:AnimPaths = @{}
foreach ($n in 'idle', 'celebrate', 'surprised', 'sleepy', 'thinking', 'cheer', 'sleeping') {
  $p = Join-Path $script:WpmD ($n + '.wpm')
  if (Test-Path $p) { $script:AnimPaths[$n] = $p }
}
$script:Anims = @{}
function Get-Anim([string]$name) {
  if ($script:Anims.ContainsKey($name)) { return $script:Anims[$name] }
  if (-not $script:AnimPaths.ContainsKey($name)) { return $null }
  $clip = [WpmClip]::Load($script:AnimPaths[$name])
  if (-not $clip -or $clip.Frames.Count -lt 2) { return $null }
  # keep only the current clip resident; drop the rest and let the GC decide
  # when to collect (v4 forced a blocking gen2 collection every 30 s)
  $script:Anims = @{ }
  $script:Anims[$name] = $clip
  return $clip
}

$script:CurrentPose = ''
$script:AnimIdx = 0
$script:LastAnimAt = 0

function Set-Pose([string]$name) {
  if ($script:CurrentPose -eq $name) { return $false }
  $clip = Get-Anim $name
  if (-not $clip) { Log ("pose missing: " + $name); return $false }
  $script:AnimIdx = 0
  $script:LastAnimAt = 0
  $script:PetAr = [double]$clip.Width / [double]$clip.Height
  $petImg.Source = $clip.Frames[0]
  $script:CurrentPose = $name
  Apply-Comp 'pet'
  Set-BubblePos
  return $true
}

$animTimer = New-Object System.Windows.Threading.DispatcherTimer
$animTimer.Interval = [TimeSpan]::FromMilliseconds(33)
$animTimer.Add_Tick({
  try {
    if (-not $script:CurrentPose) { return }
    $clip = $script:Anims[$script:CurrentPose]
    if (-not $clip) { return }
    $now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    $frameMs = [int](1000.0 / $clip.Fps)
    if ($now - $script:LastAnimAt -lt $frameMs) { return }
    $script:LastAnimAt = $now
    $script:AnimIdx = ($script:AnimIdx + 1) % $clip.Frames.Count
    $petImg.Source = $clip.Frames[$script:AnimIdx]
  } catch { }
})
$animTimer.Start()

# ---------------------------------------------------------------------------
# 8. drag / group move / wheel
# ---------------------------------------------------------------------------
$script:Drag = $null

# Interaction model (v6, deliberately simple):
#   drag any component  -> the whole arrangement moves as one rigid body
#   wheel anywhere      -> the whole arrangement scales about the pet's top-left
#   click the character -> cycle the manual pose list
#   click the bubblechan-> cycle the monitored screen
# There is no per-component move/scale and no lock toggle any more; the base
# positions are fixed and only the group scale changes their spacing.
function Begin-Drag([string]$kind) {
  $c = [WpmDpi]::Cursor()
  $bases = @{}
  foreach ($k in $script:Comps5) {
    $bases[$k] = @{ x = [double]$script:Base[$k].x; y = [double]$script:Base[$k].y }
  }
  $script:Drag = @{ Kind = $kind; El = $null; SX = $c[0]; SY = $c[1]; Base = $bases; Moved = $false }
}

function Update-Drag([int]$dx = 0, [int]$dy = 0, [bool]$explicit = $false) {
  if (-not $script:Drag) { return }
  $d = $script:Drag
  if ($explicit) {
    $mx = [int]$d.SX + $dx; $my = [int]$d.SY + $dy
  } else {
    $c = [WpmDpi]::Cursor(); $mx = $c[0]; $my = $c[1]
  }
  $ddx = [double]($mx - $d.SX); $ddy = [double]($my - $d.SY)
  if ([Math]::Abs($ddx) + [Math]::Abs($ddy) -gt 3) { $d.Moved = $true }
  if (-not $d.Moved) { return }
  foreach ($k in $script:Comps5) {
    $script:Base[$k].x = $d.Base[$k].x + $ddx
    $script:Base[$k].y = $d.Base[$k].y + $ddy
  }
  [void](Clamp-Group)
  Sync-Layout
  foreach ($k in $script:Comps5) { Move-Comp $k }
  Set-BubblePos
}

function Complete-Drag {
  if (-not $script:Drag) { return }
  $d = $script:Drag
  $script:Drag = $null
  if (-not $d.Moved) { return }
  [void](Clamp-Group)
  Sync-Layout
  foreach ($k in $script:Comps5) { Move-Comp $k }
  Set-BubblePos
  Save-Cfg
}

function Set-GroupScale([double]$k) {
  # Per-component ceiling raised to 2.2: with the panel's base scale at 1.5 the
  # old 1.7 ceiling capped the whole group at 1.13x, which the user hit
  # immediately when scrolling up (and a clamped wheel is not symmetric, so the
  # scale drifted down over time).
  $lo = 0.30; $hi = 2.20
  foreach ($c in $script:Comps5) {
    $bs = [double]$script:Base[$c].s
    if ($bs -gt 0) {
      $lo = [Math]::Max($lo, 0.40 / $bs)
      $hi = [Math]::Min($hi, 2.20 / $bs)
    }
  }
  if ($hi -lt $lo) { $hi = $lo }
  $script:GroupScale = [Math]::Max($lo, [Math]::Min($hi, $k))
  Sync-Layout
  foreach ($c in $script:Comps5) { Apply-Comp $c }
  Set-BubblePos
  Apply-Comp 'bubble'
}

function Invoke-Click([string]$kind) {
  if ($kind -eq 'pet') {
    # cycle the manual pose list: with one-pose emotion pools a click used to
    # produce no visible change at all
    $i = [Array]::IndexOf($script:PoseList, $script:CurrentPose)
    $next = ''
    for ($n = 1; $n -le $script:PoseList.Count; $n++) {
      $cand = $script:PoseList[(($i + $n) % $script:PoseList.Count)]
      if ($script:AnimPaths.ContainsKey($cand)) { $next = $cand; break }
    }
    if ($next -and (Set-Pose $next)) {
      $script:ManualPose = $true
      $script:ManualAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
      Log ("pose -> " + $next + " (manual)")
    }
    Show-Bubble (Pick-Random (Get-Lines 'idle_switch'))
  } elseif ($kind -eq 'bchan') {
    & $script:CycleScreen
  }
}

$hDown = {
  param($sender, $e)
  try {
    # handlers are attached to the WINDOW (whose Transparent background is
    # reliably hit-testable) and mapped back to the component via KeyOf; the
    # element Tag is only a fallback.  Attaching to child elements proved
    # fragile: a Grid with a null background is not hit-testable at all, and
    # decorative children without a Tag silently swallowed input.
    $kind = [string]$script:KeyOf[$sender]
    if (-not $kind) { $kind = [string]$sender.Tag }
    if (-not $kind) { Log ('input down with no component mapping'); return }
    Log ("input down -> " + $kind)
    Begin-Drag $kind
    $script:Drag.El = $sender
    $sender.CaptureMouse()
  } catch { Log ("drag down err: " + $_.Exception.Message) }
}
$hMove = {
  param($sender, $e)
  try {
    if (-not $script:Drag -or $script:Drag.El -ne $sender) { return }
    Update-Drag
  } catch { }
}
$hUp = {
  param($sender, $e)
  try {
    if (-not $script:Drag -or $script:Drag.El -ne $sender) { return }
    $moved = [bool]$script:Drag.Moved
    $kind = [string]$script:Drag.Kind
    try { $sender.ReleaseMouseCapture() } catch { }
    if ($moved) {
      Complete-Drag
    } else {
      $script:Drag = $null
      Log ("input up -> click on " + $kind)
      Invoke-Click $kind
    }
  } catch { Log ("drag up err: " + $_.Exception.Message) }
}
$hWheel = {
  param($sender, $e)
  try {
    $notches = $e.Delta / 120.0
    Set-GroupScale ([double]$script:GroupScale + 0.05 * $notches)
    Save-Cfg
    Log ("group scale -> " + [Math]::Round([double]$script:GroupScale, 3) + " (wheel " + $notches + " notches)")
    $e.Handled = $true
  } catch { Log ("wheel err: " + $_.Exception.Message) }
}
# input is wired at the WINDOW level: each component is one window, so the
# window-to-component map ($script:KeyOf) gives the hit target and no child
# element can swallow the event.  The bubble follows the pet and stays inert.
foreach ($k in $script:Comps5) {
  $cwin = $script:Wins[$k]
  $cwin.Add_MouseLeftButtonDown($hDown)
  $cwin.Add_MouseMove($hMove)
  $cwin.Add_MouseLeftButtonUp($hUp)
  $cwin.Add_MouseWheel($hWheel)
}

# ---------------------------------------------------------------------------
# 9. lines / bubble
# ---------------------------------------------------------------------------
$script:LineBank = @{}
if (Test-Path $script:LinesF) {
  try {
    $lj = Get-Content $script:LinesF -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $lj.PSObject.Properties) { $script:LineBank[$p.Name] = @($p.Value) }
  } catch { Log ("lines parse fail: " + $_.Exception.Message) }
}
function Get-Lines([string]$key) {
  if ($script:LineBank.ContainsKey($key)) {
    $v = @($script:LineBank[$key])
    if ($v.Count -gt 0) { return , $v }
  }
  return , @((U 'lineFallback' '...'))
}

$script:BubbleSide = if ($script:Side -eq 'L') { 'L' } else { 'R' }
$hideTimer = New-Object System.Windows.Threading.DispatcherTimer
$hideTimer.Interval = [TimeSpan]::FromSeconds(9)
$hideTimer.Add_Tick({ $bubbleWin.Hide(); $hideTimer.Stop() })

function Measure-BubbleFont([string]$line, [double]$availW, [double]$availH, [double]$baseFs) {
  # auto-fit: shrink the font until the wrapped text really fits the bubble's
  # inner box, so no line can ever spill over the art (v6 reported overflow)
  $fs = $baseFs
  if ($fs -le 0) { $fs = 13.0 }
  $tf = $null
  try { $tf = New-Object System.Windows.Media.Typeface($bubbleText.FontFamily, $bubbleText.FontStyle, $bubbleText.FontWeight, $bubbleText.FontStretch) } catch { }
  if (-not $tf) { return $fs }
  $brush = (C '#2E5D4E')
  for ($i = 0; $i -lt 12; $i++) {
    try {
      $ft = New-Object System.Windows.Media.FormattedText($line, [System.Globalization.CultureInfo]::CurrentCulture, [System.Windows.FlowDirection]::LeftToRight, $tf, $fs, $brush, 1.0)
      $ft.MaxTextWidth = [Math]::Max(20.0, $availW)
      $ft.LineHeight = $fs * 1.32
      if ($ft.Height -le $availH) { return [Math]::Round($fs, 2) }
    } catch { return [Math]::Round($fs, 2) }
    $fs = $fs * 0.9
  }
  return [Math]::Round($fs, 2)
}

function Show-Bubble([string]$line) {
  if (-not $line) { return }
  $baseFs = [double]$script:BubFontBase
  if ($baseFs -le 0) { $baseFs = 13.0 }
  $aw = [double]$script:BubAvailW; if ($aw -le 0) { $aw = 120.0 }
  $ah = [double]$script:BubAvailH; if ($ah -le 0) { $ah = 40.0 }
  $fs = Measure-BubbleFont $line $aw $ah $baseFs
  $bubbleText.FontSize = $fs
  $bubbleText.LineHeight = [Math]::Round($fs * 1.32, 1)
  $bubbleText.Text = $line
  $disp = $script:BubbleSide
  $bubbleFlip.ScaleX = if ($disp -eq 'L') { -1 } else { 1 }
  $script:Side = $disp
  Set-BubblePos
  $script:BubbleSide = if ($disp -eq 'L') { 'R' } else { 'L' }
  $bubbleWin.Show()
  # keep the bubble above every other component (user request)
  [WpmDpi]::Top($script:Hwnd.bubble)
  [WpmDpi]::NoTaskbar($script:Hwnd.bubble)
  $hideTimer.Stop(); $hideTimer.Start()
}

function Build-Line {
  $fps = [int][WhalePerf]::Fps; $cpu = [int][WhalePerf]::Cpu
  $gpu = [int][WhalePerf]::Gpu; $mem = [WhalePerf]::Mem
  $load = [Math]::Max($cpu, $gpu)
  $line = ''
  $pool = ''
  if ($fps -lt 0) {
    $pool = 'nortss'; $line = Pick-Random (Get-Lines $pool)
  } elseif ($gpu -ge $script:Emo.worriedGpu -or $cpu -ge $script:Emo.worriedCpu -or $mem -ge $script:Emo.worriedMem) {
    $pool = 'worried'; $line = Pick-Random (Get-Lines $pool)
  } elseif ([WhalePerf]::InGame) {
    if ($fps -ge 75) { $pool = 'skill_praise' }
    elseif ($fps -ge 36) { $pool = 'game_eval' }
    elseif ($fps -ge 1 -and $load -ge 55) { $pool = if ((Get-Random -Maximum 2) -eq 0) { 'comfort_lag' } else { 'encourage' } }
    else { $pool = 'browsing' }
    $line = Pick-Random (Get-Lines $pool)
  } else {
    # non-game lines follow the current emotion so text and pose tell one story
    switch ($script:EmoName) {
      'thinking' { $pool = 'busy' }
      'sleepy'   { $pool = 'sleepy' }
      'asleep'   { $pool = 'night' }
      default    { $pool = 'browsing' }
    }
    $line = Pick-Random (Get-Lines $pool)
  }
  $out = $line.Replace('{fps}', [string]$fps).Replace('{cpu}', [string]$cpu).Replace('{gpu}', [string]$gpu).Replace('{mem}', [string]$mem).Replace('{load}', [string]$load)
  Log ("say [{0}] pool={1} emo={2} mode={3} fps={4} load={5} :: {6}" -f $line.Length, $pool, $script:EmoName, [WhalePerf]::DetectHow, $fps, $load, $out)
  return $out
}

$lineTimer = New-Object System.Windows.Threading.DispatcherTimer
function Arm-LineTimer {
  $lineTimer.Interval = [TimeSpan]::FromMilliseconds((Get-Random -Minimum 15000 -Maximum 45000))
  $lineTimer.Stop(); $lineTimer.Start()
}
$lineTimer.Add_Tick({
  try { Show-Bubble (Build-Line) } catch { Log ("line tick err: " + $_.Exception.Message) }
  Arm-LineTimer
})

# ---------------------------------------------------------------------------
# 10. emotion state machine (data driven, with hysteresis)
# ---------------------------------------------------------------------------
$script:EmoName = 'idle'
$script:EmoCand = ''
$script:EmoCandN = 0
$script:LastPoseAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$script:FpsEma = -1

function Eval-State {
  $cpu = [int][WhalePerf]::Cpu; $gpu = [int][WhalePerf]::Gpu; $mem = [WhalePerf]::Mem
  $load = [Math]::Max($cpu, $gpu)
  $hour = (Get-Date).Hour
  if ($gpu -ge $script:Emo.worriedGpu -or $cpu -ge $script:Emo.worriedCpu -or $mem -ge $script:Emo.worriedMem) { return 'worried' }
  if ([WhalePerf]::InGame) {
    if ($script:FpsEma -ge $script:Emo.celebrateFps) { return 'happy' }
    if ($script:FpsEma -ge 1 -and $script:FpsEma -le $script:Emo.thinkFpsMax -and $load -ge $script:Emo.thinkLoad) { return 'thinking' }
    if ($load -ge $script:Emo.busyLoad) { return 'thinking' }
    return 'idle'
  }
  if ($load -ge $script:Emo.busyLoad) { return 'thinking' }
  $night = ($hour -ge $script:Emo.nightStart -or $hour -lt $script:Emo.nightEnd)
  if ($night -and $load -le $script:Emo.idleLoad) { return 'asleep' }
  if ($load -le $script:Emo.idleLoad -and $mem -lt $script:Emo.worriedMem) { return 'sleepy' }
  return 'idle'
}

function Set-Emo([string]$st, [bool]$force) {
  $pool = @($script:StatePoses[$st])
  if ($pool.Count -eq 0) { $pool = @('idle') }
  $next = Pick-Random @($pool | Where-Object { $_ -ne $script:CurrentPose })
  if (-not $next) { $next = Pick-Random $pool }
  $changed = Set-Pose $next
  $stateChanged = ($st -ne $script:EmoName)
  $script:EmoName = $st
  $script:LastPoseAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
  # a real emotion change takes ownership of the pose back from a manual pick
  if ($stateChanged) { $script:ManualPose = $false }
  # only log real transitions: a same-state re-pick with a single-pose pool is
  # not an event worth a log line every rotateSec
  if ($changed -or $stateChanged -or $force) {
    Log ("emo -> {0} / pose {1} (mode {2} fps {3} cpu {4} gpu {5} mem {6} load {7})" -f $st, $next, [WhalePerf]::DetectHow, [int][WhalePerf]::Fps, [int][WhalePerf]::Cpu, [int][WhalePerf]::Gpu, [WhalePerf]::Mem, [Math]::Max([int][WhalePerf]::Cpu, [int][WhalePerf]::Gpu))
  }
}

$emoTimer = New-Object System.Windows.Threading.DispatcherTimer
$emoTimer.Interval = [TimeSpan]::FromSeconds([Math]::Max(1, $script:Emo.evalSec))
$emoTimer.Add_Tick({
  try {
    $f = [double][WhalePerf]::Fps
    if ([WhalePerf]::InGame -and $f -gt 0) {
      if ($script:FpsEma -lt 0) { $script:FpsEma = $f } else { $script:FpsEma = $script:FpsEma * 0.6 + $f * 0.4 }
    } elseif (-not [WhalePerf]::InGame) { $script:FpsEma = -1 }
    $want = Eval-State
    $now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    # a manual pose holds for at most 5 minutes, then the emotion machine takes
    # the pose back (otherwise the pet could stay on a hand-picked pose all day)
    if ($script:ManualPose -and ($now - $script:ManualAt) -gt 300000) {
      $script:ManualPose = $false
      Log 'manual pose expired -> emotion machine resumes'
    }
    if ($want -ne $script:EmoName) {
      if ($want -ne $script:EmoCand) { $script:EmoCand = $want; $script:EmoCandN = 1 } else { $script:EmoCandN++ }
      $held = ($now - $script:LastPoseAt) -ge ($script:Emo.minDwellSec * 1000)
      if ($script:EmoCandN -ge $script:Emo.holdTicks -and $held) { Set-Emo $want $false }
    } else {
      $script:EmoCand = ''; $script:EmoCandN = 0
      # same-state variant rotation, but never over a manual pose the user picked
      if (-not $script:ManualPose -and $script:RotateSec -gt 0 -and ($now - $script:LastPoseAt) -ge ($script:RotateSec * 1000)) { Set-Emo $script:EmoName $true }
    }
  } catch { Log ("emo tick err: " + $_.Exception.Message) }
})
$emoTimer.Start()

# ---------------------------------------------------------------------------
# 11. panel refresh / topmost re-assert / RTSS guard / petcmd / menu
# ---------------------------------------------------------------------------
# RTSS lifecycle + autostart helpers. They must live BEFORE the first top-level
# use (startup call in section 13, guard tick below, menu + shutdown handlers).
function Get-RtssExe {
  # RTSS installs to a fixed official location; absence simply means the FPS
  # feature keeps its "refresh rate" fallback (behaviour unchanged).
  $rtssPath = Join-Path ${env:ProgramFiles(x86)} 'RivaTuner Statistics Server\RTSS.exe'
  if (Test-Path $rtssPath) { return $rtssPath }
  return ''
}

function New-RtssShortcut {
  # Desktop shortcut for RTSS so the user can always start it by hand.
  # Idempotent: skipped when made once (marker in runtime\) or the .lnk exists.
  try {
    $rscMark = Join-Path $script:Run 'rtss_shortcut.created'
    if (Test-Path $rscMark) { return }
    $rscDesk = [Environment]::GetFolderPath('Desktop')
    if ($rscDesk) {
      $rscPath = Join-Path $rscDesk ((U 'rtssShortcutName' 'RTSS FPS Tool') + '.lnk')
      if (-not (Test-Path $rscPath)) {
        $rscExe = Get-RtssExe
        if ($rscExe -ne '') {
          $rsc = New-Object -ComObject WScript.Shell
          $rscLnk = $rsc.CreateShortcut($rscPath)
          $rscLnk.TargetPath = $rscExe
          $rscLnk.WorkingDirectory = (Split-Path -Parent $rscExe)
          $rscLnk.Save()
          [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($rsc)
          Log 'rtss desktop shortcut created'
        }
      }
      Set-Content -Path $rscMark -Value '1' -Encoding ASCII
    }
  } catch { Log ("rtss shortcut err: " + $_.Exception.Message) }
}

function Ensure-Rtss {
  # Called once at startup: if RTSS is installed but not running, start it.
  # This makes game FPS work on machines where RTSS did not register its own
  # autostart; needs no scheduled task and no admin rights.
  try {
    $re = Get-RtssExe
    if ($re -eq '') { return }
    if (Get-Process RTSS -ErrorAction SilentlyContinue) { return }
    Start-Process -FilePath $re
    Log 'rtss not running -> started by pet'
    New-RtssShortcut
  } catch { Log ("ensure-rtss err: " + $_.Exception.Message) }
}

function Start-RtssDirect {
  # guard revive without the scheduled task (no admin needed); harmless no-op
  # when RTSS is already running or not installed
  try {
    $rtssExe = Get-RtssExe
    if ($rtssExe -eq '') { return }
    if (Get-Process RTSS -ErrorAction SilentlyContinue) { return }
    Start-Process -FilePath $rtssExe
    Log 'rtss revived directly by pet guard'
  } catch { Log ("rtss direct start err: " + $_.Exception.Message) }
}

function Stop-Rtss {
  # Called on real shutdown (not on the 'reload' handoff): the pet owns the
  # RTSS lifetime. RTSS itself runs elevated (official requirement), so this
  # stop can be denied by the OS; then RTSS keeps running and the user closes
  # it from its own tray - logged, never an error, exit is never delayed long.
  try {
    $rp = Get-Process RTSS -ErrorAction SilentlyContinue
    if ($rp) {
      $rids = ($rp | ForEach-Object { $_.Id }) -join ','
      $rp | Stop-Process -Force -ErrorAction SilentlyContinue
      Start-Sleep -Milliseconds 500
      if (Get-Process RTSS -ErrorAction SilentlyContinue) {
        Log ("rtss stop denied (RTSS runs elevated), left running (pids=" + $rids + ")")
      } else {
        Log ("rtss stopped with pet (pids=" + $rids + ")")
      }
    }
  } catch { Log ("stop-rtss err: " + $_.Exception.Message) }
}

function Test-Autostart {
  try {
    $runVal = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'ZZZSunnaMonitor' -ErrorAction SilentlyContinue
    return ($null -ne $runVal)
  } catch { return $false }
}

function Set-Autostart([bool]$on) {
  # HKCU Run only: no admin needed, and it never touches the elevated guard
  # task (that one is managed separately via daemon\register_task.ps1).
  try {
    $rk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ($on) {
      New-ItemProperty -Path $rk -Name 'ZZZSunnaMonitor' -Value ('wscript.exe "' + (Join-Path $script:Root 'daemon\pet_launcher.vbs') + '"') -PropertyType String -Force | Out-Null
      Log 'autostart ON (HKCU Run ZZZSunnaMonitor)'
    } else {
      Remove-ItemProperty -Path $rk -Name 'ZZZSunnaMonitor' -ErrorAction SilentlyContinue
      Log 'autostart OFF'
    }
    return $true
  } catch {
    Log ("autostart err: " + $_.Exception.Message)
    return $false
  }
}

$script:LastModeLog = ''
$script:TickN = 0

function Refresh-Monitors {
  # the monitor set changed (a screen was plugged/unplugged): rebuild the
  # geometry tables, normalize the selected screen index, and pull the whole
  # arrangement back into the new virtual desktop - without this the pet either
  # sat on the dead monitor or kept stale cached monitor geometry
  Refresh-Mon
  Update-VBounds
  if ($script:ScreenIdx -ge $script:Mon.Count) {
    $script:ScreenIdx = 0
    [WhalePerf]::SetScreenIndex(0)
    Log 'selected screen no longer exists -> back to monitor 1'
  }
  if ($script:Mon.Count -gt 1) {
    $names = UArr 'names' @('1', '2', '3')
    $accName.Text = [string]$names[[Math]::Min($script:ScreenIdx, $names.Count - 1)]
  }
  [void](Ensure-PetOnScreen)   # a just-unplugged screen can leave the group inside a hole
  [void](Clamp-Group 'monitor-change')
  Sync-Layout
  foreach ($c in $script:Comps5) { Apply-Comp $c }
  Set-BubblePos
  Apply-Comp 'bubble'
  Save-Cfg
  Log ("monitor change handled: count={0} vdesk=({1},{2})-({3},{4}) pet=({5},{6})" -f `
    $script:Mon.Count, $script:VLeft, $script:VTop, $script:VRight, $script:VBottom, `
    [int]$script:Layout.pet.x, [int]$script:Layout.pet.y)
}

function Reset-Layout {
  # shared by the right-click menu and petcmd 'reset': rebuild the monitor
  # table first (defaults are centred on the CURRENT primary, not the table
  # cached at startup), then restore the default arrangement at scale 1.0
  Refresh-Mon; Update-VBounds
  $rd = Get-DefaultPositions
  foreach ($rk in $script:Comps5) {
    $script:Base[$rk].x = [double]$rd[$rk].x; $script:Base[$rk].y = [double]$rd[$rk].y
    $script:Base[$rk].s = [double]$rd[$rk].s
  }
  $script:GroupScale = 1.0
  Apply-All; Save-Cfg
}

$panelTimer = New-Object System.Windows.Threading.DispatcherTimer
$panelTimer.Interval = [TimeSpan]::FromSeconds(1)
$panelTimer.Add_Tick({
  try {
    $script:TickN++
    # monitor-set watchdog (every 5s): cheap snapshot compare. The C# table
    # refreshes itself every 2s; this notices when it changed.
    if (($script:TickN % 5) -eq 0) {
      $sig = ([WhalePerf]::MonSnapshot() -join ';')
      if ($script:MonSig -eq '') { $script:MonSig = $sig }
      elseif ($sig -ne $script:MonSig) { $script:MonSig = $sig; Refresh-Monitors }
    }
    $ig = [WhalePerf]::InGame
    # Safety valve (config: untopInGame): while a game is detected, drop the
    # topmost state so this always-on-top overlay cannot keep the game out of
    # its fast presentation path (exclusive fullscreen / independent flip).
    # This is the class of problem that can make a game slow *and* survive
    # quitting the pet (the game stays in the degraded mode until restarted).
    $wantTop = [bool]$script:Topmost
    if ($script:UntopInGame -and $ig) { $wantTop = $false }
    if ($wantTop -ne $script:AppliedTop) {
      $script:AppliedTop = $wantTop
      foreach ($k in $script:CompsAll) {
        try { $script:Wins[$k].Topmost = $wantTop } catch { }
      }
      Log ("topmost applied -> " + $wantTop + " (inGame=" + $ig + " userTopmost=" + $script:Topmost + " untopInGame=" + $script:UntopInGame + ")")
    }
    if ($wantTop -and ($script:TickN % 5) -eq 0) {
      # bubble last: it must sit above every other component
      foreach ($k in $script:CompsAll) {
        [WpmDpi]::Top($script:Hwnd[$k]); [WpmDpi]::NoTaskbar($script:Hwnd[$k])
      }
    }
    $fps = [int][WhalePerf]::Fps
    $script:PanelTxt.fps.Text = if ($fps -ge 0) { [string]$fps } else { '--' }
    $script:PanelLbl.fps.Text = if ($fps -lt 0) { (U 'labelFpsModeShort' 'FPS') } elseif ($ig) { (U 'modeGame' 'FPS/GAME') } else { (U 'modeDaily' 'REFRESH') }
    $script:PanelTxt.cpu.Text = [string][int][WhalePerf]::Cpu + '%'
    $script:PanelTxt.gpu.Text = [string][int][WhalePerf]::Gpu + '%'
    $script:PanelTxt.mem.Text = [string][WhalePerf]::Mem + '%'
    $ml = ("{0}|{1}|{2}" -f $ig, $fps, [WhalePerf]::FpsApp)
    if ($ml -ne $script:LastModeLog) {
      $script:LastModeLog = $ml
      Log ("mode -> {0} fps {1} how {2} app {3} rtss {4} gpu {5}" -f $(if ($ig) { 'game' } else { 'daily' }), $fps, [WhalePerf]::DetectHow, [WhalePerf]::FpsApp, $(if ([WhalePerf]::RtssOk) { 'ok' } else { 'down' }), [WhalePerf]::GpuSrc)
    }
  } catch { }
})
$panelTimer.Start()

$script:RtssMiss = 0
$script:RtssTries = 0
$script:RtssCmdAt = 0
$rtssGuard = New-Object System.Windows.Threading.DispatcherTimer
$rtssGuard.Interval = [TimeSpan]::FromSeconds(1)
$rtssGuard.Add_Tick({
  try {
    # the revive handoff file must not linger when the guard task is not
    # registered (nothing would ever consume it) - clean it up after 30s
    if ($script:RtssCmdAt -gt 0 -and ([DateTimeOffset]::Now.ToUnixTimeMilliseconds() - $script:RtssCmdAt) -gt 30000) {
      $cmdPath = Join-Path $script:Run 'command.txt'
      if (Test-Path $cmdPath) {
        Remove-Item $cmdPath -Force -ErrorAction SilentlyContinue
        Log 'stale command.txt removed (RTSS guard task not registered?)'
      }
      $script:RtssCmdAt = 0
    }
    if ([WhalePerf]::RtssOk) { $script:RtssMiss = 0; if ($script:RtssTries -gt 0) { $script:RtssTries = 0; Log 'rtss back online' }; return }
    $script:RtssMiss++
    if ($script:RtssMiss -ge 30 -and $script:RtssTries -lt 3) {
      $script:RtssTries++
      $script:RtssMiss = 0
      # direct start first: works on fresh user machines with no elevated guard
      # task; the task handoff below stays for setups where it is registered
      # (both are idempotent - they only start RTSS when it is not running)
      Start-RtssDirect
      Set-Content -Path (Join-Path $script:Run 'command.txt') -Value 'start-rtss' -Encoding UTF8
      $script:RtssCmdAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
      Start-Process -FilePath 'schtasks.exe' -ArgumentList '/run', '/tn', 'ZZZSunnaMonitor_RTSS' -WindowStyle Hidden
      Log ("rtss missing -> revive attempt " + $script:RtssTries)
    }
  } catch { }
})
$rtssGuard.Start()

# petcmd.txt automation hook
$script:CmdTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:CmdTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:CmdTimer.Add_Tick({
  try {
    if (-not (Test-Path $script:CmdF)) { return }
    $cmd = (Get-Content $script:CmdF -Raw -Encoding UTF8).Trim()
    Remove-Item $script:CmdF -Force -ErrorAction SilentlyContinue
    if (-not $cmd) { return }
    Log ("cmd <- " + $cmd)
    if ($cmd -eq 'quit') { $script:Closing = 'cmd quit'; $script:Wins.pet.Close(); return }
    elseif ($cmd -eq 'say') { Show-Bubble (Build-Line) }
    elseif ($cmd -eq 'state') {
      $g0 = [GC]::CollectionCount(0); $g1 = [GC]::CollectionCount(1); $g2 = [GC]::CollectionCount(2)
      Log ("state: emo={0} pose={1} topmost={2} screen={3} groupScale={4} petScale={5} managedMB={6} gc={7}/{8}/{9} clips={10}" -f $script:EmoName, $script:CurrentPose, $script:Topmost, $script:ScreenIdx, [Math]::Round([double]$script:GroupScale, 3), [Math]::Round([double]$script:Layout.pet.s, 3), [int]([System.GC]::GetTotalMemory($false) / 1MB), $g0, $g1, $g2, $script:Anims.Count)
    }
    elseif ($cmd -eq 'diag') {
      Log 'diag: start'
      foreach ($k in $script:CompsAll) {
        $line = 'diag ' + $k
        try { $line += ' | win=' + [WpmDpi]::RectInfo($script:Hwnd[$k]) } catch { $line += ' | win=ERR ' + $_.Exception.Message }
        try { $el = $script:Elems[$k]; $line += ' | wpf=' + [int]$el.ActualWidth + 'x' + [int]$el.ActualHeight } catch { $line += ' | wpf=ERR ' + $_.Exception.Message }
        try { $line += ' | scale=' + [Math]::Round([double]$script:WinDpi[$k], 3) } catch { $line += ' | scale=ERR' }
        Log $line
      }
      try {
        Log ("diag bubbleText: len={0} font={1} size={2}x{3} visibility={4} winvis={5}" -f $bubbleText.Text.Length, $bubbleText.FontSize, [int]$bubbleText.ActualWidth, [int]$bubbleText.ActualHeight, $bubbleText.Visibility, $bubbleWin.Visibility)
        Log ("diag bubbleTree: children={0} parent={1} desired={2}x{3} rootSize={4}x{5} cols={6} rows={7}" -f $bubbleRoot.Children.Count, $(if ($bubbleText.Parent) { $bubbleText.Parent.GetType().Name } else { 'NULL' }), [int]$bubbleText.DesiredSize.Width, [int]$bubbleText.DesiredSize.Height, [int]$bubbleRoot.ActualWidth, [int]$bubbleRoot.ActualHeight, $bubbleRoot.ColumnDefinitions.Count, $bubbleRoot.RowDefinitions.Count)
        Log ("diag bubbleText preview: [" + $bubbleText.Text + "]")
      } catch { Log ("diag bubbleText ERR: " + $_.Exception.Message) }
      Log 'diag: end'
    }
    elseif ($cmd -eq 'reload') { $script:CmdTimer.Stop(); $panelTimer.Stop(); $emoTimer.Stop(); $rtssGuard.Stop(); $hideTimer.Stop(); Log 'reload requested -> restarting process'; Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + (Join-Path $script:Root 'daemon\pet_launcher.vbs') + '"'); $script:Closing = 'reload'; $script:Wins.pet.Close(); return }
    elseif ($cmd -eq 'menu') { & $script:ShowMenu }
    elseif ($cmd -eq 'reset') {
      Reset-Layout
      Log ("reset (cmd) -> pet={0},{1} panel={2},{3} easel={4},{5}" -f [int]$script:Base.pet.x, [int]$script:Base.pet.y, [int]$script:Base.panel.x, [int]$script:Base.panel.y, [int]$script:Base.easel.x, [int]$script:Base.easel.y)
    }
    elseif ($cmd -eq 'monrefresh') { $script:MonSig = ''; Log 'monrefresh requested' }
    elseif ($cmd -eq 'geom') {
      Log ("geom vbounds: L={0} T={1} R={2} B={3} monCount={4}" -f $script:VLeft, $script:VTop, $script:VRight, $script:VBottom, $script:Mon.Count)
      foreach ($gk in $script:Comps5) {
        Log ("geom {0,-7} base=({1},{2}) s={3} | layout=({4},{5})" -f $gk, `
          [int]$script:Base[$gk].x, [int]$script:Base[$gk].y, [Math]::Round([double]$script:Base[$gk].s, 3), `
          [int]$script:Layout[$gk].x, [int]$script:Layout[$gk].y)
      }
      foreach ($gm in $script:Mon) {
        Log ("geom mon prim={0} ({1},{2}) {3}x{4}" -f $gm.prim, $gm.x, $gm.y, $gm.w, $gm.h)
      }
    }
    elseif ($cmd.StartsWith('saytext:')) {
      $tx = $cmd.Substring(8)
      Log ("saytext len=" + $tx.Length)
      Show-Bubble $tx
    }
    elseif ($cmd.StartsWith('sayfrom:')) {
      $pl = $cmd.Substring(8).Trim()
      $ln = Pick-Random (Get-Lines $pl)
      Log ("sayfrom " + $pl + " -> [" + $ln + "]")
      Show-Bubble $ln
    }
    elseif ($cmd -eq 'linetest') {
      # verify EVERY line in lines.json fits the bubble's inner box (auto-fit
      # must not have to shrink below 55% of the base font)
      $ltTot = 0; $ltBad = 0
      $ltBase = [double]$script:BubFontBase
      foreach ($ltPool in @($script:LineBank.Keys | Sort-Object)) {
        foreach ($ltLn in @($script:LineBank[$ltPool])) {
          $ltTot++
          $lt = ([string]$ltLn).Replace('{fps}', '160').Replace('{cpu}', '22').Replace('{gpu}', '40').Replace('{mem}', '55').Replace('{load}', '40')
          $ltFs = Measure-BubbleFont $lt ([double]$script:BubAvailW) ([double]$script:BubAvailH) $ltBase
          $ltOk = ($ltFs -ge ($ltBase * 0.55))
          if (-not $ltOk) { $ltBad++ }
          Log ("linetest {0,-12} len={1,2} fs={2,5} {3} [{4}]" -f $ltPool, $lt.Length, $ltFs, $(if ($ltOk) { 'ok' } else { 'WARN' }), $lt)
        }
      }
      Log ("linetest done: {0} lines, {1} below 55% of base font (avail {2}x{3} at base {4})" -f $ltTot, $ltBad, [int]$script:BubAvailW, [int]$script:BubAvailH, [Math]::Round($ltBase, 2))
    }
    elseif ($cmd -eq 'shot') { & $script:ShotAll }
    elseif ($cmd -eq 'rtss') {
      # report RTSS state, then run the same ensure path as startup
      $re2 = Get-RtssExe
      $rp2 = Get-Process RTSS -ErrorAction SilentlyContinue
      Log ("rtss cmd: exe=" + $(if ($re2 -ne '') { $re2 } else { 'NOT-FOUND' }) +
        " proc=" + $(if ($rp2) { ($rp2 | ForEach-Object { $_.Id }) -join ',' } else { 'none' }) +
        " shm=" + $(if ([WhalePerf]::RtssOk) { 'ok' } else { 'down' }) +
        " autostart=" + $(if (Test-Autostart) { 'on' } else { 'off' }))
      Ensure-Rtss
    }
    elseif ($cmd.StartsWith('pose:')) { $n = $cmd.Substring(5).Trim(); if (Set-Pose $n) { Log ("pose -> " + $n + " (cmd)") } }
    elseif ($cmd.StartsWith('screen:')) { $ix = 0; if ([int]::TryParse($cmd.Substring(7).Trim(), [ref]$ix)) { Set-Screen $ix } }
    elseif ($cmd.StartsWith('uclick:')) { $kd = $cmd.Substring(7).Trim(); Log ("uclick " + $kd); Invoke-Click $kd }
    elseif ($cmd.StartsWith('hittest:')) {
      $hk = $cmd.Substring(8).Trim()
      try {
        $hel = $script:Elems[$hk]
        $hw = [Math]::Max(1.0, [double]$hel.ActualWidth); $hhh = [Math]::Max(1.0, [double]$hel.ActualHeight)
        $hpt = New-Object System.Windows.Point ($hw / 2), ($hhh / 2)
        $hres = [System.Windows.Media.VisualTreeHelper]::HitTest($hel, $hpt)
        $hn = $hres.Count
        $hdesc = @()
        for ($hi = 0; $hi -lt [Math]::Min(3, $hn); $hi++) {
          $hv = $hres[$hi].VisualHit
          $hdesc += ($hv.GetType().Name + '[tag=' + [string]$hv.Tag + ']')
        }
        $hbg = 'n/a'
        try { if ($hel.Background -ne $null) { $hbg = 'brush' } else { $hbg = 'null' } } catch { $hbg = 'no-prop' }
        Log ("hittest {0}: el={1}x{2} hits={3} bg={4} hitvis={5} desc={6}" -f $hk, [int]$hw, [int]$hhh, $hn, $hbg, $hel.IsHitTestVisible, ($hdesc -join ' | '))
      } catch { Log ("hittest err: " + $_.Exception.Message) }
    }
    elseif ($cmd.StartsWith('udrag:')) {
      $p = $cmd.Split(':')
      if ($p.Count -ge 4) {
        $dx = 0; $dy = 0
        [void][int]::TryParse($p[2], [ref]$dx)
        [void][int]::TryParse($p[3], [ref]$dy)
        Begin-Drag $p[1]
        Update-Drag $dx $dy $true
        Complete-Drag
        Log ("udrag {0} {1},{2} -> {3},{4}" -f $p[1], $dx, $dy, [int]$script:Layout[$p[1]].x, [int]$script:Layout[$p[1]].y)
      }
    }
    elseif ($cmd.StartsWith('uwheel:')) {
      # uwheel:<delta>  (the old uwheel:<component>:<delta> form is also accepted)
      $p = $cmd.Split(':')
      $st = 0.0
      if ($p.Count -ge 3) { [void][double]::TryParse($p[2], [ref]$st) }
      elseif ($p.Count -eq 2) { [void][double]::TryParse($p[1], [ref]$st) }
      if ($st -ne 0) {
        Set-GroupScale ([double]$script:GroupScale + $st)
        Save-Cfg
        Log ("uwheel {0} -> groupScale={1}" -f $st, [Math]::Round([double]$script:GroupScale, 3))
      }
    }
  } catch {
    Log ("cmd err: " + $_.Exception.Message)
    try { Log ("cmd err at: " + ($_.InvocationInfo.PositionMessage -replace "`r?`n", ' | ')) } catch { }
  }
})
$script:CmdTimer.Start()

$script:NameOnly = 0
function Set-Screen([int]$i) {
  Refresh-Mon
  $n = $script:Mon.Count
  if ($n -le 0) { return }
  if ($i -lt 0 -or $i -ge $n) { $i = 0 }
  $script:ScreenIdx = $i
  [WhalePerf]::SetScreenIndex($i)
  $names = UArr 'names' @('1', '2', '3')
  if ($n -eq 1) {
    $script:NameOnly = (($script:NameOnly + 1) % [Math]::Max(1, $names.Count))
    $accName.Text = [string]$names[$script:NameOnly]
    Log ("screen pick -> " + $accName.Text + " (single monitor, label only)")
    # give the click visible feedback instead of silently doing nothing
    Show-Bubble (Pick-Random (Get-Lines 'single_screen'))
  } else {
    $accName.Text = [string]$names[[Math]::Min($i, $names.Count - 1)]
    Log ("screen pick -> " + $accName.Text + " (monitor " + ($i + 1) + " of " + $n + ")")
  }
  Save-Cfg
}
$script:CycleScreen = { Set-Screen ((($script:ScreenIdx + 1) % [Math]::Max(1, $script:Mon.Count))) }

function Shot-Comp([string]$k) {
  try {
    $el = $script:Elems[$k]
    $w = [int][Math]::Ceiling($el.ActualWidth); $h = [int][Math]::Ceiling($el.ActualHeight)
    if ($w -le 0 -or $h -le 0) {
      # element has no WPF layout size yet: fall back to the physical window rect
      $h2 = $script:Hwnd[$k]
      $rc = New-Object WpmDpi+RECT
      if ($h2 -ne [IntPtr]::Zero -and [WpmDpi]::GetClientRect($h2, [ref]$rc)) {
        $w = $rc.Right - $rc.Left; $h = $rc.Bottom - $rc.Top
      }
      if ($w -le 0 -or $h -le 0) { Log ("shot skip " + $k + ": no size"); return }
    }
    $rtb = New-Object -TypeName System.Windows.Media.Imaging.RenderTargetBitmap -ArgumentList @($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($el)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $p = Join-Path $script:ShotD ("{0}_{1}.png" -f (Get-Date -Format 'HHmmss'), $k)
    $fs = [System.IO.File]::Create($p)
    $enc.Save($fs); $fs.Close()
    Log ("shot -> " + $p + " (" + $w + "x" + $h + ")")
  } catch { Log ("shot err " + $k + ": " + $_.Exception.Message) }
}
$script:ShotAll = { foreach ($k in $script:CompsAll) { Shot-Comp $k } }

$script:ShowMenu = {
  try {
    $topH = if ($script:Topmost) { (U 'menuUntop' 'Cancel topmost') } else { (U 'menuTop' 'Topmost') }
    $menu = New-Object System.Windows.Controls.ContextMenu
    $mk = @(
      @{ h = (U 'menuSay' 'Say'); a = { Show-Bubble (Build-Line) } },
      @{ h = (U 'menuPose' 'Pose'); a = { Invoke-Click 'pet' } },
      @{ h = (U 'menuReset' 'Reset'); a = { Reset-Layout; Log ("reset (menu) -> pet={0},{1} easel={2},{3}" -f [int]$script:Base.pet.x, [int]$script:Base.pet.y, [int]$script:Base.easel.x, [int]$script:Base.easel.y) } },
      @{ h = (U 'menuScreen' 'Screen'); a = { & $script:CycleScreen } },
      @{ h = $topH; a = {
          $script:Topmost = -not $script:Topmost
          foreach ($k in $script:CompsAll) { $script:Wins[$k].Topmost = $script:Topmost }
          Save-Cfg; Log ("topmost -> " + $script:Topmost)
        } },
      @{ h = $(if (Test-Autostart) { (U 'menuAutoOn' 'Autostart: ON') } else { (U 'menuAutoOff' 'Autostart: OFF') }); a = {
          $asNew = -not (Test-Autostart)
          if (Set-Autostart $asNew) {
            if ($asNew) { Show-Bubble (U 'autoOnMsg' 'Autostart is ON - see you next boot!') }
            else { Show-Bubble (U 'autoOffMsg' 'Autostart is OFF.') }
          } else {
            Show-Bubble (U 'autoErrMsg' 'Could not change autostart.')
          }
        } },
      @{ h = (U 'menuQuit' 'Quit'); a = { $script:Closing = 'menu'; $script:Wins.pet.Close() } }
    )
    foreach ($m in $mk) {
      $mi = New-Object System.Windows.Controls.MenuItem
      $mi.Header = $m.h
      $mi.Add_Click($m.a)
      $menu.Items.Add($mi) | Out-Null
    }
    $menu.PlacementTarget = $script:Wins.pet
    $menu.IsOpen = $true
  } catch { Log ("menu err: " + $_.Exception.Message) }
}

# ---------------------------------------------------------------------------
# 12. shutdown
# ---------------------------------------------------------------------------
$script:Closing = 'window closed'
$petWin.Add_Closed({
  try {
    $script:CmdTimer.Stop(); $panelTimer.Stop(); $emoTimer.Stop(); $rtssGuard.Stop(); $hideTimer.Stop(); $animTimer.Stop(); $lineTimer.Stop()
    try { $rtssStartTimer.Stop() } catch { }
    [WhalePerf]::Stop()
    # the pet owns the RTSS lifetime: real shutdown stops RTSS with it - except
    # on 'reload', where a fresh instance takes over and RTSS must survive
    if ($script:Closing -ne 'reload') { Stop-Rtss }
    try { Remove-Item $script:PidF -Force -ErrorAction SilentlyContinue } catch { }
    Log ("pet v1 closed (" + $script:Closing + ")")
    try { $mutex.ReleaseMutex() } catch { }
    foreach ($k in 'panel', 'guitar', 'easel', 'bchan', 'bubble') {
      try { $script:Wins[$k].Close() } catch { }
    }
    # end the (non-modal) message loop started at the bottom of this script
    try { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } catch { }
  } catch { }
})
# hooking a .NET event must use its add_ accessor; "$x.Event.Add_Handler" hits
# the event's null backing field and throws InvokeMethodOnNull (silent in the
# hidden launcher since v4.4 - the global exception log never actually attached)
$petWin.Dispatcher.add_UnhandledException({
  param($s, $e)
  Log ("DISPATCHER-EXC: " + $e.Exception.Message)
  $e.Exception.ToString().Split("`n") | Select-Object -First 6 | ForEach-Object { Log ("  " + $_.Trim()) }
  $e.Handled = $true
})

# ---------------------------------------------------------------------------
# 13. go
# ---------------------------------------------------------------------------
Save-Cfg
Set-Pose 'idle' | Out-Null
$script:EmoName = 'idle'
$script:LastPoseAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
Arm-LineTimer
Show-Bubble (Build-Line)
$script:NameList = UArr 'names' @('1', '2', '3')
$accName.Text = [string]$script:NameList[[Math]::Min($script:ScreenIdx, $script:NameList.Count - 1)]
Log ("pet v1 started dpi=" + $script:DpiState + " monitors=" + $script:Mon.Count + " screen=" + $script:ScreenIdx + " groupScale=" + [Math]::Round([double]$script:GroupScale, 3) + " petAr=" + [Math]::Round($script:PetAr, 3))
Log ("geometry: vdesk=" + $script:VLeft + "," + $script:VTop + " " + ($script:VRight - $script:VLeft) + "x" + ($script:VBottom - $script:VTop) + " | pet=" + [int]$script:Layout.pet.x + "," + [int]$script:Layout.pet.y + " " + $script:Size.pet.w + "x" + $script:Size.pet.h + " | panel=" + [int]$script:Layout.panel.x + "," + [int]$script:Layout.panel.y + " " + $script:Size.panel.w + "x" + $script:Size.panel.h)
foreach ($m in $script:Mon) { Log ("monitor {0} prim={1} {2},{3} {4}x{5} work {6},{7} {8}x{9} hz={10}" -f $m.name, $m.prim, $m.x, $m.y, $m.w, $m.h, $m.wx, $m.wy, $m.ww, $m.wh, $m.hz) }
Log ("gpu src=" + [WhalePerf]::GpuSrc + " nvml=" + [WhalePerf]::NvmlOk + " | rtss ver=" + [WhalePerf]::RtssVer + " entry=" + [WhalePerf]::RtssEntrySize + " count=" + [WhalePerf]::RtssCount)
# Show the pet window WITHOUT modality.  ShowDialog() disables every other
# window of the process (WPF modality), which silently killed all mouse input to
# the component windows - clicks and the wheel appeared "dead".  The pet window
# is activated once so that wheel routing stays inside this process (Windows
# sends WM_MOUSEWHEEL to the focused window).
$petWin.Show()
[WpmDpi]::NoTaskbar($script:Hwnd.pet)
try { [void]$petWin.Activate() } catch { }

# RTSS lifecycle: if installed, make sure it is running - covers machines where
# RTSS missed its own autostart (fresh user installs). Deferred a few seconds
# into the message loop: starting a process (and the COM shortcut call) must
# NOT delay Dispatcher.Run(), or the first paint and window enumeration lag.
$rtssStartTimer = New-Object System.Windows.Threading.DispatcherTimer
$rtssStartTimer.Interval = [TimeSpan]::FromSeconds(3)
$rtssStartTimer.Add_Tick({
  try { Ensure-Rtss } catch { }
  try { $rtssStartTimer.Stop() } catch { }
})
$rtssStartTimer.Start()

# Auto-create a desktop shortcut once, on first launch of a fresh copy: the pet
# itself already sits ON the desktop, so the shortcut only matters for relaunch
# later.  A marker file in runtime\ (never shipped, never overwritten) makes
# this strictly once - if the user deletes the icon it will NOT come back.
try {
  $scMark = Join-Path $script:Run 'shortcut.created'
  if (-not (Test-Path $scMark)) {
    $desk = [Environment]::GetFolderPath('Desktop')
    if ($desk) {
      # NO Chinese literal here (pure-ASCII rule): the display name comes from
      # assets\ui.json "shortcutName"; the English fallback keeps this file ASCII
      $scPath = Join-Path $desk ((U 'shortcutName' 'ZZZ Chinatsu Monitor') + '.lnk')
      if (-not (Test-Path $scPath)) {
        $sc = New-Object -ComObject WScript.Shell
        $lnk = $sc.CreateShortcut($scPath)
        $lnk.TargetPath = 'wscript.exe'
        $lnk.Arguments = ('"' + (Join-Path $script:Root 'daemon\pet_launcher.vbs') + '"')
        $lnk.WorkingDirectory = $script:Root
        $lnk.IconLocation = (Join-Path $script:Assets 'petmon.ico') + ',0'
        $lnk.Save()
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($sc)
        Log 'desktop shortcut created'
      }
    }
    Set-Content -Path $scMark -Value '1' -Encoding ASCII
  }
} catch { Log ("desktop shortcut err: " + $_.Exception.Message) }
try { [System.Windows.Threading.Dispatcher]::Run() } catch { Log ("RUN-THREW: " + $_.Exception.Message) }
Log 'pet message loop exited'
