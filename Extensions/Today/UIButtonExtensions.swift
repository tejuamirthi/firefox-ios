// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0

import UIKit

extension UIButton {
    func setBackgroundColor(_ color: UIColor, forState state: UIControl.State) {
        let colorView = UIView(frame: CGRect(width: 1, height: 1))
        colorView.backgroundColor = color

        UIGraphicsBeginImageContext(colorView.bounds.size)
        if let context = UIGraphicsGetCurrentContext() {
            colorView.layer.render(in: context)
        }
        let colorImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        self.setBackgroundImage(colorImage, for: state)
    }

    func setInsets(forContentPadding contentPadding: UIEdgeInsets,
                   imageTitlePadding: CGFloat) {
        let isLTR = effectiveUserInterfaceLayoutDirection == .leftToRight

        contentEdgeInsets = UIEdgeInsets(
            top: contentPadding.top,
            left: isLTR ? contentPadding.left : contentPadding.right + imageTitlePadding,
            bottom: contentPadding.bottom,
            right: isLTR ? contentPadding.right + imageTitlePadding : contentPadding.left
        )

        titleEdgeInsets = UIEdgeInsets(
            top: 0,
            left: isLTR ? imageTitlePadding : -imageTitlePadding,
            bottom: 0,
            right: isLTR ? -imageTitlePadding: imageTitlePadding
        )
    }
}
