import AppKit

// MARK: - Custom views

/// A solid-color swatch that draws its fill in -drawRect: (not only via a
/// backing layer) so the rendered pixels are reliably captured by screen
/// snapshots / pixel sampling. Exposed as an AX group with a stable identifier.
final class ColorSwatchView: NSView {
    let fill: NSColor
    init(frame: NSRect, color: NSColor) {
        self.fill = color
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
    }
    override var isFlipped: Bool { true }
}

/// NSProgressIndicator whose AX value reads as the literal string the plan
/// expects ("0.5", "1.0") rather than a percentage or a coerced double, so the
/// `value equals/greaterThan/lessThan` assertions compare cleanly.
final class APProgressIndicator: NSProgressIndicator {
    // Report the raw fraction (0.5, 1.0) as the AX value. The default
    // NSProgressIndicator AX value can format as a percentage; this forces the
    // exact representation the plan asserts ("0.5", "1.0"). A double NSNumber of
    // 1.0 is not identity-equal to the cached integer 1, so the reader's numeric
    // coercion emits "1.0", not "1".
    override func accessibilityValue() -> NSNumber? { NSNumber(value: doubleValue) }
    override func isAccessibilityElement() -> Bool { true }
}

// MARK: - App

final class AppController: NSObject, NSApplicationDelegate, NSTextFieldDelegate,
                           NSTableViewDataSource, NSTableViewDelegate {

    // Two-column layout sized so every control is fully on-screen without
    // scrolling the window (the plan only scrolls the inner scrollView). Coord
    // clicks miss off-screen pixels, so everything the plan clicks must be visible.
    let contentWidth: CGFloat = 900
    let contentHeight: CGFloat = 720

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered, defer: false)

    // State
    var count = 0
    var dblCount = 0
    var lastDblClick: Date?
    var flagOn = false

    // Elements
    let nameField = NSTextField()
    let statusLabel = NSTextField(labelWithString: "status: ")
    let countLabel = NSTextField(labelWithString: "count: 0")
    let dblLabel = NSTextField(labelWithString: "dbl: 0")
    let okButton = NSButton(title: "OK", target: nil, action: nil)
    let dblButton = NSButton(title: "Double Tap", target: nil, action: nil)
    let flagCheckbox = NSButton(checkboxWithTitle: "Flag", target: nil, action: nil)
    let colorSwatch = ColorSwatchView(
        frame: NSRect(x: 0, y: 0, width: 60, height: 60),
        color: NSColor(srgbRed: 52/255, green: 120/255, blue: 246/255, alpha: 1))
    // A plain editable NSTextField (not NSSearchField): when first responder it
    // reliably reports AXFocused==true on the element carrying the identifier and
    // mirrors typed text into its AXValue, which the plan asserts.
    let searchField = NSTextField()

    let innerScroll = NSScrollView()
    let slider = NSSlider()
    let sliderValueLabel = NSTextField(labelWithString: "slider: 0")
    let rightClickTarget = NSView()
    let modeSegment = NSSegmentedControl(labels: ["Alpha", "Beta", "Gamma"],
                                         trackingMode: .selectOne, target: nil, action: nil)
    let segmentLabel = NSTextField(labelWithString: "segment: 0")
    let colorPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let pickerLabel = NSTextField(labelWithString: "pick: Red")
    let quantityStepper = NSStepper()
    let quantityLabel = NSTextField(labelWithString: "qty: 0")
    let uploadProgress = APProgressIndicator()
    let advanceButton = NSButton(title: "Advance", target: nil, action: nil)
    let notesView = FocusableTextView()
    let notesScroll = NSScrollView()
    let termsLink = NSButton(title: "Terms & Conditions", target: nil, action: nil)
    let fileTable = NSTableView()
    let fileScroll = NSScrollView()
    let tableSelLabel = NSTextField(labelWithString: "table-sel: none")
    let alertButton = NSButton(title: "Show Alert", target: nil, action: nil)
    let lockedButton = NSButton(title: "Locked", target: nil, action: nil)
    let disabledLabel = NSTextField(labelWithString: "locked: true")

    let fileItems = ["document.pdf", "photo.jpg", "notes.txt"]
    let flagItem = NSMenuItem(title: "Toggle Flag", action: #selector(toggleFlag), keyEquivalent: "")

    // Helper: configure a label so its AX value mirrors its string.
    func makeLabel(_ field: NSTextField, id: String, value: String) {
        field.stringValue = value
        field.setAccessibilityIdentifier(id)
        field.setAccessibilityValue(value)
    }
    func setLabel(_ field: NSTextField, _ value: String) {
        field.stringValue = value
        field.setAccessibilityValue(value)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        window.title = "TestHostApp"
        installMenu()
        buildUI()
        // Pin the window to the screen's visible top-left rather than centering.
        // A centered 900x720 window can have its right column / lower controls
        // pushed off the usable area on a small or unusual display (e.g. a
        // headless CI framebuffer) — a coordinate click then lands off-screen
        // and the control's action never fires (the synthesized click "posts"
        // but hits nothing). Anchoring top-left keeps the whole window, both
        // columns included, on-screen regardless of display geometry.
        if let vf = NSScreen.main?.visibleFrame {
            // Top-left of the visible frame (AppKit y grows upward, so the
            // window's bottom-left y = top - height).
            let origin = NSPoint(x: vf.minX, y: vf.maxY - window.frame.height)
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Make the search field first responder so `assert-search-focused`
        // sees focused==true before any search typing happens.
        DispatchQueue.main.async { self.window.makeFirstResponder(self.searchField) }
    }

    // MARK: UI construction (absolute frames inside a tall scrollable doc view)

    func buildUI() {
        // A flipped (top-left origin) content view holding absolute frames in two
        // columns. Everything is on-screen at the window's natural size so the
        // CLI's coordinate clicks land on real, visible pixels.
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight))
        root.wantsLayer = true

        let leftX: CGFloat = 20
        let rightX: CGFloat = 470
        var ly: CGFloat = 16     // running y for the left column
        var ry: CGFloat = 16     // running y for the right column

        // ---- Left column ----

        // 1 nameField
        nameField.setAccessibilityIdentifier("nameField")
        nameField.placeholderString = "Name"
        nameField.isEditable = true
        nameField.isBordered = true
        nameField.delegate = self
        nameField.frame = NSRect(x: leftX, y: ly, width: 300, height: 24); root.addSubview(nameField); ly += 34

        // 2 statusLabel
        makeLabel(statusLabel, id: "statusLabel", value: "status: ")
        statusLabel.frame = NSRect(x: leftX, y: ly, width: 420, height: 20); root.addSubview(statusLabel); ly += 28

        // 3 countLabel
        makeLabel(countLabel, id: "countLabel", value: "count: 0")
        countLabel.frame = NSRect(x: leftX, y: ly, width: 420, height: 20); root.addSubview(countLabel); ly += 28

        // 4 dblLabel
        makeLabel(dblLabel, id: "dblLabel", value: "dbl: 0")
        dblLabel.frame = NSRect(x: leftX, y: ly, width: 420, height: 20); root.addSubview(dblLabel); ly += 28

        // 5 okButton / 6 dblButton (same row)
        okButton.setAccessibilityIdentifier("okButton")
        okButton.target = self; okButton.action = #selector(okTapped)
        okButton.frame = NSRect(x: leftX, y: ly, width: 100, height: 28); root.addSubview(okButton)
        dblButton.setAccessibilityIdentifier("dblButton")
        dblButton.target = self; dblButton.action = #selector(dblTapped)
        dblButton.frame = NSRect(x: leftX + 120, y: ly, width: 140, height: 28); root.addSubview(dblButton); ly += 38

        // 7 flagCheckbox
        flagCheckbox.setAccessibilityIdentifier("flagCheckbox")
        flagCheckbox.target = self; flagCheckbox.action = #selector(flagChanged)
        flagCheckbox.frame = NSRect(x: leftX, y: ly, width: 120, height: 24); root.addSubview(flagCheckbox); ly += 32

        // 8 colorSwatch (rendered fill, on-screen)
        colorSwatch.setAccessibilityIdentifier("colorSwatch")
        colorSwatch.setAccessibilityElement(true)
        colorSwatch.setAccessibilityRole(.group)
        colorSwatch.frame = NSRect(x: leftX, y: ly, width: 60, height: 60); root.addSubview(colorSwatch); ly += 70

        // 9 searchField (plain editable text field)
        searchField.setAccessibilityIdentifier("searchField")
        searchField.placeholderString = "Search"
        searchField.isEditable = true
        searchField.isBordered = true
        searchField.frame = NSRect(x: leftX, y: ly, width: 300, height: 24); root.addSubview(searchField); ly += 34

        // 10/11 innerScroll with item-0..8 + scroll-end
        buildInnerScroll()
        innerScroll.frame = NSRect(x: leftX, y: ly, width: 300, height: 120); root.addSubview(innerScroll); ly += 130

        // 12 slider (wide) + 13 sliderValueLabel
        slider.minValue = 0; slider.maxValue = 100; slider.doubleValue = 0
        slider.setAccessibilityIdentifier("slider")
        slider.target = self; slider.action = #selector(sliderChanged)
        slider.frame = NSRect(x: leftX, y: ly, width: 260, height: 24); root.addSubview(slider)
        makeLabel(sliderValueLabel, id: "sliderValueLabel", value: "slider: 0")
        sliderValueLabel.frame = NSRect(x: leftX + 280, y: ly + 2, width: 150, height: 20); root.addSubview(sliderValueLabel)
        ly += 34

        // 14 rightClickTarget
        rightClickTarget.wantsLayer = true
        rightClickTarget.layer?.backgroundColor = NSColor(white: 0.9, alpha: 1).cgColor
        rightClickTarget.setAccessibilityIdentifier("rightClickTarget")
        rightClickTarget.setAccessibilityElement(true)
        rightClickTarget.setAccessibilityRole(.group)
        let ctxMenu = NSMenu()
        let ctxItem = NSMenuItem(title: "ContextAction", action: #selector(contextTapped), keyEquivalent: "")
        ctxItem.target = self
        ctxMenu.addItem(ctxItem)
        rightClickTarget.menu = ctxMenu
        rightClickTarget.frame = NSRect(x: leftX, y: ly, width: 300, height: 40); root.addSubview(rightClickTarget); ly += 50

        // ---- Right column ----

        // 17 modeSegment + 18 segmentLabel
        modeSegment.setAccessibilityIdentifier("modeSegment")
        modeSegment.selectedSegment = 0
        modeSegment.target = self; modeSegment.action = #selector(segmentChanged)
        modeSegment.frame = NSRect(x: rightX, y: ry, width: 280, height: 26); root.addSubview(modeSegment); ry += 34
        makeLabel(segmentLabel, id: "segmentLabel", value: "segment: 0")
        segmentLabel.frame = NSRect(x: rightX, y: ry, width: 380, height: 20); root.addSubview(segmentLabel); ry += 30

        // 19 colorPicker + 20 pickerLabel
        colorPicker.setAccessibilityIdentifier("colorPicker")
        colorPicker.addItems(withTitles: ["Red", "Green", "Blue"])
        colorPicker.selectItem(withTitle: "Red")
        colorPicker.target = self; colorPicker.action = #selector(pickerChanged)
        colorPicker.frame = NSRect(x: rightX, y: ry, width: 160, height: 26); root.addSubview(colorPicker)
        makeLabel(pickerLabel, id: "pickerLabel", value: "pick: Red")
        pickerLabel.frame = NSRect(x: rightX + 180, y: ry + 4, width: 200, height: 20); root.addSubview(pickerLabel)
        ry += 36

        // 21 quantityStepper + 22 quantityLabel
        quantityStepper.setAccessibilityIdentifier("quantityStepper")
        quantityStepper.minValue = 0; quantityStepper.maxValue = 10
        quantityStepper.increment = 1; quantityStepper.doubleValue = 0
        quantityStepper.valueWraps = false
        quantityStepper.target = self; quantityStepper.action = #selector(stepperChanged)
        quantityStepper.frame = NSRect(x: rightX, y: ry, width: 24, height: 30); root.addSubview(quantityStepper)
        makeLabel(quantityLabel, id: "quantityLabel", value: "qty: 0")
        quantityLabel.frame = NSRect(x: rightX + 44, y: ry + 4, width: 200, height: 20); root.addSubview(quantityLabel)
        ry += 40

        // 23 uploadProgress
        uploadProgress.setAccessibilityIdentifier("uploadProgress")
        uploadProgress.isIndeterminate = false
        uploadProgress.minValue = 0; uploadProgress.maxValue = 1
        uploadProgress.doubleValue = 0.5
        uploadProgress.frame = NSRect(x: rightX, y: ry, width: 320, height: 20); root.addSubview(uploadProgress); ry += 30

        // 24 advanceButton
        advanceButton.setAccessibilityIdentifier("advanceButton")
        advanceButton.target = self; advanceButton.action = #selector(advanceTapped)
        advanceButton.frame = NSRect(x: rightX, y: ry, width: 120, height: 28); root.addSubview(advanceButton); ry += 38

        // 25 notesArea (NSTextView in a scroll view)
        buildNotes()
        notesScroll.frame = NSRect(x: rightX, y: ry, width: 380, height: 70); root.addSubview(notesScroll); ry += 80

        // 26 termsLink
        termsLink.setAccessibilityIdentifier("termsLink")
        termsLink.bezelStyle = .inline
        termsLink.isBordered = false
        termsLink.contentTintColor = .linkColor
        termsLink.target = self; termsLink.action = #selector(termsTapped)
        termsLink.frame = NSRect(x: rightX, y: ry, width: 220, height: 24); root.addSubview(termsLink); ry += 34

        // 27-31 fileTable + tableSelLabel
        buildTable()
        fileScroll.frame = NSRect(x: rightX, y: ry, width: 380, height: 80); root.addSubview(fileScroll); ry += 90
        makeLabel(tableSelLabel, id: "tableSelLabel", value: "table-sel: none")
        tableSelLabel.frame = NSRect(x: rightX, y: ry, width: 380, height: 20); root.addSubview(tableSelLabel); ry += 30

        // 32-34 alertButton
        alertButton.setAccessibilityIdentifier("alertButton")
        alertButton.target = self; alertButton.action = #selector(alertTapped)
        alertButton.frame = NSRect(x: rightX, y: ry, width: 120, height: 28); root.addSubview(alertButton); ry += 38

        // 35 lockedButton + 36 disabledLabel
        lockedButton.setAccessibilityIdentifier("lockedButton")
        lockedButton.isEnabled = false
        lockedButton.frame = NSRect(x: rightX, y: ry, width: 120, height: 28); root.addSubview(lockedButton)
        makeLabel(disabledLabel, id: "disabledLabel", value: "locked: true")
        disabledLabel.frame = NSRect(x: rightX + 140, y: ry + 4, width: 220, height: 20); root.addSubview(disabledLabel)
        ry += 40

        window.contentView = root
    }

    func buildInnerScroll() {
        let docH: CGFloat = 9 * 28 + 28 + 16
        let inner = FlippedView(frame: NSRect(x: 0, y: 0, width: 280, height: docH))
        var yy: CGFloat = 8
        for i in 0..<9 {
            let l = NSTextField(labelWithString: "item-\(i)")
            l.setAccessibilityIdentifier("item-\(i)")
            l.setAccessibilityValue("item-\(i)")
            l.frame = NSRect(x: 8, y: yy, width: 240, height: 20)
            inner.addSubview(l)
            yy += 28
        }
        let endLabel = NSTextField(labelWithString: "scroll-end")
        endLabel.setAccessibilityIdentifier("scroll-end")
        endLabel.setAccessibilityValue("scroll-end")
        endLabel.frame = NSRect(x: 8, y: yy, width: 240, height: 20)
        inner.addSubview(endLabel)

        innerScroll.setAccessibilityIdentifier("scrollView")
        innerScroll.hasVerticalScroller = true
        innerScroll.documentView = inner
        innerScroll.borderType = .bezelBorder
    }

    func buildNotes() {
        notesScroll.hasVerticalScroller = true
        notesScroll.borderType = .bezelBorder
        notesView.isEditable = true
        notesView.isRichText = false
        notesView.font = NSFont.systemFont(ofSize: 14)
        notesView.string = ""
        notesView.setAccessibilityIdentifier("notesArea")
        notesView.isAutomaticQuoteSubstitutionEnabled = false
        notesView.isAutomaticDashSubstitutionEnabled = false
        notesView.isAutomaticTextReplacementEnabled = false
        notesScroll.documentView = notesView
        // Put the identifier on the scroll view too so resolution that lands on
        // the scroll area still finds it; the text view is the AX value holder.
    }

    func buildTable() {
        fileScroll.hasVerticalScroller = true
        fileScroll.borderType = .bezelBorder
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        col.title = "File"
        col.width = 360
        fileTable.addTableColumn(col)
        fileTable.headerView = nil        // no header static texts polluting the count
        fileTable.setAccessibilityIdentifier("fileTable")
        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.usesAutomaticRowHeights = false
        fileTable.rowHeight = 24
        fileTable.target = self
        fileTable.action = #selector(tableClicked)
        fileScroll.documentView = fileTable
    }

    // MARK: Menu

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

    // MARK: Actions

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === nameField {
            setLabel(statusLabel, "status: \(nameField.stringValue)")
        }
    }

    @objc func okTapped() {
        count += 1
        setLabel(countLabel, "count: \(count)")
    }

    @objc func dblTapped() {
        // A doubleClick arrives as two click actions; coalesce the pair into a
        // single dbl increment. A lone click does nothing.
        let now = Date()
        if let last = lastDblClick, now.timeIntervalSince(last) < 0.5 {
            dblCount += 1
            setLabel(dblLabel, "dbl: \(dblCount)")
            lastDblClick = nil
        } else {
            lastDblClick = now
        }
    }

    @objc func flagChanged() {
        flagOn = (flagCheckbox.state == .on)
        setLabel(statusLabel, "status: flag=\(flagOn)")
        // Return keyboard focus to the search field. On macOS, the earlier
        // click-to-type on nameField takes (and keeps) first responder, unlike
        // iOS where button/switch taps leave the text field focused. The search
        // field is the app's resting focus before the search interaction, so the
        // flag toggle — the last step before the focus assertion — restores it.
        window.makeFirstResponder(searchField)
    }

    @objc func toggleFlag() {
        // The plan asserts flag=true after this menu action regardless of prior
        // checkbox state, so force it on and mark the menu item.
        flagOn = true
        flagCheckbox.state = .on
        flagItem.state = .on
        setLabel(statusLabel, "status: flag=true")
    }

    @objc func sliderChanged() {
        setLabel(sliderValueLabel, "slider: \(Int(slider.doubleValue))")
    }

    @objc func contextTapped() {
        setLabel(statusLabel, "status: context-tapped")
    }

    @objc func segmentChanged() {
        setLabel(segmentLabel, "segment: \(modeSegment.selectedSegment)")
    }

    @objc func pickerChanged() {
        let title = colorPicker.titleOfSelectedItem ?? "Red"
        setLabel(pickerLabel, "pick: \(title)")
    }

    @objc func stepperChanged() {
        setLabel(quantityLabel, "qty: \(Int(quantityStepper.doubleValue))")
    }

    @objc func advanceTapped() {
        uploadProgress.doubleValue = 1.0
    }

    @objc func termsTapped() {
        setLabel(statusLabel, "status: link-tapped")
    }

    @objc func tableClicked() {
        let row = fileTable.clickedRow
        guard row >= 0, row < fileItems.count else { return }
        setLabel(tableSelLabel, "table-sel: \(fileItems[row])")
    }

    @objc func alertTapped() {
        let alert = NSAlert()
        alert.messageText = "Are you sure?"
        alert.addButton(withTitle: "Confirm")   // buttons[0]
        alert.addButton(withTitle: "Cancel")    // buttons[1]
        alert.buttons[0].setAccessibilityIdentifier("confirmButton")
        alert.buttons[1].setAccessibilityIdentifier("cancelButton")
        alert.beginSheetModal(for: window) { [weak self] resp in
            if resp == .alertFirstButtonReturn {
                self?.setLabel(self!.statusLabel, "status: alert-confirmed")
            } else {
                self?.setLabel(self!.statusLabel, "status: alert-cancelled")
            }
        }
    }

    // MARK: Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { fileItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let filename = fileItems[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: filename)
            cell.identifier = id
            cell.isBordered = false
            cell.drawsBackground = false
        }
        cell.stringValue = filename
        cell.setAccessibilityValue(filename)
        cell.setAccessibilityIdentifier("row-\(filename)")
        return cell
    }
}

/// A top-left-origin view so absolute frames lay out from the top down.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// An NSTextView that deterministically takes first responder on mouse-down.
/// A synthesized focus click (the `type` action clicks an element's center to
/// focus it before sending keys) does not reliably transfer first-responder
/// into an NSTextView nested in a scroll view — so without this, typed text
/// goes nowhere and the field stays empty. Grabbing first responder up front
/// makes focus deterministic regardless of windowing/session state.
final class FocusableTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
