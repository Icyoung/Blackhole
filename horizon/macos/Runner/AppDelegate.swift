import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private let ptyManager = PtyManager()
  private var outputSink: FlutterEventSink?
  private var securityScopedUrls: [URL] = []
  private let bookmarkDefaultsKey = "blackhole.security.bookmarks"

  override func applicationDidFinishLaunching(_ notification: Notification) {
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else {
      return
    }

    let channel = FlutterMethodChannel(
      name: "com.blackhole/pty",
      binaryMessenger: controller.engine.binaryMessenger
    )
    let systemChannel = FlutterMethodChannel(
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
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    systemChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "SYSTEM_DEINIT", message: "AppDelegate released", details: nil))
        return
      }
      switch call.method {
      case "requestFolderAccess":
        let args = call.arguments as? [String: Any]
        let initial = args?["initialPath"] as? String
        self.requestFolderAccess(initialPath: initial) { granted in
          result(granted)
        }
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
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func requestFolderAccess(initialPath: String?, completion: @escaping (Bool) -> Void) {
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
        completion(false)
        return
      }
      guard response == .OK, let url = panel.url else {
        completion(false)
        return
      }
      if url.startAccessingSecurityScopedResource() {
        self.securityScopedUrls.append(url)
        self.saveBookmark(for: url)
        completion(true)
      } else {
        completion(false)
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
