<div align="center">

# Storage AI

### Intelligent Disk Space Analyzer for macOS

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue?style=for-the-badge&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-Native-purple?style=for-the-badge&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

<br/>

**Storage AI** is a beautiful, native macOS app that helps you understand and reclaim your disk space. Powered by intelligent file categorization and optional local AI recommendations via Ollama.

[Download Latest Release](../../releases/latest) · [Report Bug](../../issues) · [Request Feature](../../issues)

<br/>

---

</div>

## ✨ Features

<table>
<tr>
<td width="50%">

### 🔍 Smart Scanning
- **Lightning-fast** file system analysis
- **Intelligent categorization** into 6 categories
- **Real-time progress** with live updates
- **Resume capability** - pause and continue anytime

</td>
<td width="50%">

### 🎨 Beautiful Interface
- **Native SwiftUI** design
- **6 accent color themes** to match your style
- **Light/Dark mode** support
- **Adjustable font sizes** for accessibility

</td>
</tr>
<tr>
<td width="50%">

### 🧹 Cleanup Tools
- **Safe cleanup** recommendations
- **Cache cleaning** for apps and system
- **Xcode cleanup** (derived data, archives)
- **Log file** management

</td>
<td width="50%">

### 🤖 AI-Powered (Optional)
- **Local Ollama** integration
- **Smart recommendations** for what to delete
- **Privacy-first** - all processing stays on device
- **Works offline** - no cloud dependency

</td>
</tr>
</table>

## 📸 Screenshots

<div align="center">
<i>Coming soon - beautiful screenshots of Storage AI in action</i>
</div>

## 🚀 Installation

### Download DMG (Recommended)

1. Download the latest DMG from [Releases](../../releases/latest)
2. Open the DMG file
3. Drag **Storage AI** to your Applications folder
4. Launch from Applications or Spotlight

### Build from Source

```bash
# Clone the repository
git clone https://github.com/yourusername/storage-ai.git
cd storage-ai

# Build release version
swift build -c release

# Or create a DMG installer
./scripts/create-dmg.sh
```

## 📖 Usage

### First Launch

1. **Grant Permissions** - Storage AI needs Full Disk Access to scan your files
2. **Start Scan** - Click the scan button to analyze your disk
3. **Explore Categories** - Click any category to see detailed file lists
4. **Clean Up** - Use the cleanup tools to reclaim space

### File Categories

| Category | Description |
|----------|-------------|
| 📱 **Applications** | Apps in /Applications and .app bundles |
| 📄 **Documents** | Files in Documents, Desktop, Downloads |
| 🎬 **Media** | Movies, Music, Pictures, and media files |
| ⚙️ **System** | System files, libraries, and binaries |
| 📚 **Libraries** | App caches, containers, and support files |
| 📦 **Other** | Everything else |

### AI Recommendations (Optional)

To enable AI-powered recommendations:

1. Install [Ollama](https://ollama.ai) on your Mac
2. Pull a model: `ollama pull llama3.2`
3. Enable Ollama in Storage AI Settings
4. Get intelligent cleanup suggestions

## 🛠 Requirements

- **macOS 14.0+** (Sonoma or later)
- **Apple Silicon or Intel** Mac
- **Full Disk Access** permission
- **Optional:** Ollama for AI features

## 🏗 Architecture

```
StorageAI/
├── Models/
│   ├── AppState.swift        # Central state management
│   └── StorageModels.swift   # Data models
├── Services/
│   ├── ScanService.swift     # Scan orchestration
│   ├── FileIndexer.swift     # File system traversal
│   ├── ScanDataStore.swift   # Persistence layer
│   ├── CleanupService.swift  # Cleanup operations
│   └── OllamaClient.swift    # AI integration
└── Views/
    ├── DashboardView.swift   # Main interface
    ├── CategoryDetailView.swift
    ├── CleanupView.swift
    └── SettingsView.swift
```

### Key Technologies

- **SwiftUI** - Modern declarative UI
- **Combine** - Reactive state management
- **Swift Concurrency** - Async/await for smooth performance
- **Actor Isolation** - Thread-safe data operations

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Built with [SwiftUI](https://developer.apple.com/xcode/swiftui/)
- AI powered by [Ollama](https://ollama.ai)
- Icons from [SF Symbols](https://developer.apple.com/sf-symbols/)

---

<div align="center">

**Made with ❤️ for macOS**

⭐ Star this repo if you find it useful!

</div>
