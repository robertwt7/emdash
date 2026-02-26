import XCTest
@testable import Emdash

final class ShellEscapeTests: XCTestCase {

    func testQuoteShellArgSimple() {
        XCTAssertEqual(ShellEscape.quoteShellArg("hello"), "'hello'")
    }

    func testQuoteShellArgWithSingleQuotes() {
        XCTAssertEqual(ShellEscape.quoteShellArg("it's"), "'it'\\''s'")
    }

    func testQuoteShellArgWithSpaces() {
        XCTAssertEqual(ShellEscape.quoteShellArg("hello world"), "'hello world'")
    }

    func testQuoteShellArgWithSpecialChars() {
        XCTAssertEqual(ShellEscape.quoteShellArg("$HOME"), "'$HOME'")
        XCTAssertEqual(ShellEscape.quoteShellArg("`whoami`"), "'`whoami`'")
        XCTAssertEqual(ShellEscape.quoteShellArg("$(rm -rf /)"), "'$(rm -rf /)'")
    }

    func testQuoteShellArgEmpty() {
        XCTAssertEqual(ShellEscape.quoteShellArg(""), "''")
    }

    func testIsValidEnvVarNameValid() {
        XCTAssertTrue(ShellEscape.isValidEnvVarName("HOME"))
        XCTAssertTrue(ShellEscape.isValidEnvVarName("_PATH"))
        XCTAssertTrue(ShellEscape.isValidEnvVarName("MY_VAR_123"))
        XCTAssertTrue(ShellEscape.isValidEnvVarName("a"))
    }

    func testIsValidEnvVarNameInvalid() {
        XCTAssertFalse(ShellEscape.isValidEnvVarName(""))
        XCTAssertFalse(ShellEscape.isValidEnvVarName("123"))
        XCTAssertFalse(ShellEscape.isValidEnvVarName("MY-VAR"))
        XCTAssertFalse(ShellEscape.isValidEnvVarName("MY VAR"))
        XCTAssertFalse(ShellEscape.isValidEnvVarName("$VAR"))
    }
}
