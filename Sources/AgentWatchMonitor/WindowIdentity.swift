import AppKit
import ApplicationServices
import CoreFoundation
import CoreGraphics
import Darwin
import Foundation

/// Rectangle values in global, top-left-origin screen points.
public struct WindowIdentityRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    fileprivate var isUsable: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && width > 0 && height > 0
    }

    fileprivate func matches(_ other: Self, tolerance: Double) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

/// A title-free window-server record used only for identity matching.
public struct WindowIdentityCandidate: Equatable, Sendable {
    public let ownerPID: Int32
    public let windowNumber: CGWindowID
    public let bounds: WindowIdentityRect

    public init(ownerPID: Int32, windowNumber: CGWindowID, bounds: WindowIdentityRect) {
        self.ownerPID = ownerPID
        self.windowNumber = windowNumber
        self.bounds = bounds
    }
}

/// Pure rectangle matching policy. A non-unique match is deliberately unknown.
public enum WindowIdentityPolicy {
    public static let defaultTolerance = 2.0

    public static func uniqueWindowNumber(
        pid: Int32,
        accessibilityBounds: WindowIdentityRect,
        candidates: [WindowIdentityCandidate],
        tolerance: Double = defaultTolerance
    ) -> CGWindowID? {
        guard pid > 0,
              tolerance.isFinite,
              tolerance >= 0,
              accessibilityBounds.isUsable else {
            return nil
        }

        let matches = candidates.filter { candidate in
            candidate.ownerPID == pid
                && candidate.windowNumber != kCGNullWindowID
                && candidate.bounds.isUsable
                && accessibilityBounds.matches(candidate.bounds, tolerance: tolerance)
        }
        guard matches.count == 1 else { return nil }
        return matches[0].windowNumber
    }

    /// Prefer a valid AX-derived window number; otherwise retain the
    /// public-API geometry match.
    public static func preferredWindowNumber(
        privateAXWindowNumber: CGWindowID?,
        geometryWindowNumber: CGWindowID?
    ) -> CGWindowID? {
        if let privateAXWindowNumber, privateAXWindowNumber != kCGNullWindowID {
            return privateAXWindowNumber
        }
        guard let geometryWindowNumber, geometryWindowNumber != kCGNullWindowID else { return nil }
        return geometryWindowNumber
    }
}

/// A bounded, read-only snapshot of all reported windows owned by one selected PID.
public struct WindowIdentitySnapshot: Sendable {
    public let ownerPID: Int32
    public let capturedAtUptime: TimeInterval
    public let candidates: [WindowIdentityCandidate]

    fileprivate init(ownerPID: Int32, capturedAtUptime: TimeInterval, candidates: [WindowIdentityCandidate]) {
        self.ownerPID = ownerPID
        self.capturedAtUptime = capturedAtUptime
        self.candidates = candidates
    }
}

/// Fixed outcomes for a read-only, verified-target AX root lookup.
public enum WindowRootDiscoveryStatus: String, Sendable {
    case rootsFound = "ax_root_discovery_found"
    case noRoots = "ax_root_discovery_no_roots"
    case targetNotVerified = "ax_root_discovery_target_not_verified"
    case permissionDenied = "ax_root_discovery_permission_denied"
    case applicationPIDMismatch = "ax_root_discovery_pid_mismatch"
    case metadataUnavailable = "ax_root_discovery_metadata_unavailable"
    case timeBudgetExceeded = "ax_root_discovery_time_budget_exceeded"
    case partial = "ax_root_discovery_partial"
}

/// AXWindow elements discovered without reading titles, labels, or web content.
public struct WindowRootDiscoveryResult {
    public let roots: [AXUIElement]
    public let hitTestCount: Int
    public let metadataWindowCount: Int
    public let matchedWindowCount: Int
    public let status: WindowRootDiscoveryStatus

    fileprivate init(
        roots: [AXUIElement],
        hitTestCount: Int,
        metadataWindowCount: Int = 0,
        matchedWindowCount: Int = 0,
        status: WindowRootDiscoveryStatus
    ) {
        self.roots = roots
        self.hitTestCount = hitTestCount
        self.metadataWindowCount = metadataWindowCount
        self.matchedWindowCount = matchedWindowCount
        self.status = status
    }
}

/// Read-only AX geometry to CGWindow identity matching.
public enum WindowIdentity {
    private static let windowListQueue = DispatchQueue(
        label: "com.agentwatch.window-identity.cg-list",
        qos: .utility
    )
    private static let maximumWindowListEntries = 2_048
    private static let maximumOwnedWindows = 64
    private static let maximumWindowListWaitSeconds = 0.25
    private static let maximumSnapshotAgeSeconds = 0.5
    private static let maximumRootChildren = 64
    private static let maximumRootHitTests = 32
    private static let maximumRootParentDepth = 24
    private static let maximumRootMessageTimeout: Float = 0.05
    private static let privateAXQueue = DispatchQueue(
        label: "com.agentwatch.window-identity.private-ax",
        qos: .utility
    )
    private static let privateAXWindowAPI = PrivateAXWindowAPI()

    /// Discover target-owned AXWindow roots when AXWindows is absent or empty.
    /// The target is revalidated against its live bundle identity; the Doubao
    /// Browser helper also requires its exact bundle path and Doubao parent.
    /// Hit-testing uses only that target's application element and metadata
    /// window centers, never the global AX element or the user's pointer.
    public static func discoverVerifiedTargetRoots(
        appID: String,
        pid: Int32,
        bundleIdentifier: String?,
        deadline: TimeInterval,
        metadataSnapshot: WindowIdentitySnapshot? = nil,
        messageTimeout: Float = 0.05
    ) -> WindowRootDiscoveryResult {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            return WindowRootDiscoveryResult(roots: [], hitTestCount: 0, status: .timeBudgetExceeded)
        }
        guard ChromiumAccessibilityCompatibility.isVerifiedRootDiscoveryTarget(
            appID: appID,
            pid: pid,
            requestedBundleIdentifier: bundleIdentifier
        ) else {
            return WindowRootDiscoveryResult(roots: [], hitTestCount: 0, status: .targetNotVerified)
        }
        guard AXIsProcessTrusted() else {
            return WindowRootDiscoveryResult(roots: [], hitTestCount: 0, status: .permissionDenied)
        }
        guard pid > 0 else {
            return WindowRootDiscoveryResult(roots: [], hitTestCount: 0, status: .applicationPIDMismatch)
        }

        let application = AXUIElementCreateApplication(pid)
        guard elementPID(application, deadline: deadline, messageTimeout: messageTimeout) == pid else {
            return WindowRootDiscoveryResult(roots: [], hitTestCount: 0, status: .applicationPIDMismatch)
        }
        guard ChromiumAccessibilityCompatibility.isVerifiedRootDiscoveryTarget(
            appID: appID,
            pid: pid,
            requestedBundleIdentifier: bundleIdentifier
        ) else {
            return WindowRootDiscoveryResult(roots: [], hitTestCount: 0, status: .targetNotVerified)
        }

        var roots: [AXUIElement] = []
        appendWindowAttribute(
            kAXMainWindowAttribute as CFString,
            from: application,
            pid: pid,
            roots: &roots,
            deadline: deadline,
            messageTimeout: messageTimeout
        )
        appendWindowAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: application,
            pid: pid,
            roots: &roots,
            deadline: deadline,
            messageTimeout: messageTimeout
        )
        appendWindowChildren(
            from: application,
            pid: pid,
            roots: &roots,
            deadline: deadline,
            messageTimeout: messageTimeout
        )

        guard ProcessInfo.processInfo.systemUptime < deadline else {
            return WindowRootDiscoveryResult(
                roots: roots,
                hitTestCount: 0,
                status: roots.isEmpty ? .timeBudgetExceeded : .partial
            )
        }

        let snapshot: WindowIdentitySnapshot?
        if let metadataSnapshot,
           metadataSnapshot.ownerPID == pid,
           ProcessInfo.processInfo.systemUptime >= metadataSnapshot.capturedAtUptime,
           ProcessInfo.processInfo.systemUptime - metadataSnapshot.capturedAtUptime <= maximumSnapshotAgeSeconds {
            snapshot = metadataSnapshot
        } else {
            snapshot = captureWindowSnapshot(forPID: pid, deadline: deadline)
        }
        guard let snapshot, snapshot.ownerPID == pid else {
            return WindowRootDiscoveryResult(
                roots: roots,
                hitTestCount: 0,
                status: roots.isEmpty ? .metadataUnavailable : .rootsFound
            )
        }

        var knownWindowNumbers = Set<CGWindowID>()
        for root in roots {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            if let number = resolvedWindowNumber(
                for: root,
                pid: pid,
                snapshot: snapshot,
                deadline: deadline,
                messageTimeout: messageTimeout
            ) {
                knownWindowNumbers.insert(number)
            }
        }

        var hitTestCount = 0
        for candidate in snapshot.candidates where !knownWindowNumbers.contains(candidate.windowNumber) {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  hitTestCount < maximumRootHitTests else {
                break
            }
            hitTestCount += 1
            guard let hitElement = hitTest(
                application: application,
                candidate: candidate,
                deadline: deadline,
                messageTimeout: messageTimeout
            ),
                  let root = nearestWindowRoot(
                    from: hitElement,
                    pid: pid,
                    deadline: deadline,
                    messageTimeout: messageTimeout
                  ),
                  resolvedWindowNumber(
                    for: root,
                    pid: pid,
                    snapshot: snapshot,
                    deadline: deadline,
                    messageTimeout: messageTimeout
                  ) == candidate.windowNumber else {
                continue
            }
            appendUnique(root, to: &roots)
            knownWindowNumbers.insert(candidate.windowNumber)
        }

        let timedOut = ProcessInfo.processInfo.systemUptime >= deadline
        let unmatchedWindowCount = snapshot.candidates.filter {
            !knownWindowNumbers.contains($0.windowNumber)
        }.count
        let status: WindowRootDiscoveryStatus
        if timedOut {
            status = roots.isEmpty ? .timeBudgetExceeded : .partial
        } else if unmatchedWindowCount > 0 {
            status = .partial
        } else if roots.isEmpty {
            status = .noRoots
        } else {
            status = .rootsFound
        }
        return WindowRootDiscoveryResult(
            roots: roots,
            hitTestCount: hitTestCount,
            metadataWindowCount: snapshot.candidates.count,
            matchedWindowCount: snapshot.candidates.count - unmatchedWindowCount,
            status: status
        )
    }

    private static func appendWindowAttribute(
        _ attribute: CFString,
        from application: AXUIElement,
        pid: Int32,
        roots: inout [AXUIElement],
        deadline: TimeInterval,
        messageTimeout: Float
    ) {
        guard let element = copyAXElement(
            attribute,
            from: application,
            deadline: deadline,
            messageTimeout: messageTimeout
        ), isWindowRoot(element, pid: pid, deadline: deadline, messageTimeout: messageTimeout) else {
            return
        }
        appendUnique(element, to: &roots)
    }

    private static func appendWindowChildren(
        from application: AXUIElement,
        pid: Int32,
        roots: inout [AXUIElement],
        deadline: TimeInterval,
        messageTimeout: Float
    ) {
        guard configureAXElement(application, deadline: deadline, messageTimeout: messageTimeout) else { return }
        var childCount: CFIndex = 0
        let countResult = AXUIElementGetAttributeValueCount(
            application,
            kAXChildrenAttribute as CFString,
            &childCount
        )
        guard countResult == .success, childCount > 0,
              ProcessInfo.processInfo.systemUptime < deadline else {
            return
        }

        let inspectedCount = min(childCount, CFIndex(maximumRootChildren))
        var copiedChildren: CFArray?
        let copyResult = AXUIElementCopyAttributeValues(
            application,
            kAXChildrenAttribute as CFString,
            0,
            inspectedCount,
            &copiedChildren
        )
        guard copyResult == .success, let copiedChildren,
              CFArrayGetCount(copiedChildren) == inspectedCount else {
            return
        }

        for index in 0..<inspectedCount {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let pointer = CFArrayGetValueAtIndex(copiedChildren, index) else {
                return
            }
            let reference = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(reference) == AXUIElementGetTypeID() else { continue }
            let child = Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue()
            guard isWindowRoot(child, pid: pid, deadline: deadline, messageTimeout: messageTimeout) else {
                continue
            }
            appendUnique(child, to: &roots)
        }
    }

    private static func hitTest(
        application: AXUIElement,
        candidate: WindowIdentityCandidate,
        deadline: TimeInterval,
        messageTimeout: Float
    ) -> AXUIElement? {
        guard configureAXElement(application, deadline: deadline, messageTimeout: messageTimeout) else { return nil }
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            application,
            Float(candidate.bounds.x + candidate.bounds.width / 2),
            Float(candidate.bounds.y + candidate.bounds.height / 2),
            &element
        )
        guard result == .success, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        return element
    }

    private static func nearestWindowRoot(
        from hitElement: AXUIElement,
        pid: Int32,
        deadline: TimeInterval,
        messageTimeout: Float
    ) -> AXUIElement? {
        var current: AXUIElement? = hitElement
        for _ in 0..<maximumRootParentDepth {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let element = current,
                  elementPID(element, deadline: deadline, messageTimeout: messageTimeout) == pid,
                  let role = copyAXString(
                    kAXRoleAttribute as CFString,
                    from: element,
                    deadline: deadline,
                    messageTimeout: messageTimeout
                  ) else {
                return nil
            }
            if role == "AXWindow" { return element }
            current = copyAXElement(
                kAXParentAttribute as CFString,
                from: element,
                deadline: deadline,
                messageTimeout: messageTimeout
            )
        }
        return nil
    }

    private static func isWindowRoot(
        _ element: AXUIElement,
        pid: Int32,
        deadline: TimeInterval,
        messageTimeout: Float
    ) -> Bool {
        elementPID(element, deadline: deadline, messageTimeout: messageTimeout) == pid
            && copyAXString(
                kAXRoleAttribute as CFString,
                from: element,
                deadline: deadline,
                messageTimeout: messageTimeout
            ) == "AXWindow"
    }

    private static func elementPID(
        _ element: AXUIElement,
        deadline: TimeInterval,
        messageTimeout: Float
    ) -> Int32? {
        guard configureAXElement(element, deadline: deadline, messageTimeout: messageTimeout),
              ProcessInfo.processInfo.systemUptime < deadline else {
            return nil
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              ProcessInfo.processInfo.systemUptime < deadline,
              pid > 0 else {
            return nil
        }
        return Int32(pid)
    }

    private static func copyAXElement(
        _ attribute: CFString,
        from element: AXUIElement,
        deadline: TimeInterval,
        messageTimeout: Float
    ) -> AXUIElement? {
        guard configureAXElement(element, deadline: deadline, messageTimeout: messageTimeout),
              ProcessInfo.processInfo.systemUptime < deadline else {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              ProcessInfo.processInfo.systemUptime < deadline,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func copyAXString(
        _ attribute: CFString,
        from element: AXUIElement,
        deadline: TimeInterval,
        messageTimeout: Float
    ) -> String? {
        guard configureAXElement(element, deadline: deadline, messageTimeout: messageTimeout),
              ProcessInfo.processInfo.systemUptime < deadline else {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              ProcessInfo.processInfo.systemUptime < deadline,
              let value,
              CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return value as? String
    }

    private static func configureAXElement(
        _ element: AXUIElement,
        deadline: TimeInterval,
        messageTimeout: Float
    ) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0, messageTimeout > 0 else { return false }
        return AXUIElementSetMessagingTimeout(element, min(messageTimeout, Float(remaining))) == .success
    }

    private static func appendUnique(_ element: AXUIElement, to roots: inout [AXUIElement]) {
        guard !roots.contains(where: { CFEqual($0, element) }) else { return }
        roots.append(element)
    }

    private static func resolvedWindowNumber(
        for root: AXUIElement,
        pid: Int32,
        snapshot: WindowIdentitySnapshot,
        deadline: TimeInterval,
        messageTimeout: Float
    ) -> CGWindowID? {
        if let windowNumber = windowNumberFromAXElement(
            pid: pid,
            axWindow: root,
            deadline: deadline,
            messageTimeout: messageTimeout
        ) {
            return windowNumber
        }
        return matchOSWindowNumber(
            pid: pid,
            axWindow: root,
            snapshot: snapshot,
            deadline: deadline,
            messageTimeout: messageTimeout
        )
    }

    /// Capture one metadata-only window-server snapshot for the selected PID.
    /// Uses `optionAll` so offscreen windows in other Spaces can be considered;
    /// minimized windows are matchable only if the window server reports them.
    /// The system call runs off the caller's queue and the caller stops waiting
    /// when the supplied uptime deadline or short query budget expires.
    public static func captureWindowSnapshot(
        forPID pid: Int32,
        deadline: TimeInterval
    ) -> WindowIdentitySnapshot? {
        guard pid > 0 else { return nil }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return nil }

        let waitSeconds = min(remaining, maximumWindowListWaitSeconds)
        let semaphore = DispatchSemaphore(value: 0)
        let box = WindowIdentitySnapshotBox()
        windowListQueue.async {
            box.complete(readWindowServerSnapshot(pid: pid, deadline: deadline))
            semaphore.signal()
        }

        let waitNanoseconds = max(1, Int(waitSeconds * 1_000_000_000))
        guard semaphore.wait(timeout: .now() + .nanoseconds(waitNanoseconds)) == .success else {
            return nil
        }
        return box.value
    }

    /// Match an AX window against the captured PID-filtered snapshot.
    /// Only AXPosition/AXSize and CGWindow owner PID/number/bounds are read.
    public static func matchOSWindowNumber(
        pid: Int32,
        axWindow: AXUIElement,
        snapshot: WindowIdentitySnapshot,
        deadline: TimeInterval,
        messageTimeout: Float = 0.1
    ) -> CGWindowID? {
        let now = ProcessInfo.processInfo.systemUptime
        guard pid > 0,
              snapshot.ownerPID == pid,
              now < deadline,
              now >= snapshot.capturedAtUptime,
              now - snapshot.capturedAtUptime <= maximumSnapshotAgeSeconds,
              messageTimeout > 0 else {
            return nil
        }

        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        let timeout = min(messageTimeout, Float(remaining))
        guard timeout > 0,
              AXUIElementSetMessagingTimeout(axWindow, timeout) == .success,
              ProcessInfo.processInfo.systemUptime < deadline,
              let origin = readPoint(axWindow, attribute: kAXPositionAttribute as CFString),
              ProcessInfo.processInfo.systemUptime < deadline,
              let size = readSize(axWindow, attribute: kAXSizeAttribute as CFString),
              ProcessInfo.processInfo.systemUptime < deadline else {
            return nil
        }

        let bounds = WindowIdentityRect(
            x: Double(origin.x), y: Double(origin.y),
            width: Double(size.width), height: Double(size.height)
        )
        return WindowIdentityPolicy.uniqueWindowNumber(
            pid: pid,
            accessibilityBounds: bounds,
            candidates: snapshot.candidates
        )
    }

    /// Capture and match in one bounded call when a caller does not need to
    /// reuse one snapshot for several AX windows.
    public static func resolveOSWindowNumber(
        pid: Int32,
        axWindow: AXUIElement,
        deadline: TimeInterval,
        messageTimeout: Float = 0.1
    ) -> CGWindowID? {
        if let windowNumber = windowNumberFromAXElement(
            pid: pid,
            axWindow: axWindow,
            deadline: deadline,
            messageTimeout: messageTimeout
        ) {
            return windowNumber
        }
        guard let snapshot = captureWindowSnapshot(forPID: pid, deadline: deadline) else { return nil }
        return matchOSWindowNumber(
            pid: pid,
            axWindow: axWindow,
            snapshot: snapshot,
            deadline: deadline,
            messageTimeout: messageTimeout
        )
    }

    /// Resolve an AX window's WindowServer ID using the private HIServices SPI
    /// when present. Requires the caller's existing Accessibility trust and
    /// confirms the AX element belongs to the selected PID. Missing symbols,
    /// API errors, and a zero ID return nil so callers can use geometry fallback.
    public static func windowNumberFromAXElement(
        pid: Int32,
        axWindow: AXUIElement,
        deadline: TimeInterval,
        messageTimeout: Float = 0.1
    ) -> CGWindowID? {
        guard pid > 0,
              AXIsProcessTrusted(),
              ProcessInfo.processInfo.systemUptime < deadline,
              messageTimeout > 0,
              AXUIElementSetMessagingTimeout(axWindow, min(messageTimeout, Float(deadline - ProcessInfo.processInfo.systemUptime))) == .success,
              ProcessInfo.processInfo.systemUptime < deadline else {
            return nil
        }

        var elementPID: pid_t = 0
        guard AXUIElementGetPid(axWindow, &elementPID) == .success,
              elementPID == pid,
              ProcessInfo.processInfo.systemUptime < deadline,
              let getWindow = privateAXWindowAPI.getWindow else {
            return nil
        }

        let waitSeconds = min(Double(messageTimeout), deadline - ProcessInfo.processInfo.systemUptime)
        guard waitSeconds > 0 else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        let box = PrivateWindowNumberBox()
        let elementBox = AXElementBox(axWindow)
        privateAXQueue.async {
            var windowNumber = kCGNullWindowID
            let result = getWindow(elementBox.element, &windowNumber)
            box.complete(result == .success && windowNumber != kCGNullWindowID ? windowNumber : nil)
            semaphore.signal()
        }
        let waitNanoseconds = max(1, Int(waitSeconds * 1_000_000_000))
        guard semaphore.wait(timeout: .now() + .nanoseconds(waitNanoseconds)) == .success,
              ProcessInfo.processInfo.systemUptime < deadline else {
            return nil
        }
        return box.value
    }

    private static func readWindowServerSnapshot(pid: Int32, deadline: TimeInterval) -> WindowIdentitySnapshot? {
        let startedAt = ProcessInfo.processInfo.systemUptime
        guard startedAt < deadline,
              let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID),
              ProcessInfo.processInfo.systemUptime < deadline else {
            return nil
        }

        let entryCount = CFArrayGetCount(windowList)
        guard entryCount >= 0, entryCount <= maximumWindowListEntries else { return nil }

        var candidates: [WindowIdentityCandidate] = []
        candidates.reserveCapacity(8)
        for index in 0..<entryCount {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let pointer = CFArrayGetValueAtIndex(windowList, index) else {
                return nil
            }
            let item = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(item) == CFDictionaryGetTypeID() else { return nil }
            let dictionary = unsafeDowncast(item, to: CFDictionary.self)

            // Read the required PID first. Other processes' window fields are untouched.
            guard let ownerValue = value(for: kCGWindowOwnerPID, in: dictionary),
                  let owner = integerValue(ownerValue) else {
                return nil
            }
            guard owner == pid else { continue }

            guard let numberValue = value(for: kCGWindowNumber, in: dictionary),
                  let number = windowNumberValue(numberValue),
                  let boundsValue = value(for: kCGWindowBounds, in: dictionary),
                  CFGetTypeID(boundsValue) == CFDictionaryGetTypeID() else {
                return nil
            }
            let boundsDictionary = unsafeDowncast(boundsValue, to: CFDictionary.self)
            var cgBounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDictionary, &cgBounds) else { return nil }

            let rect = WindowIdentityRect(
                x: Double(cgBounds.origin.x), y: Double(cgBounds.origin.y),
                width: Double(cgBounds.size.width), height: Double(cgBounds.size.height)
            )
            // A minimized or otherwise non-rendered entry can have no usable
            // rectangle; it cannot match a visible AX window and should not
            // prevent other valid windows from being identified.
            guard rect.isUsable else { continue }
            candidates.append(WindowIdentityCandidate(ownerPID: owner, windowNumber: number, bounds: rect))
            guard candidates.count <= maximumOwnedWindows else { return nil }
        }

        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        return WindowIdentitySnapshot(ownerPID: pid, capturedAtUptime: startedAt, candidates: candidates)
    }

    private static func readPoint(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        let value = unsafeDowncast(rawValue, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point),
              point.x.isFinite, point.y.isFinite else {
            return nil
        }
        return point
    }

    private static func readSize(_ element: AXUIElement, attribute: CFString) -> CGSize? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        let value = unsafeDowncast(rawValue, to: AXValue.self)
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size),
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            return nil
        }
        return size
    }

    private static func value(for key: CFString, in dictionary: CFDictionary) -> CFTypeRef? {
        guard let rawValue = CFDictionaryGetValue(
            dictionary,
            Unmanaged.passUnretained(key).toOpaque()
        ) else {
            return nil
        }
        return Unmanaged<CFTypeRef>.fromOpaque(rawValue).takeUnretainedValue()
    }

    private static func integerValue(_ value: CFTypeRef) -> Int32? {
        guard CFGetTypeID(value) == CFNumberGetTypeID(),
              let number = value as? NSNumber else {
            return nil
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue >= Double(Int32.min),
              doubleValue <= Double(Int32.max) else {
            return nil
        }
        return number.int32Value
    }

    private static func windowNumberValue(_ value: CFTypeRef) -> CGWindowID? {
        guard CFGetTypeID(value) == CFNumberGetTypeID(),
              let number = value as? NSNumber else {
            return nil
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue > 0,
              doubleValue <= Double(CGWindowID.max) else {
            return nil
        }
        return number.uint32Value
    }
}

private final class WindowIdentitySnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: WindowIdentitySnapshot?

    func complete(_ snapshot: WindowIdentitySnapshot?) {
        lock.lock()
        storedValue = snapshot
        lock.unlock()
    }

    var value: WindowIdentitySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

private typealias AXUIElementGetWindowFunction = @convention(c) (
    AXUIElement,
    UnsafeMutablePointer<CGWindowID>
) -> AXError

/// Optional runtime binding keeps the private SPI out of the link-time ABI.
private final class PrivateAXWindowAPI: @unchecked Sendable {
    private let libraryHandle: UnsafeMutableRawPointer?
    let getWindow: AXUIElementGetWindowFunction?

    init() {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/HIServices"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            libraryHandle = nil
            getWindow = nil
            return
        }
        libraryHandle = handle
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            getWindow = nil
            return
        }
        getWindow = unsafeBitCast(symbol, to: AXUIElementGetWindowFunction.self)
    }
}

private final class AXElementBox: @unchecked Sendable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }
}

private final class PrivateWindowNumberBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: CGWindowID?

    func complete(_ windowNumber: CGWindowID?) {
        lock.lock()
        storedValue = windowNumber
        lock.unlock()
    }

    var value: CGWindowID? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}
