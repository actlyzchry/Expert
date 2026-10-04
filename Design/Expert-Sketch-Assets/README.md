# Expert — Sketch asset pack

## Use in Sketch
Unzip the pack, create a Sketch document, and drag any SVG from Components, Icons, Brand, Screens or Foundations onto the canvas. Each SVG is self-contained. Use Expert-Overview.svg to browse the component collection. Convert recurring imported groups into Symbols and save your document as a Sketch Library if desired.

Official SVG import guidance: https://www.sketch.com/docs/designing/graphics/

## Contents
- 40 editable outline icons: 20 designs in light and dark variants, 24 × 24.
- 20 component SVGs: buttons, field, add-skill control, skill card, session row, timer, progress bar, saved state.
- 2 illustrative home layouts at 390 × 844.
- Editable vector brand mark and wordmark; original 1024px app icon PNG.
- Color/type reference, JSON design tokens, and component overview.

## Fidelity and editing
Source: App/Expert/ContentView.swift and the existing app icon. Components use the app’s Menlo font, palette, opacity treatments and corner radii. Example data is illustrative. Screen layouts are design references, not simulator screenshots. System colors are static default appearance references; iOS accessibility and platform settings can vary them. SVG text remains text; Menlo must be available on the importing Mac. Font weight substitution can vary by importer.

The vector mark is a simplified reconstruction of the existing icon, without its raster glow; the original PNG is the canonical icon. Icons are newly drawn editable equivalents for interface actions, not exported Apple SF Symbols. The app itself continues to use SF Symbols.

The add-skill control captures a static glow state; animation is not part of SVG delivery. No fonts are bundled. This is an SVG import pack, not a native .sketch document or preconfigured Symbol library. Sketch is not installed in the build environment, so native import has not been verified.
