// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Shared

enum SearchBarPosition: String, FlaggableFeatureOptions {
    case bottom
    case top

    var getLocalizedTitle: String {
        switch self {
        case .bottom:
            return .Settings.Toolbar.Bottom
        case .top:
            return .Settings.Toolbar.Top
        }
    }
}

protocol SearchBarPreferenceDelegate: AnyObject {
    func didUpdateSearchBarPositionPreference()
}

final class SearchBarSettingsViewModel: FeatureFlaggable {

    static var isEnabled: Bool {
        let isiPad = UIDevice.current.userInterfaceIdiom == .pad
        let isFeatureEnabled = FeatureFlagsManager.shared.isFeatureEnabled(.bottomSearchBar, checking: .buildOnly)
        return !isiPad && isFeatureEnabled && !AppConstants.isRunningUITests
    }

    var title: String = .Settings.Toolbar.Toolbar
    weak var delegate: SearchBarPreferenceDelegate?

    private let prefs: Prefs
    private let notificationCenter: NotificationCenter
    init(prefs: Prefs, notificationCenter: NotificationCenter = NotificationCenter.default) {
        self.prefs = prefs
        self.notificationCenter = notificationCenter
    }

    var searchBarTitle: String {
        searchBarPosition.getLocalizedTitle
    }

    var searchBarPosition: SearchBarPosition {
        guard let position: SearchBarPosition = featureFlags.getCustomState(for: .searchBarPosition) else {
            return .bottom
        }

        return position
    }

    var topSetting: CheckmarkSetting {
        return CheckmarkSetting(title: NSAttributedString(string: SearchBarPosition.top.getLocalizedTitle),
                                subtitle: nil,
                                accessibilityIdentifier: AccessibilityIdentifiers.Settings.SearchBar.topSetting,
                                isChecked: { return self.searchBarPosition == .top },
                                onChecked: { self.saveSearchBarPosition(SearchBarPosition.top)}
        )
    }

    var bottomSetting: CheckmarkSetting {
        return CheckmarkSetting(title: NSAttributedString(string: SearchBarPosition.bottom.getLocalizedTitle),
                                subtitle: nil,
                                accessibilityIdentifier: AccessibilityIdentifiers.Settings.SearchBar.bottomSetting,
                                isChecked: { return self.searchBarPosition == .bottom },
                                onChecked: { self.saveSearchBarPosition(SearchBarPosition.bottom) }
        )
    }
}

// MARK: Private
private extension SearchBarSettingsViewModel {

    func saveSearchBarPosition(_ searchBarPosition: SearchBarPosition) {
        featureFlags.set(feature: .searchBarPosition, to: searchBarPosition)
        delegate?.didUpdateSearchBarPositionPreference()
        recordPreferenceChange(searchBarPosition)

        let notificationObject = [PrefsKeys.FeatureFlags.SearchBarPosition: searchBarPosition]
        notificationCenter.post(name: .SearchBarPositionDidChange, object: notificationObject)
    }

    func recordPreferenceChange(_ searchBarPosition: SearchBarPosition) {
        let extras = [TelemetryWrapper.EventExtraKey.preference.rawValue: PrefsKeys.FeatureFlags.SearchBarPosition,
                      TelemetryWrapper.EventExtraKey.preferenceChanged.rawValue: searchBarPosition.rawValue]
        TelemetryWrapper.recordEvent(category: .action,
                                     method: .change,
                                     object: .setting,
                                     extras: extras)
    }
}

// MARK: Telemetry
extension SearchBarSettingsViewModel {

    static func recordLocationTelemetry(for searchbarPosition: SearchBarPosition) {
        let extras = [TelemetryWrapper.EventExtraKey.preference.rawValue: searchbarPosition.rawValue]
        TelemetryWrapper.recordEvent(category: .information, method: .view, object: .awesomebarLocation, extras: extras)
    }
}
