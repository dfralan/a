// a

// MAIN NAVIGATION STRUCTURE

import Foundation
import SwiftUI

class MainTabNavigation: ObservableObject {
    @Published var mainTabPath = NavigationPath()
}

class Navigation: ObservableObject {
    
    @Published var homePath = NavigationPath() {
        didSet {
            print("🔄 Navigation: Home Path updated - Count: \(homePath.count)")
        }
    }
    
    // MARK: - Navigation State Management
    private var isNavigating = false
    private var navigationQueue: [() -> Void] = []
    private var lastResetTime: Date = Date()
    private let resetCooldown: TimeInterval = 0.2
    
    init() {
        // Set up memory warning observer
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleMemoryWarning() {
        print("⚠️ Memory warning received - clearing navigation state")
        DispatchQueue.main.async {
            self.emergencyReset()
        }
    }
    
    // MARK: - Navigation Protection
    func safeNavigate<T: Hashable>(_ destination: T) {
        // Check if we can navigate
        guard canNavigate() else {
            print("❌ Navigation blocked: Cannot navigate at this time")
            queueNavigation(destination)
            return
        }
        
        isNavigating = true
        print("🚀 Navigating to: \(destination)")
        
        // Clear path if it's getting too deep
        if homePath.count > 5 {
            print("🧹 Clearing deep navigation stack")
            homePath = NavigationPath()
        }
        
        // Add small delay to prevent rapid navigation issues, but shorter for better responsiveness
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Double-check that we're still in a valid state
            guard self.isNavigating else {
                print("⚠️ Navigation cancelled: State changed during delay")
                return
            }
            
            self.homePath.append(destination)
            self.isNavigating = false
            
            // Process queued navigation if any
            if !self.navigationQueue.isEmpty {
                let nextNavigation = self.navigationQueue.removeFirst()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    nextNavigation()
                }
            }
        }
    }
    
    func queueNavigation<T: Hashable>(_ destination: T) {
        navigationQueue.append {
            self.safeNavigate(destination)
        }
    }
    
    // MARK: - Navigation Cleanup
    func clearNavigation() {
        print("🧹 Clearing navigation stack")
        homePath = NavigationPath()
        isNavigating = false
        navigationQueue.removeAll()
    }
    
    // MARK: - Gentle Navigation Reset
    func gentleReset() {
        print("🔄 Gentle navigation reset")
        isNavigating = false
        navigationQueue.removeAll()
        lastResetTime = Date()
        // Don't clear the path immediately, let it clear naturally
    }
    
    // MARK: - Navigation State Validation
    func validateNavigationState() -> Bool {
        let isValid = homePath.count <= 10 && !isNavigating
        if !isValid {
            print("⚠️ Navigation state invalid - clearing")
            clearNavigation()
        }
        return isValid
    }
    
    // MARK: - Navigation State Check
    func canNavigate() -> Bool {
        let timeSinceReset = Date().timeIntervalSince(lastResetTime)
        let cooldownPassed = timeSinceReset > resetCooldown
        return !isNavigating && homePath.count <= 10 && cooldownPassed
    }
    
    // MARK: - Emergency Navigation Reset
    func emergencyReset() {
        print("🚨 Emergency navigation reset")
        isNavigating = false
        navigationQueue.removeAll()
        homePath = NavigationPath()
    }
    
    // MARK: - Navigation Types
    
    // PROFILE DETAILED VIEW
    struct NavUserProfile: Hashable {
        let userProfile: RUserProfile
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(userProfile.publicKey)
        }
        
        static func == (lhs: NavUserProfile, rhs: NavUserProfile) -> Bool {
            return lhs.userProfile.publicKey == rhs.userProfile.publicKey
        }
    }
    
    // FOLLOWING LIST VIEW
    struct NavFollowing: Hashable {
        let userProfile: RUserProfile
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(userProfile.publicKey)
        }
        
        static func == (lhs: NavFollowing, rhs: NavFollowing) -> Bool {
            return lhs.userProfile.publicKey == rhs.userProfile.publicKey
        }
    }
    
    // FOLLOWERS LIST VIEW
    struct NavFollowers: Hashable {
        let userProfile: RUserProfile
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(userProfile.publicKey)
        }
        
        static func == (lhs: NavFollowers, rhs: NavFollowers) -> Bool {
            return lhs.userProfile.publicKey == rhs.userProfile.publicKey
        }
    }
    
    // QR VIEW
    struct NavQR: Hashable {
        let userProfile: RUserProfile
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(userProfile.publicKey)
        }
        
        static func == (lhs: NavQR, rhs: NavQR) -> Bool {
            return lhs.userProfile.publicKey == rhs.userProfile.publicKey
        }
    }
    
    //EDIT PROFILE VIEW
    struct NavEditProfile: Hashable {
        let userProfile: RUserProfile
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(userProfile.publicKey)
        }
        
        static func == (lhs: NavEditProfile, rhs: NavEditProfile) -> Bool {
            return lhs.userProfile.publicKey == rhs.userProfile.publicKey
        }
    }
    
    //HOMEVIEW
    struct NavHome: Hashable {
        let userProfile: RUserProfile
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(userProfile.publicKey)
        }
        
        static func == (lhs: NavHome, rhs: NavHome) -> Bool {
            return lhs.userProfile.publicKey == rhs.userProfile.publicKey
        }
    }
}
