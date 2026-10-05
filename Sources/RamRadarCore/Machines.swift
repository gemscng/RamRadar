import Foundation

/// Tells whose virtual machine a Virtualization-framework process is, from the disk image it has open.
public enum VirtualMachines {
    public static let executableName = "com.apple.Virtualization.VirtualMachine"

    public struct Owner: Hashable, Sendable {
        public var name: String
        /// The owning app's bundle file name. Quitting that app shuts its VM down cleanly.
        public var bundleName: String?
    }

    /// Path fragment of the VM's disk image → owner. Rancher Desktop keeps a Lima VM
    /// inside its own folder, so it is checked before plain Lima.
    static let owners: [(fragment: String, owner: Owner)] = [
        ("/com.docker.docker/", Owner(name: "Docker Desktop", bundleName: "Docker.app")),
        ("/.orbstack/", Owner(name: "OrbStack", bundleName: "OrbStack.app")),
        ("/com.utmapp.UTM/", Owner(name: "UTM", bundleName: "UTM.app")),
        ("/rancher-desktop/", Owner(name: "Rancher Desktop", bundleName: "Rancher Desktop.app")),
        ("/podman/machine/", Owner(name: "Podman", bundleName: nil)),
        ("/.colima/", Owner(name: "Colima", bundleName: nil)),
        ("/.lima/", Owner(name: "Lima", bundleName: nil)),
        ("/.tart/", Owner(name: "Tart", bundleName: nil)),
    ]

    public static func owner(openFiles: [String]) -> Owner? {
        owners.first { entry in openFiles.contains { $0.contains(entry.fragment) } }?.owner
    }
}

/// Booted Xcode simulators. Each runs a whole simulated OS (~200 processes) under one `launchd_sim`.
public enum Simulators {
    /// `launchd_sim …/Devices/<UDID>/data/var/run/launchd_bootstrap.plist` → `…/Devices/<UDID>`,
    /// the folder holding the device's `device.plist`.
    public static func deviceDirectory(_ root: ProcessSample) -> String? {
        guard let arg = root.arguments.first(where: { $0.hasSuffix("/launchd_bootstrap.plist") }),
              let r = arg.range(of: "/data/var/run/") else { return nil }
        return String(arg[..<r.lowerBound])
    }

    /// `…/Runtimes/iOS 18.1.simruntime/…` in any of the simulator's processes → `iOS 18.1`.
    public static func runtime(_ processes: [ProcessSample]) -> String? {
        for p in processes {
            guard let end = p.path.range(of: ".simruntime/") else { continue }
            return (String(p.path[..<end.lowerBound]) as NSString).lastPathComponent
        }
        return nil
    }

    /// Xcode's canvas previews run in their own simulators, which Xcode manages.
    public static func isPreview(_ root: ProcessSample) -> Bool {
        deviceDirectory(root)?.contains("/UserData/Previews/") ?? false
    }
}
