import AppKit
import SMCCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: Einstellungen

    enum Key {
        static let interval = "interval"
        static let showCPU = "showCPU"
        static let showGPU = "showGPU"
        static let showFan = "showFan"
        static let showPower = "showPower"
        static let labeled = "labeled"
        static let warnColor = "warnColor"
    }

    /// Ab dieser Temperatur wird die Menüleisten-Schrift rot.
    private let warnThreshold: Double = 85

    // MARK: Zustand

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var snapshot = Snapshot()
    private let defaults = UserDefaults.standard

    // MARK: Lebenszyklus

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            Key.interval: 2.0,
            Key.showCPU: true,
            Key.showGPU: true,
            Key.showFan: true,
            Key.showPower: false,
            Key.labeled: true,
            Key.warnColor: true,
        ])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                           weight: .regular)
            button.title = "FanStats"
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        refresh()
        restartTimer()

        // Sensor-Suche läuft im Hintergrund, sie kostet ein paar hundert Millisekunden.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            Machine.shared.discoverSensors()
            DispatchQueue.main.async { self?.refresh() }
        }

        // Diagnose: FANSTATS_DUMP_MENU=1 ./FanStats  ->  Menübaum ausgeben und beenden.
        if ProcessInfo.processInfo.environment["FANSTATS_DUMP_MENU"] != nil {
            Machine.shared.discoverSensors()
            snapshot = Machine.shared.snapshot()
            let probe = NSMenu()
            build(probe)
            dump(probe, indent: 0)
            exit(0)
        }
    }

    /// Gibt den Menübaum als Text aus. Prüft, dass das Menü überhaupt baut und
    /// dass Einträge mit Untermenü aktiviert sind (sonst klappen sie nicht auf).
    private func dump(_ menu: NSMenu, indent: Int) {
        let prefix = String(repeating: "  ", count: indent)
        for item in menu.items {
            if item.isSeparatorItem {
                print(prefix + "---")
                continue
            }
            var flags: [String] = []
            if !item.isEnabled && item.action == nil && item.submenu == nil { flags.append("deaktiviert") }
            if item.state == .on { flags.append("an") }
            if item.submenu != nil { flags.append("Untermenü") }
            print(prefix + item.title + (flags.isEmpty ? "" : "   [" + flags.joined(separator: ", ") + "]"))
            if let sub = item.submenu { dump(sub, indent: indent + 1) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    // MARK: Aktualisierung

    private func restartTimer() {
        timer?.invalidate()
        let interval = max(0.5, defaults.double(forKey: Key.interval))
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)   // läuft auch bei offenem Menü weiter
        timer = t
    }

    @objc private func refresh() {
        snapshot = Machine.shared.snapshot()
        updateStatusItem()
    }

    private var isHot: Bool {
        (snapshot.cpu ?? 0) >= warnThreshold || (snapshot.gpu ?? 0) >= warnThreshold
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let text = statusTitle()

        if defaults.bool(forKey: Key.warnColor) && isHot {
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                        weight: .medium),
                .foregroundColor: NSColor.systemRed,
            ])
        } else {
            button.title = text
        }
        button.toolTip = tooltip()

        // Diagnose: FANSTATS_LOG=1 ./FanStats  ->  Werte auf stderr ausgeben
        if ProcessInfo.processInfo.environment["FANSTATS_LOG"] != nil {
            let visible = statusItem.isVisible && button.window != nil
            let fans = snapshot.fans.map { rpm($0.actual) }.joined(separator: ", ")
            let sensorCount = snapshot.groups.reduce(0) { $0 + $1.readings.count }
            var line = "[FanStats] statusItem=\(visible ? "sichtbar" : "NICHT sichtbar")"
            line += " | Titel: \"\(text)\""
            line += " | CPU \(temp(snapshot.cpu))"
            line += " | GPU \(temp(snapshot.gpu))"
            line += " | Lüfter \(fans)"
            line += " | Sensoren \(sensorCount)\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
    }

    private func statusTitle() -> String {
        var parts: [String] = []
        let labeled = defaults.bool(forKey: Key.labeled)

        if defaults.bool(forKey: Key.showCPU), let t = snapshot.cpu {
            parts.append(labeled ? "C \(deg(t))" : deg(t))
        }
        if defaults.bool(forKey: Key.showGPU), let t = snapshot.gpu {
            parts.append(labeled ? "G \(deg(t))" : deg(t))
        }
        if defaults.bool(forKey: Key.showFan), let rpm = snapshot.maxFanRPM {
            parts.append(labeled ? "\(Int(rpm.rounded())) rpm" : "\(Int(rpm.rounded()))")
        }
        if defaults.bool(forKey: Key.showPower),
           let w = snapshot.cpuPower ?? snapshot.systemPower {
            parts.append(labeled ? "\(Int(w.rounded())) W" : "\(Int(w.rounded()))")
        }
        return parts.isEmpty ? "FanStats" : parts.joined(separator: "  ")
    }

    private func tooltip() -> String {
        var lines = ["\(Machine.shared.modelName) (\(Machine.shared.modelIdentifier))"]
        if let c = snapshot.cpu { lines.append("CPU: \(temp(c))") }
        if let g = snapshot.gpu { lines.append("GPU: \(temp(g))") }
        for fan in snapshot.fans {
            lines.append("\(fan.name): \(fan.actual.map { "\(Int($0.rounded())) rpm" } ?? "–")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Formatierung

    private func deg(_ v: Double) -> String { "\(Int(v.rounded()))°" }

    private func num(_ v: Double, _ decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", v).replacingOccurrences(of: ".", with: ",")
    }

    private func temp(_ v: Double?) -> String {
        v.map { "\(num($0)) °C" } ?? "–"
    }

    private func rpm(_ v: Double?) -> String {
        v.map { "\(Int($0.rounded())) rpm" } ?? "–"
    }

    // MARK: Menü

    func menuNeedsUpdate(_ menu: NSMenu) {
        snapshot = Machine.shared.snapshot()
        updateStatusItem()
        build(menu)
    }

    private func info(_ title: String, indent: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(noop(_:)), keyEquivalent: "")
        item.target = self
        item.indentationLevel = indent
        return item
    }

    /// Eintrag, der ein Untermenü trägt. Muss eine Aktion haben, sonst öffnet
    /// AppKit das Untermenü nicht (deaktivierte Einträge klappen nicht auf).
    private func submenuHeader(_ title: String, indent: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(noop(_:)), keyEquivalent: "")
        item.target = self
        item.indentationLevel = indent
        return item
    }

    private func header(_ title: String, indent: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = indent
        return item
    }

    private func check(_ title: String, on: Bool, setting: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(toggleDisplay(_:)), keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        item.representedObject = setting
        return item
    }

    private func build(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(header(Machine.shared.displayName))

        guard Machine.shared.smcAvailable else {
            menu.addItem(info("AppleSMC nicht erreichbar"))
            menu.addItem(info("Dieses Tool liest die Sensoren über den AppleSMC-Treiber."))
            menu.addItem(info("Unterstützt Intel- und Apple-Silicon-Macs."))
            menu.addItem(.separator())
            addFooter(menu)
            return
        }

        menu.addItem(.separator())

        // --- Temperaturen ---
        // Intel: PECI-Schnittstelle, Apple Silicon: CPU-Die.
        let cpuLabel = Machine.shared.isIntel ? "CPU (PECI)" : "CPU (Die)"
        let cpuItem = info("\(cpuLabel):   \(temp(snapshot.cpu))")
        if !snapshot.cpuCores.isEmpty || snapshot.cpuProximity != nil {
            let sub = NSMenu()
            if let p = snapshot.cpuProximity { sub.addItem(info("CPU Proximity (TC0P):   \(temp(p))")) }
            if !snapshot.cpuCores.isEmpty { sub.addItem(.separator()) }
            for core in snapshot.cpuCores {
                sub.addItem(info("\(core.key):   \(temp(core.celsius))"))
            }
            cpuItem.submenu = sub
        }
        menu.addItem(cpuItem)

        let gpuItem = info("GPU (Die/Hotspot):   \(temp(snapshot.gpu))")
        if !snapshot.gpuSensors.isEmpty || snapshot.gpuProximity != nil {
            let sub = NSMenu()
            for s in snapshot.gpuSensors { sub.addItem(info("\(s.key):   \(temp(s.celsius))")) }
            if let p = snapshot.gpuProximity {
                sub.addItem(.separator())
                sub.addItem(info("GPU Proximity:   \(temp(p))"))
            }
            gpuItem.submenu = sub
        }
        menu.addItem(gpuItem)

        if let w = snapshot.cpuPower {
            var text = "Leistung:   CPU \(num(w, 1)) W"
            if let g = snapshot.gpuPower { text += "   ·   GPU \(num(g, 1)) W" }
            menu.addItem(info(text))
        } else if let p = snapshot.systemPower {
            // Apple Silicon: nur die Gesamtleistung des Rechners (PSTR).
            menu.addItem(info("Leistung:   System \(num(p, 1)) W"))
        }

        menu.addItem(.separator())

        // --- Lüfter ---
        if snapshot.fans.isEmpty {
            menu.addItem(info("Keine Lüfter gefunden (FNum = 0)"))
        }
        for fan in snapshot.fans {
            var text = "\(fan.name):   \(rpm(fan.actual))"
            if let load = fan.load {
                text += "   (\(Int((load * 100).rounded())) %)"
            }
            let item = info(text)
            let sub = NSMenu()
            sub.addItem(info("Modus:   \((fan.mode ?? 0) == 0 ? "automatisch" : "manuell")"))
            if let t = fan.target { sub.addItem(info("Ziel (F\(fan.index)Tg):   \(rpm(t))")) }
            if let lo = fan.minRPM, let hi = fan.maxRPM {
                sub.addItem(info("Bereich:   \(Int(lo.rounded())) … \(Int(hi.rounded())) rpm"))
            }
            if let d = fan.duty { sub.addItem(info("PWM (F\(fan.index)Dc):   \(num(d * 100, 1)) %")) }
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        addDisplays(menu)
        menu.addItem(.separator())
        addControls(menu)
        menu.addItem(.separator())
        addSensorMenu(menu)
        menu.addItem(.separator())
        addFooter(menu)
    }

    /// Zeigt für jeden Bildschirm, ob er nativ oder skaliert läuft.
    ///
    /// Das ist für die Lüfterfrage zentral: ein skalierter Modus zwingt die GPU,
    /// einen größeren Framebuffer zu rendern und herunterzurechnen. Gleiche
    /// Bildschirmzahl, gleiche Optik - aber deutlich mehr Leistungsaufnahme.
    private func addDisplays(_ menu: NSMenu) {
        let displays = Diagnostics.displays()
        guard !displays.isEmpty else { return }

        let total = displays.reduce(0) { $0 + $1.megapixels }
        let scaled = displays.filter(\.isDownscaled).count
        let title = "Bildschirme: \(displays.count), \(num(total, 1)) MP Framebuffer"
            + (scaled > 0 ? "  ⚠︎" : "")
        let item = submenuHeader(title)
        let sub = NSMenu()

        for (i, d) in displays.enumerated() {
            let role = (d.isMain ? "Haupt" : "neben") + ", " + (d.isBuiltin ? "intern" : "extern")
            let entry = submenuHeader("\(i + 1). \(role): \(d.logicalWidth)×\(d.logicalHeight)")
            let detail = NSMenu()
            detail.addItem(info("Framebuffer: \(d.pixelWidth)×\(d.pixelHeight)"
                                + "  (\(num(d.megapixels, 1)) MP)"))
            if d.nativeMegapixels > 0 {
                detail.addItem(info("Panel nativ: \(d.nativePixelWidth)×\(d.nativePixelHeight)"
                                    + "  (\(num(d.nativeMegapixels, 1)) MP)"))
            }
            detail.addItem(info("Skalierung: Faktor \(num(d.scale, 2))"))
            detail.addItem(info("Modus: \(d.modeText)"))
            if d.refreshRate > 0 {
                detail.addItem(info("Bildrate: \(Int(d.refreshRate.rounded())) Hz"))
            }
            entry.submenu = detail
            sub.addItem(entry)
        }

        sub.addItem(.separator())
        if scaled > 0 {
            sub.addItem(info("\(scaled) Bildschirm(e) werden heruntergerechnet:"))
            sub.addItem(info("die GPU rendert mehr Pixel als das Panel hat."))
            sub.addItem(info("Native Auflösung spart GPU-Leistung und Wärme."))
        } else {
            sub.addItem(info("Kein Bildschirm wird heruntergerechnet."))
        }
        item.submenu = sub
        menu.addItem(item)
    }

    private func addControls(_ menu: NSMenu) {
        let refreshItem = NSMenuItem(title: "Jetzt aktualisieren",
                                     action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let intervalItem = submenuHeader("Aktualisierung")
        let intervalMenu = NSMenu()
        let current = defaults.double(forKey: Key.interval)
        for seconds in [1.0, 2.0, 5.0, 10.0, 30.0] {
            let item = NSMenuItem(title: "\(Int(seconds)) s",
                                  action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(seconds)
            item.state = abs(current - seconds) < 0.01 ? .on : .off
            intervalMenu.addItem(item)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        let displayItem = submenuHeader("In der Menüleiste zeigen")
        let displayMenu = NSMenu()
        displayMenu.addItem(check("CPU-Temperatur", on: defaults.bool(forKey: Key.showCPU),
                                  setting: Key.showCPU))
        displayMenu.addItem(check("GPU-Temperatur", on: defaults.bool(forKey: Key.showGPU),
                                  setting: Key.showGPU))
        displayMenu.addItem(check("Lüfter-Drehzahl", on: defaults.bool(forKey: Key.showFan),
                                  setting: Key.showFan))
        displayMenu.addItem(check("CPU-Leistung", on: defaults.bool(forKey: Key.showPower),
                                  setting: Key.showPower))
        displayMenu.addItem(.separator())
        displayMenu.addItem(check("Beschriftung (C / G)", on: defaults.bool(forKey: Key.labeled),
                                  setting: Key.labeled))
        displayMenu.addItem(check("Rot ab \(Int(warnThreshold)) °C",
                                  on: defaults.bool(forKey: Key.warnColor),
                                  setting: Key.warnColor))
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)
    }

    private func addSensorMenu(_ menu: NSMenu) {
        let count = snapshot.groups.reduce(0) { $0 + $1.readings.count }
        let item = submenuHeader("Alle Sensoren (\(count))")
        let sub = NSMenu()
        if snapshot.groups.isEmpty {
            sub.addItem(info("Sensor-Suche läuft noch …"))
        }
        for group in snapshot.groups {
            let groupItem = submenuHeader("\(group.name) (\(group.readings.count))")
            let groupMenu = NSMenu()
            for r in group.readings {
                groupMenu.addItem(info("\(r.key):   \(temp(r.celsius))"))
            }
            groupItem.submenu = groupMenu
            sub.addItem(groupItem)
        }
        item.submenu = sub
        menu.addItem(item)
    }

    private func addFooter(_ menu: NSMenu) {
        let about = NSMenuItem(title: "Über FanStats", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "FanStats beenden", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: Aktionen

    @objc private func noop(_ sender: Any?) {}

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        updateStatusItem()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        defaults.set(Double(sender.tag), forKey: Key.interval)
        restartTimer()
        refresh()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "FanStats"
        alert.informativeText = """
            \(Machine.shared.displayName)
            \(Machine.shared.cpuName)
            \(Machine.shared.architectureName)

            SMC-Keys: \(Machine.shared.smcKeyCount)
            Lüfter: \(snapshot.fans.count)
            Temperatursensoren: \(snapshot.groups.reduce(0) { $0 + $1.readings.count })

            Liest Werte direkt über den AppleSMC-Userclient (IOKit).
            Aktuell nur Anzeige – keine Lüftersteuerung.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
