import SwiftUI
import WebKit

/// Achew's website, already signed in.
struct AchewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            AchewWebView(loading: $loading, error: $error)
                .ignoresSafeArea(edges: .bottom)
                .overlay {
                    if let error {
                        ContentUnavailableView("Couldn't open Achew", systemImage: "exclamationmark.triangle", description: Text(error))
                            .background(Color(.systemBackground))
                    } else if loading {
                        ProgressView()
                    }
                }
                .navigationTitle("Achew")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

private struct AchewWebView: UIViewRepresentable {
    @Binding var loading: Bool
    @Binding var error: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        if let base = Achew.shared.baseURL, let url = URL(string: base) { web.load(URLRequest(url: url)) }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let parent: AchewWebView

        init(_ parent: AchewWebView) { self.parent = parent }

        /// Answers the site's login prompt, only for Achew's own address. A rejected
        /// login isn't retried, so a wrong password shows an error instead of looping.
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let achew = Achew.shared
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
                  challenge.protectionSpace.host == achew.baseURL.flatMap({ URL(string: $0)?.host }),
                  let username = achew.username, let password = achew.password else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            guard challenge.previousFailureCount == 0 else {
                parent.error = "Achew rejected the saved username or password. Check them in Settings."
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.loading = false }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
            if parent.error == nil, (error as NSError).code != NSURLErrorCancelled { parent.error = error.localizedDescription }
        }

        // A web view shows JavaScript dialogs only if the app does.
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            present(alert, from: webView) { completionHandler() }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            present(alert, from: webView) { completionHandler(false) }
        }

        private func present(_ alert: UIAlertController, from webView: WKWebView, otherwise: () -> Void) {
            var top = webView.window?.rootViewController
            while let next = top?.presentedViewController { top = next }
            guard let top else { otherwise(); return }
            top.present(alert, animated: true)
        }
    }
}

/// Connect to an Achew server, and show or hide its action on Book Details.
struct AchewSettingsView: View {
    @Environment(AppSettings.self) private var settings
    private let achew = Achew.shared
    @State private var url = Achew.shared.baseURL ?? ""
    @State private var username = Achew.shared.username ?? ""
    @State private var password = Achew.shared.password ?? ""
    @State private var busy = false
    @State private var error: String?
    @State private var connected = false

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                TextField("Server URL", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            } footer: {
                Text("Achew repairs a book's chapters on Audiobookshelf. Leave the username and password empty if your server doesn't ask for them. They're kept in the Keychain.")
            }
            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Text("Connect")
                        Spacer()
                        if busy {
                            ProgressView()
                        } else if connected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .disabled(busy || url.isEmpty)
            } footer: {
                if let error { Text(error).foregroundStyle(.red) }
            }
            if achew.configured {
                Section {
                    Toggle(isOn: $s.achewEnabled) {
                        Text("Fix Chapters in Book Details")
                        Text("Adds it to the ⋯ menu on each book")
                    }
                }
                Section {
                    Button("Disconnect", role: .destructive) {
                        achew.clear()
                        s.achewEnabled = false
                        url = ""
                        username = ""
                        password = ""
                        connected = false
                    }
                }
            }
        }
        .kitziBackground(grouped: true)
        .navigationTitle("Achew")
    }

    private func connect() async {
        busy = true; error = nil; connected = false
        defer { busy = false }
        do {
            try await achew.connect(url: url, username: username, password: password)
            connected = true
            settings.achewEnabled = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
