import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Captures system audio (via ScreenCaptureKit) and microphone (via AVAudioRecorder)
/// to two separate .m4a files, then mixes them into a single .m4a on stop.
final class AudioPipeline: NSObject, SCStreamOutput, SCStreamDelegate {
    enum State {
        case idle
        case recording
        case stopping
    }

    private(set) var state: State = .idle

    private var systemStream: SCStream?
    private var systemWriter: AVAssetWriter?
    private var systemInput: AVAssetWriterInput?
    private var sessionStarted = false
    private let scQueue = DispatchQueue(label: "reviewlite.sc-audio", qos: .userInitiated)

    private var micRecorder: AVAudioRecorder?

    private var workDir: URL?

    /// Starts capture; on success the workDir is the folder containing system.m4a / mic.m4a.
    func start() async throws -> URL {
        guard state == .idle else { throw error("already recording") }

        let id = UUID().uuidString
        let dir = Database.shared.meetingsDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workDir = dir

        let systemURL = dir.appendingPathComponent("system.m4a")
        let micURL = dir.appendingPathComponent("mic.m4a")

        try startMic(url: micURL)

        // Skip system-audio capture when the user is on built-in speakers — the mic already
        // picks up the meeting audio leaking out of the speakers, and capturing system audio
        // separately would result in the meeting audio appearing twice in the mixed file
        // (with a small delay, audible as an echo). Headphones / external outputs are fine.
        let onSpeakers = AudioRouting.usingBuiltInSpeakers()
        if onSpeakers {
            Log.meetings.info("Default output is built-in speakers — recording mic only to avoid echo.")
        } else {
            do {
                try await startSystem(url: systemURL)
            } catch {
                micRecorder?.stop()
                micRecorder = nil
                throw error
            }
        }

        state = .recording
        return dir
    }

    /// Stops capture and mixes both files into mixed.m4a inside the work dir.
    /// Returns the URL of the mixed file (or whichever single source we have if mixing fails).
    @discardableResult
    func stopAndMix() async -> URL? {
        guard state == .recording, let workDir else { return nil }
        state = .stopping

        // Stop mic first — synchronous and quick.
        micRecorder?.stop()
        micRecorder = nil

        // Stop system audio capture.
        if let stream = systemStream {
            try? await stream.stopCapture()
        }
        systemStream = nil

        if let input = systemInput {
            input.markAsFinished()
        }
        if let writer = systemWriter {
            await writer.finishWriting()
        }
        systemInput = nil
        systemWriter = nil
        sessionStarted = false

        let systemURL = workDir.appendingPathComponent("system.m4a")
        let micURL = workDir.appendingPathComponent("mic.m4a")
        let mixedURL = workDir.appendingPathComponent("mixed.m4a")

        let hasSystem = (try? systemURL.checkResourceIsReachable()) == true && fileSize(systemURL) > 1024
        let hasMic = (try? micURL.checkResourceIsReachable()) == true && fileSize(micURL) > 1024

        if hasSystem && hasMic {
            do {
                try await Self.mix(systemURL: systemURL, micURL: micURL, output: mixedURL)
                state = .idle
                return mixedURL
            } catch {
                Log.meetings.error("Audio mix failed: \(error.localizedDescription, privacy: .public). Falling back to single source.")
            }
        }
        state = .idle
        if hasMic { return micURL }
        if hasSystem { return systemURL }
        return nil
    }

    // MARK: - Mic

    private func startMic(url: URL) throws {
        // HE-AAC is AAC's low-bitrate variant — designed for speech / streaming.
        // 16 kHz mono at 16 kbps lands around ~7 MB/hour and stays intelligible for voice.
        // Whisper resamples to 16 kHz mono internally, so transcription accuracy is unaffected.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC_HE,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 16_000
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = false
        guard recorder.prepareToRecord(), recorder.record() else {
            throw error("could not start mic recorder")
        }
        self.micRecorder = recorder
    }

    // MARK: - System audio (ScreenCaptureKit)

    private func startSystem(url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw error("no display available for SCStream")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Video is required by SCK but we don't write it; minimize and rate-limit.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        // HE-AAC, mono, 16 kHz, 16 kbps. ScreenCaptureKit still delivers stereo 48 kHz buffers;
        // the encoder handles downmix and downsampling as part of its output settings.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC_HE,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 16_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? error("AVAssetWriter.startWriting failed")
        }
        self.systemWriter = writer
        self.systemInput = input
        self.sessionStarted = false

        let stream = try SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: scQueue)
        // Add a screen output too so SCK doesn't queue forever.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: scQueue)
        try await stream.startCapture()
        self.systemStream = stream
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }                  // discard screen frames
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let writer = systemWriter, let input = systemInput else { return }

        if !sessionStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Log.capture.error("SCStream stopped with error: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Helpers

    private func error(_ msg: String) -> NSError {
        return NSError(domain: "AudioPipeline", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    static func mix(systemURL: URL, micURL: URL, output: URL) async throws {
        let comp = AVMutableComposition()
        guard let sysTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let micTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "AudioPipeline", code: -2, userInfo: [NSLocalizedDescriptionKey: "could not add composition tracks"])
        }
        let sysAsset = AVURLAsset(url: systemURL)
        let micAsset = AVURLAsset(url: micURL)

        let sysAudios = try await sysAsset.loadTracks(withMediaType: .audio)
        let micAudios = try await micAsset.loadTracks(withMediaType: .audio)

        if let sa = sysAudios.first {
            let dur = try await sysAsset.load(.duration)
            try sysTrack.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: sa, at: .zero)
        }
        if let ma = micAudios.first {
            let dur = try await micAsset.load(.duration)
            try micTrack.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: ma, at: .zero)
        }

        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.removeItem(at: output)
        }

        guard let exporter = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "AudioPipeline", code: -3, userInfo: [NSLocalizedDescriptionKey: "could not create exporter"])
        }
        exporter.outputURL = output
        exporter.outputFileType = .m4a

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { cont.resume() }
        }
        if exporter.status != .completed {
            throw exporter.error ?? NSError(domain: "AudioPipeline", code: -4, userInfo: [NSLocalizedDescriptionKey: "exporter status \(exporter.status.rawValue)"])
        }
    }
}
