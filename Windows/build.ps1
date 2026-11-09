param(
    [ValidateSet('x64', 'ARM64')][string]$Architecture = 'x64',
    [switch]$TestsOnly
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$deps = Join-Path $PSScriptRoot 'out/deps'
$archive = Join-Path $deps 'nlohmann-json.zip'
$sha = '5f6132720fb25d0d70bf0742f8397b49a540dcc193e7312a914f6aa49f054810'
if (!(Test-Path "$deps/nlohmann_json/include/nlohmann/json.hpp")) {
    New-Item -ItemType Directory -Force $deps | Out-Null
    Invoke-WebRequest 'https://files.pythonhosted.org/packages/51/69/a42fddc89a6de959b65b27a15d69de85e88d2f99884e00b1b02c12dce301/nlohmann_json-3.12.0-py3-none-any.whl' -OutFile $archive
    if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) {
        throw 'JSON header package checksum mismatch'
    }
    Expand-Archive $archive $deps -Force
}
$msbuild = Get-Command msbuild.exe -ErrorAction SilentlyContinue
if ($msbuild) { $compiler = $msbuild.Source }
else {
    $vswhere = Join-Path ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) 'Microsoft Visual Studio/Installer/vswhere.exe'
    $compiler = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\Current\Bin\MSBuild.exe' | Select-Object -First 1
}
if (!$compiler) { throw 'Install Visual Studio with Desktop development with C++ and the Windows 11 SDK.' }

$common = @('/nologo', '/m', '/p:Configuration=Release', "/p:Platform=$Architecture")
& $compiler 'Tests/BackupGeniusTests.vcxproj' @common
if ($LASTEXITCODE -ne 0) { throw "Core test build failed ($LASTEXITCODE)" }
if (!$TestsOnly) {
    & $compiler 'App/BackupGenius.vcxproj' '/restore' @common
    if ($LASTEXITCODE -ne 0) { throw "WinUI build failed ($LASTEXITCODE)" }
    $app = Join-Path $PSScriptRoot "out/$Architecture/app"
    if (!(Test-Path "$app/BackupGenius.exe")) { throw 'Missing WinUI executable' }
    Copy-Item '../LICENSE' "$app/LICENSE.txt" -Force
    Copy-Item '../README.md' "$app/README.md" -Force
    $runtimeLicense = Join-Path $PSScriptRoot 'out/packages/microsoft.windowsappsdk/2.6.5/license.txt'
    if (Test-Path $runtimeLicense) { Copy-Item $runtimeLicense "$app/Windows-App-SDK-LICENSE.txt" -Force }
    $notice = Get-ChildItem "$deps/nlohmann_json-3.12.0.dist-info" -Recurse -File |
        Where-Object { $_.Name -like 'LICENSE*' } | Select-Object -First 1
    if (!$notice) { throw 'Missing nlohmann/json license' }
    Copy-Item $notice.FullName "$app/nlohmann-json-LICENSE.txt" -Force
    New-Item -ItemType Directory -Force '../dist' | Out-Null
    Compress-Archive -Path "$app/*" -DestinationPath "../dist/Backup-Genius-Windows-$Architecture.zip" -Force
}
