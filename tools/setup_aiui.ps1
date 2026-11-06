# 从讯飞 AIUI Android SDK 官方 zip 还原原生依赖
#
# 用法（在仓库根目录）：
#   pwsh -File tools/setup_aiui.ps1 -SdkZip "C:\Users\你\Downloads\Android_aiui_soft_6.7.0001.0007.zip"
#
# 做完这一步，android/app 下就补回了：
#   libs/AIUI.jar, libs/xrtcsdk.aar
#   src/main/jniLibs/{arm64-v8a,armeabi-v7a}/{libaiui.so,libvtn_mic1.so}
#   src/main/assets/vad/evad_16k.jet
#   src/main/assets/ivw/vtn/{vtn.ini,res.bin}
#   src/main/assets/cfg/{aiui_phone.cfg,msc.cfg}
#
# 这些东西不进 Git 的原因：第三方闭源二进制 + 合计约 60MB + cfg 里含密钥。

param(
  [Parameter(Mandatory = $true)][string]$SdkZip
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SdkZip)) { throw "找不到 SDK zip：$SdkZip" }

$root = Split-Path -Parent $PSScriptRoot
$appDir = Join-Path $root 'android\app'
if (-not (Test-Path $appDir)) { throw "请把脚本放在 <repo>/tools 下，当前找不到 android\app" }

$tmp = Join-Path $env:TEMP ("aiui_sdk_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
Write-Host "解压 $SdkZip → $tmp"
Expand-Archive -Path $SdkZip -DestinationPath $tmp -Force

# zip 里通常多一层 Android_aiui_soft_xxx 目录
$src = Get-ChildItem $tmp -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'libs') } | Select-Object -First 1
if (-not $src) { throw "zip 结构不对，找不到含 libs 的目录" }
$s = $src.FullName
Write-Host "SDK 根目录：$s"

function Copy-Into([string]$from, [string]$to) {
  if (-not (Test-Path $from)) { Write-Warning "缺少 $from，跳过"; return }
  New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force | Out-Null
  Copy-Item $from $to -Force
  Write-Host "  + $to"
}

# ---- jar / aar ----
Copy-Into (Join-Path $s 'libs\AIUI.jar') (Join-Path $appDir 'libs\AIUI.jar')

$aar = Get-ChildItem (Join-Path $s 'libs') -Filter 'xrtc*.aar' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if ($aar) {
  Copy-Into $aar.FullName (Join-Path $appDir 'libs\xrtcsdk.aar')
} else {
  Write-Warning "没找到 xrtcsdk*.aar"
}

# ---- so ----
foreach ($abi in @('arm64-v8a', 'armeabi-v7a')) {
  foreach ($so in @('libaiui.so', 'libvtn_mic1.so')) {
    Copy-Into (Join-Path $s "libs\$abi\$so") (Join-Path $appDir "src\main\jniLibs\$abi\$so")
  }
}

# ---- assets ----
Copy-Into (Join-Path $s 'assets\vad\evad_16k.jet') (Join-Path $appDir 'src\main\assets\vad\evad_16k.jet')
Copy-Into (Join-Path $s 'assets\ivw\vtn\vtn.ini')   (Join-Path $appDir 'src\main\assets\ivw\vtn\vtn.ini')
Copy-Into (Join-Path $s 'assets\ivw\vtn\res.bin')   (Join-Path $appDir 'src\main\assets\ivw\vtn\res.bin')
Copy-Into (Join-Path $s 'assets\cfg\msc.cfg')       (Join-Path $appDir 'src\main\assets\cfg\msc.cfg')

# ---- cfg：已存在就不覆盖（里面填了你的密钥）----
$cfgTarget = Join-Path $appDir 'src\main\assets\cfg\aiui_phone.cfg'
if (Test-Path $cfgTarget) {
  Write-Host "  = aiui_phone.cfg 已存在，保留你原来的（不覆盖）"
} else {
  Copy-Into (Join-Path $s 'assets\cfg\aiui_phone.cfg') $cfgTarget
  Write-Host ""
  Write-Host "下一步：编辑 android/app/src/main/assets/cfg/aiui_phone.cfg" -ForegroundColor Yellow
  Write-Host "  把 login.appid / api_secret / key 换成你自己的（控制台 → 语音交互 → AIUI）" -ForegroundColor Yellow
  Write-Host "  文件里的注释也可以参考 aiui_phone.cfg.example" -ForegroundColor Yellow
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "完成。现在可以 flutter build apk --release" -ForegroundColor Green
