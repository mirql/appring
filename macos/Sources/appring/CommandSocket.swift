import Darwin
import Foundation

// The socket is in the user's own temporary folder, not the shared /tmp: in /tmp another user could
// take the path first, and the app would not start. The folder comes from confstr, not TMPDIR, so
// every process of the user finds the same one; its path fits in sockaddr_un (~104 bytes).
enum CommandSocket {
    static func path() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else { return nil }
        var folder = String(cString: buffer)
        if !folder.hasSuffix("/") { folder += "/" }
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_mode & 0o077 == 0 else { return nil }
        return folder + "appring.sock"
    }

    static func send(_ line: String) -> Bool {
        guard let path = self.path() else { return false }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else {
            return false
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        guard fill(&address, path: path) else { return false }
        let connected = withSockAddress(&address) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        guard connected == 0 else { return false }
        let bytes = Array((line + "\n").utf8)
        let wrote = bytes.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return write(fd, base, raw.count)
        }
        return wrote == bytes.count
    }

    // run and open often start together. Wait briefly for the socket, and only then become the second instance.
    static func sendReady(_ line: String) -> Bool {
        for _ in 0..<30 {
            if send(line) { return true }
            usleep(50_000)
        }
        return false
    }
}

final class CommandServer {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var clients: [Int32: ClientReader] = [:]
    var onLine: ((String) -> Void)?

    func start() -> Bool {
        // The lock is in the user's own TMPDIR: another user could create a file in /tmp first and so claim the start.
        let lock = StartupLock()
        guard lock.acquire() else { return false }
        defer { lock.release() }
        guard let path = CommandSocket.path() else { return false }
        // Don't remove a live socket: a second `appring open` would break the command for the instance already running.
        if CommandSocket.send("ping") { return false }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid() else { return false }
            fputs("appring: replacing stale socket\n", stderr)
            unlink(path)
        }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_un()
        guard fill(&address, path: path) else {
            dropSocket()
            return false
        }
        let bound = withSockAddress(&address) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        guard bound == 0 else {
            // Don't remove someone else's socket: bind failed, the path isn't ours.
            dropSocket()
            return false
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            dropSocket()
            return false
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        reader.setEventHandler { [weak self] in self?.acceptClients() }
        reader.resume()
        source = reader
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        for reader in clients.values { reader.cancel() }
        clients.removeAll()
        // A client gets terminate too and must not remove the running instance's socket.
        guard fd >= 0 else { return }
        // The same lock as in start. Otherwise a new process takes the path between close and unlink, and we remove its socket.
        let lock = StartupLock()
        guard lock.acquire() else {
            dropSocket()
            return
        }
        defer { lock.release() }
        dropSocket()
        if let path = CommandSocket.path() { unlink(path) }
    }

    private func dropSocket() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    private func acceptClients() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            if getpeereid(client, &uid, &gid) != 0 || uid != getuid() {
                close(client)
                continue
            }
            readClient(client)
        }
    }

    // An accepted socket inherits O_NONBLOCK. EAGAIN means no data yet; don't close the connection.
    private func readClient(_ client: Int32) {
        var chunk = [UInt8](repeating: 0, count: 512)
        while true {
            let count = read(client, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    watch(client)
                    return
                }
                finish(client)
                return
            }
            let reader = clients[client] ?? ClientReader(fd: client)
            if count == 0 {
                let line = reader.text(eof: true)
                finish(client)
                if let line { onLine?(line) }
                return
            }
            reader.append(chunk.prefix(count))
            clients[client] = reader
            if reader.overflow {
                finish(client)
                return
            }
            if let line = reader.text(eof: false) {
                finish(client)
                onLine?(line)
                return
            }
        }
    }

    private func watch(_ client: Int32) {
        let reader = clients[client] ?? ClientReader(fd: client)
        if reader.source != nil {
            clients[client] = reader
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: .main)
        source.setEventHandler { [weak self] in self?.readClient(client) }
        source.setCancelHandler { close(client) }
        reader.source = source
        clients[client] = reader
        source.resume()
    }

    private func finish(_ client: Int32) {
        guard let reader = clients.removeValue(forKey: client) else {
            close(client)
            return
        }
        reader.cancel()
    }
}

private final class ClientReader {
    let fd: Int32
    var source: DispatchSourceRead?
    private var bytes = Data()
    private(set) var overflow = false

    init(fd: Int32) { self.fd = fd }

    func append(_ chunk: ArraySlice<UInt8>) {
        bytes.append(contentsOf: chunk)
        if bytes.count > 512 { overflow = true }
    }

    func text(eof: Bool) -> String? {
        guard eof || bytes.contains(UInt8(10)), !overflow else { return nil }
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func cancel() {
        if let source {
            source.cancel()
            self.source = nil
            return
        }
        close(fd)
    }
}

// The user's own directory, not the shared /tmp: another process can't create this file before us.
private final class StartupLock {
    private var fd: Int32 = -1

    func acquire() -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appring-server.lock")
        fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return false }
        chmod(url.path, 0o600)
        if flock(fd, LOCK_EX) != 0 {
            close(fd)
            fd = -1
            return false
        }
        return true
    }

    func release() {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }
}

private func fill(_ address: inout sockaddr_un, path: String) -> Bool {
    address.sun_family = sa_family_t(AF_UNIX)
    let encoded = Array(path.utf8)
    return withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        guard encoded.count + 1 <= buffer.count else { return false }
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        for (index, byte) in encoded.enumerated() {
            buffer[index] = byte
        }
        return true
    }
}

private func withSockAddress<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>) -> T) -> T {
    withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1, body)
    }
}
