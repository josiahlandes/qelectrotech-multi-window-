<#
.SYNOPSIS
    Build QElectroTech from source on Windows and create an NSIS installer.

.DESCRIPTION
    This script checks for (and optionally installs) all required build
    dependencies, configures and compiles QElectroTech with CMake, stages
    the output into the NSIS "files/" layout, and invokes makensis to
    produce a ready-to-distribute installer .exe.

    Run from an elevated (Administrator) PowerShell prompt so that winget
    and NSIS can install / run without UAC interruptions.

.PARAMETER QtDir
    Root of a Qt installation, e.g. "C:\Qt\5.15.2\msvc2019_64".
    If omitted the script searches common locations automatically.

.PARAMETER BuildType
    CMake build type: Release (default) or Debug.

.PARAMETER SkipBuild
    If set, skip the CMake build and only stage + create the installer
    from an existing build directory.

.PARAMETER Generator
    CMake generator string.  Defaults to "Ninja" when ninja is found,
    otherwise falls back to the newest Visual Studio generator detected.

.EXAMPLE
    .\build_installer.ps1
    .\build_installer.ps1 -QtDir "C:\Qt\5.15.2\msvc2019_64"
    .\build_installer.ps1 -SkipBuild
#>

[CmdletBinding()]
param(
    [string]$QtDir,
    [ValidateSet("Release","Debug")]
    [string]$BuildType = "Release",
    [switch]$SkipBuild,
    [string]$Generator
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Paths ───────────────────────────────────────────────────────────────
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoRoot    = (Resolve-Path "$ScriptDir\..\..").Path
$BuildDir    = Join-Path $RepoRoot "build"
$StageDir    = Join-Path $ScriptDir "files"

# Version extracted from sources/qetversion.cpp
$versionLine = Select-String -Path "$RepoRoot\sources\qetversion.cpp" `
    -Pattern 'return QVersionNumber\{' | Select-Object -First 1
if ($versionLine -match '\{\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}') {
    $Version = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
} else {
    $Version = "0.0.0"
}

$GitSha = ""
try { $GitSha = (git -C $RepoRoot rev-parse --short HEAD 2>$null) } catch {}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  QElectroTech Windows Installer Builder"    -ForegroundColor Cyan
Write-Host "  Version : $Version"                        -ForegroundColor Cyan
Write-Host "  Commit  : $GitSha"                         -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ── Helper: test whether a command exists ───────────────────────────────
function Test-CommandExists([string]$cmd) {
    $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue)
}

# ── Helper: install a package via winget (if available) ─────────────────
function Install-WithWinget([string]$id, [string]$name) {
    if (Test-CommandExists "winget") {
        Write-Host "  -> Installing $name via winget ($id) ..." -ForegroundColor Yellow
        winget install --id $id --exact --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) {
            Write-Error "winget install of $name failed (exit $LASTEXITCODE)."
        }
        # Refresh PATH for the current session
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                     [System.Environment]::GetEnvironmentVariable("Path","User")
    } else {
        Write-Error "$name is required but not found and winget is unavailable. Please install it manually."
    }
}

# ════════════════════════════════════════════════════════════════════════
#  1. CHECK / INSTALL DEPENDENCIES
# ════════════════════════════════════════════════════════════════════════
Write-Host "[1/6] Checking dependencies ..." -ForegroundColor Green

# ── Git ─────────────────────────────────────────────────────────────────
Write-Host "  Checking Git ..."
if (-not (Test-CommandExists "git")) {
    Install-WithWinget "Git.Git" "Git"
}
if (-not (Test-CommandExists "git")) {
    Write-Error "Git is still not found after install attempt. Add it to PATH and retry."
}
Write-Host "  [OK] Git: $(git --version)" -ForegroundColor DarkGreen

# ── CMake ───────────────────────────────────────────────────────────────
Write-Host "  Checking CMake ..."
if (-not (Test-CommandExists "cmake")) {
    Install-WithWinget "Kitware.CMake" "CMake"
}
if (-not (Test-CommandExists "cmake")) {
    Write-Error "CMake is still not found after install attempt. Add it to PATH and retry."
}
$cmakeVer = (cmake --version | Select-Object -First 1)
Write-Host "  [OK] CMake: $cmakeVer" -ForegroundColor DarkGreen

# ── Ninja (optional but preferred) ─────────────────────────────────────
Write-Host "  Checking Ninja ..."
if (-not (Test-CommandExists "ninja")) {
    if (Test-CommandExists "winget") {
        Write-Host "  -> Installing Ninja via winget ..." -ForegroundColor Yellow
        winget install --id "Ninja-build.Ninja" --exact --accept-source-agreements --accept-package-agreements 2>$null
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                     [System.Environment]::GetEnvironmentVariable("Path","User")
    }
}
if (Test-CommandExists "ninja") {
    Write-Host "  [OK] Ninja: $(ninja --version)" -ForegroundColor DarkGreen
} else {
    Write-Host "  [--] Ninja not found (will fall back to VS generator)" -ForegroundColor DarkYellow
}

# ── C++ compiler (MSVC via vswhere) ────────────────────────────────────
Write-Host "  Checking C++ compiler ..."
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstallPath = $null
if (Test-Path $vsWhere) {
    $vsInstallPath = & $vsWhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>$null
}

if ($vsInstallPath) {
    Write-Host "  [OK] Visual Studio: $vsInstallPath" -ForegroundColor DarkGreen
    # Import the VS dev environment into our session
    $vcvars = Join-Path $vsInstallPath "VC\Auxiliary\Build\vcvars64.bat"
    if (Test-Path $vcvars) {
        Write-Host "  -> Importing VS developer environment (x64) ..."
        $output = cmd /c "`"$vcvars`" >nul 2>&1 && set"
        foreach ($line in $output) {
            if ($line -match '^([^=]+)=(.*)$') {
                [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process")
            }
        }
    }
} else {
    # Try MinGW / g++ as fallback
    if (Test-CommandExists "g++") {
        Write-Host "  [OK] g++: $(g++ --version | Select-Object -First 1)" -ForegroundColor DarkGreen
    } else {
        Write-Error @"
No C++ compiler found. Install one of:
  - Visual Studio 2019+ with 'Desktop development with C++' workload
  - MinGW-w64 (e.g. via winget install MSYS2.MSYS2, or Qt's bundled MinGW)
"@
    }
}

# ── Qt ──────────────────────────────────────────────────────────────────
Write-Host "  Checking Qt ..."
if (-not $QtDir) {
    # Auto-detect common Qt install locations
    $searchRoots = @(
        "C:\Qt", "D:\Qt",
        "$env:USERPROFILE\Qt",
        "$env:ProgramFiles\Qt"
    )
    foreach ($root in $searchRoots) {
        if (Test-Path $root) {
            # Look for msvc or mingw directories containing bin\qmake.exe
            $candidates = Get-ChildItem -Path $root -Recurse -Filter "qmake.exe" -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match '(msvc|mingw).*\\bin\\qmake\.exe$' } |
                Sort-Object LastWriteTime -Descending
            if ($candidates) {
                $QtDir = Split-Path (Split-Path $candidates[0].FullName)
                break
            }
        }
    }
}
if (-not $QtDir -or -not (Test-Path $QtDir)) {
    Write-Error @"
Qt installation not found. Either:
  1. Pass -QtDir "C:\Qt\5.15.2\msvc2019_64" explicitly, or
  2. Install Qt via the online installer (https://www.qt.io/download-qt-installer)
     with components: LinguistTools, PrintSupport, Xml, Svg, Sql, Network, Widgets, Concurrent
"@
}
Write-Host "  [OK] Qt: $QtDir" -ForegroundColor DarkGreen

# ── NSIS ────────────────────────────────────────────────────────────────
Write-Host "  Checking NSIS ..."
$nsisExe = $null
$nsisSearchPaths = @(
    "${env:ProgramFiles(x86)}\NSIS\makensis.exe",
    "${env:ProgramFiles}\NSIS\makensis.exe",
    "C:\NSIS\makensis.exe"
)
foreach ($p in $nsisSearchPaths) {
    if (Test-Path $p) { $nsisExe = $p; break }
}
if (-not $nsisExe) {
    if (-not (Test-CommandExists "makensis")) {
        Install-WithWinget "NSIS.NSIS" "NSIS"
        # Re-scan
        foreach ($p in $nsisSearchPaths) {
            if (Test-Path $p) { $nsisExe = $p; break }
        }
        if (-not $nsisExe -and (Test-CommandExists "makensis")) {
            $nsisExe = (Get-Command makensis).Source
        }
    } else {
        $nsisExe = (Get-Command makensis).Source
    }
}
if (-not $nsisExe) {
    Write-Error "NSIS (makensis.exe) not found. Install from https://nsis.sourceforge.io/ or via winget."
}
Write-Host "  [OK] NSIS: $nsisExe" -ForegroundColor DarkGreen

Write-Host ""
Write-Host "  All dependencies satisfied." -ForegroundColor Green
Write-Host ""

# ════════════════════════════════════════════════════════════════════════
#  2. INITIALISE GIT SUBMODULES
# ════════════════════════════════════════════════════════════════════════
Write-Host "[2/6] Initialising git submodules ..." -ForegroundColor Green
Push-Location $RepoRoot
try {
    git submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "git submodule update returned exit code $LASTEXITCODE — some submodules may be missing."
    }
} finally {
    Pop-Location
}

# ════════════════════════════════════════════════════════════════════════
#  3. CMAKE CONFIGURE + BUILD
# ════════════════════════════════════════════════════════════════════════
if (-not $SkipBuild) {
    Write-Host "[3/6] Configuring CMake ..." -ForegroundColor Green

    if (-not (Test-Path $BuildDir)) {
        New-Item -ItemType Directory -Path $BuildDir | Out-Null
    }

    # Pick generator
    if (-not $Generator) {
        if (Test-CommandExists "ninja") {
            $Generator = "Ninja"
        } elseif ($vsInstallPath) {
            # Detect VS version for generator name
            $vsVersion = & $vsWhere -latest -property catalog_productLineVersion 2>$null
            switch ($vsVersion) {
                "2022" { $Generator = "Visual Studio 17 2022" }
                "2019" { $Generator = "Visual Studio 16 2019" }
                default { $Generator = "Visual Studio 17 2022" }
            }
        } else {
            $Generator = "MinGW Makefiles"
        }
    }
    Write-Host "  Generator: $Generator"

    $cmakeArgs = @(
        "-S", $RepoRoot,
        "-B", $BuildDir,
        "-G", $Generator,
        "-DCMAKE_BUILD_TYPE=$BuildType",
        "-DCMAKE_PREFIX_PATH=$QtDir",
        "-DPACKAGE_TESTS=OFF"
    )

    # For VS generators, specify x64 architecture
    if ($Generator -match "Visual Studio") {
        $cmakeArgs += @("-A", "x64")
    }

    cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "CMake configure failed (exit $LASTEXITCODE)."
    }

    Write-Host "[4/6] Building ($BuildType) ..." -ForegroundColor Green
    cmake --build $BuildDir --config $BuildType --parallel
    if ($LASTEXITCODE -ne 0) {
        Write-Error "CMake build failed (exit $LASTEXITCODE)."
    }
} else {
    Write-Host "[3/6] Skipping CMake configure (--SkipBuild) ..." -ForegroundColor Yellow
    Write-Host "[4/6] Skipping build (--SkipBuild) ..." -ForegroundColor Yellow
}

# ════════════════════════════════════════════════════════════════════════
#  4. FIND THE BUILT EXECUTABLE
# ════════════════════════════════════════════════════════════════════════
Write-Host "[5/6] Staging installer files ..." -ForegroundColor Green

$exeCandidates = @(
    (Join-Path $BuildDir "qelectrotech.exe"),
    (Join-Path $BuildDir "$BuildType\qelectrotech.exe"),
    (Join-Path $BuildDir "bin\qelectrotech.exe")
)
$builtExe = $null
foreach ($c in $exeCandidates) {
    if (Test-Path $c) { $builtExe = $c; break }
}
if (-not $builtExe) {
    Write-Error @"
Cannot find built qelectrotech.exe in $BuildDir.
Searched: $($exeCandidates -join ', ')
Build may have failed or placed the binary elsewhere.
"@
}
Write-Host "  Found executable: $builtExe"

# ── Create staging layout expected by QET64.nsi ─────────────────────────
if (Test-Path $StageDir) {
    Remove-Item -Recurse -Force $StageDir
}
New-Item -ItemType Directory -Force -Path "$StageDir\bin" | Out-Null

# Copy executable
Copy-Item $builtExe "$StageDir\bin\QElectroTech.exe"

# Run windeployqt to copy Qt runtime DLLs
$windeployqt = Join-Path $QtDir "bin\windeployqt.exe"
if (-not (Test-Path $windeployqt)) {
    # Try finding it on PATH
    if (Test-CommandExists "windeployqt") {
        $windeployqt = (Get-Command windeployqt).Source
    }
}
if (Test-Path $windeployqt) {
    Write-Host "  Running windeployqt ..."
    & $windeployqt --$($BuildType.ToLower()) --no-translations "$StageDir\bin\QElectroTech.exe"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "windeployqt returned exit $LASTEXITCODE — some Qt plugins may be missing."
    }
} else {
    Write-Warning "windeployqt not found — Qt runtime DLLs will NOT be bundled. The installer may produce a broken installation."
}

# Copy data directories from the repo
$dataDirs = @(
    @{ Src = "elements";    Dst = "elements" },
    @{ Src = "titleblocks"; Dst = "titleblocks" },
    @{ Src = "examples";    Dst = "examples" },
    @{ Src = "ico";         Dst = "ico" }
)
foreach ($d in $dataDirs) {
    $src = Join-Path $RepoRoot $d.Src
    $dst = Join-Path $StageDir $d.Dst
    if (Test-Path $src) {
        Write-Host "  Copying $($d.Src) ..."
        Copy-Item -Recurse -Force $src $dst
    } else {
        Write-Warning "Directory $src not found — skipping."
    }
}

# Copy language .qm files
$langSrc = Join-Path $RepoRoot "lang"
$langDst = Join-Path $StageDir "lang"
New-Item -ItemType Directory -Force -Path $langDst | Out-Null
$qmFiles = Get-ChildItem -Path $BuildDir -Recurse -Filter "*.qm" -ErrorAction SilentlyContinue
if ($qmFiles) {
    foreach ($qm in $qmFiles) {
        Copy-Item $qm.FullName $langDst
    }
    Write-Host "  Copied $($qmFiles.Count) .qm translation files."
} elseif (Test-Path $langSrc) {
    $qmFromRepo = Get-ChildItem -Path $langSrc -Filter "*.qm" -ErrorAction SilentlyContinue
    if ($qmFromRepo) {
        foreach ($qm in $qmFromRepo) {
            Copy-Item $qm.FullName $langDst
        }
        Write-Host "  Copied $($qmFromRepo.Count) .qm files from repo lang/."
    }
}

# Copy misc files expected by the .nsi
$miscFiles = @("LICENSE", "CREDIT", "ELEMENTS.LICENSE", "README", "ChangeLog")
foreach ($f in $miscFiles) {
    $src = Join-Path $RepoRoot $f
    if (Test-Path $src) {
        Copy-Item $src $StageDir
    }
}

# Copy file-association helpers
$regFile = Join-Path $RepoRoot "misc\qet_uninstall_file_associations.reg"
if (Test-Path $regFile) {
    Copy-Item $regFile $StageDir
}

# Create register_filetypes.bat stub (referenced by NSIS script)
$regBat = Join-Path $StageDir "register_filetypes.bat"
if (-not (Test-Path $regBat)) {
    Set-Content -Path $regBat -Value "@echo off`r`necho File types registered by installer."
}

Write-Host "  Staging complete: $StageDir"

# ════════════════════════════════════════════════════════════════════════
#  5. BUILD NSIS INSTALLER
# ════════════════════════════════════════════════════════════════════════
Write-Host "[6/6] Building NSIS installer ..." -ForegroundColor Green

$nsiFile = Join-Path $ScriptDir "QET64.nsi"
if (-not (Test-Path $nsiFile)) {
    Write-Error "NSIS script not found at $nsiFile"
}

$softVersion = "${Version}-dev_x86_64-win64+${GitSha}"

& $nsisExe /DSOFT_VERSION="$softVersion" /DPROC=64 "$nsiFile"
if ($LASTEXITCODE -ne 0) {
    Write-Error "makensis failed (exit $LASTEXITCODE). Check NSIS output above."
}

# Find the produced installer
$installerExe = Get-ChildItem -Path $ScriptDir -Filter "Installer_QElectroTech-*.exe" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Installer created successfully!"           -ForegroundColor Green
if ($installerExe) {
    Write-Host "  $($installerExe.FullName)"             -ForegroundColor Green
    Write-Host "  Size: $([math]::Round($installerExe.Length / 1MB, 1)) MB" -ForegroundColor Green
}
Write-Host "============================================" -ForegroundColor Green

<#
.NOTES
    Dependency summary:
    ───────────────────
    Tool          Installed via        Required
    ──────────    ─────────────        ────────
    Git           winget Git.Git       Yes
    CMake 3.14+   winget Kitware.CMake Yes
    Ninja         winget Ninja-build   Optional (faster builds)
    Qt 5/6        manual install       Yes (pass -QtDir or auto-detected)
    MSVC / MinGW  VS Installer         Yes (C++17 support)
    NSIS          winget NSIS.NSIS     Yes (for installer creation)
#>
