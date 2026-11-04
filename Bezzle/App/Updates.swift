import AppKit
import SwiftUI

/// Updates for the copy of Bezzle that comes from the website. The Mac App Store updates its own
/// copy, so the App Store build has no updater at all: only a build made with `BEZZLE_DIRECT`
/// (Scripts/release.sh) has this code. The script puts Sparkle into that copy's
/// Contents/Frameworks, and the feed, the key and the sandbox's installer service into its
/// Info.plist. Sparkle is loaded when Bezzle starts rather than linked, so the project needs no
/// package for it and the App Store build carries no trace of it.
///
/// Every launch looks for a new version in the background, and Sparkle once a day after that. A new
/// version is downloaded quietly and put in place when Bezzle quits (`SUAutomaticallyUpdate`).
enum Updates {
    /// Whether this copy updates itself: a website build with Sparkle inside.
    static var isAvailable: Bool {
        #if BEZZLE_DIRECT
        sparkle != nil
        #else
        false
        #endif
    }

    /// Starts the updater, once. Called when Bezzle has finished launching.
    static func start() {
        #if BEZZLE_DIRECT
        guard controller == nil, let sparkle else { return }
        let started = sparkle.init(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = started
        // Sparkle's own schedule looks once a day; this looks on every launch too.
        let updater = started.updater
        if updater.value(forKey: "automaticallyChecksForUpdates") as? Bool == true {
            updater.perform(NSSelectorFromString("checkForUpdatesInBackground"))
        }
        #endif
    }

    /// Bezzle › Check for Updates…: Sparkle's window, with what it finds.
    static func check() {
        #if BEZZLE_DIRECT
        start()
        controller?.checkForUpdates(nil)
        #endif
    }

    #if BEZZLE_DIRECT
    /// Sparkle's controller class, from the framework the release script put inside the app.
    private static let sparkle: SparkleUpdaterController.Type? = {
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("Sparkle.framework"),
              let bundle = Bundle(url: url), bundle.load(),
              let type = NSClassFromString("SPUStandardUpdaterController") else { return nil }
        return unsafeBitCast(type, to: SparkleUpdaterController.Type.self)
    }()

    private static var controller: SparkleUpdaterController?
    #endif
}

#if BEZZLE_DIRECT
/// The part of Sparkle's `SPUStandardUpdaterController` that Bezzle calls. Sparkle is not linked, so
/// its class is found by name and reached through this protocol, which it does not adopt: an
/// Objective-C protocol only names selectors, and the class answers to these.
@objc private protocol SparkleUpdaterController: NSObjectProtocol {
    init(startingUpdater: Bool, updaterDelegate: AnyObject?, userDriverDelegate: AnyObject?)
    var updater: NSObject { get }
    func checkForUpdates(_ sender: Any?)
}
#endif

/// Check for Updates… under About Bezzle, in the website's copy only. Outside `BEZZLE_DIRECT` so
/// that its title stays in the string catalog whichever build Xcode extracts it from.
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if Updates.isAvailable {
                Button("Check for Updates…") { Updates.check() }
            }
        }
    }
}
