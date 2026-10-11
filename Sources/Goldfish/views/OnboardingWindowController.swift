import AppKit

final class OnboardingWindowController: NSObject, NSWindowDelegate {
  enum ShortcutChoice: String { case pasteStyle, clipBoredDefault, current }
  struct PresentationChoice: Equatable {
    let showMenuBarIcon: Bool
    let showDockIcon: Bool
  }
  static let pasteStyleOpenShortcut = ShortcutBinding(
    key: "v", modifierFlags: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue)

  static func normalizedPresentation(showMenuBarIcon: Bool, showDockIcon: Bool) -> PresentationChoice {
    if showMenuBarIcon || showDockIcon { return PresentationChoice(showMenuBarIcon: showMenuBarIcon, showDockIcon: showDockIcon) }
    return PresentationChoice(showMenuBarIcon: true, showDockIcon: false)
  }
  static func initialShortcutChoice(for binding: ShortcutBinding, onboardingCompleted: Bool) -> ShortcutChoice {
    if binding == pasteStyleOpenShortcut { return .pasteStyle }
    if binding == AppConfig.defaultOpenShortcut { return onboardingCompleted ? .clipBoredDefault : .pasteStyle }
    return .current
  }
  static func shortcutBinding(for choice: ShortcutChoice, current: ShortcutBinding) -> ShortcutBinding {
    switch choice {
    case .pasteStyle: return pasteStyleOpenShortcut
    case .clipBoredDefault: return AppConfig.defaultOpenShortcut
    case .current: return current
    }
  }

  private let settings: SettingsModel
  private let onOpenAccessibility: () -> Void
  private let onFinish: () -> Void
  private var window: NSWindow?
  private var didComplete = false
  private var shortcutChoice = ShortcutChoice.pasteStyle
  private let shortcutButton = WelcomeButton(title: "", primary: false)
  private let permissionButton = WelcomeButton(title: "Enable…", primary: false)
  private let permissionStatusLabel = NSTextField(labelWithString: "")
  private let privacyLabel = NSTextField(labelWithString: "")

  init(settings: SettingsModel, onOpenAccessibility: @escaping () -> Void, onFinish: @escaping () -> Void) {
    self.settings = settings
    self.onOpenAccessibility = onOpenAccessibility
    self.onFinish = onFinish
    super.init()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 548), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered,
      defer: false)
    window.title = "Welcome to Goldfish"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.contentView = makeContentView()
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.center()
    self.window = window
    refreshFromSettings()
  }

  func show() {
    guard let window else { return }
    refreshFromSettings()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func refreshPermissionStatus() {
    let trusted = AccessibilityPermissionService.isTrusted
    permissionStatusLabel.stringValue = trusted ? "Ready to paste into your previous app." : "Optional. Without access, clips copy instead."
    permissionButton.title = trusted ? "Enabled ✓" : "Enable…"
    permissionButton.isEnabled = !trusted
    permissionButton.setAccessibilityLabel(trusted ? "Automatic paste enabled" : "Enable automatic paste")
  }
  func windowWillClose(_ notification: Notification) {
    // Dismissing the introduction is not consent to start clipboard capture.
    // Keep this controller available so the menu bar or shortcut can reopen it.
  }

  private func makeContentView() -> NSView {
    let content = WelcomeSurface()
    let hero = NSView()
    let brand = label("GOLDFISH", size: 11, weight: .semibold, color: ShelfStyle.secondaryText)
    brand.attributedStringValue = NSAttributedString(
      string: "GOLDFISH",
      attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: ShelfStyle.secondaryText, .kern: 2])
    let heading = label("A little less lost.\nA lot more found.", size: 32, weight: .bold)
    let subtitle = label("Your links, ideas, and everyday copies.\nOne shortcut away.", size: 14, color: ShelfStyle.secondaryText)
    let words = NativeUI.stack([brand, heading, subtitle], axis: .vertical, alignment: .leading, spacing: 14)
    words.setCustomSpacing(12, after: heading)
    let preview = WelcomeShelfPreview()
    for view in [words, preview] {
      view.translatesAutoresizingMaskIntoConstraints = false
      hero.addSubview(view)
    }
    NSLayoutConstraint.activate([
      words.leadingAnchor.constraint(equalTo: hero.leadingAnchor), words.centerYAnchor.constraint(equalTo: hero.centerYAnchor),
      words.widthAnchor.constraint(equalToConstant: 340), preview.trailingAnchor.constraint(equalTo: hero.trailingAnchor),
      preview.centerYAnchor.constraint(equalTo: hero.centerYAnchor), preview.widthAnchor.constraint(equalToConstant: 200),
      preview.heightAnchor.constraint(equalToConstant: 192), hero.heightAnchor.constraint(equalToConstant: 196),
    ])

    shortcutButton.target = self
    shortcutButton.action = #selector(chooseShortcut)
    shortcutButton.setAccessibilityLabel("Open Goldfish shortcut")
    shortcutButton.constrainSize(width: 126, height: 38)
    permissionButton.target = self
    permissionButton.action = #selector(openAccessibilitySettings)
    permissionButton.constrainSize(width: 126, height: 38)
    permissionStatusLabel.font = .systemFont(ofSize: 12)
    permissionStatusLabel.textColor = ShelfStyle.secondaryText
    let options = WelcomeOptionsSurface()
    let shortcutRow = optionRow(
      symbol: "command", title: "Open your clipboard",
      subtitle: label("Choose a shortcut that feels familiar.", size: 12, color: ShelfStyle.secondaryText), control: shortcutButton)
    let permissionRow = optionRow(
      symbol: "cursorarrow.click", title: "Paste directly into apps", subtitle: permissionStatusLabel, control: permissionButton)
    let rows = NativeUI.stack([shortcutRow, permissionRow], axis: .vertical, alignment: .leading, spacing: 0)
    rows.translatesAutoresizingMaskIntoConstraints = false
    options.addSubview(rows)
    NSLayoutConstraint.activate([
      rows.leadingAnchor.constraint(equalTo: options.leadingAnchor), rows.trailingAnchor.constraint(equalTo: options.trailingAnchor),
      rows.topAnchor.constraint(equalTo: options.topAnchor), rows.bottomAnchor.constraint(equalTo: options.bottomAnchor),
      shortcutRow.widthAnchor.constraint(equalTo: rows.widthAnchor), permissionRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
    ])

    let privacyIcon = NSImageView(image: NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)!)
    privacyIcon.contentTintColor = ShelfStyle.secondaryText
    privacyIcon.constrainSize(width: 15, height: 16)
    privacyLabel.font = .systemFont(ofSize: 11)
    privacyLabel.textColor = ShelfStyle.secondaryText
    let privacy = NativeUI.stack([privacyIcon, privacyLabel], axis: .horizontal, alignment: .centerY, spacing: 7)
    let finish = WelcomeButton(title: "Start using Goldfish  →", primary: true)
    finish.target = self
    finish.action = #selector(finishSetup)
    finish.keyEquivalent = "\r"
    finish.setAccessibilityLabel("Start using Goldfish")
    finish.constrainSize(width: 214, height: 44)
    let note = label(
      "Start saves your future copies locally.\nClose this window to set up later.", size: 12, color: ShelfStyle.secondaryText)
    let footer = NativeUI.stack([note, NSView(), finish], axis: .horizontal, alignment: .centerY, spacing: 16)
    footer.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
    let stack = NativeUI.stack([hero, options, privacy, footer], axis: .vertical, alignment: .leading, spacing: 18)
    stack.setCustomSpacing(24, after: hero)
    stack.setCustomSpacing(24, after: privacy)
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
    ])
    for view in [hero, options, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    return content
  }

  private func optionRow(symbol: String, title: String, subtitle: NSTextField, control: NSView) -> NSView {
    let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
    icon.contentTintColor = ShelfStyle.secondaryText
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .regular)
    icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
    let text = NativeUI.stack([label(title, size: 14, weight: .medium), subtitle], axis: .vertical, alignment: .leading, spacing: 4)
    let row = NativeUI.stack(
      [icon, text, NSView(), control], axis: .horizontal, alignment: .centerY, spacing: 12,
      insets: NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 16))
    row.arrangedSubviews[2].setContentHuggingPriority(.defaultLow, for: .horizontal)
    row.heightAnchor.constraint(equalToConstant: 76).isActive = true
    return row
  }
  private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let label = NativeUI.label(text, font: .systemFont(ofSize: size, weight: weight), color: color, maxLines: 0)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    return label
  }
  private func refreshFromSettings() {
    shortcutChoice = Self.initialShortcutChoice(for: settings.openShortcut, onboardingCompleted: settings.onboardingCompleted)
    updateShortcutTitle()
    privacyLabel.stringValue =
      settings.excludeSensitive ? "Stored locally · Encrypted history · Secret filtering on" : "Stored locally · Encrypted history"
    refreshPermissionStatus()
  }
  private func updateShortcutTitle() {
    shortcutButton.title = Self.shortcutBinding(for: shortcutChoice, current: settings.openShortcut).displayText + "  ⌄"
  }
  @objc private func chooseShortcut() {
    let menu = NSMenu()
    var choices: [(String, ShortcutChoice)] = [("⇧⌘V — Shift–Command–V", .pasteStyle), ("⌥⌘V — Option–Command–V", .clipBoredDefault)]
    if settings.openShortcut != Self.pasteStyleOpenShortcut, settings.openShortcut != AppConfig.defaultOpenShortcut {
      choices.append(("Keep current: \(settings.openShortcut.displayText)", .current))
    }
    for (title, choice) in choices {
      let item = NSMenuItem(title: title, action: #selector(shortcutSelected(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = choice.rawValue
      item.state = choice == shortcutChoice ? .on : .off
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: shortcutButton.bounds.minY - 4), in: shortcutButton)
  }
  @objc private func shortcutSelected(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let choice = ShortcutChoice(rawValue: raw) else { return }
    shortcutChoice = choice
    updateShortcutTitle()
  }
  @objc private func openAccessibilitySettings() {
    onOpenAccessibility()
    refreshPermissionStatus()
  }
  @objc private func finishSetup() {
    guard !didComplete else { return }
    didComplete = true
    settings.openShortcut = Self.shortcutBinding(for: shortcutChoice, current: settings.openShortcut)
    let presentation = Self.normalizedPresentation(showMenuBarIcon: settings.showMenuBarIcon, showDockIcon: settings.showDockIcon)
    settings.showMenuBarIcon = presentation.showMenuBarIcon
    settings.showDockIcon = presentation.showDockIcon
    settings.markAccessibilityNoticeShown()
    settings.markOnboardingCompleted()
    window?.delegate = nil
    window?.close()
    onFinish()
  }
}

// First launch is an introduction, not a second preferences window. The shelf
// illustration is native vector artwork and stays sharp at every display scale.
private class WelcomeSurface: NSView {
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) { bounds.fill(with: ShelfStyle.windowBackground) }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

private final class WelcomeOptionsSurface: WelcomeSurface {
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
    path.fill(with: NSColor.labelColor.withAlphaComponent(0.035))
    path.stroke(with: NSColor.labelColor.withAlphaComponent(0.065), width: 1)
    let divider = NSBezierPath()
    divider.move(to: NSPoint(x: 54, y: bounds.midY))
    divider.line(to: NSPoint(x: bounds.maxX - 16, y: bounds.midY))
    divider.lineWidth = 1
    divider.stroke()
  }
}

private final class WelcomeButton: NativeHoverButton {
  private let primary: Bool
  init(title: String, primary: Bool) {
    self.primary = primary
    super.init(frame: .zero)
    self.title = title
    isBordered = false
    setButtonType(.momentaryPushIn)
    font = .systemFont(ofSize: 13, weight: .semibold)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var trackingActivity: NSTrackingArea.Options { .activeInKeyWindow }
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
    let base = ShelfStyle.brandAccent
    let fill =
      primary
      ? (isHighlighted ? base.blended(withFraction: 0.16, of: .black)! : base)
      : NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.13 : (isPointerInside ? 0.09 : 0.055))
    path.fill(with: fill)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font ?? NSFont.systemFont(ofSize: 13, weight: .semibold),
      .foregroundColor: primary ? ShelfStyle.foregroundColor(on: base) : (isEnabled ? NSColor.labelColor : ShelfStyle.secondaryText),
    ]
    let size = (title as NSString).size(withAttributes: attributes)
    (title as NSString).draw(
      at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    if window?.firstResponder === self { path.stroke(with: NSColor.keyboardFocusIndicatorColor, width: 2) }
  }
}

private final class WelcomeShelfPreview: NSView {
  override var isFlipped: Bool { true }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    let shell = NSBezierPath(roundedRect: NSRect(x: 6, y: 0, width: 188, height: 192), xRadius: 18, yRadius: 18)
    shell.fill(with: NSColor.labelColor.withAlphaComponent(0.045))
    drawText("Search your clips", at: NSPoint(x: 23, y: 14), size: 10, color: ShelfStyle.secondaryText)
    let cards: [(CGFloat, String, String, String)] = [
      (38, "Notes", "Keep the good things.", "A little inspiration."), (112, "Safari", "A good find.", "apple.com"),
    ]
    for (y, source, title, body) in cards {
      let rect = NSRect(x: 18, y: y, width: 164, height: 64)
      let path = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
      path.fill(with: ShelfStyle.cardBackground)
      path.clipped {
        let accent = ClipPresentation().accentColor(for: source == "Notes" ? .text : .url)
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 20).fill(with: accent)
        drawText(source == "Notes" ? "Text" : "Link", at: NSPoint(x: 29, y: y + 5), size: 8, color: ShelfStyle.foregroundColor(on: accent))
        drawText(title, at: NSPoint(x: 29, y: y + 27), size: 10, color: .labelColor)
        drawText(body, at: NSPoint(x: 29, y: y + 44), size: 9, color: ShelfStyle.secondaryText)
      }
    }
  }

  private func drawText(_ text: String, at point: NSPoint, size: CGFloat, color: NSColor) {
    (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color])
  }
}
