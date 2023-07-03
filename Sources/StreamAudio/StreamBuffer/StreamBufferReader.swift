//
//  File.swift
//  
//
//  Created by feichao on 2023/7/2.
//

import Foundation


class StreamBufferReader {
    private var offset: StreamIndexOffset = StreamIndexOffset(index: 0, offset: 0)
    private let buffer: StreamBuffer
    
    init(_ buffer: StreamBuffer) {
        self.buffer = buffer
    }
    
    func read(buf: inout Data, length: Int) -> Int {
        let d = buffer.subrangeBytes(offset, size: length)
        if let d {
            buffer.advanceStreamIndexOffset(&offset, size: d.count)
            buf.removeAll(keepingCapacity: true)
            buf.append(d)
            return d.count
        }
        return 0
    }
}
