import AVFoundation
import Darwin
import Foundation

struct AudioRecordingSnapshot: Sendable {
    var samples: [Float]
    let sampleRate: Double
    let duration: TimeInterval
    let overallRMS: Float
    let peak: Float
    let voicedFraction: Float
    let wasTruncated: Bool

    var containsLikelySpeech: Bool {
        duration >= 0.25
            && peak >= 0.015
            && (overallRMS >= 0.002 || voicedFraction >= 0.025)
    }

    mutating func zeroize() {
        samples.withUnsafeMutableBytes { bytes in
            if let baseAddress = bytes.baseAddress, !bytes.isEmpty {
                secureZeroMemory(baseAddress, byteCount: bytes.count)
            }
        }
        samples.removeAll(keepingCapacity: false)
    }
}

enum AudioCaptureError: LocalizedError {
    case microphoneUnavailable
    case unsupportedInputFormat
    case alreadyRunning
    case routeChanged
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            return "Микрофон недоступен"
        case .unsupportedInputFormat:
            return "Формат микрофона не поддерживается"
        case .alreadyRunning:
            return "Запись уже выполняется"
        case .routeChanged:
            return "Аудиоустройство изменилось во время диктовки"
        case let .conversionFailed(message):
            return "Не удалось преобразовать звук: \(message)"
        }
    }
}

final class AudioCaptureEngine: @unchecked Sendable {
    static let sampleRate = 16_000.0
    static let maximumDuration: TimeInterval = 10 * 60

    private let stateCondition = NSCondition()
    private let drainQueue = DispatchQueue(
        label: "localflow.audio.drain",
        qos: .userInitiated
    )
    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var drainTimer: DispatchSourceTimer?
    private var pipeline: RealtimeAudioPipeline?
    private var configurationObserver: NSObjectProtocol?
    private var starting = false
    private var running = false
    private var errorCallback: (@Sendable (Error) -> Void)?

    func start(
        onLevel: @escaping @Sendable (Float) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws {
        stateCondition.lock()
        guard !running, !starting else {
            stateCondition.unlock()
            throw AudioCaptureError.alreadyRunning
        }
        starting = true
        stateCondition.unlock()

        var localEngine: AVAudioEngine?
        var localInputNode: AVAudioInputNode?
        var localTimer: DispatchSourceTimer?
        var localPipeline: RealtimeAudioPipeline?
        var localObserver: NSObjectProtocol?
        var tapInstalled = false

        do {
            let engine = AVAudioEngine()
            localEngine = engine
            let input = engine.inputNode
            localInputNode = input
            let deviceFormat = input.outputFormat(forBus: 0)
            guard
                deviceFormat.sampleRate.isFinite,
                (4_000...384_000).contains(deviceFormat.sampleRate),
                (1...32).contains(Int(deviceFormat.channelCount))
            else {
                throw AudioCaptureError.unsupportedInputFormat
            }

            let tapFormat: AVAudioFormat
            if deviceFormat.commonFormat == .pcmFormatFloat32 {
                tapFormat = deviceFormat
            } else {
                guard let convertedTapFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: deviceFormat.sampleRate,
                    channels: deviceFormat.channelCount,
                    interleaved: false
                ) else {
                    throw AudioCaptureError.unsupportedInputFormat
                }
                tapFormat = convertedTapFormat
            }

            let pipeline = try RealtimeAudioPipeline(
                sourceSampleRate: tapFormat.sampleRate,
                sourceChannelCount: Int(tapFormat.channelCount),
                onLevel: onLevel,
                onFailure: onError
            )
            localPipeline = pipeline
            let timer = DispatchSource.makeTimerSource(queue: drainQueue)
            localTimer = timer
            timer.setEventHandler { [weak pipeline] in
                pipeline?.drainTick()
            }
            timer.schedule(
                deadline: .now() + .milliseconds(15),
                repeating: .milliseconds(15),
                leeway: .milliseconds(4)
            )
            timer.resume()

            input.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: tapFormat
            ) { [pipeline] buffer, _ in
                pipeline.ingestFromRealtimeThread(buffer)
            }
            tapInstalled = true

            let observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                self?.reportConfigurationChange()
            }
            localObserver = observer

            engine.prepare()
            try engine.start()

            stateCondition.lock()
            self.engine = engine
            inputNode = input
            drainTimer = timer
            self.pipeline = pipeline
            configurationObserver = observer
            errorCallback = onError
            running = true
            starting = false
            stateCondition.broadcast()
            stateCondition.unlock()
        } catch {
            if tapInstalled {
                localInputNode?.removeTap(onBus: 0)
            }
            localEngine?.stop()
            localTimer?.cancel()
            if let localObserver {
                NotificationCenter.default.removeObserver(localObserver)
            }
            if let localPipeline {
                localPipeline.stopAcceptingInput()
                drainQueue.sync {
                    localPipeline.zeroize()
                }
            }

            stateCondition.lock()
            starting = false
            stateCondition.broadcast()
            stateCondition.unlock()
            throw error
        }
    }

    func snapshot(lastSeconds: TimeInterval? = nil) -> [Float] {
        stateCondition.lock()
        let pipeline = self.pipeline
        stateCondition.unlock()
        guard let pipeline else { return [] }

        return drainQueue.sync {
            pipeline.copySamples(lastSeconds: lastSeconds)
        }
    }

    func capturedSampleCount() -> Int {
        stateCondition.lock()
        let pipeline = self.pipeline
        stateCondition.unlock()
        guard let pipeline else { return 0 }

        return drainQueue.sync {
            pipeline.drainAndReturnSampleCount()
        }
    }

    func stop() -> AudioRecordingSnapshot {
        stateCondition.lock()
        while starting {
            stateCondition.wait()
        }

        guard
            running,
            let engine,
            let inputNode,
            let drainTimer,
            let pipeline
        else {
            stateCondition.unlock()
            return Self.emptySnapshot()
        }

        running = false
        let observer = configurationObserver
        self.engine = nil
        self.inputNode = nil
        self.drainTimer = nil
        self.pipeline = nil
        configurationObserver = nil
        errorCallback = nil
        stateCondition.unlock()

        inputNode.removeTap(onBus: 0)
        engine.stop()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        drainTimer.cancel()
        pipeline.stopAcceptingInput()

        return drainQueue.sync {
            pipeline.finishAndTakeSnapshot()
        }
    }

    func cancelAndZeroize() {
        var snapshot = stop()
        snapshot.zeroize()
    }

    private func reportConfigurationChange() {
        stateCondition.lock()
        guard running else {
            stateCondition.unlock()
            return
        }
        let callback = errorCallback
        stateCondition.unlock()
        callback?(AudioCaptureError.routeChanged)
    }

    private static func emptySnapshot() -> AudioRecordingSnapshot {
        AudioRecordingSnapshot(
            samples: [],
            sampleRate: sampleRate,
            duration: 0,
            overallRMS: 0,
            peak: 0,
            voicedFraction: 0,
            wasTruncated: false
        )
    }
}
