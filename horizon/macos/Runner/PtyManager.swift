import Foundation
import Darwin

final class PtyManager {
  struct Session {
    let id: String
    let masterFd: Int32
    let childPid: pid_t
    let readSource: DispatchSourceRead
  }

  private var sessions: [String: Session] = [:]
  var outputHandler: ((String, Data) -> Void)?

  func startShell(rows: Int, cols: Int, shellPath: String?, cwd: String?) throws -> String {
    var masterFd: Int32 = 0
    var win = winsize(
      ws_row: UInt16(rows),
      ws_col: UInt16(cols),
      ws_xpixel: 0,
      ws_ypixel: 0
    )

    // Resolve all values BEFORE fork — Foundation/Swift calls are not safe after fork()
    let shell = shellPath ?? "/bin/zsh"

    let homeDir: String = {
      // Prefer getpwuid (POSIX, reliable) over NSHomeDirectory (may return sandbox path)
      if let pw = getpwuid(getuid()) {
        return String(cString: pw.pointee.pw_dir)
      }
      let h = NSHomeDirectory()
      if !h.isEmpty && h != "/" { return h }
      return "/Users/\(NSUserName())"
    }()

    let userName: String = {
      if let pw = getpwuid(getuid()) {
        return String(cString: pw.pointee.pw_name)
      }
      return NSUserName()
    }()

    // Bootstrap PATH: GUI apps inherit minimal PATH from launchd (/usr/bin:/bin:/usr/sbin:/sbin).
    // Profile scripts (e.g. .zshrc) need tools like rbenv/brew to already be reachable.
    let bootstrapPath: String = {
      let extra = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
      if let cur = ProcessInfo.processInfo.environment["PATH"], !cur.isEmpty {
        if cur.contains("/opt/homebrew/bin") { return cur }
        return "\(extra):\(cur)"
      }
      return "\(extra):/usr/bin:/bin:/usr/sbin:/sbin"
    }()

    // Pre-allocate C strings so the child process only uses POSIX calls
    let cHome  = strdup(homeDir)
    let cShell = strdup(shell)
    let cPath  = strdup(bootstrapPath)
    let cUser  = strdup(userName)
    // Shell command: cd to target directory, then exec interactive login shell
    let cdTarget = cwd ?? ""
    let cCdExec: UnsafeMutablePointer<CChar>?
    if cdTarget.isEmpty {
      cCdExec = strdup("cd && exec \(shell) -il")
    } else {
      let escaped = cdTarget.replacingOccurrences(of: "'", with: "'\\''")
      cCdExec = strdup("cd '\(escaped)' && exec \(shell) -il")
    }

    let pid = forkpty(&masterFd, nil, nil, &win)
    if pid < 0 {
      free(cHome); free(cShell); free(cPath); free(cUser); free(cCdExec)
      throw NSError(domain: "PtyManager", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "forkpty failed"
      ])
    }

    if pid == 0 {
      // ── Child process — only POSIX/C calls from here ──

      // Set identity & home
      if let h = cHome {
        setenv("HOME", h, 1)
      }
      if let u = cUser {
        setenv("USER", u, 1)
        setenv("LOGNAME", u, 1)
      }
      if let s = cShell { setenv("SHELL", s, 1) }
      if let p = cPath  { setenv("PATH", p, 1) }

      // Terminal environment
      setenv("TERM", "xterm-256color", 1)
      setenv("COLORTERM", "truecolor", 1)
      setenv("LANG", "en_US.UTF-8", 1)

      // Clean up inherited env that interferes with nested tools
      unsetenv("CLAUDECODE")

      // Use shell -c "cd && exec shell -il" so the shell itself handles
      // changing to $HOME before starting the interactive login session.
      var args: [UnsafeMutablePointer<CChar>?] = [
        cShell,
        strdup("-c"),
        cCdExec,
        nil
      ]
      execv(cShell!, &args)
      _exit(1)
    }

    // Parent — free pre-allocated C strings
    free(cHome); free(cShell); free(cPath); free(cUser); free(cCdExec)

    let flags = fcntl(masterFd, F_GETFL)
    _ = fcntl(masterFd, F_SETFL, flags | O_NONBLOCK)

    let sessionId = UUID().uuidString
    let source = DispatchSource.makeReadSource(fileDescriptor: masterFd, queue: DispatchQueue.global())
    source.setEventHandler { [weak self] in
      var buffer = [UInt8](repeating: 0, count: 16384)
      let n = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
        guard let baseAddress = rawBuffer.baseAddress else {
          return -1
        }
        return read(masterFd, baseAddress, rawBuffer.count)
      }
      if n > 0 {
        let output = Data(buffer.prefix(n))
        DispatchQueue.main.async {
          self?.outputHandler?(sessionId, output)
        }
      } else if n == 0 || (n < 0 && errno != EAGAIN) {
        source.cancel()
      }
    }
    source.setCancelHandler {
      close(masterFd)
    }
    source.resume()

    let session = Session(id: sessionId, masterFd: masterFd, childPid: pid, readSource: source)
    sessions[sessionId] = session
    return sessionId
  }

  func writeStdin(sessionId: String, data: Data) {
    guard let session = sessions[sessionId] else {
      return
    }
    data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var totalWritten = 0
      let totalBytes = data.count
      while totalWritten < totalBytes {
        let bytesWritten = write(
          session.masterFd,
          baseAddress.advanced(by: totalWritten),
          totalBytes - totalWritten
        )
        if bytesWritten < 0 {
          let err = errno
          if err == EAGAIN || err == EWOULDBLOCK {
            // Buffer full, wait a bit and retry
            usleep(1000)  // 1ms
            continue
          }
          // Actual error - stop writing
          break
        }
        totalWritten += bytesWritten
      }
    }
  }

  func resize(sessionId: String, rows: Int, cols: Int) {
    guard let session = sessions[sessionId] else {
      return
    }
    var win = winsize(
      ws_row: UInt16(rows),
      ws_col: UInt16(cols),
      ws_xpixel: 0,
      ws_ypixel: 0
    )
    ioctl(session.masterFd, TIOCSWINSZ, &win)
  }

  func kill(sessionId: String) {
    guard let session = sessions.removeValue(forKey: sessionId) else {
      return
    }
    session.readSource.cancel()
    _ = Darwin.kill(session.childPid, SIGTERM)
  }

  func getCwd(sessionId: String) -> String? {
    guard let session = sessions[sessionId] else {
      return nil
    }
    // Get the foreground process group of the terminal
    var fgPid = tcgetpgrp(session.masterFd)
    if fgPid < 0 {
      fgPid = session.childPid
    }

    // Use proc_pidinfo to get the current working directory
    var pathInfo = proc_vnodepathinfo()
    let pathInfoSize = MemoryLayout<proc_vnodepathinfo>.size
    let result = proc_pidinfo(fgPid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, Int32(pathInfoSize))

    if result == pathInfoSize {
      return withUnsafePointer(to: pathInfo.pvi_cdir.vip_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { charPtr in
          String(cString: charPtr)
        }
      }
    }
    return nil
  }
}
