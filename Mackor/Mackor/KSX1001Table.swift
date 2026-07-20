import Foundation

/// 현대 한국어가 실제로 사용하는 음절 집합 (KS X 1001 완성형, 2,350자).
///
/// 유니코드 한글 음절 영역은 11,172자지만 그중 현대 국어 표기에 쓰이는 것은
/// 21%뿐이다. 나머지 79%는 이론적으로 조합 가능할 뿐 실제 표기에 나타나지
/// 않으며, 영문 자판 문자열을 두벌식으로 잘못 읽었을 때 생기는 잔해가 정확히
/// 그 영역에 몰린다 (`솓`, `갲`, `뮫` 등).
///
/// 이 표는 단어 목록이 아니라 **문자 집합**이며, 목록을 코드에 기재하지 않고
/// macOS의 EUC-KR 변환기에서 런타임에 유도한다. `kCFStringEncodingEUC_KR`은
/// 엄격한 KS X 1001이라 인코딩 성공 여부가 곧 소속 여부다 (실측: 정확히 2,350자).
enum KSX1001Table {

    /// 한글 음절 영역의 첫 스칼라.
    private static let syllableBase: UInt32 = 0xAC00
    /// 한글 음절 영역의 마지막 스칼라.
    private static let syllableLast: UInt32 = 0xD7A3
    /// 표준이 정의한 완성형 음절 수. 유도 결과가 이 값이 아니면 표를 신뢰하지 않는다.
    static let expectedSyllableCount = 2350

    private static let eucKREncoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)
        )
    )

    private struct Table {
        /// 음절당 1비트. 11,172비트 = 175워드 ≈ 1.4KB.
        let bits: [UInt64]
        let count: Int
        /// 변환기가 예상과 다르게 동작하면 이 표는 사용하지 않는다.
        var isTrustworthy: Bool { count == expectedSyllableCount }
    }

    private static let table: Table = buildTable()

    private static func buildTable() -> Table {
        let syllableCount = Int(syllableLast - syllableBase + 1)
        var bits = [UInt64](repeating: 0, count: (syllableCount + 63) / 64)
        var found = 0

        for offset in 0..<syllableCount {
            guard let scalar = Unicode.Scalar(syllableBase + UInt32(offset)) else { continue }
            // EUC-KR로 표현 가능 == KS X 1001 완성형에 속함.
            guard String(scalar).data(using: eucKREncoding) != nil else { continue }
            bits[offset >> 6] |= (UInt64(1) << UInt64(offset & 63))
            found += 1
        }

        return Table(bits: bits, count: found)
    }

    /// 표를 미리 만들어 둔다. 이벤트 탭 콜백에서 최초 접근 비용을 물지 않도록
    /// 앱 시작 직후 호출한다. 실패하거나 느려도 입력을 막지 않는다.
    static func prepare() {
        _ = table.isTrustworthy
    }

    /// 유도된 음절 수. 진단과 테스트용.
    static var derivedSyllableCount: Int { table.count }

    /// 변환기가 정상 동작해 표를 신뢰할 수 있는지 여부.
    static var isTrustworthy: Bool { table.isTrustworthy }

    /// 해당 스칼라가 현대 한국어 음절인지.
    ///
    /// 한글 음절 영역 밖이면 `false`. 변환기가 비정상이면(표 불신) 모든 음절을
    /// 통과시켜, 이 규칙이 조용히 교정을 전면 차단하는 일이 없게 한다.
    static func isModernSyllable(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        guard value >= syllableBase, value <= syllableLast else { return false }
        guard table.isTrustworthy else { return true }
        let offset = Int(value - syllableBase)
        return (table.bits[offset >> 6] & (UInt64(1) << UInt64(offset & 63))) != 0
    }

    /// 문자열의 모든 한글 음절이 현대 음절인지. 음절이 아닌 문자는 검사 대상이 아니다.
    static func containsOnlyModernSyllables(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where (syllableBase...syllableLast).contains(scalar.value) {
            if !isModernSyllable(scalar) { return false }
        }
        return true
    }
}
