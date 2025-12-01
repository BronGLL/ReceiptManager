import Foundation
import SwiftUI

// View model which is responsible for tracking the current authentication/session state

@MainActor
@Observable
final class SessionViewModel {
    // Representation of the session state for the app
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(User)
        case error(String)
    }
    // Authentication service used to perfrom sign-in/sign-out ops
    private let auth: AuthService
    // Current session state
    var state: State = .loading
    // Creates a new SessionViewModel instance
    init(auth: AuthService = .shared) {
        self.auth = auth
        // Initial data from Firebase's current user
        if let user = auth.currentUser {
            state = .signedIn(user)
        } else {
            state = .signedOut
        }
        // Start listening for authentication changes
        Task { await observeAuthState() }
    }
    // Helper to update the state
    private func setState(_ new: State) {
        withAnimation(.default) {
            state = new
        }
    }
    // Attempts to sign in using and email/password
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
    // Creates a new account using an email/password
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

    // Google sign-in entrypoint from the UI
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
    // Signs out the current user
    func signOut() async {
        do {
            try await auth.signOut()
            setState(.signedOut)
        } catch {
            setState(.error(error.localizedDescription))
        }
    }
    // Observes the states of firebase authentication state
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
// Private helpers for logging properties
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
