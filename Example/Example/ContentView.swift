//
//  ContentView.swift
//  Example
//
//  Created by feichao on 2023/7/1.
//

import SwiftUI
import StreamAudio
import OSLog
import AudioToolbox
import AVFAudio


fileprivate let logger = Logger(subsystem: "StreamAudio", category: "Mp3Downloader")

struct ContentView: View {
    @State var downloader: Mp3Downloader? = nil
    
    init() {
        
    }
    
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
            Button("Download") {
                Task {
                    do {
                        try self.downloader?.stop()
                        let downloader = Mp3Downloader(URL(string: "https://freetestdata.com/wp-content/uploads/2021/09/Free_Test_Data_100KB_MP3.mp3")!)
                        try await downloader.play()
                        self.downloader = downloader
                    } catch {
                        logger.error("download error: \(error)")
                    }
                }
            }
        }
        .padding()
    }
}


private let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("a.mp3")

class Mp3Downloader : NSObject, URLSessionDataDelegate, StreamPlayerDelegate {

    private var task: URLSessionDataTask? = nil
    private var parser: StreamParser? = nil
    private let url: URL
    private let buffer: StreamAudioBuffer = StreamAudioBuffer(path: path)
    private var totalPackets = 0
    private var totalPcmBuffers = 0
    private var backgroundTask: Task<(), Never>?
    private var streamPlayer: StreamPlayer? = nil
    private var pendingPackets: [StreamPacket] = []
    private var pendingLock: NSLock = NSLock()
    
    private let audioEngineSetuped = OneShotChannel()
    let file = try! AVAudioFile(forWriting: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("output.wav"),
                                settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2])
    
    init(_ url: URL) {
        self.url = url
        logger.info("store path: \(path, privacy: .public)")
    }
    
    func onFillData(_ buffer: inout AudioQueueBuffer, packetDescriptions: inout [AudioStreamPacketDescription], pause: inout Bool) -> Int {
        let packet: StreamPacket? = pendingLock.withLock {
            guard !pendingPackets.isEmpty else {
                return nil
            }
            let packet = pendingPackets.removeFirst()
            assert(packet.data.count < buffer.mAudioDataBytesCapacity)
            return packet
        }
        guard let packet else {
            return 0
        }
        packet.data.withUnsafeBytes { ptr in
            buffer.mAudioData.copyMemory(from: ptr.baseAddress!, byteCount: ptr.count)
        }
        buffer.mAudioDataByteSize = UInt32(packet.data.count)
        
        if let d = packet.packetDescription {
            packetDescriptions.append(d)
        }
        
        return packet.data.count
        
    }
    
    func onStart() {
        
    }
    
    func onStop() {
        logger.info("stop")
    }
    
    func onPause() {
        logger.info("pause")
    }
    
    private func receivedPacket(_ packet: StreamPacket) {
        pendingLock.withLock {
            pendingPackets.append(packet)
        }
        audioEngineSetuped.finish(())
        totalPcmBuffers += 1
        do {
            try streamPlayer?.notifyNewData()
        } catch {}
    }
    
    private func setupAudioEngine(format: AVAudioFormat) throws {
        streamPlayer = try StreamPlayer(asbd: format.streamDescription.pointee)
        streamPlayer?.delegate = self
    }
    
    func play() async throws {
        try download()
        try await audioEngineSetuped.wait()
        
        try streamPlayer?.start()
    }
    
    func stop() throws {
        backgroundTask?.cancel()
        try streamPlayer?.stop()
    }
    
    private func cancelBackgroundTask () {
        if let backgroundTask {
            backgroundTask.cancel()
            self.backgroundTask = nil
        }
    }

    func download() throws {
        guard task == nil else {
            return
        }
        
        parser = try StreamParser.create(fileType: kAudioFileMP3Type)
        task = URLSession.shared.dataTask(with: url)
        task?.delegate = self
        task?.resume()
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
        
        var totalData = 0
        while !Task.isCancelled {
            let data = try reader.read(exact: 20480)
            guard let data else {
                logger.info("no enough data available now, sleep")
                try await Task.sleep(for: .milliseconds(100))
                // retry later
                continue
            }
            if data.isEmpty {
                logger.error("reach EOF.")
                break
            }
            logger.info("read data: \(data.count)")
            totalData += data.count
            try await parseData(data: data)
        }
        logger.info("finish background task, total data: \(totalData), total packets: \(self.totalPackets, privacy: .public), total pcm buffers: \(self.totalPcmBuffers, privacy: .public)")
        dump(parser?.context)
    }
    
    private func parseData(data: Data) async throws {
//        logger.info("new data: \(data.count)")
        
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

            try setupAudioEngine(format: audioFormat)
        }
        
        for packet in packets {
            totalPackets += 1
            receivedPacket(packet)
        }
//        logger.info("finished parsedData")
    }
    
    internal func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        logger.info("finished recved all data.")
        try! buffer.close()
        
        if let error {
            logger.error("complele error: \(error)")
            return
        }
    }
    
    internal func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        logger.info("recved data: \(data.count)")
        do {
            try buffer.write(contentsOf: data)
        } catch {
            logger.error("write data error: \(error)")
        }
    }
    
    deinit {
        cancelBackgroundTask()
        do {
            try stop()
        } catch {
            
        }
    }
}


@available(iOS 16.0, macOS 13.0, *)
#Preview {
    ContentView()
}
