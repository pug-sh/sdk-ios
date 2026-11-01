import Testing

@testable import Pug

@Test("sdkVersion is a release tag SwiftPM can serve: X.Y.Z")
func sdkVersionIsATagName() {
    let parts = sdkVersion.split(separator: ".", omittingEmptySubsequences: false)
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (0x30...0x39).contains($0) } })
}
