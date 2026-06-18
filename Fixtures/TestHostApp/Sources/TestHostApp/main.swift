import AppKit

final class AppController: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let nameField = NSTextField(frame: NSRect(x: 20, y: 150, width: 200, height: 24))
    let statusLabel = NSTextField(labelWithString: "status: ")
    let countLabel = NSTextField(labelWithString: "count: 0")
    var count = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        window.title = "TestHostApp"
        let content = NSView(frame: window.contentView!.bounds)

        nameField.setAccessibilityIdentifier("nameField")
        nameField.target = self
        nameField.action = #selector(nameChanged)
        nameField.delegate = self   // live updates on every keystroke
        content.addSubview(nameField)

        statusLabel.frame = NSRect(x: 20, y: 110, width: 320, height: 20)
        statusLabel.setAccessibilityIdentifier("statusLabel")
        content.addSubview(statusLabel)

        countLabel.frame = NSRect(x: 20, y: 80, width: 320, height: 20)
        countLabel.setAccessibilityIdentifier("countLabel")
        content.addSubview(countLabel)

        let okButton = NSButton(title: "OK", target: self, action: #selector(okTapped))
        okButton.frame = NSRect(x: 20, y: 30, width: 80, height: 28)
        okButton.setAccessibilityIdentifier("okButton")
        content.addSubview(okButton)

        // A checkbox so tests can read a numeric (NSNumber) AXValue via `value`.
        let check = NSButton(checkboxWithTitle: "Flag", target: nil, action: nil)
        check.frame = NSRect(x: 120, y: 30, width: 120, height: 28)
        check.setAccessibilityIdentifier("flagCheckbox")
        content.addSubview(check)

        // A solid-color swatch with a known RGB, for visual-assertion tests
        // (assertPixel / assertRegion / snapshot). #3478F6 = (52,120,246).
        let swatch = NSView(frame: NSRect(x: 250, y: 60, width: 60, height: 60))
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = NSColor(srgbRed: 52/255, green: 120/255, blue: 246/255, alpha: 1).cgColor
        swatch.setAccessibilityIdentifier("colorSwatch")
        swatch.setAccessibilityElement(true)
        swatch.setAccessibilityRole(.group)
        content.addSubview(swatch)

        // An NSSearchField — its editing happens in a child field editor, so it
        // exercises the keycode-based `type` path (unicode-string events fail here).
        let search = NSSearchField(frame: NSRect(x: 20, y: 0, width: 200, height: 24))
        search.setAccessibilityIdentifier("searchField")
        content.addSubview(search)
        // Make it first responder so focus:false typing targets it directly.
        DispatchQueue.main.async { self.window.makeFirstResponder(search) }

        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        installMenu()
    }

    // A "View" menu with a checkable "Toggle Flag" item (no key equivalent), so
    // GUI tests can exercise the `menu` action and read the checkmark state.
    var flagOn = false
    let flagItem = NSMenuItem(title: "Toggle Flag", action: #selector(toggleFlag), keyEquivalent: "")

    func installMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

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

    // Live update on every keystroke so GUI tests can observe derived state
    // without needing the field to commit (Enter / focus-loss).
    func controlTextDidChange(_ obj: Notification) {
        statusLabel.stringValue = "status: \(nameField.stringValue)"
    }

    @objc func okTapped() {
        count += 1
        countLabel.stringValue = "count: \(count)"
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
