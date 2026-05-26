import Cocoa
import FlutterMacOS
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  enum TrafficLightMode {
    case relative
    case absolute
  }

  // Without .titled, the window doesn't automatically become key/main on click.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  private var trafficLightDx: CGFloat = 0
  private var trafficLightDy: CGFloat = 0
  private var trafficLightMode: TrafficLightMode = .relative
  private var trafficLightForce: Bool = true
  private weak var trafficLightTargetView: NSView?

  // Track last applied adjustment to avoid accumulating offsets across layout passes.
  private var trafficLightLastAppliedOffset: NSPoint?
  private var trafficLightLastAdjustedOrigin: NSPoint?
  private var trafficLightRepositionScheduled = false
  private var trafficLightObserversInstalled = false
  private var trafficLightKeepAliveTimer: Timer?
  private var trafficLightKeepAliveUntil: TimeInterval = 0

  func setTrafficLightOffset(dx: CGFloat, dy: CGFloat, mode: TrafficLightMode = .relative) {
    trafficLightDx = dx
    trafficLightDy = dy
    trafficLightMode = mode
    // Default to "force" to prevent AppKit constraint relayout from snapping back.
    // Can be disabled via env var for debugging.
    let forceStr = (ProcessInfo.processInfo.environment["BLACKHOLE_TRAFFIC_LIGHT_FORCE"] ?? "1").lowercased()
    trafficLightForce = !(forceStr == "0" || forceStr == "false" || forceStr == "no")
    // Reset state so the next layout pass applies relative to the current system layout.
    trafficLightLastAppliedOffset = nil
    trafficLightLastAdjustedOrigin = nil
    trafficLightTargetView = nil
    scheduleTrafficLightReposition(doublePass: true)
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Register plugins for sub-windows (e.g., Settings window)
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      RegisterGeneratedPlugins(registry: controller)
    }

    super.awakeFromNib()
    installTrafficLightObserversIfNeeded()
  }

  override func setFrame(_ frameRect: NSRect, display flag: Bool) {
    super.setFrame(frameRect, display: flag)
    scheduleTrafficLightReposition(doublePass: false)
  }

  override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
    super.setFrame(frameRect, display: flag, animate: animateFlag)
    scheduleTrafficLightReposition(doublePass: false)
  }

  private func scheduleTrafficLightReposition(doublePass: Bool) {
    if trafficLightRepositionScheduled { return }
    trafficLightRepositionScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.trafficLightRepositionScheduled = false
      self.repositionTrafficLightsIfNeeded()
    }
    if doublePass {
      // AppKit sometimes does an additional titlebar layout after resize; a second
      // pass helps ensure our adjustment "wins".
      DispatchQueue.main.async { [weak self] in
        self?.repositionTrafficLightsIfNeeded()
      }
      // And sometimes there's a delayed pass after the runloop tick.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
        self?.repositionTrafficLightsIfNeeded()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
        self?.repositionTrafficLightsIfNeeded()
      }
    }
  }

  private func installTrafficLightObserversIfNeeded() {
    if trafficLightObserversInstalled { return }
    trafficLightObserversInstalled = true

    let center = NotificationCenter.default
    center.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: self, queue: .main) { [weak self] _ in
      self?.trafficLightTargetView = nil
      self?.startTrafficLightKeepAlive(seconds: 10.0)
    }
    center.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { [weak self] _ in
      self?.trafficLightTargetView = nil
      self?.scheduleTrafficLightReposition(doublePass: true)
      self?.startTrafficLightKeepAlive(seconds: 0.8)
    }
    center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: self, queue: .main) { [weak self] _ in
      // AppKit often does delayed titlebar relayout after live resize ends.
      self?.startTrafficLightKeepAlive(seconds: 1.2)
      self?.scheduleTrafficLightReposition(doublePass: true)
    }
    center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      self?.stopTrafficLightKeepAlive()
      self?.trafficLightLastAppliedOffset = nil
      self?.trafficLightLastAdjustedOrigin = nil
      self?.trafficLightTargetView = nil
      self?.scheduleTrafficLightReposition(doublePass: true)
    }
    center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      self?.stopTrafficLightKeepAlive()
      self?.trafficLightLastAppliedOffset = nil
      self?.trafficLightLastAdjustedOrigin = nil
      self?.trafficLightTargetView = nil
      self?.scheduleTrafficLightReposition(doublePass: true)
    }
  }

  private func startTrafficLightKeepAlive(seconds: TimeInterval) {
    trafficLightKeepAliveUntil = max(trafficLightKeepAliveUntil, Date().timeIntervalSince1970 + seconds)
    if trafficLightKeepAliveTimer != nil { return }

    // AppKit may relayout the titlebar multiple times after resize/fullscreen.
    // Keep applying the adjustment for a short window so it "wins" eventually.
    trafficLightKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      self.repositionTrafficLightsIfNeeded()

      let now = Date().timeIntervalSince1970
      if now >= self.trafficLightKeepAliveUntil {
        self.stopTrafficLightKeepAlive()
      }
    }
    RunLoop.main.add(trafficLightKeepAliveTimer!, forMode: .common)
  }

  private func stopTrafficLightKeepAlive() {
    trafficLightKeepAliveTimer?.invalidate()
    trafficLightKeepAliveTimer = nil
    trafficLightKeepAliveUntil = 0
  }

  private func repositionTrafficLightsIfNeeded() {
    guard trafficLightDx != 0 || trafficLightDy != 0 else { return }
    guard
      let closeButton = standardWindowButton(.closeButton),
      let container = closeButton.superview
    else {
      return
    }

    // Resolve the best view in the titlebar hierarchy to move. Depending on macOS
    // version/style, moving closeButton.superview may not affect window coords.
    let target = resolveTrafficLightTarget(closeButton: closeButton, start: container)

    // If requested, break constraints so our frame adjustments can stick.
    if trafficLightForce {
      breakConstraintsAffecting(view: target)
    }

    switch trafficLightMode {
    case .absolute:
      guard let sv = target.superview else { return }
      // Place the target at an absolute inset from the top-left of its superview.
      let x = trafficLightDx
      let y: CGFloat
      if sv.isFlipped {
        y = trafficLightDy
      } else {
        // Non-flipped: origin is bottom-left; convert "dy from top" to y from bottom.
        y = sv.bounds.height - target.frame.height - trafficLightDy
      }
      target.setFrameOrigin(NSPoint(x: x, y: y))
      // Reset relative-mode state in case the mode flips back later.
      trafficLightLastAppliedOffset = nil
      trafficLightLastAdjustedOrigin = nil
      return

    case .relative:
      break
    }

    // Relative: apply a stable delta to the system-chosen origin.
    // In flipped coordinates, +y moves down; otherwise +y moves up.
    let dyInCoords = (target.superview?.isFlipped ?? true) ? trafficLightDy : -trafficLightDy
    let desiredOffset = NSPoint(x: trafficLightDx, y: dyInCoords)

    let current = target.frame.origin

    // If the container is still at the last adjusted origin, remove the last offset
    // before applying the new one. If AppKit has relaid out the titlebar (resize,
    // fullscreen changes), treat the current origin as the new base.
    var base = current
    if
      let lastOrigin = trafficLightLastAdjustedOrigin,
      let lastOffset = trafficLightLastAppliedOffset
    {
      if abs(current.x - lastOrigin.x) < 0.5 && abs(current.y - lastOrigin.y) < 0.5 {
        base = NSPoint(x: current.x - lastOffset.x, y: current.y - lastOffset.y)
      }
    }

    let newOrigin = NSPoint(x: base.x + desiredOffset.x, y: base.y + desiredOffset.y)
    target.setFrameOrigin(newOrigin)
    trafficLightLastAppliedOffset = desiredOffset
    trafficLightLastAdjustedOrigin = newOrigin
  }

  private func resolveTrafficLightTarget(closeButton: NSButton, start: NSView) -> NSView {
    if let cached = trafficLightTargetView, cached.window === self {
      return cached
    }

    let before = closeButton.convert(NSPoint(x: 0, y: 0), to: nil)

    var v: NSView? = start
    var depth = 0
    while let view = v, depth < 20 {
      guard let sv = view.superview else { break }
      let original = view.frame.origin

      // Try a tiny nudge; if the closeButton moves in window coords, this is a
      // viable target view to adjust.
      view.setFrameOrigin(NSPoint(x: original.x + 1, y: original.y))
      sv.layoutSubtreeIfNeeded()
      let after = closeButton.convert(NSPoint(x: 0, y: 0), to: nil)

      // Revert the probe.
      view.setFrameOrigin(original)
      sv.layoutSubtreeIfNeeded()

      if abs(after.x - before.x) > 0.5 || abs(after.y - before.y) > 0.5 {
        trafficLightTargetView = view
        return view
      }

      v = view.superview
      depth += 1
    }

    // Fallback: at least try moving the immediate container.
    trafficLightTargetView = start
    return start
  }

  private func breakConstraintsAffecting(view: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = true

    var host: NSView? = view.superview
    var depth = 0
    while let h = host, depth < 20 {
      for c in h.constraints {
        let involvesView = (c.firstItem as AnyObject?) === view || (c.secondItem as AnyObject?) === view
        if !involvesView { continue }
        c.isActive = false
      }
      host = h.superview
      depth += 1
    }
  }
}
