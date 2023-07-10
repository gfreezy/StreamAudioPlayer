//
//  File.swift
//  
//
//  Created by feichao on 2023/7/10.
//

import AudioToolbox

import OSLog

fileprivate let logger = Logger(subsystem: "StreamAudio", category: "StreamPlayer")

public protocol StreamPlayerDelegate: AnyObject {
    func onFillData(_ buffer: inout AudioQueueBuffer, packetDescriptions: inout [AudioStreamPacketDescription], pause: inout Bool) -> Int
    func onStart()
    func onStop()
    func onPause()
}

public enum RunningState: String {
    case created
    case stopped
    case playing
    case paused
    case disposed
}

public class StreamPlayer {
    private var audioQueue: AudioQueueRef? = nil
    private var _runningState: RunningState = .created
    private var runningStateLock: NSLock = NSLock()
    private(set) var runningState: RunningState {
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
    public weak var delegate: StreamPlayerDelegate?
    
    public init(asbd: AudioStreamBasicDescription) throws {
        self.asbd = asbd
        var status = AudioQueueNewOutput(&self.asbd, handleOutputBuffer, Unmanaged.passUnretained(self).toOpaque(), nil, nil, 0, &audioQueue)
        guard status == noErr, let audioQueue else {
            logger.error("AudioQueueNewOutput error: \(status)")
            throw StreamAudioError(errorDescription: "AudioQueueNewOutput error: \(status)")
        }
        
        // allocate buffers
        let buffersCount = 5
        let bufferSize = 4096
        for _ in 0..<buffersCount {
            var buffer: AudioQueueBufferRef?
            status = AudioQueueAllocateBuffer(audioQueue, UInt32(bufferSize), &buffer)
            guard status == noErr, let buffer else {
                logger.error("AudioQueueAllocateBuffer error: \(status)")
                throw StreamAudioError(errorDescription: "AudioQueueAllocateBuffer error: \(status)")
            }
            handleOutputBuffer(Unmanaged.passUnretained(self).toOpaque(), audioQueue, buffer)
        }
        
        status = AudioQueueAddPropertyListener(audioQueue, kAudioQueueProperty_IsRunning, propertyListener, Unmanaged.passUnretained(self).toOpaque())
        guard status == noErr else {
            logger.error("AudioQueueAddPropertyListener for `IsRunning` error: \(status)")
            throw StreamAudioError(errorDescription: "AudioQueueAddPropertyListener for `IsRunning` error: \(status)")
        }
    }

    public func notifyNewData() throws {
        if runningState == .created || runningState == .paused {
            try start()
        }
    }
    
    public func start() throws {
        if runningState == .stopped || runningState == .disposed {
            logger.error("AudioQueue is stopped or disposed")
            return
        }
        guard let queue = audioQueue else {
            logger.error("audioQueue empty")
            throw StreamAudioError(errorDescription: "audioQueue empty")
        }

        runningState = .playing
        
        let status = AudioQueueStart(queue, nil)
        guard status == noErr else {
            logger.error("AudioQueueStart error: \(status)")
            throw StreamAudioError(errorDescription: "AudioQueueStart error: \(status)")
        }
        
        delegate?.onStart()
    }
    
    public func pause() throws {
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
        delegate?.onPause()
    }
    
    public func stop(_ immediate: Bool = true) throws {
        if runningState == .stopped || runningState == .disposed {
            return
        }
        guard runningState == .playing || runningState == .paused else {
            logger.error("AudioQueue is not running")
            return
        }
        guard let queue = audioQueue else {
            throw StreamAudioError(errorDescription: "audioQueue empty")
        }
        runningState = .stopped
        let status = AudioQueueStop(queue, immediate)
        guard status == noErr else {
            logger.error("AudioQueueStop error: \(status)")
            throw StreamAudioError(errorDescription: "AudioQueueStop error: \(status)")
        }
        
        delegate?.onStop()
        try dispose()
    }
    
    func dispose(_ immediate: Bool = true) throws {
        guard runningState != .disposed else {
            logger.error("AudioQueue is disposed")
            return
        }
        guard let queue = audioQueue else {
            throw StreamAudioError(errorDescription: "audioQueue empty")
        }
        runningState = .disposed
        let status = AudioQueueDispose(queue, immediate)
        guard status == noErr else {
            logger.error("AudioQueueDispose error: \(status)")
            throw StreamAudioError(errorDescription: "AudioQueueDispose error: \(status)")
        }
        delegate?.onStop()
    }
    
    private let handleOutputBuffer: AudioQueueOutputCallback = { userData, queue, buffer in
        let player = Unmanaged<StreamPlayer>.fromOpaque(userData!).takeUnretainedValue()
        guard player.runningState == .playing || player.runningState == .created else {
            return
        }
        var packetDescriptions: [AudioStreamPacketDescription] = []
        var pause = false
        let bytes = player.delegate?.onFillData(&buffer.pointee, packetDescriptions: &packetDescriptions, pause: &pause) ?? 0
        if bytes == 0 {
            memset(buffer.pointee.mAudioData, 0, Int(buffer.pointee.mAudioDataBytesCapacity))
            buffer.pointee.mAudioDataByteSize = buffer.pointee.mAudioDataBytesCapacity
        }
        if player.runningState == .playing {
            if bytes == 0 {
                logger.info("enqueue empty buffer")
            } else {
                logger.info("enqueue buffer: \(buffer.pointee.mAudioDataByteSize)")
            }
        }
        var status = if packetDescriptions.isEmpty {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        } else {
            AudioQueueEnqueueBuffer(queue, buffer, UInt32(packetDescriptions.count), &packetDescriptions)
        }
        guard status == noErr else {
            logger.error("AudioQueueEnqueueBuffer error: \(status)")
            return
        }
//        status = AudioQueuePrime(queue, 0, nil)
//        guard status == noErr else {
//            logger.error("AudioQueuePrime error: \(status)")
//            return
//        }
        do {
            if player.runningState == .playing && bytes == 0 {
                if pause {
                    try player.pause()
                } else {
                    try player.stop(false)
                }
            }
        } catch {
            logger.error("pause in AudioQueueOutputCallback error: \(error)")
        }
    }
    
    private let propertyListener: AudioQueuePropertyListenerProc = { userData, queue, propertyId in
        let player = Unmanaged<StreamPlayer>.fromOpaque(userData!).takeUnretainedValue()
        
        if (propertyId == kAudioQueueProperty_IsRunning) {
            var isRunning: UInt32 = 0
            var dataSize = UInt32(MemoryLayout<UInt32>.size);
            let status = AudioQueueGetProperty(queue, propertyId, &isRunning, &dataSize);
            guard status == noErr else {
                logger.error("AudioQueueGetProperty \(propertyId) error: \(status)")
                return
            }
            
            if isRunning == 0 {
                do {
                    try player.stop(false)
                } catch {
                    logger.error("stop in propertyListener error: \(error)")
                }
            }
        }
    }
    
    deinit {
        do {
            try dispose()
        } catch {}
    }
}
