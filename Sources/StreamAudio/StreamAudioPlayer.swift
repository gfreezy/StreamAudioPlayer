//
//  File.swift
//  
//
//  Created by feichao on 2023/7/12.
//

import Foundation
import OSLog
import AudioToolbox
import AVFAudio
import Semaphore

fileprivate let logger = Logger(subsystem: "StreamAudio", category: "StreamAudioPlayer")

/// Initialized a new `StreamAudioPlayer` every time.
public class StreamAudioPlayer : NSObject {
    private var parser: StreamParser? = nil
    private let buffer: StreamAudioBuffer
    private let fileType: AudioFileTypeID
    private var totalPackets = 0
    private var totalPcmBuffers = 0
    private var backgroundTask: Task<(), Never>?
    private var streamPlayer: StreamPlayer? = nil
    private var pendingPackets: [StreamPacket] = []
    private var pendingLock: NSLock = NSLock()
    private var pendingPacketsSemaphore = AsyncSemaphore(value: 1)
    private let pendingPacketsLimit: Int
    private var finishedAllPacketsParsing = false
    private let audioEngineSetuped = OneShotChannel()
    private let stoppedSignal = OneShotChannel()

    public init(cachePath: URL? = nil, fileType: AudioFileTypeID = 0, bufferPacketsSize pendingPacketsLimit: Int = 50) {
        self.pendingPacketsLimit = pendingPacketsLimit
        let path = if let cachePath {
            cachePath
        } else {
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: UUID().uuidString)
        }
        self.buffer = StreamAudioBuffer(path: path)
        self.fileType = fileType
    }
    
    private enum PendingPacket {
        case some(StreamPacket)
        case none
        case eof
    }
    
    private func popLeftPendingPackets() -> PendingPacket {
        pendingLock.withLock { () -> PendingPacket in
            switch (pendingPackets.isEmpty, finishedAllPacketsParsing) {
            case (true, true):
                return .eof
            case (true, false):
                return .none
            case (false, _):
                break
            }
            let packet = pendingPackets.removeFirst()
            return .some(packet)
        }
    }
    
    private func finishedParsingAllPackets() {
        pendingLock.withLock {
            finishedAllPacketsParsing = true
        }
    }
    
    private func pushPendingPackets(contentsOf packets: [StreamPacket]) {
        pendingLock.withLock {
            pendingPackets.append(contentsOf: packets)
        }
    }
    
    private var pendingPacketCount: Int {
        pendingLock.withLock {
            pendingPackets.count
        }
    }
    
    public func play() async throws {
        try starBackgroundParsingAndDecoding()
        try await audioEngineSetuped.wait()
        
        try streamPlayer?.play()
    }
    
    public func stop() throws {
        cancelBackgroundTask()
        try streamPlayer?.stop()
    }
    
    public func waitForStop() async throws {
        try await stoppedSignal.wait()
    }
    
    private func cancelBackgroundTask () {
        if let backgroundTask {
            backgroundTask.cancel()
            self.backgroundTask = nil
        }
    }

    public func starBackgroundParsingAndDecoding() throws {
        parser = try StreamParser.create(fileType: fileType)
        backgroundTask = Task.detached { [weak self] in
            guard let self else {
                return
            }
            do {
                try await processDataInBackground()
            } catch {
                logger.error("process background error: \(error)")
            }
        }
    }
    
    public func writeData(_ data: Data) throws {
        do {
            try buffer.write(contentsOf: data)
        } catch {
            logger.error("write data error: \(error)")
        }
    }
    
    public func finishData() throws {
        try buffer.close()
    }
    
    public func newReader() -> StreamAudioBufferReader {
        buffer.newReader()
    }
    
    private func processDataInBackground() async throws {
        let reader = buffer.newReader()
        
        defer {
            finishedParsingAllPackets()
        }
        
        while !Task.isCancelled {
//            logger.info("Wait for pendingPacketsSemaphore.")
            try await pendingPacketsSemaphore.waitUnlessCancelled()
            let status = try await parseEnoughPackets(reader: reader)
            if status == .eof {
                logger.info("Parsed all data, exit.")
                break
            }
        }
        
        logger.info("finish background task, total packets: \(self.totalPackets, privacy: .public), total pcm buffers: \(self.totalPcmBuffers, privacy: .public)")
//        dump(parser?.context)
    }
    
    private enum ParseStatus {
        case hasMoreData
        case eof
    }
    
    private func parseEnoughPackets(reader: StreamAudioBufferReader) async throws -> ParseStatus {
        while !Task.isCancelled && pendingPacketCount <= pendingPacketsLimit {
            let data = try reader.read(exact: 20480)
            switch data {
            case .eof:
                logger.info("reach EOF.")
                return .eof
            case .retry:
                logger.info("no enough data available now, sleep")
                try await Task.sleep(for: .milliseconds(100))
                // retry later
                continue
            case .data(let data):
                try parseData(data: data)
            }
        }
        
        return .hasMoreData
    }
    
    private func onPacketsParsed(_ packets: [StreamPacket]) {
        pushPendingPackets(contentsOf: packets)
        
        audioEngineSetuped.finish(())
        totalPcmBuffers += 1
        do {
            try streamPlayer?.notifyNewData()
            logger.info("notify new data")
        } catch {}
    }
    
    private func parseData(data: Data) throws {
        guard let parser else {
            return
        }
        
        let packets = try parser.parseBytes(data)
        logger.info("parsed packets: \(packets.count)")
        self.totalPackets += packets.count
        
        guard parser.readyToProducePackets() else {
            logger.info("Not ready to produce packets, wait for next time.")
            return
        }
        
        if streamPlayer == nil {
            guard let audioFormat = parser.audioFormat() else {
                logger.error("No audio format got from parser. Return early.")
                return
            }

            let streamPlayer = try StreamPlayer(asbd: audioFormat.streamDescription.pointee)
            streamPlayer.delegate = self
            self.streamPlayer = streamPlayer
        }
        
        onPacketsParsed(packets)
    }
    
    deinit {
        cancelBackgroundTask()
        do {
            try stop()
        } catch {
            
        }
    }
}

extension StreamAudioPlayer: StreamPlayerDelegate {
    public func onFillData(_ buffer: inout AudioQueueBuffer, packetDescriptions: inout [AudioStreamPacketDescription]) -> FillDataStatus {
        let packet = popLeftPendingPackets()
        
        switch packet {
        case .some(let packet):
            assert(packet.data.count < buffer.mAudioDataBytesCapacity)
            pendingPacketsSemaphore.signal()
            
            packet.data.withUnsafeBytes { ptr in
                buffer.mAudioData.copyMemory(from: ptr.baseAddress!, byteCount: ptr.count)
            }
            buffer.mAudioDataByteSize = UInt32(packet.data.count)
            
            if let d = packet.packetDescription {
                packetDescriptions.append(d)
            }
            return .hasMoreData
        case .none:
            pendingPacketsSemaphore.signal()
            return .noEnoughData
        case .eof:
            return .eof
        }
    }
    
    public func onStopped() {
        stoppedSignal.finish(())
    }
}
