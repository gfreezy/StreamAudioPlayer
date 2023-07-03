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

fileprivate let logger = Logger(subsystem: "StreamAudio", category: "Mp3Downloader")

struct ContentView: View {
    @State var downloader: Mp3Downloader? = nil
    
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
            Button("Download") {
                do {
                    let downloader = Mp3Downloader(URL(string: "https://file-examples.com/storage/fede3f30f864a1f979d2bf0/2017/11/file_example_MP3_700KB.mp3")!)
                    try downloader.download()
                    self.downloader = downloader
                } catch {
                    logger.error("download error: \(error)")
                }
            }
        }
        .padding()
    }
}


class Mp3Downloader : NSObject, URLSessionDataDelegate {
    private var task: URLSessionDataTask? = nil
    private var parser: StreamParser? = nil
    private let url: URL
    
    init(_ url: URL) {
        self.url = url
    }
    
    func download() throws {
        parser = try StreamParser.create(fileType: kAudioFileMP3Type)
        task = URLSession.shared.dataTask(with: url)
        task?.delegate = self
        task?.resume()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            logger.error("complele error: \(error)")
            return
        }
        guard let parser else {
            return
        }
        logger.info("parser data: \(String(describing: parser.context), privacy: .public)")
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let parser else {
            return
        }
        
        do {
            try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                try parser.parseBytes(UInt32(ptr.count), ptr.baseAddress)
            }
        } catch {
            logger.error("parseBytes: \(error)")
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
