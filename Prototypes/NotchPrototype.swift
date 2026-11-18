// Notch animation prototype for ApexAgent. Standalone: it does not touch the app.
// Build and run:  swiftc -parse-as-library Prototypes/NotchPrototype.swift -o /tmp/notch && /tmp/notch
// It cycles through the agent states every 2.5 s so you can see each animation. Quit with Ctrl-C.

import AppKit
import SwiftUI

// MARK: - States the agent will report

enum AgentState: String, CaseIterable {
    case idle, listening, thinking, acting, speaking

    var label: String {
        switch self {
        case .idle: return ""
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .acting: return "Opened Calculator"
        case .speaking: return "Speaking"
        }
    }

    var tint: Color {
        switch self {
        case .idle: return .white
        case .listening: return Color(red: 0.35, green: 0.65, blue: 1.0)
        case .thinking: return Color(red: 0.74, green: 0.55, blue: 1.0)
        case .acting: return Color(red: 0.25, green: 0.73, blue: 0.31)
        case .speaking: return Color(red: 0.94, green: 0.53, blue: 0.24)
        }
    }
}

final class NotchModel: ObservableObject {
    @Published var state: AgentState = .idle
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    init(notchWidth: CGFloat, notchHeight: CGFloat) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
    }

    // Idle hugs the notch; active states grow sideways (status on each side) and slightly down.
    var size: CGSize {
        switch state {
        case .idle: return CGSize(width: notchWidth, height: notchHeight)
        case .acting: return CGSize(width: notchWidth + 210, height: notchHeight + 6)
        default: return CGSize(width: notchWidth + 150, height: notchHeight + 6)
        }
    }
}

// MARK: - Shape: flat top that meets the screen edge, rounded bottom corners like the notch

struct NotchShape: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(bottomRadius, rect.height / 2, rect.width / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Indicators

// Five bars that move: audio coming in (listening) or going out (speaking)
struct WaveBars: View {
    let tint: Color
    let fast: Bool
    @State private var phase = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: phase ? CGFloat([14, 8, 16, 10, 13][i]) : CGFloat([6, 12, 5, 14, 7][i]))
                    .animation(.easeInOut(duration: fast ? 0.28 : 0.45).repeatForever().delay(Double(i) * 0.07), value: phase)
            }
        }
        .frame(height: 18)
        .onAppear { phase = true }
    }
}

// Three dots that rise in turn (thinking)
struct ThinkingDots: View {
    let tint: Color
    @State private var up = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
                    .offset(y: up ? -3 : 3)
                    .animation(.easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.13), value: up)
            }
        }
        .frame(height: 18)
        .onAppear { up = true }
    }
}

// A soft pulsing dot (listening, left side)
struct PulseDot: View {
    let tint: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.35)).frame(width: 14, height: 14).scaleEffect(pulse ? 1.5 : 0.8).opacity(pulse ? 0 : 1)
            Circle().fill(tint).frame(width: 7, height: 7)
        }
        .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
        .onAppear { pulse = true }
    }
}

// MARK: - The notch view

struct NotchView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let size = model.size
        ZStack(alignment: .top) {
            NotchShape(bottomRadius: model.state == .idle ? 8 : 14)
                .fill(Color.black)
                .frame(width: size.width, height: size.height)

            if model.state != .idle {
                HStack(spacing: 0) {
                    // left of the notch: what the agent is doing
                    HStack(spacing: 7) {
                        leftIndicator
                        Text(model.state.label)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.leading, 14)
                    Spacer(minLength: model.notchWidth)   // the camera sits here
                    rightIndicator
                        .padding(.trailing, 14)
                }
                .frame(width: size.width, height: model.notchHeight)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(width: model.notchWidth + 260, height: model.notchHeight + 40, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: model.state)
    }

    @ViewBuilder private var leftIndicator: some View {
        switch model.state {
        case .listening: PulseDot(tint: model.state.tint)
        case .thinking: Image(systemName: "sparkles").foregroundColor(model.state.tint).font(.system(size: 12, weight: .semibold))
        case .acting: Image(systemName: "checkmark.circle.fill").foregroundColor(model.state.tint).font(.system(size: 13))
        case .speaking: Image(systemName: "waveform").foregroundColor(model.state.tint).font(.system(size: 12, weight: .semibold))
        case .idle: EmptyView()
        }
    }

    @ViewBuilder private var rightIndicator: some View {
        switch model.state {
        case .listening: WaveBars(tint: model.state.tint, fast: false)
        case .thinking: ThinkingDots(tint: model.state.tint)
        case .acting: Image(systemName: "app.badge.checkmark").foregroundColor(model.state.tint).font(.system(size: 13))
        case .speaking: WaveBars(tint: model.state.tint, fast: true)
        case .idle: EmptyView()
        }
    }
}

// MARK: - Window that sits over the notch

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel?
    var model: NotchModel?
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { return }
        // On notched Macs the menu bar inset is the notch height; the notch width is the gap between
        // the two auxiliary top areas. Without a notch, fall back to a menu-bar-sized pill.
        let notchHeight: CGFloat = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 32
        var notchWidth: CGFloat = 190
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
        }
        print(String(format: "screen %.0fx%.0f, notch %@ %.0fx%.0f", screen.frame.width, screen.frame.height,
                     screen.safeAreaInsets.top > 0 ? "found" : "not found (fallback)", notchWidth, notchHeight))

        let model = NotchModel(notchWidth: notchWidth, notchHeight: notchHeight)
        let width = notchWidth + 260
        let height = notchHeight + 40
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar + 1          // above the menu bar, where the notch is
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: NotchView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel
        self.model = model

        // Demo: cycle through every state
        var index = 0
        let states = AgentState.allCases
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            index = (index + 1) % states.count
            model.state = states[index]
            print("state:", states[index].rawValue)
        }
    }
}

@main
struct NotchPrototype {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)        // print each line immediately, even into a file
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // no Dock icon
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
