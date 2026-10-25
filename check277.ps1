$c = Get-Content "E:\edit_video\android\app\src\main\kotlin\com\example\edit_video\Media3ExportService.kt"
for($i=277; $i -le 285; $i++){
    $ln = $i+1
    Write-Output "$ln`: $($c[$i])"
}