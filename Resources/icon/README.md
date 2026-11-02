# meum icon

- `meum-1024-opaque.png`: the artwork (layered emerald wave hexagon on near-black), square and full-bleed. The source
  for `meum.icns`.
- `meum-1024.png`: the mark alone on a transparent canvas, for docs and web.
- `meum.icns`: the macOS app icon, the opaque artwork at 16–1024 px via `iconutil`. It is full-bleed on purpose:
  macOS 26 rounds a square icon itself, but puts any non-square shape (the transparent hexagon) small on a grey
  plate.

Regenerate: write a `.iconset` with the ten sizes (`sips -z`) from `meum-1024-opaque.png`, then `iconutil -c icns`.
