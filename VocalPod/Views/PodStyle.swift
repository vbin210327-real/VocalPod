import SwiftUI

enum PodStyle {
    static let background = Color(white: 0.885)
    static let surface = Color(white: 0.88)
    static let accent = Color(white: 0.10)
    static let secondary = Color(white: 0.40)
    static let hairline = Color.black.opacity(0.13)

    static func time(_ value: TimeInterval) -> String {
        let seconds = value.isFinite ? max(0, Int(value)) : 0
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func speed(_ value: Float) -> String {
        value.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

// Shared with Scripts/generate_icon.swift: 66-point bars, 33-point gaps,
// and heights 170 / 320 / 480 / 320 / 170.
struct PodMark: View {
    var size: CGFloat = 34
    var color: Color = PodStyle.accent
    var body: some View {
        HStack(spacing: size * 33 / 480) {
            ForEach(Array([170.0, 320, 480, 320, 170].enumerated()), id: \.offset) { _, height in
                Capsule().frame(width: size * 66 / 480, height: size * height / 480)
            }
        }
        .foregroundStyle(color)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct PodIcon: View {
    var size: CGFloat = 48
    var body: some View {
        Image("PodIcon")
            .resizable().interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: size * 0.23).strokeBorder(.white.opacity(0.25), lineWidth: 0.7) }
            .accessibilityHidden(true)
    }
}

struct SilverBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(white: 0.925), Color(white: 0.875), Color(white: 0.84)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Canvas { context, size in
                    // Fixed low-contrast grain; no bitmap, timers, or disk cache.
                    for index in 0..<4800 {
                        let x = CGFloat((index * 7919) % 104729) / 104729 * size.width
                        let y = CGFloat((index * 15427) % 104723) / 104723 * size.height
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 0.28, height: 0.28)), with: .color(.black.opacity(0.025)))
                    }
                }.allowsHitTesting(false)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

struct SilverSurface: View {
    enum Finish { case panel, key }
    var radius: CGFloat = 18
    var dark = false
    var selected = false
    var finish: Finish = .panel

    private var shades: [Color] {
        if dark { return [Color(white: 0.22), Color(white: 0.09), Color(white: 0.13)] }
        if selected { return [Color(white: 0.855), Color(white: 0.785)] }
        if finish == .key { return [Color(white: 0.875), Color(white: 0.775)] }
        return [Color(white: 0.925), Color(white: 0.865)]
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(LinearGradient(colors: shades, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [
                    .white.opacity(dark ? 0.4 : 0.85),
                    .white.opacity(dark ? 0.06 : 0.14),
                    .white.opacity(dark ? 0.12 : 0.45)
                ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.85).padding(1)
            }
            .overlay { shape.strokeBorder(.black.opacity(dark ? 0.65 : 0.32), lineWidth: 0.65) }
            .shadow(color: .white.opacity(dark ? 0 : 0.45), radius: 0.3, x: 0, y: -0.5)
            .shadow(color: .black.opacity(dark ? 0.12 : 0.07), radius: 0.8, x: 0, y: 1)
    }
}

struct MetalDisc: View {
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) / 2
            Circle()
                // Four soft reflections across the lathe finish, with darker
                // opposing sectors. The grooves sit over the light field.
                .fill(AngularGradient(stops: [
                    .init(color: Color(white: 0.49), location: 0),
                    .init(color: Color(white: 0.53), location: 0.083),
                    .init(color: Color(white: 0.97), location: 0.167),
                    .init(color: Color(white: 0.65), location: 0.25),
                    .init(color: Color(white: 0.68), location: 0.333),
                    .init(color: Color(white: 0.92), location: 0.417),
                    .init(color: Color(white: 0.51), location: 0.5),
                    .init(color: Color(white: 0.70), location: 0.583),
                    .init(color: Color(white: 0.99), location: 0.667),
                    .init(color: Color(white: 0.79), location: 0.75),
                    .init(color: Color(white: 0.72), location: 0.833),
                    .init(color: Color(white: 0.94), location: 0.917),
                    .init(color: Color(white: 0.49), location: 1)
                ], center: .center))
                .overlay {
                    Canvas { context, size in
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let count = max(80, Int(radius * scale / 2))
                        for index in 1..<count {
                            let r = radius * CGFloat(index) / CGFloat(count)
                            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                            context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.20)), lineWidth: 0.8 / scale)
                            context.stroke(Path(ellipseIn: rect.insetBy(dx: 0.65 / scale, dy: 0.65 / scale)), with: .color(.white.opacity(0.29)), lineWidth: 0.65 / scale)
                        }
                    }.clipShape(Circle())
                }
                .overlay {
                    Circle().fill(RadialGradient(stops: [
                        .init(color: .white.opacity(0.16), location: 0),
                        .init(color: .clear, location: 0.30),
                        .init(color: .clear, location: 0.80),
                        .init(color: .black.opacity(0.12), location: 1)
                    ], center: .center, startRadius: 0, endRadius: radius))
                }
                .overlay { Circle().strokeBorder(.black.opacity(0.58), lineWidth: 0.8) }
                .overlay {
                    Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.98), .white.opacity(0.22), .white.opacity(0.80)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2).padding(1.4)
                }
                .overlay { Circle().strokeBorder(.black.opacity(0.27), lineWidth: 0.5).padding(3) }
                .shadow(color: .white.opacity(0.75), radius: 0.4, x: 0, y: -0.6)
                .shadow(color: .black.opacity(0.17), radius: 1.2, x: 0, y: 1.6)
        }
        .accessibilityHidden(true)
    }
}

struct PlayButtonFace: View {
    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(white: 0.37), Color(white: 0.67), Color(white: 0.33)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Circle().fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.075), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)).padding(2.2)
            }
            .overlay {
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .black.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7).padding(3.2)
            }
            .overlay { Circle().strokeBorder(.black.opacity(0.6), lineWidth: 0.7) }
            .shadow(color: .white.opacity(0.75), radius: 0.4, x: 0, y: -0.8)
            .shadow(color: .black.opacity(0.18), radius: 1.2, x: 0, y: 1.5)
            .accessibilityHidden(true)
    }
}

struct PodPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .brightness(configuration.isPressed ? -0.045 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct RoundControl: View {
    let symbol: String
    let label: String
    var size: CGFloat = 48
    var bodyColor: Color = PodStyle.accent
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.37, weight: .medium))
                .foregroundStyle(bodyColor)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(PodPressStyle())
        .accessibilityLabel(label)
    }
}
