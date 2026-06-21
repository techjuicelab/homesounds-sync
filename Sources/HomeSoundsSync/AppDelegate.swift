import AppKit
import CoreAudio

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let engine = SyncEngine()
    private let devices = AudioDevices()

    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var toggleButton: NSButton!

    // Dynamic speaker lists (scrollable; one row per discovered device).
    private var airplayScroll: NSScrollView!
    private var airplayDoc: FlippedView!
    private var airplayEmpty: NSTextField!
    private var localScroll: NSScrollView!
    private var localDoc: FlippedView!

    private var airplayRows: [String: AirPlayRow] = [:]   // OwnTone output id → row
    private var localRows: [String: LocalRow] = [:]       // Core Audio device UID → row
    private var airplayOrder: [String] = []

    private var pollTimer: Timer?

    private let rowWidth: CGFloat = 458
    private let airplayRowH: CGFloat = 32
    private let localRowH: CGFloat = 60
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

    private enum Keys {
        static let enabledAirPlay = "enabledAirPlayIds"
        static let enabledLocal = "enabledLocalUIDs"
        static let localDelay = "localDelayMsByUID"
        static let localGain = "localGainByUID"
        static let legacyDelay = "delayMs"   // migrate the old single global delay
    }

    override init() {
        let d = UserDefaults.standard
        enabledAirPlay = Set((d.array(forKey: Keys.enabledAirPlay) as? [String]) ?? [])
        enabledLocal = Set((d.array(forKey: Keys.enabledLocal) as? [String]) ?? [])
        localDelayMs = (d.dictionary(forKey: Keys.localDelay) as? [String: Double]) ?? [:]
        localGain = (d.dictionary(forKey: Keys.localGain) as? [String: Double]) ?? [:]
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
            // re-attaches automatically when the device comes back. We do NOT touch
            // the checkbox here — reconcileLocal keeps every row's check state in
            // sync with `enabledLocal`, so the box can never lie about audio state.
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
            self.showAlert("Apple Music이 종료되어 동기화를 멈췄습니다.")
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
        let frame = NSRect(x: 0, y: 0, width: 520, height: 560)
        let win = NSWindow(contentRect: frame,
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "HomeSounds Sync"
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.center()

        let content = NSVisualEffectView(frame: frame)
        content.material = .windowBackground
        content.blendingMode = .behindWindow
        content.state = .active

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 24, y: 522, width: 472, height: 26)
        statusLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        content.addSubview(statusLabel)

        // ── AirPlay speakers (dynamic) ────────────────────
        content.addSubview(sectionLabel("AirPlay 스피커 (HomePod·Apple TV) — 여러 대 동시", y: 502))
        let (apCard, apScroll, apDoc) = scrollList(cardFrame: NSRect(x: 20, y: 400, width: 480, height: 98))
        content.addSubview(apCard); content.addSubview(apScroll)
        airplayScroll = apScroll; airplayDoc = apDoc
        airplayEmpty = NSTextField(labelWithString: "OwnTone 미실행 또는 발견된 AirPlay 기기 없음")
        airplayEmpty.frame = NSRect(x: 10, y: 8, width: rowWidth - 16, height: 18)
        airplayEmpty.font = .systemFont(ofSize: 11)
        airplayEmpty.textColor = .secondaryLabelColor
        airplayDoc.addSubview(airplayEmpty)

        // ── Local (wired/USB) speakers (dynamic) ──────────
        content.addSubview(sectionLabel("로컬 스피커 (이 Mac) — 각자 지연 조절, 여러 대 동시", y: 380))
        let (lcCard, lcScroll, lcDoc) = scrollList(cardFrame: NSRect(x: 20, y: 210, width: 480, height: 162))
        content.addSubview(lcCard); content.addSubview(lcScroll)
        localScroll = lcScroll; localDoc = lcDoc

        // ── Master toggle ─────────────────────────────────
        toggleButton = NSButton(frame: NSRect(x: 20, y: 150, width: 480, height: 44))
        toggleButton.bezelStyle = .rounded
        toggleButton.font = .systemFont(ofSize: 15, weight: .semibold)
        toggleButton.bezelColor = .systemPurple
        toggleButton.target = self
        toggleButton.action = #selector(toggle(_:))
        toggleButton.keyEquivalent = "\r"
        content.addSubview(toggleButton)

        let hint = NSTextField(wrappingLabelWithString:
            "• Apple Music 출력은 Computer로 두세요 — HomePod은 위 목록에서 켭니다(OwnTone가 담당).\n" +
            "• 보낼 스피커를 체크하면 늘어납니다. 로컬 스피커는 각 행의 ‘지연’으로 맞추세요.\n" +
            "• EDIFIER가 먼저 들리면 지연 ↑, HomePod이 먼저면 지연 ↓. AirPlay 여러 대는 서로 자동 동기화.")
        hint.frame = NSRect(x: 24, y: 18, width: 472, height: 112)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)

        win.contentView = content
        window = win
    }

    private func sectionLabel(_ text: String, y: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.frame = NSRect(x: 28, y: y, width: 470, height: 14)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    /// A rounded "card" background + a transparent scroll view with a flipped
    /// document view that holds dynamically-added speaker rows.
    private func scrollList(cardFrame: NSRect) -> (NSView, NSScrollView, FlippedView) {
        let card = NSView(frame: cardFrame)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.cgColor

        let scroll = NSScrollView(frame: cardFrame.insetBy(dx: 1, dy: 1))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: cardFrame.height - 2))
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
            self.airplayOrder = order
            self.airplayEmpty.isHidden = !order.isEmpty
            self.layout(doc: self.airplayDoc, scroll: self.airplayScroll,
                        containers: order.compactMap { self.airplayRows[$0]?.container },
                        rowHeight: self.airplayRowH)
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
            // Keep the checkbox honest: it always mirrors the persisted enabled set,
            // so it can never read OFF while the speaker is actually playing.
            localRows[d.uid]?.check.state = enabledLocal.contains(d.uid) ? .on : .off
        }
        for (uid, row) in localRows where !seen.contains(uid) {
            // Don't yank a row out from under an in-progress delay edit (it would
            // discard the uncommitted value); drop it on a later pass instead.
            if row.delayField.currentEditor() != nil { continue }
            row.container.removeFromSuperview()
            localRows[uid] = nil
        }
        layout(doc: localDoc, scroll: localScroll,
               containers: order.compactMap { localRows[$0]?.container },
               rowHeight: localRowH)
        syncLocalOutputs(available: available)
    }

    private func layout(doc: FlippedView, scroll: NSScrollView, containers: [NSView], rowHeight: CGFloat) {
        var y: CGFloat = airplayEmpty != nil && doc === airplayDoc && containers.isEmpty ? 26 : 0
        for c in containers {
            c.frame = NSRect(x: 0, y: y, width: rowWidth, height: rowHeight)
            y += rowHeight
        }
        let minH = scroll.contentSize.height
        doc.frame = NSRect(x: 0, y: 0, width: rowWidth, height: max(y, minH))
    }

    // MARK: - Row builders

    private func makeAirPlayRow(id: String, name: String, volume: Int) -> AirPlayRow {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: airplayRowH))
        let check = NSButton(checkboxWithTitle: name, target: self, action: #selector(airplayCheckChanged(_:)))
        check.frame = NSRect(x: 8, y: 6, width: rowWidth - 8 - 128, height: 20)
        (check.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        check.state = enabledAirPlay.contains(id) ? .on : .off
        container.addSubview(check)
        container.addSubview(speakerIcon(x: rowWidth - 122, y: 8))
        let vol = NSSlider(value: Double(volume), minValue: 0, maxValue: 100,
                           target: self, action: #selector(airplayVolumeChanged(_:)))
        vol.frame = NSRect(x: rowWidth - 104, y: 6, width: 96, height: 20)
        vol.isContinuous = true
        container.addSubview(vol)
        return AirPlayRow(id: id, container: container, check: check, volume: vol)
    }

    private func makeLocalRow(uid: String, name: String) -> LocalRow {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: localRowH))
        // Top line: enable + name … volume
        let check = NSButton(checkboxWithTitle: name, target: self, action: #selector(localCheckChanged(_:)))
        check.frame = NSRect(x: 8, y: localRowH - 26, width: rowWidth - 8 - 128, height: 20)
        (check.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        check.state = enabledLocal.contains(uid) ? .on : .off
        container.addSubview(check)
        container.addSubview(speakerIcon(x: rowWidth - 122, y: localRowH - 24))
        let vol = NSSlider(value: localGain[uid] ?? 100, minValue: 0, maxValue: 150,
                           target: self, action: #selector(localVolumeChanged(_:)))
        vol.frame = NSRect(x: rowWidth - 104, y: localRowH - 26, width: 96, height: 20)
        vol.isContinuous = true
        container.addSubview(vol)
        // Bottom line: 지연 slider + field + 초
        let dl = NSTextField(labelWithString: "지연")
        dl.frame = NSRect(x: 8, y: 8, width: 28, height: 18)
        dl.font = .systemFont(ofSize: 11); dl.textColor = .secondaryLabelColor
        container.addSubview(dl)
        let ms = localDelayMs[uid] ?? defaultDelayMs
        let dSlider = NSSlider(value: ms, minValue: 0, maxValue: maxDelayMs,
                               target: self, action: #selector(localDelayChanged(_:)))
        dSlider.frame = NSRect(x: 40, y: 9, width: rowWidth - 40 - 96, height: 16)
        dSlider.isContinuous = true
        container.addSubview(dSlider)
        let dField = NSTextField(frame: NSRect(x: rowWidth - 88, y: 6, width: 52, height: 20))
        dField.alignment = .right; dField.font = .systemFont(ofSize: 12)
        dField.isBezeled = true; dField.bezelStyle = .roundedBezel
        dField.isEditable = true; dField.isSelectable = true
        dField.stringValue = String(format: "%.2f", ms / 1000.0)
        dField.target = self; dField.action = #selector(localDelayFieldChanged(_:))
        container.addSubview(dField)
        let sec = NSTextField(labelWithString: "초")
        sec.frame = NSRect(x: rowWidth - 30, y: 8, width: 18, height: 18)
        sec.font = .systemFont(ofSize: 11); sec.textColor = .secondaryLabelColor
        container.addSubview(sec)
        return LocalRow(uid: uid, container: container, check: check, volume: vol,
                        delaySlider: dSlider, delayField: dField)
    }

    private func speakerIcon(x: CGFloat, y: CGFloat) -> NSImageView {
        let iv = NSImageView(frame: NSRect(x: x, y: y, width: 16, height: 16))
        iv.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "볼륨")
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
        // A device that is present but fails to start (busy/exclusive/format) would
        // otherwise be retried every 3 s forever. Disable it and tell the user once.
        if !failed.isEmpty {
            for uid in failed {
                enabledLocal.remove(uid)
                localRows[uid]?.check.state = .off
            }
            let names = failed.compactMap { byUID[$0]?.name }.joined(separator: ", ")
            showAlert("이 스피커로 출력을 시작할 수 없어 해제했습니다: \(names.isEmpty ? "(알 수 없는 장치)" : names)\n다른 앱이 독점 사용 중이거나 포맷이 맞지 않을 수 있습니다.")
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
            showAlert("‘켜기’를 누르면 선택한 스피커로 재생을 시작합니다.")
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
            showAlert("보낼 스피커를 한 개 이상 체크한 뒤 켜기를 누르세요.\n(AirPlay 또는 로컬 목록에서 선택)")
            return
        }
        do {
            try engine.start()
        } catch {
            showAlert("\(error)")
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
            self.showAlert("오디오가 캡처되지 않고 있습니다.\n시스템 설정 → 개인정보 보호 및 보안 → 시스템 오디오 녹음에서 권한을 허용한 뒤, Apple Music을 재생하세요. 권한을 방금 허용했다면 끄기 후 다시 켜기를 눌러 주세요.")
        }
    }

    private func updateUI() {
        statusLabel.stringValue = engine.running ? "● 동기화 켜짐" : "○ 동기화 꺼짐"
        statusLabel.textColor = engine.running ? .systemGreen : .secondaryLabelColor
        toggleButton.title = engine.running ? "끄기" : "켜기"
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "HomeSounds Sync"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
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
    let delaySlider: NSSlider
    let delayField: NSTextField
    init(uid: String, container: NSView, check: NSButton, volume: NSSlider,
         delaySlider: NSSlider, delayField: NSTextField) {
        self.uid = uid; self.container = container; self.check = check; self.volume = volume
        self.delaySlider = delaySlider; self.delayField = delayField
    }
}
