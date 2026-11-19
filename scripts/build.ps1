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

if (-not $SrcDir) { throw "SRC_DIR must point at an openssl source tree" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# Import the MSVC environment for the requested architecture. No -requires
# filter: vcvarsall is the authority, and the ARM64 runner only carries the
# ARM64 toolset.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -products * -property installationPath
if (-not $vsPath) { throw "Visual Studio not found" }
$vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvarsall.bat"
$vcEnv = & cmd /c "`"$vcvars`" $VcArch && set"
$imported = 0
foreach ($line in $vcEnv) {
  if ($line -match '^([^=]+)=(.*)$') {
    [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
    $imported++
  }
}
if ($imported -lt 10) { throw "vcvarsall $VcArch produced no environment" }
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

# Link one tiny program so a broken archive fails here instead of in a consumer.
$src = Join-Path $stage "t.c"
Set-Content -Path $src -Encoding ascii -Value @(
  '#include <openssl/rand.h>',
  'int main(void){unsigned char b[16];return RAND_bytes(b,16)==1?0:1;}')
& cl /nologo /I (Join-Path $stage "include") $src (Join-Path $stage "lib\libcrypto.lib") `
  ws2_32.lib advapi32.lib user32.lib crypt32.lib "/Fe:$stage\t.exe"
if ($LASTEXITCODE -ne 0) { throw "FAIL: libcrypto.lib does not link" }
Remove-Item -Force $src
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $stage "t.exe"), (Join-Path $stage "t.obj")

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
