#!/usr/bin/pwsh

param(
  [string]$windowsTargetName,
  [string]$destinationDirectory = 'output',
  [ValidateSet("x64", "arm64")] [string]$architecture = "x64",
  [ValidateSet("pro", "core", "multi", "home")] [string]$edition = "pro",
  [ValidateSet("nb-no", "fr-ca", "fi-fi", "lv-lv", "es-es", "en-gb", "zh-tw", "th-th", "sv-se", "en-us", "es-mx", "bg-bg", "hr-hr", "pt-br", "el-gr", "cs-cz", "it-it", "sk-sk", "pl-pl", "sl-si", "neutral", "ja-jp", "et-ee", "ro-ro", "fr-fr", "pt-pt", "ar-sa", "lt-lt", "hu-hu", "da-dk", "zh-cn", "uk-ua", "tr-tr", "ru-ru", "nl-nl", "he-il", "ko-kr", "sr-latn-rs", "de-de")]
  [string]$lang = "en-us",
  # >>> CHANGED: 增加 All 选项
  [ValidateSet("All", "Education", "Enterprise", "ProfessionalEducation", "ProfessionalWorkstation")]
  [string]$virtualEdition,
  [switch]$esd,
  [switch]$drivers,
  [switch]$netfx3,
  [string]$revision
)

Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

$preview  = $false
$ringLower = $null

trap {
  Write-Host "ERROR: $_"
  @(($_.ScriptStackTrace -split '\r?\n') -replace '^(.*)$','ERROR: $1') | Write-Host
  @(($_.Exception.ToString() -split '\r?\n') -replace '^(.*)$','ERROR EXCEPTION: $1') | Write-Host
  Exit 1
}

# ------------------------------
# Log helpers + DISM bucketed progress (no aria2 parsing)
# ------------------------------
$script:reAnsi = [regex]'\x1B\[[0-9;]*[A-Za-z]'
$script:LastPrintedLine = $null
function Write-CleanLine([string]$text) {
  $clean = $script:reAnsi.Replace(($text ?? ''), '')
  if ($clean -eq $script:LastPrintedLine) { return }
  $script:LastPrintedLine = $clean
  Write-Host $clean
}

# DISM buckets (0/10/.../100)
$script:DismLastBucket = -1
$script:DismEveryPercent = if ($env:DISM_PROGRESS_STEP) { [int]$env:DISM_PROGRESS_STEP } else { 10 }
$script:DismNormalizeOutput = if ($env:DISM_PROGRESS_RAW -eq '1') { $false } else { $true }

$script:reArchiving = [regex]'Archiving file data:\s+.*?\((\d+)%\)\s+done'
$script:reBracket   = [regex]'\[\s*[= \-]*\s*(\d+(?:[.,]\d+)?)%\s*[= \-]*\s*\]'
$script:reLoosePct  = [regex]'(^|\s)(\d{1,3})(?:[.,]\d+)?%(\s|$)'

function Get-PercentFromText([string]$text) {
  if ([string]::IsNullOrEmpty($text)) { return $null }
  $t = $script:reAnsi.Replace($text, '')

  $m = $script:reArchiving.Match($t)
  if ($m.Success) { return [int]$m.Groups[1].Value }

  $m = $script:reBracket.Match($t)
  if ($m.Success) {
    $pct = $m.Groups[1].Value -replace ',', '.'
    return [int][math]::Floor([double]$pct)
  }

  $m = $script:reLoosePct.Match($t)
  if ($m.Success) {
    $n = [int]$m.Groups[2].Value
    if ($n -ge 0 -and $n -le 100) { return $n }
  }
  return $null
}

function Reset-ProgressSession { $script:DismLastBucket = -1 }

function Emit-ProgressBucket([int]$pct) {
  $bucket = [int]([math]::Floor($pct / $script:DismEveryPercent) * $script:DismEveryPercent)
  if ($bucket -le $script:DismLastBucket) { return $false }
  $script:DismLastBucket = $bucket

  if ($script:DismNormalizeOutput) { Write-CleanLine ("[DISM] Progress: {0}%" -f $bucket) }
  else { Write-CleanLine ("Progress: {0}%" -f $bucket) }

  if ($bucket -ge 100) {
    Write-CleanLine "[DISM] Progress: 100% (done)"
    Reset-ProgressSession
  }
  return $true
}

function Process-ProgressLine([string]$line) {
  $pct = Get-PercentFromText $line
  if ($pct -eq $null) { return $false }
  if ($script:DismLastBucket -ge 0 -and $pct -lt $script:DismLastBucket) { Reset-ProgressSession }
  [void](Emit-ProgressBucket $pct)
  return $true
}

# ------------------------------
# Basic metadata helpers
# ------------------------------
$arch = if ($architecture -eq "x64") { "amd64" } else { "arm64" }

if ($windowsTargetName -match 'beta|dev|wif|canary') {
  $preview = $true
  $ringLower = @('beta','dev','wif','canary').Where({$windowsTargetName -match $_})[0]
}

# >>> CHANGED: core/home 映射到 CoreCountrySpecific
function Get-EditionName($e) {
  switch ($e.ToLower()) {
    "core"  { "CoreCountrySpecific" }
    "home"  { "CoreCountrySpecific" }
    "multi" { "Multi" }
    default { "Professional" }
  }
}

# >>> CHANGED: vAutoEditions 是逗号分隔的目标 edition 名列表（与 UUP dump 官方 ConvertConfig.ini 一致）
#   pro / multi -> 返回目标名列表（multi 下 CoreCountrySpecific 无法升级到这些目标，自动不转换）
#   其他        -> $null
function Get-VAutoEditionsValue {
  param([string]$Edition, [string]$VirtualEdition)

  if ([string]::IsNullOrWhiteSpace($VirtualEdition)) { return $null }
  if ($Edition -notin @('pro','multi')) { return $null }

  if ($VirtualEdition -eq 'All') {
    # 与 UUP dump 官方 ConvertConfig.ini 保持一致
    return "ProfessionalWorkstation,ProfessionalEducation,Education,Enterprise,IoTEnterprise"
  }
  return $VirtualEdition
}

$dotSystemRevision = if ([string]::IsNullOrWhiteSpace($revision)) { '' } else { ".$revision" }
$systemRevision = if ([string]::IsNullOrWhiteSpace($revision)) { '' } else { " $revision" }

$TARGETS = @{
  "windows-10"           = @{ search="windows 10 19045$dotSystemRevision $arch"; edition=(Get-EditionName $edition) }
  "windows-11old"        = @{ search="windows 11 22631$dotSystemRevision $arch"; edition=(Get-EditionName $edition) }
  "windows-11"           = @{ search="windows 11 26100$dotSystemRevision $arch"; edition=(Get-EditionName $edition) }
  "windows-11new"        = @{ search="windows 11 26200$dotSystemRevision $arch"; edition=(Get-EditionName $edition) }
  "windows-11beta"       = @{ search="windows 11 26120$dotSystemRevision $arch"; edition=(Get-EditionName $edition); ring="Beta" }
  "windows-11dev"        = @{ search="windows 11 26220$dotSystemRevision $arch"; edition=(Get-EditionName $edition); ring="Wif" }
  "windows-1126h1"       = @{ search="windows 11 28000$dotSystemRevision $arch"; edition=(Get-EditionName $edition) }
  "windows-1126h2"       = @{ search="windows 11 26300$dotSystemRevision $arch"; edition=(Get-EditionName $edition) }
  "windows-1126h2beta"   = @{ search="windows 11 26340$dotSystemRevision $arch"; edition=(Get-EditionName $edition) }
  "windows-dev"          = @{ search="windows 11 26300$dotSystemRevision $arch"; edition=(Get-EditionName $edition); ring="Dev" }
  "windows-canary"       = @{ search="windows 11$systemRevision $arch"; edition=(Get-EditionName $edition); ring="Canary" }
}

function New-QueryString([hashtable]$parameters) {
  @($parameters.GetEnumerator() | ForEach-Object { "$($_.Key)=$([System.Net.WebUtility]::UrlEncode([string]$_.Value))" }) -join '&'
}

function Invoke-UupDumpApi([string]$name, [hashtable]$body) {
  for ($n = 0; $n -lt 15; ++$n) {
    if ($n) {
      Write-CleanLine "Waiting a bit before retrying the uup-dump api ${name} request #$n"
      Start-Sleep -Seconds 10
      Write-CleanLine "Retrying the uup-dump api ${name} request #$n"
    }
    try {
      $qs = if ($body) { '?' + (New-QueryString $body) } else { '' }
      return Invoke-RestMethod -Method Get -Uri ("https://api.uupdump.net/{0}.php{1}" -f $name, $qs)
    } catch {
      Write-CleanLine "WARN: failed the uup-dump api $name request: $_"
    }
  }
  throw "timeout making the uup-dump api $name request"
}

function Get-UupDumpIso($name, $target) {
  # >>> CHANGED: 将 vAutoEditions 注入 target 副本（避免污染全局 $TARGETS）
  $vAuto = Get-VAutoEditionsValue -Edition $edition -VirtualEdition $virtualEdition
  if ($vAuto) {
    $target = @{} + $target
    $target['virtualEdition'] = $vAuto
  }

  Write-CleanLine "Getting the $name metadata"
  $result = Invoke-UupDumpApi listid @{ search = $target.search }

  $result.response.builds.PSObject.Properties
  | ForEach-Object {
      $id = $_.Value.uuid
      $uupDumpUrl = 'https://uupdump.net/selectlang.php?' + (New-QueryString @{ id = $id })
      Write-CleanLine "Processing $name $id ($uupDumpUrl)"
      $_
    }
  | Where-Object {
      if ($_.Value.title -match '\.NET Framework') {
            Write-CleanLine "Skipping, ignore .NET Framework update."
            return $false
        }
      if ($_.Value.title -match 'Windows CPC OS') {
            Write-CleanLine "Skipping, ignore Windows CPC OS."
            return $false
        }
      if (!$preview) {
        $ok = ($target.search -like '*preview*') -or ($_.Value.title -notlike '*preview*')
        if (-not $ok) {
          Write-CleanLine "Skipping.
L1: Expected preview=false.
L2: Got preview=true."
        }
        return $ok
      }
      $true
    }
  | ForEach-Object {
      $id = $_.Value.uuid
      Write-CleanLine "Getting the $name $id langs metadata"
      $result = Invoke-UupDumpApi listlangs @{ id = $id }
      if ($result.response.updateInfo.build -ne $_.Value.build) {
        throw 'for some reason listlangs returned an unexpected build'
      }
      $_.Value | Add-Member -NotePropertyMembers @{ langs = $result.response.langFancyNames; info = $result.response.updateInfo }

      $langs = $_.Value.langs.PSObject.Properties.Name
      $eds = if ($langs -contains $lang) {
        Write-CleanLine "Getting the $name $id editions metadata"
        $result = Invoke-UupDumpApi listeditions @{ id = $id; lang = $lang }
        $result.response.editionFancyNames
      } else {
        Write-CleanLine "Skipping.
L3: Expected langs=$lang.
L4: Got langs=$($langs -join ',')."
        [PSCustomObject]@{}
      }
      $_.Value | Add-Member -NotePropertyMembers @{ editions = $eds }
      $_
    }
  | Where-Object {
      $langs = $_.Value.langs.PSObject.Properties.Name
      $editions = $_.Value.editions.PSObject.Properties.Name
      $res = $true

      if ($ringLower) {
        $actual = ($_.Value.info.ring).ToUpper()
        $allowedRings = switch ($ringLower) {
          'canary' { 'CANARY', 'WIF' }
          'dev'    { 'DEV', 'WIF', 'WIS' }
          'beta'   { 'BETA', 'WIF', 'WIS' }
          default { $ringLower.ToUpper() }
        }

        if ($actual -notin $allowedRings) {
          Write-CleanLine "Skipping. Expected ring: $($allowedRings -join ', '). Got ring=$actual."
          $res = $false
        }
      }

      if ($langs -notcontains $lang) {
        Write-CleanLine "Skipping. Expected langs=$lang. Got langs=$($langs -join ',')."
        $res = $false
      }

      if ((Get-EditionName $edition) -eq "Multi") {
        if (($editions -notcontains "Professional") -and ($editions -notcontains "Core")) {
          Write-CleanLine "Skipping.
L6: Expected editions=Multi (Professional/Core). Got editions=$($editions -join ',')."
          $res = $false
        }
      # >>> CHANGED: CoreCountrySpecific 兼容旧 build 的 "Core"
      } elseif ((Get-EditionName $edition) -eq "CoreCountrySpecific") {
        if (($editions -notcontains "CoreCountrySpecific") -and ($editions -notcontains "Core")) {
          Write-CleanLine ("Skipping. Expected editions=CoreCountrySpecific (or Core). Got editions={0}." -f ($editions -join ','))
          $res = $false
        }
      } elseif ($editions -notcontains (Get-EditionName $edition)) {
        Write-CleanLine ("Skipping. Expected editions={0}.
L7: Got editions={1}." -f (Get-EditionName $edition), ($editions -join ','))
        $res = $false
      }

      if (!$preview -and -not ($_.Value.title -match 'version')) {
        Write-CleanLine "Skipping. Unexpected title format: missing 'version'."
        $res = $false
      }

      $res
    }
  | Select-Object -First 1
  | ForEach-Object {
      $id = $_.Value.uuid

      # >>> CHANGED: UUP dump API edition 参数用小写标识符
      $uupEditionParam = if ($edition -eq "multi") {
        "corecountryspecific;professional"
      } else {
        $target.edition.ToLowerInvariant()
      }

      [PSCustomObject]@{
        name               = $name
        title              = $_.Value.title
        build              = $_.Value.build
        id                 = $id
        edition            = $target.edition
        virtualEdition     = $target['virtualEdition']   # vAutoEditions 列表，如 "Enterprise" 或 "ProfessionalWorkstation,ProfessionalEducation,Education,Enterprise,IoTEnterprise"
        apiUrl             = 'https://api.uupdump.net/get.php?' + (New-QueryString @{ id = $id; lang = $lang; edition = $uupEditionParam })
        downloadUrl        = 'https://uupdump.net/download.php?' + (New-QueryString @{ id = $id; pack = $lang; edition = $uupEditionParam })
        downloadPackageUrl = 'https://uupdump.net/get.php?' + (New-QueryString @{ id = $id; pack = $lang; edition = $uupEditionParam })
      }
    }
}

function Get-IsoWindowsImages($isoPath) {
  $isoPath = Resolve-Path $isoPath
  Write-CleanLine "Mounting $isoPath"
  $isoImage = Mount-DiskImage $isoPath -PassThru
  try {
    $isoVolume = $isoImage | Get-Volume
    $installPath = if ($esd) { "$($isoVolume.DriveLetter):\sources\install.esd" } else { "$($isoVolume.DriveLetter):\sources\install.wim" }
    Write-CleanLine "Getting Windows images from $installPath"
    Get-WindowsImage -ImagePath $installPath | ForEach-Object {
      $image = Get-WindowsImage -ImagePath $installPath -Index $_.ImageIndex
      [PSCustomObject]@{ index = $image.ImageIndex; name = $image.ImageName; version = $image.Version }
    }
  }
  finally {
    Write-CleanLine "Dismounting $isoPath"
    Dismount-DiskImage $isoPath | Out-Null
  }
}

# ------------------------------
# Patch uup_download_windows.cmd with sed - quiet aria2 flags
# ------------------------------
function Patch-Aria2-Flags {
  param([string]$CmdPath)
  if (-not (Test-Path $CmdPath)) { return }

  $sed = Get-Command sed -ErrorAction SilentlyContinue
  if ($sed) {
    Write-CleanLine "Patching aria2 flags in $CmdPath using sed."
    # Remove conflicting flags first
    & $sed.Path -ri 's/\s--console-log-level=\w+\b//g; s/\s--summary-interval=\d+\b//g; s/\s--download-result=\w+\b//g; s/\s--enable-color=\w+\b//g; s/\s-(q|quiet(=\w+)?)\b//g' $CmdPath
    # Inject quiet set right after "%aria2%"
    & $sed.Path -ri 's@("%aria2%"\s+)@\1--quiet=true --console-log-level=error --summary-interval=0 --download-result=hide --enable-color=false @g' $CmdPath
    return
  }

  # Fallback: PowerShell regex (preserves UTF-16LE)
  Write-CleanLine "sed not found. Patching aria2 flags in $CmdPath using PowerShell fallback."
  $bytes   = [System.IO.File]::ReadAllBytes($CmdPath)
  $content = [System.Text.Encoding]::Unicode.GetString($bytes)

  $patternsToRemove = @(
    '\s--console-log-level=\w+\b',
    '\s--summary-interval=\d+\b',
    '\s--download-result=\w+\b',
    '\s--enable-color=\w+\b',
    '\s-(?:q|quiet(?:=\w+)?)\b'
  )
  foreach ($re in $patternsToRemove) {
    $content = [regex]::Replace($content, $re, '', 'IgnoreCase, CultureInvariant')
  }
  $inject = '--quiet=true --console-log-level=error --summary-interval=0 --download-result=hide --enable-color=false '
  $content = [regex]::Replace($content, '("%aria2%"\s+)', ('$1' + $inject), 'IgnoreCase, CultureInvariant')

  $newBytes = [System.Text.Encoding]::Unicode.GetBytes($content)
  [System.IO.File]::WriteAllBytes($CmdPath, $newBytes)
}

function Get-WindowsIso($name, $destinationDirectory) {
  # >>> CHANGED: 虚拟版本只允许 pro / multi
  if ($virtualEdition -and $edition -notin @('pro','multi')) {
    throw "virtualEdition 只能与 -edition pro 或 multi 一起使用（当前 edition=$edition）。"
  }

  $iso = Get-UupDumpIso $name $TARGETS.$name
  if (-not $iso) { throw "Can't find UUP for $name ($($TARGETS.$name.search)), lang=$lang." }

  $isoHasEdition    = $iso.PSObject.Properties.Name -contains 'edition' -and $iso.edition
  # >>> CHANGED: virtualEdition 现在是逗号分隔的列表串
  $hasVirtualMember = ($iso.PSObject.Properties.Name -contains 'virtualEdition') -and
                      (-not [string]::IsNullOrWhiteSpace($iso.virtualEdition))
  $effectiveEdition = if ($isoHasEdition) { $iso.edition } else { $TARGETS.$name.edition }

  if (!$preview) {
    if ($iso.title -match 'version') {
      $parts = $iso.title -split 'version\s*'
      if ($parts.Count -lt 2) { throw "Unexpected title format, split resulted in less than 2 parts: $($parts -join '|')" }
      $verbuild = $parts[1] -split '[\s\(]' | Select-Object -First 1
    } else {
      Write-CleanLine "WARN: Unexpected title format: missing 'version'. Using build number fallback."
      $verbuild = $iso.build
    }
  } else {
    $verbuild = $ringLower.ToUpper()
  }

  $buildDirectory               = "$destinationDirectory/$name"
  $destinationIsoPath           = "$buildDirectory.iso"
  $destinationIsoMetadataPath   = "$destinationIsoPath.json"
  $destinationIsoChecksumPath   = "$destinationIsoPath.sha256.txt"

  if (Test-Path $buildDirectory) { Remove-Item -Force -Recurse $buildDirectory | Out-Null }
  New-Item -ItemType Directory -Force $buildDirectory | Out-Null

  # >>> CHANGED: 标题展示用用户指定的虚拟版本名；All 显示 Virtual-All
  $edn = if ($hasVirtualMember) {
    if ($virtualEdition -eq 'All') { 'Virtual-All' } else { $virtualEdition }
  } else {
    $effectiveEdition
  }
  Write-CleanLine $edn
  $title = "$name $edn $($iso.build)"

  Write-CleanLine "Downloading the UUP dump download package for $title from $($iso.downloadPackageUrl)"

  # >>> CHANGED: virtualEditions[] 多值；All 展开为官方 5 个目标
  $virtualEditionsList = @(
    if ($hasVirtualMember) {
      if ($virtualEdition -eq 'All') {
        'ProfessionalWorkstation','ProfessionalEducation','Education','Enterprise','IoTEnterprise'
      } else {
        $virtualEdition
      }
    }
  )

  # >>> CHANGED: 有多个 virtualEditions[] 时必须用字符串 body（hashtable 不能重复 key）
  $downloadPackageBody = if ($virtualEditionsList.Count -gt 0) {
    $pairs = @('autodl=3','updates=1','cleanup=1')
    foreach ($ve in $virtualEditionsList) {
      $pairs += "virtualEditions[]=$([System.Net.WebUtility]::UrlEncode($ve))"
    }
    ($pairs -join '&')
  } else {
    @{ autodl=2; updates=1; cleanup=1 }
  }

  Invoke-WebRequest -Method Post -Uri $iso.downloadPackageUrl -Body $downloadPackageBody -OutFile "$buildDirectory.zip" | Out-Null
  Expand-Archive "$buildDirectory.zip" $buildDirectory

  $convertConfig = (Get-Content $buildDirectory/ConvertConfig.ini) `
    -replace '^(AutoExit\s*)=.*','$1=1' `
    -replace '^(ResetBase\s*)=.*','$1=1' `
    -replace '^(Cleanup\s*)=.*','$1=1'

  $tag = ""
  if ($esd) { $convertConfig = $convertConfig -replace '^(wim2esd\s*)=.*', '$1=1'; $tag += ".E" }
  if ($drivers -and $arch -ne "arm64") {
    $convertConfig = $convertConfig -replace '^(AddDrivers\s*)=.*', '$1=1'
    $tag += ".D"
    Write-CleanLine "Copy Dell drivers to $buildDirectory directory"
    Copy-Item -Path Drivers -Destination $buildDirectory/Drivers -Recurse
  }
  if ($netfx3) { $convertConfig = $convertConfig -replace '^(NetFx3\s*)=.*', '$1=1'; $tag += ".N" }

  # >>> CHANGED: vAutoEditions 直接写逗号列表（与官方语法一致）
  if ($hasVirtualMember) {
    $convertConfig = $convertConfig `
      -replace '^(StartVirtual\s*)=.*','$1=1' `
      -replace '^(vDeleteSource\s*)=.*','$1=1' `
      -replace '^(vAutoEditions\s*)=.*',"`$1=$($iso.virtualEdition)"
  }
  Set-Content -Encoding ascii -Path $buildDirectory/ConvertConfig.ini -Value $convertConfig

  Write-CleanLine "Creating the $title iso file inside the $buildDirectory directory"
  Push-Location $buildDirectory

  # Patch aria2 flags in the batch before running it
  Patch-Aria2-Flags -CmdPath (Join-Path $buildDirectory 'uup_download_windows.cmd')

  # Raw log path
  $rawLog = Join-Path $env:RUNNER_TEMP "uup_dism_aria2_raw.log"

  choco install aria2 /y *> $null

  & {
    powershell cmd /c uup_download_windows.cmd 2>&1 |
      Tee-Object -FilePath $rawLog |
      ForEach-Object {
        $raw = [string]$_
        if ([string]::IsNullOrEmpty($raw)) { return }
        foreach ($crChunk in ($raw -split "`r")) {
          foreach ($line in ($crChunk -split "`n")) {
            if ($line -eq $null) { continue }
            # DISM progress buckets; aria2 is not parsed here
            if (-not (Process-ProgressLine $line)) {
              if ($line -match '^\s*(Mounting image|Saving image|Applying image|Exporting image|Unmounting image|Deployment Image Servicing and Management tool|^=== )') {
                Reset-ProgressSession
              }
              Write-CleanLine $line
            }
          }
        }
      }
  }

  if ($LASTEXITCODE) {
    Write-Host "::warning title=Build failed::Dumping last 1500 raw log lines"
    Get-Content $rawLog -Tail 1500 | Write-Host
    throw "uup_download_windows.cmd failed with exit code $LASTEXITCODE"
  }

  Pop-Location

  $sourceIsoPath = Resolve-Path $buildDirectory/*.iso
  $IsoName = Split-Path $sourceIsoPath -leaf

  Write-CleanLine "Getting the $sourceIsoPath checksum"
  $isoChecksum = (Get-FileHash -Algorithm SHA256 $sourceIsoPath).Hash.ToLowerInvariant()
  Set-Content -Encoding ascii -NoNewline -Path $destinationIsoChecksumPath -Value $isoChecksum

  $windowsImages = Get-IsoWindowsImages $sourceIsoPath
  Set-Content -Path $destinationIsoMetadataPath -Value (
    ([PSCustomObject]@{
      name    = $name
      title   = $iso.title
      build   = $iso.build
      version = $verbuild
      tags    = $tag
      # >>> CHANGED: 记录用户选择（All 或具体版本）
      virtualEdition = if ($hasVirtualMember) { $virtualEdition } else { $null }
      checksum = $isoChecksum
      images  = @($windowsImages)
      uupDump = @{
        id                 = $iso.id
        apiUrl             = $iso.apiUrl
        downloadUrl        = $iso.downloadUrl
        downloadPackageUrl = $iso.downloadPackageUrl
      }
    } | ConvertTo-Json -Depth 99) -replace '\\u0026','&'
  )

  Write-CleanLine "Moving the created $sourceIsoPath to $destinationDirectory/$IsoName"
  Move-Item -Force $sourceIsoPath "$destinationDirectory/$IsoName"

  Write-Output "ISO_NAME=$IsoName" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
  Write-CleanLine 'All Done.'
}

Get-WindowsIso $windowsTargetName $destinationDirectory
