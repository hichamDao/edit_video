$p = "E:\edit_video\android\app\src\main\kotlin\com\example\edit_video\Media3ExportService.kt"
$c = [System.IO.File]::ReadAllText($p)
$c = $c.Replace("import androidx.media3.common.Effects`r`n", "")
$c = $c.Replace("import androidx.media3.common.Effects`n", "")
$old1 = "            b.setEffects(Effects(audioProcs, videoEffects))"
$new1 = "            if (audioProcs.isNotEmpty()) b.setAudioProcessors(audioProcs)`r`n            if (videoEffects.isNotEmpty()) b.setVideoEffects(videoEffects)"
if ($c.Contains($old1)) { $c = $c.Replace($old1, $new1) }
$old2 = "Effects(listOf(), listOf<Effect>(OverlayEffect(ImmutableList.copyOf(overlays)))"
$new2 = "listOf<Effect>(OverlayEffect(ImmutableList.copyOf(overlays)))"
if ($c.Contains($old2)) { $c = $c.Replace($old2, $new2) }
[System.IO.File]::WriteAllText($p, $c)
Write-Host "done"