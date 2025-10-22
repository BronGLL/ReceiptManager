import Foundation
import UIKit
import SwiftUI
@preconcurrency import GoogleSignIn

struct SignInView: View {
    @Bindable var session: SessionViewModel

    @State private var email = ""
    @State private var password = ""
    @State private var isBusy = false

    private let googleHelper = SignInWithGoogleHelper(
        GIDClientID: SignInView.googleClientID()
    )

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Account")) {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .onSubmit {
                            Task { await runBusy {
                                await session.signIn(email: trimmedEmail, password: password)
                            } }
                        }
                }

                Section {
                    Button {
                        Task { await runBusy {
                            await session.signIn(email: trimmedEmail, password: password)
                        } }
                    } label: {
                        Label("Sign In", systemImage: "arrow.right.circle.fill")
                    }
                    .disabled(!isValid)

                    Button {
                        Task { await runBusy {
                            await session.createAccount(email: trimmedEmail, password: password)
                        } }
                    } label: {
                        Label("Create Account", systemImage: "person.badge.plus")
                    }
                    .disabled(!isValid)
                }

                // Google Sign-In button
                Section {
                    Button {
                        Task { await runBusy { await signInWithGoogleTapped() } }
                    } label: {
                        Label("Sign in with Google", systemImage: "g.circle")
                    }
                }

                if case .error(let message) = session.state {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Sign In")
            .disabled(isBusy)
            .overlay {
                if isBusy { ProgressView().controlSize(.large) }
            }
        }
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedEmail.isEmpty && !password.isEmpty && password.count >= 6
    }

    private func runBusy(_ work: @escaping () async -> Void) async {
        isBusy = true
        defer { isBusy = false }
        await work()
    }

    private func signInWithGoogleTapped() async {
        do {
            let result = try await googleHelper.signIn()
            // result already provides non-optional idToken and accessToken
            await session.signInWithGoogle(idToken: result.idToken, accessToken: result.accessToken)
        } catch {
            // Surface error via state to show in the form
            await MainActor.run {
                session.state = .error(error.localizedDescription)
            }
        }
    }

    private static func googleClientID() -> String {
        guard
            let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dict = plist as? [String: Any],
            let clientID = dict["CLIENT_ID"] as? String,
            !clientID.isEmpty
        else {
            assertionFailure("Google CLIENT_ID not found. Ensure GoogleService-Info.plist is in the app bundle and contains CLIENT_ID.")
            return "" // Will cause a controlled failure inside helper if somehow used.
        }
        return clientID
    }
}


struct GoogleTokens {
    let idToken: String
    let accessToken: String
}

final class SignInWithGoogleHelper {

    private let clientID: String

    init(GIDClientID clientID: String) {
        self.clientID = clientID
    }

    
    func signIn() async throws -> GoogleTokens {
        
        let presenter = try await currentPresentingViewController()

        
        guard !clientID.isEmpty else {
            throw NSError(domain: "GoogleSignIn", code: -2000, userInfo: [NSLocalizedDescriptionKey: "Missing Google CLIENT_ID."])
        }

        
        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        
        await withCheckedContinuation { continuation in
            if #available(iOS 14.0, *) {
                GIDSignIn.sharedInstance.configure(completion: { _ in
                    continuation.resume()
                })
            } else {
                continuation.resume()
            }
        }

        
        let result = try await signInWithPresenting(presenter)

        
        guard let idToken = result.user.idToken?.tokenString else {
            throw NSError(domain: "GoogleSignIn", code: -1001, userInfo: [NSLocalizedDescriptionKey: "Missing idToken"])
        }
        let accessToken = result.user.accessToken.tokenString

        return GoogleTokens(idToken: idToken, accessToken: accessToken)
    }

    

    private func signInWithPresenting(_ presenter: UIViewController) async throws -> GIDSignInResult {
        try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { signInResult, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                if let signInResult = signInResult {
                    continuation.resume(returning: signInResult)
                } else {
                    continuation.resume(throwing: NSError(domain: "GoogleSignIn", code: -1000, userInfo: [NSLocalizedDescriptionKey: "Sign-in result missing"]))
                }
            }
        }
    }

    private func currentPresentingViewController() async throws -> UIViewController {
        try await MainActor.run { () -> UIViewController in
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
                  let window = scene.windows.first(where: { $0.isKeyWindow }),
                  let root = window.rootViewController
            else {
                throw NSError(domain: "GoogleSignIn", code: -1002, userInfo: [NSLocalizedDescriptionKey: "Unable to find a presenting view controller"])
            }
            var top = root
            while let presented = top.presentedViewController {
                top = presented
            }
            return top
        }
    }
}
