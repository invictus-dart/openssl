param(
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$Target,
  [Parameter(Mandatory = $true)][string]$Suffix,
  [Parameter(Mandatory = $true)][string]$VcArch,
  [string]$SrcDir = $env:SRC_DIR,
  [string]$OutDir = "./out"
)

$ErrorActionPreference = 'Stop'
$asset = "openssl-$Version-$Suffix"
$stage = Join-Path $OutDir $asset
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $SrcDir) { throw "SRC_DIR must point at an openssl source tree" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# Import the MSVC environment for the requested architecture into this process.
# No -requires filter: the x86/x64 images install their native toolset and the
# ARM64 image installs the ARM64 one; vcvarsall is the authority here.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -products * -property installationPath
if (-not $vsPath) { throw "Visual Studio not found" }
$vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvarsall.bat"
# stderr is left visible on purpose: a silently failing vcvarsall is exactly
# what surfaced later as "The term 'nmake' is not recognized".
$vcEnv = & cmd /c "`"$vcvars`" $VcArch && set"
$imported = 0
foreach ($line in $vcEnv) {
  if ($line -match '^([^=]+)=(.*)$') {
    [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
    $imported++
  }
}
if ($imported -lt 10) { throw "vcvarsall $VcArch produced no environment" }

# Fail with an explicit message instead of a cryptic downstream "not recognized".
# jom instead of nmake: the mars hook builds with jom because nmake has no
# parallel mode; the CI workflow puts jom on PATH (upstream installs it from
# download.qt.io as well).
foreach ($tool in @("perl", "cl", "jom")) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "tool '$tool' is not on PATH after importing the $VcArch environment"
  }
}

# OpenSSL's generated makefile passes the shared `/Zi /Fdossl_static.pdb` to
# every cl invocation without `/FS`, so parallel compiles collide on one PDB and
# abort with C1041. cl reads CL from the environment, so no makefile edit is
# needed. Same workaround as the hook.
$env:CL = (@($env:CL, "/FS") | Where-Object { $_ }) -join ' '

Push-Location $SrcDir
try {
  & perl Configure $Target no-shared no-pinshared no-apps no-tests no-docs --prefix="$stage" --libdir=lib
  if ($LASTEXITCODE -ne 0) { throw "Configure failed" }

  & jom /J $env:NUMBER_OF_PROCESSORS build_libs
  if ($LASTEXITCODE -ne 0) { throw "jom build_libs failed" }

  # `install` is what the mars hook runs. `/J 1` keeps the install rules serial:
  # their `depend` step renames makefile-<pid> over makefile, and Windows
  # refuses that rename while another jom instance holds the file open
  # ([depend] Error 13).
  & jom install /J 1
  if ($LASTEXITCODE -ne 0) { throw "jom install failed" }
}
finally {
  Pop-Location
}

# Windows-only helper that `install` also copies; irrelevant to static consumers.
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $stage "include\openssl\applink.c")
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $stage "bin")

# --- assertions -------------------------------------------------------------
foreach ($f in @("include\openssl\configuration.h", "include\openssl\crypto.h",
                 "lib\libcrypto.lib", "lib\libssl.lib")) {
  if (-not (Test-Path (Join-Path $stage $f))) { throw "FAIL: missing $f" }
}

$symbols = & dumpbin /symbols (Join-Path $stage "lib\libcrypto.lib") 2>&1
foreach ($s in @("MD5", "RAND_bytes")) {
  if (-not ($symbols | Select-String -SimpleMatch "_$s")) {
    throw "FAIL: libcrypto.lib does not define $s"
  }
}

# --- smoke test -------------------------------------------------------------
& cl /nologo /I (Join-Path $stage "include") (Join-Path $scriptDir "smoke.c") `
  (Join-Path $stage "lib\libcrypto.lib") ws2_32.lib advapi32.lib user32.lib crypt32.lib `
  "/Fe:$stage\smoke.exe"
if ($LASTEXITCODE -ne 0) { throw "FAIL: smoke test does not link against libcrypto.lib" }
& (Join-Path $stage "smoke.exe")
if ($LASTEXITCODE -ne 0) { throw "FAIL: smoke test failed" }
Remove-Item -Force (Join-Path $stage "smoke.exe")
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $stage "smoke.obj")

# --- metadata ---------------------------------------------------------------
$info = [ordered]@{
  openssl_version  = $Version
  configure_target = $Target
  asset            = $asset
  vc_arch          = $VcArch
  build_host       = "windows-$VcArch"
  compiler         = (& cl 2>&1 | Select-Object -First 1)
  built_at         = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}
$json = $info | ConvertTo-Json
# UTF-8 without BOM: Windows PowerShell 5.1's -Encoding utf8 emits a BOM.
[System.IO.File]::WriteAllText((Join-Path $stage "build-info.json"), $json,
  (New-Object System.Text.UTF8Encoding($false)))

Copy-Item (Join-Path $SrcDir "LICENSE.txt") (Join-Path $stage "LICENSE.txt")

# --- archive ----------------------------------------------------------------
$archive = Join-Path $OutDir "$asset.tar.gz"
if (Test-Path $archive) { Remove-Item -Force $archive }
& tar -czf $archive -C $OutDir $asset
if ($LASTEXITCODE -ne 0) { throw "tar failed" }

$entries = & tar -tzf $archive
if ($entries[0] -ne "$asset/") { throw "FAIL: archive root is not $asset/" }

Write-Host "OK $archive"
