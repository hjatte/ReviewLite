import CoreAudio
import Foundation

/// Per-process audio activity probe using the macOS 14 `AudioProcess` API.
/// Lets us ask "is any process *other than us* currently using audio input?" without
/// having to pause our own AVAudioRecorder (which doesn't actually release the mic).
enum AudioProcessActivity {

    /// Returns true if a process whose bundle ID matches one of `meetingPrefixes` is currently
    /// using the mic. Matching is by exact equality OR prefix match (so `com.microsoft.teams2.helper`
    /// counts as part of the `com.microsoft.teams2` meeting app — Electron apps run audio in helpers).
    /// On API failure returns nil.
    ///
    /// We deliberately ignore non-meeting processes (e.g. `com.apple.CoreSpeech`, which holds the
    /// mic open continuously for dictation/"Hey Siri") so they don't prevent stop detection.
    static func meetingAppHoldingInput(meetingPrefixes: Set<String>) -> Bool? {
        let processObjects = listAudioProcesses()
        guard let processObjects else { return nil }
        let ourPID = ProcessInfo.processInfo.processIdentifier

        for object in processObjects {
            guard let pid = pid(of: object), pid != ourPID else { continue }
            guard let bundle = bundleID(of: object) else { continue }
            let matches = meetingPrefixes.contains { prefix in
                bundle == prefix || bundle.hasPrefix(prefix + ".")
            }
            guard matches else { continue }
            if isRunningInput(object) == true {
                return true
            }
        }
        return false
    }

    /// Snapshot of (pid, bundleID, isRunningInput, isRunningOutput) for every audio process.
    /// Used for logging / diagnostics.
    static func snapshot() -> [(pid: pid_t, bundleID: String?, runningInput: Bool, runningOutput: Bool)] {
        guard let objects = listAudioProcesses() else { return [] }
        return objects.compactMap { object in
            guard let pid = pid(of: object) else { return nil }
            return (pid, bundleID(of: object), isRunningInput(object) ?? false, isRunningOutput(object) ?? false)
        }
    }

    // MARK: - Internals

    private static func listAudioProcesses() -> [AudioObjectID]? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        ) == noErr else { return nil }
        return ids
    }

    private static func pid(of audioProcess: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<pid_t>.size)
        var pid: pid_t = 0
        guard AudioObjectGetPropertyData(audioProcess, &addr, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    private static func bundleID(of audioProcess: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Core Audio returns a retained CFStringRef. Swift's `CFString?` direct binding is
        // unreliable; use Unmanaged<CFString> + takeRetainedValue() for correct ARC handling.
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(audioProcess, &addr, 0, nil, &size, &unmanaged) == noErr else { return nil }
        return unmanaged?.takeRetainedValue() as String?
    }

    private static func isRunningInput(_ audioProcess: AudioObjectID) -> Bool? {
        return readUInt32Property(audioProcess, selector: kAudioProcessPropertyIsRunningInput).map { $0 != 0 }
    }

    private static func isRunningOutput(_ audioProcess: AudioObjectID) -> Bool? {
        return readUInt32Property(audioProcess, selector: kAudioProcessPropertyIsRunningOutput).map { $0 != 0 }
    }

    private static func readUInt32Property(_ audioProcess: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(audioProcess, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
