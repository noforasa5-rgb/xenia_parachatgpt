# XUI Runtime PoC 3 plan

This branch continues the Xbox 360 achievement notification XUI runtime work.

Source of truth remains the user's original `notify.xur` and `skin.xur` extracted from their own Xbox 360 dashboard. Converted XUI files are used only as a reverse-engineering oracle to validate the native parser; they are not bundled.

PoC 3 targets:
- Parse DATA8 object tree enough to locate `scr_Notification` dynamically.
- Parse KEYP8 property index stream.
- Bind KEYD8 keyframes to the 13 `scr_Notification` timelines.
- Preserve raw KEYD flag bytes, including unknown flag forms, rather than assuming linear interpolation.
- Log the discovered object tree and timeline ranges from the original XUR at runtime.

Validated from the converted 17559 scene:
- `NotifyPopupScene` -> `PopupControl` -> Visual `scr_Notification`.
- `scr_Notification` is `XuiVisual`, 370x61, with 13 direct children and 13 timelines.
- Named frames: `TransTo` 0, `loop` 65, `EndTransTo` 185 -> GoToAndPlay(loop), `TransFrom` 186, `EndTransFrom` 240 -> Stop, `EndTransBackFrom` 241 -> Stop.
- The `scr_Notification` timeline keyframe range is KEYD indices 315..401 inclusive. None of those keyframes use the XUIHelper-unknown 0x0A / 0x0B flag forms.

No Microsoft dashboard binary/image/font assets are committed to this repository.
