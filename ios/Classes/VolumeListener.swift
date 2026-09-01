//
//  VolumeListener.swift
//  flutter_volume_controller
//
//  Created by yosemiteyss on 18/9/2022.
//

import AVFoundation
import Flutter
import Foundation
import UIKit

class VolumeListener: NSObject, FlutterStreamHandler {
    private static let retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8]

    private let audioSession: AVAudioSession
    private let volumeController: VolumeController

    private var outputVolumeObservation: NSKeyValueObservation?
    private var activationRetryWorkItem: DispatchWorkItem?
    private var foregroundObserver: NSObjectProtocol?
    private var activationAttempt = 0
    private var isSessionActivated = false

    var isListening: Bool {
        return outputVolumeObservation != nil
    }

    init(audioSession: AVAudioSession, volumeController: VolumeController) {
        self.audioSession = audioSession
        self.volumeController = volumeController
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        let args = arguments as! [String: Any]
        let category = AudioSessionCategory.allCases[args[MethodArg.audioSessionCategory] as! Int]
        let emitOnStart = args[MethodArg.emitOnStart] as! Bool

        do {
            try audioSession.setCategory(category.categoryType)
        } catch {
            return FlutterError(
                code: ErrorCode.registerVolumeListener,
                message: ErrorMessage.registerVolumeListener,
                details: error.localizedDescription
            )
        }

        outputVolumeObservation = audioSession.observe(\.outputVolume) { session, _ in
            events(String(session.outputVolume))
        }

        if emitOnStart {
            events(String(audioSession.outputVolume))
        }

        activationAttempt = 0
        isSessionActivated = false
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.activateSession(events: events)
        }
        activateSession(events: events)

        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        activationRetryWorkItem?.cancel()
        activationRetryWorkItem = nil
        removeForegroundObserver()
        isSessionActivated = false
        outputVolumeObservation = nil
        try? volumeController.deactivateAudioSession()
        return nil
    }

    private func activateSession(events: @escaping FlutterEventSink) {
        guard !isSessionActivated, outputVolumeObservation != nil else { return }

        activationRetryWorkItem?.cancel()
        activationRetryWorkItem = nil

        do {
            try audioSession.setActive(true)
            isSessionActivated = true
            removeForegroundObserver()
        } catch {
            scheduleActivationRetry(events: events, lastError: error)
        }
    }

    private func scheduleActivationRetry(events: @escaping FlutterEventSink, lastError: Error) {
        if activationAttempt < Self.retryDelays.count {
            let delay = Self.retryDelays[activationAttempt]
            activationAttempt += 1

            let workItem = DispatchWorkItem { [weak self] in
                self?.activateSession(events: events)
            }
            activationRetryWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else if activationAttempt == Self.retryDelays.count {
            // Emit the error once; the foreground observer keeps retrying.
            activationAttempt += 1
            events(FlutterError(
                code: ErrorCode.registerVolumeListener,
                message: ErrorMessage.registerVolumeListener,
                details: lastError.localizedDescription
            ))
        }
    }

    private func removeForegroundObserver() {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
    }
}
