//
//  ContentView.swift
//  ReceiptManagerIOSApp
//
//  Created by Bronsen Laine-Lasala on 10/17/25.
//

import SwiftUI
import FirebaseAuth

struct ContentView: View {
    @State private var hasCompletedLanding = false
    @State private var session = SessionViewModel()
    @State private var selectedTab: Tab = .scan
    
    enum Tab {
        case scan, receipts, stats
    }
    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView().controlSize(.large)

            case .signedOut, .error:
                SignInView(session: session)

            case .signedIn:
                if hasCompletedLanding {
                    mainTabs
                } else {
                    LandingView {
                        withAnimation(.easeInOut) {
                            hasCompletedLanding = true
                        }
                    }
                }
            }
        }
        .animation(.default, value: session.stateDisplayKey)
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScanView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                Task { await session.signOut() }
                            } label: {
                                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                    }
            }
            .tabItem {
                Label("Scan", systemImage: "camera.viewfinder")
            }
            .tag(Tab.scan)   // <-- important

            NavigationStack {
                ReceiptsView(selectedTab: $selectedTab)
            }
            .tabItem {
                Label("Receipts", systemImage: "doc.text.magnifyingglass")
            }
            .tag(Tab.receipts)  // <-- important

            NavigationStack {
                StatisticsView()
            }
            .tabItem {
                Label("Stats", systemImage: "chart.bar")
            }
            .tag(Tab.stats)   // <-- important
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


private struct LandingView: View {
    var onContinue: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "creditcard.viewfinder")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 140)
                        .foregroundStyle(.tint)

                    Text("Receipt Manager")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Capture, store, and analyze your receipts. Keep track of expenses effortlessly for individuals and teams.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    FeatureRow(icon: "camera.viewfinder",
                               title: "Scan Receipts",
                               subtitle: "Use your iPhone camera to capture paper receipts.")
                    FeatureRow(icon: "tray.full",
                               title: "Store Securely",
                               subtitle: "Save receipts to your account for easy access.")
                    FeatureRow(icon: "chart.bar",
                               title: "View Insights",
                               subtitle: "Track spending over time and by merchant.")

                    Button(action: onContinue) {
                        Label("Get Started", systemImage: "arrow.right.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle("Welcome")
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

#Preview {
    ContentView()
}
