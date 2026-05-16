# App Icons

The canonical app icon source is [`app_icon.svg`](app_icon.svg).
The canonical transparent brand mark source is [`brand_mark.svg`](brand_mark.svg).

That SVG is full-bleed and deliberately has no platform chrome: no rounded corners, no shadow, and no inset card. iOS applies the outer app icon mask itself, so iOS AppIcon PNGs must be generated directly from the full-bleed SVG rather than from a macOS-style rounded icon.

Use the transparent brand mark for template icons, menu bar icons, and inline logos.

Regenerate platform icons and landing brand assets with:

```bash
./scripts/generate_app_icons.sh
```
