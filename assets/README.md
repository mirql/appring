# appring logo and app icons

The mark is the app itself, drawn in pixels: eight buttons in a ring, the highlighted one
bigger and glowing pink, a centre disc with an arrow pointing at it. The files are generated
as a set: don't hand-edit one of them.

| File | What it is for |
|------|----------------|
| `logo/appring-banner.svg` | the README's header: mark, name and tagline on a night sky, one image for GitHub's dark and light themes |
| `logo/appring-dark.svg`, `logo/appring-light.svg` | the name alone, transparent, as a dark/light pair |
| `logo/appring-lockup-dark.svg`, `logo/appring-lockup-light.svg` | the mark and the name, for docs and slides |
| `logo/appring-mark-dark.svg`, `logo/appring-mark-light.svg` | the mark alone, transparent |
| `logo/appring-icon.svg`, `logo/appring-icon-512.png` | the mark on a night tile: avatar, store pages |
| `logo/social-preview.png` (+ `.svg`) | GitHub's social preview, 1280×640 |
| `icons/linux/hicolor/` | a hicolor icon theme: 16 to 512 px, `scalable/`, `symbolic/`. Icon name `com.mirql.appring` |
| `icons/windows/appring.ico` | 16 to 256 px in one file |
| `icons/macos/appring.icns` | 16 to 1024 px on Apple's grid |

Small icons are not scaled down from the big one: below 64 px they use a 16-pixel drawing
(eight dots, the highlighted button, the centre), from 64 px the full 32-pixel tile, each at
a whole number of screen pixels per art pixel.
