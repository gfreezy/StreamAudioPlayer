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

struct ContentView: View {
    @State var downloader: StreamAudioPlayer? = nil
    
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
                        let downloader = StreamAudioPlayer(URL(string: "https://freetestdata.com/wp-content/uploads/2021/09/Free_Test_Data_100KB_MP3.mp3")!,
                        cachePath: path)
                        try await downloader.play()
                        self.downloader = downloader
                    } catch let error as StreamAudioError {
                        logger.error("download error: \(error, privacy: .public)")
                    }
                }
            }
        }
        .padding()
    }
}


private let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("a.mp3")

@available(iOS 16.0, macOS 13.0, *)
#Preview {
    ContentView()
}
