//
//  NicoUtility.swift
//  Hakumai
//
//  Created by Hiroyuki Onishi on 11/10/14.
//  Copyright (c) 2014 Hiroyuki Onishi. All rights reserved.
//

import Foundation
import XCGLogger

// MARK: protocol

// note these functions are called in background thread, not main thread.
// so use explicit main thread for updating ui in these callbacks.
protocol NicoUtilityProtocol {
    func nicoUtilityDidPrepareLive(nicoUtility: NicoUtility, user: User, live: Live)
    func nicoUtilityDidStartListening(nicoUtility: NicoUtility, roomPosition: RoomPosition)
    func nicoUtilityDidReceiveFirstChat(nicoUtility: NicoUtility, chat: Chat)
    func nicoUtilityDidReceiveChat(nicoUtility: NicoUtility, chat: Chat)
    func nicoUtilityDidFinishListening(nicoUtility: NicoUtility)
    func nicoUtilityDidReceiveHeartbeat(nicoUtility: NicoUtility, heartbeat: Heartbeat)
}

// MARK: constant value

private let kRequiredCommunityLevelForStandRoom: [RoomPosition: Int] = [
    .Arena: 0,
    .StandA: 0,
    .StandB: 66,
    .StandC: 70,
    .StandD: 105,
    .StandE: 150,
    .StandF: 190,
    .StandG: 232]

// urls for api
private let kGetPlayerStatusUrl = "http://watch.live.nicovideo.jp/api/getplayerstatus"
private let kGetPostKeyUrl = "http://live.nicovideo.jp/api/getpostkey"
private let kHeartbeatUrl = "http://live.nicovideo.jp/api/heartbeat"
private let kNgScoringUrl:String = "http://watch.live.nicovideo.jp/api/ngscoring"

// urls for scraping
private let kCommunityUrl = "http://com.nicovideo.jp/community/"
private let kUserUrl = "http://www.nicovideo.jp/user/"

// request header
private let kUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_10_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/39.0.2171.71 Safari/537.36"

// intervals
private let kHeartbeatDefaultInterval: NSTimeInterval = 30

// MARK: class

class NicoUtility : NSObject, RoomListenerDelegate {
    var delegate: NicoUtilityProtocol?
    
    var live: Live?
    var user: User?
    var messageServer: MessageServer?
    
    var messageServers: [MessageServer] = []
    var roomListeners: [RoomListener] = []
    var receivedFirstChat = [RoomPosition: Bool]()
    
    var cachedUsernames = [String: String]()
    
    var heartbeatTimer: NSTimer?
    
    let log = XCGLogger.defaultInstance()
    let fileLog = XCGLogger()

    // MARK: - Object Lifecycle
    private override init() {
        super.init()
        
        self.initializeFileLog()
    }
    
    class var sharedInstance : NicoUtility {
        struct Static {
            static let instance : NicoUtility = NicoUtility()
        }
        return Static.instance
    }
    
    func initializeFileLog() {
        let fileLogPath = NSHomeDirectory() + "/Hakumai.log"
        fileLog.setup(logLevel: .Verbose, showLogLevel: true, showFileNames: true, showLineNumbers: true, writeToFile: fileLogPath)
        
        if let console = fileLog.logDestination(XCGLogger.constants.baseConsoleLogDestinationIdentifier) {
            fileLog.removeLogDestination(console)
        }
    }

    // MARK: - Public Interface
    func connect(live: Int) {
        if 0 < self.roomListeners.count {
            self.disconnect()
        }
        
        func completion(live: Live?, user: User?, server: MessageServer?) {
            self.log.debug("extracted live: \(live)")
            self.log.debug("extracted server: \(server)")
            
            if live == nil || server == nil {
                self.log.error("could not extract live information.")
                return
            }
            
            self.live = live
            self.user = user
            self.messageServer = server
            
            self.loadCommunity(self.live!.community, completion: { (isSuccess) -> Void in
                self.log.debug("loaded community info: success?:\(isSuccess) community:\(self.live!.community)")
                
                if !isSuccess {
                    self.log.error("error in loading community info")
                    return
                }
                
                if self.user != nil && self.live != nil {
                    self.delegate?.nicoUtilityDidPrepareLive(self, user: self.user!, live: self.live!)
                }
                
                self.openMessageServers(server!)
                
                self.scheduleHeartbeatTimer(immediateFire: true)
            })
        }
        
        self.getPlayerStatus(live, completion: completion)
    }
    
    func disconnect() {
        for listener in self.roomListeners {
            listener.closeSocket()
        }
        
        self.stopHeartbeatTimer()
        
        self.delegate?.nicoUtilityDidFinishListening(self)
        
        self.reset()
    }
    
    func comment(comment: String, anonymously: Bool = true) {
        self.getPostKey { (postKey) -> (Void) in
            if self.live == nil || self.user == nil || postKey == nil {
                self.log.debug("no available stream, user, or post key")
                return
            }
            
            let roomListener = self.roomListeners[self.messageServer!.roomPosition.rawValue]
            roomListener.comment(self.live!, user: self.user!, postKey: postKey!, comment: comment, anonymously: anonymously)
        }
    }
    
    func loadThumbnail(completion: (imageData: NSData?) -> (Void)) {
        if self.live?.community.thumbnailUrl == nil {
            log.debug("no thumbnail url")
            completion(imageData: nil)
            return
        }
        
        func httpCompletion (response: NSURLResponse!, data: NSData!, connectionError: NSError!) {
            if connectionError != nil {
                log.error("error in loading thumbnail request")
                completion(imageData: nil)
                return
            }
            
            completion(imageData: data)
        }
        
        self.cookiedAsyncRequest("GET", url: self.live!.community.thumbnailUrl!, parameters: nil, completion: httpCompletion)
    }
    
    func resolveUsername(userId: String, completion: (userName: String?) -> (Void)) {
        if !self.isRawUserId(userId) {
            completion(userName: nil)
            return
        }
        
        if let cachedUsername = self.cachedUsernames[userId] {
            completion(userName: cachedUsername)
            return
        }
        
        func httpCompletion (response: NSURLResponse!, data: NSData!, connectionError: NSError!) {
            if connectionError != nil {
                log.error("error in resolving username")
                completion(userName: nil)
                return
            }
            
            let username = self.extractUsername(data)
            self.cachedUsernames[userId] = username
            
            completion(userName: username)
        }
        
        self.cookiedAsyncRequest("GET", url: kUserUrl + String(userId), parameters: nil, completion: httpCompletion)
    }
    
    func reportAsNgUser(chat: Chat) {
        func httpCompletion (response: NSURLResponse!, data: NSData!, connectionError: NSError!) {
            if connectionError != nil {
                log.error("error in requesting ng user")
                // TODO: error completion?
                return
            }
            
            log.debug("completed to request ng user")
            
            // TODO: success completion?
        }
        
        let parameters: [String: Any] = [
            "vid": self.live!.liveId!,
            "lang": "ja-jp",
            "type": "ID",
            "locale": "GLOBAL",
            "value": chat.userId!,
            "player": "v4",
            "uid": chat.userId!,
            "tpos": String(Int(chat.date!.timeIntervalSince1970)) + "." + String(chat.dateUsec!),
            "comment": String(chat.no!),
            "thread": String(self.messageServers[chat.roomPosition!.rawValue].thread),
            "comment_locale": "ja-jp"
        ]
        
        self.cookiedAsyncRequest("POST", url: kNgScoringUrl, parameters: parameters, completion: httpCompletion)
    }
    
    func urlStringForUserId(userId: String) -> String {
        return kUserUrl + userId
    }
    
    // MARK: - Message Server Functions
    private func openMessageServers(originServer: MessageServer) {
        self.messageServers = self.deriveMessageServers(originServer)
        
        // opens arena only
        self.addMessageServer()
    }
    
    private func addMessageServer() {
        if self.roomListeners.count == self.messageServers.count {
            log.info("already opened max servers.")
            return
        }
        
        if let lastRoomListener = self.roomListeners.last {
            if let lastRoomPosition = lastRoomListener.server?.roomPosition {
                if let level = self.live?.community.level {
                    if !self.canOpenRoomPosition(lastRoomPosition.next()!, communityLevel: level) {
                        log.info("already opened max servers with this community level \(level)")
                        return
                    }
                }
            }
        }
        
        let targetServerIndex = self.roomListeners.count
        let targetServer = self.messageServers[targetServerIndex]
        let listener = RoomListener(delegate: self, server: targetServer)
        
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), {
            listener.openSocket()
        })
        
        self.roomListeners.append(listener)
    }
    
    func canOpenRoomPosition(roomPosition: RoomPosition, communityLevel: Int) -> Bool {
        let requiredCommunityLevel = kRequiredCommunityLevelForStandRoom[roomPosition]
        return (requiredCommunityLevel <= communityLevel)
    }
    
    private func getPlayerStatus(live: Int, completion: (live: Live?, user: User?, messageServer: MessageServer?) -> (Void)) {
        func httpCompletion (response: NSURLResponse!, data: NSData!, connectionError: NSError!) {
            if connectionError != nil {
                log.error("error in cookied async request")
                completion(live: nil, user: nil, messageServer: nil)
                return
            }
            
            let responseString = NSString(data: data, encoding: NSUTF8StringEncoding)
            // log.debug("\(responseString)")
            
            if data == nil {
                log.error("error in unpacking response data")
                completion(live: nil, user: nil, messageServer: nil)
                return
            }
            
            if self.isErrorResponse(data) {
                log.error("detected error")
                completion(live: nil, user: nil, messageServer: nil)
                return
            }
            
            let live = self.extractLive(data)
            let user = self.extractUser(data)
            
            var messageServer: MessageServer?
            if user != nil {
                messageServer = self.extractMessageServer(data, user: user!)
            }
            
            if live == nil || user == nil || messageServer == nil {
                log.error("error in extracting getplayerstatus response")
                completion(live: nil, user: nil, messageServer: nil)
                return
            }

            completion(live: live, user: user, messageServer: messageServer)
        }

        self.cookiedAsyncRequest("GET", url: kGetPlayerStatusUrl, parameters: ["v": "lv" + String(live)], completion: httpCompletion)
    }
    
    // MARK: - General Extractor
    private func isErrorResponse(xmlData: NSData) -> Bool {
        var err: NSError?
        let xmlDocument = NSXMLDocument(data: xmlData, options: kNilOptions, error: &err)
        let rootElement = xmlDocument?.rootElement()
        
        let status = rootElement?.attributeForName("status")?.stringValue
        
        if status == "fail" {
            log.warning("failed to load message server")
            
            if let errorCode = rootElement?.firstStringValueForXPathNode("/getplayerstatus/error/code") {
                log.warning("error code: \(errorCode)")
            }
            
            return true
        }
        
        return false
    }
    
    // MARK: - Stream Extractor
    func extractLive(xmlData: NSData) -> Live? {
        var err: NSError?
        let xmlDocument = NSXMLDocument(data: xmlData, options: kNilOptions, error: &err)
        let rootElement = xmlDocument?.rootElement()
        
        let live = Live()
        let baseXPath = "/getplayerstatus/stream/"
        
        live.liveId = rootElement?.firstStringValueForXPathNode(baseXPath + "id")
        live.title = rootElement?.firstStringValueForXPathNode(baseXPath + "title")
        live.community.community = rootElement?.firstStringValueForXPathNode(baseXPath + "default_community")
        live.baseTime = rootElement?.firstIntValueForXPathNode(baseXPath + "base_time")?.toDateAsTimeIntervalSince1970()
        live.openTime = rootElement?.firstIntValueForXPathNode(baseXPath + "open_time")?.toDateAsTimeIntervalSince1970()
        live.startTime = rootElement?.firstIntValueForXPathNode(baseXPath + "start_time")?.toDateAsTimeIntervalSince1970()
        
        return live
    }
    
    private func loadCommunity(community: Community, completion: ((Bool) -> Void)) {
        func httpCompletion (response: NSURLResponse!, data: NSData!, connectionError: NSError!) {
            if connectionError != nil {
                log.error("error in cookied async request")
                completion(false)
                return
            }
            
            let responseString = NSString(data: data, encoding: NSUTF8StringEncoding)
            // log.debug("\(responseString)")
            
            if data == nil {
                log.error("error in unpacking response data")
                completion(false)
                return
            }
            
            self.extractCommunity(data, community: community)
            
            completion(true)
        }
        
        self.cookiedAsyncRequest("GET", url: kCommunityUrl + community.community!, parameters: nil, completion: httpCompletion)
    }
    
    func extractCommunity(xmlData: NSData, community: Community) {
        var err: NSError?
        let xmlDocument = NSXMLDocument(data: xmlData, options: Int(NSXMLDocumentTidyHTML), error: &err)
        let rootElement = xmlDocument?.rootElement()
        
        if rootElement == nil {
            log.error("rootElement is nil")
            return
        }

        let xpathTitle = "//*[@id=\"community_name\"]"
        community.title = rootElement?.firstStringValueForXPathNode(xpathTitle)?.stringByRemovingPattern("\n")
        
        let xpathLevel = "//*[@id=\"cbox_profile\"]/table/tr/td[1]/table/tr[1]/td[2]/strong[1]"
        community.level = rootElement?.firstIntValueForXPathNode(xpathLevel)
        
        let xpathThumbnailUrl = "//*[@id=\"cbox_profile\"]/table/tr/td[2]/p/img/@src"
        if let thumbnailUrl = rootElement?.firstStringValueForXPathNode(xpathThumbnailUrl) {
            community.thumbnailUrl = NSURL(string: thumbnailUrl)
        }
    }
    
    // MARK: - Message Server Extractor
    private func extractMessageServer (xmlData: NSData, user: User) -> MessageServer? {
        var err: NSError?
        let xmlDocument = NSXMLDocument(data: xmlData, options: kNilOptions, error: &err)
        let rootElement = xmlDocument?.rootElement()
        
        let status = rootElement?.attributeForName("status")?.stringValue
        
        if status == "fail" {
            log.warning("failed to load message server")
            
            if let errorCode = rootElement?.firstStringValueForXPathNode("/getplayerstatus/error/code") {
                log.warning("error code: \(errorCode)")
            }
            
            return nil
        }

        if user.roomLabel == nil {
            return nil
        }
        
        let roomPosition = self.roomPositionByRoomLabel(user.roomLabel!)
        
        if roomPosition == nil {
            return nil
        }
        
        let baseXPath = "/getplayerstatus/ms/"

        let address = rootElement?.firstStringValueForXPathNode(baseXPath + "addr")
        let port = rootElement?.firstIntValueForXPathNode(baseXPath + "port")
        let thread = rootElement?.firstIntValueForXPathNode(baseXPath + "thread")
        // log.debug("\(address?),\(port),\(thread)")
 
        if address == nil || port == nil || thread == nil {
            return nil
        }

        let server = MessageServer(roomPosition: roomPosition!, address: address!, port: port!, thread: thread!)
        
        return server
    }
    
    func roomPositionByRoomLabel(roomLabel: String) -> RoomPosition? {
        // log.debug("roomLabel:\(roomLabel)")
        
        if self.isArena(roomLabel) == true {
            return RoomPosition(rawValue: 0)
        }
        
        if let standCharacter = self.extractStandCharacter(roomLabel) {
            log.debug("extracted standCharacter:\(standCharacter)")
            let raw = (standCharacter - ("A" as Character)) + 1
            return RoomPosition(rawValue: raw)
        }
        
        return nil
    }
    
    private func isArena(roomLabel: String) -> Bool {
        let regexp = NSRegularExpression(pattern: "co\\d+", options: nil, error: nil)!
        let matched = regexp.firstMatchInString(roomLabel, options: nil, range: NSMakeRange(0, roomLabel.utf16Count))
        
        return matched != nil ? true : false
    }
    
    private func extractStandCharacter(roomLabel: String) -> Character? {
        let matched = roomLabel.extractRegexpPattern("立ち見(\\w)列")
        
        // using subscript String extension defined above
        return matched?[0]
    }

    // MARK: Message Server Utility
    func deriveMessageServers(originServer: MessageServer) -> [MessageServer] {
        if originServer.isOfficial() == true {
            // TODO: not yet supported
            return [originServer]
        }
        
        var arenaServer = originServer
        
        if 0 < originServer.roomPosition.rawValue {
            for _ in 1...(originServer.roomPosition.rawValue) {
                arenaServer = arenaServer.previous()
            }
        }
        
        var servers = [arenaServer]
        
        // add stand a, b, c, d, e, f
        for _ in 1...6 {
            servers.append(servers.last!.next())
        }
        
        return servers
    }
    
    func deriveMessageServer(originServer: MessageServer, distance: Int) -> MessageServer? {
        if originServer.isOfficial() == true {
            // TODO: not yet supported
            return nil
        }
        
        if distance == 0 {
            return originServer
        }
        
        var server = originServer
        
        if 0 < distance {
            for _ in 1...distance {
                server = server.next()
            }
        }
        else {
            for _ in 1...abs(distance) {
                server = server.previous()
            }
        }
        
        return server
    }
    
    // MARK: - User Extractor
    private func extractUser(xmlData: NSData) -> User? {
        var err: NSError?
        let xmlDocument = NSXMLDocument(data: xmlData, options: kNilOptions, error: &err)
        let rootElement = xmlDocument?.rootElement()
        
        let user = User()
        let baseXPath = "/getplayerstatus/user/"
        
        user.userId = rootElement?.firstIntValueForXPathNode(baseXPath + "user_id")
        user.nickname = rootElement?.firstStringValueForXPathNode(baseXPath + "nickname")
        user.isPremium = rootElement?.firstIntValueForXPathNode(baseXPath + "is_premium")
        user.roomLabel = rootElement?.firstStringValueForXPathNode(baseXPath + "room_label")
        user.seatNo = rootElement?.firstIntValueForXPathNode(baseXPath + "room_seetno")
        
        return user
    }
    
    // MARK: - Comment
    private func getPostKey(completion: (postKey: String?) -> (Void)) {
        if messageServer == nil {
            log.error("cannot comment without messageServer")
            completion(postKey: nil)
            return
        }
        
        func httpCompletion (response: NSURLResponse!, data: NSData!, connectionError: NSError!) {
            if connectionError != nil {
                log.error("error in cookied async request")
                completion(postKey: nil)
                return
            }
            
            let responseString = NSString(data: data, encoding: NSUTF8StringEncoding)
            log.debug("\(responseString)")
            
            if data == nil {
                log.error("error in unpacking response data")
                completion(postKey: nil)
                return
            }
            
            let postKey = (responseString as String).extractRegexpPattern("postkey=(.+)")
            
            if postKey == nil {
                log.error("error in extracting postkey")
                completion(postKey: nil)
                return
            }
            
            completion(postKey: postKey)
        }
        
        let thread = messageServer!.thread
        let blockNo = (roomListeners[messageServer!.roomPosition.rawValue].lastRes + 1) / 100
        
        self.cookiedAsyncRequest("GET", url: kGetPostKeyUrl, parameters: ["thread": thread, "block_no": blockNo], completion: httpCompletion)
    }
    
    // MARK: - Username
    func extractUsername(xmlData: NSData) -> String? {
        var err: NSError?
        let xmlDocument = NSXMLDocument(data: xmlData, options: Int(NSXMLDocumentTidyHTML), error: &err)
        let rootElement = xmlDocument?.rootElement()
        
        // /html/body/div[3]/div[2]/h2/text() -> other's userpage
        // /html/body/div[4]/div[2]/h2/text() -> my userpage, contains '他のユーザーから見たあなたのプロフィールです。' box
        let username = rootElement?.firstStringValueForXPathNode("/html/body/*/div[2]/h2")
        let cleansed = username?.stringByRemovingPattern("(?:さん|)\n$")
        
        return cleansed
    }
    
    func isRawUserId(userId: String) -> Bool {
        let regexp = NSRegularExpression(pattern: "^\\d+$", options: nil, error: nil)!
        let matched = regexp.firstMatchInString(userId, options: nil, range: NSMakeRange(0, userId.utf16Count))
        
        return matched != nil ? true : false
    }
    
    // MARK: - Heartbeat
    func checkHeartbeat(timer: NSTimer) {
        func httpCompletion (response: NSURLResponse!, data: NSData!, connectionError: NSError!) {
            if connectionError != nil {
                log.error("error in checking heartbeat")
                return
            }
            
            let responseString = NSString(data: data, encoding: NSUTF8StringEncoding)
            fileLog.debug("\(responseString)")
            
            let heartbeat = self.extractHeartbeat(data)
            fileLog.debug("\(heartbeat)")
            
            if heartbeat == nil {
                log.error("error in extracting heatbeat")
                return
            }
            
            self.delegate?.nicoUtilityDidReceiveHeartbeat(self, heartbeat: heartbeat!)
            
            if let interval = heartbeat?.waitTime {
                self.stopHeartbeatTimer()
                self.scheduleHeartbeatTimer(immediateFire: false, interval: NSTimeInterval(interval))
            }
        }
        
        let liveId = self.live!.liveId!
        self.cookiedAsyncRequest("GET", url: kHeartbeatUrl, parameters: ["v": liveId], completion: httpCompletion)
    }
    
    func extractHeartbeat(xmlData: NSData) -> Heartbeat? {
        var err: NSError?
        let xmlDocument = NSXMLDocument(data: xmlData, options: kNilOptions, error: &err)
        let rootElement = xmlDocument?.rootElement()
        
        let heartbeat = Heartbeat()
        let baseXPath = "/heartbeat/"
        
        if let status = rootElement?.firstStringValueForXPathNode(baseXPath + "@status") {
            heartbeat.status = Heartbeat.statusFromString(status: status)
        }
        
        if heartbeat.status == Heartbeat.Status.Ok {
            heartbeat.watchCount = rootElement?.firstIntValueForXPathNode(baseXPath + "watchCount")
            heartbeat.commentCount = rootElement?.firstIntValueForXPathNode(baseXPath + "commentCount")
            heartbeat.freeSlotNum = rootElement?.firstIntValueForXPathNode(baseXPath + "freeSlotNum")
            heartbeat.isRestrict = rootElement?.firstIntValueForXPathNode(baseXPath + "is_restrict")
            heartbeat.ticket = rootElement?.firstStringValueForXPathNode(baseXPath + "ticket")
            heartbeat.waitTime = rootElement?.firstIntValueForXPathNode(baseXPath + "waitTime")
        }
        else if heartbeat.status == Heartbeat.Status.Fail {
            if let errorCode = rootElement?.firstStringValueForXPathNode(baseXPath + "error/code") {
                heartbeat.errorCode = Heartbeat.errorCodeFromString(errorCode: errorCode)
            }
        }
        
        return heartbeat
    }
    
    private func scheduleHeartbeatTimer(immediateFire: Bool = false, interval: NSTimeInterval = kHeartbeatDefaultInterval) {
        self.stopHeartbeatTimer()
        
        dispatch_async(dispatch_get_main_queue(), {
            self.heartbeatTimer = NSTimer.scheduledTimerWithTimeInterval(interval, target: self, selector: "checkHeartbeat:", userInfo: nil, repeats: true)
            if immediateFire {
                self.heartbeatTimer?.fire()
            }
        })
    }
    
    private func stopHeartbeatTimer() {
        if self.heartbeatTimer == nil {
            return
        }
        
        self.heartbeatTimer?.invalidate()
        self.heartbeatTimer = nil
    }
    
    // MARK: - Internal Http Utility
    private func cookiedAsyncRequest(httpMethod: String, url: NSURL, parameters: [String: Any]?, completion: (NSURLResponse!, NSData!, NSError!) -> Void) {
        self.cookiedAsyncRequest(httpMethod, url: url.absoluteString!, parameters: parameters, completion: completion)
    }
    
    private func cookiedAsyncRequest(httpMethod: String, url: String, parameters: [String: Any]?, completion: (NSURLResponse!, NSData!, NSError!) -> Void) {
        var parameteredUrl: String = url
        let constructedParameters = self.constructParameters(parameters)
        
        if httpMethod == "GET" && constructedParameters != nil {
            parameteredUrl += "?" + constructedParameters!
        }
        
        var request = self.mutableRequestWithCustomHeaders(parameteredUrl)
        request.HTTPMethod = httpMethod
        
        if httpMethod == "POST" && constructedParameters != nil {
            request.HTTPBody = constructedParameters!.dataUsingEncoding(NSUTF8StringEncoding)
        }
        
        if let cookie = self.sessionCookie() {
            let requestHeader = NSHTTPCookie.requestHeaderFieldsWithCookies([cookie])
            request.allHTTPHeaderFields = requestHeader
        }
        else {
            log.error("could not get cookie")
            completion(nil, nil, NSError(domain:"", code:0, userInfo: nil))
        }
        
        let queue = NSOperationQueue()
        NSURLConnection.sendAsynchronousRequest(request, queue: queue, completionHandler: completion)
    }
    
    func constructParameters(parameters: [String: Any]?) -> String? {
        if parameters == nil {
            return nil
        }
        
        var constructed: NSString = ""
        
        for (key, value) in parameters! {
            if 0 < constructed.length {
                constructed = constructed + "&"
            }
            
            constructed = constructed + "\(key)=\(value)"
        }
        
        // use custom escape character sets instead of NSCharacterSet.URLQueryAllowedCharacterSet()
        // cause we need to escape strings like this: tpos=1416842780%2E802121&comment%5Flocale=ja%2Djp
        var allowed = NSMutableCharacterSet.alphanumericCharacterSet()
        allowed.addCharactersInString("?=&")
        
        return constructed.stringByAddingPercentEncodingWithAllowedCharacters(allowed)
    }
    
    private func mutableRequestWithCustomHeaders(url: String) -> NSMutableURLRequest {
        let urlObject = NSURL(string: url)!
        var mutableRequest = NSMutableURLRequest(URL: urlObject)

        mutableRequest.setValue(kUserAgent, forHTTPHeaderField: "User-Agent")
        
        return mutableRequest
    }
    
    private func sessionCookie() -> NSHTTPCookie? {
        if let cookie = CookieUtility.cookie(CookieUtility.BrowserType.Chrome) {
            // log.debug("cookie:[\(cookie)]")
            
            let userSessionCookie = NSHTTPCookie(properties: [
                NSHTTPCookieDomain: "nicovideo.jp",
                NSHTTPCookieName: "user_session",
                NSHTTPCookieValue: cookie,
                NSHTTPCookieExpires: NSDate().dateByAddingTimeInterval(7200),
                NSHTTPCookiePath: "/"])
            
            return userSessionCookie
        }
        
        return nil
    }
    
    // MARK: - Misc Utility
    func reset() {
        self.live = nil
        self.user = nil
        self.messageServer = nil
        
        self.messageServers.removeAll(keepCapacity: false)
        self.roomListeners.removeAll(keepCapacity: false)
        self.receivedFirstChat.removeAll(keepCapacity: false)
    }

    // MARK: - RoomListenerDelegate Functions
    func roomListenerDidReceiveThread(roomListener: RoomListener, thread: Thread) {
        log.debug("\(thread)")
        self.delegate?.nicoUtilityDidStartListening(self, roomPosition: roomListener.server!.roomPosition)
    }
    
    func roomListenerDidReceiveChat(roomListener: RoomListener, chat: Chat) {
        // open next room, if first comment in the room received
        if chat.premium == .Ippan || chat.premium == .Premium {
            if let room = roomListener.server?.roomPosition {
                if self.receivedFirstChat[room] == nil || self.receivedFirstChat[room] == false {
                    self.receivedFirstChat[room] = true
                    self.addMessageServer()
                    
                    self.delegate?.nicoUtilityDidReceiveFirstChat(self, chat: chat)
                }
            }
        }
        
        self.delegate?.nicoUtilityDidReceiveChat(self, chat: chat)
        
        if (chat.comment == "/disconnect" && (chat.premium == .Caster || chat.premium == .System) &&
            chat.roomPosition == .Arena) {
            self.disconnect()
        }
    }
}