// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// An internal struct used to define wallpaper names and their respective
/// accessibility strings for voice-over.
private struct WallpaperID {
    let name: String
    let accessibilityLabel: String
}

/// A internal model for projects with wallpapers that are timed.
private struct LegacyWallpaperCollection {
    /// The base file names of the wallpaper assets to be included in the collection.
    let wallpaperIDs: [WallpaperID]
    let type: LegacyWallpaperType
    /// The date on which a collection should become available to users.
    let shipDate: Date?
    /// The date on which a collection becomes unavailable to users.
    let expiryDate: Date?
    /// The locales that the wallpapers will show up in. If empty,
    /// they will not show up anywhere.
    let locales: [String]?

    /// Created a collection of wallpapers offered, with the option for it to be
    /// region or time limited.
    ///
    /// - Parameters:
    ///   - wallpaperFileNames: An array of the names of the wallpapers included in the collection.
    ///   - type: The collection type.
    ///   - shipDate: An optional shipping date
    ///   - expiryDate: An optional expiry date, on and after which the wallpapers in the array are no longer shown.
    ///   - locales: An optional set of locales used to limit the regions to which
    ///         wallpapers in the collection are shown.
    init(wallpaperFileNames: [WallpaperID],
         ofType type: LegacyWallpaperType,
         shippingOn shipDate: Date? = nil,
         expiringOn expiryDate: Date? = nil,
         limitedToLocales locales: [String]? = nil) {
        self.wallpaperIDs = wallpaperFileNames
        self.type = type
        self.shipDate = shipDate
        self.expiryDate = expiryDate
        self.locales = locales
    }
}

struct LegacyWallpaperDataManager {
    typealias accessibilityIDs = String.Settings.Homepage.Wallpaper.AccessibilityLabels

    private var resourceManager: LegacyWallpaperResourceManager

    init(with resourceManager: LegacyWallpaperResourceManager = LegacyWallpaperResourceManager()) {
        self.resourceManager = resourceManager
    }

    /// Returns an array of wallpapers available to the user given their region,
    /// and various seasonal or expiration date requirements.
    var availableWallpapers: [LegacyWallpaper] {
        var wallpapers: [LegacyWallpaper] = []
        // Default wallpaper should always be first in the array.
        wallpapers.append(LegacyWallpaper(named: "defaultBackground",
                                    ofType: .defaultBackground,
                                    withAccessibiltyLabel: accessibilityIDs.DefaultWallpaper))

        if let themedWallpapers = getWallpapers(from: allWallpaperCollections()) {
            wallpapers.append(contentsOf: themedWallpapers)
        }

        return wallpapers
    }

    public func getImageSet(at index: Int) -> LegacyWallpaperImageSet {
        return resourceManager.getImageSet(for: availableWallpapers[index])
    }

    // MARK: - Wallpaper data

    /// This function will, given an array of collections, return an array of individual
    /// `Wallpaper` objects if those objects meet date and locale criteria and if
    /// those objects currently have resources (images) available to be presented
    /// to the user.
    private func getWallpapers(
        from collection: [LegacyWallpaperCollection]?,
        ignoringEligibility shouldIgnoreEligibility: Bool = false
    ) -> [LegacyWallpaper]? {

        guard let collection = collection else { return nil }

        var wallpapers = [LegacyWallpaper]()

        collection.forEach { collection in
            wallpapers.append(
                contentsOf: collection.wallpaperIDs.compactMap { wallpaperID in

                    let wallpaper = LegacyWallpaper(named: wallpaperID.name,
                                              ofType: collection.type,
                                              withAccessibiltyLabel: wallpaperID.accessibilityLabel,
                                              expiringOn: collection.expiryDate,
                                              limitedToLocale: collection.locales)

                    if shouldIgnoreEligibility { return wallpaper }
                    let shouldShowWallpaper = wallpaper.meetsDateAndLocaleCriteria && resourceManager.verifyResourceExists(for: wallpaper)
                    return shouldShowWallpaper ? wallpaper : nil
            })
        }

        return wallpapers
    }

    private func allWallpaperCollections() -> [LegacyWallpaperCollection] {

        var allCollections = firefoxDefaultCollection()

        if let specialCollections = allSpecialCollections() {
            allCollections.append(contentsOf: specialCollections)
        }

        return allCollections
    }

    private func firefoxDefaultCollection() -> [LegacyWallpaperCollection] {
        return [LegacyWallpaperCollection(
            wallpaperFileNames: [WallpaperID(name: "fxSunrise",
                                             accessibilityLabel: accessibilityIDs.FxSunriseWallpaper)],
            ofType: .themed(type: .firefox)),
                LegacyWallpaperCollection(
            wallpaperFileNames: [WallpaperID(name: "fxCerulean",
                                             accessibilityLabel: accessibilityIDs.FxCeruleanWallpaper),
                                 WallpaperID(name: "fxAmethyst",
                                             accessibilityLabel: accessibilityIDs.FxAmethystWallpaper)],
            ofType: .themed(type: .firefoxOverlay))]
    }

    private func allSpecialCollections() -> [LegacyWallpaperCollection]? {
        var specialCollections = [LegacyWallpaperCollection]()

        specialCollections.append(projectHouseCollection())
        specialCollections.append(v100CelebrationCollection())

        return specialCollections.isEmpty ? nil : specialCollections
    }

    // MARK: - Resource verification
    public func verifyResources() {
        guard let specialCollections = getWallpapers(from: allSpecialCollections(),
                                                     ignoringEligibility: true)
        else { return }

        resourceManager.verifyResources(for: specialCollections)
    }
}

// MARK: - Wallpaper Collections
// These collections should remain in code for as long as possible.
// They are required for not just downloading wallpapers, but also
// deleting them from the disk once they expire.
extension LegacyWallpaperDataManager {
    private func projectHouseCollection() -> LegacyWallpaperCollection {
        let houseExpiryDate = Calendar.current.date(
            from: DateComponents(year: 2022, month: 5, day: 1))

        return LegacyWallpaperCollection(
            wallpaperFileNames: [WallpaperID(name: "trRed",
                                             accessibilityLabel: "Turning Red wallpaper, giant red panda"),
                                 WallpaperID(name: "trGroup",
                                             accessibilityLabel: "Turning Red wallpaper, Mei and friends")],
            ofType: .themed(type: .projectHouse),
            expiringOn: houseExpiryDate,
            limitedToLocales: ["en_US", "es_US"])
    }

    private func v100CelebrationCollection() -> LegacyWallpaperCollection {
        return LegacyWallpaperCollection(
            wallpaperFileNames: [WallpaperID(name: "beachVibes",
                                             accessibilityLabel: accessibilityIDs.FxBeachHillsWallpaper),
                                 WallpaperID(name: "twilightHills",
                                             accessibilityLabel: accessibilityIDs.FxTwilightHillsWallpaper)],
            ofType: .themed(type: .v100Celebration))
    }
}
