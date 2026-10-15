import Testing
@testable import ONTTheWireCore

struct SpeedTestMathTests {
    @Test func medianAndJitter() {
        #expect(SpeedTest.median([30, 10, 20]) == 20)
        #expect(SpeedTest.median([10, 20, 30, 40]) == 25)
        // Ookla-style jitter: mean absolute difference of consecutive samples.
        #expect(SpeedTest.jitter([10, 12, 11, 15]) == (2 + 1 + 4) / 3.0)
        #expect(SpeedTest.jitter([10]) == 0)
    }

    @Test func streamsRespectServerCaps() {
        let streams = SpeedTest.assign(16, to: SpeedServer.all)
        #expect(streams.count == 16)
        #expect(streams.filter { $0.name == "OVH" }.count == 2)
        #expect(streams.filter { $0.name == "Cloudflare" }.count == 7)
        #expect(streams.filter { $0.name == "Apple CDN" }.count == 7)
        let upload = SpeedTest.assign(8, to: SpeedServer.all.filter { $0.uploadPath != nil })
        #expect(Set(upload.map(\.name)) == ["Cloudflare", "Apple CDN"])
    }
}
