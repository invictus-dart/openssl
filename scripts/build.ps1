param(
  [Parameter(Mandatory = $true)][string]$Tag,
  [Parameter(Mandatory = $true)][string]$Target,
  [string]$SrcDir = $env:SRC_DIR,
  [string]$OutDir = "./out"
)

$ErrorActionPreference = 'Stop'

# 3.5.9 and openssl-3.5.9 both end up as an asset named openssl-<version>-<target>.
$Version = $Tag -replace '^openssl-', ''
$asset = "openssl-$Version-$Target"

# The target decides the MSVC environment; there is no separate arch parameter.
$VcArch = switch ($Target) {
  "VC-WIN32"     { "x86" }
  "VC-WIN64A"    { "x64" }
  "VC-WIN64-ARM" { "arm64" }
  default        { throw "unsupported target $Target" }
}
$stage = Join-Path $OutDir $asset

if (-not $SrcDir) { throw "SRC_DIR must point at an openssl source tree" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# Import the MSVC environment for the requested architecture. VsDevCmd.bat is
# what the "Developer Command Prompt" shortcut runs; its arch names differ
# from the ones vcvarsall takes, hence the mapping.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -products * -property installationPath
if (-not $vsPath) { throw "Visual Studio not found" }
$devArch = switch ($VcArch) { "x64" { "amd64" } "x86" { "x86" } default { $VcArch } }
$hostArch = if ($VcArch -eq "arm64") { "arm64" } else { "amd64" }
$vsdev = Join-Path $vsPath "Common7\Tools\VsDevCmd.bat"
$vcEnv = & cmd /c "`"$vsdev`" -arch=$devArch -host_arch=$hostArch -no_logo && set"
$imported = 0
foreach ($line in $vcEnv) {
  if ($line -match '^([^=]+)=(.*)$') {
    [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
    $imported++
  }
}
if ($imported -lt 10) { throw "VsDevCmd.bat -arch=$devArch produced no environment" }
foreach ($tool in @("perl", "cl", "jom")) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "tool '$tool' is not on PATH after importing the $VcArch environment"
  }
}

# The generated makefile passes one shared /Fdossl_static.pdb to every cl; /FS
# serialises the writes so parallel builds do not fail with C1041.
$env:CL = (@($env:CL, "/FS") | Where-Object { $_ }) -join ' '

Push-Location $SrcDir
try {
  & perl Configure $Target no-shared no-pinshared no-apps no-tests no-docs --prefix="$stage" --libdir=lib
  if ($LASTEXITCODE -ne 0) { throw "Configure failed" }

  & jom /J $env:NUMBER_OF_PROCESSORS build_libs
  if ($LASTEXITCODE -ne 0) { throw "jom build_libs failed" }

  # Install rules are not independent: their depend step renames
  # makefile-<pid> over makefile, which Windows refuses while another jom
  # instance holds it (Error 13). /J 1 keeps them one at a time.
  & jom install /J 1
  if ($LASTEXITCODE -ne 0) { throw "jom install failed" }
}
finally {
  Pop-Location
}

# The archive is the install tree as-is; nothing is pruned.

foreach ($lib in @("lib\libcrypto.lib", "lib\libssl.lib")) {
  if (-not (Test-Path (Join-Path $stage $lib))) { throw "FAIL: $lib missing" }
}

$info = @{
  version = $Version
  target  = $Target
  asset   = $asset
  host    = "windows-$VcArch"
  built   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
} | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText((Join-Path $stage "build-info.json"), $info,
  (New-Object System.Text.UTF8Encoding($false)))

Copy-Item (Join-Path $SrcDir "LICENSE.txt") (Join-Path $stage "LICENSE.txt")

$archive = Join-Path $OutDir "$asset.tar.gz"
if (Test-Path $archive) { Remove-Item -Force $archive }
& tar -czf $archive -C $OutDir $asset
if ($LASTEXITCODE -ne 0) { throw "tar failed" }

# Consumers extract with a plain tar, so the root entry must match the asset.
$entries = & tar -tzf $archive
if ($entries[0] -ne "$asset/") { throw "FAIL: archive root is not $asset/" }

Write-Host "built $archive"
