// a

import SwiftUI
import RealmSwift
import SimpleToast

// MARK: - Home View

struct HomeView: View {
    
    // MARK: - Properties
    
    @State private var textNotesFilter: TextNotesFilter = .verse
    @State private var viewIsVisible = true
    @State private var retrieveData = true /// Switch track retrieving data
    @StateObject private var toolbarState = ToolbarState() /// Toolbar State
    @StateObject private var reactionsBarState = ReactionsBarState() /// Reactions Bar State
    @EnvironmentObject var nostrData: NostrData
    @EnvironmentObject var navigation: Navigation
    @ObservedResults(TextNoteVM.self, sortDescriptor: SortDescriptor(keyPath: "createdAt", ascending: false)) var textNoteResults
    
    /// Text Notes Filter
    enum TextNotesFilter: String {
        case verse = "My Verse"
        case following = "Following"
    }
    
    /// Events Filter (Should implement Virtual ScrollView)
    var textNotes: [TextNoteVM] {
        guard retrieveData else { return [] } /// Return an empty array if data retrieval is paused
        return Array(textNoteResults.filter("createdAt < %@", nostrData.lastSeenDate).prefix(250))
    }
    
    /// Events Filter For Pill
    var newTextNotes: [TextNoteVM] {
        guard retrieveData else { return [] }
        return Array(textNoteResults.filter("createdAt > %@", nostrData.lastSeenDate))
    }
    
    var body: some View {
        NavigationStack(path: $navigation.homePath) {
            ZStack(alignment: .bottom){
                VStack {
                    ScrollViewReader { reader in
                        ScrollView {
                            
                            // MARK: - Main Events Iteration
                            
                            LazyVStack(spacing: 20) {
                                ForEach(textNotes) { textNote in
                                    EventView(textNote: textNote) /// Displays an EventView with the given textNote
                                        .id(textNote.id) /// Identifies the EventView using the textNote's ID
                                        .scaleEffect(toolbarState.expanded ? 0.95 : 1) /// Scale effect based on the toolbarState's "expanded" property
                                    Divider()
                                }
                            }
                            .padding() /// Adds padding to the LazyVStack
                        }
                        .onDisappear {
                            viewIsVisible = false /// Sets the viewIsVisible property to false when the ScrollView disappears
                        }
                        
                        .onAppear {
                            viewIsVisible = true
                            // Only clear navigation if we're coming from a deep navigation stack
                            // Don't clear if we're just returning to home normally
                            if navigation.homePath.count > 3 {
                                print("🧹 HomeView: Clearing deep navigation stack on appear")
                                navigation.clearNavigation()
                            } else if navigation.homePath.count > 0 {
                                print("📱 HomeView: Returning to home with \(navigation.homePath.count) items in stack")
                            } else {
                                NostrData.shared.updateLastSeenDate() /// Updates the last seen date using NostrData's shared instance
                            }
                            NostrData.shared.bootstrapRelays(relay: "wss://relay.damus.io") /// Bootstraps relays using NostrData's shared instance with the selected relay URL
                        }
                        
                        /// Home tapped listener
                        .onChange(of: toolbarState.homeTapped) { value in
                            if !navigation.homePath.isEmpty {
                                print("🔄 HomeView: Gentle reset on home tap")
                                navigation.gentleReset()
                                NostrData.shared.updateLastSeenDate() /// Updates the last seen date using NostrData's shared instance
                            } else {
                                NostrData.shared.updateLastSeenDate() /// Updates the last seen date using NostrData's shared instance
                            }
                            if viewIsVisible {
                                withAnimation {
                                    reader.scrollTo(textNotes.first?.id, anchor: .top) /// Scrolls to the top of the ScrollView using the ID of the first textNote
                                }
                            }
                        }
                    }
                }

                // MARK: - Floating Toolbar
                
                floatingToolbarView(toolbarState: toolbarState)
                    .padding()
                
                // MARK: - Navigation Debug Overlay (for development)
                #if DEBUG
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Nav Stack: \(navigation.homePath.count)")
                                .font(.caption2)
                                .padding(4)
                                .background(.ultraThinMaterial)
                                .cornerRadius(4)
                            
                            Button("Clear Nav") {
                                navigation.clearNavigation()
                            }
                            .font(.caption2)
                            .padding(4)
                            .background(.ultraThinMaterial)
                            .cornerRadius(4)
                        }
                        .padding(.trailing, 8)
                    }
                }
                #endif
            }
            
            // MARK: - New Events Floating Pill
            
            .simpleToast(
                isPresented: .constant(newTextNotes.count > 0), /// Determines if the toast should be presented based on the count of newTextNotes
                options: SimpleToastOptions(
                    alignment: .top, /// Sets the position of the toast to the top of the screen
                    backdrop: .clear, /// Sets the backdrop style of the toast to clear
                    animation: .spring(response: 0.2, dampingFraction: 0.7, blendDuration: 0.2), /// Sets the animation style of the toast to a spring animation
                    modifierType: .skew /// Applies a skew modifier to the toast
                ),
                onDismiss: nil /// No action is taken when the toast is dismissed
            ) {
                NewPostsToastView(
                    avatarUrls: newTextNotes.prefix(3).map {
                        $0.userProfile?.avatarUrl ?? URL(string: $0.userProfile!.publicKey)!
                        /// Constructs an array of avatar URLs for up to the first three elements of newTextNotes.
                        /// If the userProfile is not nil, it uses the avatarUrl. Otherwise, it uses the userProfile's publicKey as a string converted to a URL.
                    }
                )
                .onTapGesture {
                    nostrData.updateLastSeenDate() /// Updates the last seen date in the nostrData object
                    toolbarState.homeTapped += 1 /// Increments the homeTapped property in the toolbarState object by 1
                }
            }
            
            // MARK: - Title
            
            .navigationTitle(textNotesFilter.rawValue)
            
            // MARK: - Destinations
            
            .navigationDestination(for: Navigation.NavUserProfile.self) { nav in
                ProfileDetailView(userProfile: nav.userProfile) /// Profile Detail View
                    .onAppear {
                        print("🎯 Navigation: ProfileDetailView appeared for \(nav.userProfile.publicKey.prefix(8))")
                    }
            }
            
            .navigationDestination(for: Navigation.NavFollowing.self) { nav in
                FollowingView(userProfile: nav.userProfile) /// Following List View
                    .onAppear {
                        print("🎯 Navigation: FollowingView appeared for \(nav.userProfile.publicKey.prefix(8))")
                    }
            }
            
            .navigationDestination(for: Navigation.NavFollowers.self) { nav in
                FollowersView(userProfile: nav.userProfile) /// Followers List View
                    .onAppear {
                        print("🎯 Navigation: FollowersView appeared for \(nav.userProfile.publicKey.prefix(8))")
                    }
            }
            
            .navigationDestination(for: Navigation.NavQR.self) { nav in
                QRView(userProfile: nav.userProfile) /// QR View
                    .onAppear {
                        print("🎯 Navigation: QRView appeared for \(nav.userProfile.publicKey.prefix(8))")
                    }
            }
            
            .navigationDestination(for: Navigation.NavEditProfile.self) { nav in
                EditProfileView(userProfile: nav.userProfile) /// Edit Profile View
                    .onAppear {
                        print("🎯 Navigation: EditProfileView appeared for \(nav.userProfile.publicKey.prefix(8))")
                    }
            }
            
            .toolbar {
                
                /// Switch track retrieving data
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        retrieveData.toggle()
                        if retrieveData {
                            NostrData.shared.reconnect()
                        } else {
                            NostrData.shared.disconnect()
                        }
                    } label: {
                        Image(systemName: retrieveData ? "togglepower" : "power")
                    }
                }
                
                /// Event Filter
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            self.textNotesFilter = .verse
                        } label:{
                            Label("My Verse", systemImage: "globe.americas")
                        }
                        
                        Button {
                            self.textNotesFilter = .following
                        } label: {
                            Label("Crew", systemImage: "person.3")
                        }
                    } label: {
                        Image(systemName: textNotesFilter == .verse ? "globe.americas" : "person.3")
                    }
                }
                
                /// Notifications Button
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        NotificationsView(userProfile: RUserProfile.preview)
                    } label: {
                        Image(systemName: "bell")
                    }
                }
                
                /// Wallet Button
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        WalletListView()
                    } label: {
                        Image(systemName: "bolt")
                    }
                }
                
                /// Navigation Test Button (for debugging)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        print("🧪 Testing navigation with sample profile")
                        let testProfile = RUserProfile.createEmpty(withPublicKey: "test123")
                        navigation.safeNavigate(Navigation.NavUserProfile(userProfile: testProfile))
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
    }
}

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
            .environmentObject(Navigation())
            .environmentObject(NostrData.shared.initPreview())
    }
}
