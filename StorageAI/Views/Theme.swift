import SwiftUI

// MARK: - Theme Environment Key
struct AccentColorKey: EnvironmentKey {
    static let defaultValue: Color = .blue
}

struct FontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var accentTheme: Color {
        get { self[AccentColorKey.self] }
        set { self[AccentColorKey.self] = newValue }
    }
    
    var fontScale: CGFloat {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

// MARK: - Scaled Font Modifier
struct ScaledFont: ViewModifier {
    @Environment(\.fontScale) private var fontScale
    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    
    func body(content: Content) -> some View {
        content.font(.system(size: baseSize * fontScale, weight: weight, design: design))
    }
}

extension View {
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(baseSize: size, weight: weight, design: design))
    }
}

// MARK: - Formatters
struct Formatters {
    static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    static func relativeDate(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    static func number(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
    
    static func percentage(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

// MARK: - Glassmorphism Card
struct GlassCard<Content: View>: View {
    let content: Content
    var padding: CGFloat = 16
    
    @Environment(\.colorScheme) private var colorScheme
    
    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 8, x: 0, y: 4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(colorScheme == .dark ? 0.15 : 0.5),
                                .white.opacity(colorScheme == .dark ? 0.05 : 0.2)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
    }
}

// MARK: - Legacy Card (for compatibility)
struct CardView<Content: View>: View {
    let content: Content
    var padding: CGFloat = 16
    
    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    
    var body: some View {
        GlassCard(padding: padding) {
            content
        }
    }
}

// MARK: - Stat Card
struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .blue
    
    @Environment(\.accentTheme) private var accentTheme
    @Environment(\.fontScale) private var fontScale
    
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18 * fontScale, weight: .medium))
                    .foregroundStyle(color == .blue ? accentTheme : color)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(value)
                        .font(.system(size: 22 * fontScale, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    
                    Text(title)
                        .font(.system(size: 12 * fontScale))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Donut Chart
struct DonutChart: View {
    let segments: [(color: Color, value: Double, label: String)]
    var innerRadiusRatio: CGFloat = 0.65
    var showLabels: Bool = true
    
    @Environment(\.colorScheme) private var colorScheme
    
    private var total: Double {
        segments.map(\.value).reduce(0, +)
    }
    
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            
            ZStack {
                // Background ring
                Circle()
                    .stroke(Color.secondary.opacity(0.1), lineWidth: size * 0.15)
                    .frame(width: size * 0.7, height: size * 0.7)
                
                // Segments
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    DonutSegment(
                        startAngle: startAngle(for: index),
                        endAngle: endAngle(for: index),
                        innerRadiusRatio: innerRadiusRatio
                    )
                    .fill(segment.color)
                }
                
                // Glass center
                if showLabels {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: size * innerRadiusRatio - 4, height: size * innerRadiusRatio - 4)
                    
                    VStack(spacing: 2) {
                        Text(Formatters.bytes(Int64(total)))
                            .font(.system(size: size * 0.1, weight: .semibold, design: .rounded))
                        Text("Total")
                            .font(.system(size: size * 0.045))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: size, height: size)
            .position(center)
        }
        .aspectRatio(1, contentMode: .fit)
        // The chart conveys categories by color only; expose a text breakdown so VoiceOver and
        // color-blind users get the same information.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage distribution")
        .accessibilityValue(accessibilityBreakdown)
    }

    private var accessibilityBreakdown: String {
        guard total > 0 else { return "No data" }
        return segments
            .filter { $0.value > 0 }
            .map { "\($0.label) \(Int(($0.value / total) * 100)) percent" }
            .joined(separator: ", ")
    }

    private func startAngle(for index: Int) -> Angle {
        let precedingTotal = segments.prefix(index).map(\.value).reduce(0, +)
        return .degrees(360 * precedingTotal / max(total, 1) - 90)
    }
    
    private func endAngle(for index: Int) -> Angle {
        let includingTotal = segments.prefix(index + 1).map(\.value).reduce(0, +)
        return .degrees(360 * includingTotal / max(total, 1) - 90)
    }
}

struct DonutSegment: Shape {
    var startAngle: Angle
    var endAngle: Angle
    var innerRadiusRatio: CGFloat
    
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(startAngle.degrees, endAngle.degrees) }
        set {
            startAngle = .degrees(newValue.first)
            endAngle = .degrees(newValue.second)
        }
    }
    
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let innerRadius = radius * innerRadiusRatio
        
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: endAngle, endAngle: startAngle, clockwise: true)
        path.closeSubpath()
        return path
    }
}

// MARK: - Storage Bar
struct StorageBar: View {
    let used: Int64
    let total: Int64
    var height: CGFloat = 8
    var showLabels: Bool = true
    var color: Color = .blue  // Default to blue, not accent
    
    @Environment(\.colorScheme) private var colorScheme
    
    private var percentage: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }
    
    private var barColor: Color {
        if percentage > 0.9 { return .red }
        if percentage > 0.75 { return .orange }
        return color
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background with glass effect
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(.ultraThinMaterial)
                    
                    // Used space
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(barColor)
                        .frame(width: geometry.size.width * CGFloat(percentage))
                        .animation(.spring(response: 0.5), value: percentage)
                }
            }
            .frame(height: height)
            
            if showLabels {
                HStack {
                    Text("\(Formatters.bytes(used)) used")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Formatters.bytes(total - used)) available")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }
}

// MARK: - Scanning Animation
struct ScanningIndicator: View {
    @State private var rotation: Double = 0
    @Environment(\.accentTheme) private var accentTheme
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(accentTheme.opacity(0.15), lineWidth: 3)
            
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(accentTheme, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(rotation))
            
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(accentTheme)
        }
        .frame(width: 44, height: 44)
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Progress Card
struct ScanProgressCard: View {
    let progress: ScanProgress
    @State private var dotCount = 0
    @Environment(\.accentTheme) private var accentTheme
    @Environment(\.fontScale) private var fontScale
    
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    
    private var dots: String {
        String(repeating: ".", count: dotCount % 4)
    }
    
    var body: some View {
        GlassCard {
            HStack(spacing: 14) {
                ScanningIndicator()
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 2) {
                        Text(progress.phase.rawValue)
                            .font(.system(size: 14 * fontScale, weight: .medium))
                        Text(dots)
                            .font(.system(size: 14 * fontScale, weight: .medium))
                            .frame(width: 16, alignment: .leading)
                    }
                    
                    Text(progress.currentPath.isEmpty ? "Initializing..." : progress.currentPath)
                        .font(.system(size: 12 * fontScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                Spacer()
                
                HStack(spacing: 16) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Formatters.number(progress.scannedFiles))
                            .font(.system(size: 14 * fontScale, weight: .semibold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("files")
                            .font(.system(size: 10 * fontScale))
                            .foregroundStyle(.secondary)
                    }
                    
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Formatters.bytes(progress.scannedBytes))
                            .font(.system(size: 14 * fontScale, weight: .semibold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("scanned")
                            .font(.system(size: 10 * fontScale))
                            .foregroundStyle(.secondary)
                    }
                    
                    // Time estimate
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(progress.formattedTimeRemaining)
                            .font(.system(size: 14 * fontScale, weight: .semibold, design: .rounded))
                            .foregroundStyle(accentTheme)
                            .contentTransition(.numericText())
                        Text("remaining")
                            .font(.system(size: 10 * fontScale))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            withAnimation {
                dotCount += 1
            }
        }
    }
}

// MARK: - Category Row
struct CategoryRow: View {
    let bucket: StorageBucket
    let totalBytes: Int64
    var fileCount: Int = 0
    
    @Environment(\.fontScale) private var fontScale
    
    private var percentage: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bucket.bytes) / Double(totalBytes) * 100
    }
    
    var body: some View {
        HStack(spacing: 10) {
            // Icon
            Image(systemName: bucket.category.icon)
                .font(.system(size: 14 * fontScale))
                .foregroundStyle(bucket.category.color)
                .frame(width: 28 * fontScale, height: 28 * fontScale)
                .background(bucket.category.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(bucket.category.displayName)
                        .font(.system(size: 14 * fontScale, weight: .medium))
                    
                    Spacer()
                    
                    Text(Formatters.bytes(bucket.bytes))
                        .font(.system(size: 12 * fontScale))
                        .foregroundStyle(.secondary)
                }
                
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.ultraThinMaterial)
                        
                        RoundedRectangle(cornerRadius: 2)
                            .fill(bucket.category.color)
                            .frame(width: geometry.size.width * CGFloat(percentage / 100))
                    }
                }
                .frame(height: 4)
            }
            
            Text(Formatters.percentage(percentage))
                .font(.system(size: 10 * fontScale))
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - App Row
struct AppRow: View {
    let app: AppEntry
    
    @Environment(\.fontScale) private var fontScale
    
    var body: some View {
        HStack(spacing: 10) {
            // App Icon
            if let icon = app.iconImage {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36 * fontScale, height: 36 * fontScale)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial)
                    .frame(width: 36 * fontScale, height: 36 * fontScale)
                    .overlay {
                        Image(systemName: "app")
                            .foregroundStyle(.secondary)
                    }
            }
            
            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 14 * fontScale, weight: .medium))
                
                Text("Bundle: \(Formatters.bytes(app.bundleSizeBytes))")
                    .font(.system(size: 10 * fontScale))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Text(Formatters.bytes(app.totalBytes))
                .font(.system(size: 14 * fontScale, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Empty State
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var action: (() -> Void)? = nil
    var actionTitle: String = "Get Started"
    
    @Environment(\.accentTheme) private var accentTheme
    @Environment(\.fontScale) private var fontScale
    
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 36 * fontScale))
                .foregroundStyle(.secondary)
            
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 14 * fontScale, weight: .medium))
                
                Text(message)
                    .font(.system(size: 12 * fontScale))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
            
            if let action {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .tint(accentTheme)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Section Header
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var action: (() -> Void)? = nil
    var actionTitle: String = "See All"
    
    @Environment(\.accentTheme) private var accentTheme
    @Environment(\.fontScale) private var fontScale
    
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14 * fontScale, weight: .semibold))
                
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12 * fontScale))
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            if let action {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.plain)
                .foregroundStyle(accentTheme)
                .font(.system(size: 12 * fontScale))
            }
        }
    }
}

// MARK: - Theme Picker
struct ThemePicker: View {
    @Binding var selectedTheme: ColorTheme

    var body: some View {
        HStack(spacing: 12) {
            ForEach(ColorTheme.allCases, id: \.self) { theme in
                Button {
                    selectedTheme = theme
                } label: {
                    ZStack {
                        Color.clear
                        Circle()
                            .fill(theme.accentColor)
                            .frame(width: 28, height: 28)
                            .overlay {
                                if selectedTheme == theme {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay {
                                Circle()
                                    .strokeBorder(.white.opacity(0.3), lineWidth: 2)
                            }
                            .shadow(color: theme.accentColor.opacity(0.4), radius: selectedTheme == theme ? 6 : 0)
                    }
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(.easeOut(duration: 0.15), value: selectedTheme)
            }
        }
    }
}

// MARK: - Font Size Picker
struct FontSizePicker: View {
    @Binding var selectedSize: FontSize

    var body: some View {
        HStack(spacing: 8) {
            ForEach(FontSize.allCases, id: \.self) { size in
                FontSizeButton(size: size, isSelected: selectedSize == size) {
                    selectedSize = size
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: selectedSize)
    }
}

struct FontSizeButton: View {
    let size: FontSize
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text("Aa")
                    .font(.system(size: 14 * size.scale, weight: .medium))
                Text(size.displayPercentage)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.secondary.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.primary.opacity(0.2) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
    }
}

// MARK: - Appearance Picker
struct AppearancePicker: View {
    @Binding var selectedMode: AppearanceMode

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                AppearanceButton(mode: mode, isSelected: selectedMode == mode) {
                    selectedMode = mode
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: selectedMode)
    }
}

struct AppearanceButton: View {
    let mode: AppearanceMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.system(size: 18))
                Text(mode.rawValue)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.secondary.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.primary.opacity(0.2) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
    }
}
