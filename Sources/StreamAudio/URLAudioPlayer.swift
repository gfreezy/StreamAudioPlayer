//
//  URLAudioPlayer.swift
//  Example
//
//  Created by feichao on 2023/7/29.
//

import Foundation
import AudioToolbox
import AVFAudio
import OSLog


fileprivate let logger = Logger(subsystem: "StreamAudio", category: "URLAudioPlayer")


public class URLAudioPlayer: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    private var urlSessionTask: URLSessionDataTask? = nil
    private let url: URL
    private let player: StreamAudioPlayer
    
    public init(_ url: URL, cachePath: URL? = nil, fileType: AudioFileTypeID = 0, bufferPacketsSize: Int = 50) {
        self.url = url
        player = StreamAudioPlayer(cachePath: cachePath, fileType: fileType, bufferPacketsSize: bufferPacketsSize)
    }
    
    public func load() {
        guard urlSessionTask == nil else {
            return
        }
        urlSessionTask = URLSession.shared.dataTask(with: url)
        urlSessionTask?.delegate = self
        urlSessionTask?.resume()
    }
    
    public func play() async throws {
        load()
        try await player.play()
    }
    
    public func stop() throws {
        try player.stop()
    }
    
    public func waitForStop() async throws {
        try await player.waitForStop()
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        logger.info("finished recved all data.")
        try! player.finishData()
        
        if let error {
            logger.error("complele error: \(error)")
            return
        }
    }
    
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        logger.info("recved data: \(data.count)")
        do {
            try player.writeData(data)
        } catch {
            logger.error("write data error: \(error)")
        }
    }
}

