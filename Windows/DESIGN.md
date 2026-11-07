# Bezzle for Windows looks like Bezzle for the Mac

Erik (2026-11-06): the Windows app has the same design as the Mac app. These are the Mac's own
numbers, from its code (paths under `Bezzle/`); the Windows code takes them from here
(`Sources/Bezzle/Theme.swift`). What differs is only what Windows does its own way: the window's
caption buttons sit at the right of the bar, where the Mac has its traffic lights at the left.

## Window (Views/TabBar.swift, Workspace.swift)

- Bar 52 pt (`Theme.barHeight`). Tabs from 90 pt in on the Mac (traffic lights); on Windows from
  16 pt, the caption buttons to the right of everything. Home tab: "Bezzle" in the serif, 15
  semibold, 30 tall, 10 padding. Design tab: 30 tall, 12.5 (medium in front), front tab 196 wide on
  a card of radius 9; others 44–196, ink 5% on hover; close cross 18×18, line 1.3; "+" 26 circle.
  Right of the bar, spacing 10: zoom ("NN%"), Versions, Share…, mode switch, mode action (Export…).
- Body below the bar: tool rail 56 | layers 236 | canvas (radius 12, 9 below, 2 right; edge
  shadow 1.5 pt at 22%, blur 1.5, y+1, and a 0.5 hairline) | inspector 280. Window minimum
  1000 × 640. The panels have no fill of their own: they show the paper.

## Colours (Views/Theme.swift), light / dark

paper #F0EDE7 / #1B1A18 · panel #F6F4EF / #22211F · card #FCFBF8 / #2A2926 · well #E5E1D9 /
#141312 · ink #1C1B19 / #EDEAE4, ink2 64%, ink3 44%, ink4 22%, hairline 9% · shadow #3A3226 /
#000 · onInk #F6F4EF / #1B1A18 · pencil (accent) #3559C7 / #8FA8F2, pencilWash 10% / 16% ·
linked #7650D8 / #AE93F2 · warning #B3402F / #E4705C.

Canvas: table #E5E1D9 / #0F0E0D · selection #3A63D8 · gap marks #E0457B · artboard label ink 50%,
selected or hovered pencil · ruler beside an artboard #EAE7E0 / #161514.

Card: card fill, shadow 7% (r 7, y 3), lifted 16% (r 18, y 9), plus 8% (r 0.5, y 0.5); hairline
0.5. Well: well fill, inner shadow 22% (r 1.5, y 1), lip (white 75% / 5%) 1 pt below.

## Type

System font throughout (on Windows: the open SF stand-in, Inter, as the designs use); serif =
New York (on Windows: Gelasio). Layer rows 12.5 · panel titles 13 semibold · card titles 12.5
semibold · card summaries 12, mono digits · row labels 12 ink2 · fields 12 mono, labels 11 medium
· captions 11 ink3 · key caps 11 medium mono · menus 13, shortcuts 12 · artboard names 11 medium.

## Canvas (Canvas/CanvasView.swift, Renderer.swift)

Table behind the artboards. Zoom 0.02–64, steps 0.02 0.05 0.1 0.125 0.25 0.333 0.5 0.667 1 1.5 2 3
4 6 8 12 16 24 32 48 64; fit with 64 pt padding, never above 1×. Artboards white unless filled,
shadow 2 pt down, blur 10, 13%, no border. Name 19 above the artboard, 16 tall, tail-truncated,
hidden under 30 pt wide. Hover: 1.5 pt pencil outline. Selection: 1 pt pencil; several: dashed
[3,3] box. Handles 8 pt white squares, 1 pt pencil, shadow black 18% (blur 1.5, y 0.5); side
handles drop under 28 pt. Size pill: pencil, radius 6, 20 tall, 10 below, white 11 medium mono.
Rulers 20 pt, labels 9 medium mono.

## Tools (Views/Workspace.swift)

Select V, Artboard A, Rectangle R, Ellipse E, Line L, Pen P, Knife K, Text T, Note N. Rail buttons
38×38, radius 10, spacing 4, 6 top; selected in a well, hover ink 6%; glyphs 18 pt drawn by hand,
stroke 1.5, round ends (Glyphs.swift has the same paths). Resources and Layers at the rail's foot.

## Layers (Views/LayersPanel.swift)

Header: "Layers" 13 semibold, chevron and the artboard's name on its page, count 11.5 mono ink3 at
the right; 16 sides, 8 top, 6 bottom. Rows 28 tall, inset 8, indent 18 a level, spacing 6,
padding 4 / 6; chevron 9×9 in 14×14; kind glyph 15 (ink selected, ink3 otherwise; violet for
copies); name 12.5, medium for artboards and the selected; selected pencilWash radius 7, hover
ink 5%. Empty: dashed slot rows (28, radius 8, [3,3], ink 15%) fading downward.

## Inspector (Views/Inspector.swift, Cards.swift, SelectionInspector.swift)

Gutter 16, cards 248 wide, radius 12, spacing 8, 14 top. Folded line 40 tall, padding 9 / 8,
glyph in 22, title 12.5 semibold, summary at the right. Order: Arrange, Frame, (artboard cards),
Component, Repeat Grid, Mask, Text, Path, Corners, Opacity, Fill, Photo, Border, Shadow, Blur, 3D,
Export, then dashed add chips (28, radius 8). Summaries: Frame "W × H · X, Y", Opacity "NN%",
Fill "#HEX · NN%", Border "N pt · Inside", Text "Font · N pt", mixed "Several". Nothing selected:
the style kit, then the tools and their keys (rows 30, and "Space · Move around").

One card is open at a time, Frame to begin with (`store.openAspect = .frame`). Inside a card: 12 in
from its sides, rows 8 apart. Two fields side by side are a column each, (224 − 20) / 2, with 20
between them (where the width/height lock goes); on Windows 100, as the card's hairline takes room.
A number field (Fields.swift NumberField): 28 tall, a well of radius 7, its label inside at the
left (11 medium, ink3, 8 in, at least 12 wide), the number 12; a unit at the right (11, ink3, 7
in). Dragging it sideways scrubs (pencil wash, pencil edge at 60%, label and number in pencil);
Shift in tens; a click types; Enter sets, Esc puts back; the arrows step it, Shift by ten. Frame
opens to W·H, X·Y, ↻ (°, scrub 0.5) beside Flip (two 28 buttons, 2 apart, dimmed to 35% when
nothing would change), then for one layer on an artboard the PlacePad: the artboard in small
(fits 192 × 132) in a well of radius 10, 28 taller than it, the layer on it in pencil wash with a
pencil edge, catching on the edges and middle within 5 screen points, a pencil line showing where.
