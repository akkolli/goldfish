import AppKit
import WebKit

final class LinkPreviewWindowController: PreviewController, WKNavigationDelegate {
  enum NavigationDecision: Equatable {
    case allow
    case openExternally
    case cancel
  }

  private enum Metrics {
    static let minimumWidth: CGFloat = 760
    static let minimumHeight: CGFloat = 420
    static let preferredHeight: CGFloat = 560
    static let margin: CGFloat = 24
    static let panelGap: CGFloat = 14
    static let toolbarHeight: CGFloat = 56
    static let toolbarLeadingInset: CGFloat = 86
  }

  private let webView: WKWebView
  private let titleLabel = NSTextField(labelWithString: "")
  private let addressLabel = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  private let progressIndicator = NSProgressIndicator()
  private let backButton = NSButton()
  private let forwardButton = NSButton()
  private let reloadButton = NSButton()
  private let openExternalButton = NSButton()
  private let openURL: (URL) -> Void
  private var progressObservation: NSKeyValueObservation?
  private var titleObservation: NSKeyValueObservation?
  private var canGoBackObservation: NSKeyValueObservation?
  private var canGoForwardObservation: NSKeyValueObservation?
  private var currentRequest: LinkPreviewRequest?
  private var currentPageURL: URL?
  private var acceptsObservedPageTitles = false

  init(openURL: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
    self.openURL = openURL
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

    webView = WKWebView(frame: .zero, configuration: configuration)
    let window = PreviewPanel(
      contentRect: NSRect(x: 0, y: 0, width: Metrics.minimumWidth, height: Metrics.preferredHeight),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
    window.title = "Link Preview"
    window.minSize = NSSize(width: 560, height: 420)
    window.isReleasedWhenClosed = false
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.hidesOnDeactivate = false
    window.level = .floating
    window.isFloatingPanel = true

    super.init(window: window)
    configureContent(in: window)
    configureObservations()
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ request: LinkPreviewRequest, relativeTo parent: NSWindow?) {
    prepareForPreview(request)
    present(relativeTo: parent)
    webView.load(URLRequest(url: request.url))
  }

  override func windowWillClose(_ notification: Notification) {
    webView.stopLoading()
    // Stop already-running media and page timers as well as pending requests.
    // A closed preview can remain owned until the shelf itself is dismissed.
    webView.loadHTMLString("", baseURL: nil)
    super.windowWillClose(notification)
  }

  private func prepareForPreview(_ request: LinkPreviewRequest) {
    currentRequest = request
    currentPageURL = request.url
    acceptsObservedPageTitles = false
    setTitleText(Self.displayTitle(for: request))
    setAddress(request.url)
    setStatus("Loading")
  }

  private static func displayTitle(for request: LinkPreviewRequest) -> String {
    request.title.clipboardTrimmed.isEmpty ? request.url.host ?? "Link Preview" : request.title
  }

  static func previewFrame(relativeTo parent: NSWindow) -> NSRect {
    let visibleFrame = parent.screen?.visibleFrame ?? parent.frame
    return previewFrame(parentFrame: parent.frame, visibleFrame: visibleFrame)
  }

  static func previewFrame(parentFrame: NSRect, visibleFrame: NSRect) -> NSRect {
    let usableWidth = max(1, visibleFrame.width - (Metrics.margin * 2))
    let width = min(max(Metrics.minimumWidth, floor(parentFrame.width * 0.72)), usableWidth)
    let usableHeight = max(1, visibleFrame.height - (Metrics.margin * 2))
    let abovePanelY = parentFrame.maxY + Metrics.panelGap
    let availableAbovePanel = visibleFrame.maxY - abovePanelY - Metrics.margin
    let preferredHeight = min(Metrics.preferredHeight, usableHeight)
    let height = availableAbovePanel >= Metrics.minimumHeight ? min(preferredHeight, availableAbovePanel) : preferredHeight
    let centeredX = parentFrame.midX - (width / 2)
    let preferredX: CGFloat
    if parentFrame.minX - Metrics.panelGap - width >= visibleFrame.minX + Metrics.margin {
      preferredX = parentFrame.minX - Metrics.panelGap - width
    } else if parentFrame.maxX + Metrics.panelGap + width <= visibleFrame.maxX - Metrics.margin {
      preferredX = parentFrame.maxX + Metrics.panelGap
    } else {
      preferredX = centeredX
    }
    let x = min(max(visibleFrame.minX + Metrics.margin, preferredX), visibleFrame.maxX - width - Metrics.margin)
    let preferredY = availableAbovePanel >= Metrics.minimumHeight ? abovePanelY : visibleFrame.midY - (height / 2)
    let y = min(max(visibleFrame.minY + Metrics.margin, preferredY), visibleFrame.maxY - height - Metrics.margin)
    return NSRect(x: floor(x), y: floor(y), width: floor(width), height: floor(height))
  }

  private func configureContent(in window: NSWindow) {
    webView.navigationDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    webView.translatesAutoresizingMaskIntoConstraints = false

    let content = NSView()
    content.wantsLayer = true
    content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    content.translatesAutoresizingMaskIntoConstraints = false
    window.contentView = content

    let toolbar = NSVisualEffectView()
    toolbar.material = .windowBackground
    toolbar.blendingMode = .withinWindow
    toolbar.state = .active
    toolbar.translatesAutoresizingMaskIntoConstraints = false

    let titleColumn = NativeUI.stack([titleLabel, addressLabel], axis: .vertical, alignment: .leading, spacing: 2)
    titleColumn.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.maximumNumberOfLines = 1
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    addressLabel.font = .systemFont(ofSize: 11)
    addressLabel.textColor = ShelfStyle.secondaryText
    addressLabel.lineBreakMode = .byTruncatingMiddle
    addressLabel.maximumNumberOfLines = 1
    addressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let controls = NativeUI.stack(
      [
        configuredButton(backButton, symbol: "chevron.left", toolTip: "Back", action: #selector(goBack)),
        configuredButton(forwardButton, symbol: "chevron.right", toolTip: "Forward", action: #selector(goForward)),
        configuredButton(reloadButton, symbol: "arrow.clockwise", toolTip: "Reload", action: #selector(reload)),
        configuredButton(openExternalButton, symbol: "arrow.up.right.square", toolTip: "Open in Browser", action: #selector(openInBrowser)),
      ], axis: .horizontal, alignment: .centerY, spacing: 6)
    controls.translatesAutoresizingMaskIntoConstraints = false

    progressIndicator.isIndeterminate = false
    progressIndicator.minValue = 0
    progressIndicator.maxValue = 1
    progressIndicator.controlSize = .small
    progressIndicator.style = .bar
    progressIndicator.translatesAutoresizingMaskIntoConstraints = false

    statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.maximumNumberOfLines = 1
    statusLabel.translatesAutoresizingMaskIntoConstraints = false

    content.addSubview(toolbar)
    toolbar.addSubview(controls)
    toolbar.addSubview(titleColumn)
    toolbar.addSubview(statusLabel)
    toolbar.addSubview(progressIndicator)
    content.addSubview(webView)

    NSLayoutConstraint.activate([
      toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      toolbar.topAnchor.constraint(equalTo: content.topAnchor), toolbar.heightAnchor.constraint(equalToConstant: Metrics.toolbarHeight),

      controls.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: Metrics.toolbarLeadingInset),
      controls.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

      titleColumn.leadingAnchor.constraint(equalTo: controls.trailingAnchor, constant: 14),
      titleColumn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
      titleColumn.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -16),

      statusLabel.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -16),
      statusLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
      statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 180),

      progressIndicator.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
      progressIndicator.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
      progressIndicator.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
      progressIndicator.heightAnchor.constraint(equalToConstant: 2),

      webView.leadingAnchor.constraint(equalTo: content.leadingAnchor), webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor), webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])

    updateNavigationButtons()
  }

  private func configuredButton(_ button: NSButton, symbol: String, toolTip: String, action: Selector) -> NSButton {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
    image?.isTemplate = true
    button.image = image
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.isBordered = false
    button.wantsLayer = true
    button.layer?.cornerRadius = ShelfStyle.controlRadius
    button.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    button.contentTintColor = .labelColor
    button.toolTip = toolTip
    button.setAccessibilityLabel(toolTip)
    button.target = self
    button.action = action
    button.translatesAutoresizingMaskIntoConstraints = false
    button.constrainSize(width: 32, height: 32)
    return button
  }

  private func configureObservations() {
    progressObservation = webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
      self?.progressIndicator.doubleValue = webView.estimatedProgress
      self?.progressIndicator.isHidden = webView.estimatedProgress >= 1
    }
    titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in self?.applyObservedPageTitle(webView.title) }
    canGoBackObservation = webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in self?.updateNavigationButtons() }
    canGoForwardObservation = webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, _ in
      self?.updateNavigationButtons()
    }
  }

  private func updateNavigationButtons() {
    backButton.isEnabled = webView.canGoBack
    forwardButton.isEnabled = webView.canGoForward
  }

  private func applyObservedPageTitle(_ title: String?) {
    guard acceptsObservedPageTitles, let title = title?.clipboardTrimmed, !title.isEmpty else { return }
    setTitleText(title)
  }

  private func setTitleText(_ text: String) {
    titleLabel.stringValue = text
    titleLabel.toolTip = text
    window?.title = text
  }

  private func setAddress(_ url: URL) {
    currentPageURL = url
    let text = url.absoluteString
    addressLabel.stringValue = text
    addressLabel.toolTip = text
  }

  private func setStatus(_ text: String) {
    statusLabel.stringValue = text
    statusLabel.toolTip = text.isEmpty ? nil : text
  }

  @objc private func goBack() {
    guard webView.canGoBack else { return }
    webView.goBack()
  }

  @objc private func goForward() {
    guard webView.canGoForward else { return }
    webView.goForward()
  }

  @objc private func reload() { webView.reload() }

  @objc private func openInBrowser() {
    guard let url = currentPageURL ?? currentRequest?.url else { return }
    openURL(url)
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    acceptsObservedPageTitles = true
    setStatus("Loading")
    if let url = webView.url { setAddress(url) }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    setStatus("")
    if let url = webView.url { setAddress(url) }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { handleNavigationFailure(error) }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    handleNavigationFailure(error)
  }

  private func handleNavigationFailure(_ error: Error) {
    guard !Self.isNavigationCancellation(error) else { return }
    setStatus("Could not load")
  }

  private static func isNavigationCancellation(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error { return isNavigationCancellation(underlying) }
    return false
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }

    switch Self.navigationDecision(scheme: url.scheme, navigationType: navigationAction.navigationType) {
    case .allow: decisionHandler(.allow)
    case .openExternally:
      openURL(url)
      decisionHandler(.cancel)
    case .cancel: decisionHandler(.cancel)
    }
  }

  static func navigationDecision(scheme: String?, navigationType: WKNavigationType) -> NavigationDecision {
    let normalizedScheme = scheme?.lowercased()
    if normalizedScheme == "http" || normalizedScheme == "https" { return .allow }
    return navigationType == .linkActivated ? .openExternally : .cancel
  }

}
