//
//  LoginCookie.swift
//  Hakumai
//
//  Created by Hiroyuki Onishi on 1/6/15.
//  Copyright (c) 2015 Hiroyuki Onishi. All rights reserved.
//

import Foundation

private let kNicoVideoDomain = "http://nicovideo.jp"
private let kLoginUrl = "https://secure.nicovideo.jp/secure/login?site=niconico"

// request header
private let kUserAgent = kCommonUserAgent

class LoginCookie {
    // MARK: - Public Functions
    static func requestCookie(mailAddress: String, password: String, completion: @escaping (_ userSessionCookie: String?) -> Void) {
        func httpCompletion(_ response: URLResponse?, _ data: Data?, _ connectionError: Error?) {
            if connectionError != nil {
                logger.error("login failed. connection error:[\(connectionError)]")
                completion(nil)
                return
            }
            
            let httpResponse = response as! HTTPURLResponse
            if httpResponse.statusCode != 200 {
                logger.error("login failed. got unexpected status code::[\(httpResponse.statusCode)]")
                completion(nil)
                return
            }

            let userSessionCookie = LoginCookie.findUserSessionCookie()
            logger.debug("found session cookie:[\(userSessionCookie)]")
            
            if userSessionCookie == nil {
                completion(nil)
                return
            }
            
            completion(userSessionCookie!)
        }
        
        LoginCookie.removeAllStoredCookie()
        
        let parameters = "mail=\(mailAddress)&password=\(password)"
        
        let request = NSMutableURLRequest(url: URL(string: kLoginUrl)!)
        request.setValue(kUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpMethod = "POST"
        request.httpBody = parameters.data(using: String.Encoding.utf8)

        let queue = OperationQueue()
        NSURLConnection.sendAsynchronousRequest(request as URLRequest, queue: queue, completionHandler: httpCompletion)
    }
    
    // MARK: - Internal Functions
    private static func removeAllStoredCookie() {
        let cookieStorage = HTTPCookieStorage.shared
        let cookies = cookieStorage.cookies(for: URL(string: kNicoVideoDomain)!)
        
        if cookies == nil {
            return
        }
        
        for cookie in cookies! {
            cookieStorage.deleteCookie((cookie ))
        }
    }
    
    private static func findUserSessionCookie() -> String? {
        let cookieStorage = HTTPCookieStorage.shared
        let cookies = cookieStorage.cookies(for: URL(string: kNicoVideoDomain)!)
        
        if cookies == nil {
            return nil
        }
        
        for cookie in cookies! {
            let castedCookie = (cookie )
            if castedCookie.name == "user_session" {
                return castedCookie.value
            }
        }
        
        return nil
    }
}
