//
//  ThumbnailItemInitTests.swift
//  ShrikeUITests
//
//  Regression: the browser grid crashed on its first cell because
//  `NSCollectionView` builds registered item classes through the
//  Objective-C `initWithNibName:bundle:` path, which `ThumbnailItem`
//  did not implement (Swift "unimplemented initializer" trap).
//

import AppKit
import XCTest
@testable import ShrikeUI

@MainActor
final class ThumbnailItemInitTests: XCTestCase, NSCollectionViewDataSource {

    func testRegisteredCollectionViewCanMakeThumbnailItem() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 120, height: 150)
        let collectionView = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        collectionView.collectionViewLayout = layout
        collectionView.register(ThumbnailItem.self,
                                forItemWithIdentifier: ThumbnailItem.reuseIdentifier)
        collectionView.dataSource = self

        // This is the exact call the browser makes per cell. Before the
        // fix it trapped inside `ThumbnailItem.init(nibName:bundle:)`.
        let item = collectionView.makeItem(
            withIdentifier: ThumbnailItem.reuseIdentifier,
            for: IndexPath(item: 0, section: 0)
        )
        XCTAssertTrue(item is ThumbnailItem)
        // The view must be loadable too (loadView builds the cell chrome).
        XCTAssertNotNil(item.view)
    }

    func testObjCInitializerPathBuildsItem() {
        // Same entry point AppKit uses, called directly.
        let item = ThumbnailItem(nibName: nil, bundle: nil)
        XCTAssertNotNil(item.view)
        let viaConvenience = ThumbnailItem()
        XCTAssertNotNil(viaConvenience.view)
    }

    // MARK: NSCollectionViewDataSource (one dummy item)

    nonisolated func collectionView(_ collectionView: NSCollectionView,
                                    numberOfItemsInSection section: Int) -> Int { 1 }

    nonisolated func collectionView(_ collectionView: NSCollectionView,
                                    itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        MainActor.assumeIsolated {
            collectionView.makeItem(withIdentifier: ThumbnailItem.reuseIdentifier, for: indexPath)
        }
    }
}
