// UnixSocket.swift — shared helper for the Unix-domain socket address
// byte-copy the IPC server and shedctl both need for bind/connect.

import Darwin
import Foundation

/// Build a filled `sockaddr_un` for `path`, or nil if the path is too long
/// for `sun_path`. Centralizes the unsafe pointer dance that would
/// otherwise be copy-pasted at every bind/connect site.
public func makeUnixSocketAddress(path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { c in
            for (i, b) in bytes.enumerated() { c[i] = CChar(b) }
            c[bytes.count] = 0
        }
    }
    return addr
}
