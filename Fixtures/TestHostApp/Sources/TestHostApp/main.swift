import AppKit

final class AppController: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)

    // --- type / status / count ---
    let nameField = NSTextField(frame: NSRect(x: 20, y: 410, width: 200, height: 24))
    let statusLabel = NSTextField(labelWithString: "status: ")
    let countLabel = NSTextField(labelWithString: "count: 0")
    var count = 0

    // --- double-click counter ---
    let dblLabel = NSTextField(labelWithString: "dbl: 0")
    var dblCount = 0

    // --- menu flag ---
    var flagOn = false
    let flagItem = NSMenuItem(title: "Toggle Flag", action: #selector(toggleFlag), keyEquivalent: "")

    // --- slider (drag test) ---
    // NSSlider 0–100, starts at 0; drag moves the thumb
    let sliderValueLabel = NSTextField(labelWithString: "slider: 0")

    func applicationDidFinishLaunching(_ note: Notification) {
        window.title = "TestHostApp"
        let content = NSView(frame: window.contentView!.bounds)

        // ── nameField ────────────────────────────────────────────────────────
        nameField.setAccessibilityIdentifier("nameField")
        nameField.target = self
        nameField.action = #selector(nameChanged)
        nameField.delegate = self
        content.addSubview(nameField)

        // ── statusLabel ──────────────────────────────────────────────────────
        statusLabel.frame = NSRect(x: 20, y: 382, width: 440, height: 22)
        statusLabel.setAccessibilityIdentifier("statusLabel")
        content.addSubview(statusLabel)

        // ── countLabel ───────────────────────────────────────────────────────
        countLabel.frame = NSRect(x: 20, y: 356, width: 200, height: 20)
        countLabel.setAccessibilityIdentifier("countLabel")
        content.addSubview(countLabel)

        // ── dblLabel ─────────────────────────────────────────────────────────
        dblLabel.frame = NSRect(x: 240, y: 356, width: 200, height: 20)
        dblLabel.setAccessibilityIdentifier("dblLabel")
        content.addSubview(dblLabel)

        // ── okButton ─────────────────────────────────────────────────────────
        let okButton = NSButton(title: "OK", target: self, action: #selector(okTapped))
        okButton.frame = NSRect(x: 20, y: 316, width: 80, height: 28)
        okButton.setAccessibilityIdentifier("okButton")
        content.addSubview(okButton)

        // ── dblButton (custom double-click view acting as AX button) ────────
        let dblButton = DoubleClickButton(label: "DblClick", controller: self)
        dblButton.frame = NSRect(x: 120, y: 316, width: 90, height: 28)
        dblButton.setAccessibilityIdentifier("dblButton")
        dblButton.setAccessibilityElement(true)
        dblButton.setAccessibilityRole(.button)
        dblButton.setAccessibilityLabel("DblClick")
        content.addSubview(dblButton)

        // ── flagCheckbox ─────────────────────────────────────────────────────
        let check = NSButton(checkboxWithTitle: "Flag", target: nil, action: nil)
        check.frame = NSRect(x: 230, y: 316, width: 120, height: 28)
        check.setAccessibilityIdentifier("flagCheckbox")
        content.addSubview(check)

        // ── colorSwatch — solid #3478F6 = sRGB(52,120,246) ──────────────────
        let swatch = NSView(frame: NSRect(x: 370, y: 296, width: 80, height: 80))
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = NSColor(srgbRed: 52/255, green: 120/255, blue: 246/255, alpha: 1).cgColor
        swatch.setAccessibilityIdentifier("colorSwatch")
        swatch.setAccessibilityElement(true)
        swatch.setAccessibilityRole(.group)
        content.addSubview(swatch)

        // ── searchField ──────────────────────────────────────────────────────
        let search = NSSearchField(frame: NSRect(x: 20, y: 280, width: 200, height: 24))
        search.setAccessibilityIdentifier("searchField")
        content.addSubview(search)
        DispatchQueue.main.async { self.window.makeFirstResponder(search) }

        // ── scroll view ──────────────────────────────────────────────────────
        // Contains 10 numbered labels; "scroll-end" is at the bottom (hidden initially).
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 160, width: 220, height: 100))
        scrollView.setAccessibilityIdentifier("scrollView")
        scrollView.hasVerticalScroller = true
        let tallContent = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: 300))
        for i in 0..<10 {
            let lbl = NSTextField(labelWithString: i == 9 ? "scroll-end" : "item-\(i)")
            lbl.frame = NSRect(x: 4, y: 4 + i * 28, width: 200, height: 22)
            lbl.setAccessibilityIdentifier(i == 9 ? "scroll-end" : "item-\(i)")
            tallContent.addSubview(lbl)
        }
        scrollView.documentView = tallContent
        content.addSubview(scrollView)

        // ── slider (drag test) ───────────────────────────────────────────────
        // A 200pt wide slider 0–100, starting at 0.
        // Dragging the thumb right raises its value; we read it back as a float string.
        let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: self, action: #selector(sliderMoved(_:)))
        slider.frame = NSRect(x: 20, y: 120, width: 200, height: 22)
        slider.setAccessibilityIdentifier("slider")
        content.addSubview(slider)

        sliderValueLabel.frame = NSRect(x: 232, y: 120, width: 200, height: 22)
        sliderValueLabel.setAccessibilityIdentifier("sliderValueLabel")
        content.addSubview(sliderValueLabel)

        // ── right-click target ────────────────────────────────────────────────
        let rightClickBox = RightClickBox(statusLabel: statusLabel)
        rightClickBox.frame = NSRect(x: 20, y: 76, width: 140, height: 32)
        rightClickBox.wantsLayer = true
        rightClickBox.layer?.backgroundColor = NSColor.systemPurple.cgColor
        rightClickBox.setAccessibilityIdentifier("rightClickTarget")
        rightClickBox.setAccessibilityElement(true)
        rightClickBox.setAccessibilityRole(.group)
        rightClickBox.setAccessibilityLabel("rightClickTarget")
        content.addSubview(rightClickBox)

        // ── rightClick label (shows which context item was chosen) ────────────
        let rcLabel = NSTextField(labelWithString: "rc: none")
        rcLabel.frame = NSRect(x: 172, y: 82, width: 200, height: 22)
        rcLabel.setAccessibilityIdentifier("rcLabel")
        rightClickBox.rcLabel = rcLabel
        content.addSubview(rcLabel)

        // ── result label for various actions (drag outcome, etc.) ─────────────
        let resultLabel = NSTextField(labelWithString: "result: idle")
        resultLabel.frame = NSRect(x: 20, y: 40, width: 300, height: 22)
        resultLabel.setAccessibilityIdentifier("resultLabel")
        content.addSubview(resultLabel)

        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        installMenu()
    }

    func installMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        flagItem.target = self
        viewMenu.addItem(flagItem)
        viewItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    @objc func toggleFlag() {
        flagOn.toggle()
        flagItem.state = flagOn ? .on : .off
        statusLabel.stringValue = "status: flag=\(flagOn)"
    }

    @objc func nameChanged() {
        statusLabel.stringValue = "status: \(nameField.stringValue)"
    }

    func controlTextDidChange(_ obj: Notification) {
        statusLabel.stringValue = "status: \(nameField.stringValue)"
    }

    @objc func okTapped() {
        count += 1
        countLabel.stringValue = "count: \(count)"
    }

    func doubleClickFired() {
        dblCount += 1
        dblLabel.stringValue = "dbl: \(dblCount)"
    }

    @objc func sliderMoved(_ sender: NSSlider) {
        sliderValueLabel.stringValue = "slider: \(Int(sender.doubleValue))"
    }
}

// MARK: - DoubleClickButton

/// NSView that fires a double-click callback and exposes AX as a button.
final class DoubleClickButton: NSView {
    private let label: String
    private weak var controller: AppController?

    init(label: String, controller: AppController) {
        self.label = label
        self.controller = controller
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: NSRect) {
        NSColor.systemBlue.setFill()
        rect.fill()
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white,
                                                     .font: NSFont.systemFont(ofSize: 12)]
        NSAttributedString(string: label, attributes: attrs).draw(at: NSPoint(x: 6, y: 7))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { controller?.doubleClickFired() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - RightClickBox

/// Purple view that shows a context menu on right-click; selection updates rcLabel.
final class RightClickBox: NSView {
    weak var rcLabel: NSTextField?
    private weak var statusLabel: NSTextField?

    init(statusLabel: NSTextField) {
        self.statusLabel = statusLabel
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu(title: "Context")
        let item = NSMenuItem(title: "ContextAction", action: #selector(contextAction), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc func contextAction() {
        rcLabel?.stringValue = "rc: tapped"
        statusLabel?.stringValue = "status: context-tapped"
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
