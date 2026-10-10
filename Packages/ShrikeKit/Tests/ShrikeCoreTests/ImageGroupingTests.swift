//
//  ImageGroupingTests.swift
//  ShrikeCoreTests
//
//  RAW+JPEG pairs, sidecars and Live Photos. Pure string work,
//  so the URLs below never touch the disk.
//

import XCTest
import Foundation
@testable import ShrikeCore

final class ImageGroupingTests: XCTestCase {

    private func u(_ path: String) -> URL { URL(fileURLWithPath: path) }
    private func names(_ groups: [ImageGroup]) -> [String] { groups.map(\.primary.lastPathComponent) }

    func testOlympusJPGAndORFBecomeOneGroupWithJPGPrimary() {
        let groups = ImageGrouping.group([u("/cam/P1250298.JPG"), u("/cam/P1250298.ORF")])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].primary, u("/cam/P1250298.JPG"))
        XCTAssertEqual(groups[0].rawURL, u("/cam/P1250298.ORF"))
        XCTAssertTrue(groups[0].hasRAW)
        XCTAssertFalse(groups[0].primaryIsRAW)
        XCTAssertEqual(groups[0].allURLs, [u("/cam/P1250298.JPG"), u("/cam/P1250298.ORF")])
    }

    func testRAWListedBeforeJPGStillPicksJPG() {
        let groups = ImageGrouping.group([u("/c/A.CR3"), u("/c/A.JPG")])
        XCTAssertEqual(names(groups), ["A.JPG"])
        XCTAssertEqual(groups[0].rawURLs, [u("/c/A.CR3")])
    }

    func testBasenameMatchIsCaseInsensitive() {
        let groups = ImageGrouping.group([u("/c/IMG_0001.jpg"), u("/c/img_0001.CR3")])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].rawURL, u("/c/img_0001.CR3"))
    }

    func testLoneRAWIsItsOwnPrimary() {
        let groups = ImageGrouping.group([u("/c/DSC_1.NEF"), u("/c/DSC_2.JPG")])
        XCTAssertEqual(names(groups), ["DSC_1.NEF", "DSC_2.JPG"])
        XCTAssertTrue(groups[0].primaryIsRAW)
        XCTAssertTrue(groups[0].hasRAW)
        XCTAssertTrue(groups[0].companions.isEmpty)
        XCTAssertFalse(groups[1].hasRAW)
    }

    func testInputOrderIsPreserved() {
        let input = [u("/c/a.ORF"), u("/c/a.JPG"), u("/c/b.JPG"), u("/c/c.ORF"), u("/c/d.png")]
        XCTAssertEqual(names(ImageGrouping.group(input)), ["a.JPG", "b.JPG", "c.ORF", "d.png"])
    }

    func testFilesInDifferentFoldersDoNotPair() {
        let groups = ImageGrouping.group([u("/one/IMG_1.JPG"), u("/two/IMG_1.CR2")])
        XCTAssertEqual(groups.count, 2)
        XCTAssertFalse(groups[0].hasRAW)
        XCTAssertTrue(groups[1].primaryIsRAW)
    }

    func testDisplayPriorityJPEGOverHEICOverPNG() {
        let groups = ImageGrouping.group([u("/c/x.png"), u("/c/x.heic"), u("/c/x.jpg"), u("/c/x.dng")])
        // Display files never merge with each other; the RAW joins the best one.
        XCTAssertEqual(names(groups), ["x.png", "x.heic", "x.jpg"])
        XCTAssertEqual(groups[2].rawURL, u("/c/x.dng"))
        XCTAssertNil(groups[0].rawURL)
        XCTAssertNil(groups[1].rawURL)
    }

    func testHEICLivePhotoMovieAttaches() {
        let groups = ImageGrouping.group([u("/p/IMG_4000.HEIC"), u("/p/IMG_4000.MOV"), u("/p/IMG_4001.JPG"), u("/p/IMG_4001.mov")])
        XCTAssertEqual(names(groups), ["IMG_4000.HEIC", "IMG_4001.JPG"])
        XCTAssertEqual(groups[0].livePhotoMovie, u("/p/IMG_4000.MOV"))
        XCTAssertEqual(groups[1].livePhotoMovie, u("/p/IMG_4001.mov"))
        XCTAssertFalse(groups[0].hasRAW)
    }

    func testMovieNextToPNGOrRAWIsNotALivePhoto() {
        let groups = ImageGrouping.group([u("/p/a.png"), u("/p/a.mov"), u("/p/b.ORF"), u("/p/b.MOV")])
        XCTAssertEqual(names(groups), ["a.png", "b.ORF"])
        XCTAssertNil(groups[0].livePhotoMovie)
        XCTAssertNil(groups[1].livePhotoMovie)
    }

    func testXMPSidecarsAttach() {
        let groups = ImageGrouping.group([
            u("/c/IMG_1.CR2"), u("/c/IMG_1.JPG"), u("/c/IMG_1.xmp"),
            u("/c/IMG_2.CR2"), u("/c/IMG_2.CR2.xmp"),      // darktable style, RAW only
            u("/c/IMG_3.jpg"), u("/c/IMG_3.AAE"),          // Apple edit sidecar
        ])
        XCTAssertEqual(names(groups), ["IMG_1.JPG", "IMG_2.CR2", "IMG_3.jpg"])
        XCTAssertEqual(groups[0].companions.map(\.kind), [.raw, .sidecar])
        XCTAssertEqual(groups[0].sidecarURLs, [u("/c/IMG_1.xmp")])
        XCTAssertEqual(groups[1].sidecarURLs, [u("/c/IMG_2.CR2.xmp")])
        XCTAssertTrue(groups[1].primaryIsRAW)
        XCTAssertEqual(groups[2].sidecarURLs, [u("/c/IMG_3.AAE")])
    }

    func testOrphanCompanionsDroppedByDefaultKeptOnRequest() {
        let input = [u("/c/a.jpg"), u("/c/lonely.xmp"), u("/c/clip.mov")]
        XCTAssertEqual(names(ImageGrouping.group(input)), ["a.jpg"])
        var options = ImageGrouping.Options()
        options.keepOrphanCompanions = true
        XCTAssertEqual(names(ImageGrouping.group(input, options: options)), ["a.jpg", "lonely.xmp", "clip.mov"])
    }

    func testDisabledOptionsKeepEveryImageSeparate() {
        let input = [u("/c/a.JPG"), u("/c/a.ORF"), u("/c/a.xmp"), u("/c/b.HEIC"), u("/c/b.MOV")]
        let groups = ImageGrouping.group(input, options: .disabled)
        XCTAssertEqual(names(groups), ["a.JPG", "a.ORF", "b.HEIC"])
        XCTAssertTrue(groups.allSatisfy { $0.companions.isEmpty })
        XCTAssertTrue(groups[1].primaryIsRAW)
    }

    func testRAWPairingOffStillAttachesSidecarToRAW() {
        var options = ImageGrouping.Options()
        options.pairRAW = false
        let groups = ImageGrouping.group([u("/c/a.JPG"), u("/c/a.ORF"), u("/c/a.xmp")], options: options)
        XCTAssertEqual(names(groups), ["a.JPG", "a.ORF"])
        XCTAssertEqual(groups[1].sidecarURLs, [u("/c/a.xmp")])
    }

    func testUnknownAndExtensionlessFilesPassThrough() {
        let groups = ImageGrouping.group([u("/c/README"), u("/c/notes.txt"), u("/c/v1.2/scan"), u("/c/x.jpg")])
        XCTAssertEqual(names(groups), ["README", "notes.txt", "scan", "x.jpg"])
    }

    func testEmptyInput() {
        XCTAssertTrue(ImageGrouping.group([]).isEmpty)
    }

    func testPreferenceKeyAndDefault() {
        let key = ImageGroupingPreference.key
        let saved = ShrikeDefaults.store.object(forKey: key)
        defer { ShrikeDefaults.store.set(saved, forKey: key) }
        ShrikeDefaults.store.removeObject(forKey: key)
        XCTAssertTrue(ImageGroupingPreference.isEnabled)
        XCTAssertEqual(ImageGroupingPreference.options, .default)
        ImageGroupingPreference.isEnabled = false
        XCTAssertEqual(ImageGroupingPreference.options, .showBothFiles)
        XCTAssertFalse(ImageGroupingPreference.options.pairRAW)
        XCTAssertTrue(ImageGroupingPreference.options.attachSidecars)
        XCTAssertTrue(ImageGroupingPreference.options.attachLivePhotoMovies)
    }

    // MARK: - "Show both files" (last row)

    func testShowBothFilesKeepsCompanionsWithTheirImage() {
        // Pref off: JPEG and ORF are separate items; the MOV stays with the
        // JPEG (its Live Photo), the plain XMP with the ORF (RAW editors'
        // sidecar) — the same files they travel with when pairing is on.
        let input = [u("/c/P1.JPG"), u("/c/P1.ORF"), u("/c/P1.xmp"), u("/c/P1.MOV")]
        let groups = ImageGrouping.group(input, options: .showBothFiles)
        XCTAssertEqual(names(groups), ["P1.JPG", "P1.ORF"])
        XCTAssertEqual(groups[0].allURLs, [u("/c/P1.JPG"), u("/c/P1.MOV")])
        XCTAssertEqual(groups[0].livePhotoMovie, u("/c/P1.MOV"))
        XCTAssertFalse(groups[0].hasRAW)
        XCTAssertEqual(groups[1].allURLs, [u("/c/P1.ORF"), u("/c/P1.xmp")])
        XCTAssertEqual(groups[1].sidecarURLs, [u("/c/P1.xmp")])
        XCTAssertTrue(groups[1].primaryIsRAW)

        // Same files, pairing on: one item, everything together.
        let paired = ImageGrouping.group(input)
        XCTAssertEqual(names(paired), ["P1.JPG"])
        XCTAssertEqual(Set(paired[0].allURLs), Set(input))
    }

    func testShowBothFilesViaPreference() {
        let key = ImageGroupingPreference.key
        let saved = ShrikeDefaults.store.object(forKey: key)
        defer { ShrikeDefaults.store.set(saved, forKey: key) }
        ImageGroupingPreference.isEnabled = false
        let groups = ImageGrouping.group([u("/c/a.HEIC"), u("/c/a.MOV"), u("/c/a.AAE"), u("/c/b.JPG"), u("/c/b.ORF")],
                                         options: ImageGroupingPreference.options)
        XCTAssertEqual(names(groups), ["a.HEIC", "b.JPG", "b.ORF"])
        XCTAssertEqual(groups[0].allURLs, [u("/c/a.HEIC"), u("/c/a.MOV"), u("/c/a.AAE")])
    }

    func testShowBothFilesSidecarOwners() {
        let groups = ImageGrouping.group([
            u("/c/A.JPG"), u("/c/A.CR3"), u("/c/A.AAE"),                  // .aae → display file
            u("/c/B.jpg"), u("/c/B.cr3"), u("/c/B.JPG.xmp"), u("/c/B.CR3.xmp"),  // darktable names
            u("/c/C.ORF"), u("/c/C.aae"),                                 // lone RAW takes all
            u("/c/D.heic"), u("/c/D.xmp"),                                // lone display takes all
        ], options: .showBothFiles)
        XCTAssertEqual(names(groups), ["A.JPG", "A.CR3", "B.jpg", "B.cr3", "C.ORF", "D.heic"])
        XCTAssertEqual(groups[0].sidecarURLs, [u("/c/A.AAE")])
        XCTAssertEqual(groups[1].companions, [])
        XCTAssertEqual(groups[2].sidecarURLs, [u("/c/B.JPG.xmp")])
        XCTAssertEqual(groups[3].sidecarURLs, [u("/c/B.CR3.xmp")])
        XCTAssertEqual(groups[4].sidecarURLs, [u("/c/C.aae")])
        XCTAssertEqual(groups[5].sidecarURLs, [u("/c/D.xmp")])
    }

    // MARK: - RAW list comes from ImageFormat

    func testLessCommonDecodableRAWPairs() {
        let groups = ImageGrouping.group([u("/c/H1.JPG"), u("/c/H1.3FR"), u("/c/L1.jpg"), u("/c/L1.RWL")])
        XCTAssertEqual(names(groups), ["H1.JPG", "L1.jpg"])
        XCTAssertEqual(groups[0].rawURL, u("/c/H1.3FR"))
        XCTAssertEqual(groups[1].rawURL, u("/c/L1.RWL"))
    }

    func testUndecodableRAWIsCompanionOnly() {
        // X3F / KDC travel with their JPEG (trash, move, copy,
        // rename) but are never listed on their own.
        let groups = ImageGrouping.group([u("/c/S1.JPG"), u("/c/S1.X3F"), u("/c/K1.jpg"), u("/c/K1.kdc"),
                                          u("/c/S1.X3F.xmp")])
        XCTAssertEqual(names(groups), ["S1.JPG", "K1.jpg"])
        XCTAssertEqual(groups[0].rawURL, u("/c/S1.X3F"))
        XCTAssertEqual(groups[0].sidecarURLs, [u("/c/S1.X3F.xmp")])
        XCTAssertEqual(groups[0].allURLs, [u("/c/S1.JPG"), u("/c/S1.X3F"), u("/c/S1.X3F.xmp")])
        XCTAssertEqual(groups[1].rawURL, u("/c/K1.kdc"))
        XCTAssertFalse(groups[0].primaryIsRAW)
    }

    func testLoneUndecodableRAWIsNotListed() {
        XCTAssertEqual(names(ImageGrouping.group([u("/c/S2.X3F"), u("/c/K2.KDC"), u("/c/other.jpg")])),
                       ["other.jpg"])
        let orphansKept = ImageGrouping.Options(keepOrphanCompanions: true)
        XCTAssertEqual(names(ImageGrouping.group([u("/c/S2.X3F")], options: orphansKept)), [],
                       "never a primary, even with orphan companions kept")
        // Pairing off ("Show both files"): nothing to attach to, so dropped.
        XCTAssertEqual(names(ImageGrouping.group([u("/c/S1.JPG"), u("/c/S1.X3F")], options: .disabled)),
                       ["S1.JPG"])
    }

    func testOtherSupportedDisplayTypePairsWithRAW() {
        let groups = ImageGrouping.group([u("/c/A.jp2"), u("/c/A.CR2")])
        XCTAssertEqual(names(groups), ["A.jp2"])
        XCTAssertEqual(groups[0].rawURL, u("/c/A.CR2"))
    }

    // MARK: - Performance

    /// 20,000 URLs (10,000 JPG+ORF pairs, mixed case, long paths).
    /// Budget: < 20 ms in release (`swift test -c release -Xswiftc
    /// -enable-testing`). Debug builds get a looser bound because
    /// unoptimised Swift is several times slower; the bound there only
    /// catches accidental O(n^2) regressions.
    func testPerformance20k() {
        var urls: [URL] = []
        urls.reserveCapacity(20_000)
        let dir = "/Volumes/Card/DCIM/100OLYMP"
        for i in 0..<10_000 {
            let base = String(format: "P%07d", i)
            urls.append(URL(fileURLWithPath: "\(dir)/\(base).JPG"))
            urls.append(URL(fileURLWithPath: "\(dir)/\(base).\(i % 3 == 0 ? "orf" : "ORF")"))
        }

        var best = Duration.seconds(10)
        var groups: [ImageGroup] = []
        let clock = ContinuousClock()
        for _ in 0..<5 {
            let elapsed = clock.measure { groups = ImageGrouping.group(urls) }
            best = min(best, elapsed)
        }
        XCTAssertEqual(groups.count, 10_000)
        XCTAssertTrue(groups.allSatisfy(\.hasRAW))

        let ms = Double(best.components.attoseconds) / 1e15 + Double(best.components.seconds) * 1000
        #if DEBUG
        let budget = 150.0
        #else
        let budget = 20.0
        #endif
        print("[ImageGrouping] 20,000 URLs grouped in \(String(format: "%.2f", ms)) ms (best of 5)")
        XCTAssertLessThan(ms, budget)
    }
}
