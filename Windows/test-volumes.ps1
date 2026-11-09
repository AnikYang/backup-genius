param(
    [ValidateSet('x64', 'ARM64')][string]$Architecture = 'x64',
    [string]$MacFixture,
    [string]$OutputFixture,
    [switch]$Benchmark
)
$ErrorActionPreference = 'Stop'
$test = Join-Path $PSScriptRoot "out/$Architecture/tests/BackupGeniusTests.exe"
if (!(Test-Path $test)) { throw 'Build Windows tests first.' }
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("Backup-Genius-Tests-" + [Guid]::NewGuid())
New-Item -ItemType Directory $work | Out-Null
$diskImage = Join-Path $work 'scratch.vhdx'
$diskPart = Join-Path $work 'create.txt'

& $test
if ($LASTEXITCODE -ne 0) { throw "NTFS tests failed ($LASTEXITCODE)" }
if ($Benchmark) {
    New-Item -ItemType Directory -Force "$PSScriptRoot/../dist" | Out-Null
    & $test --benchmark 100000 ([System.IO.Path]::GetTempPath()) "$PSScriptRoot/../dist/performance-NTFS-$Architecture.json"
    if ($LASTEXITCODE -ne 0) { throw 'NTFS benchmark failed' }
}

try {
    @("create vdisk file=""$diskImage"" type=expandable maximum=2048", "select vdisk file=""$diskImage""", 'attach vdisk') |
        Set-Content -Path $diskPart -Encoding ascii
    & diskpart.exe /s $diskPart
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the disposable exFAT test disk' }
    $image = Get-DiskImage -ImagePath $diskImage
    $disk = $image | Get-Disk
    if (!$image.Attached -or !$disk -or @($disk).Count -ne 1 -or $disk.IsBoot -or $disk.IsSystem -or
        $disk.PartitionStyle -ne 'RAW' -or $disk.BusType -ne 'File Backed Virtual') {
        throw 'The expected new, unformatted VHDX was not found'
    }
    $disk | Initialize-Disk -PartitionStyle GPT
    $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    $volume = Format-Volume -Partition $partition -FileSystem exFAT -NewFileSystemLabel 'BGTEST' -Confirm:$false -Force
    if (!$volume.DriveLetter -or $volume.FileSystem -ne 'exFAT') { throw 'Test volume setup failed' }
    $mount = "$($volume.DriveLetter):\"
    & $test $mount
    if ($LASTEXITCODE -ne 0) { throw "exFAT tests failed ($LASTEXITCODE)" }
    if ($MacFixture) {
        if (!$OutputFixture) { throw 'Specify an output path for the exchanged fixture' }
        & $test --interop $MacFixture $OutputFixture $mount
        if ($LASTEXITCODE -ne 0) { throw "Cross-platform fixture test failed ($LASTEXITCODE)" }
    }
    if ($Benchmark) {
        & $test --benchmark 100000 $mount "$PSScriptRoot/../dist/performance-exFAT-$Architecture.json"
        if ($LASTEXITCODE -ne 0) { throw 'exFAT benchmark failed' }
    }
} finally {
    if (Test-Path $diskImage) {
        $attached = Get-DiskImage -ImagePath $diskImage -ErrorAction SilentlyContinue
        if ($attached.Attached) { Dismount-DiskImage -ImagePath $diskImage }
        if (!(Get-DiskImage -ImagePath $diskImage -ErrorAction SilentlyContinue).Attached) {
            Remove-Item -LiteralPath $diskImage
        }
    }
    if (Test-Path $diskPart) { Remove-Item -LiteralPath $diskPart }
    if (!(Get-ChildItem -LiteralPath $work)) { Remove-Item -LiteralPath $work }
}
