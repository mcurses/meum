# meum icon

Two open upright planes as marks on a paper ground.

- `meum.icon`: the macOS app icon (icon set v3, 2026-11-12), an Icon Composer bundle with the light, dark, clear and
  tinted appearances. `scripts/build-app.sh` compiles it with `xcrun actool` into `Assets.car` (macOS 26 draws the
  four appearances from it; 11–15 use its flattened light icon) and a `meum.icns` fallback at 16–1024 px. Needs the
  Xcode 26 toolchain.
- `meum-1024-opaque.png`, `meum-1024.png`, `meum-mark.svg`: the earlier artwork (icon set v2) and the mark alone on a
  transparent canvas, for docs and web.
