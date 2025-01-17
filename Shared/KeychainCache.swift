// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0

import Foundation
import SwiftyJSON
import MozillaAppServices

private let log = Logger.keychainLogger

public protocol JSONLiteralConvertible {
    func asJSON() -> JSON
}

open class KeychainCache<T: JSONLiteralConvertible> {
    public let branch: String
    public let label: String

    open var value: T? {
        didSet {
            checkpoint()
        }
    }

    public init(branch: String, label: String, value: T?) {
        self.branch = branch
        self.label = label
        self.value = value
    }

    open class func fromBranch(_ branch: String, withLabel label: String?, withDefault defaultValue: T? = nil, factory: (JSON) -> T?) -> KeychainCache<T> {
        if let l = label {
            let key = "\(branch).\(l)"
            MZKeychainWrapper.sharedClientAppContainerKeychain.ensureStringItemAccessibility(.afterFirstUnlock, forKey: key)
            if let s = MZKeychainWrapper.sharedClientAppContainerKeychain.string(forKey: key) {
                if let t = factory(JSON(parseJSON: s)) {
                    log.info("Read \(branch) from Keychain with label \(branch).\(l).")
                    return KeychainCache(branch: branch, label: l, value: t)
                } else {
                    log.warning("Found \(branch) in Keychain with label \(branch).\(l), but could not parse it.")
                }
            } else {
                log.warning("Did not find \(branch) in Keychain with label \(branch).\(l).")
            }
        } else {
            log.warning("Did not find \(branch) label in Keychain.")
        }
        // Fall through to missing.
        log.warning("Failed to read \(branch) from Keychain.")
        let label = label ?? Bytes.generateGUID()
        return KeychainCache(branch: branch, label: label, value: defaultValue)
    }

    open func checkpoint() {
        log.info("Storing \(self.branch) in Keychain with label \(self.branch).\(self.label).")
        if let value = value,
            let jsonString = value.asJSON().stringify() {
            MZKeychainWrapper.sharedClientAppContainerKeychain.set(jsonString, forKey: "\(branch).\(label)", withAccessibility: .afterFirstUnlock)
        } else {
            MZKeychainWrapper.sharedClientAppContainerKeychain.removeObject(forKey: "\(branch).\(label)")
        }
    }
}
