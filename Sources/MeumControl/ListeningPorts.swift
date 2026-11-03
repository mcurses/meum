// Listening TCP ports of process trees, read with libproc (no lsof: one scan costs a few milliseconds).
// The app polls it for each workspace's zmx sessions, so the sidebar can show a dev server's port.
import Darwin
import Foundation

public enum ListeningPorts {
    /// Every process's parent: pid -> ppid.
    public static func parents() -> [pid_t: pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard got > 0 else { return [:] }
        var out: [pid_t: pid_t] = [:]
        for pid in pids.prefix(Int(got)) where pid > 0 {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size {
                out[pid] = pid_t(info.pbsi_ppid)
            }
        }
        return out
    }

    /// `root` and all its descendants.
    public static func tree(of root: pid_t, parents: [pid_t: pid_t]) -> Set<pid_t> {
        var children: [pid_t: [pid_t]] = [:]
        for (p, pp) in parents { children[pp, default: []].append(p) }
        var seen: Set<pid_t> = [root]
        var stack = [root]
        while let p = stack.popLast() {
            for c in children[p] ?? [] where seen.insert(c).inserted { stack.append(c) }
        }
        return seen
    }

    /// TCP ports the process listens on (IPv4 and IPv6), sorted, distinct.
    public static func ports(of pid: pid_t) -> [Int] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let used = fds.withUnsafeMutableBufferPointer { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, bytes) }
        guard used > 0 else { return [] }
        var found: Set<Int> = []
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var si = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size,
                  si.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0 { found.insert(port) }
        }
        return found.sorted()
    }

    /// For each key, the ports its process tree listens on (sorted, distinct; keys without any are left out).
    public static func byRoot<K: Hashable>(_ roots: [K: pid_t]) -> [K: [Int]] {
        guard !roots.isEmpty else { return [:] }
        let parents = parents()
        var cache: [pid_t: [Int]] = [:]
        var out: [K: [Int]] = [:]
        for (key, root) in roots {
            var ports: Set<Int> = []
            for p in tree(of: root, parents: parents) {
                if cache[p] == nil { cache[p] = Self.ports(of: p) }
                ports.formUnion(cache[p]!)
            }
            if !ports.isEmpty { out[key] = ports.sorted() }
        }
        return out
    }
}
