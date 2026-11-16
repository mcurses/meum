// Which terminal a Claude Code hook comes from. A session's hook names its tab through MEUM_TAB, but that variable is
// inherited by anything started from the tab: a background-session daemon that a tab's claude spawned passes it on to
// every session it runs elsewhere. meum takes a hook for a tab only when it runs on that tab's own terminal: the pty
// of the tab's zmx session, where its shell and claude run (meum-hook sends its terminal as `tty`).
import Darwin
import Foundation

public enum HookOrigin {
    /// Whether a hook that ran on `hookTTY` ("ttys012", or "" when it has no terminal) may speak for a tab whose
    /// session runs on `tabTTY`. When meum can't tell the tab's terminal (no zmx session found), it takes the hook,
    /// as before this check.
    public static func accepts(hookTTY: String, tabTTY: String?) -> Bool {
        guard let tabTTY else { return true }
        return hookTTY == tabTTY
    }

    /// The controlling terminal of a process ("ttys012"), or nil when it has none or is gone.
    public static func ttyName(of pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        let s = String(cString: name)
        return s.isEmpty || s == "??" ? nil : s
    }
}
