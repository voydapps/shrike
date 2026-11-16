//
//  SettingsWindowSize.swift
//  ShrikeUI
//
//  The Settings window's height per tab. Pure rule; the window
//  wiring (resize on a tab switch, top edge fixed) is
//  `PreferencesWindowController.fitToTab(animated:)`.
//

import Foundation

enum SettingsWindowSize {
    static let width: CGFloat = 560
    static let minimumHeight: CGFloat = 320
    static let screenShare: CGFloat = 0.8
    /// Seconds of the resize ease; none under Reduce Motion.
    static let animationSeconds: TimeInterval = 0.15

    /// The content height for a tab whose content needs `fitting`. Its own
    /// height, but at least `320 - chrome`, so the WINDOW (content + `chrome`,
    /// the title bar and toolbar) is at least 320 pt. At most 80 % of the
    /// screen's visible height (never under 320 pt); a taller tab is cut
    /// to that and scrolls.
    static func height(fitting: CGFloat, chrome: CGFloat = 0, visibleScreenHeight: CGFloat) -> CGFloat {
        let cap = max(visibleScreenHeight * screenShare, minimumHeight)
        return min(max(fitting, minimumHeight - chrome), cap)
    }

    static func animationDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : animationSeconds
    }
}
