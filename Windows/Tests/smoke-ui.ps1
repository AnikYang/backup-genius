param([ValidateSet('x64', 'ARM64')][string]$Architecture = 'ARM64')
$ErrorActionPreference = 'Stop'
$os = Get-CimInstance Win32_OperatingSystem
Write-Output "UI host: $($os.Caption) $($os.Version)"
if ($os.ProductType -ne 1 -or [int]$os.BuildNumber -lt 26200) { throw 'Use a Windows 11 25H2 or later desktop' }
$app = Join-Path $PSScriptRoot "../out/$Architecture/app/BackupGenius.exe"
if (!(Test-Path $app)) { throw 'Build the WinUI application first' }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$process = Start-Process $app -PassThru
try {
    $limit = (Get-Date).AddSeconds(30)
    $content = $null
    do {
        Start-Sleep -Milliseconds 200
        $process.Refresh()
        if ($process.HasExited) { throw "App exited with $($process.ExitCode)" }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
            $condition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, '尚未设置备份')
            $content = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        }
    } until ($content -or (Get-Date) -ge $limit)
    if (!$content) { throw 'Native window did not expose its setup heading' }
    Write-Output 'WinUI startup and accessibility tree verified.'
} finally {
    if (!$process.HasExited) { Stop-Process -Id $process.Id }
}
