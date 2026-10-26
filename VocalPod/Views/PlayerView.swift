import SwiftUI
import AVKit

struct PlayerView: View {
    let player: AudioPlayer
    let library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var seeking = false
    @State private var seekValue: Double = 0
    @State private var speedPresented = false
    @State private var viewportInsets = EdgeInsets()

    private var index: Int? { library.clips.firstIndex { $0.id == player.currentClip?.id } }
    private var position: Double { seeking ? seekValue : player.currentTime }

    var body: some View {
        GeometryReader { geometry in
            // Measure the viewport in its actual window: SwiftUI can report zero
            // insets after PhotosPicker, even when part of the inset is already applied.
            let topInset = viewportInsets.top
            let bottomInset = viewportInsets.bottom
            let contentHeight = max(0, geometry.size.height - topInset - bottomInset)
            let side = max(230, min(geometry.size.width - 48, contentHeight - 400, 380))
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        RoundControl(symbol: "chevron.down", label: "收起播放器", size: 44) { dismiss() }
                            .accessibilityIdentifier("player.close")
                        Spacer()
                        RoutePicker().frame(width: 44, height: 44).accessibilityLabel("选择音频输出")
                    }
                    .padding(.horizontal, -8)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(format: "%02d / %02d", (index ?? 0) + 1, library.clips.count))
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundStyle(PodStyle.secondary)
                            .accessibilityLabel("第 \((index ?? 0) + 1) 首，共 \(library.clips.count) 首")
                        Text(library.clips.first(where: { $0.id == player.currentClip?.id })?.title ?? player.currentClip?.title ?? "VocalPod")
                            .font(.system(size: 32, weight: .semibold)).tracking(-0.8)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .accessibilityIdentifier("player.title")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 14).padding(.bottom, 12)

                    ProgressDial(value: position, duration: player.duration, onScrub: { value in
                        seekValue = value
                        seeking = true
                    }, onCommit: { value in
                        player.seek(to: value)
                        seeking = false
                    })
                    .frame(width: side, height: side)

                    HStack {
                        Text(PodStyle.time(position))
                            .accessibilityLabel("已播放 " + PodStyle.time(position))
                        Spacer()
                        Text(PodStyle.time(player.duration))
                            .accessibilityLabel("总时长，秒")
                            .accessibilityValue(String(format: "%.2f", player.duration))
                            .accessibilityIdentifier("player.duration")
                    }
                    .font(.system(size: 14, weight: .regular))
                    .monospacedDigit().foregroundStyle(PodStyle.secondary)
                    .padding(.top, 2)

                    transport
                        .padding(.horizontal, 2).padding(.top, 16)
                    options.padding(.top, 18)
                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 14)
                .frame(maxWidth: 460)
                .frame(minHeight: contentHeight)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
        }
        .background { SilverBackground() }
        .overlay {
            PlayerViewportReader { viewportInsets = $0 }
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .foregroundStyle(PodStyle.accent)
        .onChange(of: player.currentClip?.id) { _, _ in seeking = false }
        .sensoryFeedback(.selection, trigger: player.currentClip?.id)
        .alert("暂时无法播放", isPresented: Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { player.errorMessage = nil }
        } message: { Text(player.errorMessage ?? "请重试。") }
        .sheet(isPresented: $speedPresented) {
            SpeedView(player: player)
                .presentationDetents([.height(350)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
    }

    private var transport: some View {
        HStack {
            trackButton(symbol: "backward.end.fill", label: "上一首", identifier: "player.previous", enabled: player.canPlayPreviousTrack) {
                player.playPreviousTrack()
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace.offUp))
                    .offset(x: player.isPlaying ? 0 : 2)
                    .foregroundStyle(Color(white: 0.97))
                    .frame(width: 112, height: 112)
                    .background { PlayButtonFace() }
            }
            .buttonStyle(PodPressStyle())
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            .accessibilityValue(player.isPlaying ? "playing" : "paused")
            .accessibilityIdentifier("player.play")
            Spacer()
            trackButton(symbol: "forward.end.fill", label: "下一首", identifier: "player.next", enabled: player.canPlayNextTrack) {
                player.playNextTrack()
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
    }

    private func trackButton(symbol: String, label: String, identifier: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(PodStyle.accent.opacity(enabled ? 1 : 0.24))
                .frame(width: 78, height: 66)
                .background { SilverSurface(radius: 18, finish: .key) }
        }
        .buttonStyle(PodPressStyle())
        .disabled(!enabled)
        .accessibilityLabel(label).accessibilityIdentifier(identifier)
    }

    private var options: some View {
        HStack {
            Button { speedPresented = true } label: {
                Text(PodStyle.speed(player.rate))
                    .font(.system(size: 19, weight: .medium)).monospacedDigit()
                    .frame(width: 120, height: 54)
                    .background { SilverSurface(radius: 27, finish: .key) }
            }
            .buttonStyle(PodPressStyle())
            .accessibilityIdentifier("player.speed")
            .accessibilityLabel("播放速度").accessibilityValue(PodStyle.speed(player.rate))
            Spacer()
            Button { player.cyclePlaybackMode() } label: {
                Image(systemName: player.playbackMode.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(PodStyle.accent)
                    .frame(width: 120, height: 54)
                    .background { SilverSurface(radius: 27, finish: .key) }
            }
            .buttonStyle(PodPressStyle())
            .accessibilityIdentifier("player.loop")
            .accessibilityLabel("播放模式").accessibilityValue(player.playbackMode.title)
            .accessibilityHint("轻点切换播放模式")
        }
        .sensoryFeedback(.selection, trigger: player.playbackMode)
    }
}

/// Measures only the portion of the real window's safe area missing from this viewport.
private struct PlayerViewportReader: UIViewRepresentable {
    let onChange: (EdgeInsets) -> Void

    func makeUIView(context: Context) -> ViewportView {
        let view = ViewportView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ViewportView, context: Context) { view.onChange = onChange }

    final class ViewportView: UIView {
        var onChange: ((EdgeInsets) -> Void)?
        private var reportedInsets: EdgeInsets?

        override func didMoveToWindow() { super.didMoveToWindow(); reportInsets() }
        override func layoutSubviews() { super.layoutSubviews(); reportInsets() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); reportInsets() }

        private func reportInsets() {
            guard let window, bounds.width > 0, bounds.height > 0 else { return }
            let frame = convert(bounds, to: window)
            let safeFrame = window.bounds.inset(by: window.safeAreaInsets)
            let insets = EdgeInsets(top: max(0, safeFrame.minY - frame.minY), leading: 0,
                                    bottom: max(0, frame.maxY - safeFrame.maxY), trailing: 0)
            guard insets != reportedInsets else { return }
            reportedInsets = insets
            DispatchQueue.main.async { [weak self] in self?.onChange?(insets) }
        }
    }
}

private struct ProgressDial: View {
    let value: Double
    let duration: Double
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void
    @State private var dragging = false
    private var fraction: Double { duration > 0 ? min(1, max(0, value / duration)) : 0 }

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            let radius = side / 2 - 10
            ZStack {
                MetalDisc().padding(side * 0.092)
                ForEach(0..<60) { index in
                    Capsule()
                        .fill(index < Int((fraction * 60).rounded(.up)) ? PodStyle.accent : Color(white: 0.72))
                        .overlay { Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 0.6) }
                        .frame(width: side * 0.022, height: side * 0.061)
                        .offset(y: -radius)
                        .rotationEffect(.degrees(Double(index) * 6))
                }
                PodMark(size: side * 0.205)
                    .shadow(color: .white.opacity(0.45), radius: 0.5, y: 1)
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { event in
                    guard let time = target(at: event.location, side: side) else { return }
                    dragging = true
                    onScrub(time)
                }
                .onEnded { event in
                    defer { dragging = false }
                    guard dragging else { return }
                    onCommit(target(at: event.location, side: side) ?? value)
                })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度，秒")
        .accessibilityValue(String(format: "%.2f", value))
        .accessibilityHint("沿圆环拖动以调整进度")
        .accessibilityIdentifier("player.progress")
        .accessibilityAdjustableAction { direction in
            let step = max(1, min(10, duration / 20))
            switch direction {
            case .increment: onCommit(min(duration, value + step))
            case .decrement: onCommit(max(0, value - step))
            @unknown default: break
            }
        }
    }

    private func target(at point: CGPoint, side: CGFloat) -> Double? {
        guard duration > 0 else { return nil }
        let dx = point.x - side / 2
        let dy = point.y - side / 2
        // The center mark is inert; only the outer dial accepts seeking.
        guard hypot(dx, dy) >= side * 0.29 else { return nil }
        let angle = atan2(dx, -dy)
        return (angle < 0 ? angle + 2 * .pi : angle) / (2 * .pi) * duration
    }
}

private struct SpeedView: View {
    let player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var customRate = ""
    @State private var invalidRate = false
    private let presets: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("倍速").font(.system(size: 23, weight: .semibold))
                    Spacer()
                    Button("完成") { dismiss() }
                        .font(.system(size: 15, weight: .medium)).frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("speed.done")
                }
                Text(PodStyle.speed(player.rate))
                    .font(.system(size: 44, weight: .medium, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { rate in
                        Button {
                            withAnimation(.easeOut(duration: 0.16)) { player.setRate(rate) }
                            customRate = ""; invalidRate = false
                        } label: {
                            Text(PodStyle.speed(rate))
                                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                                .frame(maxWidth: .infinity).frame(height: 44)
                                .background { SilverSurface(radius: 22, dark: player.rate == rate) }
                                .foregroundStyle(player.rate == rate ? .white : PodStyle.accent)
                        }
                        .buttonStyle(PodPressStyle())
                        .accessibilityIdentifier("speed.\(rate)")
                        .accessibilityAddTraits(player.rate == rate ? [.isSelected] : [])
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        TextField("自定义 0.25–3.00", text: $customRate)
                            .keyboardType(.decimalPad).font(.system(size: 15))
                            .accessibilityLabel("自定义倍速").accessibilityIdentifier("speed.custom")
                        Text("×").foregroundStyle(PodStyle.secondary)
                        Button("应用") { applyCustomRate() }
                            .font(.system(size: 15, weight: .semibold)).frame(minHeight: 44)
                            .accessibilityIdentifier("speed.apply")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    .background { SilverSurface(radius: 16) }
                    if invalidRate {
                        Text("请输入 0.25 到 3 之间的数字。")
                            .font(.system(size: 12)).foregroundStyle(PodStyle.secondary)
                            .accessibilityIdentifier("speed.error")
                    }
                }
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
        }
        .background { SilverBackground() }
        .foregroundStyle(PodStyle.accent)
    }

    private func applyCustomRate() {
        let normalized = customRate.replacingOccurrences(of: ",", with: ".")
        guard let value = Float(normalized), value.isFinite, (0.25...3).contains(value) else { invalidRate = true; return }
        invalidRate = false
        player.setRate(value)
        dismiss()
    }
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(white: 0.15, alpha: 1)
        view.activeTintColor = .black
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
