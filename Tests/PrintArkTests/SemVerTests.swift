import XCTest
@testable import PrintArk

final class SemVerTests: XCTestCase {
    func testParsesWithAndWithoutVPrefix() {
        XCTAssertEqual(SemVer("v1.1.1"), SemVer("1.1.1"))
        XCTAssertEqual(SemVer("V2.0.0"), SemVer("2.0.0"))
    }

    func testNumericOrderingNotLexical() {
        // 1.10.0 > 1.9.0 — 字符串比较会判反,整数分段比较才正确。
        XCTAssertTrue(SemVer("1.10.0")! > SemVer("1.9.0")!)
        XCTAssertTrue(SemVer("1.2.0")! > SemVer("1.1.9")!)
    }

    func testIsNewer() {
        XCTAssertTrue(SemVer.isNewer("v1.1.2", than: "1.1.1"))
        XCTAssertTrue(SemVer.isNewer("1.2.0", than: "1.1.1"))
        XCTAssertFalse(SemVer.isNewer("v1.1.1", than: "1.1.1")) // 相等不算更新
        XCTAssertFalse(SemVer.isNewer("1.1.0", than: "1.1.1")) // 更低不算更新
    }

    func testDifferentComponentCounts() {
        // 1.1 == 1.1.0;1.1.1 > 1.1
        XCTAssertEqual(SemVer("1.1"), SemVer("1.1.0"))
        XCTAssertTrue(SemVer("1.1.1")! > SemVer("1.1")!)
    }

    func testPrereleaseSuffixStripped() {
        // 预发布后缀只比数字主体:1.2.0-beta.1 视作 1.2.0。
        XCTAssertEqual(SemVer("1.2.0-beta.1"), SemVer("1.2.0"))
    }

    func testInvalidInputReturnsNil() {
        XCTAssertNil(SemVer(""))
        XCTAssertNil(SemVer("abc"))
        XCTAssertNil(SemVer("v"))
    }

    func testIsNewerSafeOnInvalidInput() {
        // 任一无法解析时不误报升级。
        XCTAssertFalse(SemVer.isNewer("garbage", than: "1.1.1"))
        XCTAssertFalse(SemVer.isNewer("1.2.0", than: "garbage"))
    }
}
