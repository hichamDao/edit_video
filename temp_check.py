with open(r'E:\edit_video\android\app\src\main\kotlin\com\example\edit_video\Media3ExportService.kt','r',encoding='utf-8') as f:
    for i,l in enumerate(f):
        if 'TimedTextOverlay' in l or 'getText' in l or 'getOverlaySettings' in l or 'TextItem' in l:
            print(i+1, l.rstrip())
            if i>400:
                break
