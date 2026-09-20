import Foundation

/// Line-based request/response protocol over a Unix domain socket.
public enum IPC {
    public static var socketPath: String {
        let dir = NSString(string: "~/.config/mac-i3").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/ipc.sock"
    }

    static func makeAddr(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in path.utf8.prefix(buf.count - 1).enumerated() { buf[i] = b }
        }
        return addr
    }

    /// Send one request to the running daemon. Returns nil if none is listening.
    public static func send(_ request: String, timeout: Int = 5) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = makeAddr(socketPath)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }
        let line = request + "\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return String(data: out, encoding: .utf8)
    }
}

/// Accepts connections on the main queue; one request line in, one response out.
final class IPCServer {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    var handler: ((String) -> String)?

    func start() -> Bool {
        let path = IPC.socketPath
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var addr = IPC.makeAddr(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, listen(fd, 16) == 0 else { return false }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)   // must not leak into the process image after `restart`
        chmod(path, 0o600)
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        s.setEventHandler { [weak self] in self?.accept() }
        s.resume()
        source = s
        return true
    }

    func stop() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        unlink(IPC.socketPath)
    }

    private func accept() {
        let c = Foundation.accept(fd, nil, nil)
        guard c >= 0 else { return }
        _ = fcntl(c, F_SETFD, FD_CLOEXEC)
        defer { close(c) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var byte: UInt8 = 0
        while read(c, &byte, 1) == 1 {
            if byte == 10 { break }
            data.append(byte)
        }
        let req = String(data: data, encoding: .utf8) ?? ""
        let resp = handler?(req) ?? "error: no handler"
        _ = resp.withCString { write(c, $0, strlen($0)) }
    }
}
