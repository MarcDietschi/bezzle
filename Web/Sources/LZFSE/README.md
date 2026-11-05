LZFSE 1.0, Apple's reference implementation (https://github.com/lzfse/lzfse, tag lzfse-1.0, BSD
3-clause, see LICENSE): the sources of `src/` but `lzfse_main.c`, unchanged but for `(void)` in
the two `scratch_size` declarations: WebAssembly's compiler refuses C functions declared without
a prototype. Shared designs are stored in iCloud packed with `NSData.compressed(using: .lzfse)`,
which writes this format; the browser reads and writes them with it.
