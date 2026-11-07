import Foundation
import WinUI
import BezzleCore

/// The Mask card, as the Mac's (Views/MaskCard.swift): a mask selected shows the kind of shape
/// that holds, with Release beside it; a layer in a mask shows which, with Take Out. Pulled off
/// (its ×), the mask is taken apart, or the layer comes out of it.
extension Inspector {
    func maskCard(_ ids: [UUID], board: Int) -> UIElement? {
        guard let m = WindowsCore.maskCard(ids), !m.locked else { return nil }
        let release: @MainActor () -> Void = { [self] in
            if m.isMask, let mask = ids.first {
                let freed = WindowsCore.releaseMask(mask)
                session.select(freed, on: board)
            } else {
                WindowsCore.takeOutOfMask(ids)
                session.select(ids, on: board)
            }
            session.edited(board: board)
        }
        let button = ExportSheet.textButton(m.isMask ? "Release" : "Take Out", release) as? FrameworkElement
        return card("Mask", m.summary, mark: Glyphs.mask(brush: Theme.ink(2)), remove: release,
                    removal: m.isMask ? "Release mask" : "Take out of mask", accessory: button)
    }
}
