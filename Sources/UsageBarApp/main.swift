import AppKit
import UsageBarCore

// Menu bar app: no Dock icon, no main window. `.accessory` is the runtime half;
// LSUIElement in the bundle's Info.plist is the other half (see
// Scripts/make-app-bundle.sh).
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
