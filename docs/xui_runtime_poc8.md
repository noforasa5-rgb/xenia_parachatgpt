# Xbox 360 XUI runtime POC8: imágenes originales y colocación

Continúa la POC7 alpha de `89f8b5080cbdc53efa7a38b661822e077f738d28`,
sobre Xenia Canary `a5a18f5c752d08f8b0d84139b69b16fb370b8cbb`.

La prueba anterior confirmó los diagnósticos POC6 y dos notificaciones
completas de la alpha. Esta entrega conserva ese evaluador y da el siguiente
paso visual. Todavía no reproduce todas las figuras y degradados del skin.

## Cambios

- Carga `xenonLogo.png` y `Achievement.png` desde la carpeta del runtime y
  sustituye la X y el trofeo dibujados con líneas.
- Conserva los márgenes transparentes de las imágenes. Las cajas y pivotes
  se basan en el layout 17559 inspeccionado; SizeMode y Anchor completos
  requieren el siguiente paso de layout y comparación visual.
- Usa la posición y el pivote para colocar los fondos circulares
  provisionales y el efecto de entrada; evita sumar dos veces sus centros.
- Aplica el pivote al estiramiento del fondo alargado.
- Elimina el borde exterior de la ventana ImGui y evita guardar su layout.
- Usa un identificador de ventana por notificación para evitar colisiones.
- Conserva Anchor en el snapshot, añade posiciones iniciales de los
  presentadores y recorta el texto al ancho de su caja.
- Mantiene las texturas en el drawer y las libera al cambiar el dispositivo.
  Si un PNG falta o no se puede cargar, usa la notificación estándar y registra
  el fallo; reiniciar tras corregir el archivo para reintentar la carga.

## Uso de la build

Extraer el artefacto y colocar esta carpeta junto a `xenia_canary.exe`:

```
xbox360_ui/
  notify.xur
  skin.xur
  xenonLogo.png
  Achievement.png
```

Reutilizar los recursos ya verificados. No recortar los PNG. Este repositorio
no incluye los assets extraídos de la consola, las fuentes XTT ni los perfiles.

Para comparar con la prueba anterior, activar un logro pendiente y grabar la
notificación completa. Entregar también el `xenia.log` de esa ejecución.
Buscar `XUI-POC8: original texture loaded`, `original PNG renderer activated`,
`external-close` y `renderer Stop`. Los mensajes POC6/POC7 del evaluador son
normales y se conservan para comparar resultados.

Comprobar: PNG reales, ausencia del rectángulo exterior, colocación de iconos,
entrada/alternancia/salida, redimensionado y ausencia de elementos residuales.
El log debe seguir indicando los diagnósticos POC6 correctos.

## Alcance pendiente

Fondos e indicadores siguen usando geometría provisional. Quedan figuras
CUST, degradados, layout general de Anchor/SizeMode, fuente original y sonido
XMA. Los 60 ticks/s y el tiempo de presentación se heredan de la alpha; no
se presentan como constantes demostradas del formato original.

## Compilación

El workflow nuevo reutiliza exactamente la revisión y la cadena acumulativa
de parches que produjo la POC7, y aplica después el parche POC8. Reconstruir
esa base no significa repetir su investigación. El parche verifica que el
evaluador anterior a la conversión del snapshot no cambie y preserva el hook
de inicialización. Las comprobaciones de integración no sustituyen al build
C++ ni a la prueba visual del ejecutable.

El artefacto incluye ejecutable, SHA-256, esta guía, procedencia de commits y
los seis archivos C++ modificados, incluido el encabezado de notificación.
