import Foundation
import FirebaseAuth
@preconcurrency import GoogleSignIn


public struct User: Sendable, Equatable {
    public let uid: String
    public let email: String?

    public init(uid: String, email: String?) {
        self.uid = uid
        self.email = email
    }
}

actor AuthService {
    static nonisolated let shared = AuthService()

    nonisolated var currentUser: User? {
        if let fb = Auth.auth().currentUser {
            return User(uid: fb.uid, email: fb.email)
        }
        return nil
    }

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

    // Google sign-in through Firebase
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

    func signOut() async throws {
        try Auth.auth().signOut()
    }

    nonisolated func authStateChanges() -> AsyncStream<User?> {
        AsyncStream { continuation in
            let handle = Auth.auth().addStateDidChangeListener { _, fbUser in
                if let fbUser = fbUser {
                    continuation.yield(User(uid: fbUser.uid, email: fbUser.email))
                } else {
                    continuation.yield(nil)
                }
            }
            continuation.onTermination = { _ in
                Auth.auth().removeStateDidChangeListener(handle)
            }
        }
    }
}
