import SwiftUI

enum FileKind: String, CaseIterable {
    case image, video, audio, code, archive, document, application, design, data, diskImage, font, folder, other

    var label: String {
        switch self {
        case .image: return "Images"
        case .video: return "Video"
        case .audio: return "Audio"
        case .code: return "Code"
        case .archive: return "Archives"
        case .document: return "Documents"
        case .application: return "Apps"
        case .design: return "Design"
        case .data: return "Data"
        case .diskImage: return "Disk Images"
        case .font: return "Fonts"
        case .folder: return "Folders"
        case .other: return "Other"
        }
    }

    var color: Color {
        switch self {
        case .image: return .purple
        case .video: return .pink
        case .audio: return .orange
        case .code: return .blue
        case .archive: return .brown
        case .document: return .teal
        case .application: return .green
        case .design: return .mint
        case .data: return .indigo
        case .diskImage: return .red
        case .font: return .yellow
        case .folder: return Color.secondary.opacity(0.5)
        case .other: return .gray
        }
    }

    private static let map: [String: FileKind] = {
        var m: [String: FileKind] = [:]
        for e in ["jpg","jpeg","png","gif","heic","heif","raw","tiff","tif","bmp","webp","svg","icns"] { m[e] = .image }
        for e in ["mp4","mov","avi","mkv","m4v","webm","mpg","mpeg","wmv","flv"] { m[e] = .video }
        for e in ["mp3","aac","flac","wav","m4a","aiff","ogg","alac"] { m[e] = .audio }
        for e in ["swift","m","mm","h","hpp","c","cc","cpp","py","js","ts","jsx","tsx","java","kt","go","rs","rb","php","cs","xml","yml","yaml","sh","sql"] { m[e] = .code }
        for e in ["zip","gz","tar","tgz","bz2","xz","7z","rar","pkg"] { m[e] = .archive }
        for e in ["pdf","doc","docx","xls","xlsx","ppt","pptx","txt","md","rtf","pages","numbers","key","epub"] { m[e] = .document }
        for e in ["app","ipa","apk"] { m[e] = .application }
        for e in ["psd","psb","ai","sketch","fig","xd","afdesign","afphoto","blend","aseprite"] { m[e] = .design }
        for e in ["json","csv","sqlite","sqlite3","db","realm","parquet","arrow","mdb","accdb","plist","log"] { m[e] = .data }
        for e in ["dmg","iso","img","vmdk","vdi","qcow2","ova","sparseimage","sparsebundle"] { m[e] = .diskImage }
        for e in ["ttf","otf","ttc","woff","woff2"] { m[e] = .font }
        return m
    }()

    static func forExtension(_ ext: String) -> FileKind {
        map[ext.lowercased()] ?? .other
    }
}

/// Deterministic, dark-canvas-friendly hues for FOLDER tiles in the treemap. Hashing the folder
/// NAME (not path) keeps a given folder the same color everywhere it appears (every node_modules
/// looks alike), and the muted brightness keeps file-kind colors and white labels readable on top.
enum FolderPalette {
    static let colors: [Color] = [
        Color(hue: 0.60, saturation: 0.45, brightness: 0.45),  // steel blue
        Color(hue: 0.52, saturation: 0.45, brightness: 0.42),  // teal
        Color(hue: 0.42, saturation: 0.40, brightness: 0.42),  // sea green
        Color(hue: 0.33, saturation: 0.38, brightness: 0.40),  // moss
        Color(hue: 0.16, saturation: 0.45, brightness: 0.46),  // ochre
        Color(hue: 0.08, saturation: 0.48, brightness: 0.48),  // terracotta
        Color(hue: 0.98, saturation: 0.40, brightness: 0.46),  // rose
        Color(hue: 0.88, saturation: 0.38, brightness: 0.44),  // plum
        Color(hue: 0.76, saturation: 0.40, brightness: 0.46),  // violet
        Color(hue: 0.68, saturation: 0.42, brightness: 0.45),  // indigo
        Color(hue: 0.55, saturation: 0.30, brightness: 0.38),  // slate
        Color(hue: 0.25, saturation: 0.30, brightness: 0.40)   // olive
    ]

    static func color(forName name: String) -> Color {
        colors[Int(fnv1a(name) % UInt64(colors.count))]
    }

    /// FNV-1a — stable across launches (String.hashValue is seeded per-process, which would
    /// reshuffle every folder's color on each run).
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h
    }
}
