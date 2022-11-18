// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0

import Foundation
import Shared
import Storage
import WebKit

private let log = Logger.browserLogger

class MetadataParserHelper: TabEventHandler {
    init() {
        register(self, forTabEvents: .didChangeURL)
    }

    func tab(_ tab: Tab, didChangeURL url: URL) {
        // Get the metadata out of the page-metadata-parser, and into a type safe struct as soon
        // as possible.
        guard let webView = tab.webView,
            let url = webView.url, url.isWebPage(includeDataURIs: false), !InternalURL.isValid(url: url) else {
                TabEvent.post(.pageMetadataNotAvailable, for: tab)
                tab.pageMetadata = nil
                return
        }
        webView.evaluateJavascriptInDefaultContentWorld("__firefox__.metadata && __firefox__.metadata.getMetadata()") { result, error in
            guard error == nil else {
                TabEvent.post(.pageMetadataNotAvailable, for: tab)
                tab.pageMetadata = nil
                return
            }

            guard let dict = result as? [String: Any],
                let pageURL = tab.url?.displayURL,
                let pageMetadata = PageMetadata.fromDictionary(dict) else {
                    log.debug("Page contains no metadata!")
                    TabEvent.post(.pageMetadataNotAvailable, for: tab)
                    tab.pageMetadata = nil
                    return
            }

            tab.pageMetadata = pageMetadata
            TabEvent.post(.didLoadPageMetadata(pageMetadata), for: tab)

            let userInfo: [String: Any] = [
                "isPrivate": tab.isPrivate,
                "pageMetadata": pageMetadata,
                "tabURL": pageURL
            ]
            NotificationCenter.default.post(name: .OnPageMetadataFetched, object: nil, userInfo: userInfo)
        }
    }
}

class MediaImageLoader: TabEventHandler {
    private let prefs: Prefs

    init(_ prefs: Prefs) {
        self.prefs = prefs
        register(self, forTabEvents: .didLoadPageMetadata)
    }

    func tab(_ tab: Tab, didLoadPageMetadata metadata: PageMetadata) {
        let cacheImages = !NoImageModeHelper.isActivated(prefs)
        if let urlString = metadata.mediaURL,
            let mediaURL = URL(string: urlString), cacheImages {
            prepareCache(mediaURL)
        }
    }

    fileprivate func prepareCache(_ url: URL) {
        if !ImageLoadingHandler.shared.isImageInCache(url: url) {
            downloadAndCache(fromURL: url)
        }
    }

    fileprivate func downloadAndCache(fromURL webUrl: URL) {
        ImageLoadingHandler.shared.downloadAndCacheImage(with: webUrl) { _, _ in }
    }
}
