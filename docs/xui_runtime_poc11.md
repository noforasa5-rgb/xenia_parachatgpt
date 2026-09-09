# Xbox 360 XUI runtime POC11

Base de Xenia Canary: `a5a18f5c752d08f8b0d84139b69b16fb370b8cbb`.

POC11 corrige el error visual señalado tras revisar `logros9.mp4`. POC9 era
válida como conexión entre el XUR y el renderizador, pero su animación no era
una reproducción fiel: confundía límites de grupos con geometría visible y
colocaba `round` sobre el logo.

## Cambios de esta prueba

- Usa la escena 460x87 declarada por `notify.xui` y centra dentro de ella el
  visual 370x61 con sus márgenes originales de 45x13.
- Reconstruye `bgCurve1` a partir de sus elementos hijos: cuerpo de
  305x55,7883, los dos brillos originales de 350x8, remate radial derecho de
  61x61,5 y la transformación animada alrededor del pivote 32,5597.
- Coloca `round` como remate izquierdo de la barra. POC9 lo dibujaba
  erróneamente como otro círculo completo centrado sobre el orbe.
- Respeta el orden del skin: barra, remate izquierdo, `logoback`, grupo `bg`,
  explosión, indicadores e imágenes.
- Los fondos radiales admiten escalas X/Y distintas y la explosión usa el
  radio de 22,5 indicado por su figura, en vez del radio provisional 31.
- Los cuatro indicadores comparten el centro real del logo y usan radio 32,5;
  ya no se desplazan como cuatro círculos independientes.
- `TextPresenter` utiliza su tamaño 11 y color `0xffebebeb` en ambas líneas.
- Conserva las timelines, la interpolación Ease, los PNG originales y el
  sonido XMA de POC10.

## Archivos necesarios

```text
xbox360_ui/
  notify.xur
  skin.xur
  xenonLogo.png
  Achievement.png
  NotifyPopup.xma
```

## Qué comprobar en el vídeo

- El orbe debe permanecer en un único centro; no debe aparecer una segunda
  esfera gris detrás.
- La barra debe nacer debajo del orbe, crecer hacia la derecha con altura
  cercana al diámetro del orbe y terminar en una punta redondeada.
- El pequeño exceso de tamaño al abrirse debe volver a su anchura normal.
- Los arcos deben quedar pegados al borde del orbe.
- El logo y el trofeo deben alternarse en el mismo centro.
- La salida debe contraer la barra hacia el orbe y terminar sin restos.
- El sonido original debe reproducirse una sola vez.

## Marcas esperadas

```text
XUI-POC6: timeline evaluator ready=true ... samples_failed=0 ... ease_selfcheck=true
XUI-POC7: snapshot evaluator ready=true
XUI-POC8: original texture loaded 'xbox360_ui/xenonLogo.png' (108x108)
XUI-POC8: original texture loaded 'xbox360_ui/Achievement.png' (32x32)
XUI-POC10: original NotifyPopup.xma playback started path='xbox360_ui/NotifyPopup.xma'
XUI-POC11: source-layout animation renderer activated (460x87 scene, 370x61 visual)
XUI-POC11: external-close -> TransFrom frame=186
XUI-POC11: renderer Stop at EndTransFrom frame=240
```
