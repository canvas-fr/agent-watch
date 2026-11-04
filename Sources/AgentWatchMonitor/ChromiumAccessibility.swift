import AppKit
import ApplicationServices
import CoreFoundation
import Darwin
import Foundation

/// Pure target policy for the Chromium accessibility compatibility request.
public enum ChromiumAccessibilityPolicy {
    public static let doubaoBundleIdentifier = "com.bot.neotix.doubao"
    public static let doubaoBrowserBundleIdentifier = "com.bot.neotix.doubao.browser"
    public static let doubaoBundlePath = "/Applications/Doubao.app"
    public static let doubaoBrowserBundlePath = "/Applications/Doubao.app/Contents/Helpers/Doubao Browser.app"
    public static let devinBundleIdentifier = "com.exafunction.windsurf"

    public enum Admission: Equatable, Sendable {
        case ignore
        case permissionDenied
        case alreadyAttempted
        case proceed
    }

    public enum AttributeRead: Equatable, Sendable {
        case alreadyEnabled
        case needsEnable
        case unsupported
        case failed
    }

    public enum SettableCheck: Equatable, Sendable {
        case notChecked
        case settable
        case notSettable
        case failed
    }

    public enum WriteDecision: Equatable, Sendable {
        case alreadyEnabled
        case checkSettable
        case refuseReadFailure
        case refuseNotSettable
        case refuseSettableCheckFailure
        case setOnce
    }

    public static func admission(
        pid: Int32,
        requestedBundleIdentifier: String?,
        liveBundleIdentifier: String?,
        liveBundlePath: String?,
        parentPID: Int32?,
        parentBundleIdentifier: String?,
        parentBundlePath: String?,
        accessibilityTrusted: Bool,
        alreadyAttempted: Bool
    ) -> Admission {
        guard pid > 0,
              requestedBundleIdentifier == liveBundleIdentifier else {
            return .ignore
        }

        if liveBundleIdentifier == doubaoBundleIdentifier {
            // Preserve the original main-app target behavior.
        } else if liveBundleIdentifier == doubaoBrowserBundleIdentifier {
            guard normalizedPath(liveBundlePath) == doubaoBrowserBundlePath,
                  let parentPID,
                  parentPID > 0,
                  parentBundleIdentifier == doubaoBundleIdentifier,
                  normalizedPath(parentBundlePath) == doubaoBundlePath else {
                return .ignore
            }
        } else {
            return .ignore
        }

        guard accessibilityTrusted else { return .permissionDenied }
        return alreadyAttempted ? .alreadyAttempted : .proceed
    }

    /// Restrict root discovery to the configured Doubao and Devin targets.
    /// Doubao's Browser helper must be the exact packaged child of Doubao.
    public static func rootDiscoveryAdmission(
        appID: String,
        requestedBundleIdentifier: String?,
        liveBundleIdentifier: String?,
        liveBundlePath: String?,
        parentPID: Int32?,
        parentBundleIdentifier: String?,
        parentBundlePath: String?
    ) -> Bool {
        guard requestedBundleIdentifier == liveBundleIdentifier else { return false }

        switch appID {
        case "doubao" where liveBundleIdentifier == doubaoBundleIdentifier:
            return normalizedPath(liveBundlePath) == doubaoBundlePath
        case "doubao" where liveBundleIdentifier == doubaoBrowserBundleIdentifier:
            return isVerifiedDoubaoBrowserChild(
                liveBundlePath: liveBundlePath,
                parentPID: parentPID,
                parentBundleIdentifier: parentBundleIdentifier,
                parentBundlePath: parentBundlePath
            )
        case "devin":
            return liveBundleIdentifier == devinBundleIdentifier
                && normalizedPath(liveBundlePath) != nil
        default:
            return false
        }
    }

    public static func isVerifiedDoubaoBrowserChild(
        liveBundlePath: String?,
        parentPID: Int32?,
        parentBundleIdentifier: String?,
        parentBundlePath: String?
    ) -> Bool {
        normalizedPath(liveBundlePath) == doubaoBrowserBundlePath
            && (parentPID ?? 0) > 0
            && parentBundleIdentifier == doubaoBundleIdentifier
            && normalizedPath(parentBundlePath) == doubaoBundlePath
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    public static func writeDecision(
        attributeRead: AttributeRead,
        settableCheck: SettableCheck
    ) -> WriteDecision {
        if attributeRead == .alreadyEnabled { return .alreadyEnabled }
        if attributeRead == .failed { return .refuseReadFailure }
        switch settableCheck {
        case .notChecked: return .checkSettable
        case .settable: return .setOnce
        case .notSettable: return .refuseNotSettable
        case .failed: return .refuseSettableCheckFailure
        }
    }
}

/// Fixed, content-free results for the optional Chromium AX compatibility step.
public enum ChromiumAccessibilityDiagnostic: String, Sendable {
    case ignoredNotWhitelisted = "chromium_ax_not_whitelisted"
    case processUnavailable = "chromium_ax_process_unavailable"
    case alreadyAttempted = "chromium_ax_already_attempted"
    case permissionDenied = "chromium_ax_permission_denied"
    case attributeAlreadyEnabled = "chromium_ax_already_enabled"
    case readFailed = "chromium_ax_read_failed"
    case settableCheckFailed = "chromium_ax_settable_check_failed"
    case attributeNotSettable = "chromium_ax_attribute_not_settable"
    case setFailed = "chromium_ax_set_failed"
    case pendingRescan = "pending_rescan"
}

/// Enables Chromium's macOS accessibility mode for the Doubao application only.
///
/// Chromium's macOS NSApplication implementation listens for
/// `AXEnhancedUserInterface` on the application accessibility element. This
/// helper reads the current value first, confirms that the attribute is
/// settable, sets only that attribute to `true`, and leaves Web tree
/// confirmation to a subsequent scan. It never sends a matching `false` value.
public enum ChromiumAccessibilityCompatibility {
    private static let attemptTracker = ChromiumAccessibilityAttemptTracker()
    private static var attribute: CFString { "AXEnhancedUserInterface" as CFString }

    /// Revalidate a configured live process before asking it for AX roots.
    /// This is read-only and does not change Chromium's accessibility setting.
    public static func isVerifiedRootDiscoveryTarget(
        appID: String,
        pid: Int32,
        requestedBundleIdentifier: String?
    ) -> Bool {
        guard pid > 0,
              let application = NSRunningApplication(processIdentifier: pid),
              let liveBundleIdentifier = application.bundleIdentifier else {
            return false
        }

        let parent: (pid: Int32, bundleIdentifier: String?, bundlePath: String?)?
        if appID == "doubao",
           liveBundleIdentifier == ChromiumAccessibilityPolicy.doubaoBrowserBundleIdentifier,
           let parentPID = processParentPID(pid: pid),
           let parentApplication = NSRunningApplication(processIdentifier: parentPID) {
            parent = (
                pid: parentPID,
                bundleIdentifier: parentApplication.bundleIdentifier,
                bundlePath: parentApplication.bundleURL?.standardizedFileURL.path
            )
        } else {
            parent = nil
        }

        return ChromiumAccessibilityPolicy.rootDiscoveryAdmission(
            appID: appID,
            requestedBundleIdentifier: requestedBundleIdentifier,
            liveBundleIdentifier: liveBundleIdentifier,
            liveBundlePath: application.bundleURL?.standardizedFileURL.path,
            parentPID: parent?.pid,
            parentBundleIdentifier: parent?.bundleIdentifier,
            parentBundlePath: parent?.bundlePath
        )
    }

    /// Request web-content accessibility once for a verified Doubao process.
    /// Callers must pass the observed PID and bundle identifier; the helper
    /// checks the live process bundle identifier again before using AX APIs.
    public static func enableWebAccessibility(
        pid: Int32,
        bundleIdentifier: String?
    ) -> ChromiumAccessibilityDiagnostic {
        guard pid > 0 else { return .ignoredNotWhitelisted }
        guard let runningApplication = NSRunningApplication(processIdentifier: pid),
              let liveBundleIdentifier = runningApplication.bundleIdentifier else {
            return .processUnavailable
        }

        let liveBundlePath = runningApplication.bundleURL?.standardizedFileURL.path
        let parentDetails: (pid: Int32, bundleIdentifier: String?, bundlePath: String?)?
        if liveBundleIdentifier == ChromiumAccessibilityPolicy.doubaoBrowserBundleIdentifier,
           let parentPID = processParentPID(pid: pid),
           let parentApplication = NSRunningApplication(processIdentifier: parentPID) {
            parentDetails = (
                pid: parentPID,
                bundleIdentifier: parentApplication.bundleIdentifier,
                bundlePath: parentApplication.bundleURL?.standardizedFileURL.path
            )
        } else {
            parentDetails = nil
        }

        let decision = ChromiumAccessibilityPolicy.admission(
            pid: pid,
            requestedBundleIdentifier: bundleIdentifier,
            liveBundleIdentifier: liveBundleIdentifier,
            liveBundlePath: liveBundlePath,
            parentPID: parentDetails?.pid,
            parentBundleIdentifier: parentDetails?.bundleIdentifier,
            parentBundlePath: parentDetails?.bundlePath,
            accessibilityTrusted: AXIsProcessTrusted(),
            alreadyAttempted: attemptTracker.hasAttempted(pid: pid)
        )
        if decision == .ignore { return .ignoredNotWhitelisted }
        if decision == .permissionDenied { return .permissionDenied }
        if decision == .alreadyAttempted { return .alreadyAttempted }
        guard attemptTracker.claim(pid: pid) else { return .alreadyAttempted }

        let application = AXUIElementCreateApplication(pid)
        var currentValue: CFTypeRef?
        let readResult = AXUIElementCopyAttributeValue(application, attribute, &currentValue)
        let attributeRead: ChromiumAccessibilityPolicy.AttributeRead
        if readResult == .success {
            attributeRead = isTrueBoolean(currentValue) ? .alreadyEnabled : .needsEnable
        } else if readResult == .noValue {
            attributeRead = .needsEnable
        } else if readResult == .attributeUnsupported || readResult == .notImplemented {
            attributeRead = .unsupported
        } else if readResult == .apiDisabled {
            return .permissionDenied
        } else {
            attributeRead = .failed
        }

        let initialWriteDecision = ChromiumAccessibilityPolicy.writeDecision(
            attributeRead: attributeRead,
            settableCheck: .notChecked
        )
        if initialWriteDecision == .alreadyEnabled { return .attributeAlreadyEnabled }
        if initialWriteDecision == .refuseReadFailure { return .readFailed }

        var isSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(application, attribute, &isSettable)
        let settableCheck: ChromiumAccessibilityPolicy.SettableCheck
        if settableResult == .success {
            settableCheck = isSettable.boolValue ? .settable : .notSettable
        } else if settableResult == .apiDisabled {
            return .permissionDenied
        } else {
            settableCheck = .failed
        }
        let writeDecision = ChromiumAccessibilityPolicy.writeDecision(
            attributeRead: attributeRead,
            settableCheck: settableCheck
        )
        if writeDecision == .refuseNotSettable { return .attributeNotSettable }
        if writeDecision == .refuseSettableCheckFailure { return .settableCheckFailed }
        guard writeDecision == .setOnce else { return .readFailed }

        let setResult = AXUIElementSetAttributeValue(application, attribute, kCFBooleanTrue)
        if setResult == .apiDisabled {
            return .permissionDenied
        }
        guard setResult == .success else { return .setFailed }
        return .pendingRescan
    }

    private static func isTrueBoolean(_ value: CFTypeRef?) -> Bool {
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    private static func processParentPID(pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bytesRead = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard bytesRead == expectedSize,
              info.pbi_pid == UInt32(pid),
              info.pbi_ppid > 0 else {
            return nil
        }
        return Int32(info.pbi_ppid)
    }
}

private final class ChromiumAccessibilityAttemptTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var attemptedPIDs: Set<Int32> = []

    func claim(pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return attemptedPIDs.insert(pid).inserted
    }

    func hasAttempted(pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return attemptedPIDs.contains(pid)
    }
}
