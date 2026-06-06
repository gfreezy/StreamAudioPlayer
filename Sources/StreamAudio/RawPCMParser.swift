//
//  RawPCMParser.swift
//
//
//  Created by feichao on 2026/6/6.
//

import AVFAudio
import AudioToolbox
import Foundation
import OSLog

fileprivate let logger = Logger(subsystem: "StreamAudio", category: "RawPCMParser")

/// A `StreamPacketProducer` for headerless linear PCM streams, e.g. the raw
/// 24kHz PCM16 audio emitted by realtime speech APIs.
///
/// Unlike `StreamParser` there is no container to parse: the format is
/// supplied up front and the byte stream is sliced into frame-aligned packets.
public final class RawPCMParser: StreamPacketProducer {
    private let format: AVAudioFormat
    private let bytesPerFrame: Int
    private let maxPacketBytes: Int
    /// Bytes carried over between `parseBytes` calls when the input is not
    /// aligned to a frame boundary.
    private var residual = Data()

    /// - Parameters:
    ///   - asbd: Linear PCM stream description (sample rate, channels, bits).
    ///   - maxPacketBytes: Upper bound for a single packet. Must stay below
    ///     `StreamPlayer`'s AudioQueue buffer size (4096).
    public init(asbd: AudioStreamBasicDescription, maxPacketBytes: Int = 2048) throws {
        var asbd = asbd
        guard asbd.mFormatID == kAudioFormatLinearPCM,
            asbd.mBytesPerFrame > 0,
            let format = AVAudioFormat(streamDescription: &asbd)
        else {
            logger.error("RawPCMParser requires a valid linear PCM ASBD")
            throw StreamAudioError(errorDescription: "RawPCMParser requires a valid linear PCM ASBD")
        }
        self.format = format
        self.bytesPerFrame = Int(asbd.mBytesPerFrame)
        // Keep packets frame-aligned, but never smaller than one frame.
        self.maxPacketBytes = max(
            maxPacketBytes - maxPacketBytes % Int(asbd.mBytesPerFrame),
            Int(asbd.mBytesPerFrame))
    }

    public func readyToProducePackets() -> Bool {
        true
    }

    public func audioFormat() -> AVAudioFormat? {
        format
    }

    public func parseBytes(_ data: Data) throws -> [StreamPacket] {
        residual.append(data)
        let usable = residual.count - residual.count % bytesPerFrame
        guard usable > 0 else {
            return []
        }
        var packets: [StreamPacket] = []
        var offset = 0
        while offset < usable {
            let length = min(maxPacketBytes, usable - offset)
            // Linear PCM is constant bitrate: no packet description needed.
            packets.append(
                StreamPacket(
                    data: residual.subdata(in: offset..<(offset + length)),
                    packetDescription: nil))
            offset += length
        }
        residual.removeSubrange(0..<offset)
        return packets
    }
}
