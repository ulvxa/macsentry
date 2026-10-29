import Foundation
import Testing
@testable import MacSentryCore

struct GlobPatternTests {
    private let home = URL(filePath: "/nonexistent-home/user", directoryHint: .isDirectory)

    private func matches(_ pattern: String, _ path: String) throws -> Bool {
        try GlobPattern(pattern, homeURL: home).matches(URL(filePath: path))
    }

    @Test func `single star matches within one segment`() throws {
        #expect(try matches("/a/*/c", "/a/b/c"))
        #expect(try matches("/a/*.psd", "/a/cover.psd"))
        #expect(try !matches("/a/*/c", "/a/b/x/c"))
        #expect(try !matches("/a/*.psd", "/a/cover.png"))
    }

    @Test func `double star matches any depth including zero`() throws {
        #expect(try matches("/a/**/c", "/a/c"))
        #expect(try matches("/a/**/c", "/a/b/x/y/c"))
        #expect(try matches("**/ClientWork/**", "/Users/x/Work/ClientWork"))
        #expect(try matches("**/ClientWork/**", "/Users/x/Work/ClientWork/a/b"))
        #expect(try !matches("**/ClientWork/**", "/Users/x/Work/ClientWorkshop"))
    }

    @Test func `question mark matches one character`() throws {
        #expect(try matches("/logs/day?.txt", "/logs/day1.txt"))
        #expect(try !matches("/logs/day?.txt", "/logs/day10.txt"))
    }

    @Test func `tilde expands to injected home`() throws {
        #expect(try matches("~/Work/**", "/nonexistent-home/user/Work/a"))
        #expect(try matches("~", "/nonexistent-home/user"))
        #expect(try !matches("~/Work", "/Users/real/Work"))
    }

    @Test func `unanchored patterns match anywhere`() throws {
        #expect(try matches("*.psd", "/any/depth/cover.psd"))
        #expect(try matches("ClientWork", "/x/ClientWork"))
    }

    @Test func `matching is case insensitive`() throws {
        #expect(try matches("~/work/CLIENT", "/nonexistent-home/user/Work/client"))
    }

    @Test(arguments: [
        ("", GlobPatternError.empty),
        ("   ", .empty),
        ("~/a[bc]", .unsupportedSyntax("[")),
        ("~/{a,b}", .unsupportedSyntax("{")),
        ("~/a**", .invalidDoubleStar("a**")),
        ("/a/***/b", .invalidDoubleStar("***")),
        ("~/a/../b", .relativeSegment("..")),
        ("~/./b", .relativeSegment(".")),
        ("~bob/Work", .userHomeNotSupported),
        ("~/a\nb", .invalidCharacter),
    ])
    func `invalid globs are rejected`(pattern: String, error: GlobPatternError) {
        #expect(throws: error) { try GlobPattern.validate(pattern) }
    }

    @Test(arguments: ["/", "~", "**", "~/", "/**", "*", "~/**"])
    func `protect everything patterns are flagged`(pattern: String) throws {
        #expect(try GlobPattern.validate(pattern) == .protectsEverything)
    }

    @Test(arguments: ["~/Work", "**/ClientWork/**", "/Volumes/Backup/*", "*.psd"])
    func `ordinary patterns have no warning`(pattern: String) throws {
        #expect(try GlobPattern.validate(pattern) == nil)
    }
}
