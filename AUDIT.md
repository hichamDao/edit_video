# Audit du projet edit_video

## Versions
- Flutter 3.24.5 / Dart 3.5.4 / Gradle 8.3 / Kotlin 1.8.22 / compileSdk 35 / minSdk par defaut Flutter.

## Dependances initiales
- uuid 4.6.0, video_player 2.9.5, image_picker 1.1.2, file_picker 8.3.7, path_provider 2.1.5, permission_handler 11.4.0, flutter_lints 4.0.0.
- Aucune dependance Media3, ffmpeg ou effet video.

## Fichiers existants
- lib/main.dart - routes / (EditorScreen) et /export (ExportScreen)
- lib/models/capcut_models.dart - Project, Track, Segment, Clip, TimeRange, Transform, Flip, Scale, MaterialEffect, MaterialTransition, VideoMetadata, VEClipInfo
- lib/services/segment_service.dart - SegmentService, ProjectServiceImpl, DraftTransformer
- lib/services/export_service.dart - ExportService, Exporter, HWCodecService, ExportVideoConfig, ExportProgress, ExportStatus, NativeDraftBridge
- lib/features/editor/editor_screen.dart - import + timeline + preview
- lib/features/export/export_screen.dart - settings UI (projet factice)
- lib/core/constants.dart - constantes
- test/widget_test.dart - test casse (MyApp n'existe pas)
- android/app/build.gradle - minSdk par defaut, aucune dependance Media3
- android/app/src/main/kotlin/.../MainActivity.kt - vide

## Etat de l'analyse initiale
17 problemes (1 error, 10 warnings, 6 infos). L'error venait du test test/widget_test.dart:16 qui appelait MyApp (la classe s'appelle EditVideoApp).

## Ce qui fonctionnait
- Modele de donnees coherent
- SegmentService.split
- ProjectServiceImpl (create/add/remove/split/move/effect/transform)
- Timeline avec regles temporelles
- Preview VideoPlayerController
- UI d'export avec stream de progression

## Lacunes critiques identifiees
1. Export factice - Exporter.render() fait une boucle Future.delayed(8ms) et ecrit un fichier vide de 0 bytes. Aucun rendu video reel.
2. Duree des clips codee - _importVideo utilise Duration(seconds: 5) constant. La duree reel n'est jamais lue.
3. Pas de detection de duree - aucun MediaMetadataRetriever/ffprobe.
4. Pas de sauvegarde de projet - draftPath jamais utilise.
5. Pas d'annuler/rtablir, pas de zoom, pas de textes/sous-titres, pas de transitions, pas de rognage/deplacement/duplication UI, pas de gestion audio (volume/fondus), pas de settings image/vitesse.
6. ExportScreen utilise un projet factice - pas de lien avec le projet reel.
7. Aucune dependance Media3 - Android Gradle ne declare rien.

## Evaluation Media3 Transformer
- Couvre : import/decodage, trim, speed change, volume, fondus, transitions de base, encodage H.264/H.265 MediaCodec, progression, annulation.
- Ne couvre pas : texte/sous-titres incrustes, keyframes, overlays multi-pistes, transitions avancees (slide/wipe).

## Fonctionnalite prioritaire n°1
Import avec detection de duree reel + Export reel via Media3 Transformer (Kotlin natif).

