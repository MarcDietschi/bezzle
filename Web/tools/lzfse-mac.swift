// Packs or unpacks with Apple's own LZFSE (NSData.compressed/decompressed), as the app does, to
// check the browser's LZFSE against it.   swift tools/lzfse-mac.swift pack|unpack <in> <out>
import Foundation
let a = CommandLine.arguments
let input = try Data(contentsOf: URL(fileURLWithPath: a[2]))
let out = a[1] == "pack" ? try (input as NSData).compressed(using: .lzfse) as Data : try (input as NSData).decompressed(using: .lzfse) as Data
try out.write(to: URL(fileURLWithPath: a[3]))
