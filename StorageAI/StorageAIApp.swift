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
        
        // Add developer directories
        let developerPaths = ["/opt/homebrew", "/usr/local", "/opt/local"]
        for path in developerPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                roots.append(url)
            }
        }
        
        if appState.settings.includeSystem {
            roots.append(URL(fileURLWithPath: "/System"))
            roots.append(URL(fileURLWithPath: "/Library"))
            roots.append(URL(fileURLWithPath: "/private/var"))
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
    
    private let labelWidth: CGFloat = 70
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Disk Storage Card - Clickable
            MenuBarClickableSection {
                openApp()
            } content: {
                VStack(spacing: 12) {
                    // Header with disk name and usage
                    HStack {
                        Image(systemName: "internaldrive.fill")
                            .font(.system(size: 16))
                        
                        Text("Macintosh HD")
                            .font(.system(size: 13, weight: .semibold))
                        
                        Spacer()
                        
                        Text("\(Int(diskPercentage * 100))%")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(diskColor)
                    }
                    
                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.15))
                            
                            RoundedRectangle(cornerRadius: 4)
                                .fill(diskColor)
                                .frame(width: max(0, geo.size.width * diskPercentage))
                        }
                    }
                    .frame(height: 8)
                    
                    // Storage details - aligned rows
                    VStack(spacing: 6) {
                        storageRow(label: "Used", value: Formatters.bytes(appState.scanService.summary.diskInfo.usedSpace))
                        storageRow(label: "Available", value: Formatters.bytes(appState.scanService.summary.diskInfo.freeSpace), valueColor: Color(red: 0.2, green: 0.7, blue: 0.3))
                        storageRow(label: "Total", value: Formatters.bytes(appState.scanService.summary.diskInfo.totalSpace))
                    }
                    .font(.system(size: 12))
                }
            }
            .padding(12)
            
            Divider()
            
            // Last scan info - Clickable
            if appState.scanService.summary.totalBytes > 0 {
                MenuBarClickableSection {
                    openApp()
                } content: {
                    VStack(spacing: 6) {
                        storageRow(label: "Scanned", value: Formatters.bytes(appState.scanService.summary.totalBytes))
                        
                        if let lastScan = appState.scanService.lastScanDate {
                            storageRow(label: "Updated", value: Formatters.relativeDate(lastScan))
                        }
                    }
                    .font(.system(size: 12))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                
                Divider()
            }
            
            // Menu Actions
            VStack(spacing: 0) {
                MenuBarMenuItem(title: "Open Storage AI", icon: "macwindow") {
                    openApp()
                }
                
                MenuBarMenuItem(
                    title: appState.scanService.isScanning ? "Scanning..." : appState.scanService.scanButtonTitle,
                    icon: appState.scanService.isScanning ? "hourglass" : "arrow.triangle.2.circlepath",
                    isDisabled: appState.scanService.isScanning
                ) {
                    startScan()
                }
                
                Divider()
                    .padding(.vertical, 4)
                
                MenuBarMenuItem(title: "Quit", icon: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 220)
    }
    
    private func storageRow(label: String, value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Text(label)
                .frame(width: labelWidth, alignment: .leading)
            Text(value)
                .fontWeight(.semibold)
                .foregroundColor(valueColor)
            Spacer()
        }
    }
    
    private var diskPercentage: CGFloat {
        let total = appState.scanService.summary.diskInfo.totalSpace
        let used = appState.scanService.summary.diskInfo.usedSpace
        guard total > 0 else { return 0 }
        return min(1.0, CGFloat(used) / CGFloat(total))
    }
    
    private var diskColor: Color {
        if diskPercentage > 0.9 { return .red }
        if diskPercentage > 0.75 { return .orange }
        return .blue
    }
    
    private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    private func startScan() {
        var roots = [
            FileManager.default.homeDirectoryForCurrentUser,
            URL(fileURLWithPath: "/Applications")
        ]
        
        // Add developer directories
        let developerPaths = ["/opt/homebrew", "/usr/local", "/opt/local"]
        for path in developerPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                roots.append(url)
            }
        }
        
        if appState.settings.includeSystem {
            roots.append(URL(fileURLWithPath: "/System"))
            roots.append(URL(fileURLWithPath: "/Library"))
            roots.append(URL(fileURLWithPath: "/private/var"))
        }
        
        appState.scanService.startScan(settings: appState.settings, roots: roots)
    }
}

// MARK: - Clickable Section
struct MenuBarClickableSection<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            content
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
                .padding(-8)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Menu Bar Menu Item
struct MenuBarMenuItem: View {
    let title: String
    let icon: String
    var isDisabled: Bool = false
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                
                Text(title)
                    .font(.system(size: 13))
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered && !isDisabled ? Color.accentColor : Color.clear)
            )
            .foregroundColor(isHovered && !isDisabled ? .white : (isDisabled ? .secondary : .primary))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            isHovered = hovering
        }
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
