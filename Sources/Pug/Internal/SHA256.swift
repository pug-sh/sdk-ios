/// SHA-256 (FIPS 180-4), for the names of storage files. CryptoKit and CommonCrypto are not on Linux.
enum SHA256 {
    private static let initialHash: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A, 0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]

    private static let roundConstants: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var padded = message
        padded.append(0x80)
        padded.append(contentsOf: repeatElement(0, count: (119 - message.count % 64) % 64))
        let bitCount = UInt64(message.count) &* 8
        padded.append(
            contentsOf: stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: bitCount >> $0) })

        var hash = initialHash
        var schedule = [UInt32](repeating: 0, count: 64)
        for block in stride(from: 0, to: padded.count, by: 64) {
            for index in 0..<16 {
                let offset = block + 4 * index
                schedule[index] = padded[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
            }
            for index in 16..<64 {
                let early = schedule[index - 15]
                let late = schedule[index - 2]
                let sigma0 = early.rotatedRight(by: 7) ^ early.rotatedRight(by: 18) ^ early >> 3
                let sigma1 = late.rotatedRight(by: 17) ^ late.rotatedRight(by: 19) ^ late >> 10
                schedule[index] = schedule[index - 16] &+ sigma0 &+ schedule[index - 7] &+ sigma1
            }
            var (a, b, c, d, e, f, g, h) = (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7])
            for index in 0..<64 {
                let sum1 = e.rotatedRight(by: 6) ^ e.rotatedRight(by: 11) ^ e.rotatedRight(by: 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = h &+ sum1 &+ choice &+ roundConstants[index] &+ schedule[index]
                let sum0 = a.rotatedRight(by: 2) ^ a.rotatedRight(by: 13) ^ a.rotatedRight(by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                (h, g, f, e, d, c, b, a) = (g, f, e, d &+ temp1, c, b, a, temp1 &+ sum0 &+ majority)
            }
            for (index, word) in [a, b, c, d, e, f, g, h].enumerated() {
                hash[index] &+= word
            }
        }
        return hash.flatMap { word in [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: word >> $0) } }
    }
}

extension UInt32 {
    fileprivate func rotatedRight(by count: UInt32) -> UInt32 {
        self >> count | self << (32 - count)
    }
}
