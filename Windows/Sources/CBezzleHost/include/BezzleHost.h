// What Bezzle's core asks of Windows, done with Skia (host.cpp): what the browser's page does for
// the WebAssembly core (Web/site/bezzle.mjs), call for call, so designs draw and measure alike.
// Path operations and pictures by name go through bz_host_call as in the browser, with the same
// numbers and bytes; text and pictures, which the browser passes as JSON, are given here as
// structs by Swift (Host/WindowsHost.swift); drawings are the core's recorded commands
// (Web/Platform/CGContext.swift).
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Does `function` (1 path operation, 2 picture by name, 4 log) with `count` bytes; keeps the
/// answer and returns its length, for bz_host_take.
int32_t bz_host_call(int32_t function, const void *bytes, int32_t count);
/// Copies the last answer into `into`, which holds its length.
void bz_host_take(void *into);

// MARK: Fonts and text

/// Adds a font face, by family and face as the core names them ("System" for the system font,
/// with an empty face). Returns 0 if Skia cannot read it.
int32_t bz_font_add(const char *family, const char *face, const void *data, int32_t count);

typedef struct bz_text_run {
    const char *text;           // UTF-8
    const char *family;
    const char *face;
    double size;
    double tracking;            // letter spacing, in points
    double weight;              // for "System": its wght axis, else 0
    double opticalSize;         // for "System": its opsz axis, 0 for none
    int32_t underline;
    int32_t strike;
    int32_t hasColor;           // without a colour the letters are not painted (a fill paints them)
    double color[4];            // r, g, b, a
    const char *features;       // OpenType features as "liga=0,ss01=1", or null
    const char *axes;           // variable font axes as "wght=500,wdth=90", or null
} bz_text_run;

/// Sets `count` runs `width` wide, aligned 0 left, 1 center, 2 right, 3 justified. Returns the
/// text's id and writes, for up to `capacity` lines, six numbers each to `lines`: its start and
/// end (UTF-16), width, ascent and descent (less half the leading, as Skia shares it out) and the
/// font's leading; `*lineCount` is how many lines there are.
int32_t bz_text_lay(const bz_text_run *runs, int32_t count, double width, int32_t align,
                    double *lines, int32_t capacity, int32_t *lineCount);
/// Where the core puts each line's baseline, from the text's top.
void bz_text_place(int32_t id, const double *baselines, int32_t count);
/// Where some letters of a text set by `bz_text_lay` are (`start` to `end`, UTF-16): for each
/// line they are on, up to `capacity`, three numbers to `boxes`: the line's number and where
/// the letters begin and end along it. Returns how many lines they are on.
int32_t bz_text_boxes(int32_t id, int32_t start, int32_t end, double *boxes, int32_t capacity);
/// Sets `count` runs as one line, for a text laid along a curve, its letters drawn one by one
/// (drawing call 13, by the line's id and a letter's place in it). Returns the line's id and
/// writes, for up to `capacity` letters, ten numbers each to `glyphs`: the run it is of, where
/// it is along the line, where it is from the baseline (y down), its advance, its font's ascent
/// and descent, where its underline is (below the baseline) and how thick, and its font's x height
/// and cap height. `*glyphCount` is how many letters there are, and `line` gets four numbers:
/// the line's width, ascent and descent, and the first letter's cap height.
int32_t bz_text_glyphs(const bz_text_run *runs, int32_t count, double *glyphs, int32_t capacity,
                       int32_t *glyphCount, double *line);
/// Forgets every text set, as when fonts were added.
void bz_text_forget(void);

// MARK: Spelling (spelling.cpp)

/// The languages Windows checks spelling in, as tags separated by commas ("en-US,de-CH"), UTF-8
/// to `out`. Returns how many bytes the list takes.
int32_t bz_spell_languages(char *out, int32_t capacity);
/// The misspelt words of `count` UTF-16 units of `text`, checked in `language`: for up to
/// `capacity` words, where each begins and how long it is, to `ranges`. Returns how many there
/// are, or -1 when Windows cannot check that language.
int32_t bz_spell_check(const char *language, const uint16_t *text, int32_t count, int32_t *ranges, int32_t capacity);
/// How a word might be spelt, likeliest first, one a line, UTF-8 to `out`. Returns how many
/// bytes they take.
int32_t bz_spell_guesses(const char *language, const uint16_t *word, int32_t count, char *out, int32_t capacity);
/// Adds a word to the dictionary of the person signed in.
void bz_spell_learn(const char *language, const uint16_t *word, int32_t count);

// MARK: Pictures

/// How big a picture file's picture is, in pixels, upright as its orientation turns it; 0 if
/// Skia cannot read it.
int32_t bz_image_size(const void *data, int32_t count, int32_t *width, int32_t *height);
/// Adds one of a design's pictures by name, as its encoded bytes. Returns its asset number, 0
/// if Skia cannot read it.
int32_t bz_asset_add(const char *name, const void *data, int32_t count);
/// The pictures a drawing made, by the core's numbers (CGImage.Source).
void bz_picture_asset(int32_t id, int32_t asset);
void bz_picture_recording(int32_t id, int32_t width, int32_t height, const double *commands, int64_t count);
/// `crop` is x, y, width, height (width 0 for none); `blur` below 0 for none; `perspective` a
/// 3×3 matrix row by row, or null.
void bz_picture_changed(int32_t id, int32_t width, int32_t height, int32_t from,
                        const double *crop, double blur, int32_t clamp, const double *perspective);
void bz_picture_pixels(int32_t id, int32_t width, int32_t height, int32_t bytesPerRow, const uint8_t *bytes);
/// The changed picture `id`'s blur grows along a ramp instead: none at `ends` 0, 1 growing to
/// the whole blur at `ends` 2, 3, in the source's pixels from its top left.
void bz_picture_ramp(int32_t id, const double *ends);
/// A picture made by bz_picture_changed is a photo developed as the Mac develops it: haze away
/// (above nought) or over, then each colour through `cube` (`size` steps a side, red fastest, three
/// floats each; none when null), then clarity, texture and sharpness. `amounts`: dehaze, clarity,
/// texture, sharpness, as the Mac's kernels take them.
void bz_picture_develop(int32_t id, const float *cube, int32_t size, const double *amounts);

/// Makes picture `id` and writes its premultiplied pixels, RGBA (or BGRA with `bgra`), rows top
/// first, to `pixels`, which holds `width` × `height` × 4 bytes. Returns 0 when done.
int32_t bz_picture_read(int32_t id, int32_t width, int32_t height, int32_t bgra, void *pixels);
/// Forgets picture `id` and what was made of it: the core holds it no more.
void bz_picture_forget(int32_t id);
/// The shadow an artboard casts on the canvas: a `width` by `height` rectangle `dy` down, blurred
/// by `blur` (Core Graphics' measure: twice the sigma), in `rgb` at `alpha`, drawn into premultiplied
/// BGRA pixels `pad` larger on every side. Returns 0 when done.
int32_t bz_shadow(int32_t width, int32_t height, int32_t pad, double blur, double dy, uint32_t rgb, double alpha, void *pixels);
/// Home's table: `table` in a rectangle of radius 20 (points, at `scale` pixels each), a pool of
/// `light` at `strength` round (`x`, `y`) (fractions of the width and height) out to `reach` of the
/// diagonal, and black at `shade` towards the bottom; into BGRA pixels. Returns 0 when done.
int32_t bz_stage(int32_t width, int32_t height, double scale, uint32_t table, uint32_t light, double strength,
                 double x, double y, double reach, double shade, void *pixels);
/// Unpacks raw DEFLATE (RFC 1951, as Apple's COMPRESSION_ZLIB writes it, the icon library's
/// packing): keeps the bytes and returns their length, for bz_host_take; -1 if they cannot be.
int32_t bz_inflate(const void *bytes, int32_t count);
/// Writes pixels as bz_picture_read makes them to a PNG file at `path` (UTF-8). Returns 0 when done.
int32_t bz_png_write(const char *path, int32_t width, int32_t height, const void *pixels);
/// Writes premultiplied RGBA pixels as a picture file: `format` 0 PNG, 1 JPEG, 2 WebP (lossless at
/// a quality of 1), `quality` 0…1. Returns 0 when written.
int32_t bz_image_write(const char *path, int32_t width, int32_t height, const void *pixels, int32_t format, double quality);
/// A PDF: begun at a path (0 if it cannot be), given pages, each a recorded picture the core made
/// at `scale` pixels a point and `width` by `height` points, and ended, which writes it.
int32_t bz_pdf_begin(const char *path);
int32_t bz_pdf_page(int32_t pdf, int32_t picture, double width, double height, double scale);
int32_t bz_pdf_end(int32_t pdf);

#ifdef __cplusplus
}
#endif
