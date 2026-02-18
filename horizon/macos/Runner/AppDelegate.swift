import Cocoa
import FlutterMacOS
import Darwin

@main
class AppDelegate: FlutterAppDelegate {
  private let ptyManager = PtyManager()
  private var outputSink: FlutterEventSink?
  private var securityScopedUrls: [URL] = []
  private let bookmarkDefaultsKey = "blackhole.security.bookmarks"
  private var statusItem: NSStatusItem?
  private var allowTerminate = false
  private var systemChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else {
      return
    }

    mainFlutterWindow?.delegate = self
    setupStatusItem()
    setupAppMenu()
    setupToolbar()

    let channel = FlutterMethodChannel(
      name: "com.blackhole/pty",
      binaryMessenger: controller.engine.binaryMessenger
    )
    systemChannel = FlutterMethodChannel(
      name: "com.blackhole/system",
      binaryMessenger: controller.engine.binaryMessenger
    )
    let outputChannel = FlutterEventChannel(
      name: "com.blackhole/pty/output",
      binaryMessenger: controller.engine.binaryMessenger
    )

    outputChannel.setStreamHandler(self)
    restoreSecurityBookmarks()

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "PTY_DEINIT", message: "PtyManager released", details: nil))
        return
      }
      switch call.method {
      case "startShell":
        let args = call.arguments as? [String: Any]
        let rows = args?["rows"] as? Int ?? 24
        let cols = args?["cols"] as? Int ?? 80
        let shellPath = args?["shellPath"] as? String
        do {
          let sessionId = try self.ptyManager.startShell(rows: rows, cols: cols, shellPath: shellPath)
          result(sessionId)
        } catch {
          result(FlutterError(code: "PTY_START", message: error.localizedDescription, details: nil))
        }
      case "writeStdin":
        let args = call.arguments as? [String: Any]
        let sessionId = args?["sessionId"] as? String ?? ""
        guard
          let data = (args?["data"] as? FlutterStandardTypedData)?.data
        else {
          result(FlutterError(code: "PTY_STDIN", message: "Missing data", details: nil))
          return
        }
        self.ptyManager.writeStdin(sessionId: sessionId, data: data)
        result(nil)
      case "resize":
        let args = call.arguments as? [String: Any]
        let sessionId = args?["sessionId"] as? String ?? ""
        let rows = args?["rows"] as? Int ?? 24
        let cols = args?["cols"] as? Int ?? 80
        self.ptyManager.resize(sessionId: sessionId, rows: rows, cols: cols)
        result(nil)
      case "kill":
        let args = call.arguments as? [String: Any]
        let sessionId = args?["sessionId"] as? String ?? ""
        self.ptyManager.kill(sessionId: sessionId)
        result(nil)
      case "getCwd":
        let args = call.arguments as? [String: Any]
        let sessionId = args?["sessionId"] as? String ?? ""
        let cwd = self.ptyManager.getCwd(sessionId: sessionId)
        result(cwd)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    systemChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "SYSTEM_DEINIT", message: "AppDelegate released", details: nil))
        return
      }
      switch call.method {
      case "requestFolderAccess":
        let args = call.arguments as? [String: Any]
        let initial = args?["initialPath"] as? String
        self.requestFolderAccess(initialPath: initial) { granted in
          if let path = granted {
            result(["granted": true, "path": path])
          } else {
            result(["granted": false])
          }
        }
      case "multiWindowChanged":
        result(nil)
      case "openSettings":
        self.openSettingsWindow()
        result(nil)
      case "settingsChanged":
        self.restartDaemonIfNeeded()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    ptyManager.outputHandler = { [weak self] sessionId, data in
      guard let self = self else { return }
      let payload: [String: Any] = [
        "sessionId": sessionId,
        "data": FlutterStandardTypedData(bytes: data),
      ]
      self.outputSink?(payload)
    }

    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showMainWindow()
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func setupAppMenu() {
    // Find and update the Settings/Preferences menu item in the app menu
    guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return }

    var foundSettings = false
    for item in appMenu.items {
      // Look for Preferences or Settings menu item (handles both "..." and "…")
      let title = item.title.lowercased()
      if title.contains("preferences") || title.contains("settings") {
        item.target = self
        item.action = #selector(openPreferences(_:))
        foundSettings = true
      }
    }

    // Only add if no existing settings item was found
    if !foundSettings {
      let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openPreferences(_:)), keyEquivalent: ",")
      settingsItem.target = self
      settingsItem.keyEquivalentModifierMask = .command

      // Insert after About (usually index 0) and separator (index 1)
      if appMenu.items.count > 2 {
        appMenu.insertItem(settingsItem, at: 2)
        appMenu.insertItem(NSMenuItem.separator(), at: 3)
      } else {
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(settingsItem)
      }
    }
  }

  @IBAction func openPreferences(_ sender: Any?) {
    openSettingsWindow()
  }

  private func setupToolbar() {
    guard let window = mainFlutterWindow else { return }

    // Required for immersive titlebar; also helps avoid 1px/light borders around content.
    window.styleMask.insert(.fullSizeContentView)

    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    if #available(macOS 11.0, *) {
      window.titlebarSeparatorStyle = .none
    }
    // Match tab bar background color #202124
    window.backgroundColor = NSColor(calibratedRed: 0.125, green: 0.129, blue: 0.141, alpha: 1.0)
    window.isOpaque = true
    window.contentView?.wantsLayer = true
    window.contentView?.layer?.backgroundColor = window.backgroundColor?.cgColor
    window.contentView?.superview?.wantsLayer = true
    window.contentView?.superview?.layer?.backgroundColor = window.backgroundColor?.cgColor

    // Immersive titlebar: nudge traffic-light buttons a bit down/right so they
    // don't feel glued to the window edge when Flutter draws under the titlebar.
    let dxEnv = ProcessInfo.processInfo.environment["BLACKHOLE_TRAFFIC_LIGHT_DX"].flatMap { Double($0) }
    let dyEnv = ProcessInfo.processInfo.environment["BLACKHOLE_TRAFFIC_LIGHT_DY"].flatMap { Double($0) }
    let dx = CGFloat(dxEnv ?? 10)
    let dy = CGFloat(dyEnv ?? 8)
    let modeStr = (ProcessInfo.processInfo.environment["BLACKHOLE_TRAFFIC_LIGHT_MODE"] ?? "relative").lowercased()
    let mode: MainFlutterWindow.TrafficLightMode = (modeStr == "absolute") ? .absolute : .relative

    if let w = window as? MainFlutterWindow {
      w.setTrafficLightOffset(dx: dx, dy: dy, mode: mode)
    } else {
      installTrafficLightAdjuster(for: window, dx: dx, dy: dy)
    }

    // Multi-window toggle is now in the Flutter tab bar
    setupWindowMenu()
  }

  // Keep original constraint constants so repeated apply() does not accumulate.
  private var trafficLightBaseConstraintConstants: [ObjectIdentifier: CGFloat] = [:]
  // Some titlebar constraints move in the opposite direction (e.g. trailing/bottom).
  // Cache the inferred multiplier so we don't "probe" on every apply().
  private var trafficLightConstraintXMultiplier: [ObjectIdentifier: CGFloat] = [:]
  private var trafficLightConstraintYMultiplier: [ObjectIdentifier: CGFloat] = [:]
  // For the frame-based fallback, keep a base origin so repeated apply() is idempotent.
  private var trafficLightBaseViewOrigins: [ObjectIdentifier: NSPoint] = [:]

  private func installTrafficLightAdjuster(for window: NSWindow, dx: CGFloat, dy: CGFloat) {
    // Apply once after layout and keep re-applying on resize/fullscreen changes,
    // because AppKit may reset standardWindowButton frames.
    func apply() {
      // Let AppKit lay out the titlebar views first, then adjust.
      window.contentView?.superview?.layoutSubtreeIfNeeded()
      adjustTrafficLights(window: window, dx: dx, dy: dy)
    }

    DispatchQueue.main.async { apply() }

    NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification,
      object: window,
      queue: .main
    ) { _ in
      apply()
    }
    NotificationCenter.default.addObserver(
      forName: NSWindow.didExitFullScreenNotification,
      object: window,
      queue: .main
    ) { _ in
      self.resetTrafficLightAdjustmentCaches()
      apply()
    }
    NotificationCenter.default.addObserver(
      forName: NSWindow.didEnterFullScreenNotification,
      object: window,
      queue: .main
    ) { _ in
      self.resetTrafficLightAdjustmentCaches()
      apply()
    }
  }

  private func adjustTrafficLights(window: NSWindow, dx: CGFloat, dy: CGFloat) {
    // On newer macOS versions the traffic lights are embedded in a titlebar view
    // hierarchy (often a stack view). Shifting the right view in that hierarchy
    // is more reliable than fighting individual button frames.
    if adjustTrafficLightHierarchy(window: window, dx: dx, dy: dy) {
      return
    }

    let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    for type in buttons {
      guard let button = window.standardWindowButton(type) else { continue }

      // Prefer adjusting AutoLayout constraints; AppKit often overwrites manual frames.
      if adjustViewPosition(view: button, dx: dx, dy: dy) {
        continue
      }
    }
  }

  private func resetTrafficLightAdjustmentCaches() {
    trafficLightBaseConstraintConstants.removeAll()
    trafficLightConstraintXMultiplier.removeAll()
    trafficLightConstraintYMultiplier.removeAll()
    trafficLightBaseViewOrigins.removeAll()
  }

  private func adjustTrafficLightHierarchy(window: NSWindow, dx: CGFloat, dy: CGFloat) -> Bool {
    guard
      let closeButton = window.standardWindowButton(.closeButton)
    else {
      return false
    }

    let debugTrafficLights = ProcessInfo.processInfo.environment["BLACKHOLE_DEBUG_TRAFFIC_LIGHTS"] == "1"
    let forceTrafficLights = ProcessInfo.processInfo.environment["BLACKHOLE_FORCE_TRAFFIC_LIGHTS"] == "1"

    let before = closeButton.convert(NSPoint(x: 0, y: 0), to: nil)
    if debugTrafficLights {
      NSLog("TrafficLights: before closeButton origin in window coords = (%.2f, %.2f)", before.x, before.y)
    }

    if forceTrafficLights {
      if debugTrafficLights {
        NSLog("TrafficLights: force mode enabled")
      }
      _ = forceMoveTrafficLightContainer(window: window, dx: dx, dy: dy, debug: debugTrafficLights)
      window.contentView?.superview?.layoutSubtreeIfNeeded()
      let after = closeButton.convert(NSPoint(x: 0, y: 0), to: nil)
      if abs(after.x - before.x) > 0.5 || abs(after.y - before.y) > 0.5 {
        if debugTrafficLights {
          NSLog("TrafficLights: force moved by (%.2f, %.2f)", after.x - before.x, after.y - before.y)
        }
        return true
      }
      if debugTrafficLights {
        NSLog("TrafficLights: force mode did not move (continuing with normal attempts)")
      }
    }

    // Try moving superviews up the chain until the close button actually moves.
    var v: NSView? = closeButton.superview
    var depth = 0
    while let view = v, depth < 20 {
      if debugTrafficLights {
        let cls = NSStringFromClass(type(of: view))
        NSLog(
          "TrafficLights: try depth=%d view=%@ flipped=%d frame=(%.2f, %.2f, %.2f, %.2f)",
          depth,
          cls,
          view.isFlipped ? 1 : 0,
          view.frame.origin.x,
          view.frame.origin.y,
          view.frame.size.width,
          view.frame.size.height
        )
      }
      _ = adjustViewPosition(view: view, dx: dx, dy: dy)
      window.contentView?.superview?.layoutSubtreeIfNeeded()

      let after = closeButton.convert(NSPoint(x: 0, y: 0), to: nil)
      if debugTrafficLights {
        NSLog("TrafficLights: after closeButton origin in window coords = (%.2f, %.2f)", after.x, after.y)
      }
      if abs(after.x - before.x) > 0.5 || abs(after.y - before.y) > 0.5 {
        if debugTrafficLights {
          NSLog(
            "TrafficLights: moved by (%.2f, %.2f) at depth=%d",
            after.x - before.x,
            after.y - before.y,
            depth
          )
        }
        return true
      }

      v = view.superview
      depth += 1
    }

    if debugTrafficLights {
      NSLog("TrafficLights: no movement detected in hierarchy (depth limit reached)")
    }
    return false
  }

  private func forceMoveTrafficLightContainer(window: NSWindow, dx: CGFloat, dy: CGFloat, debug: Bool) -> Bool {
    guard
      let closeButton = window.standardWindowButton(.closeButton),
      let container = closeButton.superview,
      let containerSuperview = container.superview
    else {
      return false
    }

    // Disable AutoLayout constraints that pin the container, so frame changes stick.
    var host: NSView? = containerSuperview
    var depth = 0
    while let h = host, depth < 20 {
      for c in h.constraints {
        let involvesContainer = (c.firstItem as AnyObject?) === container || (c.secondItem as AnyObject?) === container
        if !involvesContainer { continue }
        if debug {
          let cls = NSStringFromClass(type(of: h))
          NSLog(
            "TrafficLights: deactivating constraint on host=%@ first=%ld second=%ld const=%.2f",
            cls,
            c.firstAttribute.rawValue,
            c.secondAttribute.rawValue,
            c.constant
          )
        }
        c.isActive = false
      }
      host = h.superview
      depth += 1
    }

    container.translatesAutoresizingMaskIntoConstraints = true

    // Make frame updates idempotent.
    let key = ObjectIdentifier(container)
    let base = trafficLightBaseViewOrigins[key] ?? container.frame.origin
    trafficLightBaseViewOrigins[key] = base

    let newOrigin = NSPoint(
      x: base.x + dx,
      y: base.y + (containerSuperview.isFlipped ? dy : -dy)
    )
    if debug {
      let cls = NSStringFromClass(type(of: container))
      NSLog(
        "TrafficLights: force setFrameOrigin container=%@ base=(%.2f, %.2f) new=(%.2f, %.2f) flipped=%d",
        cls,
        base.x,
        base.y,
        newOrigin.x,
        newOrigin.y,
        containerSuperview.isFlipped ? 1 : 0
      )
    }
    container.setFrameOrigin(newOrigin)
    return true
  }

  private func adjustViewPosition(view: NSView, dx: CGFloat, dy: CGFloat) -> Bool {
    // 1) Prefer constraints (stable under AppKit relayout).
    if adjustConstraintsAffectingView(view: view, dx: dx, dy: dy) {
      return true
    }

    // 2) Fallback to frame tweak (may be overwritten, but better than nothing).
    guard let superview = view.superview else { return false }
    let key = ObjectIdentifier(view)
    let base = trafficLightBaseViewOrigins[key] ?? view.frame.origin
    trafficLightBaseViewOrigins[key] = base

    let newOrigin = NSPoint(
      x: base.x + dx,
      y: base.y + (superview.isFlipped ? dy : -dy)
    )
    view.setFrameOrigin(newOrigin)
    return true
  }

  private func adjustConstraintsAffectingView(view: NSView, dx: CGFloat, dy: CGFloat) -> Bool {
    var adjusted = false

    // Constraints are usually installed on the closest common ancestor, not
    // necessarily the immediate superview.
    var host: NSView? = view
    var depth = 0
    while let h = host, depth < 20 {
      for c in h.constraints {
        let involvesView = (c.firstItem as AnyObject?) === view || (c.secondItem as AnyObject?) === view
        if !involvesView { continue }

        // X-axis position constraints.
        if isXPositionConstraint(c) {
          let key = ObjectIdentifier(c)
          let base = trafficLightBaseConstraintConstants[key] ?? c.constant
          trafficLightBaseConstraintConstants[key] = base
          if let mul = inferXMultiplierIfNeeded(constraint: c, host: h, view: view, base: base) {
            c.constant = base + (mul * dx)
            adjusted = true
          }
        }

        // Y-axis position constraints.
        if isYPositionConstraint(c) {
          let key = ObjectIdentifier(c)
          let base = trafficLightBaseConstraintConstants[key] ?? c.constant
          trafficLightBaseConstraintConstants[key] = base
          if let mul = inferYMultiplierIfNeeded(constraint: c, host: h, view: view, base: base) {
            c.constant = base + (mul * dy)
            adjusted = true
          }
        }
      }

      host = h.superview
      depth += 1
    }

    if adjusted {
      view.superview?.layoutSubtreeIfNeeded()
    }
    return adjusted
  }

  private func isXPositionConstraint(_ c: NSLayoutConstraint) -> Bool {
    return c.firstAttribute == .leading
      || c.secondAttribute == .leading
      || c.firstAttribute == .left
      || c.secondAttribute == .left
      || c.firstAttribute == .trailing
      || c.secondAttribute == .trailing
      || c.firstAttribute == .right
      || c.secondAttribute == .right
      || c.firstAttribute == .centerX
      || c.secondAttribute == .centerX
  }

  private func isYPositionConstraint(_ c: NSLayoutConstraint) -> Bool {
    return c.firstAttribute == .top
      || c.secondAttribute == .top
      || c.firstAttribute == .bottom
      || c.secondAttribute == .bottom
      || c.firstAttribute == .centerY
      || c.secondAttribute == .centerY
  }

  // Returns +1 or -1 if the constraint actually moves the view in X; nil if it doesn't.
  private func inferXMultiplierIfNeeded(
    constraint c: NSLayoutConstraint,
    host: NSView,
    view: NSView,
    base: CGFloat
  ) -> CGFloat? {
    let key = ObjectIdentifier(c)
    if let cached = trafficLightConstraintXMultiplier[key] {
      return cached == 0 ? nil : cached
    }

    let before = view.frame.origin.x
    c.constant = base + 1
    host.layoutSubtreeIfNeeded()
    let after = view.frame.origin.x
    c.constant = base
    host.layoutSubtreeIfNeeded()

    let delta = after - before
    if abs(delta) < 0.1 {
      trafficLightConstraintXMultiplier[key] = 0
      return nil
    }
    let mul: CGFloat = delta > 0 ? 1 : -1
    trafficLightConstraintXMultiplier[key] = mul
    return mul
  }

  // Returns +1 or -1 if the constraint actually moves the view in Y; nil if it doesn't.
  // Convention: positive dy should move the view *down* visually.
  private func inferYMultiplierIfNeeded(
    constraint c: NSLayoutConstraint,
    host: NSView,
    view: NSView,
    base: CGFloat
  ) -> CGFloat? {
    let key = ObjectIdentifier(c)
    if let cached = trafficLightConstraintYMultiplier[key] {
      return cached == 0 ? nil : cached
    }

    let before = view.frame.origin.y
    c.constant = base + 1
    host.layoutSubtreeIfNeeded()
    let after = view.frame.origin.y
    c.constant = base
    host.layoutSubtreeIfNeeded()

    let delta = after - before
    if abs(delta) < 0.1 {
      trafficLightConstraintYMultiplier[key] = 0
      return nil
    }

    // If increasing constant increased origin.y, in a non-flipped coordinate system
    // that means "up". We want dy>0 to mean "down", so pick the multiplier based on flipping.
    // In flipped coordinates, increasing origin.y is down; in non-flipped it's up.
    let constantMovesDown = host.isFlipped ? (delta > 0) : (delta < 0)
    let mul: CGFloat = constantMovesDown ? 1 : -1
    trafficLightConstraintYMultiplier[key] = mul
    return mul
  }

  private func setupWindowMenu() {
    guard let windowMenu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu else { return }

    let multiWindowItem = NSMenuItem(
      title: "Toggle Multi-Window",
      action: #selector(toggleMultiWindow(_:)),
      keyEquivalent: "m"
    )
    multiWindowItem.target = self
    multiWindowItem.keyEquivalentModifierMask = [.command, .shift]

    // Insert at the beginning of Window menu
    windowMenu.insertItem(multiWindowItem, at: 0)
    windowMenu.insertItem(NSMenuItem.separator(), at: 1)
  }

  @objc private func toggleMultiWindow(_ sender: Any?) {
    systemChannel?.invokeMethod("toggleMultiWindow", arguments: nil)
  }

  private func setupStatusItem() {
    if statusItem != nil {
      return
    }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      if #available(macOS 11.0, *) {
        button.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Horizon")
      } else {
        button.title = "H"
      }
      button.action = #selector(onStatusItemClicked(_:))
      button.target = self
    }

    let menu = NSMenu()

    let showItem = NSMenuItem(title: "Show Horizon", action: #selector(showFromStatusItem(_:)), keyEquivalent: "")
    showItem.target = self
    menu.addItem(showItem)

    menu.addItem(NSMenuItem.separator())

    let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsFromStatusItem(_:)), keyEquivalent: ",")
    settingsItem.target = self
    menu.addItem(settingsItem)

    menu.addItem(NSMenuItem.separator())

    let quitItem = NSMenuItem(title: "Quit", action: #selector(quitFromStatusItem(_:)), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)

    item.menu = menu
    statusItem = item
  }

  @objc private func onStatusItemClicked(_ sender: Any?) {
    // With a menu set, AppKit handles showing the menu automatically.
  }

  private func showMainWindow() {
    guard let window = mainFlutterWindow else {
      return
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func showFromStatusItem(_ sender: Any?) {
    showMainWindow()
  }

  @objc private func openSettingsFromStatusItem(_ sender: Any?) {
    openSettingsWindow()
  }

  private func openSettingsWindow() {
    // Send message to Flutter to open settings page
    systemChannel?.invokeMethod("openSettings", arguments: nil)
    showMainWindow()
  }

  @objc private func quitFromStatusItem(_ sender: Any?) {
    stopDaemonIfRunning()
    allowTerminate = true
    NSApp.terminate(nil)
  }

  override func applicationWillTerminate(_ notification: Notification) {
    stopDaemonIfRunning()
  }

  private func stopDaemonIfRunning() {
    let pidUrl = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".blackhole")
      .appendingPathComponent("horizon")
      .appendingPathComponent("daemon.pid")

    guard let pidText = try? String(contentsOf: pidUrl, encoding: .utf8) else {
      return
    }
    let trimmed = pidText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = Int32(trimmed), pid > 0 else {
      return
    }
    _ = kill(pid, SIGTERM)
  }

  private func restartDaemonIfNeeded() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let pidUrl = home.appendingPathComponent(".blackhole/horizon/daemon.pid")

    guard let pidText = try? String(contentsOf: pidUrl, encoding: .utf8) else {
      return
    }
    let trimmed = pidText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = Int32(trimmed), pid > 0 else {
      return
    }
    _ = kill(pid, SIGHUP)
  }

  private func requestFolderAccess(initialPath: String?, completion: @escaping (String?) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Grant Access"
    if let initialPath = initialPath {
      panel.directoryURL = URL(fileURLWithPath: initialPath, isDirectory: true)
    }

    panel.begin { [weak self] response in
      guard let self = self else {
        completion(nil)
        return
      }
      guard response == .OK, let url = panel.url else {
        completion(nil)
        return
      }
      if url.startAccessingSecurityScopedResource() {
        self.securityScopedUrls.append(url)
        self.saveBookmark(for: url)
        // Also save to JSON file for Flutter side to read
        self.saveFolderToBookmarksFile(path: url.path)
        completion(url.path)
      } else {
        completion(nil)
      }
    }
  }

  private func saveBookmark(for url: URL) {
    do {
      let bookmark = try url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      var saved = UserDefaults.standard.array(forKey: bookmarkDefaultsKey) as? [Data] ?? []
      saved.append(bookmark)
      UserDefaults.standard.set(saved, forKey: bookmarkDefaultsKey)
    } catch {
      NSLog("Failed to save security bookmark: %@", error.localizedDescription)
    }
  }

  private func saveFolderToBookmarksFile(path: String) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let bookmarksPath = home.appendingPathComponent(".blackhole/horizon/folder_bookmarks.json")

    do {
      // Create directory if it doesn't exist
      let dir = bookmarksPath.deletingLastPathComponent()
      if !FileManager.default.fileExists(atPath: dir.path) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
      }

      // Read existing bookmarks or create new structure
      var bookmarks: [[String: String]] = []
      if FileManager.default.fileExists(atPath: bookmarksPath.path) {
        let data = try Data(contentsOf: bookmarksPath)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let existingBookmarks = json["bookmarks"] as? [[String: String]] {
          bookmarks = existingBookmarks
        }
      }

      // Check if path already exists
      let alreadyExists = bookmarks.contains { $0["path"] == path }
      if !alreadyExists {
        bookmarks.append(["path": path])
      }

      // Save updated bookmarks
      let json: [String: Any] = [
        "version": 1,
        "bookmarks": bookmarks
      ]

      let jsonData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
      try jsonData.write(to: bookmarksPath)

      NSLog("Saved folder bookmark to JSON: %@", path)
    } catch {
      NSLog("Failed to save folder to bookmarks file: %@", error.localizedDescription)
    }
  }

  private func restoreSecurityBookmarks() {
    let saved = UserDefaults.standard.array(forKey: bookmarkDefaultsKey) as? [Data] ?? []
    for data in saved {
      var stale = false
      do {
        let url = try URL(
          resolvingBookmarkData: data,
          options: .withSecurityScope,
          relativeTo: nil,
          bookmarkDataIsStale: &stale
        )
        if url.startAccessingSecurityScopedResource() {
          securityScopedUrls.append(url)
        }
      } catch {
        NSLog("Failed to restore security bookmark: %@", error.localizedDescription)
      }
    }
  }
}

extension AppDelegate: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    outputSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    outputSink = nil
    return nil
  }
}

extension AppDelegate: NSWindowDelegate {
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if allowTerminate {
      return true
    }
    sender.orderOut(nil)
    return false
  }
}
