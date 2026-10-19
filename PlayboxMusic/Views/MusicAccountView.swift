import SwiftUI

struct MusicAccountView: View {
    @EnvironmentObject private var client: SoulseekClient
    @EnvironmentObject private var player: MusicPlayer
    @State private var showEqualizer = false
    @AppStorage("playbox.music.username") private var username = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button(client.isConnected ? "Reconnect" : "Sign In") {
                    CredentialStore.setPassword(password, for: username)
                    Task { await client.connect(username: username, password: password) }
                }
                .disabled(username.isEmpty || password.isEmpty || client.connectionState == .connecting)
                if client.isConnected {
                    Button("Sign Out", role: .destructive) { client.disconnect() }
                }
            } header: {
                Text("Soulseek account")
            } footer: {
                Text("A new username is registered automatically the first time you sign in with it. Keep the password: it cannot be recovered.")
            }

            Section {
                EmptyView()
            } header: {
                Text("Mix between songs")
            }
            MixSettingsForm(mix: player.mix)

            Section("Sound") {
                Button("Equalizer") { showEqualizer = true }
            }

            Section("Status") {
                LabeledContent("Server", value: statusText)
                if let port = client.listenPort {
                    LabeledContent("Listening port", value: String(port))
                }
            }

            Section {
                Text("Playbox Music downloads from other Soulseek users and shares nothing back, so some users may decline or queue requests. Only download music you have the right to use.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Account")
        .sheet(isPresented: $showEqualizer) { EqualizerView().environmentObject(player) }
        .onAppear {
            if password.isEmpty, !username.isEmpty {
                password = CredentialStore.password(for: username) ?? ""
            }
        }
    }

    private var statusText: String {
        switch client.connectionState {
        case .disconnected: "Signed out"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed(let reason): reason
        }
    }
}
