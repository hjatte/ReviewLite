import CoreAudio
import Foundation

/// Inspects the system's default audio output device. When it's the built-in laptop speaker,
/// recording system audio at the same time as the mic causes echo (the mic picks up what's
/// coming out of the speakers, so the meeting audio ends up in the recording twice — once
/// direct from system capture, once via the air gap). The pipeline uses this to skip system
/// audio capture in that case.
enum AudioRouting {

    /// True when the user's default output device is the built-in speaker (laptop or iMac).
    /// Headphones, AirPods, USB DACs, HDMI displays etc. all return false.
    static func usingBuiltInSpeakers() -> Bool {
        guard let outID = defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice) else {
            return false
        }
        return transportType(of: outID) == UInt32(kAudioDeviceTransportTypeBuiltIn)
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func transportType(of deviceID: AudioDeviceID) -> UInt32 {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else {
            return 0
        }
        return transport
    }
}
