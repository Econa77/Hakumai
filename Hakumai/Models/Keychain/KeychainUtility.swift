//
//  KeychainUtility.swift
//  Hakumai
//
//  Created by Hiroyuki Onishi on 1/6/15.
//  Copyright (c) 2015 Hiroyuki Onishi. All rights reserved.
//

import Foundation
import XCGLogger

// logger for class methods
private let log = XCGLogger.defaultInstance()

class KeychainUtility {
    // MARK: - Public Functions
    class func removeAllAccountsInKeychain() {
        let serviceName = KeychainUtility.keychainServiceName()
        
        if let accounts = SSKeychain.accountsForService(serviceName) {
            for account in accounts {
                if let accountName = (account as? NSDictionary)?[kSSKeychainAccountKey] as? NSString {
                    if SSKeychain.deletePasswordForService(serviceName, account: accountName) == true {
                        log.debug("completed to delete account from keychain:[\(accountName)]")
                    }
                    else {
                        log.error("failed to delete account from keychain:[\(accountName)]")
                    }
                }
            }
        }
    }
    
    class func setAccountToKeychainWith(mailAddress: String, password: String) {
        let serviceName = KeychainUtility.keychainServiceName()
        
        if SSKeychain.setPassword(password, forService: serviceName, account: mailAddress) == true {
            log.debug("completed to set account into keychain:[\(mailAddress)]")
        }
        else {
            log.error("failed to set account into keychain:[\(mailAddress)]")
        }
    }
    
    class func accountInKeychain() -> (mailAddress: String, password: String)? {
        let serviceName = KeychainUtility.keychainServiceName()
        
        if let accounts = SSKeychain.accountsForService(serviceName) {
            let accountName = (accounts.last as? NSDictionary)?[kSSKeychainAccountKey] as? NSString
            if accountName == nil {
                return nil
            }
            
            let password = SSKeychain.passwordForService(serviceName, account: accountName)
            if password == nil {
                return nil
            }
            
            log.debug("found account in keychain:[\(accountName!)]")
            return (accountName!, password!)
        }
        
        log.debug("found no account in keychain")
        return nil
    }
    
    class func keychainServiceName() -> String {
        var bundleIdentifier = ""
        if let bi = NSBundle.mainBundle().infoDictionary?["CFBundleIdentifier"] as? String {
            bundleIdentifier = bi
        }
        
        return bundleIdentifier + ".account"
    }
}