# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Storage AI is a macOS disk space analyzer application built with SwiftUI. It scans the file system, categorizes files by type, and optionally uses local Ollama LLM for AI-powered cleanup recommendations. The app runs as both a windowed application and a menu bar extra.

## Build Commands

```bash
# Build release version
swift build -c release

# Build debug version
swift build

# Create DMG installer (requires release build first)
./scripts/create-dmg.sh
```

The release binary is output to `.build/release/StorageAI`.

## Architecture

### Core Data Flow

1. **AppState** (`Models/AppState.swift`) - Central observable state managing settings, appearance preferences, and the scan service
2. **ScanService** (`Services/ScanService.swift`) - Orchestrates scanning, manages scan lifecycle, and publishes results
3. **FileIndexer** (`Services/FileIndexer.swift`) - Performs the actual file system traversal with cooperative cancellation
4. **ScanDataStore** (`Services/ScanDataStore.swift`) - Actor-based persistence layer caching scan results to JSON

### File Classification

`StorageClassifier` in `FileIndexer.swift` categorizes files into six `StorageCategory` types based on path patterns and extensions:
- **applications**: /Applications, .app bundles
- **documents**: ~/Documents, ~/Desktop, ~/Downloads
- **media**: ~/Movies, ~/Music, ~/Pictures, media file extensions
- **system**: /System, /Library, /usr, /bin
- **libraries**: ~/Library (caches, app support, containers, logs)
- **other**: Everything else

### Key Services

- **OllamaClient** (`Services/OllamaClient.swift`) - HTTP client for local Ollama LLM integration (default: llama3.2 on localhost:11434)
- **CleanupService** (`Services/CleanupService.swift`) - Identifies cleanup targets (caches, logs, Xcode data, etc.) with safe/aggressive scopes

### View Structure

- **RootView** → OnboardingFlow or DashboardView based on `didCompleteOnboarding`
- **DashboardView** - Main scanner interface with category breakdown
- **CategoryDetailView** / **AppDetailView** - Drill-down views for files
- **CleanupView** - Cleanup target selection and execution
- **SettingsView** - App preferences and Ollama configuration
- **MenuBarView** - Menu bar extra showing disk usage summary

### Environment Values

Custom environment keys defined in `Theme.swift`:
- `\.accentTheme` - Current color theme accent
- `\.fontScale` - Font size scaling factor

## Requirements

- macOS 14.0+ (Sonoma)
- Swift 5.9+
- Optional: Ollama installed locally for AI features

## Key Patterns

- **Combine**: AppState forwards changes from nested ObservableObjects via `objectWillChange` sink
- **Swift Concurrency**: File scanning uses `Task.detached(priority: .utility)` for background work
- **Cooperative Cancellation**: `CancellationToken` class for thread-safe scan cancellation
- **Actor Isolation**: `ScanDataStore` is an actor for thread-safe cache operations
- **@MainActor**: UI-bound classes (AppState, ScanService) are MainActor-isolated
