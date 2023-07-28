//
//  ContentView.swift
//  Example
//
//  Created by feichao on 2023/7/1.
//

import SwiftUI
import StreamAudio
import OSLog

fileprivate let logger = Logger(subsystem: "StreamAudio", category: "Mp3Downloader")


private let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("a.mp3")

struct ContentView: View {
    @State var downloader: URLAudioPlayer? = nil
    
    init() {
        
    }
    
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
            Button("Play") {
                Task {
                    do {
                        logger.info("start play")
//                        try self.downloader?.stop()
                        let downloader = URLAudioPlayer(URL(string: "https://freetestdata.com/wp-content/uploads/2021/09/Free_Test_Data_100KB_MP3.mp3")!)
                        try await downloader.play()
                        try await downloader.waitForStop()
                        logger.info("wait for stop")
                        
                        let downloader2 = URLAudioPlayer(URL(string: "https://samples-files.com/samples/Audio/mp3/sample-file-4.mp3")!)
                        try await downloader2.play()
                        try await downloader2.waitForStop()
                    } catch {
                        logger.error("download error: \(error, privacy: .public)")
                    }
                }
            }
            
            Button("Stop") {
                do {
                    try self.downloader?.stop()
                } catch {}
            }
        }
        .padding()
    }
}

@available(iOS 16.0, macOS 13.0, *)
#Preview {
    ContentView()
}
