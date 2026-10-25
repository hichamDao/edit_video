$lines = [System.IO.File]::ReadAllLines("E:\edit_video\android\app\src\main\kotlin\com\example\edit_video\Media3ExportService.kt")
for($i=0; $i -lt [Math]::Min($lines.Length, 250); $i++){
  $num = $i+1
  Write-Host ($num.ToString() + ": " + $lines[$i])
}