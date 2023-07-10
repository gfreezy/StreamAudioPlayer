//
//  File.swift
//  
//
//  Created by feichao on 2023/7/9.
//

import Foundation
import AVFoundation
import OSLog

fileprivate let logger = Logger(subsystem: "StreamAudio", category: "StreamDecoder")

public class StreamDecoder {
    private let audioConverter: AVAudioConverter?
    private let sourceFormat: AVAudioFormat
    public let pcmFormat: AVAudioFormat

    public init?(sourceFormat: AVAudioFormat) {
        // 创建一个音频格式，用于 PCM 数据
        pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sourceFormat.sampleRate, channels: sourceFormat.channelCount)!
        self.sourceFormat = sourceFormat
        
        if sourceFormat.commonFormat != .otherFormat {
            audioConverter = nil
            return
        }
        
        // 创建一个音频转换器
        guard let converter = AVAudioConverter(from: sourceFormat, to: pcmFormat) else {
            logger.error("create AVAudioConverter error")
            return nil
        }
        audioConverter = converter
    }
    
    public func decodeOne(packet: StreamPacket) throws -> AVAudioPCMBuffer? {
        if let desc = packet.packetDescription {
            try decode(data: packet.data, packetCount: 1, packetDescriptions: [desc])
        } else {
            try decode(data: packet.data, packetCount: 1, packetDescriptions: nil)
        }
    }
        
    public func decode(data: Data, packetCount: UInt32, packetDescriptions: [AudioStreamPacketDescription]?) throws -> AVAudioPCMBuffer? {
        if sourceFormat.commonFormat == .otherFormat {
            guard let packetDescriptions else {
                throw StreamAudioError(errorDescription: "packet descriptions must not be nil")
            }
            let maximumPacketSize = packetDescriptions.map { $0.mDataByteSize }.max()!
            logger.info("maximumPacketSize: \(maximumPacketSize)")
            // 创建一个 AVAudioCompressedBuffer
            let audioBuffer = AVAudioCompressedBuffer(format: sourceFormat, packetCapacity: AVAudioPacketCount(packetCount), maximumPacketSize: Int(maximumPacketSize))
            audioBuffer.byteLength = UInt32(data.count)
            audioBuffer.packetCount = packetCount
            data.withUnsafeBytes { ptr in
                audioBuffer.data.copyMemory(from: ptr.baseAddress!, byteCount: ptr.count)
            }
            audioBuffer.packetDescriptions?.update(from: packetDescriptions, count: packetDescriptions.count)
            return try decode(buffer: audioBuffer)
        } else {
            // 创建一个 AVAudioPCMBuffer
            let audioBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(data.count) / sourceFormat.streamDescription.pointee.mBytesPerFrame)!
            // 将数据复制到缓冲区
            let aBuffers = audioBuffer.mutableAudioBufferList.pointee.mBuffers
            data.withUnsafeBytes { dataPtr in
                aBuffers.mData?.copyMemory(from: dataPtr.baseAddress!, byteCount: data.count)
            }
            
            // 设置缓冲区的帧数
            audioBuffer.frameLength = AVAudioFrameCount(data.count) / sourceFormat.streamDescription.pointee.mBytesPerFrame
            return audioBuffer
        }
    }
    
    public func decode(buffer: AVAudioCompressedBuffer) throws -> AVAudioPCMBuffer? {
        guard let audioConverter else {
            fatalError("audioConverter is nil")
        }
        
        // 创建一个 PCM 缓冲区
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(buffer.byteLength))!
        pcmBuffer.frameLength = 0

        var processed = false
        // 进行转换
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
//            logger.info("AVAudioConverterInputBlock: \(inNumPackets)")
            if !processed {
                outStatus.pointee = AVAudioConverterInputStatus.haveData
                assert(inNumPackets >= buffer.packetCount)
                processed = true
                return buffer
            } else {
                outStatus.pointee = AVAudioConverterInputStatus.noDataNow
                return nil
            }
        }
        var error: NSError?
        let status = audioConverter.convert(to: pcmBuffer, error: &error, withInputFrom: inputBlock)

        // 检查转换是否成功
        switch (status, error) {
        case (.error, let e?):
            logger.error("Conversion failed")
            throw e
        case (.inputRanDry, _):
            return pcmBuffer
        case (.haveData, _):
            return pcmBuffer
        case (.endOfStream , _):
            logger.info("end of stream reached")
            return nil
        default:
            fatalError("AudioConverter report error status while no error is provided.")
        }
    }
}
