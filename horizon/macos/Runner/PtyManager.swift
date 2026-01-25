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

  func startShell(rows: Int, cols: Int, shellPath: String?) throws -> String {
    var masterFd: Int32 = 0
    var win = winsize(
      ws_row: UInt16(rows),
      ws_col: UInt16(cols),
      ws_xpixel: 0,
      ws_ypixel: 0
    )

    let pid = forkpty(&masterFd, nil, nil, &win)
    if pid < 0 {
      throw NSError(domain: "PtyManager", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "forkpty failed"
      ])
    }

    if pid == 0 {
      let shell = shellPath ?? "/bin/zsh"
      let home = NSHomeDirectory()
      _ = home.withCString { chdir($0) }

      // Set essential environment variables for interactive programs
      setenv("TERM", "xterm-256color", 1)
      setenv("COLORTERM", "truecolor", 1)
      setenv("LANG", "en_US.UTF-8", 1)

      guard let shellCString = strdup(shell) else {
        _exit(1)
      }
      var args: [UnsafeMutablePointer<CChar>?] = [
        shellCString,
        strdup("-i"),
        strdup("-l"),
        nil
      ]
      execv(shellCString, &args)
      free(shellCString)
      for arg in args {
        if let arg = arg {
          free(arg)
        }
      }
      _exit(1)
    }

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
      if let baseAddress = rawBuffer.baseAddress {
        _ = write(session.masterFd, baseAddress, data.count)
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
