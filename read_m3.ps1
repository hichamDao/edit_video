$c = Get-Content "E:\edit_video\android\app\src\main\kotlin\com\example\edit_video\Media3ExportService.kt"
for($i=0; $i -lt [Math]::Min($c.Count,250); $i++){
    Write-Output (($i+1).ToString()+": "+$c[$i])
}