import CoreAudio
import Foundation

/// Cheap polling check for "is the system's default input device currently being used by ANY process?"
/// We use this as the primary trigger for meeting auto-detection: any meeting tool grabs the mic when
/// a call starts, so this signal is locale- and version-agnostic.
enum MicrophoneActivity {
    static func isInUse() -> Bool {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let s1 = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &deviceID
        )
        guard s1 == noErr, deviceID != 0 else { return false }

        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let s2 = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &running)
        guard s2 == noErr else { return false }
        return running != 0
    }
}
