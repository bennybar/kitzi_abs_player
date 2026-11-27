import Accelerate
import AVFoundation
import MediaToolbox

/// Voice boost and skip silence, as a tap on the playing item's audio.
///
/// Boost: the samples are made louder and soft-limited (tanh), so a quiet
/// narrator comes up without the loud parts clipping. Skip silence: the tap
/// measures each buffer's level; after a third of a second of quiet it asks the
/// player to run fast until sound returns.
///
/// Only attached while one of them is on (a tap costs a little CPU on every
/// buffer), and only to files: an HLS stream has no audio track to tap.
nonisolated final class AudioEffects: @unchecked Sendable {
    static let shared = AudioEffects()

    // Read on the audio thread; written on the main one (plain flags: a stale
    // read for one buffer doesn't matter).
    nonisolated(unsafe) var boost = false
    nonisolated(unsafe) var skipSilence = false

    // Audio-thread state.
    nonisolated(unsafe) private var isFloat = true
    nonisolated(unsafe) private var sampleRate: Double = 44_100
    nonisolated(unsafe) private var quietFrames = 0
    nonisolated(unsafe) private var fast = false
    #if DEBUG
    // Test counters (simulator runs).
    nonisolated(unsafe) var debugBuffers = 0
    nonisolated(unsafe) var debugSilences = 0
    nonisolated(unsafe) var debugPeak: Float = 0
    #endif

    /// 2× (+6 dB) into the limiter.
    private static let gain: Float = 2
    /// About −42 dB: below it is "silence" (room tone, not speech).
    private static let quietLevel: Float = 0.008
    private static let quietSeconds = 0.35

    /// Puts the tap on `item` (its first audio track). No-op for HLS.
    @MainActor
    func attach(to item: AVPlayerItem) async {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: nil,
            prepare: { tap, _, format in
                let fx = Unmanaged<AudioEffects>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                fx.isFloat = format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.pointee.mBitsPerChannel == 32
                fx.sampleRate = format.pointee.mSampleRate > 0 ? format.pointee.mSampleRate : 44_100
                fx.quietFrames = 0
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                let fx = Unmanaged<AudioEffects>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                fx.process(UnsafeMutableAudioBufferListPointer(buffers), frames: Int(framesOut.pointee))
            }
        )
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else { return }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }

    private func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard isFloat, frames > 0 else { return }
        #if DEBUG
        debugBuffers += 1
        #endif
        var peak: Float = 0
        for b in buffers {
            guard let data = b.mData else { continue }
            let n = min(Int(b.mDataByteSize) / MemoryLayout<Float>.size, frames * Int(max(b.mNumberChannels, 1)))
            guard n > 0 else { continue }
            let p = data.assumingMemoryBound(to: Float.self)
            if skipSilence {
                var rms: Float = 0
                vDSP_rmsqv(p, 1, &rms, vDSP_Length(n))
                peak = max(peak, rms)
            }
            if boost {
                var g = Self.gain
                vDSP_vsmul(p, 1, &g, p, 1, vDSP_Length(n))
                var count = Int32(n)
                vvtanhf(p, p, &count) // soft limit: never past ±1
                #if DEBUG
                var m: Float = 0
                vDSP_maxmgv(p, 1, &m, vDSP_Length(n))
                debugPeak = max(debugPeak, m)
                #endif
            }
        }
        guard skipSilence else {
            if fast { fast = false; Self.tell(false) }
            return
        }
        if peak < Self.quietLevel {
            quietFrames += frames
            if !fast, Double(quietFrames) / sampleRate >= Self.quietSeconds {
                fast = true
                #if DEBUG
                debugSilences += 1
                #endif
                Self.tell(true)
            }
        } else {
            quietFrames = 0
            if fast { fast = false; Self.tell(false) }
        }
    }

    private static func tell(_ fast: Bool) {
        Task { @MainActor in Player.shared.silence(fast) }
    }
}
