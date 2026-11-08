import Foundation
import WinSDK
import BezzleCore

/// The welcome tour (BezzleCore's `Welcome`, made as the Mac's Store/Welcome.swift makes it), as
/// the Mac brings it: made and opened the first time Bezzle starts with no designs, and only that
/// once, not again after it is thrown away nor for someone who had designs already; and a fresh
/// copy whenever the Bezzle menu's Welcome to Bezzle is chosen.
///
/// A copy kept to a folder of its own (BEZZLE_DESIGNS_FOLDER, BEZZLE_DESIGNS, BEZZLE_LIBRARY) is
/// never given it by itself, as the Mac's tests are not. For trying: BEZZLE_WELCOME=1 makes a
/// fresh copy and opens it, as on the Mac; BEZZLE_FIRST_LAUNCH=1 asks as a first start does,
/// whether or not it was made before, so an empty folder gets it and one with designs does not.
@MainActor
enum WelcomeTour {
    private static let madeKey = "welcomeMade"

    /// As Bezzle starts, with its tabs ready.
    static func start() {
        let env = ProcessInfo.processInfo.environment
        if env["BEZZLE_WELCOME"] != nil {
            open()
        } else {
            makeOnFirstLaunch(trying: env["BEZZLE_FIRST_LAUNCH"] != nil)
        }
    }

    private static func makeOnFirstLaunch(trying: Bool) {
        if !trying {
            let env = ProcessInfo.processInfo.environment
            let isolated = ["BEZZLE_DESIGNS_FOLDER", "BEZZLE_DESIGNS", "BEZZLE_LIBRARY"].contains { !(env[$0] ?? "").isEmpty }
            let settings = UserDefaults.standard
            guard !isolated, !settings.bool(forKey: madeKey) else { return }
            settings.set(true, forKey: madeKey)
        }
        let folder = BezzleApp.designsFolder
        let there = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard !there.contains(where: { $0.pathExtension.lowercased() == "bezzle" }) else { return }
        open()
    }

    /// A fresh copy of the tour, in the designs folder, opened in a tab of its own.
    static func open() {
        let folder = BezzleApp.designsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let url = Welcome.make(in: folder) else {
            MessageBeep(0)
            return
        }
        Tabs.shared.open(url)
    }
}
