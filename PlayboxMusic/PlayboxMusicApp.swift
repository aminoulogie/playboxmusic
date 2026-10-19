import SwiftUI

@main
struct PlayboxMusicApp: App {
    @StateObject private var client = SoulseekClient()
    @StateObject private var library = MusicLibrary()
    @StateObject private var player = MusicPlayer()

    var body: some Scene {
        WindowGroup {
            MusicContentView()
                .environmentObject(client)
                .environmentObject(library)
                .environmentObject(player)
        }
    }
}
