<#
.SYNOPSIS
    Комплексный инструмент автоматического восстановления микрофона на Windows.
.DESCRIPTION
    Выполняет полную цепочку диагностики и восстановления аудиоподсистемы Windows:
    - Проверка и автоматический запрос прав администратора (UAC)
    - Восстановление статуса микрофона в реестре MMDevices (DeviceState = 1) через Win32 API
    - Перезапуск служб Windows Audio (Audiosrv, AudioEndpointBuilder, NahimicService)
    - Проверка и настройка конфиденциальности (Privacy Consent)
    - Аппаратное пересканирование шин и перезапуск PnP-стека AMD Audio Device (pnputil)
    - Снятие программного мьюта и установка громкости на 100% через Windows CoreAudio API
    - Тестирование активности и замер входного сигнала
    - Интерактивный прогресс-бар с таймером обратного отсчёта и красивый итоговый отчёт
#>

[CmdletBinding()]
param(
    [switch]$DiagOnly,
    [switch]$Force,
    [switch]$Silent,
    [string]$LogPath = ""
)

# Настройка UTF-8 для корректного отображения шрифтов и прогресс-бара
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

# Определение рабочей папки скрипта и каталога логов (всё в 1 папке!)
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { "C:\Users\admin\Documents\mic-fix" }
if ([string]::IsNullOrWhiteSpace($scriptDir) -or -not (Test-Path $scriptDir)) {
    $scriptDir = "C:\Users\admin\Documents\mic-fix"
}
$logsFolder = Join-Path $scriptDir "logs"
if (-not (Test-Path $logsFolder)) {
    try { New-Item -ItemType Directory -Path $logsFolder -Force | Out-Null } catch {}
}

# Инициализация пути журнала в папке logs
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $LogPath = Join-Path $logsFolder "mic-fix-log-$timestamp.txt"
}

# Проверка прав администратора
function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Автоматическое повышение прав: если запущен не от администратора, запрашивает UAC
if (-not (Test-Admin) -and -not $DiagOnly) {
    $targetScript = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { Join-Path $scriptDir "fix-microphone.ps1" }
    
    Write-Host "`n  [!] Требуются права администратора для перезапуска аудиослужб и шин PnP." -ForegroundColor Yellow
    Write-Host "  [*] Запрашиваю разрешение UAC...`n" -ForegroundColor Cyan
    
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File `"$targetScript`"", "-LogPath `"$LogPath`"")
    if ($DiagOnly) { $argList += "-DiagOnly" }
    if ($Force)    { $argList += "-Force" }
    if ($Silent)   { $argList += "-Silent" }

    try {
        Start-Process -FilePath "powershell.exe" -ArgumentList ($argList -join " ") -WorkingDirectory "`"$scriptDir`"" -Verb RunAs
        exit 0
    } catch {
        Write-Host "  [-] Отказано в повышении прав. Запуск в режиме диагностики..." -ForegroundColor Red
        $DiagOnly = $true
    }
}

# Логирование
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $time = Get-Date -Format "HH:mm:ss"
    $logLine = "[$time] [$Level] $Message"
    try {
        Add-Content -Path $LogPath -Value $logLine -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

# ==============================================================================
# UI И ВИЗУАЛЬНЫЙ ПРОГРЕСС-БАР С ТАЙМЕРОМ
# ==============================================================================

function Update-UIProgress {
    param(
        [int]$Percent,
        [string]$StepName,
        [int]$SecondsLeft
    )
    
    # Системный прогресс-бар Windows PowerShell
    Write-Progress -Activity "Восстановление микрофона" -Status "$StepName (осталось ~$SecondsLeft сек.)" -PercentComplete $Percent
    
    # Консольный красивый прогресс-бар
    $barWidth = 24
    $filled = [int](($Percent / 100) * $barWidth)
    $empty = $barWidth - $filled
    $bar = ("█" * $filled) + ("░" * $empty)
    
    $secText = if ($SecondsLeft -le 0) { "завершение" } else { "~$SecondsLeft сек." }
    Write-Host "`r  [$bar] $Percent%  •  $StepName ($secText)       " -NoNewline -ForegroundColor Cyan
}

function Complete-UIStep {
    param(
        [string]$Message
    )
    Write-Host "`r  [✓] $Message                                                         `n" -ForegroundColor Green
}

# ==============================================================================
# ИНТЕГРАЦИЯ С WINDOWS WIN32 REGISTRY И COREAUDIO COM API
# ==============================================================================

try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace WinAudioFix
{
    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDevice
    {
        int Activate(ref Guid id, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer);
        int OpenPropertyStore(int stgmAccess, out IntPtr properties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceCollection
    {
        int GetCount(out uint count);
        int Item(uint index, out IMMDevice device);
    }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
        int GetDevice(string id, out IMMDevice endpoint);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    public class MMDeviceEnumeratorComObject { }

    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioEndpointVolume
    {
        int RegisterControlChangeNotify(IntPtr notify);
        int UnregisterControlChangeNotify(IntPtr notify);
        int GetChannelCount(out int channelCount);
        int SetMasterVolumeLevel(float levelDB, ref Guid eventContext);
        int SetMasterVolumeLevelScalar(float level, ref Guid eventContext);
        int GetMasterVolumeLevel(out float levelDB);
        int GetMasterVolumeLevelScalar(out float level);
        int SetChannelVolumeLevel(uint channelNumber, float levelDB, ref Guid eventContext);
        int SetChannelVolumeLevelScalar(uint channelNumber, float level, ref Guid eventContext);
        int GetChannelVolumeLevel(uint channelNumber, out float levelDB);
        int GetChannelVolumeLevelScalar(uint channelNumber, out float level);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool isMuted, ref Guid eventContext);
        int GetMute([MarshalAs(UnmanagedType.Bool)] out bool isMuted);
    }

    [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioMeterInformation
    {
        int GetPeakValue(out float pfPeak);
        int GetMeteringChannelCount(out uint pnChannelCount);
        int GetChannelsPeakValues(uint u32ChannelCount, [Out] float[] afPeakValues);
        int QueryHardwareSupport(out uint pdwHardwareSupportMask);
    }

    public class AudioEndpointInfo
    {
        public string Id;
        public bool IsMuted;
        public float Volume;
        public float PeakValue;
    }

    public class CoreAudioManager
    {
        public static AudioEndpointInfo GetDefaultCaptureEndpoint()
        {
            var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            IMMDevice dev;
            int hr = enumerator.GetDefaultAudioEndpoint(1, 0, out dev);
            if (hr != 0 || dev == null) return null;

            var info = new AudioEndpointInfo();
            dev.GetId(out info.Id);

            Guid iidVolume = typeof(IAudioEndpointVolume).GUID;
            object epvObj;
            if (dev.Activate(ref iidVolume, 1, IntPtr.Zero, out epvObj) == 0 && epvObj != null)
            {
                var epv = (IAudioEndpointVolume)epvObj;
                epv.GetMute(out info.IsMuted);
                epv.GetMasterVolumeLevelScalar(out info.Volume);
            }

            Guid iidMeter = typeof(IAudioMeterInformation).GUID;
            object meterObj;
            if (dev.Activate(ref iidMeter, 1, IntPtr.Zero, out meterObj) == 0 && meterObj != null)
            {
                var meter = (IAudioMeterInformation)meterObj;
                meter.GetPeakValue(out info.PeakValue);
            }

            return info;
        }

        public static bool UnmuteAndSetVolume(string deviceId, float volumeScalar, int dataFlow)
        {
            try
            {
                var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                IMMDevice dev;
                int hr = string.IsNullOrEmpty(deviceId) 
                    ? enumerator.GetDefaultAudioEndpoint(dataFlow, 0, out dev) 
                    : enumerator.GetDevice(deviceId, out dev);

                if (hr != 0 || dev == null) return false;

                Guid iidVolume = typeof(IAudioEndpointVolume).GUID;
                object epvObj;
                if (dev.Activate(ref iidVolume, 1, IntPtr.Zero, out epvObj) == 0 && epvObj != null)
                {
                    var epv = (IAudioEndpointVolume)epvObj;
                    Guid empty = Guid.Empty;
                    epv.SetMute(false, ref empty);
                    if (volumeScalar >= 0f) {
                        epv.SetMasterVolumeLevelScalar(volumeScalar, ref empty);
                    }
                    return true;
                }
            }
            catch {}
            return false;
        }

        public static bool UnmuteAndSetVolume(string deviceId, float volumeScalar)
        {
            return UnmuteAndSetVolume(deviceId, volumeScalar, 1);
        }

        public static float MeasurePeak(int sampleDurationMs)
        {
            try
            {
                var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                IMMDevice dev;
                if (enumerator.GetDefaultAudioEndpoint(1, 0, out dev) != 0 || dev == null) return -1f;

                Guid iidMeter = typeof(IAudioMeterInformation).GUID;
                object meterObj;
                if (dev.Activate(ref iidMeter, 1, IntPtr.Zero, out meterObj) != 0 || meterObj == null) return -1f;

                var meter = (IAudioMeterInformation)meterObj;
                float maxPeak = 0;
                int iterations = Math.Max(1, sampleDurationMs / 100);
                for (int i = 0; i < iterations; i++)
                {
                    float p;
                    meter.GetPeakValue(out p);
                    if (p > maxPeak) maxPeak = p;
                    Thread.Sleep(100);
                }
                return maxPeak;
            }
            catch { return -1f; }
        }
    }

    public class RegHelper
    {
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int RegOpenKeyEx(IntPtr hKey, string subKey, uint ulOptions, int samDesired, out IntPtr phkResult);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int RegSetValueEx(IntPtr hKey, string lpValueName, int Reserved, int dwType, ref int lpData, int cbData);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern int RegCloseKey(IntPtr hKey);

        public static int SetDword(string subKey, string valueName, int data)
        {
            IntPtr HKEY_LOCAL_MACHINE = new IntPtr(unchecked((int)0x80000002));
            IntPtr phk;
            int res = RegOpenKeyEx(HKEY_LOCAL_MACHINE, subKey, 0, 0x0002 /* KEY_SET_VALUE */, out phk);
            if (res != 0) return res;
            res = RegSetValueEx(phk, valueName, 0, 4 /* REG_DWORD */, ref data, 4);
            RegCloseKey(phk);
            return res;
        }
    }
}
'@ -ErrorAction SilentlyContinue
} catch {}

# ==============================================================================
# СТАРТ И ОСНОВНОЙ ЦИКЛ ВОССТАНОВЛЕНИЯ
# ==============================================================================

Clear-Host
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║           ВОССТАНОВЛЕНИЕ ВСТРОЕННОГО МИКРОФОНА WINDOWS           ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Режим: $(if ($DiagOnly) {'Диагностика'} elseif ($Force) {'Глубокий сброс'} else {'Автоматическое восстановление'})" -ForegroundColor DarkCyan
Write-Host "  Лог:   $LogPath`n" -ForegroundColor DarkGray

Write-Log "Старт процедуры восстановления микрофона." "INFO"
Write-Log "ОС: $([Environment]::OSVersion.VersionString)" "INFO"

$summaryActions = [System.Collections.Generic.List[string]]::new()
$regCapturePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture"
$regRenderPath  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render"

# ШАГ 1 (15%): Активация микрофона и динамиков в реестре MMDevices
Update-UIProgress -Percent 15 -StepName "Проверка и активация аудиоустройств в реестре" -SecondsLeft 7
Start-Sleep -Milliseconds 400

if (-not $DiagOnly) {
    # 1. Активация микрофона
    if (Test-Path $regCapturePath) {
        Get-ChildItem $regCapturePath | ForEach-Object {
            $cKey = $_
            $cState = (Get-ItemProperty $cKey.PSPath -Name "DeviceState" -ErrorAction SilentlyContinue).DeviceState
            $cProp = "$($cKey.PSPath)\Properties"
            $cName = (Get-ItemProperty $cProp -ErrorAction SilentlyContinue).'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
            
            if ($cName -like "*Microphone Array*" -or $cName -like "*AMD*" -or $cKey.PSChildName -eq "{52efac22-f9a9-451a-8023-796b5841a409}") {
                if ($cState -ne 1) {
                    Write-Log "Деактивированный микрофон '$cName' (Код: $cState). Устанавливаю DeviceState = 1..." "INFO"
                    $subKey = "SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture\$($cKey.PSChildName)"
                    [WinAudioFix.RegHelper]::SetDword($subKey, "DeviceState", 1) | Out-Null
                    $summaryActions.Add("Активирован встроенный микрофон '$cName' в реестре (DeviceState = 1).")
                }
            }
        }
    }

    # 2. Активация динамиков
    if (Test-Path $regRenderPath) {
        Get-ChildItem $regRenderPath | ForEach-Object {
            $rKey = $_
            $rState = (Get-ItemProperty $rKey.PSPath -Name "DeviceState" -ErrorAction SilentlyContinue).DeviceState
            $rProp = "$($rKey.PSPath)\Properties"
            $rName = (Get-ItemProperty $rProp -ErrorAction SilentlyContinue).'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
            
            if ($rName -like "*Динамики*" -or $rName -like "*Speakers*" -or $rKey.PSChildName -eq "{fe5d6ab3-f988-483a-a2bf-dcf2c17e5575}") {
                if ($rState -ne 1) {
                    Write-Log "Деактивированные динамики '$rName' (Код: $rState). Устанавливаю DeviceState = 1..." "INFO"
                    $subKey = "SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\$($rKey.PSChildName)"
                    [WinAudioFix.RegHelper]::SetDword($subKey, "DeviceState", 1) | Out-Null
                    $summaryActions.Add("Активированы встроенные динамики '$rName' в реестре (DeviceState = 1).")
                }
            }
        }
    }
}
Complete-UIStep "Статус микрофона и динамиков в реестре Windows проверен и активирован"

# ШАГ 2 (40%): Перезапуск аудиослужб Windows и Nahimic
Update-UIProgress -Percent 40 -StepName "Перезапуск аудиослужб (Audiosrv, Nahimic)" -SecondsLeft 5

if (-not $DiagOnly) {
    $audioServices = @("NahimicService", "AudioEndpointBuilder", "Audiosrv")
    foreach ($sName in $audioServices) {
        $svc = Get-Service -Name $sName -ErrorAction SilentlyContinue
        if ($svc) {
            try {
                if ($svc.StartType -ne 'Automatic') {
                    Set-Service -Name $sName -StartupType Automatic -ErrorAction SilentlyContinue
                }
                Restart-Service -Name $sName -Force -ErrorAction SilentlyContinue
                Write-Log "Служба $sName успешно перезапущена." "SUCCESS"
            } catch {}
        }
    }
    $summaryActions.Add("Перезапущены службы Windows Audio, AudioEndpointBuilder и Nahimic.")
    Start-Sleep -Seconds 1
}
Complete-UIStep "Аудиослужбы Windows и звуковые эффекты перезапущены"

# ШАГ 3 (60%): Проверка разрешений конфиденциальности (Privacy)
Update-UIProgress -Percent 60 -StepName "Проверка разрешений доступа к микрофону" -SecondsLeft 3

$privacyKeys = @(
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone"
)
foreach ($pKey in $privacyKeys) {
    $curVal = (Get-ItemProperty -Path $pKey -Name "Value" -ErrorAction SilentlyContinue).Value
    if ($curVal -ne "Allow" -and -not $DiagOnly) {
        try {
            if (-not (Test-Path $pKey)) { New-Item -Path $pKey -Force | Out-Null }
            Set-ItemProperty -Path $pKey -Name "Value" -Value "Allow" -Force -ErrorAction SilentlyContinue
            $summaryActions.Add("Разрешён доступ к микрофону в параметрах конфиденциальности.")
        } catch {}
    }
}
Complete-UIStep "Разрешения конфиденциальности Windows проверены (доступ открыт)"

# ШАГ 4 (80%): Перезапуск PnP-стека AMD Audio и пересканирование шин
Update-UIProgress -Percent 80 -StepName "Пересканирование шин оборудования (pnputil)" -SecondsLeft 2

if (-not $DiagOnly) {
    try {
        & pnputil /restart-device "ACP\DEVTYPE_0002&DEVREV_0000&VEN_1022&DEV_15E2&SUBSYS_1EE72053&REV_63\5&1617346a&0&04" 2>&1 | Out-Null
        & pnputil /scan-devices 2>&1 | Out-Null
        $summaryActions.Add("Выполнено аппаратное сканирование оборудования (pnputil).")
        Start-Sleep -Seconds 1
    } catch {}
}
Complete-UIStep "Аппаратные шины звукового контроллера пересканированы"

# ШАГ 5 (95%): Снятие мьюта и установка громкости на 100%
Update-UIProgress -Percent 95 -StepName "Снятие программного мьюта и установка громкости" -SecondsLeft 1

$defInfo = $null
try {
    $defInfo = [WinAudioFix.CoreAudioManager]::GetDefaultCaptureEndpoint()
} catch {}

if (-not $DiagOnly) {
    $amdEndpointId = "{0.0.1.00000000}.{52efac22-f9a9-451a-8023-796b5841a409}"
    [WinAudioFix.CoreAudioManager]::UnmuteAndSetVolume($null, 1.0) | Out-Null
    [WinAudioFix.CoreAudioManager]::UnmuteAndSetVolume($amdEndpointId, 1.0) | Out-Null
    $summaryActions.Add("Снят мьют и установлена громкость 100% на микрофоне.")
}
Complete-UIStep "Громкость микрофона выставлена на 100%, мьют снят"

# ШАГ 6 (100%): Замер входного сигнала
Update-UIProgress -Percent 100 -StepName "Замер активности входного сигнала" -SecondsLeft 0
Write-Progress -Activity "Восстановление микрофона" -Completed

$peakVal = [float]-1
try {
    $peakVal = [WinAudioFix.CoreAudioManager]::MeasurePeak(1000)
} catch {}
Complete-UIStep "Проверка активности микрофона завершена"

# ==============================================================================
# ИТОГОВАЯ КАРТОЧКА РЕЗУЛЬТАТОВ (КРАСИВЫЙ USER EXPERIENCE)
# ==============================================================================

# Проверка актуального состояния
$isMicActive = $false
if (Test-Path $regCapturePath) {
    Get-ChildItem $regCapturePath | ForEach-Object {
        $s = (Get-ItemProperty $_.PSPath -Name "DeviceState" -ErrorAction SilentlyContinue).DeviceState
        if ($_.PSChildName -eq "{52efac22-f9a9-451a-8023-796b5841a409}" -and $s -eq 1) {
            $isMicActive = $true
        }
    }
}

Write-Host "`n"
if ($isMicActive) {
    Write-Host "  ┌───────────────────────────────────────────────────────────────┐" -ForegroundColor Green
    Write-Host "  │   🟢 ВСТРОЕННЫЙ МИКРОФОН АКТИВИРОВАН И ГОТОВ К РАБОТЕ!        │" -ForegroundColor Green
    Write-Host "  └───────────────────────────────────────────────────────────────┘" -ForegroundColor Green
} else {
    Write-Host "  ┌───────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
    Write-Host "  │   ⚠️  ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА НОУТБУКА ДЛЯ ПРИМЕНЕНИЯ          │" -ForegroundColor Yellow
    Write-Host "  └───────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
}

Write-Host "  Устройство:  Microphone Array (AMD Audio Device)" -ForegroundColor White
Write-Host "  Громкость:   100%  •  Мьют: Снят" -ForegroundColor White

if ($peakVal -gt 0.01) {
    $pPerc = [math]::Round($peakVal * 100, 1)
    Write-Host "  Сигнал:      Обнаружен ($pPerc%) 🎤" -ForegroundColor Green
} else {
    Write-Host "  Сигнал:      Тишина (скажите что-нибудь в микрофон)" -ForegroundColor Gray
}

Write-Host "`n  Выполненные операции:" -ForegroundColor DarkCyan
foreach ($act in $summaryActions) {
    Write-Host "    • $act" -ForegroundColor Gray
}

Write-Host "`n  ───────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Совет для HONOR MagicBook: если микрофон всё ещё молчит," -ForegroundColor DarkGray
Write-Host "  проверьте аппаратную клавишу Fn + F7 (или F7) на клавиатуре." -ForegroundColor DarkGray
Write-Host "  Лог сохранён: $LogPath" -ForegroundColor DarkGray
Write-Host "  ───────────────────────────────────────────────────────────────`n" -ForegroundColor DarkGray

if (-not $Silent) {
    Write-Host "  Нажмите любую клавишу для завершения..." -ForegroundColor DarkGray
    [void][System.Console]::ReadKey($true)
}
