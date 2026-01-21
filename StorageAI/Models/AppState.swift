import SwiftUI
import Combine

// MARK: - Appearance Mode
enum AppearanceMode: String, Codable, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

// MARK: - Font Size
enum FontSize: String, Codable, CaseIterable {
    case small = "Small"
    case medium = "Medium"
    case large = "Large"
    
    var scale: CGFloat {
        switch self {
        case .small: return 0.85
        case .medium: return 1.0
        case .large: return 1.15
        }
    }
    
    var displayPercentage: String {
        switch self {
        case .small: return "85%"
        case .medium: return "100%"
        case .large: return "115%"
        }
    }
}

// MARK: - Color Theme
enum ColorTheme: String, Codable, CaseIterable {
    case blue = "Blue"
    case purple = "Purple"
    case pink = "Pink"
    case orange = "Orange"
    case green = "Green"
    case cyan = "Cyan"
    
    var accentColor: Color {
        switch self {
        case .blue: return .blue
        case .purple: return Color(red: 0.6, green: 0.4, blue: 0.9)
        case .pink: return .pink
        case .orange: return .orange
        case .green: return Color(red: 0.3, green: 0.7, blue: 0.4)
        case .cyan: return .cyan
        }
    }
    
    var previewGradient: [Color] {
        switch self {
        case .blue: return [.blue, .cyan]
        case .purple: return [Color(red: 0.6, green: 0.4, blue: 0.9), .purple]
        case .pink: return [.pink, .red]
        case .orange: return [.orange, .yellow]
        case .green: return [Color(red: 0.3, green: 0.7, blue: 0.4), .mint]
        case .cyan: return [.cyan, .teal]
        }
    }
}

// MARK: - App State
@MainActor
final class AppState: ObservableObject {
    @AppStorage("didCompleteOnboarding") var didCompleteOnboarding = false
    @AppStorage("appearanceMode") var appearanceMode: AppearanceMode = .system
    @AppStorage("colorTheme") var colorTheme: ColorTheme = .blue
    @AppStorage("fontSize") var fontSize: FontSize = .medium
    @Published var settings = AppSettings()
    let scanService = ScanService()
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Forward changes from scanService to trigger UI updates
        scanService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
    
    var effectiveColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - App Settings
struct AppSettings: Codable, Equatable {
    var includeSystem = false
    var includeHidden = false
    var excludedPaths: [String] = []
    var ollamaEnabled = true
}

// MARK: - AppStorage Extensions
extension AppStorage where Value == AppearanceMode {
    init(wrappedValue: AppearanceMode, _ key: String) {
        self.init(wrappedValue: wrappedValue, key, store: .standard)
    }
}

extension AppStorage where Value == ColorTheme {
    init(wrappedValue: ColorTheme, _ key: String) {
        self.init(wrappedValue: wrappedValue, key, store: .standard)
    }
}

extension AppStorage where Value == FontSize {
    init(wrappedValue: FontSize, _ key: String) {
        self.init(wrappedValue: wrappedValue, key, store: .standard)
    }
}
