import Testing

@testable import Pug

struct SHA256Tests {
  @Test(
    "digests match FIPS 180-4's examples and messages around the padding boundary",
    arguments: [
      ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
      ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
      (
        "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
      ),
      (String(repeating: "a", count: 55), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"),
      (String(repeating: "a", count: 56), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"),
      (String(repeating: "a", count: 63), "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34"),
      (String(repeating: "a", count: 64), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"),
      (
        String(repeating: "a", count: 1_000_000),
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
      ),
    ]
  )
  func digests(message: String, expected: String) {
    var hex: [UInt8] = []
    for byte in SHA256.digest(Array(message.utf8)) {
      hex.appendHex(byte)
    }

    #expect(String(decoding: hex, as: UTF8.self) == expected)
  }
}
