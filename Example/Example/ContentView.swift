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
                        let downloader = Mp3Downloader(URL(string: "https://file-examples.com/storage/fede3f30f864a1f979d2bf0/2017/11/file_example_MP3_700KB.mp3")!)
                        try downloader.download()
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


class Mp3Downloader : NSObject, URLSessionDataDelegate {
    private var task: URLSessionDataTask? = nil
    private var parser: StreamParser? = nil
    private var decoder: StreamDecoder? = nil
    private let url: URL
    private let buffer: StreamAudioBuffer = StreamAudioBuffer(path: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("a.mp3"))
    
    var backgroundTask: Task<(), Never>?
    
    let audioEngine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()
    let audioEngineSetuped = OneShotChannel()
    
    init(_ url: URL) {
        self.url = url
    }
    
    private func receivedPcmBuffer(buffer: AVAudioPCMBuffer) async {
        audioEngineSetuped.finish(())
        await playerNode.scheduleBuffer(buffer)
    }
    
    private func setupAudioEngine(format: AVAudioFormat) {
        
        // Attach the player node to the audio engine.
        audioEngine.attach(playerNode)

        // Connect the player node to the output node.
        audioEngine.connect(playerNode,
                            to: audioEngine.mainMixerNode,
                            format: format)
    }
    
    func play() async throws {
        try download()
        try await audioEngineSetuped.wait()
        
        try audioEngine.start()
        playerNode.play()
    }
    
    func stop() {
        playerNode.stop()
        audioEngine.stop()
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
        
        parser = try StreamParser.create(fileType: kAudioFileFLACType)
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
        
        while !Task.isCancelled {
            let data = try reader.read(upToCount: 1024)
            guard let data else {
                logger.error("no data available now, sleep")
                try await Task.sleep(for: .milliseconds(100))
                // retry later
                continue
            }
            if data.isEmpty {
                logger.error("reach EOF.")
                break
            }
            try await parseData(data: data)
        }
        logger.info("finish background task")
    }
    
    private func parseData(data: Data) async throws {
        logger.info("new data: \(data.count)")
        
        guard let parser else {
            return
        }
        
        let packets = try parser.parseBytes(data)
        logger.info("parsed packets: \(packets.count)")
        
        guard parser.readyToProducePackets() else {
            logger.info("Not ready to produce packets, wait for next time.")
            return
        }
        
        if decoder == nil {
            guard let audioFormat = parser.audioFormat() else {
                logger.error("No audio format got from parser. Return early.")
                return
            }
            decoder = StreamDecoder(sourceFormat: audioFormat)
            guard let decoder else {
                logger.error("Create StreamDecoder error.")
                return
            }
            setupAudioEngine(format: decoder.pcmFormat)
        }
        
        let decoder = self.decoder!
        
        for packet in packets {
            let pcmBuffer = try decoder.decode(data: packet.data, packetCount: UInt32(packet.packetCount), packetDescriptions: packet.packetDescription)
            if let pcmBuffer {
                await receivedPcmBuffer(buffer: pcmBuffer)
                logger.info("new pcmbuffer")
            } else {
                logger.info("reach end of stream")
            }
        }
        logger.info("finished parsedData")
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
    }
}


@available(iOS 16.0, macOS 13.0, *)
#Preview {
    ContentView()
}
