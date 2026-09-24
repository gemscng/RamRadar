import Foundation
@testable import RamRadarCore

let now = Date(timeIntervalSince1970: 1_800_000_000)
let me: UInt32 = 501
let gb: UInt64 = 1 << 30

func proc(
    _ pid: Int32, ppid: Int32 = 1, uid: UInt32 = me, name: String = "x", path: String = "",
    args: [String] = [], cwd: String? = nil, hours: Double = 5, bytes: UInt64 = 100 << 20
) -> ProcessSample {
    ProcessSample(
        pid: pid, ppid: ppid, uid: uid, name: name, path: path, arguments: args, cwd: cwd,
        startTime: now.addingTimeInterval(-hours * 3600), footprint: bytes
    )
}

let ownPID: Int32 = 9999
