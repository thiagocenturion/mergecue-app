UI resources loaded through Bundle.module (SwiftPM and the app bundle).

- AppMark.png / @2x: the approved app icon (fallback outside the .app).
- MenuBar-light*.png / @2x: owner-provided LIGHT glyphs for a DARK menu bar (copies of Design/menubar/).
- MenuBar-dark*.png / @2x: DARK glyphs for a LIGHT menu bar.
- "-dot" variants carry the mint signal dot (something needs you or is ready).
These are coloured images, not templates: MenuBarIcon picks the variant from the status button's effective
appearance at draw time.
