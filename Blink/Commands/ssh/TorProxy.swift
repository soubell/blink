////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2019 Blink Mobile Shell Project
//
// This file is part of Blink.
//
// Blink is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Blink is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Blink. If not, see <http://www.gnu.org/licenses/>.
//
// In addition, Blink is also subject to certain additional terms under
// GNU GPL version 3 section 7.
//
// You should have received a copy of these additional terms immediately
// following the terms and conditions of the GNU General Public License
// which accompanied the Blink Source Code. If not, see
// <http://www.github.com/blinksh/blink>.
//
////////////////////////////////////////////////////////////////////////////////

// Tor support for SSH (blink-tor).
//
// Setting a host's ProxyCommand to the magic string
//
//   tor %h %p
//
// routes that host's SSH connection through an embedded Tor client
// (Tor.framework / CTor), with no VPN configuration involved.
// The interception happens in BlinkSSH.executeProxyCommand; this file
// holds the command parser, the Tor lifecycle service and the pipe
// that bridges libssh's socketpair to Tor's SOCKS5 port.
//
// Fail-closed: any failure (Tor not ready, SOCKS error, bad magic
// string) aborts the connection. There is never a direct fallback.

import Foundation
import Darwin
import CTor


// MARK: - Magic ProxyCommand parsing

struct TorCommand {
  let host: String
  let port: Int

  /// Tokens of a ProxyCommand string, with libssh's "exec " prefix removed.
  private static func tokens(of command: String) -> [String] {
    var cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
    if cmd.hasPrefix("exec ") {
      cmd = String(cmd.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }
    return shellTokenize(cmd)
  }

  /// Whether a ProxyCommand string (from config or from libssh's callback)
  /// is the Tor magic string. Config values still carry the unexpanded
  /// `%h %p` placeholders, so this only checks the leading `tor` token.
  static func isMagic(_ proxyCommand: String?) -> Bool {
    guard let proxyCommand = proxyCommand else {
      return false
    }
    return tokens(of: proxyCommand).first == "tor"
  }

  /// Parse a command as delivered by libssh's proxy callback, where
  /// `%h` / `%p` are expected to be already expanded to the real
  /// destination. Returns nil for anything that is not a well-formed
  /// `tor <host> <port>` (including unexpanded placeholders).
  static func parse(_ command: String) -> TorCommand? {
    let tokens = tokens(of: command)
    guard tokens.count == 3, tokens[0] == "tor" else {
      return nil
    }
    let host = tokens[1]
    guard !host.isEmpty, !host.hasPrefix("%"),
          let port = Int(tokens[2]), (1...65535).contains(port)
    else {
      return nil
    }
    return TorCommand(host: host, port: port)
  }
}


// MARK: - Tor lifecycle

final class TorService {
  static let shared = TorService()

  enum ServiceError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
      switch self {
      case .message(let message):
        return message
      }
    }
  }

  private let lock = NSLock()
  private var socksEndpoint: (host: String, port: Int)?
  private var starting = false
  private var startError: Error?

  private var torThread: TorThread?
  private var torController: TorController?
  private var torConf: TorConfiguration?

  private init() {}

  /// Returns Tor's SOCKS endpoint, starting Tor on first use and
  /// blocking the calling thread until the bootstrap completes.
  /// Tor then stays resident for the lifetime of the app, so later
  /// calls return immediately. Safe to call from several threads:
  /// concurrent callers wait for the one start attempt to finish.
  func socks(progress: @escaping (String) -> Void,
             timeout: TimeInterval = 120) throws -> (host: String, port: Int) {
    lock.lock()
    if let endpoint = socksEndpoint {
      lock.unlock()
      return endpoint
    }
    if starting {
      // Another connection is starting Tor. Wait for its outcome.
      lock.unlock()
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.25)
        lock.lock()
        if let endpoint = socksEndpoint {
          lock.unlock()
          return endpoint
        }
        if !starting {
          let error = startError
          lock.unlock()
          throw error ?? ServiceError.message("Tor failed to start")
        }
        lock.unlock()
      }
      throw ServiceError.message("Timed out waiting for Tor to start")
    }
    starting = true
    startError = nil
    lock.unlock()

    do {
      let endpoint = try startTor(progress: progress, timeout: timeout)
      lock.lock()
      socksEndpoint = endpoint
      starting = false
      lock.unlock()
      return endpoint
    } catch {
      stopTor()
      lock.lock()
      starting = false
      startError = error
      lock.unlock()
      throw error
    }
  }

  private func startTor(progress: @escaping (String) -> Void,
                        timeout: TimeInterval) throws -> (host: String, port: Int) {
    let fileManager = FileManager.default
    guard let libraryDir = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else {
      throw ServiceError.message("No Library directory")
    }
    let dataDirectory = libraryDir.appendingPathComponent("tor", isDirectory: true)
    try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

    let conf = TorConfiguration()
    conf.ignoreMissingTorrc = true
    conf.cookieAuthentication = true
    conf.autoControlPort = true
    conf.clientOnly = true
    conf.avoidDiskWrites = true
    conf.dataDirectory = dataDirectory
    // Bridges are out of scope for v1; the transport stays off.
    conf.options = [
      "SocksPort": "auto",
      "UseBridges": "0",
      "Log": "err file /dev/null",
      "SafeLogging": "1",
    ]

    let thread = TorThread(configuration: conf)
    thread.start()
    torConf = conf
    torThread = thread

    // Give Tor a moment to write its control port file.
    Thread.sleep(forTimeInterval: 0.65)

    guard let controlPortFile = conf.controlPortFile else {
      throw ServiceError.message("Tor did not provide a control port file")
    }
    let controller = TorController(controlPortFile: controlPortFile)

    var connectError: Error?
    for _ in 0..<40 {
      do {
        try controller.connect()
        connectError = nil
        break
      } catch {
        connectError = error
        Thread.sleep(forTimeInterval: 0.25)
      }
    }
    if let connectError = connectError {
      throw connectError
    }
    torController = controller

    var cookie: Data?
    for _ in 0..<40 {
      if let data = conf.cookie {
        cookie = data
        break
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
    guard let cookie = cookie else {
      throw ServiceError.message("Tor authentication cookie is unreadable")
    }

    let authSemaphore = DispatchSemaphore(value: 0)
    var authError: Error?
    controller.authenticate(with: cookie) { success, error in
      if !success {
        authError = error ?? ServiceError.message("Tor control authentication failed")
      }
      authSemaphore.signal()
    }
    if authSemaphore.wait(timeout: .now() + 15) == .timedOut {
      throw ServiceError.message("Tor control authentication timed out")
    }
    if let authError = authError {
      throw authError
    }

    let progressToken = controller.addObserver(forStatusEvents: { type, _, action, arguments in
      if type == "STATUS_CLIENT" && action == "BOOTSTRAP" {
        if let value = arguments?["PROGRESS"] {
          progress("bootstrap \(value)%")
        }
        return true
      }
      return false
    })
    let establishedSemaphore = DispatchSemaphore(value: 0)
    let establishedToken = controller.addObserver(forCircuitEstablished: { established in
      if established {
        establishedSemaphore.signal()
      }
    })
    let waitResult = establishedSemaphore.wait(timeout: .now() + timeout)
    controller.removeObserver(establishedToken)
    controller.removeObserver(progressToken)
    if waitResult == .timedOut {
      throw ServiceError.message("Tor bootstrap timed out")
    }

    let socksSemaphore = DispatchSemaphore(value: 0)
    var endpoint: (host: String, port: Int)?
    var socksError: Error?
    controller.getSocks5Address { host, port, error in
      if let host = host, let port = port {
        endpoint = (host, port.intValue)
      } else {
        socksError = error ?? ServiceError.message("Tor did not report a SOCKS address")
      }
      socksSemaphore.signal()
    }
    if socksSemaphore.wait(timeout: .now() + 15) == .timedOut {
      throw ServiceError.message("Timed out asking Tor for its SOCKS address")
    }
    if let socksError = socksError {
      throw socksError
    }
    guard let endpoint = endpoint else {
      throw ServiceError.message("Tor did not report a SOCKS address")
    }
    return endpoint
  }

  private func stopTor() {
    torController?.disconnect()
    torController = nil
    torThread?.cancel()
    torThread = nil
    torConf = nil
  }
}


// MARK: - Pipe between libssh and Tor's SOCKS port

enum TorPipe {
  /// Runs the pipe in the proxy callback. Assumes executeProxyCommand
  /// has already dup2'ed the libssh sockets onto stdin/stdout and the
  /// terminal error stream onto stderr. Blocks until the connection
  /// closes, exactly like the external command it replaces.
  static func run(host: String, port: Int) {
    func note(_ message: String) {
      let line = "blink-tor: \(message)\r\n"
      line.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
    }
    func abort() {
      shutdown(STDIN_FILENO, SHUT_RDWR)
      shutdown(STDOUT_FILENO, SHUT_RDWR)
    }

    let endpoint: (host: String, port: Int)
    do {
      endpoint = try TorService.shared.socks(progress: { note($0) })
    } catch {
      note("Tor failed to start: \(error.localizedDescription)")
      abort()
      return
    }

    let remote = tcpConnect(host: endpoint.host, port: endpoint.port)
    guard remote >= 0 else {
      note("Could not connect to Tor's SOCKS port")
      abort()
      return
    }

    if !socks5Connect(fd: remote, host: host, port: port) {
      note("SOCKS5 connection to \(host):\(port) via Tor failed")
      close(remote)
      abort()
      return
    }

    note("Connected to \(host):\(port) via Tor")
    pump(localIn: STDIN_FILENO, localOut: STDOUT_FILENO, remote: remote)
    close(remote)
  }

  private static func tcpConnect(host: String, port: Int) -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &result) == 0, let result = result else {
      return -1
    }
    defer { freeaddrinfo(result) }

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
      return -1
    }
    guard connect(fd, result.pointee.ai_addr, socklen_t(result.pointee.ai_addrlen)) == 0 else {
      close(fd)
      return -1
    }
    return fd
  }

  /// SOCKS5 handshake (RFC 1928): no authentication, CONNECT with a
  /// domain-name address so name resolution happens on the Tor side
  /// (no DNS leaks, and `.onion` names work too).
  private static func socks5Connect(fd: Int32, host: String, port: Int) -> Bool {
    guard writeAll(fd, [0x05, 0x01, 0x00]) else {
      return false
    }
    var greeting = [UInt8](repeating: 0, count: 2)
    guard readExact(fd, &greeting), greeting[0] == 0x05, greeting[1] == 0x00 else {
      return false
    }

    let hostBytes = [UInt8](host.utf8)
    guard hostBytes.count <= 255 else {
      return false
    }
    var request: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)]
    request.append(contentsOf: hostBytes)
    request.append(UInt8((port >> 8) & 0xff))
    request.append(UInt8(port & 0xff))
    guard writeAll(fd, request) else {
      return false
    }

    var header = [UInt8](repeating: 0, count: 4)
    guard readExact(fd, &header), header[0] == 0x05, header[1] == 0x00 else {
      return false
    }
    // Consume the bound address, whose length depends on its type.
    let boundLength: Int
    switch header[3] {
    case 0x01:
      boundLength = 4
    case 0x03:
      var lengthByte = [UInt8](repeating: 0, count: 1)
      guard readExact(fd, &lengthByte) else {
        return false
      }
      boundLength = Int(lengthByte[0])
    case 0x04:
      boundLength = 16
    default:
      return false
    }
    var rest = [UInt8](repeating: 0, count: boundLength + 2)
    return readExact(fd, &rest)
  }

  private static func pump(localIn: Int32, localOut: Int32, remote: Int32) {
    var buffer = [UInt8](repeating: 0, count: 32 * 1024)
    var fds = [
      pollfd(fd: localIn, events: Int16(POLLIN), revents: 0),
      pollfd(fd: remote, events: Int16(POLLIN), revents: 0),
    ]

    loop: while true {
      fds[0].revents = 0
      fds[1].revents = 0
      if poll(&fds, 2, -1) < 0 {
        if errno == EINTR {
          continue
        }
        break
      }

      let localEvents = fds[0].revents
      if localEvents & Int16(POLLIN) != 0 {
        let count = read(localIn, &buffer, buffer.count)
        if count <= 0 {
          break
        }
        if !writeAll(remote, Array(buffer[0..<count])) {
          break
        }
      } else if localEvents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
        break
      }

      let remoteEvents = fds[1].revents
      if remoteEvents & Int16(POLLIN) != 0 {
        let count = read(remote, &buffer, buffer.count)
        if count <= 0 {
          break
        }
        if !writeAll(localOut, Array(buffer[0..<count])) {
          break
        }
      } else if remoteEvents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
        break
      }
    }

    shutdown(remote, SHUT_RDWR)
    shutdown(localIn, SHUT_RDWR)
    shutdown(localOut, SHUT_RDWR)
  }

  private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
      let written = bytes.withUnsafeBufferPointer { pointer -> Int in
        write(fd, pointer.baseAddress! + offset, bytes.count - offset)
      }
      if written < 0 {
        if errno == EINTR {
          continue
        }
        return false
      }
      if written == 0 {
        return false
      }
      offset += written
    }
    return true
  }

  private static func readExact(_ fd: Int32, _ bytes: inout [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
      let remaining = bytes.count - offset
      let count = bytes.withUnsafeMutableBufferPointer { pointer -> Int in
        read(fd, pointer.baseAddress! + offset, remaining)
      }
      if count < 0 {
        if errno == EINTR {
          continue
        }
        return false
      }
      if count == 0 {
        return false
      }
      offset += count
    }
    return true
  }
}
