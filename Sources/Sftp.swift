// Ssh + SFTP streaming — no third-party deps. Uses system ssh (keys/config
// from ~/.ssh/config) and a tiny loopback HTTP proxy so AVPlayer can stream
// remote files with Range support.

import Foundation

enum Ssh {
    enum SshError: Error { case failed(String) }
    enum State { case online, offline }

    static var status: [String: State] = [:]
    static var onStatus: (([String: State]) -> Void)?

    private static func setStatus(_ host: String, _ st: State) {
        status[host] = st
        DispatchQueue.main.async { onStatus?(status) }
    }

    static func probe(host: String) async {
        do { _ = try await run(host: host, command: "true"); setStatus(host, .online) }
        catch { setStatus(host, .offline) }
    }

    static func runSync(host: String, command: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, command]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        var data = Data()
        try p.run()
        let fh = pipe.fileHandleForReading
        while true {
            let chunk = fh.readData(ofLength: 1 << 16)
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw SshError.failed("ssh exit \(p.terminationStatus)") }
        return String(decoding: data, as: UTF8.self)
    }

    static func run(host: String, command: String, timeout: TimeInterval = 30) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, command]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = Pipe()
                var data = Data()
                do {
                    try p.run()
                    let fh = pipe.fileHandleForReading
                    while true {
                        let chunk = fh.readData(ofLength: 1 << 16)
                        if chunk.isEmpty { break }
                        data.append(chunk)
                    }
                    p.waitUntilExit()
                    if p.terminationStatus == 0 {
                        cont.resume(returning: String(decoding: data, as: UTF8.self))
                    } else {
                        cont.resume(throwing: SshError.failed("ssh exit \(p.terminationStatus)"))
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

// Loopback HTTP server on a POSIX socket: GET /<token> streams `ssh host
// cat file`; Range: bytes=N- restarts with `tail -c +N+1`. Blocking write()
// gives natural backpressure so we never buffer a whole track.
final class StreamProxy {
    static let shared = StreamProxy()

    private let queue = DispatchQueue(label: "stream.proxy", attributes: .concurrent)
    private var port: UInt16 = 0
    private var streams = NSMapTable<NSString, StreamEntry>(
        keyOptions: .strongMemory, valueOptions: .strongMemory)
    private final class StreamEntry {
        let host: String; let path: String
        var size = 0
        init(_ h: String, _ p: String) { host = h; path = p }
    }

    private init() { start() }

    func url(for host: String, path: String) -> URL {
        let token = String(UUID().uuidString.prefix(8))
        streams.setObject(StreamEntry(host, path), forKey: token as NSString)
        return URL(string: "http://127.0.0.1:\(port)/\(token)")!
    }

    private func start() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard bind(fd, withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { UnsafePointer($0) }
        }, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0, listen(fd, 16) == 0 else { return }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        getsockname(fd, withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { UnsafeMutablePointer($0) }
        }, &len)
        port = UInt16(bigEndian: bound.sin_port)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                let cfd = accept(fd, nil, nil)
                if cfd >= 0 {
                    var nosig: Int32 = 1
                    setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
                }
                if cfd < 0 { break }
                self?.queue.async { self?.serve(cfd) }
            }
        }
    }

    private func serve(_ cfd: Int32) {
        defer { close(cfd) }
        // read request head
        var head = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = read(cfd, &buf, buf.count)
            if n <= 0 { return }
            head.append(contentsOf: buf[0..<n])
            if head.count > 64_000 { break }
        }
        guard let text = String(data: head, encoding: .utf8),
              let first = text.components(separatedBy: "\r\n").first else { return }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", parts[1].hasPrefix("/") else { return }
        let token = String(parts[1].dropFirst().split(separator: "?").first ?? "")
        print("proxy hit: \(token) range=\(text.lowercased().contains("range:"))")
        guard let entry = streams.object(forKey: token as NSString) else {
            writeAll(cfd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
            return
        }

        // file size once per entry (cached on the entry)
        var size = entry.size
        if size <= 0 {
                    let out = try? Ssh.runSync(host: entry.host, command: "stat -c%s \(sqt(entry.path))")
                    size = Int((out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                    entry.size = size
                    print("proxy stat: size=\(size) out=\(out ?? "THREW")")
                }

        // parse Range: bytes=START-[END]
        var start = 0, end = size > 0 ? size - 1 : -1, ranged = false
        if let rline = text.components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("range:") }),
           let spec = rline.range(of: "bytes=").map({ String(rline[$0.upperBound...]) })
            .map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let halves = spec.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            if let sOpt = halves.first, let sVal = sOpt {
                start = sVal
                if halves.count > 1, let eVal = halves[1] { end = eVal }
                ranged = true
            }
        }
        if size > 0 { end = min(end, size - 1) }
        let length = (size > 0 && end >= start) ? end - start + 1 : -1

        var remoteCmd = start > 0 ? "tail -c +\(start + 1) \(sqt(entry.path))"
                                  : "cat \(sqt(entry.path))"
        if length > 0 { remoteCmd += " | head -c \(length)" }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", entry.host, remoteCmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return }

        if ranged && size > 0 {
            writeAll(cfd, "HTTP/1.1 206 Partial Content\r\nContent-Type: audio/mpeg\r\n"
                        + "Accept-Ranges: bytes\r\nContent-Range: bytes \(start)-\(end)/\(size)\r\n"
                        + "Content-Length: \(length)\r\nConnection: close\r\n\r\n")
        } else if size > 0 {
            writeAll(cfd, "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\n"
                        + "Accept-Ranges: bytes\r\nContent-Length: \(size)\r\nConnection: close\r\n\r\n")
        } else {
            writeAll(cfd, "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\n"
                        + "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n")
        }
        let fh = pipe.fileHandleForReading
        while true {
            let chunk = fh.readData(ofLength: 1 << 15)
            if chunk.isEmpty { break }
            if !writeAll(cfd, chunk) { break }   // player hung up
        }
        p.terminationHandler = nil
        if p.isRunning { p.interrupt() }
        p.waitUntilExit()
    }

    @discardableResult
    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        return data.withUnsafeBytes { raw in
            var ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            var left = raw.count
            while left > 0 {
                let n = write(fd, ptr, left)
                if n <= 0 { return false }
                ptr += n; left -= n
            }
            return true
        }
    }

    @discardableResult
    private func writeAll(_ fd: Int32, _ s: String) -> Bool {
        writeAll(fd, Data(s.utf8))
    }
}