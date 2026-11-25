import AppKit

// Einstiegspunkt der Menüleisten-App.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // kein Dock-Symbol, kein Fenster
app.run()
