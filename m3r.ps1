$lines = [System.IO.File]::ReadAllLines("E:\edit_video\android\app\src\main\kotlin\com\example\edit_video\Media3ExportService.kt")
for($i=80; $i -lt [Math]::Min($lines.Length, 300); $i++){
    $ln = $i+1
    Write-Host "$ln`: $($lines[$i])"
}