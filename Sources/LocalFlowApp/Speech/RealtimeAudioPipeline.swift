import AVFoundation
import Darwin
import Foundation
import os.lock

/// `memset_s` is guaranteed not to be removed as a dead store. Keeping the
/// wrapper in one place also avoids relying on `explicit_bzero`, which is not
/// exposed by every macOS Swift SDK module map.
@inline(never)
func secureZeroMemory(
    _ pointer: UnsafeMutableRawPointer,
    byteCount: Int
) {
    guard byteCount > 0 else { return }
    _ = memset_s(pointer, byteCount, 0, byteCount)
}

/// A fixed-size mono ring used only between AVAudioEngine's realtime callback
/// and the serial conversion queue. It never resizes or allocates after init.
private final class RealtimeMonoRing: @unchecked Sendable {
    struct Meter {
        let sumOfSquares: Double
        let peak: Float
        let frameCount: Int
    }

    struct Flags {
        let droppedFrames: Bool
        let formatMismatch: Bool
    }

    private var lock = os_unfair_lock_s()
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let expectedSampleRate: Double
    private let expectedChannelCount: Int
    private var readIndex = 0
    private var writeIndex = 0
    private var availableFrames = 0
    private var acceptingInput = true
    private var droppedFrames = false
    private var formatMismatch = false
    private var meterSumOfSquares = 0.0
    private var meterPeak: Float = 0
    private var meterFrameCount = 0

    init(
        capacityFrames: Int,
        sampleRate: Double,
        channelCount: Int
    ) {
        capacity = max(capacityFrames, 1)
        expectedSampleRate = sampleRate
        expectedChannelCount = channelCount
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        secureZeroMemory(
            UnsafeMutableRawPointer(storage),
            byteCount: capacity * MemoryLayout<Float>.stride
        )
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Called on the AVAudioEngine realtime thread.
    func write(_ buffer: AVAudioPCMBuffer) {
        let format = buffer.format
        guard
            format.commonFormat == .pcmFormatFloat32,
            Int(format.channelCount) == expectedChannelCount,
            abs(format.sampleRate - expectedSampleRate) < 0.5,
            let channels = buffer.floatChannelData
        else {
            os_unfair_lock_lock(&lock)
            formatMismatch = true
            acceptingInput = false
            os_unfair_lock_unlock(&lock)
            return
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let channelCount = expectedChannelCount
        let divisor = Float(channelCount)
        let interleaved = format.isInterleaved

        // This is a dedicated, bounded ring lock. The callback never touches
        // AudioCaptureEngine's lifecycle/state lock.
        os_unfair_lock_lock(&lock)
        guard acceptingInput else {
            os_unfair_lock_unlock(&lock)
            return
        }

        let acceptedFrames = min(frameCount, capacity - availableFrames)
        if acceptedFrames < frameCount {
            droppedFrames = true
        }

        var localSumOfSquares = 0.0
        var localPeak: Float = 0

        for frame in 0..<acceptedFrames {
            var mono: Float = 0
            if interleaved {
                let base = channels[0]
                let offset = frame * channelCount
                for channel in 0..<channelCount {
                    let sample = base[offset + channel]
                    mono += sample.isFinite ? sample : 0
                }
            } else {
                for channel in 0..<channelCount {
                    let sample = channels[channel][frame]
                    mono += sample.isFinite ? sample : 0
                }
            }
            mono /= divisor

            storage[writeIndex] = mono
            writeIndex += 1
            if writeIndex == capacity {
                writeIndex = 0
            }

            localSumOfSquares += Double(mono * mono)
            localPeak = max(localPeak, abs(mono))
        }

        availableFrames += acceptedFrames
        meterSumOfSquares += localSumOfSquares
        meterPeak = max(meterPeak, localPeak)
        meterFrameCount += acceptedFrames
        os_unfair_lock_unlock(&lock)
    }

    func read(
        into destination: UnsafeMutablePointer<Float>,
        maximumFrames: Int
    ) -> Int {
        os_unfair_lock_lock(&lock)
        let count = min(max(maximumFrames, 0), availableFrames)
        guard count > 0 else {
            os_unfair_lock_unlock(&lock)
            return 0
        }

        let firstCount = min(count, capacity - readIndex)
        destination.update(
            from: UnsafePointer(storage.advanced(by: readIndex)),
            count: firstCount
        )
        secureZeroMemory(
            UnsafeMutableRawPointer(storage.advanced(by: readIndex)),
            byteCount: firstCount * MemoryLayout<Float>.stride
        )

        let secondCount = count - firstCount
        if secondCount > 0 {
            destination.advanced(by: firstCount).update(
                from: UnsafePointer(storage),
                count: secondCount
            )
            secureZeroMemory(
                UnsafeMutableRawPointer(storage),
                byteCount: secondCount * MemoryLayout<Float>.stride
            )
        }

        readIndex = (readIndex + count) % capacity
        availableFrames -= count
        os_unfair_lock_unlock(&lock)
        return count
    }

    func takeMeter() -> Meter? {
        os_unfair_lock_lock(&lock)
        guard meterFrameCount > 0 else {
            os_unfair_lock_unlock(&lock)
            return nil
        }

        let result = Meter(
            sumOfSquares: meterSumOfSquares,
            peak: meterPeak,
            frameCount: meterFrameCount
        )
        meterSumOfSquares = 0
        meterPeak = 0
        meterFrameCount = 0
        os_unfair_lock_unlock(&lock)
        return result
    }

    func currentFlags() -> Flags {
        os_unfair_lock_lock(&lock)
        let result = Flags(
            droppedFrames: droppedFrames,
            formatMismatch: formatMismatch
        )
        os_unfair_lock_unlock(&lock)
        return result
    }

    func stopAcceptingInput() {
        os_unfair_lock_lock(&lock)
        acceptingInput = false
        os_unfair_lock_unlock(&lock)
    }

    func zeroize() {
        os_unfair_lock_lock(&lock)
        acceptingInput = false
        secureZeroMemory(
            UnsafeMutableRawPointer(storage),
            byteCount: capacity * MemoryLayout<Float>.stride
        )
        readIndex = 0
        writeIndex = 0
        availableFrames = 0
        meterSumOfSquares = 0
        meterPeak = 0
        meterFrameCount = 0
        os_unfair_lock_unlock(&lock)
    }
}

/// Owns conversion and final storage. With the exception of `ingest`, every
/// method is called on AudioCaptureEngine's serial drain queue.
final class RealtimeAudioPipeline: @unchecked Sendable {
    private static let drainChunkFrames = 4_096
    private static let levelIntervalNanoseconds: UInt64 = 50_000_000

    private let ring: RealtimeMonoRing
    private let converter: AVAudioConverter
    private let sourceBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let sourceScratch: UnsafeMutablePointer<Float>
    private let captureStorage: UnsafeMutablePointer<Float>
    private let maximumCapturedSamples: Int
    private let onLevel: @Sendable (Float) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private var capturedSampleCount = 0
    private var sumOfSquares = 0.0
    private var peak: Float = 0
    private var voicedSamples = 0
    private var truncated = false
    private var terminalFailure: Error?
    private var lastLevelEmission = DispatchTime.now().uptimeNanoseconds

    init(
        sourceSampleRate: Double,
        sourceChannelCount: Int,
        onLevel: @escaping @Sendable (Float) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceSampleRate,
                channels: 1,
                interleaved: false
            ),
            let destinationFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioCaptureEngine.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(
                from: sourceFormat,
                to: destinationFormat
            ),
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(Self.drainChunkFrames)
            )
        else {
            throw AudioCaptureError.unsupportedInputFormat
        }

        let outputCapacity = Int(
            ceil(
                Double(Self.drainChunkFrames)
                    * AudioCaptureEngine.sampleRate
                    / sourceSampleRate
            )
        ) + 512
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: destinationFormat,
            frameCapacity: AVAudioFrameCount(outputCapacity)
        ) else {
            throw AudioCaptureError.unsupportedInputFormat
        }

        let ringCapacity = max(
            Int(ceil(sourceSampleRate * 4)),
            Self.drainChunkFrames * 4
        )
        ring = RealtimeMonoRing(
            capacityFrames: ringCapacity,
            sampleRate: sourceSampleRate,
            channelCount: sourceChannelCount
        )
        self.converter = converter
        self.sourceBuffer = sourceBuffer
        self.outputBuffer = outputBuffer
        sourceScratch = .allocate(capacity: Self.drainChunkFrames)
        sourceScratch.initialize(
            repeating: 0,
            count: Self.drainChunkFrames
        )
        maximumCapturedSamples = Int(
            AudioCaptureEngine.maximumDuration
                * AudioCaptureEngine.sampleRate
        )
        captureStorage = .allocate(capacity: maximumCapturedSamples)
        captureStorage.initialize(
            repeating: 0,
            count: maximumCapturedSamples
        )
        self.onLevel = onLevel
        self.onFailure = onFailure
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        converter.primeMethod = .normal
    }

    deinit {
        secureZeroMemory(
            UnsafeMutableRawPointer(sourceScratch),
            byteCount: Self.drainChunkFrames
                * MemoryLayout<Float>.stride
        )
        sourceScratch.deinitialize(count: Self.drainChunkFrames)
        sourceScratch.deallocate()

        secureZeroMemory(
            UnsafeMutableRawPointer(captureStorage),
            byteCount: maximumCapturedSamples
                * MemoryLayout<Float>.stride
        )
        captureStorage.deinitialize(count: maximumCapturedSamples)
        captureStorage.deallocate()
    }

    func ingestFromRealtimeThread(_ buffer: AVAudioPCMBuffer) {
        ring.write(buffer)
    }

    func drainTick() {
        drainAvailableInput()
        emitLevelIfDue()
    }

    func stopAcceptingInput() {
        ring.stopAcceptingInput()
    }

    func copySamples(lastSeconds: TimeInterval?) -> [Float] {
        drainAvailableInput()
        let requestedCount: Int
        if let lastSeconds {
            requestedCount = max(
                0,
                Int(lastSeconds * AudioCaptureEngine.sampleRate)
            )
        } else {
            requestedCount = capturedSampleCount
        }
        let count = min(requestedCount, capturedSampleCount)
        let start = capturedSampleCount - count
        var result = [Float](repeating: 0, count: count)
        result.withUnsafeMutableBufferPointer { destination in
            guard let baseAddress = destination.baseAddress else { return }
            baseAddress.update(
                from: UnsafePointer(captureStorage.advanced(by: start)),
                count: count
            )
        }
        return result
    }

    func drainAndReturnSampleCount() -> Int {
        drainAvailableInput()
        return capturedSampleCount
    }

    func finishAndTakeSnapshot() -> AudioRecordingSnapshot {
        drainAvailableInput()
        flushConverter()

        let count = max(capturedSampleCount, 1)
        let result = AudioRecordingSnapshot(
            samples: copyCapturedStorage(),
            sampleRate: AudioCaptureEngine.sampleRate,
            duration: Double(capturedSampleCount)
                / AudioCaptureEngine.sampleRate,
            overallRMS: capturedSampleCount > 0
                ? Float(sqrt(sumOfSquares / Double(count)))
                : 0,
            peak: peak,
            voicedFraction: capturedSampleCount > 0
                ? Float(voicedSamples) / Float(count)
                : 0,
            wasTruncated: truncated
                || ring.currentFlags().droppedFrames
        )
        zeroize()
        return result
    }

    func zeroize() {
        ring.zeroize()
        converter.reset()
        secureZeroMemory(
            UnsafeMutableRawPointer(sourceScratch),
            byteCount: Self.drainChunkFrames
                * MemoryLayout<Float>.stride
        )
        secureZeroMemory(
            UnsafeMutableRawPointer(captureStorage),
            byteCount: maximumCapturedSamples
                * MemoryLayout<Float>.stride
        )
        if let source = sourceBuffer.floatChannelData?.pointee {
            secureZeroMemory(
                UnsafeMutableRawPointer(source),
                byteCount: Int(sourceBuffer.frameCapacity)
                    * MemoryLayout<Float>.stride
            )
        }
        if let output = outputBuffer.floatChannelData?.pointee {
            secureZeroMemory(
                UnsafeMutableRawPointer(output),
                byteCount: Int(outputBuffer.frameCapacity)
                    * MemoryLayout<Float>.stride
            )
        }
        sourceBuffer.frameLength = 0
        outputBuffer.frameLength = 0
        capturedSampleCount = 0
        sumOfSquares = 0
        peak = 0
        voicedSamples = 0
    }

    private func drainAvailableInput() {
        guard terminalFailure == nil else { return }

        let flags = ring.currentFlags()
        if flags.formatMismatch {
            reportFailure(AudioCaptureError.routeChanged)
            return
        }
        if flags.droppedFrames {
            truncated = true
        }

        while capturedSampleCount < maximumCapturedSamples {
            let frameCount = ring.read(
                into: sourceScratch,
                maximumFrames: Self.drainChunkFrames
            )
            guard frameCount > 0 else { break }
            convert(frameCount: frameCount)
            if terminalFailure != nil {
                break
            }
        }

        if capturedSampleCount >= maximumCapturedSamples {
            truncated = true
            ring.stopAcceptingInput()
        }
    }

    private func convert(frameCount: Int) {
        guard
            let source = sourceBuffer.floatChannelData?.pointee
        else {
            reportFailure(AudioCaptureError.unsupportedInputFormat)
            return
        }

        source.update(
            from: UnsafePointer(sourceScratch),
            count: frameCount
        )
        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)
        outputBuffer.frameLength = 0

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError
        ) { [sourceBuffer] _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }

        if status == .error {
            reportFailure(
                AudioCaptureError.conversionFailed(
                    conversionError?.localizedDescription
                        ?? "неизвестная ошибка AVAudioConverter"
                )
            )
            return
        }
        appendConvertedOutput()
    }

    private func flushConverter() {
        guard terminalFailure == nil, !truncated else { return }

        for _ in 0..<4 {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }

            if status == .error {
                reportFailure(
                    AudioCaptureError.conversionFailed(
                        conversionError?.localizedDescription
                            ?? "ошибка завершения AVAudioConverter"
                    )
                )
                return
            }

            let producedFrames = Int(outputBuffer.frameLength)
            appendConvertedOutput()
            if producedFrames == 0 || status == .endOfStream {
                return
            }
        }
    }

    private func appendConvertedOutput() {
        guard
            let output = outputBuffer.floatChannelData?.pointee
        else {
            reportFailure(AudioCaptureError.unsupportedInputFormat)
            return
        }

        let producedFrames = Int(outputBuffer.frameLength)
        let remaining = maximumCapturedSamples - capturedSampleCount
        let acceptedFrames = min(producedFrames, max(remaining, 0))
        if acceptedFrames < producedFrames {
            truncated = true
            ring.stopAcceptingInput()
        }
        guard acceptedFrames > 0 else { return }

        captureStorage.advanced(by: capturedSampleCount).update(
            from: UnsafePointer(output),
            count: acceptedFrames
        )

        for index in 0..<acceptedFrames {
            let sample = output[index].isFinite ? output[index] : 0
            if sample != output[index] {
                captureStorage[capturedSampleCount + index] = 0
            }
            let absolute = abs(sample)
            sumOfSquares += Double(sample * sample)
            peak = max(peak, absolute)
            if absolute >= 0.006 {
                voicedSamples += 1
            }
        }
        capturedSampleCount += acceptedFrames
    }

    private func emitLevelIfDue() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard
            now &- lastLevelEmission
                >= Self.levelIntervalNanoseconds
        else {
            return
        }
        lastLevelEmission = now
        guard let meter = ring.takeMeter() else { return }

        let rms = Float(
            sqrt(meter.sumOfSquares / Double(max(meter.frameCount, 1)))
        )
        let decibels = rms > 0 ? 20 * log10(rms) : -80
        let normalized = min(max((decibels + 55) / 45, 0.03), 1)
        onLevel(max(normalized, min(meter.peak, 1) * 0.25))
    }

    private func reportFailure(_ error: Error) {
        guard terminalFailure == nil else { return }
        terminalFailure = error
        truncated = true
        ring.stopAcceptingInput()
        onFailure(error)
    }

    private func copyCapturedStorage() -> [Float] {
        var result = [Float](
            repeating: 0,
            count: capturedSampleCount
        )
        result.withUnsafeMutableBufferPointer { destination in
            guard let baseAddress = destination.baseAddress else { return }
            baseAddress.update(
                from: UnsafePointer(captureStorage),
                count: capturedSampleCount
            )
        }
        return result
    }
}
