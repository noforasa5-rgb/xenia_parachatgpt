# Xbox 360 XUI runtime PoC 9

Base de Xenia Canary: `a5a18f5c752d08f8b0d84139b69b16fb370b8cbb`.

Esta compilación continúa directamente desde la POC8 validada con el vídeo
`logros7.mp4` y su log. No vuelve a implementar POC1-POC8.

## Cambios de esta prueba

- El fondo usa los ocho colores y posiciones del degradado vertical de
  `bgCurve1` en el `scr_Notification` original del dashboard 17559.
- `round`, `logoback`, `bg` y `explosion` usan sus colores y paradas radiales
  originales en vez de los círculos planos provisionales.
- Los cuatro indicadores dejan de ser puntos y se dibujan como tramos de aro
  luminoso alrededor del orbe.
- `xenonLogo.png` y `Achievement.png` se centran a tamaño nativo y se recortan
  dentro del control XUI. Esta es la interpretación que se prueba para
  `SizeMode=16`; POC8 mostró que escalar el PNG completo hacía ambos iconos
  demasiado pequeños.
- Continúan activos el evaluador POC6, el playhead y las 13 timelines obtenidas
  de `skin.xur`.

Los colores y paradas proceden del recurso original suministrado, pero esta
fase todavía contiene un adaptador específico para la geometría de
`scr_Notification`. Aún no es un intérprete general de todas las figuras CUST.
La fuente XTT y `NotifyPopup.xma` siguen pendientes.

## Uso

1. Sustituye el ejecutable anterior por `xenia_canary.exe` de este artefacto.
2. Conserva junto al ejecutable la misma carpeta `xbox360_ui` validada en POC8,
   con `notify.xur`, `skin.xur`, `xenonLogo.png` y `Achievement.png`.
3. Obtén un logro real y graba desde antes de aparecer hasta que desaparezca.
4. Cierra Xenia y guarda también `xenia.log`.

## Qué comprobar visualmente

- El orbe de Xbox debe llenar mejor el círculo que en POC8.
- El trofeo debe verse más grande y reconocible.
- La barra no debe tener una línea rectangular clara; sus bordes superior e
  inferior deben fundirse suavemente.
- Durante la explosión deben aparecer capas grises/verdes y cuatro tramos de
  aro, no los cuatro puntos sueltos de POC8.
- Entrada, estado central y salida deben terminar sin restos en pantalla.

## Marcas esperadas en el log

```text
XUI-POC6: timeline evaluator ready=true ... samples_failed=0 ... ease_selfcheck=true
XUI-POC7: snapshot evaluator ready=true
XUI-POC8: original texture loaded 'xbox360_ui/xenonLogo.png' (108x108)
XUI-POC8: original texture loaded 'xbox360_ui/Achievement.png' (32x32)
XUI-POC9: original gradient renderer activated (SizeMode16 native-center/clipped)
XUI-POC9: external-close -> TransFrom frame=186
XUI-POC9: renderer Stop at EndTransFrom frame=240
```

Si falta cualquiera de los dos PNG se usa la notificación estándar y el log
lo indica; la aplicación no debe cerrarse por ese motivo.
