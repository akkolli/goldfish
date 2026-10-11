import AppKit

/// One continuous material for the shelf and its attached category notch.
/// A shared contour avoids doubled blur, a seam, or a separate floating pill.
final class ShelfSurface: NSView {
  static let notchShoulderRadius: CGFloat = 10
  private let material = NSVisualEffectView()
  private let tint = NSView()
  private let surfaceMask = CAShapeLayer()
  private let outline = CAShapeLayer()
  private var bodyLeadingInset: CGFloat = 0
  private var notchFrame: NSRect = .zero
  var cornerRadius: CGFloat { didSet { updateContour() } }

  init(cornerRadius: CGFloat) {
    self.cornerRadius = cornerRadius
    super.init(frame: .zero)
    wantsLayer = true
    surfaceMask.fillColor = NSColor.black.cgColor
    layer?.mask = surfaceMask
    material.material = .sidebar
    material.blendingMode = .behindWindow
    material.state = .active
    material.isEmphasized = true
    tint.wantsLayer = true
    for view in [material, tint] {
      addSubview(view)
      view.translatesAutoresizingMaskIntoConstraints = false
      view.pinEdges(to: self)
    }
    outline.fillColor = nil
    layer?.addSublayer(outline)
    refreshAppearance()
  }

  required init?(coder: NSCoder) { nil }

  func setNotch(frame: NSRect, bodyLeadingInset: CGFloat) {
    self.notchFrame = frame
    self.bodyLeadingInset = bodyLeadingInset
    updateContour()
  }

  override func layout() {
    super.layout()
    updateContour()
  }

  private func updateContour() {
    guard bounds.width > bodyLeadingInset, bounds.height > 0 else { return }
    let body = NSRect(x: bounds.minX + bodyLeadingInset, y: bounds.minY, width: bounds.width - bodyLeadingInset, height: bounds.height)
    let radius = min(cornerRadius, body.width / 2, body.height / 2)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: body.minX + radius, y: body.maxY))
    path.addLine(to: CGPoint(x: body.maxX - radius, y: body.maxY))
    path.addQuadCurve(to: CGPoint(x: body.maxX, y: body.maxY - radius), control: CGPoint(x: body.maxX, y: body.maxY))
    path.addLine(to: CGPoint(x: body.maxX, y: body.minY + radius))
    path.addQuadCurve(to: CGPoint(x: body.maxX - radius, y: body.minY), control: CGPoint(x: body.maxX, y: body.minY))
    path.addLine(to: CGPoint(x: body.minX + radius, y: body.minY))
    path.addQuadCurve(to: CGPoint(x: body.minX, y: body.minY + radius), control: CGPoint(x: body.minX, y: body.minY))
    if !notchFrame.isEmpty, notchFrame.minX < body.minX {
      let shoulder = max(0, min(Self.notchShoulderRadius, notchFrame.minY - body.minY - radius, body.maxY - radius - notchFrame.maxY))
      let tip = min(12, notchFrame.height / 2, (body.minX - notchFrame.minX - shoulder) / 2)
      path.addLine(to: CGPoint(x: body.minX, y: notchFrame.minY - shoulder))
      path.addQuadCurve(to: CGPoint(x: body.minX - shoulder, y: notchFrame.minY), control: CGPoint(x: body.minX, y: notchFrame.minY))
      path.addLine(to: CGPoint(x: notchFrame.minX + tip, y: notchFrame.minY))
      path.addQuadCurve(to: CGPoint(x: notchFrame.minX, y: notchFrame.minY + tip), control: CGPoint(x: notchFrame.minX, y: notchFrame.minY))
      path.addLine(to: CGPoint(x: notchFrame.minX, y: notchFrame.maxY - tip))
      path.addQuadCurve(to: CGPoint(x: notchFrame.minX + tip, y: notchFrame.maxY), control: CGPoint(x: notchFrame.minX, y: notchFrame.maxY))
      path.addLine(to: CGPoint(x: body.minX - shoulder, y: notchFrame.maxY))
      path.addQuadCurve(to: CGPoint(x: body.minX, y: notchFrame.maxY + shoulder), control: CGPoint(x: body.minX, y: notchFrame.maxY))
    }
    path.addLine(to: CGPoint(x: body.minX, y: body.maxY - radius))
    path.addQuadCurve(to: CGPoint(x: body.minX + radius, y: body.maxY), control: CGPoint(x: body.minX, y: body.maxY))
    path.closeSubpath()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    surfaceMask.frame = bounds
    surfaceMask.path = path
    outline.frame = bounds
    outline.path = path
    CATransaction.commit()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshAppearance()
  }

  func refreshAppearance() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      material.alphaValue = ShelfStyle.shelfMaterialOpacity
      tint.layer?.backgroundColor = ShelfStyle.shelfTint.cgColor
      outline.strokeColor = ShelfStyle.shelfBorder.cgColor
      outline.lineWidth = ShelfStyle.increasedContrast ? 2 : 0
    }
  }
}

enum ShelfStyle {
  static let inset: CGFloat = 16
  static let cardRadius: CGFloat = 20
  static let controlRadius: CGFloat = 10
  static let cardSpacing: CGFloat = 12
  static let controlSize: CGFloat = 32
  static let brandAccent = NSColor(srgbRed: 0.96, green: 0.43, blue: 0.19, alpha: 1)
  static let cardBackground = NSColor(name: "Goldfish card") { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1) : .white
  }
  static var clipSurface: NSColor {
    if reducedTransparency || increasedContrast { return cardBackground }
    return cardBackground.withAlphaComponent(isDarkAppearance ? 0.72 : 0.78)
  }

  static var clipBorder: NSColor {
    if increasedContrast { return .labelColor }
    return isDarkAppearance ? .white.withAlphaComponent(0.13) : .black.withAlphaComponent(0.07)
  }
  static var increasedContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
  static var reducedTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
  // System secondaryLabelColor is approximately 50% black in Aqua, below
  // 4.5:1 on our opaque cards. Use stronger adaptive ink for small clip text.
  static let secondaryText = NSColor(name: "Goldfish secondary text") { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.68) : NSColor(white: 0, alpha: 0.68)
  }
  static let windowBackground = NSColor(name: "Goldfish window") { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? NSColor(srgbRed: 0.105, green: 0.115, blue: 0.13, alpha: 1) : NSColor(srgbRed: 0.97, green: 0.97, blue: 0.975, alpha: 1)
  }

  // The shelf is an edge overlay. Let the system material carry the blur and
  // use only enough neutral tint to keep the controls stable over busy windows.
  // Cards add a stronger reading surface over this shared blur.
  static var shelfTint: NSColor {
    let opacity: CGFloat = reducedTransparency || increasedContrast ? 1 : 0.08
    return windowBackground.withAlphaComponent(opacity)
  }

  static var shelfMaterialOpacity: CGFloat { reducedTransparency || increasedContrast ? 1 : (isDarkAppearance ? 0.88 : 0.84) }

  static var shelfBorder: NSColor {
    if increasedContrast { return .labelColor }
    return isDarkAppearance ? .white.withAlphaComponent(0.18) : .white.withAlphaComponent(0.72)
  }

  private static var isDarkAppearance: Bool { NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

  static func foregroundColor(on background: NSColor) -> NSColor {
    guard let rgb = background.usingColorSpace(.sRGB) else { return .white }
    func linear(_ component: CGFloat) -> CGFloat { component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4) }
    let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    // Pick the higher-contrast ink; white on yellow/teal headers was illegible.
    return luminance > 0.179 ? .black : .white
  }
}

enum ShelfMotion {
  static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
  static func duration(_ preferred: TimeInterval) -> TimeInterval { reducesMotion ? 0 : preferred }
}
