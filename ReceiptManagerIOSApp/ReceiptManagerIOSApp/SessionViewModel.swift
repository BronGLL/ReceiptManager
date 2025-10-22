import Foundation
import SwiftUI

@MainActor
@Observable
final class SessionViewModel {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(User)
        case error(String)
    }

    private let auth: AuthService
    var state: State = .loading

    init(auth: AuthService = .shared) {
        self.auth = auth
        
        if let user = auth.currentUser {
            state = .signedIn(user)
        } else {
            state = .signedOut
        }
        
        Task { await observeAuthState() }
    }

    private func setState(_ new: State) {
        withAnimation(.default) {
            state = new
        }
    }

    func signIn(email: String, password: String) async {
        setState(.loading)
        do {
            let user = try await auth.signIn(email: email, password: password)
            setState(.signedIn(user))
        } catch {
            setState(.error(error.localizedDescription))
            setState(.signedOut)
        }
    }

    func createAccount(email: String, password: String) async {
        setState(.loading)
        do {
            let user = try await auth.createUser(email: email, password: password)
            setState(.signedIn(user))
        } catch {
            setState(.error(error.localizedDescription))
            setState(.signedOut)
        }
    }

    // New: Google sign-in entrypoint from the UI
    func signInWithGoogle(idToken: String, accessToken: String) async {
        setState(.loading)
        do {
            let user = try await auth.signInWithGoogle(idToken: idToken, accessToken: accessToken)
            setState(.signedIn(user))
        } catch {
            setState(.error(error.localizedDescription))
            setState(.signedOut)
        }
    }

    func signOut() async {
        do {
            try await auth.signOut()
            setState(.signedOut)
        } catch {
            setState(.error(error.localizedDescription))
        }
    }

    private func observeAuthState() async {
        for await user in auth.authStateChanges() {
            if let user {
                setState(.signedIn(user))
            } else {
                setState(.signedOut)
            }
        }
    }
}

private extension SessionViewModel {
    var stateDisplayKey: String {
        switch state {
        case .loading: return "loading"
        case .signedOut: return "signedOut"
        case .signedIn: return "signedIn"
        case .error: return "error"
        }
    }
}
