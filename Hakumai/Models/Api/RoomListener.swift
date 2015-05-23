//
//  RoomListener.swift
//  Hakumai
//
//  Created by Hiroyuki Onishi on 11/16/14.
//  Copyright (c) 2014 Hiroyuki Onishi. All rights reserved.
//

import Foundation
import XCGLogger

private let kReadBufferSize = 102400

// MARK: protocol

protocol RoomListenerDelegate: class {
    func roomListenerDidReceiveThread(roomListener: RoomListener, thread: Thread)
    func roomListenerDidReceiveChat(roomListener: RoomListener, chat: Chat)
    func roomListenerDidFinishListening(roomListener: RoomListener)
}

// MARK: main

class RoomListener : NSObject, NSStreamDelegate {
    weak var delegate: RoomListenerDelegate?
    let server: MessageServer?
    
    var runLoop: NSRunLoop!
    
    var inputStream: NSInputStream?
    var outputStream: NSOutputStream?
    var pingTimer: NSTimer?
    
    var parsingString: NSString = ""
    
    var thread: Thread?
    var startDate: NSDate?
    var lastRes: Int = 0
    var internalNo: Int = 0
    
    let log = XCGLogger.defaultInstance()
    let fileLog = XCGLogger()
    
    init(delegate: RoomListenerDelegate?, server: MessageServer?) {
        self.delegate = delegate
        self.server = server
        
        super.init()
        
        self.initializeFileLog()
        log.info("listener initialized for message server:\(self.server)")
    }
    
    deinit {
        log.debug("")
    }
    
    func initializeFileLog() {
        var logNumber = 0
        if let server = self.server {
            logNumber = server.roomPosition.rawValue
        }
        
        ApiHelper.setupFileLog(fileLog, fileName: "Hakumai_\(logNumber).log")
    }
    
    // MARK: - Public Functions
    func openSocket(resFrom: Int = 0) {
        let server = self.server!
        
        var input :NSInputStream?
        var output :NSOutputStream?
        
        NSStream.getStreamsToHostWithName(server.address, port: server.port, inputStream: &input, outputStream: &output)
        
        if input == nil || output == nil {
            fileLog.error("failed to open socket.")
            return
        }
        
        self.inputStream = input
        self.outputStream = output
        
        self.inputStream?.delegate = self
        self.outputStream?.delegate = self
        
        self.runLoop = NSRunLoop.currentRunLoop()
        
        self.inputStream?.scheduleInRunLoop(self.runLoop, forMode: NSDefaultRunLoopMode)
        self.outputStream?.scheduleInRunLoop(self.runLoop, forMode: NSDefaultRunLoopMode)
        
        self.inputStream?.open()
        self.outputStream?.open()
        
        let message = "<thread thread=\"\(server.thread)\" res_from=\"-\(resFrom)\" version=\"20061206\"/>"
        self.sendMessage(message)
        
        self.startPingTimer()

        while self.inputStream != nil {
            self.runLoop.runUntilDate(NSDate(timeIntervalSinceNow: NSTimeInterval(1)))
        }
        
        self.delegate?.roomListenerDidFinishListening(self)
    }
    
    func closeSocket() {
        fileLog.debug("closed streams.")
        
        self.stopPingTimer()

        self.inputStream?.delegate = nil
        self.outputStream?.delegate = nil
        
        self.inputStream?.close()
        self.outputStream?.close()
        
        self.inputStream?.removeFromRunLoop(self.runLoop, forMode: NSDefaultRunLoopMode)
        self.outputStream?.removeFromRunLoop(self.runLoop, forMode: NSDefaultRunLoopMode)
        
        self.inputStream = nil
        self.outputStream = nil
    }
    
    func comment(live: Live, user: User, postKey: String, comment: String, anonymously: Bool) {
        if self.thread == nil {
            log.debug("could not get thread information")
            return
        }
        
        let thread = self.thread!.thread!
        let ticket = self.thread!.ticket!
        let originTime = Int(self.thread!.serverTime!.timeIntervalSince1970) - Int(live.baseTime!.timeIntervalSince1970)
        let elapsedTime = Int(NSDate().timeIntervalSince1970) - Int(self.startDate!.timeIntervalSince1970)
        let vpos = (originTime + elapsedTime) * 100
        let mail = anonymously ? "184" : ""
        let userId = user.userId!
        let premium = user.isPremium!
        
        let message = "<chat thread=\"\(thread)\" ticket=\"\(ticket)\" vpos=\"\(vpos)\" postkey=\"\(postKey)\" mail=\"\(mail)\" user_id=\"\(userId)\" premium=\"\(premium)\">\(comment)</chat>"
        
        self.sendMessage(message)
    }
    
    func sendMessage(message: String) {
        let data: NSData = (message + "\0").dataUsingEncoding(NSUTF8StringEncoding)!
        self.outputStream?.write(UnsafePointer<UInt8>(data.bytes), maxLength: data.length)
        
        log.debug(message)
    }
    
    // MARK: - NSStreamDelegate Functions
    func stream(aStream: NSStream, handleEvent eventCode: NSStreamEvent) {
        switch eventCode {
        case NSStreamEvent.None:
            fileLog.debug("stream event none")
            
        case NSStreamEvent.OpenCompleted:
            fileLog.debug("stream event open completed");
            
        case NSStreamEvent.HasBytesAvailable:
            // fileLog.debug("stream event has bytes available");
            
            // http://stackoverflow.com/q/26360962
            var readByte = [UInt8](count: kReadBufferSize, repeatedValue: 0)
            
            var actualRead = 0
            while self.inputStream?.hasBytesAvailable == true {
                actualRead = self.inputStream!.read(&readByte, maxLength: kReadBufferSize)
                //fileLog.debug(readByte)
                
                if let readString = NSString(bytes: &readByte, length: actualRead, encoding: NSUTF8StringEncoding) {
                    fileLog.debug("read: [ " + (readString as! String) + " ]")
                    
                    self.parsingString = self.parsingString as! String + self.streamByRemovingNull(readString as! String)
                    
                    if !self.hasValidCloseBracket(self.parsingString as! String) {
                        fileLog.warning("detected no-close-bracket stream, continue reading...")
                        continue
                    }
                    
                    if !self.hasValidOpenBracket(self.parsingString as! String) {
                        fileLog.warning("detected no-open-bracket stream, clearing buffer and continue reading...")
                        self.parsingString = ""
                        continue
                    }
                    
                    self.parseInputStream(self.parsingString as! String)
                    self.parsingString = ""
                }
            }
            
            
        case NSStreamEvent.HasSpaceAvailable:
            fileLog.debug("stream event has space available");
            
        case NSStreamEvent.ErrorOccurred:
            fileLog.error("stream event error occurred");
            self.closeSocket();
            
        case NSStreamEvent.EndEncountered:
            fileLog.debug("stream event end encountered");
            
        default:
            fileLog.warning("unexpected stream event");
        }
    }

    // MARK: Read Utility
    func streamByRemovingNull(stream: String) -> String {
        let regexp = NSRegularExpression(pattern: "\0", options: nil, error: nil)!
        let removed = regexp.stringByReplacingMatchesInString(stream, options: nil, range: NSMakeRange(0, count(stream.utf16)), withTemplate: "")
        
        return removed
    }
    
    func hasValidOpenBracket(stream: String) -> Bool {
        return self.hasValidPatternInStream("^<", stream: stream)
    }
    
    func hasValidCloseBracket(stream: String) -> Bool {
        return self.hasValidPatternInStream(">$", stream: stream)
    }
    
    func hasValidPatternInStream(pattern: String, stream: String) -> Bool {
        let regexp = NSRegularExpression(pattern: pattern, options: nil, error: nil)!
        let matched = regexp.firstMatchInString(stream, options: nil, range: NSMakeRange(0, count(stream.utf16)))
        
        return matched != nil ? true : false
    }
    
    // MARK: - Parse Utility
    func parseInputStream(stream: String) {
        let wrappedStream = "<items>" + stream + "</items>"
        fileLog.verbose("parsing: [ " + wrappedStream + " ]")
        
        var err: NSError?
        let xmlDocument = NSXMLDocument(XMLString: wrappedStream, options: Int(NSXMLDocumentTidyXML), error: &err)
        
        if xmlDocument == nil {
            fileLog.error("could not parse input stream:\(stream)")
            return
        }
        
        if let rootElement = xmlDocument?.rootElement() {
            // rootElement = '<items>...</item>'

            let threads = self.parseThreadElement(rootElement)
            for thread in threads {
                self.thread = thread
                self.lastRes = thread.lastRes!
                self.startDate = NSDate()
                self.delegate?.roomListenerDidReceiveThread(self, thread: thread)
            }
        
            let chats = self.parseChatElement(rootElement)
            for chat in chats {
                if let chatNo = chat.no {
                    self.lastRes = chatNo
                }
                
                self.delegate?.roomListenerDidReceiveChat(self, chat: chat)
            }
            
            let chatResults = self.parseChatResultElement(rootElement)
            for chatResult in chatResults {
                log.debug("\(chatResult.description)")
            }
        }
    }
    
    func parseThreadElement(rootElement: NSXMLElement) -> [Thread] {
        var threads = [Thread]()
        let threadElements = rootElement.elementsForName("thread")
        
        for threadElement in threadElements {
            let thread = Thread()
            
            thread.resultCode = threadElement.attributeForName("resultcode")?.stringValue?.toInt()
            thread.thread = threadElement.attributeForName("thread")?.stringValue?.toInt()
            
            if let lastRes = threadElement.attributeForName("last_res")?.stringValue?.toInt() {
                thread.lastRes = lastRes
            }
            else {
                thread.lastRes = 0
            }
            
            thread.ticket = threadElement.attributeForName("ticket")?.stringValue
            thread.serverTime = threadElement.attributeForName("server_time")?.stringValue?.toInt()?.toDateAsTimeIntervalSince1970()
            
            threads.append(thread)
        }
        
        return threads
    }
    
    func parseChatElement(rootElement: NSXMLElement) -> [Chat] {
        var chats = [Chat]()
        let chatElements = rootElement.elementsForName("chat")
        
        for chatElement in chatElements {
            let chat = Chat()

            chat.internalNo = self.internalNo++
            chat.roomPosition = self.server?.roomPosition
            
            if let premium = chatElement.attributeForName("premium")?.stringValue?.toInt() {
                chat.premium = Premium(rawValue: premium)
            }
            else {
                // assume no attribute provided as Ippan(0)
                chat.premium = Premium(rawValue: 0)
            }
            
            if let score = chatElement.attributeForName("score")?.stringValue?.toInt() {
                chat.score = score
            }
            else {
                chat.score = 0
            }
            
            chat.no = chatElement.attributeForName("no")?.stringValue?.toInt()
            chat.date = chatElement.attributeForName("date")?.stringValue?.toInt()?.toDateAsTimeIntervalSince1970()
            chat.dateUsec = chatElement.attributeForName("date_usec")?.stringValue?.toInt()
            if let separated = chatElement.attributeForName("mail")?.stringValue?.componentsSeparatedByString(" ") {
                chat.mail = separated
            }
            chat.userId = chatElement.attributeForName("user_id")?.stringValue
            chat.comment = chatElement.stringValue
            
            if chat.no == nil || chat.userId == nil || chat.comment == nil {
                log.warning("skipped invalid chat:[\(chat)]")
                continue
            }
            
            chats.append(chat)
        }
        
        return chats
    }
    
    func parseChatResultElement(rootElement: NSXMLElement) -> [ChatResult] {
        var chatResults = [ChatResult]()
        let chatResultElements = rootElement.elementsForName("chat_result")
        
        for chatResultElement in chatResultElements {
            let chatResult = ChatResult()
            
            if let status = chatResultElement.attributeForName("status")?.stringValue?.toInt() {
                chatResult.status = ChatResult.Status(rawValue: status)
            }
            
            chatResults.append(chatResult)
        }
        
        return chatResults
    }

    // MARK: - Private Functions
    func startPingTimer() {
        self.pingTimer = NSTimer.scheduledTimerWithTimeInterval(
            60, target: self, selector: Selector("sendPing:"), userInfo: nil, repeats: true)
    }

    func stopPingTimer() {
        self.pingTimer?.invalidate()
        self.pingTimer = nil
    }

    func sendPing(timer: NSTimer) {
        sendMessage("<ping>PING</ping>")
    }
}