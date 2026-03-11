import SwiftUI

/// App Icon Generator for Development
/// This creates a simple app icon using SF Symbols for testing
/// For production, use a proper icon design tool

struct AppIconGenerator: View {
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color.blue, Color.blue.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            // Icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 180))
                .foregroundStyle(.white)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Better icon concept with layered design
struct AppIconGeneratorEnhanced: View {
    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [
                    Color(red: 0.0, green: 0.48, blue: 1.0),  // iOS Blue
                    Color(red: 0.0, green: 0.38, blue: 0.85)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            // Subtle grid pattern in background
            VStack(spacing: 40) {
                ForEach(0..<5) { _ in
                    HStack(spacing: 40) {
                        ForEach(0..<5) { _ in
                            Circle()
                                .fill(.white.opacity(0.03))
                                .frame(width: 30, height: 30)
                        }
                    }
                }
            }
            
            // Main icon - checkmark with calendar
            VStack(spacing: -30) {
                Image(systemName: "calendar")
                    .font(.system(size: 140, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 180, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
            }
            .offset(y: 20)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Minimal clean design (RECOMMENDED)
struct AppIconGeneratorMinimal: View {
    var body: some View {
        ZStack {
            // Clean blue background
            Color(red: 0.0, green: 0.48, blue: 1.0)
            
            // Circle badge with checkmark
            Circle()
                .fill(.white)
                .frame(width: 650, height: 650)
                .shadow(color: .black.opacity(0.15), radius: 30, y: 10)
            
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.0, green: 0.48, blue: 1.0),
                            Color(red: 0.0, green: 0.38, blue: 0.85)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 600, height: 600)
            
            Image(systemName: "checkmark")
                .font(.system(size: 280, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 1024, height: 1024)
    }
}

// MARK: - Preview for all designs

#Preview("Simple Checkmark") {
    AppIconGenerator()
}

#Preview("Enhanced with Calendar") {
    AppIconGeneratorEnhanced()
}

#Preview("Minimal Clean (Recommended)") {
    AppIconGeneratorMinimal()
}

// MARK: - All Sizes Preview

struct AppIconPreviewGrid: View {
    let design: AnyView
    
    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                Text("App Icon Preview - All Sizes")
                    .font(.title.bold())
                    .padding()
                
                // Large preview
                VStack(spacing: 10) {
                    Text("App Store (1024×1024)")
                        .font(.headline)
                    design
                        .frame(width: 512, height: 512)
                        .cornerRadius(114) // iOS corner radius at this scale
                        .shadow(radius: 10)
                }
                
                // iPhone sizes
                VStack(spacing: 20) {
                    Text("iPhone Sizes")
                        .font(.title2.bold())
                    
                    HStack(spacing: 30) {
                        iconPreview(size: 180, label: "60pt @3x")
                        iconPreview(size: 120, label: "60pt @2x")
                    }
                }
                
                // iPad sizes
                VStack(spacing: 20) {
                    Text("iPad Sizes")
                        .font(.title2.bold())
                    
                    HStack(spacing: 30) {
                        iconPreview(size: 167, label: "83.5pt @2x")
                        iconPreview(size: 152, label: "76pt @2x")
                        iconPreview(size: 76, label: "76pt @1x")
                    }
                }
                
                // Small sizes
                VStack(spacing: 20) {
                    Text("Small Sizes (Settings, Spotlight)")
                        .font(.title2.bold())
                    
                    HStack(spacing: 20) {
                        iconPreview(size: 60, label: "20pt @3x")
                        iconPreview(size: 58, label: "29pt @2x")
                        iconPreview(size: 40, label: "20pt @2x")
                        iconPreview(size: 29, label: "29pt @1x")
                    }
                }
            }
            .padding()
        }
    }
    
    private func iconPreview(size: CGFloat, label: String) -> some View {
        VStack(spacing: 8) {
            design
                .frame(width: size, height: size)
                .cornerRadius(size * 0.2237) // iOS corner radius formula
                .shadow(radius: 3)
            
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text("\(Int(size))×\(Int(size))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

#Preview("All Sizes - Minimal") {
    AppIconPreviewGrid(design: AnyView(AppIconGeneratorMinimal()))
}

// MARK: - Usage Instructions

/*
 HOW TO USE:
 
 1. Open this file in Xcode
 2. Show Canvas (Editor → Canvas or ⌥⌘↩)
 3. Select a preview (e.g., "Minimal Clean (Recommended)")
 4. Right-click the canvas → "Show SwiftUI Inspector"
 5. Take a screenshot or export
 
 EXPORT OPTIONS:
 
 Option A: Screenshot
 - Press ⇧⌘5 to open Screenshot tool
 - Select area around the 1024×1024 preview
 - Save as PNG
 
 Option B: Debug Render
 - Debug → Render as Image
 - Save to desktop
 
 Option C: Use Simulator
 - Build and run in simulator
 - Navigate to the preview
 - Screenshot (⌘S)
 
 THEN:
 
 1. Go to https://appicon.co
 2. Upload your 1024×1024 image
 3. Download the generated AppIcon.appiconset
 4. In Xcode: Assets.xcassets → AppIcon → Drag & drop the .appiconset
 
 DONE! Your app now has a professional icon. 🎉
 */
