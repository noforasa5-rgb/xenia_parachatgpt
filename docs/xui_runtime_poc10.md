# Xbox 360 XUI runtime POC10

Base de Xenia Canary: `a5a18f5c752d08f8b0d84139b69b16fb370b8cbb`.

Esta compilación continúa directamente desde POC9, validada con `logros9.mp4`
y su registro. Mantiene completos el lector XUR, el evaluador POC6, las 13
timelines, los PNG originales, los degradados, los arcos y el ajuste SizeMode16.

## Cambio de esta prueba

- Al comenzar cada logro, el runtime busca `xbox360_ui/NotifyPopup.xma`, el
  sonido original al que hace referencia `skin.xur`.
- Windows reproduce directamente el RIFF/XMA1 original. El archivo no se
  convierte, no se modifica y no se incorpora al repositorio.
- El disparo tiene una protección por notificación para que el sonido se
  reproduzca una sola vez aunque el popup se dibuje durante muchos fotogramas.
- Si el archivo falta o Windows lo rechaza, el popup visual sigue funcionando
  y el motivo queda indicado en `xenia.log`.

El recurso suministrado para esta prueba es válido: XMA1, mono, 44,1 kHz,
aproximadamente 0,52 segundos.

## Uso

1. Sustituye el ejecutable anterior por `xenia_canary.exe` de este artefacto.
2. Conserva la carpeta `xbox360_ui` de POC9.
3. Añade dentro de ella el archivo original `NotifyPopup.xma` que ya tienes en
   `xbox360_notification_original_assets.zip`.
4. Obtén un logro y graba con el audio del sistema activado.
5. Cierra Xenia y guarda también `xenia.log`.

La carpeta debe quedar así:

```text
xbox360_ui/
  notify.xur
  skin.xur
  xenonLogo.png
  Achievement.png
  NotifyPopup.xma
```

## Qué comprobar

- El sonido original debe oírse una vez, sincronizado con el comienzo del
  popup.
- No debe repetirse durante el estado central ni al desaparecer.
- La imagen debe conservar el aspecto ya validado en POC9.
- El popup debe desaparecer sin restos.

## Marcas esperadas en el log

```text
XUI-POC6: timeline evaluator ready=true ... samples_failed=0 ... ease_selfcheck=true
XUI-POC7: snapshot evaluator ready=true
XUI-POC8: original texture loaded 'xbox360_ui/xenonLogo.png' (108x108)
XUI-POC8: original texture loaded 'xbox360_ui/Achievement.png' (32x32)
XUI-POC10: original NotifyPopup.xma playback started path='xbox360_ui/NotifyPopup.xma'
XUI-POC10: original XMA sound + validated POC9 renderer activated
XUI-POC9: external-close -> TransFrom frame=186
XUI-POC9: renderer Stop at EndTransFrom frame=240
```

Si aparece `original sound unavailable`, falta copiar el XMA. Si aparece
`PlaySoundW rejected original XMA`, conserva el archivo y envía el registro;
el render visual seguirá activo.
