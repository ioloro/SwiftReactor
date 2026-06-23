import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: DemoSettings
    @State private var showingSettings = false

    var body: some View {
        TabView {
            LongLiveTab()
                .tabItem { Label("LongLive-v2", systemImage: "rectangle.split.3x1") }

            HeliosTab()
                .tabItem { Label("Helios", systemImage: "photo.on.rectangle.angled") }

            LingBotTab()
                .tabItem { Label("LingBot", systemImage: "gamecontroller") }

            SanaStreamingTab()
                .tabItem { Label("SANA-Streaming", systemImage: "film.stack") }
        }
        .padding()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "key.fill")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet()
        }
        .onAppear {
            if settings.apiKey.isEmpty && settings.staticJWT.isEmpty {
                showingSettings = true
            }
        }
    }
}

struct SettingsSheet: View {
    @EnvironmentObject private var settings: DemoSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reactor credentials")
                .font(.title2.weight(.semibold))

            Text("Either paste a pre-minted JWT (fastest), or paste your `rk_…` API key and the demo will mint a JWT on each connect. In production, mint server-side — don't ship the API key.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Pre-minted JWT").font(.callout.weight(.medium))
                TextField("eyJhbGciOi…", text: $settings.staticJWT, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .lineLimit(2...4)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API key (alternative)").font(.callout.weight(.medium))
                SecureField("rk_…", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") {
                    settings.persist()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 360)
    }
}
