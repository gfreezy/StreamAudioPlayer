import AVFAudio
import XCTest

@testable import StreamAudio

final class RawPCMParserTests: XCTestCase {
    private func pcm16MonoASBD(sampleRate: Float64 = 24000) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0)
    }

    func testReadyAndFormatUpFront() throws {
        let parser = try RawPCMParser(asbd: pcm16MonoASBD())
        XCTAssertTrue(parser.readyToProducePackets())
        let format = try XCTUnwrap(parser.audioFormat())
        XCTAssertEqual(format.sampleRate, 24000)
        XCTAssertEqual(format.channelCount, 1)
    }

    func testSlicesIntoFrameAlignedPackets() throws {
        let parser = try RawPCMParser(asbd: pcm16MonoASBD(), maxPacketBytes: 2048)
        let data = Data(repeating: 0xAB, count: 4800)
        let packets = try parser.parseBytes(data)
        XCTAssertEqual(packets.map(\.data.count), [2048, 2048, 704])
        XCTAssertTrue(packets.allSatisfy { $0.packetDescription == nil })
        XCTAssertTrue(packets.allSatisfy { $0.data.count.isMultiple(of: 2) })
    }

    func testCarriesResidualAcrossCalls() throws {
        let parser = try RawPCMParser(asbd: pcm16MonoASBD(), maxPacketBytes: 2048)
        // 3 bytes: one full frame + 1 residual byte
        XCTAssertEqual(try parser.parseBytes(Data([1, 2, 3])).map(\.data.count), [2])
        // residual byte + 1 new byte = one more frame
        XCTAssertEqual(try parser.parseBytes(Data([4])).map(\.data.count), [2])
        XCTAssertEqual(try parser.parseBytes(Data()).count, 0)
    }

    func testPacketsNeverExceedAudioQueueBufferSize() throws {
        let parser = try RawPCMParser(asbd: pcm16MonoASBD(), maxPacketBytes: 2048)
        let packets = try parser.parseBytes(Data(repeating: 0, count: 100_000))
        XCTAssertTrue(packets.allSatisfy { $0.data.count <= 2048 })
        XCTAssertEqual(packets.reduce(0) { $0 + $1.data.count }, 100_000)
    }

    func testRejectsNonPCMFormat() {
        var asbd = AudioStreamBasicDescription()
        asbd.mFormatID = kAudioFormatMPEGLayer3
        XCTAssertThrowsError(try RawPCMParser(asbd: asbd))
    }
}
