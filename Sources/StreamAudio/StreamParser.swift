//
//  File.swift
//  
//
//  Created by feichao on 2023/7/2.
//

import Foundation
import AudioToolbox
import OSLog

fileprivate let logger = Logger(subsystem: "StreamAudio", category: "StreamParser")

public class StreamParserContext {
    private var input: [Data] = []
    private(set) var output: [Data] = []
    
    // AudioFileStream properties
    var readyToProducePackets: Bool = false
    var fileFormat: AudioFileTypeID? = nil
    var dataFormat: AudioStreamBasicDescription? = nil
    var formatList: [AudioFormatListItem]? = nil
    var audioDataByteCount: UInt64? = nil
    var audioDataPacketCount: UInt64? = nil
    var maximumPacketSize: UInt32? = nil
    var dataOffset: Int64? = nil
    var channelLayout: AudioChannelLayout? = nil
    var magicCookieData: Data? = nil
    var bitRate: UInt32? = nil
    var packetTableInfo: AudioFilePacketTableInfo? = nil

    init() {
        
    }
    
    func pushOutput(_ data: Data) {
        output.append(data)
    }
}


fileprivate func packetsProc(
    _ inClientData: UnsafeMutableRawPointer,
    _ inNumberBytes: UInt32,
    _ inNumberPackets: UInt32,
    _ inInputData: UnsafeRawPointer,
    _ inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
) -> Void {
    let ptr = inClientData.assumingMemoryBound(to: StreamParserContext.self)
    let context = ptr.pointee
    if let inPacketDescriptions {
        for _ in 0..<inNumberPackets {
            let description = inPacketDescriptions.pointee
            let offset = inInputData.advanced(by: Int(description.mStartOffset))
            let data = Data(bytes: offset, count: Int(description.mDataByteSize))
            context.pushOutput(data)
        }
    } else {
        let packetSizePrecision = Double(inNumberBytes) / Double(inNumberPackets);
        let packetSize = Int(packetSizePrecision)
        assert(Double(packetSize) == packetSizePrecision, "Not divide fully")
        for i in 0..<inNumberPackets {
            let offset = inInputData.advanced(by: packetSize * Int(i))
            let data = Data(bytes: offset, count: packetSize)
            context.pushOutput(data)
        }
    }
}


fileprivate func propertyListenerProc(
    _ inClientData: UnsafeMutableRawPointer,
    _ inAudioFileStream: AudioFileStreamID,
    _ inPropertyID: AudioFileStreamPropertyID,
    _ ioFlags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>
) {
    // Convert the raw pointer to a typed pointer of StreamParserContext
    let ptr = inClientData.assumingMemoryBound(to: StreamParserContext.self)
    // Dereference the pointer to get the StreamParserContext instance
    let context = ptr.pointee
    
    // Convert inPropertyID to string
    let propertyIDString = withUnsafeBytes(of: inPropertyID.bigEndian) {
        var a = Array($0)
        a.append(0)
        return String(cString: a)
    }
    
    // Process based on the property ID
    switch inPropertyID {
    case kAudioFileStreamProperty_ReadyToProducePackets:
        context.readyToProducePackets = true

    case kAudioFileStreamProperty_FileFormat:
        var fileFormat: AudioFileTypeID = 0
        var size = UInt32(MemoryLayout<AudioFileTypeID>.size)
        let status = AudioFileStreamGetProperty(inAudioFileStream, inPropertyID, &size, &fileFormat)
        if status == noErr {
            context.fileFormat = fileFormat
        } else {
            logger.error("AudioFileStreamGetProperty \(propertyIDString, privacy: .public) error: \(status)")
        }

    case kAudioFileStreamProperty_DataFormat:
        var dataFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioFileStreamGetProperty(inAudioFileStream, inPropertyID, &size, &dataFormat)
        if status == noErr {
            context.dataFormat = dataFormat
        } else {
            logger.error("AudioFileStreamGetProperty \(propertyIDString, privacy: .public) error: \(status)")
        }

    case kAudioFileStreamProperty_MagicCookieData:
        var size: UInt32 = 0
        var status = AudioFileStreamGetPropertyInfo(inAudioFileStream, inPropertyID, &size, nil)
        if status != noErr {
            logger.error("AudioFileStreamGetPropertyInfo \(propertyIDString, privacy: .public) error: \(status)")
            break
        }
        
        let magicCookieDataPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<UInt8>.alignment)
        defer { magicCookieDataPointer.deallocate() }
        status = AudioFileStreamGetProperty(inAudioFileStream, inPropertyID, &size, magicCookieDataPointer)
        if status == noErr {
            let data = Data(bytes: magicCookieDataPointer, count: Int(size))
            context.magicCookieData = data
        } else {
            logger.error("AudioFileStreamGetProperty \(propertyIDString, privacy: .public) error: \(status)")
        }
        
    case kAudioFileStreamProperty_AudioDataByteCount:
        var byteCount: UInt64 = 0
        var size = UInt32(MemoryLayout<UInt64>.size)
        let status = AudioFileStreamGetProperty(inAudioFileStream, inPropertyID, &size, &byteCount)
        if status == noErr {
            context.audioDataByteCount = byteCount
        } else {
            logger.error("AudioFileStreamGetProperty \(propertyIDString, privacy: .public) error: \(status)")
        }

    case kAudioFileStreamProperty_AudioDataPacketCount:
        var packetCount: UInt64 = 0
        var size = UInt32(MemoryLayout<UInt64>.size)
        let status = AudioFileStreamGetProperty(inAudioFileStream, inPropertyID, &size, &packetCount)
        if status == noErr {
            context.audioDataPacketCount = packetCount
        } else {
            logger.error("AudioFileStreamGetProperty \(propertyIDString, privacy: .public) error: \(status)")
        }

    case kAudioFileStreamProperty_MaximumPacketSize:
        var maxPacketSize: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioFileStreamGetProperty(inAudioFileStream, inPropertyID, &size, &maxPacketSize)
        if status == noErr {
            context.maximumPacketSize = maxPacketSize
        } else {
            logger.error("AudioFileStreamGetProperty \(propertyIDString, privacy: .public) error: \(status)")
        }

    case kAudioFileStreamProperty_DataOffset:
        var dataOffset: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        let status = AudioFileStreamGetProperty(inAudioFileStream, inPropertyID, &size, &dataOffset)
        if status == noErr {
            context.dataOffset = dataOffset
        } else {
            logger.error("AudioFileStreamGetProperty \(propertyIDString, privacy: .public) error: \(status)")
        }

    case kAudioFileStreamProperty_FormatList:
        var size: UInt32 = 0
        var status = AudioFileStreamGetPropertyInfo(inAudioFileStream, inPropertyID, &size, nil)
        if status != noErr {
            logger.error("AudioFileStreamGetPropertyInfo \(propertyIDString, privacy: .public) error: \(status)")
            break
        }
        
        let formatListData = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<UInt8>.alignment)
        defer { formatListData.deallocate() }
        status = AudioFileStreamGetProperty(inAudioFileStream, inPropertyID, &size, formatListData)
        if status == noErr {
            let listCount = Int(size) / MemoryLayout<AudioFormatListItem>.size
            let formatList = formatListData.bindMemory(to: AudioFormatListItem.self, capacity: listCount)
            context.formatList = Array(UnsafeBufferPointer(start: formatList, count: listCount))
        } else {
            logger.error("AudioFileStreamGetProperty \(propertyIDString, privacy: .public) error: \(status)")
        }

    case kAudioFileStreamProperty_ChannelLayout:
        var size: UInt32 = 0
        var status = AudioFileStreamGetPropertyInfo(inAudioFileStream, inPropertyID, &size, nil)
        if status != noErr {
            logger.error("AudioFileStreamGetProperty \(propertyIDString, privacy: .public) error: \(status)")
            break
        }
        
        let channelLayoutData = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<UInt8>.alignment)
        defer { channelLayoutData.deallocate() }
        status = AudioFileStreamGetProperty(inAudioFileStream, inPropertyID, &size, channelLayoutData)
        if status == noErr {
            let channelLayout = channelLayoutData.bindMemory(to: AudioChannelLayout.self, capacity: 1).pointee
            context.channelLayout = channelLayout
        } else {
            logger.error("AudioFileStreamGetProperty \(propertyIDString, privacy: .public) error: \(status)")
        }
    case kAudioFileStreamProperty_BitRate:
        var bitRate: UInt32 = 0
        var size: UInt32 = UInt32(MemoryLayout.size(ofValue: bitRate))
        let status = AudioFileStreamGetProperty(inAudioFileStream, inPropertyID, &size, &bitRate)
        if status == noErr {
            context.bitRate = bitRate
        } else {
            logger.error("AudioFileStreamGetProperty \(propertyIDString, privacy: .public) error: \(status)")
        }
    case kAudioFileStreamProperty_PacketTableInfo:
        var packetTableInfo: AudioFilePacketTableInfo = AudioFilePacketTableInfo()
        var size: UInt32 = UInt32(MemoryLayout.size(ofValue: packetTableInfo))
        let status = AudioFileStreamGetProperty(inAudioFileStream, inPropertyID, &size, &packetTableInfo)
        if status == noErr {
            context.packetTableInfo = packetTableInfo
        } else {
            logger.error("AudioFileStreamGetProperty \(propertyIDString, privacy: .public) error: \(status)")
        }
        
    default:
        logger.info("Unparsed property: \(propertyIDString, privacy: .public), \(inPropertyID)")
        break
    }
}


public class StreamParser {
    private let contextPointer: UnsafeMutablePointer<StreamParserContext> = {
        let p = UnsafeMutablePointer<StreamParserContext>.allocate(capacity: MemoryLayout.size(ofValue: StreamParserContext.self))
        p.initialize(to: StreamParserContext())
        return p
    }()
    
    private let audioFileStream: UnsafeMutablePointer<AudioFileStreamID?> = {
        let p = UnsafeMutablePointer<AudioFileID?>.allocate(capacity: MemoryLayout.size(ofValue: AudioFileStreamID.self))
        p.initialize(to: nil)
        return p
    }()
    
    private var streamOpened: Bool = false
    private let fileType: AudioFileTypeID
    
    public var context: StreamParserContext {
        contextPointer.pointee
    }
    
    private init(fileType: AudioFileTypeID) {
        self.fileType = fileType
    }
    
    public static func create(fileType: AudioFileTypeID) throws -> StreamParser {
        let parser = StreamParser(fileType: fileType)
        try parser.open()
        return parser
    }
    
    private func audioFileStreamId() throws -> AudioFileStreamID {
        guard let id = audioFileStream.pointee else {
            throw StreamAudioError(errorDescription: "No AudioFileStreamId available")
        }
        return id
    }
    
    private func open() throws {
        let osstatus = AudioFileStreamOpen(contextPointer, propertyListenerProc, packetsProc, fileType, audioFileStream)
        guard osstatus == noErr else {
            logger.error("AudioFileStreamOpen error: \(osstatus)")
            throw StreamAudioError(errorDescription: "AudioFileStreamOpen error: \(osstatus)")
        }
        streamOpened = true
    }
    
    public func parseBytes(_ inDataByteSize: UInt32, _ inData: UnsafeRawPointer?) throws {
        let osstatus = AudioFileStreamParseBytes(try audioFileStreamId(), inDataByteSize, inData, [])
        guard osstatus == noErr else {
            logger.error("AudioFileStreamParseBytes error: \(osstatus)")
            throw StreamAudioError(errorDescription: "AudioFileStreamParseBytes error: \(osstatus)")
        }
    }
    
    deinit {
        if streamOpened {
            do {
                let audioFileID = try audioFileStreamId()
                let osstatus = AudioFileStreamClose(audioFileID)
                if osstatus != noErr {
                    logger.error("AudioFileStreamClose error: \(osstatus)")
                }
            } catch {}
        }
        
        contextPointer.deinitialize(count: 1)
        contextPointer.deallocate()

        audioFileStream.deinitialize(count: 1)
        audioFileStream.deallocate()
        logger.info("StreamParser deinit")
    }
}
