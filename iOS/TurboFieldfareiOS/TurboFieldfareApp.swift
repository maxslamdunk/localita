import SwiftUI
import UIKit

@main
struct TurboFieldfareiOSApp: App {
    var body: some Scene {
        WindowGroup {
            HarnessView()
                .onAppear {
                    // A decode run is minutes long and the screen must stay on:
                    // a locked phone suspends the app mid-generation and the
                    // run is lost.
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}

struct HarnessView: View {
    @StateObject private var harness = Harness()
    /// Set by `--autorun`, so `devicectl device process launch` can drive a run
    /// without anyone touching the screen.
    private let autorun = ProcessInfo.processInfo.arguments.contains("--autorun")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TurboFieldfare").font(.headline)
                Spacer()
                if harness.running {
                    ProgressView()
                } else {
                    Button("Run") {
                        Task { await harness.run() }
                    }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(harness.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                }
                .onChange(of: harness.lines.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
        .padding()
        .task {
            if autorun { await harness.run() }
        }
    }
}
