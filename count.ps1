$p = "E:\edit_video\android\app\src\main\kotlin\com\example\edit_video\Media3ExportService.kt"
$s = [System.IO.File]::ReadAllText($p)
$c = ($s -split "Effects").Count - 1
Write-Host $c