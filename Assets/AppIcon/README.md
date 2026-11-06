# Landing Signal

Approved Splash Finish app icon: three raised amber signals on a dark slate tile.
Designed by Codex; this is candidate 1 selected by the user.

- `AppIcon.svg` — editable vector artwork (gradients, paths, bevels and shadows).
- `png/1024.png` — approved 1024×1024 master, with transparent margins/corners.
- `png/{16,32,64,128,256,512}.png` — direct SVG renders at native sizes, so small icons do not depend on downsampling the master.

`Scripts/render_icon.swift` copies these PNGs into the standard ten-layer macOS iconset and invokes Apple's `iconutil`. `Scripts/package_app.sh` embeds the resulting `build/Icon.icns` in the app. Normal builds require no Homebrew or third-party renderer. The menu-bar icon remains a separate monochrome template image.

After intentionally editing the SVG, regenerate the checked-in PNGs using librsvg (`rsvg-convert`):

```sh
for size in 16 32 64 128 256 512 1024; do
  rsvg-convert --width "$size" --height "$size" \
    --output "Assets/AppIcon/png/$size.png" Assets/AppIcon/AppIcon.svg
done
swift Scripts/render_icon.swift
```

Inspect the master and 16/32-pixel renders on light and dark backgrounds before committing regenerated artwork. The other design candidates are not part of the production bundle.
