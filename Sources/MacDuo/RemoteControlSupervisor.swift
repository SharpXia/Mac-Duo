import AppKit
import Combine
import Darwin
import Foundation

/// Watches for a remote-control client running on this Mac.
///
/// A remote session paints exactly what is on the screens, overlays included,
/// so a running effect would hand the far side a blurred picture it cannot
/// operate. The check is coarse on purpose: while the client is present, no
/// distinction is drawn between it sitting idle and holding a session, since
/// the far side can connect at any moment.
@MainActor
final class RemoteControlSupervisor: ObservableObject {

    @Published private(set) var isClientRunning = false

    /// Bundle identifier prefixes of known remote-control clients.
    private static let bundleIdentifierPrefixes = ["com.oray"]
    /// Fragments matched, without case, against process names of both the
    /// session apps and the daemons outside the session.
    private static let processNameFragments = ["sunlogin"]

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isClientRunning = false
    }

    private func refresh() {
        isClientRunning = Self.isClientRunning()
    }

    static func isClientRunning() -> Bool {
        if hasSessionApp() { return true }
        return processNameFragments.contains { hasProcess(named: $0) }
    }

    /// The GUI clients live in this login session, and their bundle
    /// identifiers name the vendor even when the executable is renamed.
    private static func hasSessionApp() -> Bool {
        for app in NSWorkspace.shared.runningApplications {
            if let identifier = app.bundleIdentifier?.lowercased(),
               bundleIdentifierPrefixes.contains(where: identifier.hasPrefix) {
                return true
            }
            if let name = app.executableURL?.lastPathComponent.lowercased(),
               processNameFragments.contains(where: name.contains) {
                return true
            }
        }
        return false
    }

    /// The kernel process table, which also lists the privileged helpers a
    /// login session's app list never shows.
    private static func hasProcess(named fragment: String) -> Bool {
        var size = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return false }
        // The table can grow between the two calls, so leave room.
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 16
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        var bufferSize = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &buffer, &bufferSize, nil, 0) == 0 else { return false }

        let fragment = fragment.lowercased()
        let count = bufferSize / MemoryLayout<kinfo_proc>.stride
        for index in 0..<count {
            let name = withUnsafeBytes(of: buffer[index].kp_proc.p_comm) { bytes in
                let characters = bytes.prefix { $0 != 0 }
                return String(decoding: characters, as: UTF8.self).lowercased()
            }
            if name.contains(fragment) { return true }
        }
        return false
    }

    private static let pollInterval: TimeInterval = 2
}
