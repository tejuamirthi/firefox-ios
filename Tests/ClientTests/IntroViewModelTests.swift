// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import Client

class IntroViewModelTests: XCTestCase {

    var viewModel: IntroViewModel!

    override func setUp() {
        super.setUp()
        viewModel = IntroViewModel()
    }

    override func tearDown() {
        super.tearDown()
        viewModel = nil
    }

    func testGetWelcomeViewModel() {
        let cardViewModel = viewModel.getCardViewModel(cardType: .welcome)
        XCTAssertEqual(cardViewModel?.cardType, IntroViewModel.InformationCards.welcome)
    }

    func testGetWallpaperViewModel() {
        let cardViewModel = viewModel.getCardViewModel(cardType: .wallpapers)
        XCTAssertEqual(cardViewModel?.cardType, IntroViewModel.InformationCards.wallpapers)
    }

    func testGetSyncViewModel() {
        let cardViewModel = viewModel.getCardViewModel(cardType: .signSync)
        XCTAssertEqual(cardViewModel?.cardType, IntroViewModel.InformationCards.signSync)
    }

    func testNextIndexAfterLastCard() {
        let index = viewModel.getNextIndex(currentIndex: 2, goForward: true)
        XCTAssertNil(index)
    }

    func testNextIndexBeforeFirstCard() {
        let index = viewModel.getNextIndex(currentIndex: 0, goForward: false)
        XCTAssertNil(index)
    }
}
