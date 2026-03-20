# post_build_shutdown.ps1
# Monitors build log until G-Control.exe appears or error detected, then shuts down.

$logFile  = "E:\qgc-pxlabs\build_log.txt"
$exePath  = "E:\qgc-pxlabs\build_clean\Release\G-Control.exe"
$statusFile = "E:\qgc-pxlabs\build_result.txt"

Write-Host "Monitoring build... will shutdown on success."

while ($true) {
    Start-Sleep -Seconds 15

    if (Test-Path $exePath) {
        "SUCCESS" | Set-Content $statusFile
        Write-Host "BUILD SUCCEEDED. Shutting down in 30 seconds..."
        Start-Sleep -Seconds 30
        Stop-Computer -Force
        exit 0
    }

    if (Test-Path $logFile) {
        $last = Get-Content $logFile -Tail 5 | Out-String
        if ($last -match "BUILD FAILED|CMake Error|error MSB|FAILED") {
            # Check if it's just old errors, not new
            $tail = Get-Content $logFile -Tail 20 | Out-String
            if ($tail -match "BUILD FAILED") {
                "FAILED" | Set-Content $statusFile
                Write-Host "BUILD FAILED. NOT shutting down."
                exit 1
            }
        }
        if ($last -match "BUILD SUCCEEDED") {
            "SUCCESS" | Set-Content $statusFile
            Write-Host "BUILD SUCCEEDED. Shutting down in 30 seconds..."
            Start-Sleep -Seconds 30
            Stop-Computer -Force
            exit 0
        }
    }
}
