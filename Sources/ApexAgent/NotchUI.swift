import AppKit
import SwiftUI

// The notch: a black pill that grows out of the MacBook notch and shows what the agent is doing.
// It only reads AgentState; it never calls the LLM, the audio or the shell.
// The status icons sit beside the camera; the label sits in a row below the notch,
// so text is never hidden behind the camera housing.

extension AgentState {
    var label: String {
        switch self {
        case .idle: return ""
        case .listening(let text): return text ?? "Listening"
        case .thinking(let heard): return heard ?? "Thinking"
        case .acting(let label): return label
        case .speaking(let text, _): return text
        }
    }

    var isPartialTranscript: Bool {
        if case .listening(let text) = self { return text != nil }
        return false
    }

    var tint: Color {
        switch self {
        case .idle: return .white
        case .listening: return Color(red: 0.35, green: 0.65, blue: 1.0)
        case .thinking: return Color(red: 0.74, green: 0.55, blue: 1.0)
        case .acting: return Color(red: 0.25, green: 0.73, blue: 0.31)
        case .speaking(_, let acted):
            // after a tool ran, keep the action's green; otherwise speaking orange
            return acted ? Color(red: 0.25, green: 0.73, blue: 0.31) : Color(red: 0.94, green: 0.53, blue: 0.24)
        }
    }

    // Used for animation: partial-transcript updates should not re-trigger the grow animation
    var kind: Int {
        switch self {
        case .idle: return 0
        case .listening: return 1
        case .thinking: return 2
        case .acting: return 3
        case .speaking: return 4
        }
    }
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var state: AgentState = .idle
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    init(notchWidth: CGFloat, notchHeight: CGFloat) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
    }

    var expanded: Bool { state != .idle }

    // Live words stay on one line (newest words visible); longer finished text gets a second line.
    var labelLines: Int {
        if state.isPartialTranscript { return 1 }
        return state.label.count > 36 ? 2 : 1
    }

    // Idle hugs the notch. Active: a little wider for the icons, plus one or two rows for the words.
    var size: CGSize {
        guard expanded else { return CGSize(width: notchWidth, height: notchHeight) }
        return CGSize(width: notchWidth + 96, height: notchHeight + (labelLines == 2 ? 46 : 28))
    }
}

// Flat top that meets the screen edge, rounded bottom corners like the notch
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

// A soft pulsing dot (listening)
struct PulseDot: View {
    let tint: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.35)).frame(width: 14, height: 14)
                .scaleEffect(pulse ? 1.5 : 0.8).opacity(pulse ? 0 : 1)
            Circle().fill(tint).frame(width: 7, height: 7)
        }
        .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
        .onAppear { pulse = true }
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let size = model.size
        ZStack(alignment: .top) {
            NotchShape(bottomRadius: model.expanded ? 16 : 8)
                .fill(Color.black)
                .frame(width: size.width, height: size.height)

            if model.expanded {
                VStack(spacing: 0) {
                    // Row 1, beside the camera: what kind of activity
                    HStack(spacing: 0) {
                        leftIndicator.frame(width: 30)
                        Spacer(minLength: model.notchWidth)
                        rightIndicator.frame(width: 30)
                    }
                    .padding(.horizontal, 9)
                    .frame(width: size.width, height: model.notchHeight)

                    // Row 2, below the camera: the words (what you said, or what it says)
                    Text(model.state.label)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(model.labelLines)
                        .truncationMode(model.state.isPartialTranscript ? .head : .tail)   // newest words stay visible
                        .padding(.horizontal, 16)
                        .frame(width: size.width, height: model.labelLines == 2 ? 42 : 24)
                }
                .transition(.opacity)
            }
        }
        .frame(width: model.notchWidth + 120, height: model.notchHeight + 64, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: model.state.kind)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: model.labelLines)
    }

    @ViewBuilder private var leftIndicator: some View {
        switch model.state {
        case .listening: PulseDot(tint: model.state.tint)
        case .thinking: Image(systemName: "sparkles").foregroundColor(model.state.tint).font(.system(size: 12, weight: .semibold))
        case .acting: Image(systemName: "checkmark.circle.fill").foregroundColor(model.state.tint).font(.system(size: 13))
        case .speaking(_, let acted):
            Image(systemName: acted ? "checkmark.circle.fill" : "waveform")
                .foregroundColor(model.state.tint)
                .font(.system(size: acted ? 13 : 12, weight: .semibold))
        case .idle: EmptyView()
        }
    }

    @ViewBuilder private var rightIndicator: some View {
        switch model.state {
        case .listening: WaveBars(tint: model.state.tint, fast: false)
        case .thinking: ThinkingDots(tint: model.state.tint)
        case .speaking, .acting: WaveBars(tint: model.state.tint, fast: true)
        case .idle: EmptyView()
        }
    }
}

// Owns the floating window over the notch and forwards state changes to the view.
@MainActor
final class NotchController {
    static let shared: NotchController = NotchController()
    private var panel: NSPanel?
    private var model: NotchModel?

    func start() {
        guard let screen = NSScreen.main else { return }
        // On notched Macs the top safe-area inset is the notch height, and the notch width is the gap
        // between the two auxiliary top areas. Without a notch, use a menu-bar-sized pill.
        let notchHeight: CGFloat = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 32
        var notchWidth: CGFloat = 190
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
        }

        let model = NotchModel(notchWidth: notchWidth, notchHeight: notchHeight)
        let width: CGFloat = notchWidth + 120
        let height: CGFloat = notchHeight + 64
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar + 1          // above the menu bar, where the notch is
        panel.ignoresMouseEvents = true       // clicks pass through to the menu bar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: NotchView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel
        self.model = model

        // State changes arrive from background threads; the view is updated on the main thread
        agentStateObserver = { state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NotchController.shared.model?.state = state
                }
            }
        }
    }
}
