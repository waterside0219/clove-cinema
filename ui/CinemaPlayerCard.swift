// CinemaPlayerCard.swift — self-contained SwiftUI reference UI for clove-cinema.
//
// One file, four endpoints (see ../server.py):
//   GET /cinema/list                  -> film picker
//   GET /cinema/{id}/meta             -> single film meta
//   GET /cinema/sync/{id}?from=&to=   -> subtitles in a time range (for danmu / context)
//   GET /cinema/stream/{id}           -> Range-served video
//
// Drop this file into any SwiftUI app (iOS 16+ / macOS 13+), set `baseURL`, supply
// an `onSendMoment` closure that posts to your own chat backend, done.
// No external dependencies beyond SwiftUI + AVKit.
//
// What the player gives you:
//   - Film list with cover-less rows (title + duration + subtitle count)
//   - Inline video stage with subtitle overlay (optional, off by default if hardsub baked in)
//   - Danmu layer: messages fly across the top half of the frame
//       user -> pink (#FFC0CB),  assistant -> turquoise (#40E0D0),  white stroke + soft shadow
//   - Tap arrow.up.left.and.arrow.down.right -> enter landscape fullscreen overlay
//       (fullscreen video, danmu still on top, tap composer to compose without leaving)
//   - Send a "moment": current frame JPEG + nearby subtitle cues + your text,
//       handed to `onSendMoment` for you to forward to /chat or whatever
//   - Resume position persisted per-film in UserDefaults; auto-seek next time
//
// What the player deliberately leaves to you:
//   - The chat history itself (this card just receives `messages` from outside)
//   - The actual send pipeline (`onSendMoment` is yours)
//   - Authentication / token handling
//
// Tested against Python 3.9+ clove-cinema server.

import SwiftUI
import AVKit
import AVFoundation

// MARK: - API models -----------------------------------------------------------

public struct CinemaFilm: Decodable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let videoFile: String
    public let videoMime: String
    public let videoSize: Int
    public let hasSubtitle: Bool
    public let subtitleCount: Int
    public let duration: Double

    enum CodingKeys: String, CodingKey {
        case id, title, duration
        case videoFile = "video_file"
        case videoMime = "video_mime"
        case videoSize = "video_size"
        case hasSubtitle = "has_subtitle"
        case subtitleCount = "subtitle_count"
    }
}

public struct CinemaCue: Decodable, Hashable {
    public let start: Double
    public let end: Double
    public let text: String
}

public struct CinemaListResponse: Decodable {
    public let films: [CinemaFilm]
}

public struct CinemaSyncResponse: Decodable {
    public let id: String
    public let from: Double
    public let to: Double
    public let subtitles: [CinemaCue]
}

// MARK: - Tiny HTTP client -----------------------------------------------------

@MainActor
public final class CinemaClient: ObservableObject {
    /// EDIT ME (or pass in via init): where clove-cinema server.py is reachable.
    public var baseURL: URL
    public var prefix: String

    @Published public var films: [CinemaFilm] = []
    @Published public var loadError: String?

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8770")!, prefix: String = "/cinema") {
        self.baseURL = baseURL
        self.prefix = prefix
    }

    private func endpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent(prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).appendingPathComponent(path)
    }

    public func reloadList() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: endpoint("list"))
            let decoded = try JSONDecoder().decode(CinemaListResponse.self, from: data)
            self.films = decoded.films
            self.loadError = nil
        } catch {
            self.loadError = "list 拉取失败: \(error.localizedDescription)"
        }
    }

    public func sync(filmID: String, from: Double, to: Double) async throws -> CinemaSyncResponse {
        var comps = URLComponents(url: endpoint("sync/\(filmID)"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "from", value: String(format: "%.3f", from)),
            URLQueryItem(name: "to", value: String(format: "%.3f", to)),
        ]
        guard let url = comps?.url else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(CinemaSyncResponse.self, from: data)
    }

    public func streamURL(filmID: String) -> URL {
        endpoint("stream/\(filmID)")
    }
}

// MARK: - Chat message (user-defined, intentionally minimal) -------------------

public struct CinemaMessage: Identifiable, Hashable {
    public let id: String
    public let role: Role
    public let text: String
    public init(id: String, role: Role, text: String) {
        self.id = id; self.role = role; self.text = text
    }
    public enum Role: Hashable { case user, assistant }
}

/// Payload handed to your `onSendMoment` when the user hits send.
/// You forward this to your own chat backend however you like.
public struct CinemaSnapshot {
    public let film: CinemaFilm
    public let messageText: String
    public let timeFrom: Double          // last send mark, or 0
    public let timeTo: Double            // current playhead at send
    public let nearbyCues: [CinemaCue]   // pulled from /sync between (from, to)
    public let frameJPEG: Data?          // current video frame, ~0.86 quality
}

// MARK: - Playback observable state -------------------------------------------

final class CinemaPlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0
}

final class CinemaSubtitleState: ObservableObject {
    @Published var currentCue: CinemaCue?
}

// MARK: - Danmu tracker (shared across portrait/fullscreen) -------------------

final class CinemaDanmuTracker: ObservableObject {
    private var seen = Set<String>()
    private var initialized = false

    /// First call with non-empty messages: marks ALL existing as seen (no history replay).
    /// Subsequent calls: returns only message IDs not yet seen.
    func freshMessages(from messages: [CinemaMessage]) -> [CinemaMessage] {
        if !initialized {
            initialized = true
            for m in messages { seen.insert(m.id) }
            return []
        }
        var fresh: [CinemaMessage] = []
        for m in messages where !seen.contains(m.id) {
            seen.insert(m.id)
            fresh.append(m)
        }
        return fresh
    }
}

// MARK: - Danmu visual ---------------------------------------------------------

private struct CinemaDanmuItem: Identifiable {
    let id: String
    let text: String
    let isUser: Bool
    let lane: Int
    let width: CGFloat
    let duration: Double
}

private enum CinemaDanmuMetrics {
    static func width(for text: String) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 16, weight: .bold)
        let bounds = (text as NSString).size(withAttributes: [.font: font])
        return max(60, bounds.width + 24)
    }
    static func duration(textWidth: CGFloat, containerWidth: CGFloat) -> Double {
        let pixelsPerSecond: CGFloat = 110
        let total = containerWidth + textWidth + 48
        return max(4.0, Double(total / pixelsPerSecond))
    }
}

private struct CinemaDanmuBubble: View {
    let item: CinemaDanmuItem
    private static let strokeOffsets: [CGSize] = [
        .init(width: -1.5, height: 0), .init(width: 1.5, height: 0),
        .init(width: 0, height: -1.5), .init(width: 0, height: 1.5),
    ]
    var body: some View {
        ZStack {
            ForEach(0..<Self.strokeOffsets.count, id: \.self) { i in
                Text(item.text)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(.white)
                    .offset(Self.strokeOffsets[i])
            }
            Text(item.text)
                .font(.system(size: 16, weight: .bold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(item.isUser ? Color(red: 1.0, green: 0.752, blue: 0.796)
                                              : Color(red: 0.251, green: 0.878, blue: 0.816))
        }
        .shadow(color: .black.opacity(0.32), radius: 2, x: 0, y: 1)
    }
}

private struct CinemaDanmuMotion: ViewModifier {
    let containerWidth: CGFloat
    let textWidth: CGFloat
    let duration: Double
    @State private var phase: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .offset(x: phase)
            .onAppear {
                let travel = containerWidth + textWidth + 48
                phase = 0
                withAnimation(.linear(duration: duration)) {
                    phase = -travel
                }
            }
    }
}

private struct CinemaDanmuOverlay: View {
    let messages: [CinemaMessage]
    let tracker: CinemaDanmuTracker
    @State private var visible: [CinemaDanmuItem] = []
    @State private var laneCursor = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(visible) { item in
                    CinemaDanmuBubble(item: item)
                        .frame(width: item.width, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .position(x: geo.size.width + item.width / 2 + 24,
                                  y: laneY(for: item.lane, height: geo.size.height))
                        .modifier(CinemaDanmuMotion(containerWidth: geo.size.width,
                                                    textWidth: item.width,
                                                    duration: item.duration))
                }
            }
            .clipped()
            .onAppear { ingest(messages, width: geo.size.width) }
            .onChange(of: messages.map(\.id)) { _ in
                ingest(messages, width: geo.size.width)
            }
        }
    }

    private func laneY(for lane: Int, height: CGFloat) -> CGFloat {
        let top = max(34, height * 0.16)
        let gap = min(44, max(34, height * 0.105))
        return min(height * 0.66, top + CGFloat(lane) * gap)
    }

    private func ingest(_ messages: [CinemaMessage], width: CGFloat) {
        let fresh = tracker.freshMessages(from: messages)
        for m in fresh {
            let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let w = CinemaDanmuMetrics.width(for: text)
            let d = CinemaDanmuMetrics.duration(textWidth: w, containerWidth: width)
            let item = CinemaDanmuItem(id: m.id, text: text, isUser: m.role == .user,
                                       lane: laneCursor % 4, width: w, duration: d)
            laneCursor += 1
            visible.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + d + 0.3) {
                visible.removeAll { $0.id == item.id }
            }
        }
        if visible.count > 10 { visible = Array(visible.suffix(10)) }
    }
}

// MARK: - Player layer (SwiftUI wrapper around AVPlayerLayer) -----------------

private struct CinemaPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerLayerHostView {
        let v = PlayerLayerHostView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ v: PlayerLayerHostView, context: Context) {
        v.playerLayer.player = player
    }
    final class PlayerLayerHostView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// MARK: - The main entry view --------------------------------------------------

public struct CinemaPlayerCard: View {
    public let film: CinemaFilm
    public let messages: [CinemaMessage]
    public let onSendMoment: (CinemaSnapshot) -> Void

    @ObservedObject private var client: CinemaClient
    @StateObject private var clock = CinemaPlaybackClock()
    @StateObject private var subtitleState = CinemaSubtitleState()
    @StateObject private var danmuTracker = CinemaDanmuTracker()
    @State private var player = AVPlayer()
    @State private var draft = ""
    @State private var sending = false
    @State private var status: String = ""
    @State private var isFullscreen = false
    @State private var lastSentTime: Double = 0
    @State private var didSeekToResume = false
    @State private var timeObserver: Any?
    @State private var subtitleCache: [CinemaCue] = []
    @AppStorage("clove_cinema_resume_by_film") private var resumeRaw: String = "{}"

    public init(film: CinemaFilm,
                client: CinemaClient,
                messages: [CinemaMessage],
                onSendMoment: @escaping (CinemaSnapshot) -> Void) {
        self.film = film
        self.client = client
        self.messages = messages
        self.onSendMoment = onSendMoment
    }

    public var body: some View {
        VStack(spacing: 0) {
            videoSection
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .background(Color.black)
            controlsBar
            composer
        }
        .onAppear { startPlayer() }
        .onDisappear { stopPlayer() }
        .fullScreenCover(isPresented: $isFullscreen) {
            fullscreenLayout
        }
        .statusBarHidden(isFullscreen)
    }

    // MARK: video + danmu overlay

    private var videoSection: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                CinemaPlayerLayerView(player: player)
                CinemaDanmuOverlay(messages: messages, tracker: danmuTracker)
                    .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: bottom controls (play/pause, progress, fullscreen)

    private var controlsBar: some View {
        HStack(spacing: 10) {
            Button {
                if player.timeControlStatus == .playing { player.pause() }
                else { player.play() }
            } label: {
                Image(systemName: player.timeControlStatus == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.white)
            }
            Text("\(format(clock.currentTime)) / \(format(max(film.duration, clock.currentTime)))")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            Slider(value: Binding(
                get: { min(max(clock.currentTime, 0), max(film.duration, 1)) },
                set: { v in
                    let target = CMTime(seconds: v, preferredTimescale: 600)
                    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                    clock.currentTime = v
                }
            ), in: 0...max(film.duration, 1))
                .tint(.white)
            Button {
                isFullscreen = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color.black.opacity(0.92))
    }

    // MARK: composer (the moment-send box)

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("边看边吐槽...", text: $draft)
                .padding(.horizontal, 13)
                .frame(height: 36)
                .background(Color.white)
                .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 1))
                .clipShape(Capsule())
                .textInputAutocapitalization(.never)
                .submitLabel(.send)
                .onSubmit { sendIfPossible() }
            Button {
                sendIfPossible()
            } label: {
                if sending {
                    ProgressView().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
            }
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(canSend ? Color.black : Color.black.opacity(0.32), in: Circle())
            .disabled(!canSend)
            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white)
    }

    // MARK: landscape fullscreen layout (minimal version — system rotates, danmu still rides on top)

    private var fullscreenLayout: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                CinemaPlayerLayerView(player: player)
                    .aspectRatio(16.0/9.0, contentMode: .fit)
            }
            CinemaDanmuOverlay(messages: messages, tracker: danmuTracker)
                .allowsHitTesting(false)
            VStack {
                HStack {
                    Button { isFullscreen = false } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    Spacer()
                }
                .padding(.top, 24)
                .padding(.horizontal, 16)
                Spacer()
                HStack {
                    TextField("发个弹幕...", text: $draft)
                        .padding(.horizontal, 13)
                        .frame(height: 38)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .tint(.white)
                        .submitLabel(.send)
                        .onSubmit { sendIfPossible() }
                    Button {
                        sendIfPossible()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .foregroundStyle(.black)
                            .background(Color.white, in: Circle())
                    }
                    .disabled(!canSend)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
        }
    }

    // MARK: send pipeline

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    private func sendIfPossible() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        let now = clock.currentTime.isFinite ? clock.currentTime : 0
        let from = lastSentTime
        let to = max(from, now)
        sending = true
        status = "整理这一段..."
        draft = ""
        Task {
            // best-effort grab subtitle context
            var cues: [CinemaCue] = []
            do {
                let resp = try await client.sync(filmID: film.id, from: from, to: to)
                cues = resp.subtitles
            } catch { }
            // best-effort grab the current frame
            let frame = await captureFrame(at: to)
            let snapshot = CinemaSnapshot(film: film, messageText: text,
                                          timeFrom: from, timeTo: to,
                                          nearbyCues: cues, frameJPEG: frame)
            onSendMoment(snapshot)
            lastSentTime = to
            sending = false
            status = "已发送 \(format(from)) → \(format(to))"
        }
    }

    private func captureFrame(at seconds: Double) async -> Data? {
        let asset = AVURLAsset(url: client.streamURL(filmID: film.id))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        return await Task.detached(priority: .userInitiated) {
            do {
                let cg = try generator.copyCGImage(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600), actualTime: nil)
                return UIImage(cgImage: cg).jpegData(compressionQuality: 0.86)
            } catch {
                return nil
            }
        }.value
    }

    // MARK: player lifecycle

    private func startPlayer() {
        if player.currentItem == nil {
            let item = AVPlayerItem(url: client.streamURL(filmID: film.id))
            player.replaceCurrentItem(with: item)
        }
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 1, preferredTimescale: 2), queue: .main
            ) { time in
                let s = time.seconds.isFinite ? time.seconds : 0
                clock.currentTime = s
                Task { await refreshSubtitles(around: s) }
                persistResume(s)
            }
        }
        seekToResumeIfNeeded()
        player.play()
    }

    private func stopPlayer() {
        let live = player.currentTime().seconds
        if live.isFinite, live > 0 { writeResume(seconds: live) }
        if let t = timeObserver {
            player.removeTimeObserver(t)
            timeObserver = nil
        }
        player.pause()
    }

    private func seekToResumeIfNeeded() {
        guard !didSeekToResume else { return }
        didSeekToResume = true
        guard let saved = resumeMap[film.id], saved > 5 else { return }
        if film.duration > 0, saved >= film.duration - 30 { return }
        player.seek(to: CMTime(seconds: saved, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        clock.currentTime = saved
        status = "从 \(format(saved)) 继续看"
    }

    // throttled write (≥ 10s)
    @State private static var resumeWriteThrottle: Date = .distantPast
    private func persistResume(_ s: Double) {
        if Date().timeIntervalSince(Self.resumeWriteThrottle) < 10 { return }
        Self.resumeWriteThrottle = Date()
        writeResume(seconds: s)
    }

    private func writeResume(seconds: Double) {
        guard seconds.isFinite, seconds > 5 else { return }
        var map = resumeMap
        if film.duration > 0, seconds >= film.duration - 30 {
            map.removeValue(forKey: film.id)
        } else {
            map[film.id] = seconds
        }
        if let data = try? JSONEncoder().encode(map),
           let s = String(data: data, encoding: .utf8) {
            resumeRaw = s
        }
    }

    private var resumeMap: [String: Double] {
        guard let data = resumeRaw.data(using: .utf8),
              let m = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return m
    }

    // subtitle increment refresh (pulls a small window around playhead)
    private func refreshSubtitles(around t: Double) async {
        // only refresh once per ~10s window
        let cached = subtitleCache.first { $0.start <= t && $0.end >= t }
        if let cached {
            subtitleState.currentCue = cached
            return
        }
        let from = max(0, t - 5)
        let to = t + 30
        do {
            let resp = try await client.sync(filmID: film.id, from: from, to: to)
            subtitleCache = resp.subtitles
            subtitleState.currentCue = resp.subtitles.first { $0.start <= t && $0.end >= t }
        } catch { }
    }

    // MARK: small helpers

    private func format(_ v: Double) -> String {
        guard v.isFinite else { return "00:00" }
        let total = max(0, Int(v.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Film picker (optional convenience entry view) -----------------------

/// A bare-bones "open a film" screen if you don't want to write your own picker.
/// Wraps CinemaPlayerCard inside a film selection list.
public struct CinemaLibraryView: View {
    @ObservedObject public var client: CinemaClient
    public let messages: [CinemaMessage]
    public let onSendMoment: (CinemaSnapshot) -> Void
    @State private var selected: CinemaFilm?

    public init(client: CinemaClient,
                messages: [CinemaMessage],
                onSendMoment: @escaping (CinemaSnapshot) -> Void) {
        self.client = client
        self.messages = messages
        self.onSendMoment = onSendMoment
    }

    public var body: some View {
        NavigationStack {
            List(client.films) { film in
                Button {
                    selected = film
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(film.title).font(.headline)
                            Text(film.hasSubtitle
                                 ? "\(film.subtitleCount) 字幕  ·  \(Int(film.duration)) s"
                                 : "无字幕")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Cinema")
            .task { await client.reloadList() }
            .refreshable { await client.reloadList() }
        }
        .sheet(item: $selected) { film in
            NavigationStack {
                CinemaPlayerCard(film: film, client: client,
                                 messages: messages, onSendMoment: onSendMoment)
                    .navigationTitle(film.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

// MARK: - Example wiring (commented out so it doesn't pollute your app) -------

/*
import SwiftUI

@main
struct DemoApp: App {
    @StateObject var client = CinemaClient(baseURL: URL(string: "http://192.168.0.32:8770")!)
    @State var messages: [CinemaMessage] = []

    var body: some Scene {
        WindowGroup {
            CinemaLibraryView(client: client, messages: messages) { snapshot in
                // forward to your chat backend
                Task {
                    // POST /chat with snapshot.messageText + snapshot.nearbyCues +
                    // snapshot.frameJPEG (multipart), then append the assistant
                    // reply to `messages`.
                }
            }
        }
    }
}
*/
