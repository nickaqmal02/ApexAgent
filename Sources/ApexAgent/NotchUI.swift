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
    @Published var hovering: Bool = false     // mouse over the notch: show the study picker
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let study: StudyModel

    init(notchWidth: CGFloat, notchHeight: CGFloat, study: StudyModel) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.study = study
    }

    var expanded: Bool { state != .idle }

    // Live words stay on one line (newest words visible); longer finished text gets a second line.
    var labelLines: Int {
        if state.isPartialTranscript { return 1 }
        return state.label.count > 36 ? 2 : 1
    }

    // Idle hugs the notch. Active: a little wider for the icons, plus one or two rows for the words.
    // Priority: hover (study picker) > agent activity > running study session > plain notch
    var size: CGSize {
        if hovering || (!expanded && study.showsStatus) {
            let s = statusSides
            return CGSize(width: s.left + notchWidth + s.right, height: notchHeight + (hovering ? 104 : 0))
        }
        if expanded { return CGSize(width: notchWidth + 96, height: notchHeight + (labelLines == 2 ? 46 : 28)) }
        return CGSize(width: notchWidth, height: notchHeight)
    }

    // The study row's two sides of the camera. The right (clock) keeps a fixed width; the left grows
    // to fit the subject name, so "RAG LANGCHAIN KN" shows in full instead of "RAG LANG…".
    var statusSides: (left: CGFloat, right: CGFloat) {
        let base: CGFloat = hovering ? max(120, (440 - notchWidth) / 2) : 88
        return (max(base, statusLeftNeeded), base)
    }

    // The notch is wider on the left only, so shift it left by half the extra:
    // that keeps the empty middle exactly over the camera.
    var xOffset: CGFloat {
        guard hovering || (!expanded && study.showsStatus) else { return 0 }
        let s = statusSides
        return (s.right - s.left) / 2
    }

    // Left side = padding 12 + pill padding 16 + icon 12 + gap 5 + text + 8 breathing room before the camera
    private var statusLeftNeeded: CGFloat {
        let text: String? = study.subject ?? (study.resting ? "Break" : (study.breakOver ? "Break over" : study.justFinished))
        guard let text else { return 0 }
        return 12 + 16 + 12 + 5 + ceil((text as NSString).size(withAttributes: [.font: statusFont]).width) + 8
    }
}

// Same face as the row's Text (12 pt semibold rounded), used to measure the subject name
@MainActor private let statusFont: NSFont = {
    let base = NSFont.systemFont(ofSize: 12, weight: .semibold)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 12) } ?? base
}()

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

// The glossy look: a faint top-to-bottom sheen (like light on glass) and, while the agent
// works or you hover, a slow diagonal band of light sweeping across.
// No band during a study session: a 25-minute shimmer would be distracting.
struct GlossOverlay: View {
    let shimmer: Bool
    @State private var sweep: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [.clear, Color.white.opacity(0.05), Color.white.opacity(0.11)],
                               startPoint: .top, endPoint: .bottom)
                if shimmer {
                    LinearGradient(colors: [.clear, Color.white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(60, geo.size.width * 0.28), height: geo.size.height * 3)
                        .rotationEffect(.degrees(18))
                        .offset(x: sweep ? geo.size.width * 0.75 : -geo.size.width * 0.75)
                        .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: false), value: sweep)
                        .onAppear { sweep = true }
                        .onDisappear { sweep = false }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }
}

// How much life the notch shows. Busy agent states move fast; a study session only breathes.
enum GlowEnergy: Equatable {
    case off, calm, hover, listening, thinking, acting, speaking

    var speed: Double {       // comet laps per second around the rim
        switch self {
        case .off, .calm: return 0
        case .hover: return 0.18
        case .listening: return 0.3
        case .thinking: return 0.75
        case .acting: return 0.5
        case .speaking: return 0.4
        }
    }
    var breathPeriod: Double { // seconds per glow in-and-out
        switch self {
        case .thinking: return 0.9
        case .speaking: return 0.6
        case .listening: return 1.6
        case .calm: return 5.0
        default: return 2.4
        }
    }
    var strength: Double {     // overall intensity 0...1
        switch self {
        case .off: return 0
        case .calm: return 0.35
        case .hover: return 0.55
        case .listening, .speaking: return 0.85
        case .thinking, .acting: return 1
        }
    }
}

// The living layer: a comet of light running around the rim, aurora blobs drifting inside,
// and a glow that breathes. Driven by a TimelineView that is paused when idle, so an idle
// notch costs no frames at all.
struct LivingGlow: View {
    let tint: Color
    let energy: GlowEnergy
    let radius: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: energy == .calm ? 1.0 / 15 : 1.0 / 40, paused: energy == .off)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breath = 0.5 + 0.5 * sin(t * 2 * .pi / energy.breathPeriod)   // 0...1
            let s = energy.strength
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    // Aurora: two soft blobs of the state colour drifting past each other
                    if s > 0.4 {
                        ZStack {
                            Ellipse()
                                .fill(tint.opacity(0.45 * s))
                                .frame(width: w * 0.45, height: h * 0.9)
                                .blur(radius: 18)
                                .offset(x: CGFloat(sin(t * 0.9)) * w * 0.3, y: h * 0.45)
                            Ellipse()
                                .fill(Color.white.opacity(0.18 * s))
                                .frame(width: w * 0.3, height: h * 0.7)
                                .blur(radius: 16)
                                .offset(x: CGFloat(cos(t * 0.7 + 1.3)) * w * 0.32, y: h * 0.5)
                        }
                        .frame(width: w, height: h)
                        .clipShape(NotchShape(bottomRadius: radius))
                    }
                    // Comet: a bright arc travelling around the rim
                    if energy.speed > 0 {
                        NotchShape(bottomRadius: radius)
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(stops: [
                                        .init(color: .clear, location: 0.0),
                                        .init(color: .clear, location: 0.55),
                                        .init(color: tint.opacity(0.9), location: 0.85),
                                        .init(color: .white, location: 0.93),
                                        .init(color: .clear, location: 1.0),
                                    ]),
                                    center: .center,
                                    angle: .degrees((t * energy.speed * 360).truncatingRemainder(dividingBy: 360))
                                ),
                                lineWidth: 2
                            )
                            .blur(radius: 0.6)
                    }
                    // Breathing rim, always on while there is any energy
                    NotchShape(bottomRadius: radius)
                        .stroke(tint.opacity((0.25 + 0.45 * breath) * s), lineWidth: 1.2)
                }
                .frame(width: w, height: h)
                // Fade everything out toward the top so the pill still melts into the real notch
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                             .init(color: .black, location: 0.35),
                                             .init(color: .black, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                // The glow outside the notch breathes with the rim
                .shadow(color: tint.opacity((0.25 + 0.35 * breath) * s), radius: 6 + 8 * breath, y: 2)
            }
        }
        .allowsHitTesting(false)
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
    @ObservedObject var study: StudyModel   // observed too, so the countdown redraws every tick

    var body: some View {
        let size = model.size
        let radius: CGFloat = (model.expanded || model.hovering) ? 16 : 8
        ZStack(alignment: .top) {
            NotchShape(bottomRadius: radius)
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                // Glass: a soft sheen and a moving light band, clipped to the notch
                .overlay(
                    GlossOverlay(shimmer: model.expanded || model.hovering)
                        .clipShape(NotchShape(bottomRadius: radius))
                )
                // Alive: comet on the rim, drifting aurora, breathing glow (paused when idle)
                .overlay(LivingGlow(tint: glowTint, energy: glowEnergy, radius: radius))
                // A small "pop" each time the agent changes state
                .scaleEffect(popScale, anchor: .top)

            if model.hovering {
                VStack(spacing: 0) {
                    StudyStatusRow(study: study, sides: model.statusSides, notchWidth: model.notchWidth, notchHeight: model.notchHeight)
                    StudyPicker(study: study).frame(width: size.width, height: 104)
                }
                .transition(.opacity)
            } else if model.expanded {
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
            } else if study.showsStatus {
                StudyStatusRow(study: study, sides: model.statusSides, notchWidth: model.notchWidth, notchHeight: model.notchHeight)
                    .transition(.opacity)
            }
        }
        .offset(x: model.xOffset)   // wider on the left only: keep the gap over the camera
        .frame(width: notchPanelWidth, height: model.notchHeight + notchPanelExtraHeight, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: model.state.kind)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: model.labelLines)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: model.hovering)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: study.showsStatus)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: model.xOffset)
        .animation(.easeInOut(duration: 0.4), value: glowTint)
        .onChange(of: model.state.kind) { _ in
            // Overshoot then settle: the pill "jumps" a little when something new happens
            popScale = 1.06
            withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) { popScale = 1.0 }
        }
    }

    @State private var popScale: CGFloat = 1.0

    private var glowEnergy: GlowEnergy {
        if model.hovering { return .hover }
        switch model.state {
        case .listening: return .listening
        case .thinking: return .thinking
        case .acting: return .acting
        case .speaking: return .speaking
        case .idle: break
        }
        if study.running || study.resting || study.showsStatus { return .calm }
        return .off
    }

    // Rim colour: the agent's state while it works, the study colour while a session runs
    private var glowTint: Color {
        if model.hovering { return Color.white.opacity(0.8) }
        if model.expanded { return model.state.tint }
        if study.resting { return study.paused ? studyOrange : studyBlue }
        if study.running {
            if study.paused { return studyOrange }
            switch study.urgency {   // the rim warms up with the clock as the pomodoro ends
            case .calm: return studyGreen
            case .soon: return studyOrange
            case .final: return studyRed
            }
        }
        if study.showsStatus { return studyGreen }
        return .clear
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

// The window is a fixed transparent box big enough for the largest look (the study picker)
let notchPanelWidth: CGFloat = 720   // room for a 24-letter subject on the left
let notchPanelExtraHeight: CGFloat = 110

// A panel that can take typing (the + box) without activating the app
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// Owns the floating window over the notch and forwards state changes to the view.
@MainActor
final class NotchController {
    static let shared: NotchController = NotchController()
    private var panel: NotchPanel?
    private var model: NotchModel?
    private var hoverTimer: Timer?
    private var screenFrame: NSRect = .zero

    func start() {
        guard let screen = NSScreen.main else { return }
        // On notched Macs the top safe-area inset is the notch height, and the notch width is the gap
        // between the two auxiliary top areas. Without a notch, use a menu-bar-sized pill.
        let notchHeight: CGFloat = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 32
        var notchWidth: CGFloat = 190
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
        }

        let study = StudyModel()
        let model = NotchModel(notchWidth: notchWidth, notchHeight: notchHeight, study: study)
        let width: CGFloat = notchPanelWidth
        let height: CGFloat = notchHeight + notchPanelExtraHeight
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        screenFrame = screen.frame

        let panel = NotchPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar + 1          // above the menu bar, where the notch is
        panel.ignoresMouseEvents = true       // closed: clicks pass through to the menu bar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: NotchView(model: model, study: study))
        panel.orderFrontRegardless()
        self.panel = panel
        self.model = model

        // Only the + box takes the keyboard, and only while you type in it
        study.onNeedKeyboard = { [weak panel] in panel?.makeKey() }
        // Hover: check where the mouse is 20 times a second. Cheap, and needs no special permission.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { NotchController.shared.checkHover() }
        }

        // State changes arrive from background threads; the view is updated on the main thread
        agentStateObserver = { state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NotchController.shared.model?.state = state
                }
            }
        }
    }

    // The black shape's area on screen (AppKit y grows upward, so the top is screen maxY)
    // Clipped to this screen: a monitor placed above the MacBook starts right at its top edge,
    // and moving the mouse across that edge must not open the notch.
    private func shapeRect(_ size: CGSize, margin: CGFloat, offset: CGFloat) -> NSRect {
        NSRect(x: screenFrame.midX + offset - size.width / 2 - margin, y: screenFrame.maxY - size.height - margin,
               width: size.width + margin * 2, height: size.height + margin * 2).intersection(screenFrame)
    }

    private func checkHover() {
        guard let model = model, let panel = panel else { return }
        let mouse: NSPoint = NSEvent.mouseLocation
        if model.hovering {
            // Stay open while the mouse is near, or while typing a new subject
            if !model.study.typing && !shapeRect(model.size, margin: 14, offset: model.xOffset).contains(mouse) {
                model.hovering = false
                panel.ignoresMouseEvents = true
                panel.resignKey()
            }
        } else if shapeRect(model.size, margin: 2, offset: model.xOffset).contains(mouse) {
            model.hovering = true
            panel.ignoresMouseEvents = false   // open: the panel takes clicks
        }
    }
}
