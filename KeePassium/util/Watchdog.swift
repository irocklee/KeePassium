//  KeePassium Password Manager
//  Copyright © 2018–2019 Andrei Popleteev <info@keepassium.com>
// 
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import UIKit
import KeePassiumLib

protocol WatchdogDelegate: class {
    var isAppCoverVisible: Bool { get }
    /// Should obscure the app UI while in background.
    func showAppCover(_ sender: Watchdog)
    /// Hides the cover shown by `showAppCover`.
    func hideAppCover(_ sender: Watchdog)
    
    var isAppLockVisible: Bool { get }
    /// Requests a passcode or biometric auth to access the app.
    func showAppLock(_ sender: Watchdog)
    /// Hides the AppLock passcode request (unlocks the app).
    func hideAppLock(_ sender: Watchdog)

    /// Called after watchdog has closed current database.
    func watchdogDidCloseDatabase(_ sender: Watchdog)
}

extension WatchdogDelegate {
    // Default empty implementations of delegate methods.
    var isAppCoverVisible: Bool { return false }
    func showAppCover(_ sender: Watchdog) { }
    func hideAppCover(_ sender: Watchdog) { }
    var isAppLockVisible: Bool { return false }
    func showAppLock(_ sender: Watchdog) { }
    func hideAppLock(_ sender: Watchdog) { }
    func watchdogDidCloseDatabase(_ sender: Watchdog) { }
}

fileprivate extension WatchdogDelegate {
    /// Internal synonym for `isAppLockVisible`
    var isAppLocked: Bool {
        return isAppLockVisible
    }
}

class Watchdog {
    public static let shared = Watchdog()
    
    public enum Notifications {
        /// Notification name for watchdog triggers
        public static let appLockDidEngage = Notification.Name("com.keepassium.Watchdog.appLockDidEngage")
        public static let databaseLockDidEngage = Notification.Name("com.keepassium.Watchdog.databaseLockDidEngage")
    }
    
    /// Returns `true` *once* after the database timeout was triggered.
    /// After the first call, resets back to `false`.
    public var isDatabaseTimeoutExpired: Bool {
        if _isDatabaseTimeoutExpired {
           _isDatabaseTimeoutExpired = false
            return true
        } else {
            return false
        }
    }
    private var _isDatabaseTimeoutExpired = false
    
    public weak var delegate: WatchdogDelegate?
    
    private var isBeingUnlockedFromAnotherWindow = false
    private var appLockTimer: Timer?
    private var databaseLockTimer: Timer?
    
    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil)
    }
    
    // MARK: - App state transitions
    
    @objc private func appDidBecomeActive(_ notification: Notification) {
        didBecomeActive()
    }
    
    internal func didBecomeActive() {
        print("App did become active (fromAnotherWindow: \(isBeingUnlockedFromAnotherWindow))")
        // `appDidBecomeActive` is also being called after returning from biometric auth window.
        // Flag `isBeingUnlockedFromAnotherWindow` tracks this state to avoid immediate re-locking.
        restartAppTimer()
        restartDatabaseTimer()
        if isBeingUnlockedFromAnotherWindow {
            isBeingUnlockedFromAnotherWindow = false
        } else {
            maybeLockSomething()
        }
        delegate?.hideAppCover(self)
    }
    
    @objc private func appWillResignActive(_ notification: Notification) {
        willResignActive()
    }
    
    internal func willResignActive() {
        print("App will resign active")
        guard let delegate = delegate else { return }
        delegate.showAppCover(self)
        if delegate.isAppLocked { return }

        let databaseTimeout = Settings.current.premiumDatabaseLockTimeout
        if databaseTimeout == .immediately {
            Diag.debug("Going to background: Database Lock engaged")
            engageDatabaseLock()
        }
        
        let appTimeout = Settings.current.appLockTimeout
        if appTimeout.triggerMode == .appMinimized {
            Diag.debug("Going to background: App Lock engaged")
            Watchdog.shared.restart() // update user activity timestamp (conditionally)
            // do nothing, this case is handled on appDidBecomeActive
        }
        
        // Timers don't run reliably in background anyway, so kill them
        appLockTimer?.invalidate()
        databaseLockTimer?.invalidate()
        appLockTimer = nil
        databaseLockTimer = nil
    }
    
    // MARK: - Watchdog functions
    
    @objc private func maybeLockSomething() {
        maybeLockApp()
        maybeLockDatabase()
    }
    
    @objc private func maybeLockApp() {
        if isShouldEngageAppLock() {
            engageAppLock()
        }
    }
    
    @objc private func maybeLockDatabase() {
        if isShouldEngageDatabaseLock() {
            engageDatabaseLock()
        }
    }
    
    open func restart() {
        guard let delegate = delegate else { return }
        guard !delegate.isAppLocked else { return }
        Settings.current.recentUserActivityTimestamp = Date.now
        restartAppTimer()
        restartDatabaseTimer()
    }

    private func isShouldEngageAppLock() -> Bool {
        guard Settings.current.isAppLockEnabled else { return false }
        let timeout = Settings.current.appLockTimeout
        switch timeout {
        case .never: // app lock disabled
            return false
        case .immediately:
            return true
        default:
            // also includes delays in .appMinimized trigger mode
            let timestampOfRecentActivity = Settings.current
                .recentUserActivityTimestamp
                .timeIntervalSinceReferenceDate
            let timestampNow = Date.now.timeIntervalSinceReferenceDate
            let secondsPassed = timestampNow - timestampOfRecentActivity
            return secondsPassed > Double(timeout.seconds)
        }
    }
    
    private func isShouldEngageDatabaseLock() -> Bool {
        let timeout = Settings.current.premiumDatabaseLockTimeout
        switch timeout {
        case .never:
            return false
        case .immediately:
            return true
        default:
            let timestampOfRecentActivity = Settings.current
                .recentUserActivityTimestamp
                .timeIntervalSinceReferenceDate
            let timestampNow = Date.now.timeIntervalSinceReferenceDate
            let secondsPassed = timestampNow - timestampOfRecentActivity
            return secondsPassed > Double(timeout.seconds)
        }
    }
    
    private func restartAppTimer() {
        if let appLockTimer = appLockTimer {
            appLockTimer.invalidate()
        }
        
        let timeout = Settings.current.appLockTimeout
        switch timeout.triggerMode {
        case .appMinimized:
            return
        case .userIdle:
            appLockTimer = Timer.scheduledTimer(
                timeInterval: Double(timeout.seconds),
                target: self,
                selector: #selector(maybeLockApp),
                userInfo: nil,
                repeats: false)
        }
    }

    private func restartDatabaseTimer() {
        if let databaseLockTimer = databaseLockTimer {
            databaseLockTimer.invalidate()
        }
        
        let timeout = Settings.current.premiumDatabaseLockTimeout
        Diag.verbose("Database Lock timeout: \(timeout.seconds)")
        switch timeout {
        case .never, .immediately:
            return
        default:
            databaseLockTimer = Timer.scheduledTimer(
                timeInterval: Double(timeout.seconds),
                target: self,
                selector: #selector(maybeLockDatabase),
                userInfo: nil,
                repeats: false)
        }
    }

    /// Triggers an app lock timeout notification.
    private func engageAppLock() {
        guard let delegate = delegate else { return }
        guard !delegate.isAppLocked else { return }
        Diag.info("Engaging App Lock")
        appLockTimer?.invalidate()
        appLockTimer = nil
        isBeingUnlockedFromAnotherWindow = false
        delegate.showAppLock(self)
        NotificationCenter.default.post(name: Watchdog.Notifications.appLockDidEngage, object: self)
    }
    
    /// Triggers a database timeout notification (only if there is an open DB).
    private func engageDatabaseLock() {
        Diag.info("Engaging Database Lock")
        self.databaseLockTimer?.invalidate()
        self.databaseLockTimer = nil
        try? Keychain.shared.removeAllDatabaseKeys() // throws `KeychainError`, ignored
        DatabaseManager.shared.closeDatabase(
            completion: {
                DispatchQueue.main.async {
                    self.delegate?.watchdogDidCloseDatabase(self)
                    NotificationCenter.default.post(
                        name: Watchdog.Notifications.databaseLockDidEngage,
                        object: self)
                }
            },
            clearStoredKey: true)
    }
    
    open func unlockApp(fromAnotherWindow: Bool) {
        guard let delegate = delegate else { return }
        guard delegate.isAppLocked else { return }
        isBeingUnlockedFromAnotherWindow = fromAnotherWindow
        delegate.hideAppCover(self)
        delegate.hideAppLock(self)
        restart()
    }
    
}
