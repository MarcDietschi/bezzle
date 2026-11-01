libwebp 1.6.0, from https://github.com/webmproject/libwebp (tag v1.6.0), for writing WebP files: ImageIO reads WebP but does not write it.

Only what the library itself is made of is here: `src/dec`, `src/enc`, `src/dsp`, `src/utils`, `src/webp` and `sharpyuv`, the `.c` and `.h` files only, without the MIPS and MSA ones. The linker keeps only what the encoder uses. `BezzleWebP.c` and `include/BezzleWebP.h` are Bezzle's own: the one function Swift calls (see `Bezzle/Export/WebPWriter.swift`).

To update, copy the same folders from a newer release over these, leaving out `*mips*` and `*msa*`, and build. The licence is in COPYING (BSD) and PATENTS, and Bezzle's Credits.rtf repeats it.
