#!/bin/zsh
# Copies the shared files that need one line changed to build here. They are made, never edited:
# Blurs.swift imports Core Image's filter submodule, which a Swift package cannot declare.
cd "${0:A:h}"
out=Sources/BezzleCore/Shared/Generated
mkdir -p $out
sed '/^import CoreImage.CIFilterBuiltins/d' ../Bezzle/Canvas/Blurs.swift > $out/Blurs.swift
# From BoardTiles.swift only how far layers reach, which the renderer asks; its tiles are the canvas's.
awk '/^nonisolated extension Renderer \{/{p=1} p' ../Bezzle/Canvas/BoardTiles.swift > $out/Reach.swift
# From Library.swift only the artboard sizes, which Adapt tells interfaces from compositions by.
awk '/^struct Preset:/{p=1} p{print} p&&/^}$/{exit}' ../Bezzle/Store/Library.swift > $out/Preset.swift
# DesignTokens.swift without its CGFloat overload of `number`, which here is the Double one: CGFloat is Double.
grep -v '^    static func number(_ x: CGFloat, _ places: Int = 2) -> String { number(Double(x), places) }$' ../Bezzle/Model/DesignTokens.swift > $out/DesignTokens.swift
