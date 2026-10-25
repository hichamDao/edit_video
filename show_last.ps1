$lines = [System.IO.File]::ReadAllLines("E:\edit_video\m3r_out.txt")
$start = [Math]::Max(0, $lines.Length - 250)
for($i=$start; $i -lt $lines.Length; $i++){
    Write-Output $lines[$i]
}