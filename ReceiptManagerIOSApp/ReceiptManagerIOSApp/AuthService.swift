import Foundation
import FirebaseAuth
@preconcurrency import GoogleSignIn

// A representation of an authenticated user in the app
public struct User: Sendable, Equatable {
    // Unique identifier for the user provided by firebase
    public let uid: String
    // Optional email address associated with the account
    public let email: String?
    // Creates new 'User' value
    public init(uid: String, email: String?) {
        self.uid = uid
        self.email = email
    }
}

// A concurrent authentication service using FireBase Auth
actor AuthService {
    // Global instance of AuthService
    static nonisolated let shared = AuthService()
    // The current signed-in user
    nonisolated var currentUser: User? {
        if let fb = Auth.auth().currentUser {
            return User(uid: fb.uid, email: fb.email)
        }
        return nil
    }
    // Creates a new user account with email and password
    func createUser(email: String, password: String) async throws -> User {
        try await withCheckedThrowingContinuation { continuation in
            Auth.auth().createUser(withEmail: email, password: password) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let user = result?.user {
                    continuation.resume(returning: User(uid: user.uid, email: user.email))
                } else {
                    continuation.resume(throwing: NSError(domain: "AuthService",
                                                          code: -1,
                                                          userInfo: [NSLocalizedDescriptionKey: "Unknown createUser error"]))
                }
            }
        }
    }
    // Signs in an existing user with email and password
    func signIn(email: String, password: String) async throws -> User {
        try await withCheckedThrowingContinuation { continuation in
            Auth.auth().signIn(withEmail: email, password: password) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let user = result?.user {
                    continuation.resume(returning: User(uid: user.uid, email: user.email))
                } else {
                    continuation.resume(throwing: NSError(domain: "AuthService",
                                                          code: -1,
                                                          userInfo: [NSLocalizedDescriptionKey: "Unknown signIn error"]))
                }
            }
        }
    }

    // Signs in a user with Google credentials through Firebase
    func signInWithGoogle(idToken: String, accessToken: String) async throws -> User {
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        return try await withCheckedThrowingContinuation { continuation in
            Auth.auth().signIn(with: credential) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let user = result?.user {
                    continuation.resume(returning: User(uid: user.uid, email: user.email))
                } else {
                    continuation.resume(throwing: NSError(domain: "AuthService",
                                                          code: -1,
                                                          userInfo: [NSLocalizedDescriptionKey: "Unknown Google sign-in error"]))
                }
            }
        }
    }
    // Signs out the currently authenticated user
    func signOut() async throws {
        try Auth.auth().signOut()
    }
    // A stream of authentication state changes
    nonisolated func authStateChanges() -> AsyncStream<User?> {
        AsyncStream { continuation in
            let handle = Auth.auth().addStateDidChangeListener { _, fbUser in
                if let fbUser = fbUser {
                    continuation.yield(User(uid: fbUser.uid, email: fbUser.email))
                } else {
                    continuation.yield(nil)
                }
            }
            // Clean up listener when the stream is finished or cancelled
            continuation.onTermination = { _ in
                Auth.auth().removeStateDidChangeListener(handle)
            }
        }
    }
}
