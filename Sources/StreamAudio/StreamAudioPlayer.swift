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

fileprivate let logger = Logger(subsystem: "StreamAudioPlayer", category: "Mp3Downloader")

public class StreamAudioPlayer : NSObject {
    private var urlSessionTask: URLSessionDataTask? = nil
    private var parser: StreamParser? = nil
    private let url: URL
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
    

    public init(_ url: URL, cachePath: URL, fileType: AudioFileTypeID = 0, pendingPacketsLimit: Int = 50) {
        self.url = url
        self.pendingPacketsLimit = pendingPacketsLimit
        self.buffer = StreamAudioBuffer(path: cachePath)
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
        try download()
        try await audioEngineSetuped.wait()
        
        try streamPlayer?.play()
    }
    
    public func stop() throws {
        backgroundTask?.cancel()
        try streamPlayer?.stop()
    }
    
    private func cancelBackgroundTask () {
        if let backgroundTask {
            backgroundTask.cancel()
            self.backgroundTask = nil
        }
    }

    public func download() throws {
        guard urlSessionTask == nil else {
            return
        }
        
        parser = try StreamParser.create(fileType: fileType)
        urlSessionTask = URLSession.shared.dataTask(with: url)
        urlSessionTask?.delegate = self
        urlSessionTask?.resume()
        
        backgroundTask = Task.detached { [weak self] in
            guard let self else {
                return
            }
            do {
                try await processDataInBackground()
            } catch {
                logger.error("process background error: \(error)")
            }
            backgroundTask = nil
        }
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
        dump(parser?.context)
    }
    
    private enum ParseStatus {
        case hasMoreData
        case eof
    }
    
    private func parseEnoughPackets(reader: StreamAudioBufferReader) async throws -> ParseStatus {
        while !Task.isCancelled && pendingPacketCount <= pendingPacketsLimit {
            let data = try reader.read(exact: 20480)
            guard let data else {
                logger.info("no enough data available now, sleep")
                try await Task.sleep(for: .milliseconds(100))
                // retry later
                continue
            }
            if data.isEmpty {
                logger.error("reach EOF.")
                return .eof
            }
            try parseData(data: data)
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

extension StreamAudioPlayer: URLSessionDataDelegate, StreamPlayerDelegate {
    
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
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        logger.info("finished recved all data.")
        try! buffer.close()
        
        if let error {
            logger.error("complele error: \(error)")
            return
        }
    }
    
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        logger.info("recved data: \(data.count)")
        do {
            try buffer.write(contentsOf: data)
        } catch {
            logger.error("write data error: \(error)")
        }
    }
    
}
