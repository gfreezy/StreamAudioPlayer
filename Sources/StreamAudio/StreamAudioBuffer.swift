// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation


public class StreamAudioBuffer {
    private let fileHandle: FileHandle
    fileprivate let path: URL
    private(set) var isFinished: Bool = false
    
    public init(path: URL) {
        let ret = FileManager.default.createFile(atPath: path.path, contents: nil)
        assert(ret, "create file error")
        self.fileHandle = try! FileHandle(forWritingTo: path)
        self.path = path
    }
    
    public func write(contentsOf: some DataProtocol) throws {
        if isFinished {
            throw StreamAudioError(errorDescription: "File is finished.")
        }
        try fileHandle.write(contentsOf: contentsOf)
    }
    
    public func newReader() -> StreamAudioBufferReader {
        StreamAudioBufferReader(streamAudio: self)
    }
    
    public func finish() {
        isFinished = true
    }
    
    public func close() throws {
        finish()
        try fileHandle.close()
    }
    
    deinit {
        do {
            try close()
        } catch {}
    }
}


public class StreamAudioBufferReader {
    private let streamAudio: StreamAudioBuffer
    private let fileHandle: FileHandle
    
    init(streamAudio: StreamAudioBuffer) {
        self.streamAudio = streamAudio
        self.fileHandle = try! FileHandle(forReadingFrom: streamAudio.path)
    }
    
    // return emtpy when reach eof.
    // return nil Data when there is no data available, should retry again.
    public func read(upToCount size: Int) throws -> Data? {
        let data = try fileHandle.read(upToCount: size)
        switch (data, streamAudio.isFinished) {
        case (nil, true):
            return Data()
        case (let data?, true) where data.isEmpty:
            return Data()
        case (nil, false):
            return nil
        case (let data?, false) where data.isEmpty:
            return nil
        case (let data?, _):
            return data
        }
    }

    // return emtpy when reach eof.
    // return nil Data when there is no data available, should retry again.
    public func read(exact size: Int) throws -> Data? {
        let offset = try fileHandle.offset()
        let data = try fileHandle.read(upToCount: size)
        switch (data, streamAudio.isFinished) {
        case (nil, true):
            return Data()
        case (let data?, true) where data.isEmpty:
            return Data()
        case (nil, false):
            return nil
        case (let data?, false) where data.isEmpty:
            return nil
        case (let data?, true):
            return data
        case (let data?, false) where data.count == size:
            return data
        case (_?, false):
            try fileHandle.seek(toOffset: offset)
            return nil
        }
    }
}
