//
//  ListSortIndicator.swift
//  ShrikeUI
//
//  Which list column shows the sort arrow. A sort whose
//  value has no visible column (Date Captured, Kind, or Rating / Dimensions
//  while hidden) gets one temporary last column named after the sort.
//

import Foundation

struct ListSortIndicator: Equatable {
    /// Sort-descriptor key of the column that carries the arrow.
    var arrowKey: String
    var ascending: Bool
    /// The temporary column's title; nil when the sort has a column of its own.
    var extraColumnTitle: String?

    /// The key of the temporary column's sort descriptor.
    static let extraKey = "sortvalue"
    static let extraColumnID = "col.sortvalue"

    /// What VoiceOver reads on the sorted header.
    var accessibilityValue: String { ascending ? "ascending" : "descending" }

    /// `hiddenColumnIDs` are the list columns the user hid (their identifiers, as saved).
    static func plan(key: BrowserSortKey, direction: BrowserSortDirection,
                     hiddenColumnIDs: Set<String>) -> ListSortIndicator {
        let ascending = direction == .ascending
        let own: (descriptorKey: String, columnID: String)?
        switch key {
        case .name: own = ("name", "col.name")
        case .dateModified: own = ("date", "col.date")
        case .size: own = ("size", "col.size")
        case .rating: own = ("rating", "col.rating")
        case .dimensions: own = ("dim", "col.dim")
        case .dateCaptured, .kind: own = nil
        }
        if let own, !hiddenColumnIDs.contains(own.columnID) {
            return ListSortIndicator(arrowKey: own.descriptorKey, ascending: ascending, extraColumnTitle: nil)
        }
        return ListSortIndicator(arrowKey: extraKey, ascending: ascending, extraColumnTitle: title(of: key))
    }

    /// The sort's name, as the Sort By menu words it.
    static func title(of key: BrowserSortKey) -> String {
        switch key {
        case .name: return "Name"
        case .dateCaptured: return "Date Captured"
        case .dateModified: return "Date Modified"
        case .size: return "Size"
        case .rating: return "Rating"
        case .kind: return "Kind"
        case .dimensions: return "Dimensions"
        }
    }
}
