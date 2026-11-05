# meum icon

Two open upright planes of sage-green glass on light paper.

- `meum-1024-opaque.png`: the artwork, square and full-bleed (no rounded plate: macOS applies its own mask). The
  source for `meum.icns`.
- `meum-1024.png`, `meum-mark.svg`: the mark alone as a silhouette on a transparent canvas, for docs and web.
- `meum.icns`: the macOS app icon, the artwork at 16–1024 px via `iconutil`.

Regenerate `meum.icns`: write a `.iconset` with the ten sizes (`sips -z`) from `meum-1024-opaque.png`, then
`iconutil -c icns`.
