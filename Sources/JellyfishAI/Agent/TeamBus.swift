import Foundation

/// エージェント（claude -p）とアプリをつなぐ通り道。
///
///   claude ──stdio(MCP)──▶ JellyfishAI --mcp-bridge <sock> <agentID> ──unix socket──▶ アプリ（TeamBus）
///
/// - Claude Code には公式の `--mcp-config` で「jellyfish」という stdio の MCP サーバーとして見える
/// - ブリッジは同じ実行ファイルの別モードで、標準入出力とソケットを中継するだけ（中身の MCP はアプリ側で処理）
/// - ソケットはデータフォルダに置き、所有者だけが読み書きできる（0600）
final class TeamBus {
    let path: String
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "jellyfish.bus")
    private var connections: [ObjectIdentifier: BusConnection] = [:]
    /// メインスレッドで呼ばれる
    var onMessage: ((BusConnection, [String: Any]) -> Void)?
    var onClose: ((BusConnection) -> Void)?

    init(dataDir: URL) {
        let p = dataDir.appendingPathComponent("bus.sock").path
        // sun_path は 104 バイトまで。長すぎる場所なら一時フォルダ（ユーザー専用）に置く
        path = p.utf8.count < 100 ? p : (NSTemporaryDirectory() as NSString).appendingPathComponent("jellyfish-bus.sock")
    }

    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(path.utf8.prefix(buf.count - 1))
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard ok == 0, listen(fd, 16) == 0 else { close(fd); throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.resume()
        acceptSource = src
        AppLog.write("team bus: \(path)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let c = accept(listenFD, nil, nil)
            if c < 0 { return }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            // 待ち受け側の O_NONBLOCK を引き継ぐので、読み書きは普通の（ブロックする）ソケットに戻す
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)
            let conn = BusConnection(fd: c, queue: queue)
            // つないできたプロセス（hello の名乗りを確かめるのに使う）
            var pid: pid_t = 0
            var plen = socklen_t(MemoryLayout<pid_t>.size)
            if getsockopt(c, SOL_LOCAL, LOCAL_PEERPID, &pid, &plen) == 0 { conn.peerPID = pid }
            conn.onMessage = { [weak self, weak conn] obj in
                guard let self, let conn else { return }
                DispatchQueue.main.async { self.onMessage?(conn, obj) }
            }
            conn.onClose = { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.connections[ObjectIdentifier(conn)] = nil
                DispatchQueue.main.async { self.onClose?(conn) }
            }
            connections[ObjectIdentifier(conn)] = conn
            conn.start()
        }
    }
}

/// ブリッジ 1 本ぶん（= 実行中の claude 1 プロセスぶん）
final class BusConnection {
    let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var closed = false
    /// hello で名乗ったエージェント（そのエージェントの claude の子プロセスだと確かめられたときだけ入る）
    var agentID: UUID?
    var peerPID: pid_t = 0
    var onMessage: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        source = src
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        if n < 0 && (errno == EINTR || errno == EAGAIN) { return }
        if n <= 0 { shutdown(); return }
        buffer.append(contentsOf: chunk[0..<n])
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            onMessage?(obj)
        }
    }

    /// JSON 1 行を書く（どのスレッドからでもよい）
    func send(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let w = write(self.fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                    if w <= 0 { if errno == EINTR || errno == EAGAIN { continue }; break }
                    off += w
                }
            }
        }
    }

    var isClosed: Bool { closed }

    private func shutdown() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        onClose?()
    }
}

/// `JellyfishAI --mcp-bridge <socket> <agentID>`：claude の子プロセスとして動き、標準入出力とソケットを中継する
enum TeamBridge {
    static func handles(_ args: [String]) -> Bool { args.contains("--mcp-bridge") }

    static func run(_ args: [String]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        guard let i = args.firstIndex(of: "--mcp-bridge"), args.count > i + 2 else { return 2 }
        let path = args[i + 1], agent = args[i + 2]
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(path.utf8.prefix(buf.count - 1))
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, ok == 0 else {
            FileHandle.standardError.write("Jellyfish AI に接続できません（アプリが起動していない可能性）\n".data(using: .utf8)!)
            return 1
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let hello = "{\"jellyfish\":\"hello\",\"agent\":\"\(agent)\"}\n"
        _ = hello.withCString { write(fd, $0, strlen($0)) }

        // ソケット → 標準出力
        let t = Thread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { exit(0) }
                var off = 0
                while off < n {
                    let w = buf.withUnsafeBufferPointer { write(STDOUT_FILENO, $0.baseAddress!.advanced(by: off), n - off) }
                    if w <= 0 { exit(0) }
                    off += w
                }
            }
        }
        t.start()
        // 標準入力 → ソケット（claude が終わると EOF）
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n <= 0 { break }
            var off = 0
            while off < n {
                let w = buf.withUnsafeBufferPointer { write(fd, $0.baseAddress!.advanced(by: off), n - off) }
                if w <= 0 { return 0 }
                off += w
            }
        }
        close(fd)
        return 0
    }
}

/// プロセスの親子関係
enum ProcessTree {
    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// pid が ancestor の子孫か（間にシェルなどが挟まっても数段までたどる）
    static func isDescendant(_ pid: pid_t, of ancestor: pid_t, maxDepth: Int = 6) -> Bool {
        guard pid > 1, ancestor > 1 else { return false }
        var p = pid
        for _ in 0..<maxDepth {
            guard let pp = parent(of: p), pp > 1 else { return false }
            if pp == ancestor { return true }
            p = pp
        }
        return false
    }
}
