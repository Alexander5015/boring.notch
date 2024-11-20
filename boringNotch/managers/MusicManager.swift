//
//  MusicManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import SwiftUI
import Defaults

let defaultImage: NSImage = .init(
    systemSymbolName: "heart.fill",
    accessibilityDescription: "Album Art"
)!

struct MusicData {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    var artworkData: Data?
}

class MusicManager: ObservableObject {

    // MARK: - Properties
    private var cancellables = Set<AnyCancellable>()
    private var debounceToggle: DispatchWorkItem?
    private var vm: BoringViewModel
    private var lastMusicItem: MusicData?
    private var isCurrentlyPlaying: Bool = false
    
    @Published var songTitle: String = "I'm Handsome"
    @Published var artistName: String = "Me"
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var musicToggledManually: Bool = false
    @Published var album: String = "Self Love"
    @Published var playbackManager = PlaybackManager()
    @Published var lastUpdated: Date = .init()
    @Published var isPlayerIdle: Bool = true
    @Published var animations: BoringAnimations = .init()
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String?
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = Date()
    @Published var playbackRate: Double = 0
    @ObservedObject var detector: FullscreenMediaDetector
    @Published var usingAppIconForArtwork: Bool = false
    var nowPlaying: NowPlaying
    
    private let mediaRemoteBundle: CFBundle
    private let MRMediaRemoteGetNowPlayingInfo: @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private let mrMediaRemoteRegisterForNowPlayingNotifications: @convention(c) (DispatchQueue) -> Void
    private let mrMediaRemoteGetNowPlayingApplicationIsPlaying: @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    
    // MARK: - Initialization
    init?(vm: BoringViewModel) {
        self.vm = vm
        _detector = ObservedObject(wrappedValue: FullscreenMediaDetector())
        nowPlaying = NowPlaying()
        
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
              let MRMediaRemoteGetNowPlayingInfoPointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString),
              let MRMediaRemoteRegisterForNowPlayingNotificationsPointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString),
              let MRMediaRemoteGetNowPlayingApplicationIsPlayingPointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString)
        else {
            print("Failed to load MediaRemote.framework or get function pointers")
            return nil
        }
        
        self.mediaRemoteBundle = bundle
        self.MRMediaRemoteGetNowPlayingInfo = unsafeBitCast(MRMediaRemoteGetNowPlayingInfoPointer, to: (@convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void).self)
        self.mrMediaRemoteRegisterForNowPlayingNotifications = unsafeBitCast(MRMediaRemoteRegisterForNowPlayingNotificationsPointer, to: (@convention(c) (DispatchQueue) -> Void).self)
        self.mrMediaRemoteGetNowPlayingApplicationIsPlaying = unsafeBitCast(MRMediaRemoteGetNowPlayingApplicationIsPlayingPointer, to: (@convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void).self)
        
        setupNowPlayingObserver()
        fetchNowPlayingInfo()
        
        setupDetectorObserver()
        
        if nowPlaying.playing {
            self.fetchNowPlayingInfo()
        }
    }
    
    deinit {
        debounceToggle?.cancel()
        cancellables.removeAll()
    }
    
    // MARK: - Setup Methods
    private func setupNowPlayingObserver() {
        mrMediaRemoteRegisterForNowPlayingNotifications(DispatchQueue.main)
        
        observeNotification(name: "kMRMediaRemoteNowPlayingInfoDidChangeNotification") { [weak self] in
            self?.fetchNowPlayingInfo(bundle: self?.nowPlaying.appBundleIdentifier ?? nil)
        }
        
        observeNotification(name: "kMRMediaRemoteNowPlayingApplicationDidChangeNotification") { [weak self] in
            self?.updateApp()
        }
        
        observeDistributedNotification(name: "com.spotify.client.PlaybackStateChanged") { [weak self] in
            self?.fetchNowPlayingInfo(bundle: "com.spotify.client")
        }
        
        observeDistributedNotification(name: "com.apple.Music.playerInfo") { [weak self] in
            self?.fetchNowPlayingInfo(bundle: "com.apple.Music")
        }
    }
    
    private func setupDetectorObserver() {
        detector.$currentAppInFullScreen
            .sink { [weak self] _ in
                self?.fetchNowPlayingInfo(bypass: true, bundle: self?.nowPlaying.appBundleIdentifier ?? nil)
            }
            .store(in: &cancellables)
    }
    
    private func observeNotification(name: String, handler: @escaping () -> Void) {
        NotificationCenter.default.publisher(for: NSNotification.Name(name))
            .sink { _ in handler() }
            .store(in: &cancellables)
    }
    
    private func observeDistributedNotification(name: String, handler: @escaping () -> Void) {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(name),
            object: nil,
            queue: .main
        ) { _ in handler() }
    }
    
    // MARK: - Update Methods
    @objc func updateApp() {
        self.bundleIdentifier = nowPlaying.appBundleIdentifier ?? "com.apple.Music"
    }
    
    @objc func fetchNowPlayingInfo(bypass: Bool = false, bundle: String? = nil) {
        if musicToggledManually && !bypass { return }
        
        updateBundleIdentifier(bundle)
        
        MRMediaRemoteGetNowPlayingInfo(DispatchQueue.main) { [weak self] information in
            guard let self = self else { return }
            
            let newInfo = self.extractMusicInfo(from: information)
            let state: Int? = information["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Int
            
            self.updateMusicState(newInfo: newInfo, state: state)
            
            guard let elapsedTime = information["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? TimeInterval,
                  let timestampDate = information["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date,
                  let playbackRate = information["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double else {
                return
            }
            
            DispatchQueue.main.async {
                self.elapsedTime = elapsedTime
                self.timestampDate = timestampDate
                self.playbackRate = playbackRate
            }
        }
    }
    
    // MARK: - Helper Methods
    private func updateBundleIdentifier(_ bundle: String?) {
        if let bundle = bundle {
            self.bundleIdentifier = bundle
            
        }
    }
    
    private func extractMusicInfo(from information: [String: Any]) -> MusicData {
        let title = information["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = information["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        let album = information["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let duration = information["kMRMediaRemoteNowPlayingInfoDuration"] as? TimeInterval ?? lastMusicItem?.duration ?? 0
        let artworkData = information["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
       
        return MusicData(title: title, artist: artist, album: album, duration: duration, artworkData: artworkData)
    }
    
    private func updateMusicState(newInfo: MusicData, state: Int?) {
        if (newInfo.artworkData != nil && newInfo.artworkData != lastMusicItem?.artworkData) || 
           (newInfo.title, newInfo.artist, newInfo.album) != 
           (lastMusicItem?.title, lastMusicItem?.artist, lastMusicItem?.album) {
            updateArtwork(newInfo.artworkData)
            var updatedMusicItem = lastMusicItem
            updatedMusicItem?.artworkData = newInfo.artworkData
            lastMusicItem = updatedMusicItem
        }
        lastMusicItem = newInfo
        mrMediaRemoteGetNowPlayingApplicationIsPlaying(DispatchQueue.main) { [weak self] isPlaying in
            self?.musicIsPaused(state: isPlaying, setIdle: true)
        }
        self.artistName = newInfo.artist
        self.songTitle = newInfo.title
        self.album = newInfo.album
        self.songDuration = newInfo.duration
    }
    
    private func updateArtwork(_ artworkData: Data?) {
        if let artworkData = artworkData,
           let artworkImage = NSImage(data: artworkData) {
            self.usingAppIconForArtwork = false
            self.updateAlbumArt(newAlbumArt: artworkImage)
        } else if let appIconImage = appIconAsNSImage(for: bundleIdentifier ?? nowPlaying.appBundleIdentifier ?? "") {
            self.usingAppIconForArtwork = true
            self.updateAlbumArt(newAlbumArt: appIconImage)
        }
    }
    
    func musicIsPaused(state: Bool, bypass: Bool = false, setIdle: Bool = false) {
        if musicToggledManually && !bypass { return }
        
        let previousState = self.isPlaying
        
        withAnimation(.smooth) {
            self.isPlaying = state
            self.playbackManager.isPlaying = state
            
            if !state {
                self.lastUpdated = Date()
            }
            
            updateFullscreenMediaDetection()
            
            // Only update sneak peek if the state has actually changed
            if previousState != state {
                updateSneakPeek()
            }
            
            updateIdleState(setIdle: setIdle, state: state)
        }
    }
    
    private func updateFullscreenMediaDetection() {
        DispatchQueue.main.async {
            if Defaults[.enableFullscreenMediaDetection] {
                self.vm.toggleMusicLiveActivity(status: !self.detector.currentAppInFullScreen)
            }
        }
    }
    
    private func updateSneakPeek() {
        if self.isPlaying && Defaults[.enableSneakPeek] && !self.detector.currentAppInFullScreen {
            self.vm.toggleSneakPeek(status: true, type: SneakContentType.music)
        }
    }
    
    private func updateIdleState(setIdle: Bool, state: Bool) {
        if setIdle && state {
            self.isPlayerIdle = false
            debounceToggle?.cancel()
        } else if setIdle && !state {
            debounceToggle = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.lastUpdated.timeIntervalSinceNow < -Defaults[.waitInterval] {
                    withAnimation {
                        self.isPlayerIdle = !self.isPlaying
                    }
                }
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + Defaults[.waitInterval], execute: debounceToggle!)
        }
    }
    
    func togglePlayPause() {
        musicToggledManually = true
        
        let playState = playbackManager.playPause()
        
        musicIsPaused(state: playState, bypass: true, setIdle: true)
        
        if playState {
            fetchNowPlayingInfo(bypass: true)
        } else {
            lastUpdated = Date()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.musicToggledManually = false
            self?.fetchNowPlayingInfo()
        }
    }
    
    private var workItem: DispatchWorkItem?
        
    func updateAlbumArt(newAlbumArt: NSImage) {
        workItem?.cancel()
        workItem = DispatchWorkItem { [weak self] in
            withAnimation(.smooth) {
                self?.albumArt = newAlbumArt
                if Defaults[.coloredSpectrogram] {
                    self?.calculateAverageColor()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem!)
    }
    
    func calculateAverageColor() {
        albumArt.averageColor { [weak self] color in
            DispatchQueue.main.async {
                withAnimation(.smooth) {
                    self?.avgColor = color ?? .white
                }
            }
        }
    }
    
    func nextTrack() {
        playbackManager.nextTrack()
        fetchNowPlayingInfo(bypass: true)
    }
    
    func previousTrack() {
        playbackManager.previousTrack()
        fetchNowPlayingInfo(bypass: true)
    }
    
    func seekTrack(to time: TimeInterval) {
        playbackManager.seekTrack(to: time)
    }
    
    func openMusicApp() {
        guard let bundleID = nowPlaying.appBundleIdentifier else {
            print("Error: appBundleIdentifier is nil")
            return
        }
        
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            print("Failed to find app with bundle ID: \(bundleID)")
            return
        }
        
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        print("Launched app with bundle ID: \(bundleID)")
    }
}
