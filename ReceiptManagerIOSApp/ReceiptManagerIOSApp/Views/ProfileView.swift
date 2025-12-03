import SwiftUI
import FirebaseAuth

struct ProfileView: View {
    let session: SessionViewModel

    var body: some View {
        VStack(spacing: 16) {
            if let user = Auth.auth().currentUser {
                Text("Signed in as")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(user.email ?? "No email")
                    .font(.headline)
            } else {
                Text("Not signed in")
                    .font(.headline)
            }

            Button {
                Task { await session.signOut() }
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)

            Spacer()
        }
        .padding()
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    ProfileView(session: SessionViewModel())
}
