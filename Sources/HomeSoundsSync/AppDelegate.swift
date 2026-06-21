import AppKit
import CoreAudio

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private let engine = SyncEngine()
    private let devices = AudioDevices()

    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var toggleButton: NSButton!
    private var helpButton: NSButton!
    private var helpWindow: NSWindow?
    private var languageLabel: NSTextField?
    private var languagePopup: NSPopUpButton?
    private var helpTextView: NSTextView?

    // Dynamic speaker lists (scrollable; one row per discovered device).
    private var airplayLabel: NSTextField!
    private var airplayCard: NSView!
    private var airplayScroll: NSScrollView!
    private var airplayDoc: FlippedView!
    private var airplayEmpty: NSTextField!
    private var localLabel: NSTextField!
    private var localCard: NSView!
    private var localScroll: NSScrollView!
    private var localDoc: FlippedView!

    private var airplayRows: [String: AirPlayRow] = [:]   // OwnTone output id → row
    private var localRows: [String: LocalRow] = [:]       // Core Audio device UID → row
    private var airplayOrder: [String] = []
    private var localOrder: [String] = []

    private var pollTimer: Timer?

    private let rowWidth: CGFloat = 458    // creation width; rows autoresize to the live width
    private let airplayRowH: CGFloat = 28
    private let localRowH: CGFloat = 52
    private let maxDelayMs = 20000.0
    private var defaultDelayMs = 2000.0

    // MARK: Persisted state

    private var enabledAirPlay: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabledAirPlay), forKey: Keys.enabledAirPlay) }
    }
    private var enabledLocal: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabledLocal), forKey: Keys.enabledLocal) }
    }
    private var localDelayMs: [String: Double] {
        didSet { UserDefaults.standard.set(localDelayMs, forKey: Keys.localDelay) }
    }
    private var localGain: [String: Double] {   // percent, 0…150
        didSet { UserDefaults.standard.set(localGain, forKey: Keys.localGain) }
    }
    private var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Keys.language)
            applyLanguage()
        }
    }

    private enum Keys {
        static let enabledAirPlay = "enabledAirPlayIds"
        static let enabledLocal = "enabledLocalUIDs"
        static let localDelay = "localDelayMsByUID"
        static let localGain = "localGainByUID"
        static let legacyDelay = "delayMs"   // migrate the old single global delay
        static let windowFrame = "mainWindowFrame"
        static let language = "appLanguage"
    }

    override init() {
        let d = UserDefaults.standard
        enabledAirPlay = Set((d.array(forKey: Keys.enabledAirPlay) as? [String]) ?? [])
        enabledLocal = Set((d.array(forKey: Keys.enabledLocal) as? [String]) ?? [])
        localDelayMs = (d.dictionary(forKey: Keys.localDelay) as? [String: Double]) ?? [:]
        localGain = (d.dictionary(forKey: Keys.localGain) as? [String: Double]) ?? [:]
        language = AppLanguage(defaultsValue: d.string(forKey: Keys.language))
        // Seed new rows near the user's previously tuned single-output delay,
        // clamped into the UI range so a stale legacy value can't seed out of range.
        let legacy = d.object(forKey: Keys.legacyDelay) as? Double ?? 2000
        defaultDelayMs = min(max(0, legacy), 20000)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DBG.reset()
        DBG.log("[HSS] launched")
        buildWindow()

        engine.onOutputLost = { uid in
            // Device unplugged: the renderer is already gone. Keep it enabled so it
            // re-attaches automatically when the device comes back. reconcileLocal
            // keeps every row's check state in sync with `enabledLocal`.
            DBG.log("[HSS] local output lost: \(uid) (re-attaches when device returns)")
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.engine.running,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Music" else { return }
            self.stopEngine()
            self.showAlert(self.language.text.musicTerminated)
        }

        showWindow()
        startPolling()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    // MARK: - Window

    private func buildWindow() {
        let t = language.text
        let saved = UserDefaults.standard.string(forKey: Keys.windowFrame)
        let initial = NSRect(x: 0, y: 0, width: 540, height: 600)
        let win = NSWindow(contentRect: initial,
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "HomeSounds Sync"
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.minSize = NSSize(width: 460, height: 500)

        let content = NSVisualEffectView(frame: initial)
        content.material = .windowBackground
        content.blendingMode = .behindWindow
        content.state = .active
        content.autoresizingMask = [.width, .height]

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        content.addSubview(statusLabel)

        helpButton = NSButton(title: t.settingsButton, target: self, action: #selector(showHelp(_:)))
        helpButton.bezelStyle = .rounded
        helpButton.font = .systemFont(ofSize: 12)
        content.addSubview(helpButton)

        airplayLabel = sectionLabel(t.airPlaySection)
        content.addSubview(airplayLabel)
        let (apCard, apScroll, apDoc) = makeScrollList()
        airplayCard = apCard; airplayScroll = apScroll; airplayDoc = apDoc
        content.addSubview(apCard); content.addSubview(apScroll)
        airplayEmpty = NSTextField(labelWithString: t.airPlayEmpty)
        airplayEmpty.frame = NSRect(x: 10, y: 8, width: rowWidth - 16, height: 18)
        airplayEmpty.font = .systemFont(ofSize: 11)
        airplayEmpty.textColor = .secondaryLabelColor
        airplayEmpty.autoresizingMask = [.width]
        airplayDoc.addSubview(airplayEmpty)

        localLabel = sectionLabel(t.localSection)
        content.addSubview(localLabel)
        let (lcCard, lcScroll, lcDoc) = makeScrollList()
        localCard = lcCard; localScroll = lcScroll; localDoc = lcDoc
        content.addSubview(lcCard); content.addSubview(lcScroll)

        toggleButton = NSButton(title: "", target: self, action: #selector(toggle(_:)))
        toggleButton.bezelStyle = .rounded
        toggleButton.font = .systemFont(ofSize: 13, weight: .semibold)
        toggleButton.bezelColor = .systemPurple
        toggleButton.keyEquivalent = "\r"
        content.addSubview(toggleButton)

        win.contentView = content
        window = win

        if let saved {
            let f = NSRectFromString(saved)
            if f.width >= win.minSize.width, f.height >= win.minSize.height, Self.frameIsOnScreen(f) {
                win.setFrame(f, display: false)
            } else {
                win.center()   // saved frame is off-screen (e.g. a display was unplugged)
            }
        } else {
            win.center()
        }
        layoutContent()
    }

    /// Reposition every section for the current window size. Called on build and
    /// on every resize, so the speaker lists expand to fill the whole window
    /// (hidden speakers become visible as the window grows).
    private func layoutContent() {
        guard let window, let content = window.contentView else { return }
        let b = content.bounds
        let W = b.width, H = b.height
        let M: CGFloat = 16

        let helpW: CGFloat = 66
        let toggleW: CGFloat = 74
        helpButton.frame = NSRect(x: W - M - helpW, y: H - 42, width: helpW, height: 26)
        toggleButton.frame = NSRect(x: helpButton.frame.minX - 8 - toggleW, y: H - 42, width: toggleW, height: 26)
        statusLabel.frame = NSRect(x: 24, y: H - 41, width: max(120, toggleButton.frame.minX - 36), height: 24)

        let topY = H - 52                  // top of the section stack (below status)
        let bottomY: CGFloat = 16
        let labelH: CGFloat = 16
        let gap: CGFloat = 4
        let sectionGap: CGFloat = 8
        let cardsArea = max(80, (topY - bottomY) - 2 * labelH - 2 * gap - sectionGap)

        // AirPlay takes the rows it needs, then local speakers get the rest.
        // Resizing the window vertically now directly reveals more device rows.
        let apContent = CGFloat(max(airplayRows.count, 1)) * airplayRowH + (airplayRows.isEmpty ? 24 : 4)
        let minAP: CGFloat = 44
        let minLocal: CGFloat = 96
        let apMax = max(minAP, min(cardsArea - minLocal, cardsArea * 0.42))
        let apCardH = min(max(apContent, minAP), apMax)
        let lcCardH = max(minLocal, cardsArea - apCardH)

        var y = topY
        airplayLabel.frame = NSRect(x: 28, y: y - labelH, width: W - 56, height: labelH)
        y -= labelH + gap
        airplayCard.frame = NSRect(x: M, y: y - apCardH, width: W - 2 * M, height: apCardH)
        airplayScroll.frame = airplayCard.frame.insetBy(dx: 1, dy: 1)
        y -= apCardH + sectionGap

        localLabel.frame = NSRect(x: 28, y: y - labelH, width: W - 56, height: labelH)
        y -= labelH + gap
        localCard.frame = NSRect(x: M, y: y - lcCardH, width: W - 2 * M, height: lcCardH)
        localScroll.frame = localCard.frame.insetBy(dx: 1, dy: 1)

        relayoutLists()
    }

    func windowDidResize(_ notification: Notification) {
        layoutContent()
    }

    func windowDidMove(_ notification: Notification) { saveWindowFrame() }
    func windowWillClose(_ notification: Notification) { saveWindowFrame() }

    private func saveWindowFrame() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Keys.windowFrame)
    }

    /// True if `f` overlaps a connected screen enough to be grabbable — guards
    /// against restoring a window onto a display that is no longer attached.
    private static func frameIsOnScreen(_ f: NSRect) -> Bool {
        for screen in NSScreen.screens {
            let hit = screen.visibleFrame.intersection(f)
            if hit.width > 120, hit.height > 60 { return true }
        }
        return false
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    /// A rounded "card" background + a transparent scroll view with a flipped
    /// document view that holds dynamically-added speaker rows.
    private func makeScrollList() -> (NSView, NSScrollView, FlippedView) {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.cgColor

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 10))
        scroll.documentView = doc
        return (card, scroll, doc)
    }

    private func showWindow() {
        reconcileAirPlay()
        reconcileLocal()
        updateUI()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.reconcileAirPlay()
            self?.reconcileLocal()
        }
    }

    // MARK: - List reconciliation (devices grow/shrink dynamically)

    private func reconcileAirPlay() {
        OwnToneClient.airplayOutputs { [weak self] outputs in
            guard let self else { return }
            var seen = Set<String>()
            var order: [String] = []
            for o in outputs {
                seen.insert(o.id); order.append(o.id)
                if self.airplayRows[o.id] == nil {
                    let row = self.makeAirPlayRow(id: o.id, name: o.name, volume: o.volume)
                    self.airplayRows[o.id] = row
                    self.airplayDoc.addSubview(row.container)
                }
            }
            for (id, row) in self.airplayRows where !seen.contains(id) {
                row.container.removeFromSuperview()
                self.airplayRows[id] = nil
            }
            let countChanged = self.airplayOrder.count != order.count
            self.airplayOrder = order
            self.airplayEmpty.isHidden = !order.isEmpty
            // Row count drives the AirPlay card height, so re-run the whole layout
            // when it changes; otherwise just re-place the rows.
            if countChanged { self.layoutContent() } else { self.relayoutLists() }
        }
    }

    private func reconcileLocal() {
        let available = devices.allOutputDevices().filter {
            !$0.uid.isEmpty && !$0.name.contains("HomeSoundsSync")   // hide our private aggregate
        }
        var seen = Set<String>()
        var order: [String] = []
        for d in available {
            seen.insert(d.uid); order.append(d.uid)
            if localRows[d.uid] == nil {
                let row = makeLocalRow(uid: d.uid, name: d.name)
                localRows[d.uid] = row
                localDoc.addSubview(row.container)
            }
            // Keep the checkbox honest: it always mirrors the persisted enabled set.
            localRows[d.uid]?.check.state = enabledLocal.contains(d.uid) ? .on : .off
        }
        for (uid, row) in localRows where !seen.contains(uid) {
            // Don't yank a row out from under an in-progress delay edit.
            if row.delayField.currentEditor() != nil { continue }
            row.container.removeFromSuperview()
            localRows[uid] = nil
        }
        localOrder = order
        relayoutLists()
        syncLocalOutputs(available: available)
    }

    private func relayoutLists() {
        layout(doc: airplayDoc, scroll: airplayScroll,
               containers: airplayOrder.compactMap { airplayRows[$0]?.container }, rowHeight: airplayRowH)
        layout(doc: localDoc, scroll: localScroll,
               containers: localOrder.compactMap { localRows[$0]?.container }, rowHeight: localRowH)
    }

    /// Stack rows top-down in the flipped doc, sized to the live scroll width.
    /// Row internals follow via their autoresizing masks.
    private func layout(doc: FlippedView, scroll: NSScrollView, containers: [NSView], rowHeight: CGFloat) {
        let width = max(120, scroll.contentSize.width)
        var y: CGFloat = 0
        for c in containers {
            c.frame = NSRect(x: 0, y: y, width: width, height: rowHeight)
            y += rowHeight
        }
        doc.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
    }

    // MARK: - Row builders (controls autoresize: name stretches, right-side pinned)

    private func makeAirPlayRow(id: String, name: String, volume: Int) -> AirPlayRow {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: airplayRowH))
        let check = NSButton(checkboxWithTitle: name, target: self, action: #selector(airplayCheckChanged(_:)))
        check.frame = NSRect(x: 8, y: 4, width: rowWidth - 8 - 112, height: 20)
        check.autoresizingMask = [.width]
        (check.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        check.state = enabledAirPlay.contains(id) ? .on : .off
        container.addSubview(check)
        let icon = speakerIcon(x: rowWidth - 104, y: 6)
        icon.autoresizingMask = [.minXMargin]
        container.addSubview(icon)
        let vol = NSSlider(value: Double(volume), minValue: 0, maxValue: 100,
                           target: self, action: #selector(airplayVolumeChanged(_:)))
        vol.frame = NSRect(x: rowWidth - 86, y: 4, width: 78, height: 20)
        vol.autoresizingMask = [.minXMargin]
        vol.isContinuous = true
        container.addSubview(vol)
        return AirPlayRow(id: id, container: container, check: check, volume: vol)
    }

    private func makeLocalRow(uid: String, name: String) -> LocalRow {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: localRowH))
        // Top line: enable + name … volume
        let check = NSButton(checkboxWithTitle: name, target: self, action: #selector(localCheckChanged(_:)))
        check.frame = NSRect(x: 8, y: localRowH - 24, width: rowWidth - 8 - 112, height: 20)
        check.autoresizingMask = [.width, .minYMargin]
        (check.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        check.state = enabledLocal.contains(uid) ? .on : .off
        container.addSubview(check)
        let icon = speakerIcon(x: rowWidth - 104, y: localRowH - 22)
        icon.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(icon)
        let vol = NSSlider(value: localGain[uid] ?? 100, minValue: 0, maxValue: 150,
                           target: self, action: #selector(localVolumeChanged(_:)))
        vol.frame = NSRect(x: rowWidth - 86, y: localRowH - 24, width: 78, height: 20)
        vol.autoresizingMask = [.minXMargin, .minYMargin]
        vol.isContinuous = true
        container.addSubview(vol)
        let t = language.text
        // Bottom line: delay slider + field + seconds unit
        let dl = NSTextField(labelWithString: t.delayLabel)
        dl.frame = NSRect(x: 8, y: 5, width: 36, height: 18)
        dl.font = .systemFont(ofSize: 11); dl.textColor = .secondaryLabelColor
        container.addSubview(dl)
        let ms = localDelayMs[uid] ?? defaultDelayMs
        let dSlider = NSSlider(value: ms, minValue: 0, maxValue: maxDelayMs,
                               target: self, action: #selector(localDelayChanged(_:)))
        dSlider.frame = NSRect(x: 48, y: 6, width: rowWidth - 48 - 88, height: 16)
        dSlider.autoresizingMask = [.width]
        dSlider.isContinuous = true
        container.addSubview(dSlider)
        let dField = NSTextField(frame: NSRect(x: rowWidth - 80, y: 3, width: 48, height: 20))
        dField.alignment = .right; dField.font = .systemFont(ofSize: 12)
        dField.isBezeled = true; dField.bezelStyle = .roundedBezel
        dField.isEditable = true; dField.isSelectable = true
        dField.autoresizingMask = [.minXMargin]
        dField.stringValue = String(format: "%.2f", ms / 1000.0)
        dField.target = self; dField.action = #selector(localDelayFieldChanged(_:))
        container.addSubview(dField)
        let sec = NSTextField(labelWithString: t.secondsUnit)
        sec.frame = NSRect(x: rowWidth - 28, y: 5, width: 24, height: 18)
        sec.font = .systemFont(ofSize: 11); sec.textColor = .secondaryLabelColor
        sec.autoresizingMask = [.minXMargin]
        container.addSubview(sec)
        return LocalRow(uid: uid, container: container, check: check, volume: vol,
                        delayLabel: dl, delaySlider: dSlider, delayField: dField,
                        secondsLabel: sec)
    }

    private func speakerIcon(x: CGFloat, y: CGFloat) -> NSImageView {
        let iv = NSImageView(frame: NSRect(x: x, y: y, width: 16, height: 16))
        iv.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                           accessibilityDescription: language.text.volumeAccessibility)
        iv.contentTintColor = .secondaryLabelColor
        return iv
    }

    // MARK: - Output sync (apply enabled sets to the running engine)

    /// Make the running engine's local outputs match `enabledLocal` ∩ available
    /// devices. Idempotent; safe to call on every reconcile. Pass `available` to
    /// avoid a second Core Audio enumeration when the caller already has one.
    private func syncLocalOutputs(available provided: [AudioDevices.Device]? = nil) {
        guard engine.running else { return }
        let available = provided ?? devices.allOutputDevices()
        let byUID = Dictionary(available.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        var failed: [String] = []
        for uid in enabledLocal where !engine.hasOutput(uid: uid) {
            guard let dev = byUID[uid] else { continue }   // not present yet; retry later
            do {
                try engine.addOutput(uid: uid, deviceID: dev.id,
                                     delayMs: localDelayMs[uid] ?? defaultDelayMs,
                                     gain: (localGain[uid] ?? 100) / 100.0)
            } catch {
                DBG.log("[HSS] addOutput(\(uid)) failed: \(error)")
                failed.append(uid)   // present but won't start — don't retry every tick
            }
        }
        for uid in engine.activeOutputUIDs where !enabledLocal.contains(uid) {
            engine.removeOutput(uid: uid)
        }
        if !failed.isEmpty {
            for uid in failed {
                enabledLocal.remove(uid)
                localRows[uid]?.check.state = .off
            }
            let names = failed.compactMap { byUID[$0]?.name }.joined(separator: ", ")
            showAlert(language.text.outputStartFailed(names: names))
        }
    }

    private func applyAirPlaySelection() {
        for id in airplayOrder { OwnToneClient.setSelected(id: id, on: enabledAirPlay.contains(id)) }
    }

    // MARK: - Actions: AirPlay rows

    @objc private func airplayCheckChanged(_ sender: NSButton) {
        guard let row = airplayRows.values.first(where: { $0.check === sender }) else { return }
        if sender.state == .on { enabledAirPlay.insert(row.id) } else { enabledAirPlay.remove(row.id) }
        OwnToneClient.setSelected(id: row.id, on: sender.state == .on)
    }

    @objc private func airplayVolumeChanged(_ sender: NSSlider) {
        guard let row = airplayRows.values.first(where: { $0.volume === sender }) else { return }
        OwnToneClient.setVolume(id: row.id, volume: Int(sender.doubleValue.rounded()))
    }

    // MARK: - Actions: local rows

    @objc private func localCheckChanged(_ sender: NSButton) {
        guard let row = localRows.values.first(where: { $0.check === sender }) else { return }
        if sender.state == .on { enabledLocal.insert(row.uid) } else { enabledLocal.remove(row.uid) }
        if engine.running {
            syncLocalOutputs()
        } else if sender.state == .on {
            showAlert(language.text.startAfterTurnOn)
        }
    }

    @objc private func localVolumeChanged(_ sender: NSSlider) {
        guard let row = localRows.values.first(where: { $0.volume === sender }) else { return }
        localGain[row.uid] = sender.doubleValue
        engine.setGain(uid: row.uid, g: sender.doubleValue / 100.0)
    }

    @objc private func localDelayChanged(_ sender: NSSlider) {
        guard let row = localRows.values.first(where: { $0.delaySlider === sender }) else { return }
        applyLocalDelay(uid: row.uid, ms: sender.doubleValue, row: row, syncSlider: false)
    }

    @objc private func localDelayFieldChanged(_ sender: NSTextField) {
        guard let row = localRows.values.first(where: { $0.delayField === sender }) else { return }
        applyLocalDelay(uid: row.uid, ms: sender.doubleValue * 1000.0, row: row, syncSlider: true)
    }

    private func applyLocalDelay(uid: String, ms rawMs: Double, row: LocalRow, syncSlider: Bool) {
        let ms = max(0, min(maxDelayMs, rawMs))
        localDelayMs[uid] = ms
        engine.setDelay(uid: uid, ms: ms)
        if syncSlider { row.delaySlider.doubleValue = ms }
        row.delayField.stringValue = String(format: "%.2f", ms / 1000.0)
    }

    // MARK: - Master engine control

    @objc private func toggle(_ sender: NSButton) {
        if engine.running { stopEngine() } else { startEngine() }
    }

    private func startEngine() {
        guard !enabledAirPlay.isEmpty || !enabledLocal.isEmpty else {
            showAlert(language.text.chooseSpeakerBeforeStart)
            return
        }
        do {
            try engine.start()
        } catch {
            showAlert(language.text.startError(error))
            return
        }
        applyAirPlaySelection()
        syncLocalOutputs()
        verifyAudioFlowing()
        updateUI()
    }

    private func stopEngine() {
        engine.stop()
        for id in airplayOrder { OwnToneClient.setSelected(id: id, on: false) }
        updateUI()
    }

    private func verifyAudioFlowing() {
        let before = engine.framesCaptured
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.engine.running, self.engine.framesCaptured == before else { return }
            self.showAlert(self.language.text.captureNotWorking)
        }
    }

    private func updateUI() {
        let t = language.text
        statusLabel.stringValue = engine.running ? t.statusOn : t.statusOff
        statusLabel.textColor = engine.running ? .systemGreen : .secondaryLabelColor
        toggleButton.title = engine.running ? t.turnOff : t.turnOn
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "HomeSounds Sync"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: language.text.alertOK)
        alert.runModal()
    }

    // MARK: - Help / usage window

    @objc private func showHelp(_ sender: NSButton) {
        if helpWindow == nil { helpWindow = makeHelpWindow() }
        updateSettingsUI()
        helpWindow?.center()
        helpWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeHelpWindow() -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 520, height: 560)
        let w = NSWindow(contentRect: frame,
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = language.text.settingsTitle
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 420, height: 320)

        let root = NSView(frame: frame)
        root.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: language.text.languageLabel)
        label.frame = NSRect(x: 18, y: frame.height - 42, width: 92, height: 20)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.autoresizingMask = [.minYMargin]
        root.addSubview(label)
        languageLabel = label

        let popup = NSPopUpButton(frame: NSRect(x: 110, y: frame.height - 47, width: 140, height: 28),
                                  pullsDown: false)
        for option in AppLanguage.allCases {
            popup.addItem(withTitle: option.displayName)
            popup.lastItem?.representedObject = option.rawValue
        }
        popup.target = self
        popup.action = #selector(languageChanged(_:))
        popup.autoresizingMask = [.minYMargin]
        root.addSubview(popup)
        languagePopup = popup

        let divider = NSBox(frame: NSRect(x: 0, y: frame.height - 58, width: frame.width, height: 1))
        divider.boxType = .separator
        divider.autoresizingMask = [.width, .minYMargin]
        root.addSubview(divider)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height - 58))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height - 58))
        text.autoresizingMask = [.width]
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 18, height: 18)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: frame.width - 36, height: .greatestFiniteMagnitude)
        text.font = .systemFont(ofSize: 13)
        scroll.documentView = text
        root.addSubview(scroll)
        helpTextView = text

        w.contentView = root
        updateSettingsUI()
        return w
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let selected = AppLanguage(rawValue: rawValue),
              selected != language else { return }
        language = selected
    }

    private func applyLanguage() {
        guard window != nil else { return }
        let t = language.text
        helpButton.title = t.settingsButton
        airplayLabel.stringValue = t.airPlaySection
        airplayEmpty.stringValue = t.airPlayEmpty
        localLabel.stringValue = t.localSection
        for row in localRows.values {
            row.delayLabel.stringValue = t.delayLabel
            row.secondsLabel.stringValue = t.secondsUnit
        }
        updateUI()
        updateSettingsUI()
        layoutContent()
    }

    private func updateSettingsUI() {
        let t = language.text
        helpWindow?.title = t.settingsTitle
        languageLabel?.stringValue = t.languageLabel
        languagePopup?.selectItem(withTitle: language.displayName)
        if let helpTextView {
            helpTextView.string = t.helpText
            helpTextView.sizeToFit()
        }
    }
}

// MARK: - Row models / flipped container

/// Top-anchored container so rows stack downward in the scroll view.
final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class AirPlayRow {
    let id: String
    let container: NSView
    let check: NSButton
    let volume: NSSlider
    init(id: String, container: NSView, check: NSButton, volume: NSSlider) {
        self.id = id; self.container = container; self.check = check; self.volume = volume
    }
}

final class LocalRow {
    let uid: String
    let container: NSView
    let check: NSButton
    let volume: NSSlider
    let delayLabel: NSTextField
    let delaySlider: NSSlider
    let delayField: NSTextField
    let secondsLabel: NSTextField
    init(uid: String, container: NSView, check: NSButton, volume: NSSlider,
         delayLabel: NSTextField, delaySlider: NSSlider, delayField: NSTextField,
         secondsLabel: NSTextField) {
        self.uid = uid; self.container = container; self.check = check; self.volume = volume
        self.delayLabel = delayLabel; self.delaySlider = delaySlider
        self.delayField = delayField; self.secondsLabel = secondsLabel
    }
}
