import SwiftUI

struct SettingsView: View {
    @Environment(WatchModel.self) private var model
    @Environment(WatchDownloads.self) private var downloads
    @State private var cellular = Store.downloadsUseCellular
    @State private var confirmSignOut = false

    var body: some View {
        List {
            Section {
                Toggle("Downloads Use Cellular", isOn: $cellular)
                    .onChange(of: cellular) { _, v in
                        Store.downloadsUseCellular = v
                        downloads.cellularChanged()
                    }
            } footer: {
                Text("watchOS picks between Wi-Fi and your iPhone's connection. Books sent from the iPhone don't count.")
            }
            Section {
                LabeledContent("Downloads", value: Format.size(downloads.totalBytes))
                if let u = Store.username { LabeledContent("Account", value: u) }
                if let b = API.shared.base { Text(b).font(.caption2).foregroundStyle(.secondary) }
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
            }
            Section {
                Button("Sign Out", role: .destructive) { confirmSignOut = true }
            } footer: {
                Text("Downloads stay on the watch.")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Sign out of Kitzi on this watch?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task {
                    await model.signOut()
                    WatchNav.shared.path.removeAll()
                }
            }
        }
    }
}

struct LoginView: View {
    @Environment(WatchModel.self) private var model
    @State private var working = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Button {
                    Task {
                        working = true
                        do { try await model.signInWithPhone() } catch { self.error = error.localizedDescription }
                        working = false
                    }
                } label: {
                    HStack {
                        Label("Sign In with iPhone", systemImage: "iphone")
                        if working { Spacer(); ProgressView().frame(width: 20) }
                    }
                }
                .disabled(working)
                NavigationLink { WatchSignInForm() } label: { Label("Sign In on Watch", systemImage: "applewatch") }
            } footer: {
                if let error { Text(error).foregroundStyle(.orange) }
                else { Text("Signing in with iPhone uses the account Kitzi on your iPhone is signed in to.") }
            }
        }
        .navigationTitle("Kitzi")
    }
}

private struct WatchSignInForm: View {
    @Environment(WatchModel.self) private var model
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        List {
            TextField("Server address", text: $server)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Username", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textContentType(.password)
            Button {
                Task {
                    working = true
                    do { try await model.signIn(server: server, username: username, password: password) }
                    catch { self.error = error.localizedDescription }
                    working = false
                }
            } label: {
                HStack {
                    Text("Sign In")
                    if working { Spacer(); ProgressView().frame(width: 20) }
                }
            }
            .disabled(working || server.isEmpty || username.isEmpty)
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
        }
        .navigationTitle("Sign In")
    }
}
