import SwiftUI

@main
struct StorageAIApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(appState.effectiveColorScheme)
                .tint(appState.colorTheme.accentColor)
                .onAppear {
                    // Connect appState to delegate for termination handling
                    appDelegate.appState = appState
                }
        }
        .windowStyle(.automatic)
        .windowResizability(.contentSize)
        .defaultSize(width: 1100, height: 750)
        .commands {
            CommandGroup(replacing: .newItem) { }
            
            CommandGroup(after: .appInfo) {
                Button("Reset Onboarding") {
                    appState.didCompleteOnboarding = false
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])
            }
            
            CommandGroup(after: .sidebar) {
                Button("Start Scan") {
                    startScan()
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])
            }
        }
        
        // Menu Bar Extra
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: "externaldrive")
        }
    }
    
    private func startScan() {
        var roots = [
            FileManager.default.homeDirectoryForCurrentUser,
            URL(fileURLWithPath: "/Applications")
        ]
        
        if appState.settings.includeSystem {
            roots.append(URL(fileURLWithPath: "/System"))
            roots.append(URL(fileURLWithPath: "/Library"))
        }
        
        appState.scanService.startScan(settings: appState.settings, roots: roots)
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Keep app running in menu bar when window is closed
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Save scan progress when app is about to quit
        if let scanService = appState?.scanService, scanService.summary.totalBytes > 0 {
            // Perform synchronous save since we're terminating
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await MainActor.run {
                    scanService.saveCurrentProgress()
                }
                // Give a moment for the save to complete
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1.0)
        }
    }
}

// MARK: - Menu Bar View
struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "externaldrive")
                    .font(.title3)
                Text("Storage AI")
                    .font(.headline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            Divider()
            
            // Disk Info
            VStack(alignment: .leading, spacing: 6) {
                Text("Disk Storage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                HStack {
                    Text("Used:")
                    Spacer()
                    Text(Formatters.bytes(appState.scanService.summary.diskInfo.usedSpace))
                        .fontWeight(.medium)
                }
                .font(.caption)
                
                HStack {
                    Text("Available:")
                    Spacer()
                    Text(Formatters.bytes(appState.scanService.summary.diskInfo.freeSpace))
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                }
                .font(.caption)
                
                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.2))
                        
                        RoundedRectangle(cornerRadius: 2)
                            .fill(diskColor)
                            .frame(width: geo.size.width * diskPercentage)
                    }
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            Divider()
            
            // Scanned Data Summary
            if appState.scanService.summary.totalBytes > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last Scan")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    HStack {
                        Text("Scanned:")
                        Spacer()
                        Text(Formatters.bytes(appState.scanService.summary.totalBytes))
                            .fontWeight(.medium)
                    }
                    .font(.caption)
                    
                    if let lastScan = appState.scanService.lastScanDate {
                        HStack {
                            Text("Date:")
                            Spacer()
                            Text(Formatters.relativeDate(lastScan))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                
                Divider()
            }
            
            // Actions
            Button {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.isVisible == false }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    // Open new window if none exists
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                }
            } label: {
                Label("Open Storage AI", systemImage: "macwindow")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            
            Button {
                startScan()
            } label: {
                Label(appState.scanService.isScanning ? "Scanning..." : "Start Scan", systemImage: "arrow.clockwise")
            }
            .disabled(appState.scanService.isScanning)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            
            Divider()
            
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Storage AI", systemImage: "power")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 220)
    }
    
    private var diskPercentage: CGFloat {
        let total = appState.scanService.summary.diskInfo.totalSpace
        let used = appState.scanService.summary.diskInfo.usedSpace
        guard total > 0 else { return 0 }
        return CGFloat(used) / CGFloat(total)
    }
    
    private var diskColor: Color {
        if diskPercentage > 0.9 { return .red }
        if diskPercentage > 0.75 { return .orange }
        return .blue
    }
    
    private func startScan() {
        var roots = [
            FileManager.default.homeDirectoryForCurrentUser,
            URL(fileURLWithPath: "/Applications")
        ]
        
        if appState.settings.includeSystem {
            roots.append(URL(fileURLWithPath: "/System"))
            roots.append(URL(fileURLWithPath: "/Library"))
        }
        
        appState.scanService.startScan(settings: appState.settings, roots: roots)
    }
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var currentAccentColor: Color = ColorTheme.blue.accentColor
    @State private var currentFontScale: CGFloat = FontSize.medium.scale

    var body: some View {
        ZStack {
            // Background with subtle gradient for glassmorphism
            backgroundView

            if appState.didCompleteOnboarding {
                DashboardView()
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            } else {
                OnboardingFlow()
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .frame(minWidth: 950, minHeight: 600)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.didCompleteOnboarding)
        .environment(\.accentTheme, currentAccentColor)
        .environment(\.fontScale, currentFontScale)
        .onAppear {
            currentAccentColor = appState.colorTheme.accentColor
            currentFontScale = appState.fontSize.scale
        }
        .onChange(of: appState.colorTheme) { _, newTheme in
            currentAccentColor = newTheme.accentColor
        }
        .onChange(of: appState.fontSize) { _, newSize in
            currentFontScale = newSize.scale
        }
    }

    private var backgroundView: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            RadialGradient(
                colors: [
                    currentAccentColor.opacity(colorScheme == .dark ? 0.08 : 0.05),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 400
            )

            RadialGradient(
                colors: [
                    currentAccentColor.opacity(colorScheme == .dark ? 0.06 : 0.04),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 300
            )
        }
        .ignoresSafeArea()
    }
}

#Preview("App") {
    RootView()
        .environmentObject(AppState())
        .environment(\.accentTheme, .blue)
}
