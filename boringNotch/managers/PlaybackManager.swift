//
//  PlaybackManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on  04/08/24.
//

import SwiftUI
import AppKit
import Combine

class PlaybackManager: ObservableObject {
    @Published var isPlaying = false
    @Published var mrMediaRemoteSendCommandFunction: @convention(c) (Int, AnyObject?) -> Void
    @Published var mrMediaRemoteSetElapsedTimeFunction: @convention(c) (Double) -> Void

    init() {
        self.isPlaying = false
        self.mrMediaRemoteSendCommandFunction = {_, _ in }
        self.mrMediaRemoteSetElapsedTimeFunction = { _ in }
        handleLoadMediaHandlerApis()
    }
    
    private func handleLoadMediaHandlerApis() {
            // Load framework
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")) else { return }
        
            // Get a Swift function for MRMediaRemoteSendCommand
        guard let MRMediaRemoteSendCommandPointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) else { return }
        
        typealias MRMediaRemoteSendCommandFunction = @convention(c) (Int, AnyObject?) -> Void
        
        mrMediaRemoteSendCommandFunction = unsafeBitCast(MRMediaRemoteSendCommandPointer, to: MRMediaRemoteSendCommandFunction.self)

        guard let MRMediaRemoteSetElapsedTimePointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSetElapsedTime" as CFString) else { return }

        typealias MRMediaRemoteSetElapsedTimeFunction = @convention(c) (Double) -> Void
        mrMediaRemoteSetElapsedTimeFunction = unsafeBitCast(MRMediaRemoteSetElapsedTimePointer, to: MRMediaRemoteSetElapsedTimeFunction.self)
    }
    
    deinit {
        self.mrMediaRemoteSendCommandFunction = {_, _ in }
        self.mrMediaRemoteSetElapsedTimeFunction = { _ in }
    }
    
    func playPause() -> Bool {
        if self.isPlaying {
            mrMediaRemoteSendCommandFunction(2, nil)
            self.isPlaying = false
            return false
        } else {
            mrMediaRemoteSendCommandFunction(0, nil)
            self.isPlaying = true
            return true
        }
    }
    
    func nextTrack() {
            // Implement next track action
        mrMediaRemoteSendCommandFunction(4, nil)
    }
    
    func previousTrack() {
            // Implement previous track action
        mrMediaRemoteSendCommandFunction(5, nil)
    }

    func seekTrack(to time: TimeInterval) {
        mrMediaRemoteSetElapsedTimeFunction(time)
    }
}
