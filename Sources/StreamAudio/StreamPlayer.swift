//
//  File.swift
//
//
//  Created by feichao on 2023/7/10.
//

import AudioToolbox

import OSLog

fileprivate let logger = Logger(subsystem: "StreamAudio", category: "StreamPlayer")

public enum FillDataStatus {
    case hasMoreData
    case noEnoughData
    case eof
}

public protocol StreamPlayerDelegate: AnyObject {
    func onFillData(_ buffer: inout AudioQueueBuffer, packetDescriptions: inout [AudioStreamPacketDescription]) -> FillDataStatus
    func onStarted()
    func onStopping()
    func onStopped()
    func onPaused()
}

public extension StreamPlayerDelegate {
    func onStarted() {}
    func onStopping() {}
    func onStopped() {}
    func onPaused() {}
}

public enum RunningState: String {
    case created
    case stopped
    case stopping
    case playing
    case paused
    case disposed
}

private final class StreamPlayerCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _player: StreamPlayer?
    private var activeCallbacks = 0

    init(player: StreamPlayer) {
        self._player = player
    }

    func beginCallback() -> StreamPlayer? {
        lock.lock()
        guard let player = _player else {
            lock.unlock()
            return nil
        }
        activeCallbacks += 1
        lock.unlock()
        return player
    }

    func endCallback() {
        lock.withLock {
            activeCallbacks -= 1
        }
    }

    var hasActiveCallbacks: Bool {
        lock.withLock { activeCallbacks > 0 }
    }

    func invalidate() {
        lock.withLock {
            _player = nil
        }
    }
}

public final class StreamPlayer: @unchecked Sendable {
    private var audioQueue: AudioQueueRef? = nil
    private var _runningState: RunningState = .created
    private var runningStateLock: NSLock = NSLock()
    public private(set) var runningState: RunningState {
        set(value) {
            runningStateLock.withLock {
                _runningState = value
            }
        }

        get {
            runningStateLock.withLock {
                _runningState
            }
        }
    }
    private var asbd: AudioStreamBasicDescription
    private let delegateLock = NSLock()
    private weak var _delegate: StreamPlayerDelegate?
    public weak var delegate: StreamPlayerDelegate? {
        get { delegateLock.withLock { _delegate } }
        set { delegateLock.withLock { _delegate = newValue } }
    }
    private var pendingBuffersLock = NSLock()
    private var pendingBuffers: [AudioQueueBufferRef] = []
    private var callbackContext: StreamPlayerCallbackContext?
    private var callbackUserData: UnsafeMutableRawPointer?
    private var isRunningPropertyListenerRegistered = false

    public init(asbd: AudioStreamBasicDescription) throws {
        self.asbd = asbd

        let callbackContext = StreamPlayerCallbackContext(player: self)
        self.callbackContext = callbackContext
        self.callbackUserData = Unmanaged.passRetained(callbackContext).toOpaque()

        do {
            guard let callbackUserData else {
                throw StreamAudioError(errorDescription: "AudioQueue callback context empty")
            }

            var status = AudioQueueNewOutput(&self.asbd, Self.handleOutputBuffer, callbackUserData, nil, nil, 0, &audioQueue)
            guard status == noErr, let audioQueue else {
                logger.error("AudioQueueNewOutput error: \(status)")
                throw StreamAudioError(errorDescription: "AudioQueueNewOutput error: \(status)")
            }

            // allocate buffers
            let buffersCount = 5
            let bufferSize = 4096
            for _ in 0..<buffersCount {
                var buffer: AudioQueueBufferRef?
                let status = AudioQueueAllocateBuffer(audioQueue, UInt32(bufferSize), &buffer)
                guard status == noErr, let buffer else {
                    logger.error("AudioQueueAllocateBuffer error: \(status)")
                    throw StreamAudioError(errorDescription: "AudioQueueAllocateBuffer error: \(status)")
                }
                pushPendingAudioQueueBuffer(buffer)
            }

            status = AudioQueueAddPropertyListener(audioQueue, kAudioQueueProperty_IsRunning, Self.propertyListener, callbackUserData)
            guard status == noErr else {
                logger.error("AudioQueueAddPropertyListener for `IsRunning` error: \(status)")
                throw StreamAudioError(errorDescription: "AudioQueueAddPropertyListener for `IsRunning` error: \(status)")
            }
            isRunningPropertyListenerRegistered = true
        } catch {
            cleanupAfterFailedInitialization()
            throw error
        }
    }

    private func cleanupAfterFailedInitialization() {
        callbackContext?.invalidate()
        if let audioQueue {
            AudioQueueDispose(audioQueue, true)
            self.audioQueue = nil
        }
        releaseCallbackContext()
    }

    private func releaseCallbackContext() {
        guard audioQueue == nil, let callbackUserData else {
            return
        }
        callbackContext?.invalidate()
        Unmanaged<StreamPlayerCallbackContext>.fromOpaque(callbackUserData).release()
        self.callbackUserData = nil
        self.callbackContext = nil
    }

    private func abandonCallbackContext() {
        callbackContext?.invalidate()
        callbackUserData = nil
        callbackContext = nil
    }

    private func pushPendingAudioQueueBuffer(_ buffer: AudioQueueBufferRef) {
        pendingBuffersLock.withLock {
            pendingBuffers.append(buffer)
        }
    }

    private func popPendingAudioQueueBuffer() -> AudioQueueBufferRef? {
        pendingBuffersLock.withLock {
            pendingBuffers.popLast()
        }
    }

    private func countPendingAudioQueueBuffer() -> Int {
        pendingBuffersLock.withLock {
            pendingBuffers.count
        }
    }

    private func enqueuePendingBuffers() throws {
        guard let audioQueue, let callbackUserData else {
            return
        }
        while let buffer = popPendingAudioQueueBuffer() {
            if !Self.handleOutputBufferCallback(callbackUserData, audioQueue, buffer) {
                break
            }
        }
    }

    public func notifyNewData() throws {
        if runningState == .paused {
            try play()
        }
    }

    public var isRunning: Bool {
        runningState == .playing
    }

    public func play() throws {
        guard let queue = audioQueue else {
            logger.error("audioQueue empty")
            throw StreamAudioError(errorDescription: "audioQueue empty")
        }

        let previousState = runningState
        switch previousState {
        case .created, .paused:
            break
        case .playing:
            throw StreamAudioError(errorDescription: "AudioQueue is playing")
        case .stopping, .stopped, .disposed:
            logger.error("AudioQueue is stopped or disposed")
            throw StreamAudioError(errorDescription: "AudioQueue is stopped or disposed")
        }

        logger.info("start audio queue")
        // Mark playing BEFORE refilling: the refill goes through the same
        // callback path as the AudioQueue, whose state guard rejects buffers
        // while paused. With the old order (refill first, then set playing)
        // every idle buffer bounced back to the pending list; if the queue had
        // also drained all in-flight buffers during the pause, it restarted
        // with nothing enqueued and never fired a callback again — permanently
        // starving the parser and hanging waitForStop().
        runningState = .playing
        do {
            try enqueuePendingBuffers()
        } catch {
            runningState = previousState
            throw error
        }

        // The refill can hit EOF and stop the player synchronously.
        guard runningState == .playing else {
            return
        }

        let status = AudioQueueStart(queue, nil)
        guard status == noErr else {
            logger.error("AudioQueueStart error: \(status)")
            runningState = previousState
            throw StreamAudioError(errorDescription: "AudioQueueStart error: \(status)")
        }

        delegate?.onStarted()
    }

    public func pause() throws {
        logger.info("pause")
        guard runningState == .playing else {
            logger.error("AudioQueue is not running")
            return
        }
        guard let queue = audioQueue else {
            throw StreamAudioError(errorDescription: "audioQueue empty")
        }
        runningState = .paused
        let status = AudioQueuePause(queue)
        guard status == noErr else {
            logger.error("AudioQueuePause error: \(status)")
            throw StreamAudioError(errorDescription: "AudioQueuePause error: \(status)")
        }
        delegate?.onPaused()
    }

    public func stop(_ immediate: Bool = true) throws {
        if runningState == .stopping || runningState == .stopped || runningState == .disposed {
            return
        }
        guard runningState == .playing || runningState == .paused else {
            logger.error("AudioQueue is not running")
            return
        }
        guard let queue = audioQueue else {
            throw StreamAudioError(errorDescription: "audioQueue empty")
        }
        runningState = .stopping
        let status = AudioQueueStop(queue, immediate)
        guard status == noErr else {
            logger.error("AudioQueueStop error: \(status)")
            throw StreamAudioError(errorDescription: "AudioQueueStop error: \(status)")
        }

        delegate?.onStopping()
        if immediate {
            runningState = .stopped
            delegate?.onStopped()
        }
    }

    public func dispose(_ immediate: Bool = true) throws {
        guard runningState != .disposed else {
            logger.error("AudioQueue is disposed")
            return
        }
        guard let queue = audioQueue else {
            throw StreamAudioError(errorDescription: "audioQueue empty")
        }
        runningState = .disposed
        let shouldReleaseCallbackContext = !(callbackContext?.hasActiveCallbacks ?? false)
        callbackContext?.invalidate()
        if isRunningPropertyListenerRegistered, let callbackUserData {
            let removeStatus = AudioQueueRemovePropertyListener(queue, kAudioQueueProperty_IsRunning, Self.propertyListener, callbackUserData)
            if removeStatus != noErr {
                logger.error("AudioQueueRemovePropertyListener for `IsRunning` error: \(removeStatus)")
            }
            isRunningPropertyListenerRegistered = false
        }
        let status = AudioQueueDispose(queue, immediate)
        guard status == noErr else {
            logger.error("AudioQueueDispose error: \(status)")
            throw StreamAudioError(errorDescription: "AudioQueueDispose error: \(status)")
        }
        audioQueue = nil
        if shouldReleaseCallbackContext {
            releaseCallbackContext()
        } else {
            abandonCallbackContext()
        }
    }

    private static func callbackContext(from userData: UnsafeMutableRawPointer?) -> StreamPlayerCallbackContext? {
        guard let userData else {
            return nil
        }
        return Unmanaged<StreamPlayerCallbackContext>.fromOpaque(userData).takeUnretainedValue()
    }

    private static func handleOutputBufferCallback(_ userData: UnsafeMutableRawPointer?, _ queue: AudioQueueRef, _ buffer: AudioQueueBufferRef) -> Bool {
        guard let context = callbackContext(from: userData), let player = context.beginCallback() else {
            return false
        }
        defer { context.endCallback() }

        let state = player.runningState
        if state == .stopping {
            return false
        }

        let delegateSnapshot = player.delegate
        guard state == .playing || state == .created else {
            if state == .paused {
                player.pushPendingAudioQueueBuffer(buffer)
            }
            logger.error("runningState is \(state.rawValue, privacy: .public), delegate is \(delegateSnapshot != nil, privacy: .public), exit handleOutputBuffer")
            return false
        }
        guard let delegate = delegateSnapshot else {
            player.pushPendingAudioQueueBuffer(buffer)
            logger.error("runningState is \(state.rawValue, privacy: .public), delegate is false, exit handleOutputBuffer")
            return false
        }
        var packetDescriptions: [AudioStreamPacketDescription] = []
        let fillStatus = delegate.onFillData(&buffer.pointee, packetDescriptions: &packetDescriptions)
        switch fillStatus {
        case .noEnoughData:
            player.pushPendingAudioQueueBuffer(buffer)
            try? player.pause()
            return false
        case .eof:
            logger.info("reach eof, stop player")
            try? player.stop(false)
            return false
        case .hasMoreData:
            let status = if packetDescriptions.isEmpty {
                AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            } else {
                AudioQueueEnqueueBuffer(queue, buffer, UInt32(packetDescriptions.count), &packetDescriptions)
            }
            guard status == noErr else {
                logger.error("AudioQueueEnqueueBuffer error: \(status)")
                return true
            }
            return true
        }
    }

    private static let handleOutputBuffer: AudioQueueOutputCallback = { userData, queue, buffer in
        _ = handleOutputBufferCallback(userData, queue, buffer)
        return
    }

    private static func isAudioQueueRunning(_ queue: AudioQueueRef) -> Bool? {
        let propertyId = kAudioQueueProperty_IsRunning
        var isRunning: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size);
        let status = AudioQueueGetProperty(queue, propertyId, &isRunning, &dataSize);
        guard status == noErr else {
            logger.error("AudioQueueGetProperty \(propertyId) error: \(status)")
            return nil
        }

        return isRunning == 1
    }

    private static let propertyListener: AudioQueuePropertyListenerProc = { userData, queue, propertyId in
        guard let context = callbackContext(from: userData), let player = context.beginCallback() else {
            return
        }
        defer { context.endCallback() }

        guard let isRunning = isAudioQueueRunning(queue) else {
            return
        }

        if !isRunning {
            player.delegate?.onStopped()
        }
    }

    deinit {
        if runningState != .disposed {
            do {
                try dispose()
            } catch {}
        }
        releaseCallbackContext()
    }
}
