import Foundation

/// The prototype changed (see `FlowLink`): where layers go, what is said of it, and a screen
/// going on by itself. Shared by every Bezzle; the Mac's store calls these
/// (Store/PrototypeOperations.swift), as does Windows.
extension BezzleDocument {
    /// Sends layers to a screen, or back, or nowhere (nil, not back): each, or the copy of a
    /// component it lies in. What else their flows say, their notes and motion, stays.
    mutating func linkFlow(_ ids: [UUID], to board: UUID?, back: Bool = false) {
        for id in ids.compactMap({ linkable($0) }) {
            update(id) { n in
                // A screen doesn't go to itself.
                if n.isArtboard, board == n.id, !back { return }
                var f = n.flow ?? FlowLink()
                f.to = back ? nil : board
                f.back = back ? true : nil
                if !f.leads { f.note = nil; f.motion = nil }
                n.flow = f.leads || f.after != nil ? f : nil
            }
        }
    }

    /// What is said of where layers go, written on their threads; nothing for none.
    mutating func setFlowNote(_ note: String?, for ids: [UUID]) {
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = note?.isEmpty == false ? note : nil
        for id in ids {
            update(id) { n in
                guard var f = n.flow, f.leads else { return }
                f.note = clean
                n.flow = f
            }
        }
    }

    /// How layers' screens come on; Auto as the canvas has it.
    mutating func setFlowMotion(_ motion: FlowMotion, for ids: [UUID]) {
        for id in ids {
            update(id) { n in
                guard var f = n.flow, f.leads else { return }
                f.motion = motion == .auto ? nil : motion
                n.flow = f
            }
        }
    }

    /// A screen goes on by itself after `seconds`, to where its own flow leads; nil stops it.
    mutating func setGoesOn(after seconds: Double?, board: UUID) {
        update(board) { n in
            var f = n.flow ?? FlowLink()
            f.after = seconds.map { max(0.1, ($0 * 10).rounded() / 10) }
            n.flow = f.leads || f.after != nil ? f : nil
        }
    }
}
