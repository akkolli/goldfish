import AppKit
import UniformTypeIdentifiers

final class IgnoredAppsEditor: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
  private let settings: SettingsModel
  private let table = NSTableView()
  private let removeButton = NSButton()
  private var rules: [String] = []

  init(settings: SettingsModel) {
    self.settings = settings
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 8
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app")))
    table.headerView = nil
    table.rowHeight = 26
    table.allowsMultipleSelection = true
    table.dataSource = self
    table.delegate = self
    table.setAccessibilityLabel("Ignored apps and matching rules")
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.heightAnchor.constraint(equalToConstant: 106).isActive = true
    let add = NSButton(title: "Add App…", target: self, action: #selector(addApplication))
    let edit = NSButton(title: "Edit Rules…", target: self, action: #selector(editRules))
    removeButton.title = "Remove"
    removeButton.target = self
    removeButton.action = #selector(removeRules)
    for button in [add, edit, removeButton] { button.bezelStyle = .rounded }
    let actions = NativeUI.stack([add, removeButton, NSView(), edit], axis: .horizontal, spacing: 8)
    actions.arrangedSubviews[2].setContentHuggingPriority(.defaultLow, for: .horizontal)
    for view in [scroll, actions] {
      addArrangedSubview(view)
      view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    settings.observe { [weak self] change in if change == .ignoredApps { self?.refresh() } }
    refresh()
  }
  required init?(coder: NSCoder) { nil }
  func numberOfRows(in tableView: NSTableView) -> Int { rules.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let rule = rules[row]
    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule)
    let name = url?.deletingPathExtension().lastPathComponent ?? rule
    let label = NativeUI.label(name, lineBreak: .byTruncatingTail)
    label.toolTip = rule
    let icon = NSImageView(
      image: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        ?? NSImage())
    icon.constrainSize(width: 18, height: 18)
    let rowView = NativeUI.stack([icon, label], axis: .horizontal, spacing: 7)
    rowView.setAccessibilityLabel(name == rule ? "Matching rule: \(rule)" : "\(name), \(rule)")
    return rowView
  }
  func tableViewSelectionDidChange(_ notification: Notification) { removeButton.isEnabled = table.numberOfSelectedRows > 0 }
  private func refresh() {
    rules = settings.ignoredApps
    table.reloadData()
    removeButton.isEnabled = table.numberOfSelectedRows > 0
  }
  @objc private func removeRules() {
    let selected = table.selectedRowIndexes
    settings.ignoredApps = rules.enumerated().filter { !selected.contains($0.offset) }.map(\.element)
  }
  @objc private func addApplication() {
    guard let window else { return }
    let picker = NSOpenPanel()
    picker.title = "Ignore clipboard capture from apps"
    picker.prompt = "Add Apps"
    picker.allowedContentTypes = [.application]
    picker.allowsMultipleSelection = true
    picker.directoryURL = URL(fileURLWithPath: "/Applications")
    picker.beginSheetModal(for: window) { [weak self] result in
      guard result == .OK, let self else { return }
      let identifiers = picker.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
      self.settings.ignoredApps = Self.uniqueRules(self.settings.ignoredApps + identifiers)
    }
  }
  @objc private func editRules() {
    guard let window else { return }
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 140))
    editor.isRichText = false
    editor.font = .systemFont(ofSize: 13)
    editor.string = rules.joined(separator: "\n")
    editor.setAccessibilityLabel("Ignored app names or bundle identifiers, one per line")
    let scroll = NSScrollView(frame: editor.frame)
    scroll.documentView = editor
    scroll.hasVerticalScroller = true
    let alert = NSAlert(
      title: "Edit Ignored App Rules",
      message: "One app name or bundle identifier per line. A rule matches part of the frontmost app’s name or identifier.",
      buttons: ["Save", "Cancel"])
    alert.accessoryView = scroll
    alert.window.initialFirstResponder = editor
    alert.beginSheetModal(for: window) { [weak self] result in
      guard result == .alertFirstButtonReturn else { return }
      self?.settings.ignoredApps = Self.uniqueRules(editor.string.components(separatedBy: .newlines))
    }
  }
  static func uniqueRules(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.map(\.clipboardTrimmed).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
  }
}
