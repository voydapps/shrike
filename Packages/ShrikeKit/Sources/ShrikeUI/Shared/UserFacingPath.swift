//
//  UserFacingPath.swift
//  ShrikeUI
//
//  How Shrike writes a file or folder path for people: "~"
//  for the home folder, and "/tmp", "/var", "/etc" instead of the
//  "/private/…" folders they link to. A folder chosen in an Open panel
//  comes back resolved ("/private/tmp/out") while a folder taken from a
//  listed file keeps the form the user opened ("/tmp/out"); through this
//  helper both read the same. Only for text people read — file work
//  keeps the real URL.
//

import Foundation

public enum UserFacingPath {

    /// The macOS system links: "/tmp" → "/private/tmp", and so on.
    private static let privateLinks = ["tmp", "var", "etc"]

    public static func string(_ url: URL) -> String { string(url.path) }

    public static func string(_ path: String) -> String {
        var path = path
        for link in privateLinks {
            let target = "/private/" + link
            if path == target || path.hasPrefix(target + "/") {
                path.removeFirst("/private".count)
                break
            }
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
