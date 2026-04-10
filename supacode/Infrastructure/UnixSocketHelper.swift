import Darwin

private nonisolated let unixSocketLogger = SupaLogger("UnixSocket")

/// Creates a Unix domain socket, binds it to `path`, and starts listening.
/// Returns the file descriptor on success, or -1 on failure.
nonisolated func createUnixSocket(path: String, backlog: Int32 = 8) -> Int32 {
  let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
  guard socketFD >= 0 else {
    unixSocketLogger.warning("socket() failed: \(String(cString: strerror(errno)))")
    return -1
  }

  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let pathBytes = path.utf8CString
  guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
    unixSocketLogger.warning("Socket path too long: \(path)")
    close(socketFD)
    return -1
  }
  _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
    pathBytes.withUnsafeBufferPointer { buffer in
      memcpy(sunPath, buffer.baseAddress!, buffer.count)
    }
  }

  let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
  let bindResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
      bind(socketFD, sockaddrPtr, addrLen)
    }
  }
  guard bindResult == 0 else {
    unixSocketLogger.warning("bind() failed: \(String(cString: strerror(errno)))")
    close(socketFD)
    return -1
  }

  guard listen(socketFD, backlog) == 0 else {
    unixSocketLogger.warning("listen() failed: \(String(cString: strerror(errno)))")
    close(socketFD)
    return -1
  }

  return socketFD
}
