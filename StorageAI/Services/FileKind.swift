import SwiftUI

enum FileKind: String, CaseIterable {
    case image, video, audio, code, archive, document, application, folder, other

    var label: String {
        switch self {
        case .image: return "Images"
        case .video: return "Video"
        case .audio: return "Audio"
        case .code: return "Code"
        case .archive: return "Archives"
        case .document: return "Documents"
        case .application: return "Apps"
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
        case .folder: return Color.secondary.opacity(0.5)
        case .other: return .gray
        }
    }

    private static let map: [String: FileKind] = {
        var m: [String: FileKind] = [:]
        for e in ["jpg","jpeg","png","gif","heic","heif","raw","tiff","tif","bmp","webp","svg","icns"] { m[e] = .image }
        for e in ["mp4","mov","avi","mkv","m4v","webm","mpg","mpeg","wmv","flv"] { m[e] = .video }
        for e in ["mp3","aac","flac","wav","m4a","aiff","ogg","alac"] { m[e] = .audio }
        for e in ["swift","m","mm","h","hpp","c","cc","cpp","py","js","ts","jsx","tsx","java","kt","go","rs","rb","php","cs","json","xml","yml","yaml","sh","sql"] { m[e] = .code }
        for e in ["zip","gz","tar","tgz","bz2","xz","7z","rar","dmg","pkg","iso"] { m[e] = .archive }
        for e in ["pdf","doc","docx","xls","xlsx","ppt","pptx","txt","md","rtf","pages","numbers","key","csv","epub"] { m[e] = .document }
        for e in ["app","ipa","apk"] { m[e] = .application }
        return m
    }()

    static func forExtension(_ ext: String) -> FileKind {
        map[ext.lowercased()] ?? .other
    }
}
