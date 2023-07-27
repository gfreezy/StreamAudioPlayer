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


public enum StreamAudioBufferReaderResult {
    case eof
    case data(Data)
    case retry
}

public class StreamAudioBufferReader {
    private let streamAudio: StreamAudioBuffer
    private let fileHandle: FileHandle
    
    init(streamAudio: StreamAudioBuffer) {
        self.streamAudio = streamAudio
        self.fileHandle = try! FileHandle(forReadingFrom: streamAudio.path)
    }
    
    public func read(upToCount size: Int) throws -> StreamAudioBufferReaderResult {
        let data = try fileHandle.read(upToCount: size)
        switch (data, streamAudio.isFinished) {
        case (.none, true):
            return .eof
        case (.some(let data), true) where data.isEmpty:
            return .eof
        case (.some(let data), true):
            return .data(data)
        case (.none, false):
            return .retry
        case (.some(let data), false) where data.isEmpty:
            return .retry
        case (.some(let data), false):
            return .data(data)
        }
    }

    public func read(exact size: Int) throws -> StreamAudioBufferReaderResult {
        let offset = try fileHandle.offset()
        let data = try fileHandle.read(upToCount: size)
        switch (data, streamAudio.isFinished) {
        case (nil, true):
            return .eof
        case (let data?, true) where data.isEmpty:
            return .eof
        case (let data?, true):
            return .data(data)
        case (nil, false):
            return .retry
        case (let data?, false) where data.isEmpty:
            return .retry
        case (let data?, false) where data.count == size:
            return .data(data)
        case (_?, false):
            try fileHandle.seek(toOffset: offset)
            return .retry
        }
    }
}
