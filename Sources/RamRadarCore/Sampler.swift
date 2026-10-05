import Darwin
import Foundation

/// Reads processes and system memory through public libproc / Mach / sysctl APIs.
/// No root, no private frameworks: processes owned by other users are listed
/// without arguments, and ones the kernel refuses to measure are skipped.
public enum Sampler {
    public static func snapshot(now: Date = Date()) -> Snapshot {
        Snapshot(date: now, system: systemMemory(), processes: processes(), currentUID: getuid())
    }

    // MARK: Processes

    public static func processes() -> [ProcessSample] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(capacity) + 128)
        let count = pids.withUnsafeMutableBytes { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count))
        }
        guard count > 0 else { return [] }

        let uid = getuid()
        var argBuffer = [UInt8](repeating: 0, count: argMax())
        var result: [ProcessSample] = []
        result.reserveCapacity(Int(count))

        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard let info = bsdInfo(pid) else { continue }
            guard let footprint = physFootprint(pid) else { continue }
            let owned = info.pbi_uid == uid
            var name = tupleString(info.pbi_name)
            if name.isEmpty { name = tupleString(info.pbi_comm) }
            let workingDirectory = owned ? cwd(pid) : nil
            var sample = ProcessSample(
                pid: pid,
                ppid: Int32(info.pbi_ppid),
                uid: info.pbi_uid,
                name: name,
                path: path(pid),
                arguments: owned ? arguments(pid, buffer: &argBuffer) : [],
                cwd: workingDirectory,
                // The kernel keeps reporting a deleted directory's old path.
                cwdDeleted: workingDirectory.map { !FileManager.default.fileExists(atPath: $0) } ?? false,
                startTime: startDate(info),
                footprint: footprint
            )
            if owned && sample.isVirtualMachine { sample.openFiles = openFiles(pid) }
            if owned && sample.isSimulatorRoot { sample.deviceName = simulatorDeviceName(sample) }
            result.append(sample)
        }
        return result
    }

    /// Paths of the files and folders `pid` has open.
    public static func openFiles(_ pid: Int32) -> [String] {
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdSize + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(filled) / fdSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = tupleString(info.pvip.vip_path)
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    /// The `name` in the simulator's `device.plist`, e.g. "iPhone 16 Pro".
    static func simulatorDeviceName(_ root: ProcessSample) -> String? {
        guard let dir = Simulators.deviceDirectory(root),
              let plist = NSDictionary(contentsOfFile: dir + "/device.plist") else { return nil }
        return plist["name"] as? String
    }

    /// True when `pid` still belongs to the process that was sampled. Guards the
    /// Stop button against pid reuse between a check and the click.
    public static func isSameProcess(_ p: ProcessSample) -> Bool {
        guard let info = bsdInfo(p.pid), info.pbi_status != 5 /* SZOMB: exited, not yet reaped */ else { return false }
        return abs(startDate(info).timeIntervalSince(p.startTime)) < 0.001
    }

    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func startDate(_ info: proc_bsdinfo) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    static func physFootprint(_ pid: Int32) -> UInt64? {
        var usage = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? usage.ri_phys_footprint : nil
    }

    static func path(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        return len > 0 ? String(cString: buf) : ""
    }

    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let s = tupleString(info.pvi_cdir.vip_path)
        return s.isEmpty ? nil : s
    }

    static func argMax() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctl(&mib, 2, &value, &size, nil, 0) == 0 && value > 0 ? Int(value) : 1 << 20
    }

    static func arguments(_ pid: Int32, buffer: inout [UInt8]) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let rc = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard rc == 0 else { return [] }
        return parseProcArgs(buffer[..<size])
    }

    /// `KERN_PROCARGS2` layout: `int32 argc`, exec path, NUL padding, then argc NUL-terminated strings.
    public static func parseProcArgs<C: Collection>(_ bytes: C) -> [String] where C.Element == UInt8, C.Index == Int {
        guard bytes.count > 4 else { return [] }
        var i = bytes.startIndex
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { raw in
            for k in 0..<4 { raw[k] = bytes[i + k] }
        }
        i += 4
        let end = bytes.endIndex
        while i < end && bytes[i] != 0 { i += 1 }
        while i < end && bytes[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < Int(argc) && i < end {
            let start = i
            while i < end && bytes[i] != 0 { i += 1 }
            args.append(String(decoding: bytes[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    static func tupleString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: System

    public static func systemMemory() -> SystemMemory {
        var physical: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &physical, &size, nil, 0)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        _ = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)

        let anonymous = UInt64(stats.internal_page_count) * page
        let purgeable = UInt64(stats.purgeable_count) * page
        let external = UInt64(stats.external_page_count) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

        return SystemMemory(
            physical: physical,
            appMemory: anonymous > purgeable ? anonymous - purgeable : 0,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cached: external + purgeable,
            swapUsed: swap.xsu_used,
            swapTotal: swap.xsu_total,
            pressure: PressureLevel(rawValue: Int(level)) ?? .normal
        )
    }
}
