import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var auth: SpotifyAuth
    let disconnectSpotify: () -> Void

    var body: some View {
        Form {
            Section {
                SpotifySection(auth: auth, disconnect: disconnectSpotify)
            } header: {
                Text("Spotify")
            } footer: {
                Text("Spotify only lets apps read and edit playlists through its Web API, so MusicNotch uses a private developer app that only you use. Spotify requires Premium for these apps.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Apple Music") {
                Label("Works with your Music library. Nothing to set up.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            }

            Section("General") {
                Toggle("Show the playing song beside the notch", isOn: $settings.showSongBesideNotch)
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
                LaunchAtLoginToggle()
            }

            Section {
                HStack {
                    Text("Hover the notch to open MusicNotch.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit MusicNotch") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SpotifySection: View {
    @Bindable var auth: SpotifyAuth
    let disconnect: () -> Void

    @State private var copied = false

    var body: some View {
        switch auth.status {
        case .connected:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label {
                        Text("Connected")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Spacer()
                    Button("Disconnect", role: .destructive, action: disconnect)
                }
                if !auth.canControlPlayback {
                    // Logins from before playlist playback lack the permission to start music.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                        Text("Reconnect so playlists start without bringing Spotify to the front.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Reconnect") { Task { await auth.connect() } }
                    }
                    .font(.callout)
                }
                if let error = auth.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

        case .connecting, .disconnected:
            VStack(alignment: .leading, spacing: 14) {
                Step(number: 1, title: "Create an app in the Spotify Developer Dashboard.") {
                    Link("Open Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                }
                Step(number: 2, title: "Add this Redirect URI and tick “Web API”.") {
                    HStack(spacing: 8) {
                        Text(SpotifyAuth.redirectURI)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(SpotifyAuth.redirectURI, forType: .string)
                            copied = true
                        }
                        .controlSize(.small)
                    }
                }
                Step(number: 3, title: "Paste the app’s Client ID.") {
                    TextField("Client ID", text: $auth.clientID, prompt: Text("e.g. 3f9c1a…"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .labelsHidden()
                }

                HStack(spacing: 10) {
                    if auth.status == .connecting {
                        ProgressView().controlSize(.small)
                        Text("Waiting for your browser…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { auth.cancelConnect() }
                    } else {
                        Spacer()
                        Button("Connect Spotify") {
                            Task { await auth.connect() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(auth.clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if let error = auth.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct Step<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                content()
            }
        }
    }
}

private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A closure, not `set: update`: the method reference crashes the 6.3 compiler.
            Toggle("Open at login", isOn: Binding(get: { enabled }, set: { update($0) }))
            if let error {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private func update(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}
