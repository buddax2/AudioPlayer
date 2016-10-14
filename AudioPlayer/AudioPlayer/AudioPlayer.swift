//
//  AudioPlayer.swift
//  AudioPlayer
//
//  Created by Kevin DELANNOY on 26/04/15.
//  Copyright (c) 2015 Kevin Delannoy. All rights reserved.
//

import UIKit
import MediaPlayer
import AVFoundation
fileprivate func < <T : Comparable>(lhs: T?, rhs: T?) -> Bool {
  switch (lhs, rhs) {
  case let (l?, r?):
    return l < r
  case (nil, _?):
    return true
  default:
    return false
  }
}


private class ClosureContainer: NSObject {
    let closure: (_ sender: AnyObject) -> ()

    init(closure: @escaping (_ sender: AnyObject) -> ()) {
        self.closure = closure
    }

    @objc func callSelectorOnTarget(_ sender: AnyObject) {
        closure(sender)
    }
}

// MARK: - AudioPlayerState

/**
`AudioPlayerState` defines 4 state an `AudioPlayer` instance can be in.

- `Buffering`:            Represents that the player is buffering data before playing them.
- `Playing`:              Represents that the player is playing.
- `Paused`:               Represents that the player is paused.
- `Stopped`:              Represents that the player is stopped.
- `WaitingForConnection`: Represents the state where the player is waiting for internet connection.
*/
public enum AudioPlayerState {
    case buffering
    case playing
    case paused
    case stopped
    case waitingForConnection
}


// MARK: - AudioPlayerMode

public struct AudioPlayerModeMask: OptionSet {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static var Shuffle: AudioPlayerModeMask {
        return self.init(rawValue: 0b001)
    }

    public static var Repeat: AudioPlayerModeMask {
        return self.init(rawValue: 0b010)
    }

    public static var RepeatAll: AudioPlayerModeMask {
        return self.init(rawValue: 0b100)
    }
}


// MARK: - AVPlayer+KVO

private extension AVPlayer {
    static var ap_KVOItems: [String] {
        return [
            "currentItem.playbackBufferEmpty",
            "currentItem.playbackLikelyToKeepUp",
            "currentItem.duration"
        ]
    }
}


// MARK: - NSObject+Observation

private extension NSObject {
    func observe(_ name: String, selector: Selector, object: AnyObject? = nil) {
        NotificationCenter.default.addObserver(self, selector: selector, name: NSNotification.Name(rawValue: name), object: object)
    }

    func unobserve(_ name: String, object: AnyObject? = nil) {
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: name), object: object)
    }
}


// MARK: - Array+Shuffe

private extension Array {
    func shuffled() -> [Element] {
        return sorted { e1, e2 in
            arc4random() % 2 == 0
        }
    }
}


// MARK: - AudioPlayerDelegate

public protocol AudioPlayerDelegate: NSObjectProtocol {
    func audioPlayer(_ audioPlayer: AudioPlayer, didChangeStateFrom from: AudioPlayerState, toState to: AudioPlayerState)
    func audioPlayer(_ audioPlayer: AudioPlayer, willStartPlayingItem item: AudioItem)
    func audioPlayer(_ audioPlayer: AudioPlayer, didUpdateProgressionToTime time: TimeInterval, percentageRead: Float)
    func audioPlayer(_ audioPlayer: AudioPlayer, didFindDuration duration: TimeInterval, forItem item: AudioItem)

}


// MARK: - AudioPlayer

/**
An `AudioPlayer` instance is used to play `AudioPlayerItem`. It's an easy to use
AVPlayer with simple methods to handle the whole playing audio process.

You can get events (such as state change or time observation) by registering a delegate.
*/
open class AudioPlayer: NSObject {
    // MARK: Initialization

    public override init() {
        state = .buffering
        super.init()

        observe(ReachabilityChangedNotification.rawValue, selector: #selector(AudioPlayer.reachabilityStatusChanged(_:)), object: reachability)
        try? reachability?.startNotifier()
    }

    deinit {
        reachability?.stopNotifier()
        unobserve(ReachabilityChangedNotification.rawValue, object: reachability)

        qualityAdjustmentTimer?.invalidate()
        qualityAdjustmentTimer = nil

        retryTimer?.invalidate()
        retryTimer = nil

        stop()

        endBackgroundTask()
    }


    // MARK: Private properties

    /// The audio player.
    fileprivate var player: AVPlayer? {
        didSet {
            //Gotta unobserver & observe if necessary
            for keyPath in AVPlayer.ap_KVOItems {
                oldValue?.removeObserver(self, forKeyPath: keyPath)
                player?.addObserver(self, forKeyPath: keyPath, options: .new, context: nil)
            }

            if let oldValue = oldValue {
                qualityAdjustmentTimer?.invalidate()
                qualityAdjustmentTimer = nil

                if let timeObserver = timeObserver {
                    oldValue.removeTimeObserver(timeObserver)
                }
                timeObserver = nil

                unobserve(NSNotification.Name.AVAudioSessionInterruption.rawValue)
                unobserve(NSNotification.Name.AVAudioSessionRouteChange.rawValue)
                unobserve(NSNotification.Name.AVAudioSessionMediaServicesWereLost.rawValue)
                unobserve(NSNotification.Name.AVAudioSessionMediaServicesWereReset.rawValue)
                unobserve(NSNotification.Name.AVPlayerItemDidPlayToEndTime.rawValue)
            }

            if let player = player {
                //Creating the qualityAdjustment timer
                let target = ClosureContainer(closure: { [weak self] sender in
                    self?.adjustQualityIfNecessary()
                    })
                let timer = Timer(timeInterval: adjustQualityTimeInternal, target: target, selector: #selector(ClosureContainer.callSelectorOnTarget(_:)), userInfo: nil, repeats: false)
                RunLoop.main.add(timer, forMode: RunLoopMode.commonModes)
                qualityAdjustmentTimer = timer

                timeObserver = player.addPeriodicTimeObserver(forInterval: CMTimeMake(1, 2), queue: DispatchQueue.main, using: {[weak self] time in
                    self?.currentProgressionUpdated(time)
                    }) as AnyObject?

                observe(NSNotification.Name.AVAudioSessionInterruption.rawValue, selector: #selector(AudioPlayer.audioSessionGotInterrupted(_:)))
                observe(NSNotification.Name.AVAudioSessionRouteChange.rawValue, selector: #selector(AudioPlayer.audioSessionRouteChanged(_:)))
                observe(NSNotification.Name.AVAudioSessionMediaServicesWereLost.rawValue, selector: #selector(AudioPlayer.audioSessionMessedUp(_:)))
                observe(NSNotification.Name.AVAudioSessionMediaServicesWereReset.rawValue, selector: #selector(AudioPlayer.audioSessionMessedUp(_:)))
                observe(NSNotification.Name.AVPlayerItemDidPlayToEndTime.rawValue, selector: #selector(AudioPlayer.playerItemDidEnd(_:)))
            }
        }
    }

    fileprivate typealias AudioQueueItem = (position: Int, item: AudioItem)

    /// The queue containing items to play.
    fileprivate var enqueuedItems: [AudioQueueItem]?

    /// A boolean value indicating whether the player has been paused because of a system interruption.
    fileprivate var pausedForInterruption = false

    /// The time observer
    fileprivate var timeObserver: AnyObject?

    /// The number of interruption since last quality adjustment/begin playing
    fileprivate var interruptionCount = 0 {
        didSet {
            if adjustQualityAutomatically && interruptionCount > adjustQualityAfterInterruptionCount {
                adjustQualityIfNecessary()
            }
        }
    }

    /// A boolean value indicating if quality is being changed. It's necessary for the interruption count to not be incremented while new quality is buffering.
    fileprivate var qualityIsBeingChanged = false

    /// The current number of retry we already tried
    fileprivate var retryCount = 0

    /// The timer used to cancel a retry and make a new one
    fileprivate var retryTimer: Timer?

    /// The timer used to adjust quality
    fileprivate var qualityAdjustmentTimer: Timer?

    /// The state of the player when the connection was lost
    fileprivate var stateWhenConnectionLost: AudioPlayerState?

    /// The date of the connection loss
    fileprivate var connectionLossDate: Date?

    /// The index of the current item in the queue
    fileprivate var currentItemIndexInQueue: Int?

    /// Reachability for network connection
    fileprivate let reachability = Reachability()


    // MARK: Readonly properties

    /// The current state of the player.
    open fileprivate(set) var state: AudioPlayerState {
        didSet {
            if state != oldValue {
                delegate?.audioPlayer(self, didChangeStateFrom: oldValue, toState: state)
            }
        }
    }

    /// The current item being played.
    open fileprivate(set) var currentItem: AudioItem? {
        didSet {
            for keyPath in AudioItem.ap_KVOItems {
                oldValue?.removeObserver(self, forKeyPath: keyPath)
                currentItem?.addObserver(self, forKeyPath: keyPath, options: .new, context: nil)
            }

            if let currentItem = currentItem {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    try AVAudioSession.sharedInstance().setCategory(AVAudioSessionCategoryPlayback)
                } catch { }

                player?.pause()
                player = nil
                state = .stopped

                let URLInfo: AudioItemURL = {
                    switch (self.currentQuality ?? self.defaultQuality) {
                    case .high:
                        return currentItem.highestQualityURL
                    case .medium:
                        return currentItem.mediumQualityURL
                    default:
                        return currentItem.lowestQualityURL
                    }
                    }()

                if reachability?.isReachable == true || URLInfo.URL.isFileURL {
                    state = .buffering
                }
                else {
                    connectionLossDate = nil
                    stateWhenConnectionLost = .buffering
                    state = .waitingForConnection
                    return
                }

                state = .buffering
                player = AVPlayer(url: URLInfo.URL as URL)
                player?.rate = rate
                player?.volume = volume
                currentQuality = URLInfo.quality

                player?.play()
                updateNowPlayingInfoCenter()

                if oldValue != currentItem {
                    delegate?.audioPlayer(self, willStartPlayingItem: currentItem)
                }
            }
            else {
                if let _ = oldValue {
                    stop()
                }
            }
        }
    }

    /// The current item duration or nil if no item or unknown duration.
    open var currentItemDuration: TimeInterval? {
        if let currentItem = player?.currentItem {
            let seconds = CMTimeGetSeconds(currentItem.duration)
            if !seconds.isNaN {
                return TimeInterval(seconds)
            }
        }
        return nil
    }

    /// The current item progression or nil if no item.
    open var currentItemProgression: TimeInterval? {
        if let currentItem = player?.currentItem {
            let seconds = CMTimeGetSeconds(currentItem.currentTime())
            if !seconds.isNaN {
                return TimeInterval(seconds)
            }
        }
        return nil
    }

    /// The current quality being played.
    open fileprivate(set) var currentQuality: AudioQuality?


    /// MARK: Public properties

    /// The maximum number of interruption before putting the player to Stopped mode. Default value is 10.
    open var maximumRetryCount = 10

    /// The delay to wait before cancelling last retry and retrying. Default value is 10seconds.
    open var retryTimeout = TimeInterval(10)

    /// Defines whether the player should resume after a system interruption or not. Default value is `true`.
    open var resumeAfterInterruption = true

    /// Defines whether the player should resume after a connection loss or not. Default value is `true`.
    open var resumeAfterConnectionLoss = true

    /// Defines the maximum to wait after a connection loss before putting the player to Stopped mode and cancelling the resume. Default value is 60seconds.
    open var maximumConnectionLossTime = TimeInterval(60)

    /// Defines whether the player should automatically adjust sound quality based on the number of interruption before a delay and the maximum number of interruption whithin this delay. Default value is `true`.
    open var adjustQualityAutomatically = true

    /// Defines the default quality used to play. Default value is `.Medium`
    open var defaultQuality = AudioQuality.medium

    /// Defines the delay within which the player wait for an interruption before upgrading the quality. Default value is 10minutes.
    open var adjustQualityTimeInternal = TimeInterval(10 * 60)

    /// Defines the maximum number of interruption to have within the `adjustQualityTimeInterval` delay before downgrading the quality. Default value is 3.
    open var adjustQualityAfterInterruptionCount = 3

    /// Defines the mode of the player. Default is `.Normal`.
    open var mode: AudioPlayerModeMask = [] {
        didSet {
            adaptQueueToPlayerMode()
        }
    }

    /// Defines the rate of the player. Default value is 1.
    open var rate = Float(1) {
        didSet {
            player?.rate = rate
            updateNowPlayingInfoCenter()
        }
    }

    /// Defines the volume of the player. `1.0` means 100% and `0.0` is 0%.
    open var volume = Float(1) {
        didSet {
            player?.volume = volume
        }
    }

    /// Defines the rate multiplier of the player when the backward/forward buttons are pressed. Default value is 2.
    open var rateMultiplerOnSeeking = Float(2)

    /// The delegate that will be called upon special events
    open weak var delegate: AudioPlayerDelegate?


    /// MARK: Public handy functions

    /**
    Play an item.

    - parameter item: The item to play.
    */
    open func playItem(_ item: AudioItem) {
        playItems([item])
    }

    /**
    Plays the first item in `items` and enqueud the rest.

    - parameter items: The items to play.
    */
    open func playItems(_ items: [AudioItem], startAtIndex index: Int = 0) {
        if items.count > 0 {
            var idx = 0
            enqueuedItems = items.map {
                idx = idx + 1
                return (position: idx, item: $0)
            }
            adaptQueueToPlayerMode()

            let startIndex: Int = {
                if index >= items.count || index < 0 {
                    return 0
                }
                return enqueuedItems?.index { $0.position == index } ?? 0
                }()
            currentItem = enqueuedItems?[startIndex].item
            currentItemIndexInQueue = startIndex
        }
        else {
            stop()
            enqueuedItems = nil
            currentItemIndexInQueue = nil
        }
    }

    /**
    Adds an item at the end of the queue. If queue is empty and player isn't
    playing, the behaviour will be similar to `playItem(item: item)`.

    - parameter item: The item to add.
    */
    open func addItemToQueue(_ item: AudioItem) {
        addItemsToQueue([item])
    }

    /**
    Adds items at the end of the queue. If the queue is empty and player isn't
    playing, the behaviour will be similar to `playItems(items: items)`.

    - parameter items: The items to add.
    */
    open func addItemsToQueue(_ items: [AudioItem]) {
        if currentItem != nil {
            var idx = 0
            enqueuedItems = (enqueuedItems ?? []) + items.map {
                idx = idx + 1
                return (position: idx, item: $0)
            }
            adaptQueueToPlayerMode()
        }
        else {
            playItems(items)
        }
    }

    open func removeItemAtIndex(_ index: Int) {
        assert(enqueuedItems != nil, "cannot remove an item when queue is nil")
        assert(index >= 0, "cannot remove an item at negative index")
        assert(index < enqueuedItems?.count, "cannot remove an item at an index > queue.count")

        if let enqueuedItems = enqueuedItems {
            if index >= 0 && index < enqueuedItems.count {
                self.enqueuedItems?.remove(at: index)
            }
        }
    }

    /**
    Resume the player.
    */
    open func resume() {
        player?.play()
        state = .playing
    }

    /**
    Pauses the player.
    */
    open func pause() {
        player?.pause()
        state = .paused
    }

    /**
    Stops the player and clear the queue.
    */
    open func stop() {
        //Stopping player immediately
        player?.pause()

        state = .stopped

        enqueuedItems = nil
        currentItem = nil
        player = nil
    }

    /**
    Plays next item in the queue.
    */
    open func next() {
        if let currentItemIndexInQueue = currentItemIndexInQueue , hasNext() {
            //The background task will end when the player will have enough data to play
            beginBackgroundTask()
            pause()

            let newIndex = currentItemIndexInQueue + 1
            if newIndex < enqueuedItems?.count {
                self.currentItemIndexInQueue = newIndex
                currentItem = enqueuedItems?[newIndex].item
            }
            else if mode.intersection(.RepeatAll) != [] {
                self.currentItemIndexInQueue = 0
                currentItem = enqueuedItems?.first?.item
            }
        }
    }

    /**
    Returns whether there is a next item in the queue or not.

    - returns: A boolean value indicating whether there is a next item to play or not.
    */
    open func hasNext() -> Bool {
        if let enqueuedItems = enqueuedItems, let currentItemIndexInQueue = currentItemIndexInQueue {
            if currentItemIndexInQueue + 1 < enqueuedItems.count || mode.intersection(.RepeatAll) != [] {
                return true
            }
        }
        return false
    }

    /**
    Plays previous item in the queue.
    */
    open func previous() {
        if let currentItemIndexInQueue = currentItemIndexInQueue, let enqueuedItems = enqueuedItems {
            let newIndex = currentItemIndexInQueue - 1
            if newIndex >= 0 {
                self.currentItemIndexInQueue = newIndex
                currentItem = enqueuedItems[newIndex].item
            }
            else if mode.intersection(.RepeatAll) != [] {
                self.currentItemIndexInQueue = enqueuedItems.count - 1
                currentItem = enqueuedItems.last?.item
            }
            else {
                seekToTime(0)
            }
        }
    }

    /**
    Seeks to a specific time.

    - parameter time: The time to seek to.
    */
    open func seekToTime(_ time: TimeInterval) {
        player?.seek(to: CMTimeMake(Int64(time), 1))
        updateNowPlayingInfoCenter()
    }

    /**
    Handle events received from Control Center/Lock screen/Other in UIApplicationDelegate.

    - parameter event: The event received.
    */
    open func remoteControlReceivedWithEvent(_ event: UIEvent) {
        if event.type == .remoteControl {
            //ControlCenter Or Lock screen
            switch event.subtype {
            case .remoteControlBeginSeekingBackward:
                rate = -(rate * rateMultiplerOnSeeking)
            case .remoteControlBeginSeekingForward:
                rate = rate * rateMultiplerOnSeeking
            case .remoteControlEndSeekingBackward:
                rate = -(rate / rateMultiplerOnSeeking)
            case .remoteControlEndSeekingForward:
                rate = rate / rateMultiplerOnSeeking
            case .remoteControlNextTrack:
                next()
            case .remoteControlPause:
                pause()
            case .remoteControlPlay:
                resume()
            case .remoteControlPreviousTrack:
                previous()
            case .remoteControlStop:
                stop()
            case .remoteControlTogglePlayPause:
                if state == .playing {
                    pause()
                }
                else {
                    resume()
                }
            default:
                break
            }
        }
    }


    // MARK: MPNowPlayingInfoCenter

    /**
    Updates the MPNowPlayingInfoCenter with current item's info.
    */
    fileprivate func updateNowPlayingInfoCenter() {
        if let currentItem = currentItem {
            var info = [String: AnyObject]()
            if let title = currentItem.title {
                info[MPMediaItemPropertyTitle] = title as AnyObject?
            }
            if let artist = currentItem.artist {
                info[MPMediaItemPropertyArtist] = artist as AnyObject?
            }
            if let album = currentItem.album {
                info[MPMediaItemPropertyAlbumTitle] = album as AnyObject?
            }
            if let trackCount = currentItem.trackCount {
                info[MPMediaItemPropertyAlbumTrackCount] = trackCount
            }
            if let trackNumber = currentItem.trackNumber {
                info[MPMediaItemPropertyAlbumTrackNumber] = trackNumber
            }
            if let artwork = currentItem.artworkImage {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(image: artwork)
            }

            if let duration = currentItemDuration {
                info[MPMediaItemPropertyPlaybackDuration] = duration as AnyObject?
            }
            if let progression = currentItemProgression {
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = progression as AnyObject?
            }

            info[MPNowPlayingInfoPropertyPlaybackRate] = rate as AnyObject?

            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
        else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }


    // MARK: Events

    open override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if let keyPath = keyPath, let object = object as? NSObject {
            if let player = player , object == player {
                switch keyPath {
                case "currentItem.duration":
                    //Duration is available
                    updateNowPlayingInfoCenter()

                    if let currentItem = currentItem, let currentItemDuration = currentItemDuration , currentItemDuration > 0 {
                        delegate?.audioPlayer(self, didFindDuration: currentItemDuration, forItem: currentItem)
                    }

                case "currentItem.playbackBufferEmpty":
                    //The buffer is empty and player is loading
                    if state == .playing && !qualityIsBeingChanged {
                        interruptionCount += 1
                    }
                    state = .buffering
                    beginBackgroundTask()

                case "currentItem.playbackLikelyToKeepUp":
                    if let playbackLikelyToKeepUp = player.currentItem?.isPlaybackLikelyToKeepUp , playbackLikelyToKeepUp {
                        //There is enough data in the buffer
                        if !pausedForInterruption && state != .paused && (stateWhenConnectionLost == nil || stateWhenConnectionLost != .paused) {
                            state = .playing
                            player.play()
                        }
                        else {
                            state = .paused
                        }

                        retryCount = 0

                        //We cancel the retry we might have asked for
                        retryTimer?.invalidate()
                        retryTimer = nil
                        
                        endBackgroundTask()
                    }
                    
                default:
                    break
                }
            }
            else if let currentItem = currentItem , object == currentItem {
                updateNowPlayingInfoCenter()
            }
        }
    }

    /**
    Audio session got interrupted by the system (call, Siri, ...). If interruption begins,
    we should ensure the audio pauses and if it ends, we should restart playing if state was
    `.Playing` before.

    - parameter note: The notification information.
    */
    @objc fileprivate func audioSessionGotInterrupted(_ note: Notification) {
        if let typeInt = (note as NSNotification).userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSessionInterruptionType(rawValue: typeInt) {
            if type == .began && (state == .playing || state == .buffering) {
                //We pause the player when an interruption is detected
                pausedForInterruption = true
                pause()
            }
            else {
                //We resume the player when the interruption is ended and we paused it in this interruption
                if let optionInt = (note as NSNotification).userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSessionInterruptionOptions(rawValue: optionInt)
                    if (options.intersection(.shouldResume)) != [] && pausedForInterruption {
                        if resumeAfterInterruption {
                            resume()
                        }
                        pausedForInterruption = false
                    }
                }
            }
        }
    }

    /**
    Audio session route changed (ex: earbuds plugged in/out). This can change the player
    state, so we just adapt it.

    - parameter note: The notification information.
    */
    @objc fileprivate func audioSessionRouteChanged(_ note: Notification) {
        if let player = player , player.rate == 0 {
            state = .paused
        }
    }

    /**
    Audio session got messed up (media services lost or reset). We gotta reactive the
    audio session and reset player.

    - parameter note: The notification information.
    */
    @objc fileprivate func audioSessionMessedUp(_ note: Notification) {
        //We reenable the audio session directly in case we're in background
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try AVAudioSession.sharedInstance().setCategory(AVAudioSessionCategoryPlayback)
        } catch {}

        //Aaaaand we: restart playing/go to next
        state = .stopped
        interruptionCount += 1
        retryOrPlayNext()
    }

    /**
    Playing item did end. We can play next or stop the player if queue is empty.

    - parameter note: The notification information.
    */
    @objc fileprivate func playerItemDidEnd(_ note: Notification) {
        if let sender = note.object as? AVPlayerItem, let currentItem = player?.currentItem , sender == currentItem {
            nextOrStop()
        }
    }

    @objc fileprivate func reachabilityStatusChanged(_ note: Notification) {
        if state == .waitingForConnection {
            if let connectionLossDate = connectionLossDate , reachability?.isReachable == true {
                if let stateWhenConnectionLost = stateWhenConnectionLost , stateWhenConnectionLost != .stopped {
                    if fabs(connectionLossDate.timeIntervalSinceNow) < maximumConnectionLossTime {
                        retryOrPlayNext()
                    }
                }
                self.connectionLossDate = nil
            }
        }
        else if state != .stopped && state != .paused {
            if reachability?.isReachable == true {
                retryOrPlayNext()
                connectionLossDate = nil
                stateWhenConnectionLost = nil
            }
            else {
                connectionLossDate = Date()
                stateWhenConnectionLost = state
                state = .waitingForConnection
            }
        }
    }

    /**
    The current progression was updated. When playing, this method gets called
    very often so we should consider doing as little work as possible in here.

    - parameter time: The current time.
    */
    fileprivate func currentProgressionUpdated(_ time: CMTime) {
        if let currentItemProgression = currentItemProgression, let currentItemDuration = currentItemDuration , currentItemDuration > 0 {
            //If the current progression is updated, it means we are playing. This fixes the behavior where sometimes
            //the `playbackLikelyToKeepUp` isn't changed even though it's playing (the first play).
            if state != .playing {
                if !pausedForInterruption && state != .paused && (stateWhenConnectionLost == nil || stateWhenConnectionLost != .paused) {
                    state = .playing
                    player?.play()
                }
                else {
                    state = .paused
                }
                endBackgroundTask()
            }

            //Then we can call the didUpdateProgressionToTime: delegate method
            let percentage = Float(currentItemProgression / currentItemDuration) * 100
            delegate?.audioPlayer(self, didUpdateProgressionToTime: currentItemProgression, percentageRead: percentage)
        }
    }


    // MARK: Retrying

    /**
    This will retry to play current item and seek back at the correct position if possible (or enabled). If not,
    it'll just play the next item in queue.
    */
    fileprivate func retryOrPlayNext() {
        if state == .playing {
            return
        }

        if maximumRetryCount > 0 {
            if retryCount < maximumRetryCount {
                //We can retry
                let cip = currentItemProgression
                let ci = currentItem

                currentItem = ci
                if let cip = cip {
                    seekToTime(cip)
                }

                retryCount += 1

                //We gonna cancel this current retry and create a new one if the player isn't playing after a certain delay
                let target = ClosureContainer(closure: { [weak self] sender in
                    self?.retryOrPlayNext()
                    })
                let timer = Timer(timeInterval: retryTimeout, target: target, selector: #selector(ClosureContainer.callSelectorOnTarget(_:)), userInfo: nil, repeats: false)
                RunLoop.main.add(timer, forMode: RunLoopMode.commonModes)
                retryTimer = timer

                return
            }
            else {
                retryCount = 0
            }
        }

        nextOrStop()
    }

    fileprivate func nextOrStop() {
        if mode.intersection(.Repeat) != [] {
            seekToTime(0)
            resume()
        }
        else if hasNext() {
            next()
        }
        else {
            stop()
        }
    }


    // MARK: Quality adjustment

    /**
    Adjusts quality if necessary based on interruption count.
    */
    fileprivate func adjustQualityIfNecessary() {
        if let currentQuality = currentQuality , adjustQualityAutomatically {
            if interruptionCount >= adjustQualityAfterInterruptionCount {
                //Decreasing audio quality
                let URLInfo: AudioItemURL? = {
                    if currentQuality == .high {
                        return self.currentItem?.mediumQualityURL
                    }
                    if currentQuality == .medium {
                        return self.currentItem?.lowestQualityURL
                    }
                    return nil
                    }()

                if let URLInfo = URLInfo , URLInfo.quality != currentQuality {
                    let cip = currentItemProgression
                    let item = AVPlayerItem(url: URLInfo.URL as URL)

                    qualityIsBeingChanged = true
                    player?.replaceCurrentItem(with: item)
                    if let cip = cip {
                        seekToTime(cip)
                    }
                    qualityIsBeingChanged = false

                    self.currentQuality = URLInfo.quality
                }
            }
            else if interruptionCount == 0 {
                //Increasing audio quality
                let URLInfo: AudioItemURL? = {
                    if currentQuality == .low {
                        return self.currentItem?.mediumQualityURL
                    }
                    if currentQuality == .medium {
                        return self.currentItem?.highestQualityURL
                    }
                    return nil
                    }()

                if let URLInfo = URLInfo , URLInfo.quality != currentQuality {
                    let cip = currentItemProgression
                    let item = AVPlayerItem(url: URLInfo.URL as URL)

                    qualityIsBeingChanged = true
                    player?.replaceCurrentItem(with: item)
                    if let cip = cip {
                        seekToTime(cip)
                    }
                    qualityIsBeingChanged = false

                    self.currentQuality = URLInfo.quality
                }
            }

            interruptionCount = 0

            let target = ClosureContainer(closure: { [weak self] sender in
                self?.adjustQualityIfNecessary()
                })
            let timer = Timer(timeInterval: adjustQualityTimeInternal, target: target, selector: #selector(ClosureContainer.callSelectorOnTarget(_:)), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: RunLoopMode.commonModes)
            qualityAdjustmentTimer = timer
        }
    }


    // MARK: Background

    /// The backround task identifier if a background task started. Nil if not.
    fileprivate var backgroundTaskIdentifier: Int?

    /**
    Starts a background task if there isn't already one running.
    */
    fileprivate func beginBackgroundTask() {
        if backgroundTaskIdentifier == nil {
            UIApplication.shared.beginBackgroundTask(expirationHandler: {[weak self] () -> Void in
                self?.backgroundTaskIdentifier = nil
                })
        }
    }
    
    /**
    Ends the background task if there is one.
    */
    fileprivate func endBackgroundTask() {
        if let backgroundTaskIdentifier = backgroundTaskIdentifier {
            if backgroundTaskIdentifier != UIBackgroundTaskInvalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
            }
            self.backgroundTaskIdentifier = nil
        }
    }
    
    
    // MARK: Mode
    
    /**
    Sorts the queue depending on the current mode.
    */
    fileprivate func adaptQueueToPlayerMode() {
        if mode.intersection(.Shuffle) != [] {
            enqueuedItems = enqueuedItems?.shuffled()
        }
        else {
            enqueuedItems = enqueuedItems?.sorted(by: { $0.position < $1.position })
        }
    }
}
