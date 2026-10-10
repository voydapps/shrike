//
//  UserFacingPathTests.swift
//  ShrikeUITests
//
//  One form for paths people read — "~" for home, "/tmp"
//  rather than "/private/tmp".
//

import XCTest
@testable import ShrikeUI

final class UserFacingPathTests: XCTestCase {

    func testPrivateSystemFoldersReadAsTheirLinks() {
        XCTAssertEqual(UserFacingPath.string("/private/tmp/ux-fin-out"), "/tmp/ux-fin-out")
        XCTAssertEqual(UserFacingPath.string("/private/tmp"), "/tmp")
        XCTAssertEqual(UserFacingPath.string("/private/var/folders/x/T/a"), "/var/folders/x/T/a")
        XCTAssertEqual(UserFacingPath.string("/private/etc/hosts"), "/etc/hosts")
        // Only the system links: other "/private…" paths stay as they are.
        XCTAssertEqual(UserFacingPath.string("/private/tmpfoo/a"), "/private/tmpfoo/a")
        XCTAssertEqual(UserFacingPath.string("/private/other/a"), "/private/other/a")
        XCTAssertEqual(UserFacingPath.string("/Volumes/private/tmp/a"), "/Volumes/private/tmp/a")
    }

    func testTheExportAndTheRenameFoldersReadTheSame() {
        // After an export the folder comes from the Open panel (resolved);
        // after a rename it comes from the listed files (as opened).
        let resolved = URL(fileURLWithPath: "/private/tmp/ux-fin", isDirectory: true)
        let opened = URL(fileURLWithPath: "/tmp/ux-fin", isDirectory: true)
        XCTAssertEqual(UserFacingPath.string(resolved), UserFacingPath.string(opened))
        XCTAssertEqual(UserFacingPath.string(opened), "/tmp/ux-fin")
    }

    func testHomeReadsAsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(UserFacingPath.string(home.appendingPathComponent("Pictures/Shrike Export")),
                       "~/Pictures/Shrike Export")
    }
}
