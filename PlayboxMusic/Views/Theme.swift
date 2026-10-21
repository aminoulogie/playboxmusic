import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

extension Color {
    /// Playbox green, used for accents, the play button glow and mix chips.
    static let brand = Color(red: 0.12, green: 0.84, blue: 0.38)
}

/// Colours of the three automation lanes in the mix editor.
enum MixColor {
    static let volume = Color(red: 0.36, green: 0.78, blue: 1.0)
    static let eq = Color(red: 0.98, green: 0.80, blue: 0.25)
    static let effects = Color(red: 0.90, green: 0.55, blue: 0.95)
}

/// Camelot key in a pastel pill coloured by its place on the wheel.
struct KeyBadge: View {
    let key: MusicalKey

    var body: some View {
        let hue = (0.5 - Double(key.camelotNumber) / 12).truncatingRemainder(dividingBy: 1)
        Text(key.camelot)
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.black.opacity(0.8))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color(hue: hue < 0 ? hue + 1 : hue, saturation: 0.42, brightness: 0.97),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityLabel("Key \(key.name), \(key.camelot)")
    }
}

/// Tempo, key and length for a downloaded song, as in Spotify's mix view.
struct TrackFacts: View {
    let track: Track
    @State private var analysis: TrackAnalysis?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(analysis?.bpm.map { "\(Int($0.rounded())) bpm" } ?? "– bpm")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(analysis?.bpm == nil ? 0.35 : 0.9))
            HStack(spacing: 6) {
                if let key = analysis?.key { KeyBadge(key: key) }
                Text(analysis.map { Self.format($0.duration) } ?? "")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .animation(.easeOut(duration: 0.25), value: analysis?.bpm)
        .task(id: track.id) { analysis = await TrackAnalyzer.shared.analysis(for: track.url) }
    }

    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Three bouncing bars marking the song that is playing.
struct PlayingBars: View {
    var active: Bool
    var color: Color = .brand

    var body: some View {
        TimelineView(.animation(paused: !active)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { bar in
                    let phase = time * (4.5 + Double(bar) * 1.9) + Double(bar) * 1.3
                    let level = active ? 0.3 + 0.7 * abs(sin(phase)) : 0.3
                    Capsule().fill(color).frame(width: 3, height: 14 * level)
                }
            }
            .frame(width: 15, height: 14, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// Round play button with a glowing green ring, like Spotify's mix playlists.
struct GlowPlayButton: View {
    let isPlaying: Bool
    var size: CGFloat = 56
    let action: () -> Void
    @State private var breathing = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.brand.opacity(0.45))
                    .frame(width: size + 16, height: size + 16)
                    .blur(radius: 10)
                    .scaleEffect(isPlaying && breathing ? 1.12 : 0.92)
                    .opacity(isPlaying ? 1 : 0.6)
                Circle()
                    .strokeBorder(Color.brand, lineWidth: 3)
                    .frame(width: size + 8, height: size + 8)
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.08)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                    .frame(width: size, height: size)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathing = true }
        }
    }
}

/// Rounded pill button used in chip rows (Mix, Edit, Sort…).
struct ChipLabel: View {
    let title: String
    var symbol: String?
    var selected = false
    var ring = false

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.subheadline.weight(.semibold)) }
            Text(title).font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(selected ? .black : .white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(selected ? Color.white : Color(white: 0.17), in: Capsule())
        .overlay {
            if ring {
                Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 2).padding(-3)
            }
        }
        .padding(ring ? 3 : 0)
        .contentShape(Capsule())
    }
}

/// Picks a rich background colour from album artwork.
enum ArtworkPalette {
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    static func color(of image: UIImage) -> Color? {
        guard let input = CIImage(image: image) else { return nil }
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = input.extent
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let average = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                              blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Keep it deep enough for white text, but never grey mush.
        return Color(hue: Double(hue),
                     saturation: Double(min(1, saturation * 1.25 + 0.08)),
                     brightness: Double(min(max(brightness, 0.32), 0.55)))
    }
}
