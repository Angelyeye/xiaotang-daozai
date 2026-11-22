<#
常驻版屏幕 OCR 服务（配合 scripts/agent-screen-ocr.ps1 使用）。

背景：`agent-screen-ocr.ps1` 每次调用都要重新启动 PowerShell、编译 P/Invoke、初始化 WinRT
和 OCR 引擎，单次约 1.8~1.9 秒，其中真正的识别只占几百毫秒。真机 E2E 一次要调用几十次，
绝大部分时间都花在「进程启动 + 引擎初始化」上。

本脚本把这些一次性代价摊到常驻进程里：启动时初始化一次，之后从 stdin 逐行读 JSON 请求，
逐行写 JSON 结果（与 `agent-screen-ocr.ps1` 输出结构完全一致），单次识别只付识别本身的成本。

协议（一行一条，UTF-8，无 BOM）：
  请求: {"id":1,"region":[l,t,r,b],"scale":2,"scales":[2,3],"find":"允许",
          "image":"C:\\a.png","saveImage":"out.png","cropSave":true,"cropCard":true,
          "language":"zh-Hans-CN"}
  响应: {"id":1,"ok":true,"region":[...],"language":"zh-Hans-CN","scales":[2],"attempts":[...],
          "lineCount":9,"ocrText":"...","lines":[...],"find":{...}}
  退出: stdin 关闭，或收到 {"id":N,"quit":true}

自检：`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\agent-screen-ocr-serve.ps1 -Once -Region 0,0,64,64`
（跑一次识别就退出，等价于旧脚本的 -Region/-Scale 用法，用于验证环境健康）

本文件必须保存为 UTF-8 with BOM，否则 Windows PowerShell 5.1 会按本地代码页解析中文而报错。
#>
[CmdletBinding()]
param(
  # 自检模式：处理一次（用这里的参数）就退出，方便人工确认环境。
  [switch]$Once,
  [string]$Region,
  [string]$ImagePath,
  [string]$Find,
  [int]$Scale = 2,
  [string]$Language,
  [string]$OutFile,
  [string]$SaveImage,
  [switch]$CropSave,
  [switch]$CropCard,
  [switch]$Pretty
)

$ErrorActionPreference = 'Stop'

# ---------- 一次性初始化 ----------
Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

try {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DaozaiOcrServeDpi {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
}
'@
  $null = [DaozaiOcrServeDpi]::SetProcessDpiAwareness(2)
} catch { try { $null = [DaozaiOcrServeDpi]::SetProcessDPIAware() } catch {} }

$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]

$script:AsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() |
  Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
                 $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } |
  Select-Object -First 1
function Await($operation, [Type]$resultType) {
  $task = $script:AsTask.MakeGenericMethod($resultType).Invoke($null, @($operation))
  $task.Wait(-1) | Out-Null
  $task.Result
}

$script:Engine = $null
$script:EngineTag = $null
function Get-OcrLanguages {
  try { @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag }) } catch { @() }
}
function Get-OcrEngine([string]$tag) {
  if ($script:Engine -and $script:EngineTag -eq $tag) { return $script:Engine }
  if ($tag) {
    try {
      $lang = New-Object Windows.Globalization.Language($tag)
      $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
      if ($engine) { $script:Engine = $engine; $script:EngineTag = $tag; return $engine }
    } catch {}
    throw "OCR 语言不可用: $tag（可用: $((Get-OcrLanguages) -join ', ')）"
  }
  $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  if (-not $engine) { throw '系统没有可用的 OCR 语言包（设置 → 时间和语言 → 语言，添加中文识别）' }
  $script:Engine = $engine; $script:EngineTag = $tag
  $engine
}

# 预热：启动就把引擎建好，避免第一次请求变慢，也尽早暴露「没有语言包」这类环境问题。
try { $null = Get-OcrEngine $Language } catch { }

# ---------- 截图 / 缩放 ----------
function Save-ScreenPng($rect, [string]$path) {
  if (-not $rect) {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $rect = @($vs.Left, $vs.Top, $vs.Left + $vs.Width, $vs.Top + $vs.Height)
  }
  $x = [int]$rect[0]; $y = [int]$rect[1]; $w = [int]$rect[2] - [int]$rect[0]; $h = [int]$rect[3] - [int]$rect[1]
  if ($w -le 0 -or $h -le 0) { throw "截图矩形无效: $($rect -join ',')" }
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try { $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h))) } finally { $g.Dispose() }
  try { $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
}

function Save-ScaledPng([string]$source, [string]$path, [int]$scale) {
  $img = [System.Drawing.Image]::FromFile($source)
  try {
    if ($scale -le 1) { Copy-Item -LiteralPath $source -Destination $path -Force; return }
    $big = New-Object System.Drawing.Bitmap(($img.Width * $scale), ($img.Height * $scale))
    $g = [System.Drawing.Graphics]::FromImage($big)
    try {
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
      $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
      $g.DrawImage($img, 0, 0, $big.Width, $big.Height)
    } finally { $g.Dispose() }
    try { $big.Save($path, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $big.Dispose() }
  } finally { $img.Dispose() }
}

function Invoke-Ocr([string]$file) {
  $storage = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($file)) ([Windows.Storage.StorageFile])
  $stream = Await ($storage.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  try {
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $engine = Get-OcrEngine $script:RequestLanguage
    $result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
  } finally { $stream.Dispose() }
  $result
}

function Convert-Box($box, [int]$dx, [int]$dy, [int]$scale) {
  $s = [Math]::Max(1, $scale)
  $x = [int]([double]$box.X / $s) + $dx
  $y = [int]([double]$box.Y / $s) + $dy
  $w = [int]([double]$box.Width / $s)
  $h = [int]([double]$box.Height / $s)
  [pscustomobject]@{ x = $x; y = $y; w = $w; h = $h; cx = $x + [int]($w / 2); cy = $y + [int]($h / 2) }
}

function Invoke-OcrPass([string]$file, [int]$dx, [int]$dy, [int]$scale, [string]$needle) {
  $result = Invoke-Ocr $file
  $lines = @()
  foreach ($line in @($result.Lines)) {
    $words = @()
    $x1 = [int]::MaxValue; $y1 = [int]::MaxValue; $x2 = 0; $y2 = 0
    foreach ($word in @($line.Words)) {
      $b = Convert-Box $word.BoundingRect $dx $dy $scale
      if ($b.x -lt $x1) { $x1 = $b.x }; if ($b.y -lt $y1) { $y1 = $b.y }
      if (($b.x + $b.w) -gt $x2) { $x2 = $b.x + $b.w }; if (($b.y + $b.h) -gt $y2) { $y2 = $b.y + $b.h }
      $words += [pscustomobject]@{ text = [string]$word.Text; rect = @($b.x, $b.y, $b.w, $b.h); center = @($b.cx, $b.cy) }
    }
    if (-not $words.Count) { continue }
    $raw = [string]$line.Text
    $compact = ($raw -replace '\s+', '')
    if (-not $compact) { continue }
    $lineBox = [pscustomobject]@{ x = $x1; y = $y1; w = $x2 - $x1; h = $y2 - $y1; cx = $x1 + [int](($x2 - $x1) / 2); cy = $y1 + [int](($y2 - $y1) / 2) }
    $lines += [pscustomobject]@{ text = $raw; compact = $compact; rect = @($lineBox.x, $lineBox.y, $lineBox.w, $lineBox.h); center = @($lineBox.cx, $lineBox.cy); words = $words }
  }
  $findResult = $null
  if ($needle) {
    $target = ($needle -replace '\s+', '')
    $matches = @()
    foreach ($line in $lines) {
      $haystack = $line.compact
      $at = $haystack.IndexOf($target, [StringComparison]::OrdinalIgnoreCase)
      while ($at -ge 0) {
        $ratio = $at / [Math]::Max(1, $haystack.Length)
        $lenRatio = $target.Length / [Math]::Max(1, $haystack.Length)
        $mx = $line.rect[0] + [int](($ratio + $lenRatio / 2) * $line.rect[2])
        $my = $line.center[1]
        $matches += [pscustomobject]@{ text = $line.text; center = @($mx, $my); rect = $line.rect }
        $at = $haystack.IndexOf($target, $at + $target.Length, [StringComparison]::OrdinalIgnoreCase)
      }
    }
    if ($matches.Count) {
      $findResult = [pscustomobject]@{ found = $true; query = $needle; center = $matches[0].center; line = $matches[0].text; matches = $matches }
    } else {
      $findResult = [pscustomobject]@{ found = $false; query = $needle; center = $null; line = $null; matches = @() }
    }
  }
  [pscustomobject]@{ lines = $lines; find = $findResult; text = [string]$result.Text }
}

# 把裁剪到文字包围盒（+卡片深色收边）的逻辑单独拿出来，供 saveImage 用。
function Save-CroppedImage([string]$rawPath, [string]$saveTarget, $chosen, [int]$dx, [int]$dy, [switch]$CropToCard) {
  try {
    $minX = ($chosen.lines | ForEach-Object { $_.rect[0] } | Measure-Object -Minimum).Minimum
    $minY = ($chosen.lines | ForEach-Object { $_.rect[1] } | Measure-Object -Minimum).Minimum
    $maxX = ($chosen.lines | ForEach-Object { $_.rect[0] + $_.rect[2] } | Measure-Object -Maximum).Maximum
    $maxY = ($chosen.lines | ForEach-Object { $_.rect[1] + $_.rect[3] } | Measure-Object -Maximum).Maximum
    $img = [System.Drawing.Image]::FromFile($rawPath)
    try {
      $ix = [int]$minX - $dx - 28; $iy = [int]$minY - $dy - 28
      $iw = [int]($maxX - $minX) + 56; $ih = [int]($maxY - $minY) + 56
      if ($ix -lt 0) { $iw += $ix; $ix = 0 }
      if ($iy -lt 0) { $ih += $iy; $iy = 0 }
      if ($ix + $iw -gt $img.Width) { $iw = $img.Width - $ix }
      if ($iy + $ih -gt $img.Height) { $ih = $img.Height - $iy }
      if ($iw -gt 40 -and $ih -gt 40) {
        $crop = New-Object System.Drawing.Bitmap($iw, $ih)
        $g = [System.Drawing.Graphics]::FromImage($crop)
        try { $g.DrawImage($img, (New-Object System.Drawing.Rectangle(0, 0, $iw, $ih)), (New-Object System.Drawing.Rectangle($ix, $iy, $iw, $ih)), [System.Drawing.GraphicsUnit]::Pixel) }
        finally { $g.Dispose() }
        if ($CropToCard) {
          try {
            $dark = { param($c) (($c.R + $c.G + $c.B) -lt 150) }
            $rowDark = New-Object 'bool[]' $crop.Height
            for ($yy = 0; $yy -lt $crop.Height; $yy++) {
              $cnt = 0
              for ($xx = 0; $xx -lt $crop.Width; $xx += 4) { $c = $crop.GetPixel($xx, $yy); if (& $dark $c) { $cnt++ } }
              $rowDark[$yy] = ($cnt -ge [int](($crop.Width / 4) * 0.45))
            }
            $rowEnd = -1; $gap = 0; $seen = $false
            for ($yy = 0; $yy -lt $crop.Height; $yy++) {
              if ($rowDark[$yy]) { $rowEnd = $yy; $gap = 0; $seen = $true }
              elseif ($seen) { $gap++; if ($gap -gt 12) { break } }
              elseif ($yy -gt 16) { break }
            }
            $rowStart = 0
            for ($yy = 0; $yy -lt $crop.Height; $yy++) { if ($rowDark[$yy]) { $rowStart = $yy; break } }
            $colDark = New-Object 'bool[]' $crop.Width
            $spanRows = [Math]::Max(1, $rowEnd - $rowStart + 1)
            for ($xx = 0; $xx -lt $crop.Width; $xx++) {
              $cnt = 0
              for ($yy = $rowStart; $yy -le $rowEnd; $yy += 2) { $c = $crop.GetPixel($xx, $yy); if (& $dark $c) { $cnt++ } }
              $colDark[$xx] = ($cnt -ge [int](($spanRows / 2) * 0.45))
            }
            $colStart = [int]($crop.Width / 2); $colEnd = $colStart
            while ($colStart -gt 0 -and $colDark[$colStart - 1]) { $colStart-- }
            while ($colEnd -lt ($crop.Width - 1) -and $colDark[$colEnd + 1]) { $colEnd++ }
            if ($rowEnd -gt 120 -and ($colEnd - $colStart) -gt 120) {
              $pad = 10
              $ny = [Math]::Max(0, $rowStart - $pad); $nh = [Math]::Min($crop.Height - $ny, ($rowEnd - $rowStart + 1) + $pad * 2)
              $nx = [Math]::Max(0, $colStart - $pad); $nw = [Math]::Min($crop.Width - $nx, ($colEnd - $colStart + 1) + $pad * 2)
              $tight = New-Object System.Drawing.Bitmap($nw, $nh)
              $g2 = [System.Drawing.Graphics]::FromImage($tight)
              try { $g2.DrawImage($crop, (New-Object System.Drawing.Rectangle(0, 0, $nw, $nh)), (New-Object System.Drawing.Rectangle($nx, $ny, $nw, $nh)), [System.Drawing.GraphicsUnit]::Pixel) }
              finally { $g2.Dispose() }
              $crop.Dispose()
              $crop = $tight
            }
          } catch { }
        }
        $crop.Save($saveTarget, [System.Drawing.Imaging.ImageFormat]::Png)
        $crop.Dispose()
      }
    } finally { $img.Dispose() }
  } catch { }
}

# ---------- 单次请求处理（自检与常驻模式共用） ----------
function Invoke-OcrRequest {
  param(
    $RegionValues = @(),
    [string]$Image,
    [string]$FindText,
    [int[]]$Scales = @(1),
    [string]$LanguageTag,
    [string]$SaveTarget,
    [bool]$DoCropSave = $false,
    [bool]$DoCropCard = $false
  )
  $script:RequestLanguage = $LanguageTag
  $rawTemp = $null
  try {
    $dx = 0; $dy = 0
    if ($Image) {
      $rawPath = (Resolve-Path -LiteralPath $Image).Path
    } else {
      if (-not $RegionValues.Count) {
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $RegionValues = @($vs.Left, $vs.Top, $vs.Left + $vs.Width, $vs.Top + $vs.Height)
      }
      $rawTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("daozai-ocr-" + [guid]::NewGuid().ToString('N') + '.png')
      Save-ScreenPng $RegionValues $rawTemp
      $rawPath = $rawTemp
    }
    if ($RegionValues.Count -eq 4) { $dx = [int]$RegionValues[0]; $dy = [int]$RegionValues[1]; $regionOut = @($RegionValues) }
    else { $regionOut = @($dx, $dy, ($dx + 3440), ($dy + 1440)) }

    if ($SaveTarget) {
      $dir = Split-Path -Parent ([System.IO.Path]::GetFullPath($SaveTarget))
      if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
      Copy-Item -LiteralPath $rawPath -Destination ([System.IO.Path]::GetFullPath($SaveTarget)) -Force
    }

    $attempts = @()
    $chosen = $null
    $bigCache = @{}
    foreach ($s in $Scales) {
      if ($s -gt 1) {
        if (-not $bigCache.ContainsKey($s)) {
          $big = Join-Path ([System.IO.Path]::GetTempPath()) ("daozai-ocr-big-" + [guid]::NewGuid().ToString('N') + '.png')
          Save-ScaledPng $rawPath $big $s
          $bigCache[$s] = $big
        }
        $pass = Invoke-OcrPass $bigCache[$s] $dx $dy $s $FindText
      } else {
        $pass = Invoke-OcrPass $rawPath $dx $dy $s $FindText
      }
      $attempts += [pscustomobject]@{ scale = $s; lineCount = @($pass.lines).Count; found = ($null -ne $pass.find -and $pass.find.found) }
      if ($null -eq $chosen -or @($chosen.lines).Count -eq 0) { $chosen = $pass }
      if ($FindText -and $null -ne $pass.find -and $pass.find.found) { $chosen = $pass; break }
    }
    foreach ($big in $bigCache.Values) { Remove-Item -LiteralPath $big -Force -ErrorAction SilentlyContinue }
    if ($SaveTarget -and $DoCropSave -and @($chosen.lines).Count) {
      Save-CroppedImage -rawPath $rawPath -saveTarget ([System.IO.Path]::GetFullPath($SaveTarget)) -chosen $chosen -dx $dx -dy $dy -CropToCard:$DoCropCard
    }
    if ($null -eq $chosen) { throw '没有任何可用的放大倍率' }

    $engine = Get-OcrEngine $LanguageTag
    return [pscustomobject]@{
      ok        = $true
      source    = if ($Image) { 'image' } else { 'screen' }
      region    = $regionOut
      language  = $engine.RecognizerLanguage.LanguageTag
      scales    = $Scales
      attempts  = $attempts
      lineCount = @($chosen.lines).Count
      ocrText   = $chosen.text
      lines     = $chosen.lines
      find      = $chosen.find
    }
  } finally {
    if ($rawTemp -and (Test-Path -LiteralPath $rawTemp)) { Remove-Item -LiteralPath $rawTemp -Force -ErrorAction SilentlyContinue }
  }
}

function Write-JsonLine($object, [switch]$Compress) {
  $text = if ($Compress) { $object | ConvertTo-Json -Depth 8 -Compress } else { $object | ConvertTo-Json -Depth 8 -Compress }
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  [Console]::Out.WriteLine($text)
  [Console]::Out.Flush()
}

# ---------- 自检模式 ----------
if ($Once) {
  $regionValues = @()
  if ($Region) { $regionValues = @($Region -split '[,;\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ }) }
  try {
    $result = Invoke-OcrRequest -RegionValues $regionValues -Image $ImagePath -FindText $Find -Scales @([Math]::Min(12, [Math]::Max(1, $Scale))) -LanguageTag $Language -SaveTarget $SaveImage -DoCropSave:$CropSave -DoCropCard:$CropCard
    if ($Find -and -not ($result.find -and $result.find.found)) {
      Write-JsonLine $result
      exit 2
    }
    Write-JsonLine $result
    exit 0
  } catch {
    $err = [pscustomobject]@{ ok = $false; error = $_.Exception.Message; type = $_.Exception.GetType().Name; languages = @(Get-OcrLanguages) }
    Write-JsonLine $err
    exit 1
  }
}

# ---------- 常驻模式：逐行读请求、逐行写响应 ----------
# 第一行先报 ready：客户端等到它再发请求，这样第一次识别也不会被初始化拖慢。
$readyEngine = $null
try { $readyEngine = Get-OcrEngine $Language } catch { }
$readyLang = if ($readyEngine) { $readyEngine.RecognizerLanguage.LanguageTag } else { $null }
$readyPid = $PID
Write-JsonLine ([pscustomobject]@{ ready = $true; pid = $readyPid; language = $readyLang; languages = @(Get-OcrLanguages); dpiAware = $true })

$stdin = [Console]::In
while ($true) {
  $line = $stdin.ReadLine()
  if ($null -eq $line) { break }
  $line = $line.Trim()
  if (-not $line) { continue }
  $request = $null
  try { $request = $line | ConvertFrom-Json } catch { }
  if ($null -eq $request) {
    Write-JsonLine ([pscustomobject]@{ ok = $false; error = '请求不是合法 JSON'; type = 'ProtocolError' })
    continue
  }
  if ($request.quit) { break }
  $id = $request.id
  try {
    $regionValues = @()
    if ($request.region) { $regionValues = @($request.region | ForEach-Object { [int]$_ }) }
    $scales = @(2)
    if ($request.scales) { $scales = @($request.scales | ForEach-Object { [Math]::Min(12, [Math]::Max(1, [int]$_)) }) }
    elseif ($request.scale) { $scales = @([Math]::Min(12, [Math]::Max(1, [int]$request.scale))) }
    $result = Invoke-OcrRequest -RegionValues $regionValues -Image ([string]$request.image) -FindText ([string]$request.find) `
      -Scales $scales -LanguageTag ([string]$request.language) -SaveTarget ([string]$request.saveImage) `
      -DoCropSave:([bool]$request.cropSave) -DoCropCard:([bool]$request.cropCard)
    $response = [pscustomobject]@{ id = $id; ok = $true; region = $result.region; language = $result.language; scales = $result.scales; attempts = $result.attempts; lineCount = $result.lineCount; ocrText = $result.ocrText; lines = $result.lines; find = $result.find; source = $result.source }
    if ($request.find -and -not ($result.find -and $result.find.found)) { $response | Add-Member -NotePropertyName findMissing -NotePropertyValue $true }
    Write-JsonLine $response
  } catch {
    Write-JsonLine ([pscustomobject]@{ id = $id; ok = $false; error = $_.Exception.Message; type = $_.Exception.GetType().Name; languages = @(Get-OcrLanguages) })
  }
}
exit 0
