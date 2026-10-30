
import SwiftUI
import Combine
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers
import PhotosUI
import UIKit
import Security

// MARK: - Theme

// Single release label used in Settings and developer diagnostics.
private enum AMRelease {
    static let version = "16.9.7"
    static let subtitle = "Welcome Wave • Smart Library • Queue"
}

private enum AMPalette {
    static func background(_ theme: String) -> Color {
        theme == "light" ? Color(red: 0.94, green: 0.96, blue: 0.98) : Color(red: 0.065, green: 0.085, blue: 0.115)
    }
    static func card(_ theme: String) -> Color {
        theme == "light" ? .white : Color(red: 0.105, green: 0.135, blue: 0.175)
    }
    static func elevated(_ theme: String) -> Color {
        theme == "light" ? Color(red: 0.89, green: 0.93, blue: 0.97) : Color(red: 0.15, green: 0.19, blue: 0.24)
    }
    static func primary(_ theme: String) -> Color {
        theme == "light" ? Color(red: 0.10, green: 0.16, blue: 0.23) : .white
    }
    static func secondary(_ theme: String) -> Color {
        theme == "light" ? Color(red: 0.42, green: 0.50, blue: 0.58) : Color(red: 0.61, green: 0.70, blue: 0.79)
    }
    static func accent(_ theme: String) -> Color { AMProfileStyle.blue }
}

// MARK: - Native Liquid Glass dock (iOS 26/27) with iOS 17–25 fallback.
// Keeping the native glass effect behind a version check avoids changing the
// deployment target or any app configuration / saved user preferences.
private struct AMNativeGlassSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
private extension View {
    func amNativeGlass() -> some View { modifier(AMNativeGlassSurface()) }
}

// MARK: - Native-feeling motion (respects Reduce Motion)

private enum AMMotion {
    static let tab = Animation.spring(response: 0.38, dampingFraction: 0.84)
    static let tap = Animation.spring(response: 0.24, dampingFraction: 0.68)
    static let reveal = Animation.spring(response: 0.52, dampingFraction: 0.86)
    static let selection = Animation.easeInOut(duration: 0.22)
}

private struct AMPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("amusic.dev.reduceMotion") private var developerReduceMotion = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || developerReduceMotion ? 1 : (configuration.isPressed ? 0.965 : 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion || developerReduceMotion ? nil : AMMotion.tap, value: configuration.isPressed)
    }
}

private struct AMReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("amusic.dev.reduceMotion") private var developerReduceMotion = false
    let delay: Double
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || developerReduceMotion || appeared ? 1 : 0)
            .offset(y: reduceMotion || developerReduceMotion || appeared ? 0 : 15)
            .onAppear {
                if reduceMotion || developerReduceMotion {
                    appeared = true
                } else {
                    withAnimation(AMMotion.reveal.delay(delay)) {
                        appeared = true
                    }
                }
            }
            .onDisappear { appeared = false }
    }
}

private extension View {
    func amReveal(delay: Double = 0) -> some View {
        modifier(AMReveal(delay: delay))
    }
}

// MARK: - Provisioning expiry indicator
// Reads the app's embedded signing profile when available.
// If unavailable, falls back to a user-resettable seven-day estimate.
private enum AMSigningCountdown {
    static let sevenDays: TimeInterval = 7 * 24 * 60 * 60
    private static let estimateKey = "amusic.signingCountdownStarted"

    static func expiration() -> (date: Date, fromProfile: Bool) {
        if let expirationDate = profileExpirationDate() {
            return (expirationDate, true)
        }

        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: estimateKey)
        let startedAt: TimeInterval
        if stored > 0 {
            startedAt = stored
        } else {
            startedAt = Date().timeIntervalSince1970
            defaults.set(startedAt, forKey: estimateKey)
        }
        return (Date(timeIntervalSince1970: startedAt + sevenDays), false)
    }

    static func resetEstimate() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: estimateKey)
    }

    private static func profileExpirationDate() -> Date? {
        guard let url = Bundle.main.url(
            forResource: "embedded",
            withExtension: "mobileprovision"
        ), let bytes = try? Data(contentsOf: url),
           let xmlStart = bytes.range(of: Data("<?xml".utf8))?.lowerBound,
           let xmlEnd = bytes.range(of: Data("</plist>".utf8))?.upperBound,
           xmlStart < xmlEnd else {
            return nil
        }

        let xml = bytes.subdata(in: xmlStart..<xmlEnd)
        guard let properties = try? PropertyListSerialization.propertyList(
            from: xml,
            format: nil
        ) as? [String: Any] else {
            return nil
        }
        return properties["ExpirationDate"] as? Date
    }
}

private struct AMSigningCountdownView: View {
    let theme: String

    @State private var expirationDate: Date = .now.addingTimeInterval(7 * 24 * 60 * 60)
    @State private var isActualExpiration = false
    @State private var showResetConfirmation = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let remaining = max(0, expirationDate.timeIntervalSince(timeline.date))
            let fraction = min(1, remaining / AMSigningCountdown.sevenDays)
            let isExpired = remaining <= 0
            let remainingText: String = {
                if isExpired { return "Час оновити" }
                if remaining < 24 * 60 * 60 {
                    return "\(max(1, Int(ceil(remaining / 3600)))) год."
                }
                return "\(Int(ceil(remaining / 86400))) дн."
            }()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AMPalette.accent(theme))
                    Text("Підпис AMusic")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(remainingText)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(isExpired ? .red : AMPalette.accent(theme))
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(AMPalette.elevated(theme))
                        Capsule()
                            .fill(isExpired ? Color.red : AMPalette.accent(theme))
                            .frame(width: geometry.size.width * fraction)
                    }
                }
                .frame(height: 5)

                HStack(spacing: 8) {
                    Text(isActualExpiration
                         ? "За терміном профілю підпису"
                         : "Орієнтовно: 7 днів від запуску відліку")
                        .font(.system(size: 10))
                        .foregroundStyle(AMPalette.secondary(theme))

                    Spacer(minLength: 4)

                    if !isActualExpiration {
                        Button("Скинути") {
                            showResetConfirmation = true
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AMPalette.accent(theme))
                    }
                }
            }
            .padding(14)
            .background(AMPalette.card(theme))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "Почати новий 7-денний відлік?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Я повторно підписав AMusic") {
                AMSigningCountdown.resetEstimate()
                reload()
            }
            Button("Скасувати", role: .cancel) {}
        } message: {
            Text("Скидай таймер лише після повторного підписування або встановлення нового IPA. Це орієнтовний відлік, а не продовження підпису.")
        }
    }

    private func reload() {
        let result = AMSigningCountdown.expiration()
        expirationDate = result.date
        isActualExpiration = result.fromProfile
    }
}

// Compact waveform. Redraws only while the local audio player is playing.
private struct AMEqualizer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isPlaying: Bool
    let color: Color
    var count: Int = 5
    var maxHeight: CGFloat = 23
    var barWidth: CGFloat = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0,
                                paused: !isPlaying || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: barWidth * 0.9) {
                ForEach(0..<count, id: \.self) { index in
                    let level = isPlaying && !reduceMotion
                        ? (0.22 + 0.78 * abs(sin(time * (3.0 + Double(index % 3) * 0.55)
                                              + Double(index) * 1.15)))
                        : 0.3 + 0.15 * abs(sin(Double(index) * 1.5))
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: max(3, maxHeight * level))
                }
            }
            .frame(height: maxHeight)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Local music model and player (compatible with existing library)

struct MusicTrack: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var filename: String

    init(id: UUID = UUID(), title: String, filename: String) {
        self.id = id
        self.title = title
        self.filename = filename
    }
}

// MARK: - User playlists (stored separately from original track library)

struct AMPlaylist: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var trackIDs: [UUID] = []
}

// MARK: - AMusic 16.2 · Optional native 5-band EQ playback engine
// The standard AVAudioPlayer path is preserved when EQ is disabled.
@MainActor
private final class AMEQPlayback {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 5)
    private var file: AVAudioFile?
    private var originFrame: AVAudioFramePosition = 0
    private var pausedSeconds: Double = 0
    private var generation = 0
    var didFinish: (@MainActor () -> Void)?
    private let frequencies: [Float] = [80, 250, 1000, 4000, 12000]

    init() {
        engine.attach(node)
        engine.attach(pitch)
        engine.attach(equalizer)
        for (index, band) in equalizer.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = frequencies[index]
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        equalizer.globalGain = 0
    }

    var isPlaying: Bool { node.isPlaying }
    var duration: Double { guard let file else { return 0 }; return Double(file.length) / file.processingFormat.sampleRate }
    var currentTime: Double {
        guard let file else { return 0 }
        let sampleRate = file.processingFormat.sampleRate
        guard node.isPlaying, let render = node.lastRenderTime,
              let playback = node.playerTime(forNodeTime: render) else { return pausedSeconds }
        return min(duration, Double(originFrame) / sampleRate + Double(playback.sampleTime) / playback.sampleRate)
    }
    func load(_ url: URL, volume: Float, rate: Float, preset: String) throws {
        stop()
        let opened = try AVAudioFile(forReading: url)
        file = opened
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(pitch)
        engine.disconnectNodeOutput(equalizer)
        engine.connect(node, to: pitch, format: opened.processingFormat)
        engine.connect(pitch, to: equalizer, format: opened.processingFormat)
        engine.connect(equalizer, to: engine.mainMixerNode, format: opened.processingFormat)
        node.volume = volume
        pitch.rate = rate
        setPreset(preset)
        try engine.start()
        schedule(from: 0)
    }
    func setPreset(_ name: String) {
        let gains: [Float]
        switch name {
        case "bass": gains = [5, 3, 0, -1, -1]
        case "vocal": gains = [-2, 0, 4, 3, 1]
        case "classic": gains = [2, 1, 0, 2, 3]
        case "bright": gains = [-1, 0, 1, 3, 5]
        default: gains = [0, 0, 0, 0, 0]
        }
        for (i, gain) in gains.enumerated() { equalizer.bands[i].gain = gain }
    }
    func setVolume(_ newValue: Float) { node.volume = newValue }
    func setRate(_ newValue: Float) { pitch.rate = newValue }
    func play() -> Bool {
        if !engine.isRunning { do { try engine.start() } catch { return false } }
        node.play()
        return node.isPlaying
    }
    func pause() { pausedSeconds = currentTime; node.pause() }
    func stop() {
        generation += 1
        node.stop()
        engine.stop()
        file = nil
        pausedSeconds = 0
        originFrame = 0
    }
    func seek(_ seconds: Double) {
        guard file != nil else { return }
        let wasPlaying = node.isPlaying
        node.stop()
        schedule(from: min(max(0, seconds), duration))
        if wasPlaying { node.play() }
    }
    private func schedule(from seconds: Double) {
        guard let file else { return }
        generation += 1
        let token = generation
        let sampleRate = file.processingFormat.sampleRate
        let frame = AVAudioFramePosition(max(0, min(Double(file.length - 1), seconds * sampleRate)))
        originFrame = frame
        pausedSeconds = seconds
        let remaining = file.length - frame
        guard remaining > 0 else { return }
        let safeCount = AVAudioFrameCount(min(remaining, AVAudioFramePosition(UInt32.max)))
        node.scheduleSegment(file, startingFrame: frame, frameCount: safeCount, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.didFinish?()
            }
        }
    }
}

// AVAudioPlayer's completion callback is crucial in the background: a SwiftUI
// Timer may be suspended while the screen is locked, so it must not be relied
// upon to advance the queue.
@MainActor
private final class AMPlaybackCompletionHandler: NSObject, AVAudioPlayerDelegate {
    weak var store: MusicStore?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        store?.audioPlayerFinished(player, successfully: flag)
    }
}

@MainActor
final class MusicStore: ObservableObject {
    @Published var tracks: [MusicTrack] = []
    @Published var current: MusicTrack?
    @Published var isPlaying = false
    @Published var progress = 0.0
    @Published var duration = 0.0
    @Published var volume: Float = 1 { didSet { applyEffectiveVolume() } }
    @Published var rate: Float = 1 { didSet { player?.rate = rate; eqPlayer?.setRate(rate) } }
    @Published var equalizerEnabled = false
    @Published var equalizerPreset = "flat"
    @Published var repeatTrack = false
    @Published var shuffleEnabled = false
    @Published var smoothTransitionsEnabled = true
    @Published var favoriteIDs: Set<UUID> = []
    // AMusic Replay v1: per-track listening seconds and local daily activity.
    @Published private(set) var replaySecondsByTrack: [String: Double] = [:]
    @Published private(set) var replaySecondsByDay: [String: Double] = [:]
    // AMusic 16.9.5: lightweight usage index for sorting, not stored in audio metadata.
    @Published private(set) var playCountByTrack: [String: Int] = [:]
    @Published private(set) var lastPlayedByTrack: [String: Double] = [:]
    private var replayLastTick: Date?
    private var replayUnflushedSeconds: Double = 0
    @Published var playlists: [AMPlaylist] = []
    @Published var upcomingIDs: [UUID] = []
    @Published var artwork: [UUID: UIImage] = [:]
    @Published var errorMessage: String?
    // A listening-session timer. No library files or playlists are changed.
    @Published private(set) var sleepTimerEnd: Date?
    @Published private(set) var sleepAfterCurrentTrack = false

    private var sleepTimer: Timer?
    // Volume fades only while the app is active; lock-screen playback stays at full volume.
    private var volumeRamp: Timer?
    private var fadeGeneration = 0
    private var fadeLevel: Float = 1

    private var player: AVAudioPlayer?
    private var eqPlayer: AMEQPlayback?
    private let playbackCompletion = AMPlaybackCompletionHandler()
    private var timer: Timer?
    private var contextIDs: [UUID] = []
    private var playedHistory: [UUID] = []
    // Smart Shuffle: a shuffled bag of unplayed tracks, not a new random pick on every skip.
    // The forward stack allows Next to restore a song after the listener goes Back.
    private var shuffleRemainingIDs: [UUID] = []
    private var shuffleForwardIDs: [UUID] = []
    private var artworkRequested: Set<UUID> = []

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // User-selected cover images live separately from the audio files.
    private func customArtworkURL(for id: UUID) -> URL {
        documents.appendingPathComponent("amusic_cover_\(id.uuidString).jpg")
    }

    func hasCustomArtwork(_ track: MusicTrack) -> Bool {
        FileManager.default.fileExists(atPath: customArtworkURL(for: track.id).path)
    }

    /// Keep the original UUID/filename so favorites, playlists and the queue stay intact.
    @discardableResult
    func editTrack(_ track: MusicTrack, title: String, newCover: UIImage?, removeCover: Bool) -> Bool {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return false }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Вкажи назву композиції."
            return false
        }

        let coverURL = customArtworkURL(for: track.id)
        if let newCover {
            // Resize large iPhone photos for fast loading and small storage use.
            let limit: CGFloat = 1200
            let ratio = min(1, limit / max(max(newCover.size.width, newCover.size.height), 1))
            let size = CGSize(width: max(1, newCover.size.width * ratio),
                              height: max(1, newCover.size.height * ratio))
            let reduced = UIGraphicsImageRenderer(size: size).image { _ in
                newCover.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let bytes = reduced.jpegData(compressionQuality: 0.83) else {
                errorMessage = "Не вдалося підготувати обкладинку."
                return false
            }
            do {
                try bytes.write(to: coverURL, options: .atomic)
                artwork[track.id] = reduced
                artworkRequested.insert(track.id)
            } catch {
                errorMessage = "Не вдалося зберегти обкладинку: \(error.localizedDescription)"
                return false
            }
        } else if removeCover {
            do {
                if FileManager.default.fileExists(atPath: coverURL.path) {
                    try FileManager.default.removeItem(at: coverURL)
                }
            } catch {
                errorMessage = "Не вдалося прибрати обкладинку."
                return false
            }
            artwork.removeValue(forKey: track.id)
            artworkRequested.remove(track.id)
        }

        tracks[index].title = String(name.prefix(100))
        if current?.id == track.id {
            current = tracks[index]
        }
        saveLibrary()
        if removeCover && newCover == nil {
            requestArtwork(for: tracks[index]) // Restore embedded MP3/M4A image when available.
        }
        if current?.id == track.id { updateNowPlaying() }
        return true
    }

    var favorites: [MusicTrack] { tracks.filter { favoriteIDs.contains($0.id) } }
    var queueTracks: [MusicTrack] {
        upcomingIDs.compactMap { id in tracks.first { $0.id == id } }
    }

    init() {
        volume = UserDefaults.standard.object(forKey: "amusic.volume") as? Float ?? 1
        rate = UserDefaults.standard.object(forKey: "amusic.rate") as? Float ?? 1
        repeatTrack = UserDefaults.standard.bool(forKey: "amusic.repeat")
        shuffleEnabled = UserDefaults.standard.bool(forKey: "amusic.shuffle")
        if UserDefaults.standard.object(forKey: "amusic.smartPlayer.transitions.v1") != nil {
            smoothTransitionsEnabled = UserDefaults.standard.bool(forKey: "amusic.smartPlayer.transitions.v1")
        }
        equalizerEnabled = UserDefaults.standard.bool(forKey: "amusic.eq.enabled.v1")
        equalizerPreset = UserDefaults.standard.string(forKey: "amusic.eq.preset.v1") ?? "flat"
        loadLibrary()
        loadCollections()
        if let saved = UserDefaults.standard.dictionary(forKey: "amusic.replay.seconds.tracks.v1") as? [String: Double] { replaySecondsByTrack = saved }
        if let saved = UserDefaults.standard.dictionary(forKey: "amusic.replay.seconds.days.v1") as? [String: Double] { replaySecondsByDay = saved }
        if let saved = UserDefaults.standard.dictionary(forKey: "amusic.library.plays.v1") as? [String: Int] { playCountByTrack = saved }
        if let saved = UserDefaults.standard.dictionary(forKey: "amusic.library.lastPlayed.v1") as? [String: Double] { lastPlayedByTrack = saved }
        playbackCompletion.store = self
        if let saved = UserDefaults.standard.object(forKey: "amusic.smartPlayer.sleepDeadline.v1") as? Date,
           saved > Date() {
            sleepTimerEnd = saved
            armSleepTimer()
        } else {
            UserDefaults.standard.removeObject(forKey: "amusic.smartPlayer.sleepDeadline.v1")
        }
        configureAudio()
        configureRemoteCommands()
    }

    // Local music must use an explicit playback session; background playback also
    // requires `UIBackgroundModes: [audio]` in the Info.plist embedded in the IPA.
    private func configureAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            errorMessage = "Не вдалося налаштувати аудіо: \(error.localizedDescription)"
        }
    }

    private func activateAudioForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func loadLibrary() {
        if let data = UserDefaults.standard.data(forKey: "amusic.library"),
           let saved = try? JSONDecoder().decode([MusicTrack].self, from: data) {
            tracks = saved.filter {
                FileManager.default.fileExists(atPath: documents.appendingPathComponent($0.filename).path)
            }
        }
    }

    private func saveLibrary() {
        if let data = try? JSONEncoder().encode(tracks) {
            UserDefaults.standard.set(data, forKey: "amusic.library")
        }
    }

    private func loadCollections() {
        let decoder = JSONDecoder()
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "amusic.favorites.v1"),
           let ids = try? decoder.decode([UUID].self, from: data) {
            favoriteIDs = Set(ids).intersection(Set(tracks.map(\.id)))
        }
        if let data = defaults.data(forKey: "amusic.playlists.v1"),
           let saved = try? decoder.decode([AMPlaylist].self, from: data) {
            playlists = saved
        }
        if let data = defaults.data(forKey: "amusic.queue.v1"),
           let ids = try? decoder.decode([UUID].self, from: data) {
            upcomingIDs = ids.filter { id in tracks.contains { $0.id == id } }
        }
    }

    private func saveCollections() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(Array(favoriteIDs)), forKey: "amusic.favorites.v1")
        defaults.set(try? JSONEncoder().encode(playlists), forKey: "amusic.playlists.v1")
        defaults.set(try? JSONEncoder().encode(upcomingIDs), forKey: "amusic.queue.v1")
    }

    // Telegram Sync: a stable source ID prevents repeat imports across launches.
    @discardableResult
    func importSyncedAudio(_ data: Data, name: String, sourceID: UUID) throws -> Bool {
        let key = "amusic.telegramSync.importedIDs.v1"
        let known = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let identifier = sourceID.uuidString.lowercased()
        guard !known.contains(identifier) else { return false }
        guard !data.isEmpty, data.count <= 25 * 1024 * 1024 else {
            throw NSError(domain: "AMusicSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "MP3 має бути до 25 МБ"])
        }
        let fileName = UUID().uuidString + ".mp3"
        try data.write(to: documents.appendingPathComponent(fileName), options: .atomic)
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tracks.append(MusicTrack(title: String((clean.isEmpty ? "Telegram Music" : clean).prefix(150)), filename: fileName))
        saveLibrary()
        UserDefaults.standard.set(Array(known.union([identifier])), forKey: key)
        return true
    }

    func importFiles(_ urls: [URL]) {
        var failed = 0
        for url in urls {
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension.lowercased()
            let filename = UUID().uuidString + "." + ext
            do {
                try FileManager.default.copyItem(at: url, to: documents.appendingPathComponent(filename))
                tracks.append(MusicTrack(title: url.deletingPathExtension().lastPathComponent, filename: filename))
            } catch { failed += 1 }
        }
        saveLibrary()
        if failed > 0 { errorMessage = "Не вдалося імпортувати файлів: \(failed)" }
    }

    func isFavorite(_ track: MusicTrack) -> Bool { favoriteIDs.contains(track.id) }

    func toggleFavorite(_ track: MusicTrack) {
        if favoriteIDs.contains(track.id) { favoriteIDs.remove(track.id) }
        else { favoriteIDs.insert(track.id) }
        saveCollections()
    }

    @discardableResult
    func createPlaylist(_ name: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        playlists.append(AMPlaylist(name: String(value.prefix(45))))
        saveCollections()
        return true
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = String(trimmed.prefix(45))
        saveCollections()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        saveCollections()
    }

    func playlistTracks(_ id: UUID) -> [MusicTrack] {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return [] }
        return playlist.trackIDs.compactMap { key in tracks.first { $0.id == key } }
    }

    func add(_ track: MusicTrack, to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        if !playlists[index].trackIDs.contains(track.id) {
            playlists[index].trackIDs.append(track.id)
            saveCollections()
        }
    }

    func remove(_ track: MusicTrack, from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.removeAll { $0 == track.id }
        saveCollections()
    }

    func addToQueue(_ track: MusicTrack) {
        upcomingIDs.append(track.id)
        saveCollections()
    }

    func playNext(_ track: MusicTrack) {
        upcomingIDs.insert(track.id, at: 0)
        saveCollections()
    }

    // Keep stable queue order while supporting native List drag-to-reorder.
    func reorderQueue(from source: IndexSet, to destination: Int) {
        upcomingIDs.move(fromOffsets: source, toOffset: destination)
        saveCollections()
    }

    func moveQueueItemToFront(at index: Int) {
        guard upcomingIDs.indices.contains(index), index != 0 else { return }
        let item = upcomingIDs.remove(at: index)
        upcomingIDs.insert(item, at: 0)
        saveCollections()
    }

    func removeQueueItem(at index: Int) {
        guard upcomingIDs.indices.contains(index) else { return }
        upcomingIDs.remove(at: index)
        saveCollections()
    }

    func moveQueueItem(at index: Int, direction: Int) {
        let nextIndex = index + direction
        guard upcomingIDs.indices.contains(index), upcomingIDs.indices.contains(nextIndex) else { return }
        upcomingIDs.swapAt(index, nextIndex)
        saveCollections()
    }

    func clearQueue() {
        upcomingIDs.removeAll()
        saveCollections()
    }

    // Build a fresh cycle in which each track occurs at most once.
    // Exclude the current track so a cycle boundary cannot repeat it immediately.
    private func resetShuffleCycle(excluding currentID: UUID?) {
        let source = contextIDs.compactMap { id in tracks.first { $0.id == id } }
        let pool = source.isEmpty ? tracks : source
        var seen = Set<UUID>()
        shuffleRemainingIDs = pool.map(\.id)
            .filter { id in id != currentID && seen.insert(id).inserted }
            .shuffled()
    }

    func updateShuffle(_ enabled: Bool) {
        guard shuffleEnabled != enabled else { return }
        shuffleEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "amusic.shuffle")
        shuffleForwardIDs.removeAll()
        if enabled {
            resetShuffleCycle(excluding: current?.id)
        } else {
            shuffleRemainingIDs.removeAll()
        }
    }

    func play(_ track: MusicTrack, from collection: [MusicTrack]? = nil) {
        let chosen = collection ?? tracks
        contextIDs = chosen.map(\.id)
        if !contextIDs.contains(track.id) { contextIDs.insert(track.id, at: 0) }
        playedHistory.removeAll()
        shuffleForwardIDs.removeAll()
        resetShuffleCycle(excluding: track.id)
        startPlaying(track)
    }

    // AMusic Smart Player: one shared fade state works with AVAudioPlayer and the EQ engine.
    // The actual audio files, track UUIDs and shuffle queue are never modified.
    private func applyEffectiveVolume() {
        let effective = max(0, min(1, volume * fadeLevel))
        player?.volume = effective
        eqPlayer?.setVolume(effective)
    }

    private func cancelVolumeRamp(reset: Bool = true) {
        fadeGeneration += 1
        volumeRamp?.invalidate()
        volumeRamp = nil
        if reset {
            fadeLevel = 1
            applyEffectiveVolume()
        }
    }

    private func rampVolume(to target: Float, over seconds: TimeInterval,
                            completion: (@MainActor () -> Void)? = nil) {
        cancelVolumeRamp(reset: false)
        let generation = fadeGeneration
        let initial = fadeLevel
        let start = Date()
        guard seconds > 0 else {
            fadeLevel = target
            applyEffectiveVolume()
            completion?()
            return
        }
        let fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { [weak self] tickTimer in
            // Timer is not Sendable; do not capture it in a MainActor task.
            guard self != nil else { tickTimer.invalidate(); return }
            Task { @MainActor [weak self] in
                guard let self, self.fadeGeneration == generation else { return }
                // Restore full volume if the app became inactive during a fade.
                guard UIApplication.shared.applicationState == .active else {
                    self.cancelVolumeRamp()
                    return
                }
                let fraction = Float(min(1, Date().timeIntervalSince(start) / seconds))
                self.fadeLevel = initial + (target - initial) * fraction
                self.applyEffectiveVolume()
                if fraction >= 1 {
                    self.volumeRamp?.invalidate()
                    self.volumeRamp = nil
                    completion?()
                }
            }
        }
        RunLoop.main.add(fadeTimer, forMode: .common)
        volumeRamp = fadeTimer
    }

    private func transition(_ action: @escaping @MainActor () -> Void) {
        guard smoothTransitionsEnabled, isPlaying, current != nil,
              UIApplication.shared.applicationState == .active else {
            cancelVolumeRamp()
            action()
            return
        }
        rampVolume(to: 0.12, over: 0.26, completion: action)
    }

    func changeSmoothTransitions(_ enabled: Bool) {
        smoothTransitionsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "amusic.smartPlayer.transitions.v1")
        if !enabled { cancelVolumeRamp() }
    }

    func sceneActivityChanged(isActive: Bool) {
        if !isActive { cancelVolumeRamp() }
        else { _ = checkSleepDeadline() }
    }

    private func notePlaybackStart(_ track: MusicTrack) {
        let key = track.id.uuidString
        playCountByTrack[key, default: 0] += 1
        lastPlayedByTrack[key] = Date().timeIntervalSince1970
        let defaults = UserDefaults.standard
        defaults.set(playCountByTrack, forKey: "amusic.library.plays.v1")
        defaults.set(lastPlayedByTrack, forKey: "amusic.library.lastPlayed.v1")
    }

    private func startPlaying(_ track: MusicTrack, recordListen: Bool = true) {
        flushReplay()
        replayLastTick = nil
        cancelVolumeRamp()
        let fadeIn = smoothTransitionsEnabled && UIApplication.shared.applicationState == .active
        fadeLevel = fadeIn ? 0.2 : 1
        let url = documents.appendingPathComponent(track.filename)
        do {
            try activateAudioForPlayback()
            timer?.invalidate()
            player?.stop()
            eqPlayer?.stop()
            if equalizerEnabled {
                let eq = eqPlayer ?? AMEQPlayback()
                eqPlayer = eq
                eq.didFinish = { [weak self] in self?.eqTrackFinished() }
                try eq.load(url, volume: volume * fadeLevel, rate: rate, preset: equalizerPreset)
                player = nil
                current = track
                duration = eq.duration
                progress = 0
                resume()
            if recordListen && isPlaying { notePlaybackStart(track) }
                if fadeIn && isPlaying { rampVolume(to: 1, over: 0.56) }
                requestArtwork(for: track)
                return
            }
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.delegate = playbackCompletion
            audio.enableRate = true
            audio.volume = volume * fadeLevel
            audio.rate = rate
            audio.prepareToPlay()
            player = audio
            current = track
            duration = audio.duration
            progress = 0
            resume()
            if recordListen && isPlaying { notePlaybackStart(track) }
            if fadeIn && isPlaying { rampVolume(to: 1, over: 0.56) }
            requestArtwork(for: track)
        } catch {
            isPlaying = false
            errorMessage = "Не вдалося відкрити композицію."
        }
    }

    func resume() {
        if checkSleepDeadline() { return }
        if equalizerEnabled, let eqPlayer {
            do { try activateAudioForPlayback() }
            catch { errorMessage = "Помилка аудіосесії: \(error.localizedDescription)"; return }
            isPlaying = eqPlayer.play()
            if isPlaying { startTimer() }
            updateNowPlaying()
            return
        }
        guard let player else {
            if let first = tracks.first { play(first) }
            return
        }
        do {
            try activateAudioForPlayback()
        } catch {
            isPlaying = false
            errorMessage = "Не вдалося відновити звук: \(error.localizedDescription)"
            updateNowPlaying()
            return
        }
        isPlaying = player.play()
        player.rate = rate
        if isPlaying { startTimer() }
        updateNowPlaying()
    }

    func pause() {
        cancelVolumeRamp()
        flushReplay()
        replayLastTick = nil
        if equalizerEnabled, let eqPlayer {
            eqPlayer.pause()
            progress = eqPlayer.currentTime
            isPlaying = false
            timer?.invalidate()
            updateNowPlaying()
            return
        }
        player?.pause()
        progress = player?.currentTime ?? progress
        isPlaying = false
        timer?.invalidate()
        updateNowPlaying()
    }

    func toggle() { isPlaying ? pause() : resume() }

    private func eqTrackFinished() {
        guard equalizerEnabled, eqPlayer != nil else { return }
        timer?.invalidate()
        if finishSleepAfterTrack() || checkSleepDeadline() { return }
        if repeatTrack { seek(0); resume() } else { advance() }
    }

    func changeEqualizerEnabled(_ enabled: Bool) {
        let position = progress
        let shouldResume = isPlaying
        equalizerEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "amusic.eq.enabled.v1")
        if let current {
            startPlaying(current, recordListen: false)
            seek(position)
            if !shouldResume { pause() }
        }
    }

    func changeEqualizerPreset(_ preset: String) {
        equalizerPreset = preset
        UserDefaults.standard.set(preset, forKey: "amusic.eq.preset.v1")
        eqPlayer?.setPreset(preset)
    }

    // Called by AVAudioPlayer itself, including while the iPhone is locked.
    // Ignore completions from an old player after the user skips a track.
    fileprivate func audioPlayerFinished(_ finishedPlayer: AVAudioPlayer, successfully: Bool) {
        guard let player, player === finishedPlayer else { return }
        timer?.invalidate()
        if finishSleepAfterTrack() || checkSleepDeadline() { return }
        if successfully {
            if repeatTrack {
                seek(0)
                resume()
            } else {
                advance()
            }
        } else {
            pause()
            errorMessage = "Не вдалося завершити відтворення композиції."
        }
    }

    func next() { transition { [weak self] in self?.advance() } }

    private func advance() {
        if checkSleepDeadline() { return }
        guard !tracks.isEmpty else { return }
        var nextTrack: MusicTrack?
        var removedQueueItem = false

        // Explicit user queue always wins over shuffle. Silently discard missing IDs
        // instead of recursively calling advance() for every stale queue entry.
        while !upcomingIDs.isEmpty {
            let id = upcomingIDs.removeFirst()
            removedQueueItem = true
            if let match = tracks.first(where: { $0.id == id }) {
                nextTrack = match
                break
            }
        }
        if removedQueueItem {
            saveCollections()
            shuffleForwardIDs.removeAll()
        }

        if nextTrack == nil {
            let context = contextIDs.compactMap { id in tracks.first { $0.id == id } }
            let pool = context.isEmpty ? tracks : context
            if shuffleEnabled {
                let valid = Set(pool.map(\.id))

                // When Previous was used, Next follows that exact listening history.
                while let id = shuffleForwardIDs.popLast() {
                    if id != current?.id, let restored = tracks.first(where: { $0.id == id }) {
                        nextTrack = restored
                        break
                    }
                }

                if nextTrack == nil {
                    // The shuffled bag is created once per cycle; never pick with
                    // randomElement() on every press of Next.
                    shuffleRemainingIDs.removeAll { !valid.contains($0) || $0 == current?.id }
                    if shuffleRemainingIDs.isEmpty {
                        resetShuffleCycle(excluding: current?.id)
                    }
                    while !shuffleRemainingIDs.isEmpty {
                        let id = shuffleRemainingIDs.removeLast()
                        if let candidate = tracks.first(where: { $0.id == id }) {
                            nextTrack = candidate
                            break
                        }
                    }
                    // A one-song library has no different song to advance to.
                    if nextTrack == nil { nextTrack = pool.first }
                }
            } else if !pool.isEmpty {
                let index = pool.firstIndex { $0.id == current?.id } ?? -1
                nextTrack = pool[(index + 1) % pool.count]
            }
        }

        guard let track = nextTrack else { return }
        // Manually queued songs and restored history also count as consumed.
        if shuffleEnabled {
            shuffleRemainingIDs.removeAll { $0 == track.id }
        }
        if let current { playedHistory.append(current.id) }
        startPlaying(track)
    }

    func previous() { transition { [weak self] in self?.performPrevious() } }

    private func performPrevious() {
        guard !tracks.isEmpty else { return }
        if progress > 3 { seek(0); return }
        while let id = playedHistory.popLast() {
            if let track = tracks.first(where: { $0.id == id }) {
                if shuffleEnabled, let current, current.id != track.id {
                    shuffleForwardIDs.append(current.id)
                }
                startPlaying(track)
                return
            }
        }
        // In Shuffle, don't jump to an arbitrary previous song that was never played.
        if shuffleEnabled { seek(0); return }
        let pool = contextIDs.compactMap { id in tracks.first { $0.id == id } }
        let source = pool.isEmpty ? tracks : pool
        let index = source.firstIndex { $0.id == current?.id } ?? 0
        startPlaying(source[(index - 1 + source.count) % source.count])
    }

    func seek(_ seconds: Double) {
        cancelVolumeRamp()
        if equalizerEnabled, let eqPlayer {
            eqPlayer.seek(seconds)
            progress = eqPlayer.currentTime
            updateNowPlaying()
            return
        }
        guard let player else { return }
        player.currentTime = min(max(0, seconds), duration)
        progress = player.currentTime
        updateNowPlaying()
    }

    func delete(_ track: MusicTrack) {
        if current?.id == track.id {
            cancelVolumeRamp()
            timer?.invalidate()
            player?.stop()
            eqPlayer?.stop()
            player = nil
            current = nil
            isPlaying = false
            progress = 0
            duration = 0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        try? FileManager.default.removeItem(at: documents.appendingPathComponent(track.filename))
        try? FileManager.default.removeItem(at: customArtworkURL(for: track.id))
        tracks.removeAll { $0.id == track.id }
        favoriteIDs.remove(track.id)
        upcomingIDs.removeAll { $0 == track.id }
        contextIDs.removeAll { $0 == track.id }
        playedHistory.removeAll { $0 == track.id }
        shuffleRemainingIDs.removeAll { $0 == track.id }
        shuffleForwardIDs.removeAll { $0 == track.id }
        artwork.removeValue(forKey: track.id)
        playCountByTrack.removeValue(forKey: track.id.uuidString)
        lastPlayedByTrack.removeValue(forKey: track.id.uuidString)
        UserDefaults.standard.set(playCountByTrack, forKey: "amusic.library.plays.v1")
        UserDefaults.standard.set(lastPlayedByTrack, forKey: "amusic.library.lastPlayed.v1")
        for i in playlists.indices {
            playlists[i].trackIDs.removeAll { $0 == track.id }
        }
        saveLibrary()
        saveCollections()
    }

    func updateVolume(_ value: Double) {
        volume = Float(value)
        UserDefaults.standard.set(volume, forKey: "amusic.volume")
    }

    func updateRate(_ value: Float) {
        rate = value
        UserDefaults.standard.set(rate, forKey: "amusic.rate")
        updateNowPlaying()
    }

    func updateRepeat(_ value: Bool) {
        repeatTrack = value
        UserDefaults.standard.set(value, forKey: "amusic.repeat")
    }

    func scheduleSleepTimer(minutes: Int) {
        cancelSleepTimer()
        guard minutes > 0 else { return }
        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEnd = deadline
        UserDefaults.standard.set(deadline, forKey: "amusic.smartPlayer.sleepDeadline.v1")
        armSleepTimer()
    }

    func scheduleSleepAfterCurrentTrack() {
        cancelSleepTimer()
        sleepAfterCurrentTrack = true
    }

    private func armSleepTimer() {
        sleepTimer?.invalidate()
        guard let end = sleepTimerEnd else { return }
        let seconds = max(0.1, end.timeIntervalSinceNow)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.checkSleepDeadline() { self.armSleepTimer() }
            }
        }
    }

    @discardableResult
    private func checkSleepDeadline() -> Bool {
        guard let end = sleepTimerEnd, Date() >= end else { return false }
        cancelSleepTimer()
        pause()
        return true
    }

    private func finishSleepAfterTrack() -> Bool {
        guard sleepAfterCurrentTrack else { return false }
        cancelSleepTimer()
        pause()
        return true
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerEnd = nil
        sleepAfterCurrentTrack = false
        UserDefaults.standard.removeObject(forKey: "amusic.smartPlayer.sleepDeadline.v1")
    }

    // Artwork embedded in MP3/M4A; if none exists the UI displays a waveform.
    func requestArtwork(for track: MusicTrack) {
        // Custom art has priority over metadata embedded in the original song.
        if let custom = UIImage(contentsOfFile: customArtworkURL(for: track.id).path) {
            if artwork[track.id] == nil {
                artwork[track.id] = custom
                if current?.id == track.id { updateNowPlaying() }
            }
            artworkRequested.insert(track.id)
            return
        }
        guard !artworkRequested.contains(track.id) else { return }
        artworkRequested.insert(track.id)
        let fileURL = documents.appendingPathComponent(track.filename)
        Task {
            do {
                let asset = AVURLAsset(url: fileURL)
                let metadata = try await asset.load(.commonMetadata)
                if let item = metadata.first(where: { $0.commonKey?.rawValue == "artwork" }),
                   let bytes = try await item.load(.dataValue),
                   let image = UIImage(data: bytes),
                   !FileManager.default.fileExists(atPath: customArtworkURL(for: track.id).path) {
                    artwork[track.id] = image
                    if current?.id == track.id { updateNowPlaying() }
                }
            } catch { /* Artwork is optional. */ }
        }
    }

    private func recordReplayTick() {
        let now = Date()
        defer { replayLastTick = now }
        guard isPlaying, let track = current else { return }
        let elapsed = min(max(now.timeIntervalSince(replayLastTick ?? now), 0), 1.5)
        guard elapsed > 0 else { return }
        replaySecondsByTrack[track.id.uuidString, default: 0] += elapsed
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: now)
        replaySecondsByDay[day, default: 0] += elapsed
        replayUnflushedSeconds += elapsed
        if replayUnflushedSeconds >= 10 { flushReplay() }
    }

    private func flushReplay() {
        UserDefaults.standard.set(replaySecondsByTrack, forKey: "amusic.replay.seconds.tracks.v1")
        UserDefaults.standard.set(replaySecondsByDay, forKey: "amusic.replay.seconds.days.v1")
        replayUnflushedSeconds = 0
    }

    private func startTimer() {
        replayLastTick = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.checkSleepDeadline() { return }
                self.recordReplayTick()
                if self.equalizerEnabled, let eq = self.eqPlayer {
                    self.progress = eq.currentTime
                    return
                }
                guard let player = self.player else { return }
                self.progress = player.currentTime
                // The completion delegate (not this UI timer) moves to the next track.
                // This timer is only for the on-screen progress indicator.
                if self.isPlaying && !player.isPlaying &&
                   player.currentTime < player.duration - 0.3 {
                    self.pause()
                }
            }
        }
    }

    private func updateNowPlaying() {
        guard let current else { return }
        var data: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: "AMusic",
            MPMediaItemPropertyAlbumTitle: "Локальна бібліотека",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let image = artwork[current.id] {
            data[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = data
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        // Native controls in Lock Screen / Control Center / headphones.
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.toggle() }
            return .success
        }
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.seek(max(0, self.progress - interval))
            }
            return .success
        }
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.seek(min(self.duration, self.progress + interval))
            }
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.previous() }
            return .success
        }
        // Allow seeking directly from the iOS lock screen / Control Center.
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let seconds = event.positionTime
            Task { @MainActor [weak self] in self?.seek(seconds) }
            return .success
        }
    }
}

// MARK: - App screens · AMusic Studio Edition

private enum AMTab: String, CaseIterable {
    case music = "Музика"
    case youtube = "YouTube"
    case profile = "Профіль"

    var icon: String {
        switch self {
        case .music: return "music.note.list"
        case .youtube: return "play.rectangle"
        case .profile: return "person.crop.circle"
        }
    }
}

// AMusic 16.9.4 · independent Settings sections.
private enum AMSettingsPage: String, CaseIterable {
    case player = "Звук і відтворення"
    case playerUI = "Вигляд плеєра"
    case library = "Медіатека"
    case sync = "Cloud та синхронізація"
    case appearance = "Оформлення"
    case navigation = "Навігація"
    case interaction = "Керування"
    case about = "Про AMusic"

    var symbol: String {
        switch self {
        case .player: return "waveform"
        case .playerUI: return "play.rectangle.on.rectangle"
        case .library: return "music.note.list"
        case .sync: return "icloud"
        case .appearance: return "paintpalette"
        case .navigation: return "square.grid.2x2"
        case .interaction: return "hand.tap"
        case .about: return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .player: return "Еквалайзер, Smart Shuffle, швидкість і таймер"
        case .playerUI: return "Обкладинка, анімації та елементи плеєра"
        case .library: return "Сортування, списки та захист від видалення"
        case .sync: return "Telegram Sync і приватний AMusic Cloud"
        case .appearance: return "Світла чи темна тема, мініплеєр"
        case .navigation: return "Вкладки й екран запуску"
        case .interaction: return "Жести, вібровідгук і зменшення руху"
        case .about: return "Версія, система та збереження даних"
        }
    }
}

// The system launch screen stays static; this intro begins when SwiftUI is ready.
// AMusic 16.9.5 · Welcome Wave. Native animation only; no video, web or external assets.
// The SwiftUI launch overlay deliberately does not modify the static OS launch screen.
// MARK: - Letter «A» emblem (launch animation geometry)
// Both shapes live in a 200x220 design box so they scale cleanly in any frame.
private struct AMLetterA: Shape {
    func path(in rect: CGRect) -> Path {
        let scaleX = rect.width / 200
        let scaleY = rect.height / 220
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scaleX, y: rect.minY + y * scaleY)
        }
        var path = Path()
        // One continuous stroke: left foot -> apex -> right foot,
        // so the launch animation reads like the letter is being written.
        path.move(to: point(30, 206))
        path.addLine(to: point(100, 14))
        path.addLine(to: point(170, 206))
        return path
    }
}

private struct AMLetterACrossbar: Shape {
    func path(in rect: CGRect) -> Path {
        let scaleX = rect.width / 200
        let scaleY = rect.height / 220
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scaleX, y: rect.minY + y * scaleY)
        }
        var path = Path()
        path.move(to: point(57, 132))
        path.addLine(to: point(143, 132))
        return path
    }
}

private struct AMLaunchAnimation: View {
    let theme: String
    let reduceMotion: Bool
    let onComplete: () -> Void
    @State private var arrived = false
    @State private var glow = false
    @State private var waveOn = false
    @State private var revealed = false
    @State private var loading: CGFloat = 0
    @State private var departing = false

    private var tone: Color { AMProfileStyle.blue }

    var body: some View {
        ZStack {
            AMPalette.background(theme).ignoresSafeArea()

            RadialGradient(
                colors: [tone.opacity(theme == "light" ? 0.13 : 0.22), .clear],
                center: .center, startRadius: 18, endRadius: 260
            )
            .scaleEffect(arrived ? 1.28 : 0.65)
            .opacity(departing ? 0 : 1)
            .ignoresSafeArea()

            VStack(spacing: 26) {
                emblem

                VStack(spacing: 9) {
                    Text("AMusic")
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .tracking(-1.5)
                        .foregroundStyle(AMPalette.primary(theme))
                    Text("YOUR MUSIC. YOUR SPACE.")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .tracking(2.8)
                        .foregroundStyle(AMPalette.secondary(theme))
                }
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 11)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tone.opacity(0.13))
                        Capsule()
                            .fill(LinearGradient(colors: [tone.opacity(0.55), tone],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geometry.size.width * loading)
                    }
                }
                .frame(width: 120, height: 3)
                .opacity(revealed ? 1 : 0)
                .accessibilityHidden(true)
            }
            .offset(y: departing ? -12 : 0)
            .opacity(departing ? 0 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Запуск AMusic")
        .task {
            do {
                if reduceMotion {
                    try await Task.sleep(for: .milliseconds(120))
                    onComplete()
                    return
                }
                withAnimation(.spring(response: 0.9, dampingFraction: 0.82)) { arrived = true }
                withAnimation(.easeOut(duration: 0.7)) { glow = true }
                try await Task.sleep(for: .milliseconds(430))
                withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { waveOn = true }
                try await Task.sleep(for: .milliseconds(230))
                withAnimation(.easeOut(duration: 0.43)) { revealed = true }
                withAnimation(.easeInOut(duration: 1.0)) { loading = 1 }
                try await Task.sleep(for: .milliseconds(1130))
                withAnimation(.easeInOut(duration: 0.26)) { departing = true }
                try await Task.sleep(for: .milliseconds(270))
                onComplete()
            } catch {
                // SwiftUI cancelled the launch view; do not change navigation afterwards.
            }
        }
    }

    private var emblem: some View {
        ZStack {
            Circle()
                .stroke(tone.opacity(0.13), lineWidth: 1)
                .frame(width: 230, height: 230)
            Circle()
                .stroke(tone.opacity(0.25), lineWidth: 1)
                .frame(width: 192, height: 192)
                .scaleEffect(arrived ? 1.08 : 0.72)
            Circle()
                .fill(tone.opacity(0.10))
                .frame(width: 150, height: 150)
                .blur(radius: 20)

            ZStack {
                // Soft letter-shaped glow that fades in behind the stroke.
                AMLetterA()
                    .fill(tone.opacity(0.14))
                    .blur(radius: 24)
                    .opacity(glow ? 1 : 0)

                // The letter draws itself in one continuous motion.
                AMLetterA()
                    .trim(from: 0, to: arrived ? 1 : 0)
                    .stroke(tone, style: StrokeStyle(lineWidth: 15, lineCap: .round, lineJoin: .round))

                AMLetterACrossbar()
                    .trim(from: 0, to: arrived ? 1 : 0)
                    .stroke(tone.opacity(0.9), style: StrokeStyle(lineWidth: 7, lineCap: .round))

                // The crossbar of the «A» is a living waveform.
                // Each layer has its own phase and speed for a fluid audio feel.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { tick in
                    Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                        let moment = reduceMotion ? 0 : tick.date.timeIntervalSinceReferenceDate
                        let mid = size.height / 2
                        for layer in 0..<3 {
                            let intensity = CGFloat(0.55 + Double(layer) * 0.24)
                            let amplitude: CGFloat = waveOn ? 15 : 2
                            var path = Path()
                            for x in stride(from: CGFloat(0), through: size.width, by: 2) {
                                // Split Double/CGFloat expressions to keep Swift 6 type-checking fast.
                                let relative: Double = Double(x / max(size.width, 1))
                                let layerNumber: Double = Double(layer)
                                let waveFrequency: Double = 7.0 + layerNumber * 2.1
                                let waveSpeed: Double = 2.6 + layerNumber * 0.34
                                let phaseShift: Double = layerNumber * 1.1
                                let spatialPhase: Double = relative * waveFrequency * Double.pi
                                let temporalPhase: Double = moment * waveSpeed
                                let waveAngle: Double = spatialPhase - temporalPhase + phaseShift
                                let wave: Double = sin(waveAngle)
                                let envelopeBase: Double = max(0.0, sin(relative * Double.pi))
                                let envelope: Double = pow(envelopeBase, 1.4)
                                let waveHeight: CGFloat = CGFloat(wave * envelope)
                                let volumeScale: CGFloat = amplitude * intensity * 0.6
                                let y: CGFloat = mid + waveHeight * volumeScale
                                if x == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                            context.stroke(path, with: .color(tone.opacity(layer == 0 ? 0.95 : 0.22)),
                                           style: StrokeStyle(lineWidth: layer == 0 ? 3.2 : 1.3,
                                                              lineCap: .round, lineJoin: .round))
                        }
                    }
                }
                .frame(width: 104, height: 46)
                .mask {
                    LinearGradient(colors: [.clear, .white, .white, .clear],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .offset(y: 22)
                .opacity(waveOn ? 1 : 0)
                .allowsHitTesting(false)

                // Pulsing sound dots at the feet of the letter.
                footPulse(CGPoint(x: 30, y: 206))
                footPulse(CGPoint(x: 170, y: 206))
            }
            .frame(width: 200, height: 220)
        }
        .frame(width: 240, height: 240)
        .scaleEffect(arrived ? 1 : 0.78)
    }

    private func footPulse(_ point: CGPoint) -> some View {
        Circle()
            .fill(tone)
            .frame(width: 6, height: 6)
            .position(point)
            .scaleEffect(waveOn ? 1.2 : 0.5)
            .opacity(waveOn ? 0.9 : 0)
            .animation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true), value: waveOn)
    }
}

// One-time cleanup of the retired service's old OAuth refresh token.
// This deliberately does not touch AMusic Cloud credentials or user media.
private enum AMRetiredIntegrationCleanup {
    private static let finishedKey = "amusic.cleanup.oldMusicService.v1692"

    static func runOnce() {
        guard !UserDefaults.standard.bool(forKey: finishedKey) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "amusic.spotify.pkce",
            kSecAttrAccount as String: "refresh-token"
        ]
        let result = SecItemDelete(query as CFDictionary)
        if result == errSecSuccess || result == errSecItemNotFound {
            UserDefaults.standard.set(true, forKey: finishedKey)
        }
    }
}

struct ContentView: View {
    @StateObject private var music = MusicStore()
    @StateObject private var cloudAuth = AMCloudAuthStore()
    @State private var showCloudAccount = false
    @State private var showCommunityCatalog = false
    @StateObject private var telegramSync = AMTelegramSyncStore()
    @State private var showTelegramSync = false
    @StateObject private var privateSpace = AMPrivateSpaceStore()
    @AppStorage("amusic.nickname") private var nickname = "Мій профіль"
    @AppStorage("amusic.theme") private var theme = "orange"
    @AppStorage("amusic.profile.frame") private var avatarFrame = "minimal"
    // AMusic 14.4 · profile presentation preferences (non-destructive AppStorage keys).
    @AppStorage("amusic.profile.status.v1") private var profileStatus = ""
    @AppStorage("amusic.profile.bio.v1") private var profileBio = ""
    @AppStorage("amusic.profile.genre.v1") private var profileGenre = "Не вказано"
    @AppStorage("amusic.profile.accent.v1") private var profileAccent = "orange"
    @AppStorage("amusic.profile.cover.v1") private var profileCover = "waves"
    @AppStorage("amusic.profile.alignment.v1") private var profileAlignment = "center"
    @AppStorage("amusic.profile.badge.v1") private var profileBadge = "none"
    @AppStorage("amusic.profile.typography.v1") private var profileTypography = "classic"
    @AppStorage("amusic.profile.showStats.v1") private var profileShowStats = true
    @AppStorage("amusic.dev.showYouTube") private var devShowYouTube = true
    @AppStorage("amusic.dev.compactRows") private var devCompactRows = false
    @AppStorage("amusic.dev.reduceMotion") private var devReduceMotion = false
    @AppStorage("amusic.dev.showBadge") private var devShowBadge = false
    @AppStorage("amusic.dev.brand") private var devBrand = "AMusic"
    // Settings use new keys; existing media, playlists, photos and notes remain untouched.
    @AppStorage("amusic.settings.showMiniPlayer") private var showMiniPlayer = true
    @AppStorage("amusic.settings.showTrackSubtitle") private var showTrackSubtitle = true
    @AppStorage("amusic.settings.confirmTrackDeletion") private var confirmTrackDeletion = true
    @AppStorage("amusic.settings.tabHaptics") private var tabHaptics = true
    @AppStorage("amusic.settings.seekStep") private var seekStep = 15
    @AppStorage("amusic.settings.startTab") private var startTab = "Музика"
    // New non-destructive preferences: no changes to audio, playlists or profile storage.
    @AppStorage("amusic.player.presentation.v1") private var playerPresentation = "focus"
    @AppStorage("amusic.player.artworkMotion.v1") private var playerArtworkMotion = true
    @AppStorage("amusic.player.artworkSwipe.v1") private var playerArtworkSwipe = true
    @AppStorage("amusic.player.ambientBackground.v1") private var playerAmbientBackground = true
    @AppStorage("amusic.player.extendedActions.v1") private var playerExtendedActions = true
    @AppStorage("amusic.player.remainingTime.v1") private var playerRemainingTime = true
    @AppStorage("amusic.player.haptics.v1") private var playerHaptics = true
    @State private var settingsPath: [AMSettingsPage] = []
    @State private var settingsSearch = ""
    @State private var didRestoreStartTab = false
    @State private var pendingDeleteTrack: MusicTrack?
    @State private var showDeleteConfirmation = false
    @State private var showAppearanceResetConfirmation = false
    @State private var showHomeQueue = false
    @State private var showClearQueueConfirmation = false
    @State private var tab: AMTab = .music
    @State private var search = ""
    @AppStorage("amusic.library.sortOrder") private var librarySortOrder = "recent"
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var selectedPlaylist: AMPlaylist?
    @State private var openPlayerAfterPlaylist = false
    @State private var showRenamePlaylist = false
    @State private var renamePlaylistName = ""
    @State private var showQueue = false
    @State private var showFavoritesOnly = false
    @State private var showImporter = false
    @State private var showPlayer = false
    @State private var playerSeekDraft: Double?
    @State private var coverDragOffset: CGFloat = 0
    @State private var coverTransitionDirection = 1
    @State private var showSettings = false
    @State private var showingLaunch = true
    @State private var showEditName = false
    @State private var nameDraft = ""
    @State private var showAvatarPicker = false
    @State private var showBannerPicker = false
    @State private var showFramePicker = false
    @State private var showProfilePreview = false
    @State private var showReplay = false
    @State private var banner: UIImage?
    @State private var editingTrack: MusicTrack?
    @State private var showPrivateSpace = false
    @State private var showPrivateSpaceGate = false
    @State private var privateSpacePasscode = ""
    @State private var privateSpaceWrongCode = false
    @State private var profileWasHeld = false
    @State private var avatar: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var tabSelectionNamespace

    private var accent: Color { AMPalette.accent(theme) }
    private var settingsSearchMatches: [AMSettingsPage] {
        let query = settingsSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return AMSettingsPage.allCases }
        return AMSettingsPage.allCases.filter {
            $0.rawValue.localizedStandardContains(query) ||
            $0.subtitle.localizedStandardContains(query)
        }
    }
    private var profileConfig: AMProfileConfig {
        AMProfileConfig(nickname: nickname, status: profileStatus, bio: profileBio,
                        genre: profileGenre, accent: profileAccent, cover: profileCover,
                        alignment: profileAlignment, badge: profileBadge,
                        typography: profileTypography, showStats: profileShowStats,
                        frameStyle: avatarFrame)
    }
    private var filteredTracks: [MusicTrack] {
        let source = showFavoritesOnly ? music.favorites : music.tracks
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? source : source.filter {
            $0.title.localizedStandardContains(query)
        }
        let originalOrder = Dictionary(uniqueKeysWithValues: music.tracks.enumerated().map { ($0.element.id, $0.offset) })
        switch librarySortOrder {
        case "title":
            return matches.sorted { lhs, rhs in
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? (originalOrder[lhs.id] ?? 0) < (originalOrder[rhs.id] ?? 0) : order == .orderedAscending
            }
        case "lastPlayed":
            return matches.sorted { lhs, rhs in
                let a = music.lastPlayedByTrack[lhs.id.uuidString] ?? 0
                let b = music.lastPlayedByTrack[rhs.id.uuidString] ?? 0
                return a == b ? (originalOrder[lhs.id] ?? 0) > (originalOrder[rhs.id] ?? 0) : a > b
            }
        case "mostPlayed":
            return matches.sorted { lhs, rhs in
                let a = music.playCountByTrack[lhs.id.uuidString] ?? 0
                let b = music.playCountByTrack[rhs.id.uuidString] ?? 0
                return a == b ? (originalOrder[lhs.id] ?? 0) > (originalOrder[rhs.id] ?? 0) : a > b
            }
        case "oldest":
            return matches
        default:
            return Array(matches.reversed())
        }
    }

    init() {
        UIScrollView.appearance().bounces = false
    }

    var body: some View {
        ZStack {
            AMProfileStyle.background(theme).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Rectangle().fill(AMPalette.elevated(theme)).frame(height: 1)

                Group {
                    switch tab {
                    case .music:
                        musicScreen
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    case .youtube:
                        YouTubeLibraryView() // unchanged, no motion added to YouTube
                    case .profile:
                        profileScreen
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Floating Liquid Glass dock: the mini player and the tab bar
                // share a quiet, fading backdrop while staying separate controls.
                VStack(spacing: 8) {
                    if showMiniPlayer && music.current != nil {
                        miniPlayer
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    tabBar
                }
                .padding(.top, 9)
                .background(alignment: .bottom) {
                    LinearGradient(
                        colors: [
                            AMPalette.background(theme).opacity(0),
                            AMPalette.background(theme).opacity(theme == "light" ? 0.90 : 0.94)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                    .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .allowsHitTesting(!showingLaunch)
        .accessibilityHidden(showingLaunch)
        .overlay {
            if showingLaunch {
                AMLaunchAnimation(theme: theme, reduceMotion: reduceMotion || devReduceMotion) {
                    withAnimation(.easeOut(duration: reduceMotion || devReduceMotion ? 0.15 : 0.3)) {
                        showingLaunch = false
                    }
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .foregroundStyle(AMPalette.primary(theme))
        .preferredColorScheme(theme == "light" ? .light : .dark)
        .tint(accent)
        .animation(reduceMotion || devReduceMotion ? nil : AMMotion.tab, value: music.current == nil)
        .onChange(of: scenePhase) { _, phase in
            music.sceneActivityChanged(isActive: phase == .active)
            if phase == .active {
                Task { await telegramSync.sync(cloud: cloudAuth, music: music) }
            }
        }
        .onChange(of: cloudAuth.userID) { _, newUserID in
            // Sign-in may happen after the initial .task; import without a restart.
            if newUserID != nil {
                Task { await telegramSync.sync(cloud: cloudAuth, music: music) }
            }
        }
        .task {
            await telegramSync.sync(cloud: cloudAuth, music: music)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): music.importFiles(urls)
            case .failure(let error): music.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showReplay) {
            replayScreen
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showTelegramSync) {
            AMTelegramSyncScreen(sync: telegramSync, cloud: cloudAuth, music: music)
        }
        .sheet(isPresented: $showCloudAccount) {
            AMCloudAccountScreen(cloud: cloudAuth)
        }
        .fullScreenCover(isPresented: $showCommunityCatalog) {
            AMCommunityScreen(cloud: cloudAuth, music: music)
        }
        .sheet(isPresented: $showPlayer) {
            playerScreen
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(25)
        }
        .fullScreenCover(isPresented: $showSettings) {
            settingsScreen
        }
        .sheet(isPresented: $showHomeQueue) {
            queueScreen.presentationDragIndicator(.visible)
        }
        .confirmationDialog("Видалити композицію?", isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible) {
            if let track = pendingDeleteTrack {
                Button("Видалити файл з iPhone", role: .destructive) {
                    music.delete(track)
                    pendingDeleteTrack = nil
                }
            }
            Button("Скасувати", role: .cancel) { pendingDeleteTrack = nil }
        } message: {
            Text("Композицію буде видалено з локальної бібліотеки AMusic. Цю дію неможливо скасувати.")
        }
        .sheet(item: $selectedPlaylist, onDismiss: {
            if openPlayerAfterPlaylist {
                openPlayerAfterPlaylist = false
                showPlayer = true
            }
        }) { playlist in
            playlistDetailScreen(playlist)
        }
        .sheet(isPresented: $showCreatePlaylist) {
            newPlaylistSheet
                .presentationDetents([.height(290)])
                .presentationDragIndicator(.visible)
        }
        .alert("Змінити нікнейм", isPresented: $showEditName) {
            TextField("Нікнейм", text: $nameDraft)
            Button("Скасувати", role: .cancel) {}
            Button("Зберегти") {
                let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { nickname = String(trimmed.prefix(32)) }
            }
        } message: {
            Text("Максимум 32 символи")
        }
        .alert("AMusic", isPresented: Binding(
            get: { music.errorMessage != nil },
            set: { if !$0 { music.errorMessage = nil } }
        )) {
            Button("OK") { music.errorMessage = nil }
        } message: {
            Text(music.errorMessage ?? "")
        }
        .task {
            AMRetiredIntegrationCleanup.runOnce()
            loadSavedAvatar()
            if !didRestoreStartTab {
                didRestoreStartTab = true
                // Previous installations might remember a now-removed start tab.
                // Fall back to Music instead of leaving the user on an invalid screen.
                if let preferred = AMTab(rawValue: startTab),
                   (preferred != .youtube || devShowYouTube) {
                    tab = preferred
                } else {
                    tab = .music
                }
            }
        }
        .sheet(isPresented: $showAvatarPicker) {
            AMAvatarPhotoPicker { image in
                saveSelectedPhoto(image)
            }
        }
        .sheet(isPresented: $showBannerPicker) {
            AMAvatarPhotoPicker { image in
                saveSelectedBanner(image)
            }
        }
        .sheet(isPresented: $showFramePicker) {
            AMAvatarFramePicker(theme: theme, image: avatar, selection: $avatarFrame, accentStyle: profileAccent)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showProfilePreview) {
            AMProfilePreviewSheet(config: profileConfig, theme: theme,
                                  avatar: avatar, banner: banner,
                                  trackCount: music.tracks.count,
                                  favoritesCount: music.favorites.count,
                                  playlistsCount: music.playlists.count)
        }
        .onChange(of: devShowYouTube) { _, visible in
            if !visible && tab == .youtube { tab = .music }
        }
        .sheet(item: $editingTrack) { track in
            AMTrackEditorSheet(track: track, store: music, theme: theme)
        }
        .alert("Доступ до Мого простору", isPresented: $showPrivateSpaceGate) {
            SecureField("Введіть код", text: $privateSpacePasscode)
                .keyboardType(.numberPad)
            Button("Скасувати", role: .cancel) {
                privateSpacePasscode = ""
                privateSpaceWrongCode = false
                profileWasHeld = false
            }
            Button("Увійти") {
                let accepted = privateSpacePasscode == "123123"
                privateSpacePasscode = ""
                profileWasHeld = false
                if accepted {
                    privateSpaceWrongCode = false
                    showPrivateSpace = true
                } else {
                    privateSpaceWrongCode = true
                }
            }
        } message: {
            Text("Введіть шестизначний код доступу.")
        }
        .alert("Неправильний код", isPresented: $privateSpaceWrongCode) {
            Button("Спробувати ще") {
                privateSpacePasscode = ""
                showPrivateSpaceGate = true
            }
            Button("Закрити", role: .cancel) { profileWasHeld = false }
        } message: {
            Text("Мій простір не відкрито. Спробуйте ще раз.")
        }
        .sheet(isPresented: $showPrivateSpace, onDismiss: {
            profileWasHeld = false
        }) {
            AMPrivateSpaceHome(store: privateSpace, music: music, cloud: cloudAuth, theme: theme)
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(26)
        }
    }

    // MARK: - Home / navigation (14.1)

    private var header: some View {
        HStack(spacing: 12) {
            Button { changeTab(.profile) } label: {
                AMFramedAvatar(image: avatar, theme: profileAccent,
                               frameStyle: "none", size: 34)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Мій профіль")
            VStack(alignment: .leading, spacing: 2) {
                Text(devBrand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "AMusic" : String(devBrand.prefix(18)))
                    .font(.headline)
                Text(tab == .music ? "Твоя музика" : tab.rawValue)
                    .font(.caption)
                    .foregroundStyle(AMPalette.secondary(theme))
            }
            Spacer()
            if tab == .music {
                Menu {
                    Button { showImporter = true } label: {
                        Label("Додати аудіофайли", systemImage: "square.and.arrow.down")
                    }
                    Button { newPlaylistName = ""; showCreatePlaylist = true } label: {
                        Label("Створити плейлист", systemImage: "text.badge.plus")
                    }
                    Button { showHomeQueue = true } label: {
                        Label("Черга відтворення", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Додати музику або плейлист")
            }
            Button { settingsPath = []; showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Налаштування")
        }
        .foregroundStyle(AMProfileStyle.blue)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(AMPalette.card(theme))
        .overlay(alignment: .bottom) { AMProfileStyle.blue.opacity(0.12).frame(height: 1) }
    }
    // MARK: - AMusic · Minimal Music Library
    // The quick links keep Cloud features accessible without dominating the music list.
    private var musicScreen: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                homeIntroduction
                musicSearchField
                homePlaybackActions
                musicQuickLinks
                if !music.playlists.isEmpty {
                    homeCollections
                }
                homeTracks
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .background(AMProfileStyle.background(theme))
        .tint(AMProfileStyle.blue)
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var musicQuickLinks: some View {
        HStack(spacing: 10) {
            Button { showCommunityCatalog = true } label: {
                Label("Спільнота", systemImage: "person.2")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("Відкрити музику для всіх")

            Button { showTelegramSync = true } label: {
                HStack(spacing: 7) {
                    if telegramSync.isSyncing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text("Telegram Sync")
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                }
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("Синхронізація приватної музики")
        }
        .foregroundStyle(AMPalette.primary(theme))
        .buttonStyle(AMPressStyle())
        .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(AMPalette.elevated(theme).opacity(0.6), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .center) {
            Rectangle()
                .fill(AMPalette.elevated(theme))
                .frame(width: 1, height: 21)
                .allowsHitTesting(false)
        }
    }

    private var homeIntroduction: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Моя музика")
                .font(.system(size: 29, weight: .bold))
                .tracking(-0.7)
                .foregroundStyle(AMPalette.primary(theme))
            Spacer(minLength: 8)
            Text("\(music.tracks.count) треків")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AMPalette.secondary(theme))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var musicSearchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AMPalette.secondary(theme))
            TextField("Пошук треків", text: $search)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AMPalette.secondary(theme))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Очистити пошук")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, search.isEmpty ? 12 : 0)
        .frame(minHeight: 44)
        .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(AMProfileStyle.blue.opacity(0.10), lineWidth: 1) }
    }

    private var homePlaybackActions: some View {
        HStack(spacing: 10) {
            Button {
                if let current = music.current,
                   filteredTracks.contains(where: { $0.id == current.id }) {
                    if music.isPlaying { showPlayer = true } else { music.resume() }
                } else if let first = filteredTracks.first {
                    music.play(first, from: filteredTracks)
                }
            } label: {
                Label(music.isPlaying ? "Плеєр" : "Слухати", systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(.white)
                    .background(AMProfileStyle.blue, in: RoundedRectangle(cornerRadius: 12))
            }
            Button {
                guard let first = filteredTracks.randomElement() else { return }
                music.updateShuffle(true)
                music.play(first, from: filteredTracks)
            } label: {
                Label("Перемішати", systemImage: "shuffle")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(AMPalette.primary(theme))
                    .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .buttonStyle(AMPressStyle())
        .disabled(filteredTracks.isEmpty)
        .opacity(filteredTracks.isEmpty ? 0.48 : 1)
    }

    private var homeCollections: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionCaption("Плейлисти")
                Spacer()
                Button {
                    newPlaylistName = ""
                    showCreatePlaylist = true
                } label: {
                    Label("Створити", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AMProfileStyle.blue)
                }
                .buttonStyle(AMPressStyle())
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    if music.playlists.isEmpty {
                        Button {
                            newPlaylistName = ""
                            showCreatePlaylist = true
                        } label: {
                            collectionCard(title: "Перший плейлист", count: 0,
                                           icon: "plus", highlighted: true)
                        }
                        .buttonStyle(AMPressStyle())
                    }
                    ForEach(music.playlists) { playlist in
                        Button { selectedPlaylist = playlist } label: {
                            collectionCard(title: playlist.name,
                                           count: music.playlistTracks(playlist.id).count,
                                           icon: "music.note.list", highlighted: false)
                        }
                        .buttonStyle(AMPressStyle())
                    }
                }
                .padding(.vertical, 1)
            }
            .contentMargins(.trailing, 2)
        }
    }

    private var homeTracks: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                sectionCaption("Композиції")
                Spacer()
                Menu {
                    Button {
                        librarySortOrder = "recent"
                    } label: {
                        Label("Спочатку нові", systemImage: librarySortOrder == "recent" ? "checkmark" : "clock")
                    }
                    Button {
                        librarySortOrder = "oldest"
                    } label: {
                        Label("Спочатку старі", systemImage: librarySortOrder == "oldest" ? "checkmark" : "calendar")
                    }
                    Button {
                        librarySortOrder = "title"
                    } label: {
                        Label("За назвою", systemImage: librarySortOrder == "title" ? "checkmark" : "textformat.abc")
                    }
                    Divider()
                    Button {
                        librarySortOrder = "lastPlayed"
                    } label: {
                        Label("Нещодавно слухав", systemImage: librarySortOrder == "lastPlayed" ? "checkmark" : "clock.arrow.circlepath")
                    }
                    Button {
                        librarySortOrder = "mostPlayed"
                    } label: {
                        Label("Найчастіше слухаю", systemImage: librarySortOrder == "mostPlayed" ? "checkmark" : "chart.bar.fill")
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text("Сортування")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AMPalette.secondary(theme))
                    .frame(minHeight: 34)
                }
                .accessibilityLabel("Сортування композицій")
            }

            HStack(spacing: 8) {
                libraryScopeButton("Усі", selected: !showFavoritesOnly) {
                    showFavoritesOnly = false
                }
                libraryScopeButton("Улюблені", selected: showFavoritesOnly) {
                    showFavoritesOnly = true
                }
                Spacer()
                Text("\(filteredTracks.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AMPalette.secondary(theme))
                    .accessibilityLabel("Знайдено \(filteredTracks.count) композицій")
            }

            if music.tracks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(AMProfileStyle.blue)
                        .frame(height: 36)
                    Text("Тут буде твоя музика")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Додай аудіофайли зі свого iPhone")
                        .font(.system(size: 12))
                        .foregroundStyle(AMPalette.secondary(theme))
                    Button { showImporter = true } label: {
                        Label("Додати музику", systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AMProfileStyle.blue)
                            .padding(.top, 5)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if filteredTracks.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: showFavoritesOnly ? "heart" : "magnifyingglass")
                        .font(.system(size: 23, weight: .light))
                    Text(showFavoritesOnly && search.isEmpty
                         ? "В улюблених поки порожньо" : "Нічого не знайдено")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(AMPalette.secondary(theme))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filteredTracks) { track in
                        trackRow(track, from: filteredTracks)
                        if track.id != filteredTracks.last?.id {
                            Divider().opacity(0.38).padding(.leading, devCompactRows ? 63 : 73)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var musicFraction: CGFloat {
        CGFloat(min(1, max(0, music.progress / max(1, music.duration))))
    }

    private func sectionCaption(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AMPalette.primary(theme))
    }
    private func collectionCard(title: String, count: Int, icon: String, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AMProfileStyle.blue)
                .frame(width: 34, height: 34)
                .background(AMPalette.elevated(theme), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AMPalette.primary(theme))
                    .lineLimit(1)
                Text(highlighted ? "Нова добірка" : "\(count) пісень")
                    .font(.system(size: 11))
                    .foregroundStyle(AMPalette.secondary(theme))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 178)
        .frame(minHeight: 58, alignment: .leading)
        .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 11))
    }

    private func libraryScopeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AMProfileStyle.blue : AMPalette.secondary(theme))
                Capsule()
                    .fill(selected ? AMProfileStyle.blue : .clear)
                    .frame(height: 3)
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 70, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func albumArtwork(_ track: MusicTrack?, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size > 100 ? 23 : 12)
                .fill(LinearGradient(
                    colors: [accent.opacity(0.25), AMPalette.elevated(theme)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            if let track, let image = music.artwork[track.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else if size > 100 {
                AMEqualizer(isPlaying: music.isPlaying, color: AMProfileStyle.blue,
                            count: 11, maxHeight: size * 0.31, barWidth: max(3, size * 0.014))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.32, weight: .light))
                    .foregroundStyle(AMProfileStyle.blue)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 100 ? 23 : 12))
        .task(id: track?.id) {
            if let track { music.requestArtwork(for: track) }
        }
    }

    private func trackRow(_ track: MusicTrack, from collection: [MusicTrack]? = nil) -> some View {
        let active = music.current?.id == track.id
        return HStack(spacing: 3) {
            Button {
                if active { music.toggle() }
                else { music.play(track, from: collection) }
            } label: {
                HStack(spacing: 11) {
                    albumArtwork(track, size: devCompactRows ? 42 : 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(active ? AMProfileStyle.blue : AMPalette.primary(theme))
                        if showTrackSubtitle && active {
                            Text(music.isPlaying ? "Зараз грає" : "На паузі")
                                .font(.caption)
                                .foregroundStyle(AMPalette.secondary(theme))
                        }
                    }
                    Spacer(minLength: 3)
                    if active {
                        AMEqualizer(isPlaying: music.isPlaying, color: AMProfileStyle.blue,
                                    count: 3, maxHeight: 14, barWidth: 2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: devCompactRows ? 45 : 51)
                .contentShape(Rectangle())
            }
            .buttonStyle(AMPressStyle())
            .accessibilityLabel("\(track.title), \(active ? (music.isPlaying ? "пауза" : "продовжити") : "відтворити")")

            Menu {
                Button { editingTrack = track } label: {
                    Label("Редагувати", systemImage: "square.and.pencil")
                }
                Button { music.play(track, from: collection); showPlayer = true } label: {
                    Label("Відкрити плеєр", systemImage: "play.fill")
                }
                Button { music.playNext(track) } label: {
                    Label("Відтворити наступною", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button { music.addToQueue(track) } label: {
                    Label("Додати в кінець черги", systemImage: "text.append")
                }
                Button { music.toggleFavorite(track) } label: {
                    Label(music.isFavorite(track) ? "Прибрати з улюблених" : "До улюблених",
                          systemImage: music.isFavorite(track) ? "heart.slash" : "heart")
                }
                if !music.playlists.isEmpty {
                    Menu("Додати в плейлист") {
                        ForEach(music.playlists) { playlist in
                            Button(playlist.name) { music.add(track, to: playlist.id) }
                        }
                    }
                }
                Button(role: .destructive) {
                    if confirmTrackDeletion {
                        pendingDeleteTrack = track
                        showDeleteConfirmation = true
                    } else {
                        music.delete(track)
                    }
                } label: {
                    Label("Видалити файл", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AMPalette.secondary(theme))
                    .frame(width: 44, height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Дії з композицією \(track.title)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, devCompactRows ? 4 : 8)
        .background(active ? AMProfileStyle.blue.opacity(0.08) : Color.clear)
        .animation(reduceMotion || devReduceMotion ? nil : AMMotion.selection, value: active)
    }

    private var newPlaylistSheet: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("Новий плейлист")
                    .font(.system(size: 24, weight: .bold, design: .default))
                Spacer()
                Button { showCreatePlaylist = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AMPalette.secondary(theme))
                        .font(.system(size: 22))
                }
            }
            Text("Створи добірку й додавай у неї треки через меню •••")
                .font(.system(size: 12))
                .foregroundStyle(AMPalette.secondary(theme))
            TextField("Назва плейлиста", text: $newPlaylistName)
                .padding(14)
                .background(AMPalette.card(theme))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Button {
                if music.createPlaylist(newPlaylistName) {
                    newPlaylistName = ""
                    showCreatePlaylist = false
                }
            } label: {
                Text("Створити")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(AMProfileStyle.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer(minLength: 0)
        }
        .padding(20)
        .padding(.top, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AMProfileStyle.background(theme))
        .foregroundStyle(AMPalette.primary(theme))
        .preferredColorScheme(theme == "light" ? .light : .dark)
    }

    // MARK: - Playlist detail sheet

    private func playlistDetailScreen(_ playlist: AMPlaylist) -> some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                let entries = music.playlistTracks(playlist.id)
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 15) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 29))
                            .foregroundStyle(AMProfileStyle.blue)
                            .frame(width: 75, height: 75)
                            .background(AMPalette.card(theme))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(music.playlists.first(where: { $0.id == playlist.id })?.name ?? playlist.name)
                                .font(.system(size: 22, weight: .bold, design: .default))
                            Text("\(entries.count) композицій")
                                .font(.system(size: 12))
                                .foregroundStyle(AMPalette.secondary(theme))
                        }
                    }
                    Button {
                        if let first = entries.first {
                            music.play(first, from: entries)
                            openPlayerAfterPlaylist = true
                            selectedPlaylist = nil
                        }
                    } label: {
                        Label("Слухати плейлист", systemImage: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 47)
                            .background(AMProfileStyle.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(entries.isEmpty)
                    if entries.isEmpty {
                        Text("Додай пісні через меню ••• поруч із треком у бібліотеці.")
                            .font(.system(size: 13))
                            .foregroundStyle(AMPalette.secondary(theme))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(entries) { track in
                                HStack(spacing: 8) {
                                    Button {
                                        music.play(track, from: entries)
                                        openPlayerAfterPlaylist = true
                                        selectedPlaylist = nil
                                    } label: {
                                        HStack(spacing: 10) {
                                            albumArtwork(track, size: 45)
                                            Text(track.title)
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(AMPalette.primary(theme))
                                                .lineLimit(1)
                                            Spacer()
                                            Image(systemName: "play.fill")
                                                .foregroundStyle(AMProfileStyle.blue)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    Menu {
                                        Button { music.playNext(track) } label: {
                                            Label("Відтворити наступною", systemImage: "text.line.first.and.arrowtriangle.forward")
                                        }
                                        Button { music.addToQueue(track) } label: {
                                            Label("У кінець черги", systemImage: "text.append")
                                        }
                                        Button(role: .destructive) {
                                            music.remove(track, from: playlist.id)
                                        } label: {
                                            Label("Прибрати з плейлиста", systemImage: "minus.circle")
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .foregroundStyle(AMPalette.secondary(theme))
                                            .frame(width: 32, height: 44)
                                    }
                                }
                                .padding(9)
                                .background(AMPalette.card(theme))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(AMProfileStyle.background(theme))
            .navigationTitle("Плейлист")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Перейменувати", systemImage: "pencil") {
                            renamePlaylistName = music.playlists.first(where: { $0.id == playlist.id })?.name ?? playlist.name
                            showRenamePlaylist = true
                        }
                        Button(role: .destructive) {
                            music.deletePlaylist(playlist.id)
                            selectedPlaylist = nil
                        } label: {
                            Label("Видалити плейлист", systemImage: "trash")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { selectedPlaylist = nil }
                }
            }
        }
        .foregroundStyle(AMPalette.primary(theme))
        .preferredColorScheme(theme == "light" ? .light : .dark)
        .alert("Перейменувати плейлист", isPresented: $showRenamePlaylist) {
            TextField("Назва", text: $renamePlaylistName)
            Button("Скасувати", role: .cancel) {}
            Button("Зберегти") {
                music.renamePlaylist(playlist.id, to: renamePlaylistName)
            }
        }
    }

    // MARK: - Playback queue (only local audio; YouTube unchanged)

    // Native drag handles are always visible: no long-press or hidden edit mode.
    private var queueScreen: some View {
        NavigationStack {
            List {
                Section {
                    if let track = music.current {
                        HStack(spacing: 12) {
                            albumArtwork(track, size: 50)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                                Text(music.isPlaying ? "Зараз грає" : "На паузі")
                                    .font(.system(size: 11)).foregroundStyle(AMPalette.secondary(theme))
                            }
                            Spacer(minLength: 4)
                            Button { music.toggle() } label: {
                                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(AMProfileStyle.blue)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(music.isPlaying ? "Пауза" : "Відтворити")
                        }
                        .padding(.vertical, 7)
                    } else {
                        Label("Музика ще не запущена", systemImage: "music.note")
                            .font(.subheadline)
                            .foregroundStyle(AMPalette.secondary(theme))
                    }
                } header: {
                    Text("Зараз")
                }

                Section {
                    if music.upcomingIDs.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                .font(.system(size: 26))
                                .foregroundStyle(AMProfileStyle.blue)
                            Text("Черга порожня").font(.headline)
                            Text("Додай пісню через меню ••• у бібліотеці")
                                .font(.footnote)
                                .foregroundStyle(AMPalette.secondary(theme))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    } else {
                        ForEach(Array(music.queueTracks.enumerated()), id: \.offset) { row in
                            let index = row.offset
                            let track = row.element
                            HStack(spacing: 11) {
                                albumArtwork(track, size: 42)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(track.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(index == 0 ? "Наступна" : "№ \(index + 1) у черзі")
                                        .font(.system(size: 11))
                                        .foregroundStyle(index == 0 ? AMProfileStyle.blue : AMPalette.secondary(theme))
                                }
                                Spacer(minLength: 4)
                                Menu {
                                    Button { music.moveQueueItemToFront(at: index) } label: {
                                        Label("Відтворити наступною", systemImage: "text.line.first.and.arrowtriangle.forward")
                                    }
                                    .disabled(index == 0)
                                    Button(role: .destructive) { music.removeQueueItem(at: index) } label: {
                                        Label("Прибрати з черги", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .foregroundStyle(AMPalette.secondary(theme))
                                        .frame(width: 36, height: 44)
                                }
                            }
                            .padding(.vertical, 3)
                            .listRowBackground(AMPalette.card(theme))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { music.removeQueueItem(at: index) } label: {
                                    Label("Прибрати", systemImage: "trash")
                                }
                            }
                        }
                        .onMove(perform: music.reorderQueue(from:to:))
                    }
                } header: {
                    Text("Далі · \(music.upcomingIDs.count)")
                } footer: {
                    if !music.upcomingIDs.isEmpty {
                        Text("Потягни за значок праворуч, щоб змінити порядок. Черга зберігається автоматично.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(AMPalette.background(theme))
            .navigationTitle("Черга відтворення")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !music.upcomingIDs.isEmpty {
                        Button("Очистити", role: .destructive) { showClearQueueConfirmation = true }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { showQueue = false; showHomeQueue = false }
                }
            }
            .confirmationDialog("Очистити чергу?", isPresented: $showClearQueueConfirmation,
                                titleVisibility: .visible) {
                Button("Очистити чергу", role: .destructive) { music.clearQueue() }
                Button("Скасувати", role: .cancel) {}
            } message: {
                Text("Композиції залишаться у бібліотеці та плейлистах.")
            }
        }
        .foregroundStyle(AMPalette.primary(theme))
        .preferredColorScheme(theme == "light" ? .light : .dark)
    }

    // MARK: - AMusic 16.9.4 · Minimal profile
    // Personal details stay in the existing AppStorage keys; no migration needed.
    private var profileScreen: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Профіль")
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .tracking(-0.7)
                    .padding(.horizontal, 2)

                profileHero

                // 16.9.4.3: Real iOS NavigationLink, not a button setting presentation state.
                // Keeps navigation independent from the app's many sheet presenters.
                NavigationLink {
                    AMProfileEditorView(
                        theme: theme,
                        avatar: avatar,
                        banner: banner,
                        trackCount: music.tracks.count,
                        favoritesCount: music.favorites.count,
                        playlistsCount: music.playlists.count,
                        onAvatarSelected: saveSelectedPhoto,
                        onBannerSelected: saveSelectedBanner,
                        onRemoveAvatar: removeAvatar,
                        onRemoveBanner: removeBanner
                    )
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "pencil.line")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 43, height: 43)
                            .background(AMProfileStyle.blue, in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Редагувати профіль")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AMPalette.primary(theme))
                            Text("Змінити фото, опис і стиль")
                                .font(.system(size: 12))
                                .foregroundStyle(AMPalette.secondary(theme))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AMPalette.secondary(theme))
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 72)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 17))
                    .contentShape(RoundedRectangle(cornerRadius: 17))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("amusic.profile.edit.native")
                .accessibilityHint("Відкрити екран редагування профілю")

                VStack(spacing: 0) {
                    minimalProfileRow("AMusic Cloud", subtitle: cloudAuth.isSignedIn ? "Підключено" : "Увійти", symbol: "icloud") {
                        showCloudAccount = true
                    }
                    Divider().padding(.leading, 54)
                    minimalProfileRow("AMusic Replay", subtitle: "Статистика музики", symbol: "chart.bar.xaxis") {
                        showReplay = true
                    }
                    Divider().padding(.leading, 54)
                    minimalProfileRow("Налаштування", subtitle: "Звук, інтерфейс, синхронізація", symbol: "gearshape") {
                        settingsPath = []
                        showSettings = true
                    }
                }
                .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text("AMusic " + AMRelease.version)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AMPalette.secondary(theme))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity)
        }
            .background(AMProfileStyle.background(theme))
            .scrollBounceBehavior(.basedOnSize)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func minimalProfileRow(_ title: String, subtitle: String, symbol: String,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(AMPalette.secondary(theme))
                    .frame(width: 30, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AMPalette.primary(theme))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AMPalette.secondary(theme))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AMPalette.secondary(theme).opacity(0.6))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 15)
            .frame(minHeight: 61)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Replay reads counters already stored by MusicStore. It never changes the audio library.
    private var replayScreen: some View {
        let ranks = music.tracks
            .map { (track: $0, seconds: music.replaySecondsByTrack[$0.id.uuidString, default: 0]) }
            .filter { $0.seconds > 0 }
            .sorted { $0.seconds > $1.seconds }
        let total = music.replaySecondsByDay.values.reduce(0, +)
        let recentDays: [(String, Double)] = (0..<7).reversed().compactMap { offset in
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            let key = String(format: "%04d-%02d-%02d", Calendar.current.component(.year, from: date), Calendar.current.component(.month, from: date), Calendar.current.component(.day, from: date))
            return (key, music.replaySecondsByDay[key, default: 0])
        }
        let peak = max(recentDays.map { $0.1 }.max() ?? 0, 1)
        return NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ТВОЯ МУЗИКА В ЦИФРАХ")
                            .font(.system(size: 10, weight: .bold)).tracking(1.6)
                            .foregroundStyle(AMProfileStyle.blue)
                        Text("AMusic Replay")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                    }
                    HStack(spacing: 12) {
                        replayMetric("Хвилини", value: "\(Int(total / 60))", symbol: "clock")
                        replayMetric("Прослухані", value: "\(ranks.count)", symbol: "music.note")
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Останні 7 днів").font(.headline)
                        HStack(alignment: .bottom, spacing: 9) {
                            ForEach(0..<recentDays.count, id: \.self) { dayIndex in
                                let item = recentDays[dayIndex]
                                VStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(AMProfileStyle.blue)
                                        .frame(height: max(5, CGFloat(item.1 / peak) * 104))
                                        .frame(maxHeight: 108, alignment: .bottom)
                                    Text(String(item.0.suffix(2)))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(AMPalette.secondary(theme))
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(height: 135, alignment: .bottom)
                    }
                    .padding(16)
                    .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Топ композицій").font(.headline)
                        if ranks.isEmpty {
                            Text("Поки немає статистики. Послухай музику — і Replay почне заповнюватися.")
                                .font(.subheadline)
                                .foregroundStyle(AMPalette.secondary(theme))
                        }
                        ForEach(Array(ranks.prefix(10).enumerated()), id: \.element.track.id) { index, item in
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .foregroundStyle(AMProfileStyle.blue)
                                    .frame(width: 25)
                                Text(item.track.title)
                                    .font(.subheadline).lineLimit(1)
                                Spacer(minLength: 5)
                                Text("\(Int(item.seconds / 60)) хв")
                                    .font(.caption).monospacedDigit()
                                    .foregroundStyle(AMPalette.secondary(theme))
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(16)
                    .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 16))
                    Text("Статистика зберігається тільки на цьому iPhone та накопичується від версії 16.3. Час враховується під час активного відтворення з локальної бібліотеки.")
                        .font(.caption)
                        .foregroundStyle(AMPalette.secondary(theme))
                }
                .padding(18)
            }
            .background(AMProfileStyle.background(theme))
            .navigationTitle("Replay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { showReplay = false } } }
        }
        .preferredColorScheme(theme == "light" ? .light : .dark)
    }

    private func replayMetric(_ name: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(AMProfileStyle.blue)
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded))
            Text(name).font(.caption).foregroundStyle(AMPalette.secondary(theme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 16))
    }

    private var profileHero: some View {
        AMProfileCard(config: profileConfig, theme: theme,
                      avatar: avatar, banner: banner,
                      trackCount: music.tracks.count,
                      favoritesCount: music.favorites.count,
                      playlistsCount: music.playlists.count)
    }

    // MARK: - AMusic 16.9.4 · Settings Hub

    private var settingsScreen: some View {
        NavigationStack(path: $settingsPath) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            AMFramedAvatar(image: avatar, theme: profileAccent,
                                           frameStyle: avatarFrame, size: 56)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(nickname.isEmpty ? "Мій профіль" : nickname)
                                    .font(.system(size: 19, weight: .semibold))
                                    .lineLimit(1)
                                Text("AMusic · Налаштуй під себе")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AMPalette.secondary(theme))
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(AMProfileStyle.blue)
                        }
                        HStack(spacing: 8) {
                            settingsStatusChip(icon: "music.note", text: "\(music.tracks.count) треків")
                            settingsStatusChip(icon: "icloud", text: cloudAuth.isSignedIn ? "Cloud активний" : "Cloud не підключено")
                        }
                    }
                    .padding(18)
                    .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    if settingsSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        settingsGroup("Звук і плеєр", pages: [.player, .playerUI])
                        settingsGroup("Моя музика", pages: [.library, .sync])
                        settingsGroup("Застосунок", pages: [.appearance, .navigation, .interaction])
                        settingsGroup("Інформація", pages: [.about])
                    } else if settingsSearchMatches.isEmpty {
                        ContentUnavailableView.search(text: settingsSearch)
                    } else {
                        settingsGroup("Знайдені налаштування", pages: settingsSearchMatches)
                    }

                    Text("Параметри застосовуються одразу і зберігаються локально.")
                        .font(.system(size: 11))
                        .foregroundStyle(AMPalette.secondary(theme))
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 8)
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity)
            }
            .background(AMProfileStyle.background(theme))
            .searchable(text: $settingsSearch,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Знайти параметр")
            .navigationTitle("Налаштування")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = false } label: {
                        Label("Готово", systemImage: "xmark")
                    }
                }
            }
            .navigationDestination(for: AMSettingsPage.self) { page in
                settingsDetail(page)
            }
        }
        .foregroundStyle(AMPalette.primary(theme))
        .preferredColorScheme(theme == "light" ? .light : .dark)
        .tint(AMProfileStyle.blue)
        .confirmationDialog("Скинути оформлення AMusic?", isPresented: $showAppearanceResetConfirmation,
                            titleVisibility: .visible) {
            Button("Скинути оформлення", role: .destructive) {
                theme = "orange"
                avatarFrame = "minimal"
                devCompactRows = false
                devReduceMotion = false
                showMiniPlayer = true
                showTrackSubtitle = true
                playerPresentation = "focus"
                playerArtworkMotion = true
                playerAmbientBackground = true
                playerExtendedActions = true
                playerRemainingTime = true
            }
            Button("Скасувати", role: .cancel) {}
        } message: {
            Text("Скинуться лише налаштування зовнішнього вигляду. Музика, плейлисти, фото та нотатки залишаться.")
        }
    }

    private func settingsStatusChip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AMPalette.secondary(theme))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(AMPalette.elevated(theme).opacity(0.66), in: Capsule())
    }

    private func settingsGroup(_ title: String, pages: [AMSettingsPage]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            settingsSectionHeading(title)
            VStack(spacing: 0) {
                ForEach(pages, id: \.self) { page in
                    settingsNavigationRow(page, title: page.rawValue, color: AMProfileStyle.blue)
                    if page != pages.last { settingsRowDivider }
                }
            }
            .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func settingsDetail(_ page: AMSettingsPage) -> some View {
        ScrollView(showsIndicators: false) {
            Group {
                switch page {
                case .player: settingsPlayerPage
                case .playerUI: settingsPlayerAppearancePage
                case .library: settingsLibraryPage
                case .sync: settingsSyncPage
                case .appearance: settingsAppearancePage
                case .navigation: settingsNavigationPage
                case .interaction: settingsInteractionPage
                case .about: settingsAboutPage
                }
            }
            .frame(maxWidth: 620)
            .padding(16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .background(AMProfileStyle.background(theme))
        .navigationTitle(page.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var settingsRowDivider: some View {
        Divider().padding(.leading, 60)
    }

    private func settingsSectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.footnote)
            .foregroundStyle(AMPalette.secondary(theme))
            .padding(.leading, 16)
    }

    private func settingsNavigationRow(_ page: AMSettingsPage, title: String, color: Color) -> some View {
        NavigationLink(value: page) {
            HStack(spacing: 14) {
                Image(systemName: page.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 42, height: 42)
                    .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AMPalette.primary(theme))
                    Text(page.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(AMPalette.secondary(theme))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AMPalette.secondary(theme).opacity(0.65))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .frame(minHeight: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingsCard<Content: View>(_ title: String, symbol: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsSectionHeading(title)
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .font(.body)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
    }
    private func settingsNote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(AMPalette.secondary(theme))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var settingsPlayerPage: some View {
        VStack(spacing: 24) {
            settingsCard("Гучність", symbol: "speaker.wave.2") {
                HStack {
                    Text("Гучність AMusic")
                    Spacer()
                    Text("\(Int(music.volume * 100))%")
                        .foregroundStyle(AMPalette.secondary(theme))
                }
                .font(.body)
                Slider(value: Binding(get: { Double(music.volume) },
                                      set: { music.updateVolume($0) }), in: 0...1)
                settingsNote("Керує тільки локальним плеєром. Гучність iPhone змінюється кнопками телефону.")
            }
            settingsCard("Еквалайзер", symbol: "slider.horizontal.3") {
                Toggle("Увімкнути еквалайзер", isOn: Binding(
                    get: { music.equalizerEnabled },
                    set: { music.changeEqualizerEnabled($0) }
                ))
                Picker("Звучання", selection: Binding(
                    get: { music.equalizerPreset },
                    set: { music.changeEqualizerPreset($0) }
                )) {
                    Text("Рівний").tag("flat")
                    Text("Баси").tag("bass")
                    Text("Вокал").tag("vocal")
                    Text("Класика").tag("classic")
                    Text("Яскравий").tag("bright")
                }
                .pickerStyle(.menu)
                .disabled(!music.equalizerEnabled)
                settingsNote("П’ять смуг частот для музики, збереженої на iPhone. YouTube працює окремо.")
            }
            settingsCard("Відтворення", symbol: "play.circle") {
                HStack {
                    Label("Швидкість", systemImage: "speedometer")
                    Spacer()
                    Picker("Швидкість", selection: Binding(
                        get: { music.rate }, set: { music.updateRate($0) }
                    )) {
                        Text("0.5×").tag(Float(0.5))
                        Text("0.75×").tag(Float(0.75))
                        Text("1×").tag(Float(1.0))
                        Text("1.25×").tag(Float(1.25))
                        Text("1.5×").tag(Float(1.5))
                        Text("1.75×").tag(Float(1.75))
                        Text("2×").tag(Float(2.0))
                    }
                    .pickerStyle(.menu)
                }
                Toggle(isOn: Binding(get: { music.shuffleEnabled },
                                     set: { music.updateShuffle($0) })) {
                    Label("Перемішування без повторів", systemImage: "shuffle")
                }
                settingsNote("Розумний мікс програє кожну композицію один раз, перш ніж знову перемішати список.")
                Toggle(isOn: Binding(get: { music.smoothTransitionsEnabled },
                                     set: { music.changeSmoothTransitions($0) })) {
                    Label("Плавні переходи", systemImage: "waveform")
                }
                settingsNote("М'яке приглушення при перемиканні та плавний початок наступної композиції. Працює у звичайному плеєрі й з еквалайзером. Під час блокування iPhone відтворення залишається без затримок.")
                Toggle(isOn: Binding(get: { music.repeatTrack },
                                     set: { music.updateRepeat($0) })) {
                    Label("Повтор одного треку", systemImage: "repeat.1")
                }
                settingsNote("Ці параметри стосуються локальної бібліотеки AMusic.")
            }
            settingsCard("Перемотування", symbol: "gobackward.15") {
                HStack {
                    Text("Крок перемотування")
                    Spacer()
                    Picker("Крок перемотування", selection: $seekStep) {
                        Text("10 секунд").tag(10)
                        Text("15 секунд").tag(15)
                        Text("30 секунд").tag(30)
                    }
                    .pickerStyle(.menu)
                }
                settingsNote("У повноекранному плеєрі з'являться кнопки перемотування назад і вперед.")
            }
            settingsCard("Таймер сну", symbol: "moon.zzz") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(music.sleepTimerEnd != nil || music.sleepAfterCurrentTrack ? "Таймер увімкнено" : "Таймер вимкнено")
                            .font(.system(size: 13, weight: .semibold))
                        if let end = music.sleepTimerEnd {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let remaining = max(0, Int(end.timeIntervalSince(context.date)))
                                Text(String(format: "Залишилось %02d:%02d:%02d", remaining / 3600,
                                            (remaining / 60) % 60, remaining % 60))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(AMPalette.secondary(theme))
                            }
                        } else if music.sleepAfterCurrentTrack {
                            settingsNote("Зупиниться після поточної композиції")
                        } else {
                            settingsNote("AMusic призупинить локальну музику після таймера")
                        }
                    }
                    Spacer(minLength: 4)
                    Menu {
                        Button("Після поточної композиції") { music.scheduleSleepAfterCurrentTrack() }
                        Divider()
                        ForEach([5, 10, 15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                            Button("\(minutes) хв") { music.scheduleSleepTimer(minutes: minutes) }
                        }
                        if music.sleepTimerEnd != nil || music.sleepAfterCurrentTrack {
                            Button("Вимкнути таймер", role: .destructive) {
                                music.cancelSleepTimer()
                            }
                        }
                    } label: {
                        Label("Обрати", systemImage: "timer")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(AMPalette.elevated(theme),
                                        in: RoundedRectangle(cornerRadius: 11))
                    }
                }
                settingsNote("Час завершення зберігається навіть після повторного відкриття AMusic. У фоні iOS може затримати таймер, але застосунок перевірить час перед наступною композицією.")
            }
        }
        .font(.body)
    }

    // Practical player controls, not a skin-only screen.
    private var settingsPlayerAppearancePage: some View {
        VStack(spacing: 20) {
            settingsCard("Інтерфейс плеєра", symbol: "play.rectangle") {
                Picker("Стиль заголовка", selection: $playerPresentation) {
                    Text("Focus · Велика назва").tag("focus")
                    Text("Studio · Компактна назва").tag("studio")
                }
                .pickerStyle(.segmented)
                settingsNote("Focus робить акцент на композиції, Studio залишає більше вільного простору.")
            }
            settingsCard("Обкладинка", symbol: "square.stack.3d.up") {
                Toggle(isOn: $playerArtworkMotion) {
                    Label("Анімація обкладинки", systemImage: "sparkles.rectangle.stack")
                }
                Toggle(isOn: $playerArtworkSwipe) {
                    Label("Гортати пісні свайпом", systemImage: "hand.draw")
                }
                Toggle(isOn: $playerAmbientBackground) {
                    Label("Розмитий фон з обкладинки", systemImage: "drop.halffull")
                }
                settingsNote("Анімації обкладинки автоматично вимикаються, якщо в iOS увімкнено «Зменшення руху».")
            }
            settingsCard("Елементи", symbol: "slider.horizontal.3") {
                Toggle(isOn: $playerExtendedActions) {
                    Label("Кнопки Shuffle, Черга і Repeat", systemImage: "rectangle.3.group")
                }
                Toggle(isOn: $playerRemainingTime) {
                    Label("Показувати час до кінця", systemImage: "clock.arrow.circlepath")
                }
                settingsNote("Якщо приховати нижні кнопки, черга все одно доступна зверху плеєра, а Shuffle і Repeat — у налаштуваннях звуку.")
            }
            settingsCard("Тактильний відгук", symbol: "hand.tap") {
                Toggle(isOn: $playerHaptics) {
                    Label("Відгук при перемиканні композицій", systemImage: "hand.tap")
                }
            }
        }
    }

    private var settingsSyncPage: some View {
        VStack(spacing: 20) {
            settingsCard("AMusic Cloud", symbol: "person.crop.circle") {
                HStack(spacing: 10) {
                    Circle()
                        .fill(cloudAuth.isSignedIn ? Color.green : AMPalette.secondary(theme))
                        .frame(width: 7, height: 7)
                    Text(cloudAuth.isSignedIn ? "Підключено" : "Акаунт не підключено")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    NavigationLink {
                        AMCloudAccountScreen(cloud: cloudAuth)
                    } label: {
                        Text("Акаунт")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                settingsNote("Синхронізація використовує поточний Cloud-акаунт. Паролі та приватні MP3 не зберігаються в інтерфейсі налаштувань.")
            }
            settingsCard("Telegram Sync", symbol: "arrow.triangle.2.circlepath") {
                Toggle(isOn: $telegramSync.autoSyncEnabled) {
                    Label("Перевіряти нові MP3 автоматично", systemImage: "arrow.down.circle")
                }
                settingsNote("Коли опція активна, AMusic перевіряє нові треки при відкритті застосунку й після входу в Cloud. iOS не гарантує безперервну синхронізацію у фоні.")
                if let last = telegramSync.lastSyncAt {
                    HStack {
                        Text("Остання перевірка")
                        Spacer()
                        Text(last, style: .relative)
                            .foregroundStyle(AMPalette.secondary(theme))
                    }
                    .font(.subheadline)
                }
                Button {
                    Task { await telegramSync.sync(cloud: cloudAuth, music: music, force: true) }
                } label: {
                    HStack {
                        Label("Перевірити нові MP3", systemImage: "arrow.clockwise")
                        Spacer()
                        if telegramSync.isSyncing { ProgressView().tint(.white) }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!cloudAuth.isSignedIn || telegramSync.isSyncing)
                if telegramSync.isSyncing {
                    ProgressView(telegramSync.statusLine)
                } else if let message = telegramSync.notice {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
                if let message = telegramSync.error {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if !telegramSync.history.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Останні синхронізації")
                            .font(.footnote.weight(.semibold))
                        ForEach(telegramSync.history.prefix(3)) { entry in
                            HStack {
                                Text(entry.when, format: .dateTime.day().month().hour().minute())
                                Spacer()
                                Text("+\(entry.imported)")
                            }
                            .font(.footnote)
                            .foregroundStyle(AMPalette.secondary(theme))
                        }
                    }
                }
            }
            settingsCard("Де зберігається музика", symbol: "lock.shield") {
                settingsNote("Імпортовані MP3 зберігаються локально на iPhone. Приватне сховище Telegram Sync відокремлене від публічної Community.")
                settingsNote("Перед видаленням AMusic створюй резервну копію своїх файлів: видалення програми може стерти локальні композиції та особисті дані.")
            }
        }
    }

    private var settingsInteractionPage: some View {
        VStack(spacing: 20) {
            settingsCard("Анімації та відгук", symbol: "hand.tap") {
                Toggle("Вібровідгук вкладок", isOn: $tabHaptics)
                Toggle("Вібровідгук плеєра", isOn: $playerHaptics)
                Toggle("Зменшити анімації в AMusic", isOn: $devReduceMotion)
                settingsNote("AMusic додатково враховує системний параметр «Зменшення руху» в налаштуваннях доступності iOS.")
            }
            settingsCard("Керування плеєром", symbol: "slider.horizontal.3") {
                Toggle("Перемикати пісні свайпом", isOn: $playerArtworkSwipe)
                Picker("Крок перемотування", selection: $seekStep) {
                    Text("10 секунд").tag(10)
                    Text("15 секунд").tag(15)
                    Text("30 секунд").tag(30)
                }
                .pickerStyle(.menu)
                settingsNote("Налаштування діють у повноекранному плеєрі AMusic.")
            }
            settingsCard("Безпечне видалення", symbol: "trash.slash") {
                Toggle("Підтверджувати видалення треків", isOn: $confirmTrackDeletion)
                settingsNote("Рекомендується залишити ввімкненим: видалення аудіофайлу з iPhone неможливо скасувати без копії.")
            }
        }
    }

    private var settingsLibraryPage: some View {
        VStack(spacing: 24) {
            settingsCard("Вигляд композицій", symbol: "list.bullet") {
                Toggle("Компактний список", isOn: $devCompactRows)
                Toggle("Показувати підписи під назвами", isOn: $showTrackSubtitle)
                settingsNote("Додавання до улюблених тепер у меню ••• біля композиції.")
            }
            settingsCard("Порядок музики", symbol: "arrow.up.arrow.down") {
                Picker("Сортування", selection: $librarySortOrder) {
                    Text("Спочатку нові").tag("recent")
                    Text("Спочатку старі").tag("oldest")
                    Text("За назвою").tag("title")
                    Text("Нещодавно слухав").tag("lastPlayed")
                    Text("Найчастіше слухаю").tag("mostPlayed")
                }
                .pickerStyle(.menu)
                Toggle("Запитувати перед видаленням", isOn: $confirmTrackDeletion)
                settingsNote("Підтвердження захищає від випадкового видалення імпортованого аудіофайлу.")
            }
            settingsCard("Твоя бібліотека", symbol: "square.stack") {
                settingsStat("Композицій", "\(music.tracks.count)")
                settingsStat("Плейлистів", "\(music.playlists.count)")
                settingsStat("В улюблених", "\(music.favoriteIDs.count)")
                settingsStat("У черзі", "\(music.upcomingIDs.count)")
            }
        }
        .font(.body)
    }

    // AMusic 15.3: only two app-wide display modes.
    // The private profile's own creative settings remain independent.
    private var settingsAppearancePage: some View {
        VStack(spacing: 18) {
            settingsCard("Режим оформлення", symbol: "square.on.square") {
                HStack(spacing: 12) {
                    appearanceChoice(
                        value: "orange",
                        title: "Стандартний",
                        subtitle: "Темний",
                        background: Color(red: 0.08, green: 0.10, blue: 0.12),
                        foreground: .white
                    )
                    appearanceChoice(
                        value: "light",
                        title: "Білий",
                        subtitle: "Світлий",
                        background: Color(red: 0.94, green: 0.95, blue: 0.97),
                        foreground: Color(red: 0.08, green: 0.10, blue: 0.12)
                    )
                }
                settingsNote("Два режими без зайвих кольорів. Зміни застосовуються одразу.")
            }

            settingsCard("Попередній перегляд", symbol: "eye") {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(AMProfileStyle.blue.opacity(0.13))
                        .frame(width: 50, height: 50)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 21, weight: .medium))
                                .foregroundStyle(AMProfileStyle.blue)
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Моя музика")
                            .font(.subheadline.weight(.semibold))
                        Text("Так виглядатимуть композиції")
                            .font(.caption)
                            .foregroundStyle(AMPalette.secondary(theme))
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 29))
                        .foregroundStyle(AMProfileStyle.blue)
                }
                .padding(11)
                .background(AMPalette.elevated(theme).opacity(0.55),
                            in: RoundedRectangle(cornerRadius: 13))
            }

            settingsCard("Зручність", symbol: "slider.horizontal.3") {
                Toggle(isOn: $showMiniPlayer) {
                    Label("Мініплеєр унизу", systemImage: "play.rectangle")
                }
                Toggle(isOn: $devReduceMotion) {
                    Label("Менше анімацій", systemImage: "figure.walk.motion")
                }
                settingsNote("Мініплеєр можна приховати, не вимикаючи відтворення. Зменшення анімацій не впливає на музику.")
            }

            Button {
                showAppearanceResetConfirmation = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Скинути оформлення")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AMPalette.secondary(theme))
                }
                .font(.subheadline.weight(.medium))
                .padding(16)
                .foregroundStyle(AMPalette.primary(theme))
                .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 15))
            }
            .buttonStyle(AMPressStyle())
            settingsNote("Скидання не видаляє музику, плейлисти, фото, профіль або нотатки.")
        }
        .font(.body)
        .onAppear {
            // Former experimental palettes were removed; keep the user's
            // white theme if it was selected, otherwise use Standard.
            if theme != "light" && theme != "orange" {
                theme = "orange"
            }
        }
    }

    private func appearanceChoice(
        value: String,
        title: String,
        subtitle: String,
        background: Color,
        foreground: Color
    ) -> some View {
        let isSelected = theme == value
        return Button {
            if tabHaptics { UISelectionFeedbackGenerator().selectionChanged() }
            withAnimation(reduceMotion || devReduceMotion ? nil : AMMotion.selection) {
                theme = value
            }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(background)
                        .frame(height: 85)
                        .overlay(alignment: .leading) {
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(foreground.opacity(0.38))
                                    .frame(width: 42, height: 7)
                                HStack(spacing: 7) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(AMProfileStyle.blue.opacity(0.85))
                                        .frame(width: 28, height: 28)
                                    VStack(alignment: .leading, spacing: 5) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(foreground.opacity(0.75))
                                            .frame(width: 55, height: 5)
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(foreground.opacity(0.25))
                                            .frame(width: 38, height: 4)
                                    }
                                }
                            }
                            .padding(12)
                        }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(AMProfileStyle.blue)
                            .padding(7)
                    }
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AMPalette.primary(theme))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AMPalette.secondary(theme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 15))
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(isSelected ? AMProfileStyle.blue : AMPalette.elevated(theme),
                                  lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(AMPressStyle())
        .accessibilityLabel("\(title), \(isSelected ? "вибрано" : "вибрати")")
    }

    private var settingsNavigationPage: some View {
        VStack(spacing: 24) {
            settingsCard("Вкладки", symbol: "square.grid.2x2") {
                Toggle("Показувати YouTube", isOn: $devShowYouTube)
                Toggle("Вібровідгук при зміні вкладок", isOn: $tabHaptics)
                settingsNote("Вкладка YouTube залишається незалежною від локального плеєра.")
            }
            settingsCard("Під час запуску", symbol: "house") {
                HStack {
                    Text("Відкривати вкладку")
                    Spacer()
                    Picker("Вкладка при запуску", selection: $startTab) {
                        Text("Музика").tag("Музика")
                        if devShowYouTube { Text("YouTube").tag("YouTube") }
                        Text("Профіль").tag("Профіль")
                    }
                    .pickerStyle(.menu)
                }
                settingsNote("Застосовується під час наступного запуску AMusic.")
            }
        }
        .font(.body)
    }

    private var settingsAboutPage: some View {
        VStack(spacing: 24) {
            settingsCard("AMusic", symbol: "waveform") {
                settingsStat("Версія AMusic", AMRelease.version)
                settingsStat("Оновлення", AMRelease.subtitle)
                settingsStat("Версія iOS", UIDevice.current.systemVersion)
                settingsStat("Музичний рушій", "AVFoundation")
                settingsStat("Фонове відтворення", "Для локальної музики")
                settingsNote("AMusic зберігає імпортовану музику, плейлисти, фото та нотатки локально на iPhone.")
            }
            settingsCard("Керування та можливості", symbol: "checkmark.shield") {
                settingsStat("Автоімпорт із Telegram", telegramSync.autoSyncEnabled ? "Увімкнено" : "Вимкнено")
                settingsStat("Smart Shuffle", music.shuffleEnabled ? "Увімкнено" : "Вимкнено")
                settingsStat("Еквалайзер", music.equalizerEnabled ? "Увімкнено" : "Вимкнено")
                settingsStat("Оформлення", theme == "light" ? "Світле" : "Темне")
            }
            settingsCard("Безпека даних", symbol: "externaldrive") {
                settingsNote("Не видаляй AMusic перед оновленням IPA: це може стерти її локальні файли. Використовуй встановлення поверх поточної версії з тим самим Bundle ID.")
            }
            AMSigningCountdownView(theme: theme)
        }
    }

    private func settingsStat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(AMPalette.secondary(theme))
            Spacer(minLength: 6)
            Text(value)
                .foregroundStyle(AMPalette.primary(theme))
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12))
    }

    // MARK: - Liquid Glass mini player (preserves local playback / EQ / Shuffle)

    private var miniPlayer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { showPlayer = true } label: {
                    HStack(spacing: 11) {
                        albumArtwork(music.current, size: 43)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(music.current?.title ?? "AMusic")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(AMPalette.primary(theme))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(music.isPlaying ? AMProfileStyle.blue : AMPalette.secondary(theme))
                                    .frame(width: 5, height: 5)
                                Text(music.isPlaying ? "Зараз грає" : "На паузі")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(AMPalette.secondary(theme))
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AMPressStyle())
                .accessibilityLabel("Відкрити плеєр: \(music.current?.title ?? "AMusic")")

                Button { music.toggle() } label: {
                    Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme == "light" ? AMProfileStyle.blue : .white)
                        .frame(width: 44, height: 44)
                        .background(AMProfileStyle.blue.opacity(theme == "light" ? 0.13 : 0.25),
                                    in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(AMPressStyle())
                .accessibilityLabel(music.isPlaying ? "Пауза" : "Продовжити")

                Button { switchPlayerTrack(forward: true) } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(AMPalette.primary(theme))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(AMPressStyle())
                .accessibilityLabel("Наступна композиція")
            }
            .padding(.horizontal, 11)
            .padding(.top, 7)
            .padding(.bottom, 7)

            GeometryReader { geometry in
                Capsule(style: .continuous)
                    .fill(AMProfileStyle.blue.opacity(0.15))
                    .overlay(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(AMProfileStyle.blue)
                            .frame(width: max(0, geometry.size.width * musicFraction))
                    }
            }
            .frame(height: 2.5)
            .padding(.horizontal, 22)
            .padding(.bottom, 8)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: 460)
        .amNativeGlass()
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(theme == "light" ? 0.57 : 0.16), lineWidth: 0.8)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(theme == "light" ? 0.07 : 0.20), radius: 18, x: 0, y: 7)
        .padding(.horizontal, 15)
    }
    // MARK: - Immersive full-screen player

    private var playerScreen: some View {
        GeometryReader { geometry in
            let compactHeight = geometry.size.height < 690
            let artSize = max(155, min(geometry.size.width - 62,
                                       geometry.size.height * (compactHeight ? 0.36 : 0.425), 380))

            ZStack {
                playerBackdrop(size: geometry.size)

                VStack(spacing: 0) {
                    playerTopBar

                    Spacer(minLength: 4)

                    playerArtwork(size: artSize)
                        .frame(maxWidth: .infinity)
                        .accessibilityHint("Проведи ліворуч або праворуч для зміни композиції")

                    Spacer(minLength: 10)

                    playerTrackInformation
                        .padding(.bottom, compactHeight ? 10 : 19)

                    playerSeekControls

                    playerTransportControls
                        .padding(.top, compactHeight ? 8 : 17)

                    if playerExtendedActions {
                        playerSecondaryControls
                            .padding(.top, compactHeight ? 9 : 20)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 25)
                .padding(.top, compactHeight ? 5 : 12)
                .padding(.bottom, compactHeight ? 5 : 12)
            }
        }
        .foregroundStyle(AMPalette.primary(theme))
        .preferredColorScheme(theme == "light" ? .light : .dark)
        .onChange(of: music.current?.id) { _, _ in
            playerSeekDraft = nil
            if playerHaptics && !(reduceMotion || devReduceMotion) {
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
        .onDisappear {
            coverDragOffset = 0
            playerSeekDraft = nil
        }
        .sheet(isPresented: $showQueue) {
            queueScreen.presentationDragIndicator(.visible)
        }
    }

    // Soft artwork colors in the background, without losing text contrast.
    private func playerBackdrop(size: CGSize) -> some View {
        ZStack {
            AMProfileStyle.background(theme)
            if playerAmbientBackground,
               let track = music.current, let image = music.artwork[track.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .blur(radius: 76)
                    .opacity(theme == "light" ? 0.10 : 0.17)
                    .id(track.id)
                    .transition(.opacity)
            } else if playerAmbientBackground {
                Ellipse()
                    .fill(AMProfileStyle.blue.opacity(theme == "light" ? 0.13 : 0.20))
                    .frame(width: size.width * 0.84, height: size.height * 0.45)
                    .blur(radius: 65)
                    .offset(y: -size.height * 0.15)
            }
            LinearGradient(
                colors: [
                    AMProfileStyle.background(theme).opacity(theme == "light" ? 0.65 : 0.49),
                    AMProfileStyle.background(theme).opacity(theme == "light" ? 0.82 : 0.74),
                    AMProfileStyle.background(theme).opacity(0.98)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(width: size.width, height: size.height)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.42), value: music.current?.id)
    }

    private var playerTopBar: some View {
        HStack {
            Button { showPlayer = false } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 43, height: 43)
                    .background(AMPalette.card(theme).opacity(0.70))
                    .clipShape(Circle())
            }
            .buttonStyle(AMPressStyle())
            .accessibilityLabel("Закрити плеєр")

            Spacer()

            HStack(spacing: 9) {
                AMEqualizer(isPlaying: music.isPlaying && !devReduceMotion,
                            color: AMProfileStyle.blue, count: 4,
                            maxHeight: 18, barWidth: 2.5)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text("AMUSIC")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2.0)
                        .foregroundStyle(AMProfileStyle.blue)
                    Text(playerPresentation == "focus" ? "ЗАРАЗ ГРАЄ" : "ПЛЕЄР")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(AMPalette.secondary(theme))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(music.isPlaying ? "Зараз грає" : "Музика на паузі")

            Spacer()

            Menu {
                Button("Після поточної композиції", systemImage: "moon.stars") {
                    music.scheduleSleepAfterCurrentTrack()
                }
                Divider()
                ForEach([5, 10, 15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                    Button("\(minutes) хв") { music.scheduleSleepTimer(minutes: minutes) }
                }
                if music.sleepTimerEnd != nil || music.sleepAfterCurrentTrack {
                    Divider()
                    Button(role: .destructive) {
                        music.cancelSleepTimer()
                    } label: {
                        Label("Вимкнути таймер", systemImage: "xmark.circle")
                    }
                }
            } label: {
                Image(systemName: music.sleepTimerEnd != nil || music.sleepAfterCurrentTrack ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(music.sleepTimerEnd != nil || music.sleepAfterCurrentTrack ? AMProfileStyle.blue : AMPalette.primary(theme))
                    .frame(width: 43, height: 43)
                    .background(AMPalette.card(theme).opacity(0.70))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Таймер сну")

            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 43, height: 43)
                    .background(AMPalette.card(theme).opacity(0.70))
                    .clipShape(Circle())
            }
            .buttonStyle(AMPressStyle())
            .accessibilityLabel("Черга відтворення")
        }
    }

    private func playerArtwork(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 29)
                .fill(AMProfileStyle.blue.opacity(0.19))
                .frame(width: size + 12, height: size + 12)
                .blur(radius: 22)

            ZStack {
                if let track = music.current {
                    albumArtwork(track, size: size)
                        .id(track.id)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: CGFloat(coverTransitionDirection) * 46)),
                            removal: .opacity.combined(with: .scale(scale: 0.96))
                        ))
                } else {
                    albumArtwork(nil, size: size)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 25))
            .overlay {
                RoundedRectangle(cornerRadius: 25)
                    .strokeBorder(AMPalette.primary(theme).opacity(0.11), lineWidth: 1)
            }
            .shadow(color: .black.opacity(theme == "light" ? 0.18 : 0.45), radius: 32, y: 20)
            .scaleEffect(reduceMotion || devReduceMotion || !playerArtworkMotion ? 1 : (music.isPlaying ? 1.0 : 0.966))
            .offset(x: reduceMotion || devReduceMotion || !playerArtworkSwipe ? 0 : coverDragOffset)
            .rotationEffect(.degrees(reduceMotion || devReduceMotion || !playerArtworkSwipe ? 0 : Double(coverDragOffset) / 34))
            .animation(reduceMotion || devReduceMotion || !playerArtworkMotion ? nil : AMMotion.tab,
                       value: music.current?.id)
            .animation(reduceMotion || devReduceMotion || !playerArtworkMotion ? nil :
                       .spring(response: 0.40, dampingFraction: 0.82), value: music.isPlaying)
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard playerArtworkSwipe, !(reduceMotion || devReduceMotion),
                              abs(value.translation.width) > abs(value.translation.height) else { return }
                        coverDragOffset = min(100, max(-100, value.translation.width * 0.62))
                    }
                    .onEnded { value in
                        let width = value.translation.width
                        let isHorizontal = abs(width) > abs(value.translation.height)
                        withAnimation(reduceMotion ? nil : AMMotion.tab) {
                            coverDragOffset = 0
                        }
                        guard playerArtworkSwipe, isHorizontal, abs(width) > 66 else { return }
                        switchPlayerTrack(forward: width < 0)
                    }
            )
        }
        .frame(width: size + 20, height: size + 32)
        .animation(reduceMotion || devReduceMotion || !playerArtworkMotion ? nil : AMMotion.tab,
                   value: music.current?.id)
    }

    private var playerTrackInformation: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(music.current?.title ?? "AMusic")
                    .font(.system(size: playerPresentation == "focus" ? 26 : 23,
                                  weight: .semibold, design: .default))
                    .tracking(-0.5)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .contentTransition(.opacity)

                HStack(spacing: 7) {
                    Image(systemName: music.isPlaying ? "waveform" : "music.note")
                        .font(.system(size: 10))
                    Text("Моя бібліотека")
                    if let current = music.current,
                       let index = music.tracks.firstIndex(where: { $0.id == current.id }) {
                        Text("·")
                        Text("\(index + 1) із \(music.tracks.count)")
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AMPalette.secondary(theme))
            }

            Spacer(minLength: 3)

            if let track = music.current {
                Button {
                    withAnimation(reduceMotion ? nil : AMMotion.selection) {
                        music.toggleFavorite(track)
                    }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Image(systemName: music.isFavorite(track) ? "heart.fill" : "heart")
                        .font(.system(size: 23))
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(music.isFavorite(track) ? AMProfileStyle.blue : AMPalette.primary(theme))
                        .frame(width: 48, height: 48)
                        .background(AMPalette.card(theme).opacity(0.66))
                        .clipShape(Circle())
                }
                .buttonStyle(AMPressStyle())
                .accessibilityLabel(music.isFavorite(track) ? "Прибрати з улюбленого" : "Додати в улюблене")
            }
        }
    }

    private var playerSeekControls: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { playerSeekDraft ?? music.progress },
                    set: { playerSeekDraft = $0 }
                ),
                in: 0...max(1, music.duration),
                onEditingChanged: { editing in
                    if !editing, let position = playerSeekDraft {
                        music.seek(position)
                        playerSeekDraft = nil
                    }
                }
            )
            .tint(AMProfileStyle.blue)
            .accessibilityLabel("Перемотування композиції")

            HStack(spacing: 10) {
                Button { music.seek(max(0, music.progress - Double(seekStep))) } label: {
                    Image(systemName: "gobackward.\(seekStep)")
                        .font(.system(size: 18))
                        .frame(width: 39, height: 32)
                }
                .buttonStyle(AMPressStyle())
                .accessibilityLabel("Назад на \(seekStep) секунд")
                Text(timestamp(playerSeekDraft ?? music.progress))
                Spacer(minLength: 6)
                Text(playerRemainingTime
                     ? "−" + timestamp(max(0, music.duration - (playerSeekDraft ?? music.progress)))
                     : timestamp(music.duration))
                Button { music.seek(min(music.duration, music.progress + Double(seekStep))) } label: {
                    Image(systemName: "goforward.\(seekStep)")
                        .font(.system(size: 18))
                        .frame(width: 39, height: 32)
                }
                .buttonStyle(AMPressStyle())
                .accessibilityLabel("Вперед на \(seekStep) секунд")
            }
            .font(.system(size: 11, weight: .medium, design: .default))
            .monospacedDigit()
            .foregroundStyle(AMPalette.secondary(theme))
        }
    }

    private var playerTransportControls: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button { switchPlayerTrack(forward: false) } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 26))
                    .frame(width: 66, height: 65)
            }
            .buttonStyle(AMPressStyle())
            .accessibilityLabel("Попередня композиція")

            Spacer(minLength: 12)

            Button { music.toggle() } label: {
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 78, height: 78)
                    .background(AMProfileStyle.blue)
                    .clipShape(Circle())
                    .shadow(color: AMProfileStyle.blue.opacity(0.25), radius: 18, y: 7)
            }
            .buttonStyle(AMPressStyle())
            .accessibilityLabel(music.isPlaying ? "Пауза" : "Відтворити")

            Spacer(minLength: 12)

            Button { switchPlayerTrack(forward: true) } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 26))
                    .frame(width: 66, height: 65)
            }
            .buttonStyle(AMPressStyle())
            .accessibilityLabel("Наступна композиція")
            Spacer(minLength: 0)
        }
    }

    private var playerSecondaryControls: some View {
        HStack(spacing: 13) {
            Button { music.updateShuffle(!music.shuffleEnabled) } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(music.shuffleEnabled ? AMProfileStyle.blue : AMPalette.secondary(theme))
                    .frame(maxWidth: .infinity)
                    .frame(height: 45)
                    .background(AMPalette.card(theme).opacity(0.74))
                    .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(AMPressStyle())
            .accessibilityLabel("Випадковий порядок")

            Button { showQueue = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.number")
                    Text("Черга")
                    if !music.upcomingIDs.isEmpty {
                        Text("\(music.upcomingIDs.count)")
                            .foregroundStyle(AMProfileStyle.blue)
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AMPalette.primary(theme))
                .frame(maxWidth: .infinity)
                .frame(height: 45)
                .background(AMPalette.card(theme).opacity(0.74))
                .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(AMPressStyle())

            Button { music.updateRepeat(!music.repeatTrack) } label: {
                Image(systemName: "repeat.1")
                    .font(.system(size: 18))
                    .foregroundStyle(music.repeatTrack ? AMProfileStyle.blue : AMPalette.secondary(theme))
                    .frame(width: 52, height: 45)
                    .background(AMPalette.card(theme).opacity(0.74))
                    .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(AMPressStyle())
            .accessibilityLabel("Повтор однієї композиції")
        }
    }

    // A swipe changes tracks only when the user intentionally moves across the cover.
    // This leaves the seek slider and vertical dismissal gesture independent.
    private func switchPlayerTrack(forward: Bool) {
        coverTransitionDirection = forward ? 1 : -1
        if playerHaptics { UISelectionFeedbackGenerator().selectionChanged() }
        withAnimation(reduceMotion || devReduceMotion || !playerArtworkMotion ? nil : AMMotion.tab) {
            if forward { music.next() } else { music.previous() }
        }
    }

    // MARK: - iOS 27-style floating navigation
    // Native Liquid Glass on iOS 26+; material fallback for older iPhones.
    // The existing five-second Profile hold remains unchanged.

    private var visibleDockTabs: [AMTab] {
        AMTab.allCases.filter { item in
            item != .youtube || devShowYouTube
        }
    }

    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(visibleDockTabs, id: \.self) { item in
                if item == .profile {
                    tabItem(item)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 5, maximumDistance: 28)
                                .onEnded { completed in
                                    guard completed else { return }
                                    profileWasHeld = true
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    privateSpacePasscode = ""
                                    privateSpaceWrongCode = false
                                    showPrivateSpaceGate = true
                                }
                        )
                } else {
                    tabItem(item)
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: 460)
        .amNativeGlass()
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(theme == "light" ? 0.65 : 0.20), lineWidth: 0.9)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(theme == "light" ? 0.10 : 0.28), radius: 24, x: 0, y: 9)
        .padding(.horizontal, 15)
        .padding(.bottom, 7)
        .accessibilityElement(children: .contain)
    }

    private func tabItem(_ item: AMTab) -> some View {
        let isSelected = tab == item
        return Button {
            if item == .profile && (profileWasHeld || showPrivateSpace || showPrivateSpaceGate) { return }
            changeTab(item)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tabIcon(item, selected: isSelected))
                    .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(height: 24)
                Text(item.rawValue)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(isSelected
                             ? (theme == "light" ? AMProfileStyle.blue : Color.white)
                             : AMPalette.secondary(theme))
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background {
                if isSelected {
                    Capsule()
                        .fill(AMProfileStyle.blue.opacity(theme == "light" ? 0.15 : 0.24))
                        .overlay {
                            Capsule()
                                .strokeBorder(AMProfileStyle.blue.opacity(theme == "light" ? 0.15 : 0.29),
                                              lineWidth: 0.9)
                        }
                        .matchedGeometryEffect(id: "amusic.dock.activeTab", in: tabSelectionNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(AMPressStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(item == .profile
            ? "Утримуй п’ять секунд для нотаток, фото й режиму розробника"
            : "Перейти до вкладки \(item.rawValue)")
    }

    private func changeTab(_ next: AMTab) {
        guard tab != next else { return }
        if tabHaptics { UISelectionFeedbackGenerator().selectionChanged() }
        withAnimation(reduceMotion || devReduceMotion ? nil : AMMotion.tab) {
            tab = next
        }
    }

    private func tabIcon(_ item: AMTab, selected: Bool) -> String {
        switch item {
        case .music: return selected ? "music.note.list" : "music.note"
        case .youtube: return selected ? "play.rectangle.fill" : "play.rectangle"
        case .profile: return selected ? "person.crop.circle.fill" : "person.crop.circle"
        }
    }

    private func avatarImage(size: CGFloat) -> some View {
        AMFramedAvatar(image: avatar, theme: theme, frameStyle: avatarFrame, size: size)
    }

    private func avatarURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("amusic_profile_avatar.jpg")
    }

    private func bannerURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("amusic_profile_banner.jpg")
    }

    private func loadSavedAvatar() {
        avatar = UIImage(contentsOfFile: avatarURL().path)
        banner = UIImage(contentsOfFile: bannerURL().path)
    }

    private func saveSelectedBanner(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.76) else {
            music.errorMessage = "Не вдалося обробити шапку профілю."
            return
        }
        do {
            try data.write(to: bannerURL(), options: .atomic)
            withAnimation(reduceMotion || devReduceMotion ? nil : AMMotion.tab) {
                banner = image
            }
        } catch {
            music.errorMessage = "Помилка збереження шапки: \(error.localizedDescription)"
        }
    }

    private func removeBanner() {
        do {
            let url = bannerURL()
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            banner = nil
        } catch {
            music.errorMessage = "Не вдалося прибрати шапку профілю."
        }
    }

    private func saveSelectedPhoto(_ image: UIImage) {
        guard let jpeg = image.jpegData(compressionQuality: 0.75) else {
            music.errorMessage = "Не вдалося обробити фото."
            return
        }
        do {
            try jpeg.write(to: avatarURL(), options: .atomic)
            withAnimation(reduceMotion ? nil : AMMotion.tab) {
                avatar = image
            }
        } catch {
            music.errorMessage = "Помилка збереження аватарки: \(error.localizedDescription)"
        }
    }

    private func removeAvatar() {
        do {
            let path = avatarURL()
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
            withAnimation(reduceMotion ? nil : AMMotion.tab) {
                avatar = nil
            }
        } catch {
            music.errorMessage = "Не вдалося видалити аватарку."
        }
    }

    private func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Per-track editing (title + user-selected cover)

private struct AMTrackEditorSheet: View {
    let track: MusicTrack
    @ObservedObject var store: MusicStore
    let theme: String

    @Environment(\.dismiss) private var dismiss
    @State private var draftTitle: String
    @State private var selectedCover: UIImage?
    @State private var removeCover = false
    @State private var showPhotoPicker = false

    init(track: MusicTrack, store: MusicStore, theme: String) {
        self.track = track
        self.store = store
        self.theme = theme
        _draftTitle = State(initialValue: track.title)
    }

    private var accent: Color { AMPalette.accent(theme) }

    private var displayedCover: UIImage? {
        if removeCover { return nil }
        return selectedCover ?? store.artwork[track.id]
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 19)
                                .fill(AMPalette.elevated(theme))
                            if let image = displayedCover {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 184, height: 184)
                                    .clipped()
                            } else {
                                Image(systemName: "music.note")
                                    .font(.system(size: 53, weight: .ultraLight))
                                    .foregroundStyle(accent)
                            }
                        }
                        .frame(width: 184, height: 184)
                        .clipShape(RoundedRectangle(cornerRadius: 19))
                        .overlay {
                            RoundedRectangle(cornerRadius: 19)
                                .strokeBorder(AMPalette.primary(theme).opacity(0.07), lineWidth: 1)
                        }

                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("Вибрати обкладинку", systemImage: "photo.on.rectangle")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(accent)
                        }
                        .buttonStyle(.plain)

                        if selectedCover != nil || store.hasCustomArtwork(track) {
                            Button(role: .destructive) {
                                selectedCover = nil
                                removeCover = true
                            } label: {
                                Text("Прибрати свою обкладинку")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)

                    VStack(alignment: .leading, spacing: 9) {
                        Text("НАЗВА КОМПОЗИЦІЇ")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(AMPalette.secondary(theme))
                        TextField("Назва треку", text: $draftTitle)
                            .font(.system(size: 16, weight: .medium))
                            .padding(15)
                            .background(AMPalette.card(theme))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                        Text("Назва й обкладинка будуть збережені в AMusic. Сам MP3/M4A не зміниться.")
                            .font(.system(size: 11))
                            .foregroundStyle(AMPalette.secondary(theme))
                    }

                    Button {
                        if store.editTrack(track, title: draftTitle, newCover: selectedCover, removeCover: removeCover) {
                            dismiss()
                        }
                    } label: {
                        Text("Зберегти зміни")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(accent)
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                    }
                    .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 26)
            }
            .background(AMPalette.background(theme))
            .navigationTitle("Редагувати трек")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Скасувати") { dismiss() }
                }
            }
        }
        .foregroundStyle(AMPalette.primary(theme))
        .preferredColorScheme(theme == "light" ? .light : .dark)
        .tint(accent)
        .onAppear { store.requestArtwork(for: track) }
        .sheet(isPresented: $showPhotoPicker) {
            AMAvatarPhotoPicker { image in
                selectedCover = image
                removeCover = false
            }
        }
    }
}

// MARK: - Photo gallery picker (UIKit / PHPicker)

private struct AMAvatarPhotoPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onImage: (UIImage) -> Void

        init(onImage: @escaping (UIImage) -> Void) {
            self.onImage = onImage
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                return
            }

            provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard let image = object as? UIImage else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.onImage(image)
                }
            }
        }
    }
}

// MARK: - Private Space · notes + personal photo gallery (stored on this iPhone)
// This section is a convenience shortcut, NOT encrypted or access-controlled.

private struct AMPrivateNote: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var body: String
    var modifiedAt: Date = Date()
}

private struct AMPrivatePhoto: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var filename: String
    var addedAt: Date = Date()
}

@MainActor
private final class AMPrivateSpaceStore: ObservableObject {
    @Published private(set) var notes: [AMPrivateNote] = []
    @Published private(set) var photos: [AMPrivatePhoto] = []
    @Published var errorMessage: String?
    @Published var isImporting = false

    private var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AMusicPersonalSpace", isDirectory: true)
    }
    private var photoFolder: URL { folder.appendingPathComponent("Photos", isDirectory: true) }
    private var notesFile: URL { folder.appendingPathComponent("notes.json") }
    private var photosFile: URL { folder.appendingPathComponent("photos.json") }

    init() { load() }

    private func makeDirectories() throws {
        try FileManager.default.createDirectory(at: photoFolder, withIntermediateDirectories: true)
    }

    private func load() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: notesFile),
           let decoded = try? decoder.decode([AMPrivateNote].self, from: data) {
            notes = decoded.sorted { $0.modifiedAt > $1.modifiedAt }
        }
        if let data = try? Data(contentsOf: photosFile),
           let decoded = try? decoder.decode([AMPrivatePhoto].self, from: data) {
            photos = decoded.filter { FileManager.default.fileExists(atPath: photoURL($0).path) }
                .sorted { $0.addedAt > $1.addedAt }
        }
    }

    private func saveNotes() {
        do {
            try makeDirectories()
            try JSONEncoder().encode(notes).write(to: notesFile, options: .atomic)
        } catch {
            errorMessage = "Не вдалося зберегти нотатки: \(error.localizedDescription)"
        }
    }
    private func savePhotos() {
        do {
            try makeDirectories()
            try JSONEncoder().encode(photos).write(to: photosFile, options: .atomic)
        } catch {
            errorMessage = "Не вдалося зберегти фотографії: \(error.localizedDescription)"
        }
    }

    func save(_ note: AMPrivateNote) {
        var updated = note
        updated.modifiedAt = Date()
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = updated
        } else {
            notes.append(updated)
        }
        notes.sort { $0.modifiedAt > $1.modifiedAt }
        saveNotes()
    }
    func delete(_ note: AMPrivateNote) {
        notes.removeAll { $0.id == note.id }
        saveNotes()
    }

    func photoURL(_ photo: AMPrivatePhoto) -> URL {
        photoFolder.appendingPathComponent(photo.filename)
    }

    func delete(_ photo: AMPrivatePhoto) {
        do {
            let url = photoURL(photo)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            photos.removeAll { $0.id == photo.id }
            savePhotos()
        } catch {
            errorMessage = "Не вдалося видалити фото: \(error.localizedDescription)"
        }
    }

    // Native UIKit photo picker supplies UIImage directly; avoids SwiftUI PhotosPickerItem
    // which is unavailable under some XTool/Swift SDK combinations.
    func importPhoto(_ image: UIImage) {
        isImporting = true
        defer { isImporting = false }
        do {
            try makeDirectories()
            // Fit to 1600px to limit storage while retaining display quality.
            let original = image.size
            let factor = min(1.0, 1600.0 / max(max(original.width, original.height), 1))
            let target = CGSize(width: max(1, original.width * factor),
                                height: max(1, original.height * factor))
            let renderer = UIGraphicsImageRenderer(size: target)
            let resized = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
            guard let jpeg = resized.jpegData(compressionQuality: 0.84) else {
                errorMessage = "Не вдалося обробити фотографію."
                return
            }
            let new = AMPrivatePhoto(filename: UUID().uuidString + ".jpg")
            try jpeg.write(to: photoURL(new), options: .atomic)
            photos.insert(new, at: 0)
            savePhotos()
        } catch {
            errorMessage = "Не вдалося додати фото: \(error.localizedDescription)"
        }
    }

}

private struct AMPrivateSpaceHome: View {
    @ObservedObject var store: AMPrivateSpaceStore
    @ObservedObject var music: MusicStore
    @ObservedObject var cloud: AMCloudAuthStore
    let theme: String
    @Environment(\.dismiss) private var dismiss
    private var accent: Color { AMPalette.accent(theme) }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Label("ОСОБИСТИЙ РОЗДІЛ", systemImage: "lock.shield")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.2)
                                .foregroundStyle(AMProfileStyle.blue)
                            Spacer()
                            Text("ЛОКАЛЬНО")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(AMPalette.secondary(theme))
                        }
                        Text("Мій простір")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .tracking(-1.2)
                        Text("Твої нотатки, фотографії та персональні інструменти — в одному місці.")
                            .font(.system(size: 13))
                            .foregroundStyle(AMPalette.secondary(theme))
                        HStack(spacing: 10) {
                            privateSummaryTile(symbol: "note.text", title: "Нотатки", count: store.notes.count)
                            privateSummaryTile(symbol: "photo", title: "Фото", count: store.photos.count)
                        }
                        .padding(.top, 5)
                    }
                    .padding(16)
                    .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 18))
                    .padding(.top, 12)

                    NavigationLink {
                        AMPrivateNotesView(store: store, theme: theme)
                    } label: {
                        spaceCard(icon: "note.text", title: "Нотатки",
                                  subtitle: "Записуй і редагуй",
                                  count: "\(store.notes.count)", color: accent)
                    }
                    .buttonStyle(AMPressStyle())

                    NavigationLink {
                        AMPrivatePhotosView(store: store, theme: theme)
                    } label: {
                        spaceCard(icon: "photo.on.rectangle.angled", title: "Фото",
                                  subtitle: "Власна фотогалерея",
                                  count: "\(store.photos.count)", color: Color(red: 0.42, green: 0.67, blue: 1))
                    }
                    .buttonStyle(AMPressStyle())

                    NavigationLink {
                        AMDeveloperToolsView(music: music, cloud: cloud, theme: theme,
                                             notesCount: store.notes.count,
                                             photosCount: store.photos.count)
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(.green)
                                .frame(width: 64, height: 64)
                                .background(Color.green.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Режим розробника")
                                    .font(.system(size: 19, weight: .bold, design: .rounded))
                                Text("Теми, меню, плеєр і діагностика")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AMPalette.secondary(theme))
                                Text("DEV TOOLS")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.green)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AMPalette.secondary(theme))
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AMPalette.card(theme))
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                    }
                    .buttonStyle(AMPressStyle())

                    Label("Доступ за кодом. Дані зберігаються локально, без додаткового шифрування.", systemImage: "lock")
                        .font(.system(size: 11))
                        .foregroundStyle(AMPalette.secondary(theme))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 10)
                }
                .padding(21)
            }
            .background(AMPalette.background(theme))
            .navigationTitle("Мій простір")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .tint(accent)
            .foregroundStyle(AMPalette.primary(theme))
        }
        .preferredColorScheme(theme == "light" ? .light : .dark)
        .alert("AMusic", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private func privateSummaryTile(symbol: String, title: String, count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(AMProfileStyle.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(count)")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(AMPalette.secondary(theme))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(AMPalette.elevated(theme).opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private func spaceCard(icon: String, title: String, subtitle: String,
                           count: String, color: Color) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 64, height: 64)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 19, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(AMPalette.secondary(theme))
                Text(count + " збережено")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AMPalette.secondary(theme))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AMPalette.card(theme))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - AMusic 14.4 · single shared public profile presentation
// Preview is local only: there is no social profile server or publishing feature.

private struct AMProfileConfig {
    let nickname: String
    let status: String
    let bio: String
    let genre: String
    let accent: String
    let cover: String
    let alignment: String
    let badge: String
    let typography: String
    let showStats: Bool
    let frameStyle: String
}

private enum AMProfileTypography {
    static func design(for style: String) -> Font.Design {
        switch style {
        case "rounded": return .rounded
        case "serif": return .serif
        case "mono": return .monospaced
        default: return .default
        }
    }
}

private enum AMProfileStyle {
    static let blue = Color(red: 0.20, green: 0.59, blue: 0.92)

    static func background(_ theme: String) -> Color {
        theme == "light"
            ? Color(red: 0.94, green: 0.96, blue: 0.98)
            : Color(red: 0.065, green: 0.085, blue: 0.115)
    }
}

// MARK: - AMusic 16.9.6 · Profile Atelier
// Unified profile surface, shared by profile, live editor preview and preview sheet.
private struct AMProfileCard: View {
    let config: AMProfileConfig
    let theme: String
    let avatar: UIImage?
    let banner: UIImage?
    let trackCount: Int
    let favoritesCount: Int
    let playlistsCount: Int

    private var accent: Color { AMPalette.accent(config.accent) }
    private var textColor: Color { AMPalette.primary(theme) }
    private var muted: Color { AMPalette.secondary(theme) }
    private var centered: Bool { config.alignment == "center" }
    private var name: String {
        let trimmed = config.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Мій профіль" : trimmed
    }
    private var status: String { config.status.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var bio: String { config.bio.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasGenre: Bool { !config.genre.isEmpty && config.genre != "Не вказано" }

    var body: some View {
        VStack(spacing: 0) {
            cover
            VStack(alignment: centered ? .center : .leading, spacing: 0) {
                avatarRow
                    .padding(.top, -34)
                    .padding(.bottom, 15)
                identity
                if !bio.isEmpty {
                    Text(bio)
                        .font(.system(size: 13))
                        .foregroundStyle(muted)
                        .multilineTextAlignment(centered ? .center : .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 11)
                }
                if hasGenre {
                    Label(config.genre, systemImage: "music.note")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(accent.opacity(0.09), in: Capsule())
                        .padding(.top, 13)
                }
                if config.showStats {
                    Rectangle()
                        .fill(textColor.opacity(0.08))
                        .frame(height: 1)
                        .padding(.top, 19)
                        .padding(.bottom, 15)
                    HStack(spacing: 0) {
                        metric(trackCount, label: "Треки")
                        metric(favoritesCount, label: "Улюблені")
                        metric(playlistsCount, label: "Плейлисти")
                    }
                    .padding(.bottom, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            .padding(.horizontal, 19)
            .padding(.bottom, 21)
        }
        .frame(maxWidth: .infinity)
        .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .strokeBorder(textColor.opacity(0.055), lineWidth: 0.8)
        }
    }

    private var cover: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(theme == "light" ? Color(red: 0.91, green: 0.94, blue: 0.97)
                       : Color(red: 0.10, green: 0.15, blue: 0.20))
            if let banner {
                Image(uiImage: banner)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 130)
                    .clipped()
            } else if config.cover != "noir" {
                Circle()
                    .fill(accent.opacity(config.cover == "glow" ? 0.24 : 0.12))
                    .frame(width: 175, height: 175)
                    .blur(radius: 48)
                    .offset(x: 170, y: -77)
                Circle()
                    .strokeBorder(accent.opacity(0.12), lineWidth: 1)
                    .frame(width: 190, height: 190)
                    .offset(x: 205, y: -109)
            }
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .bold))
                Text("AMUSIC PROFILE")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.6)
            }
            .foregroundStyle(banner == nil ? muted : Color.white)
            .padding(.leading, 18)
            .padding(.top, 17)
        }
        .frame(height: 130)
        .clipped()
    }

    private var avatarRow: some View {
        AMFramedAvatar(image: avatar, theme: config.accent,
                       frameStyle: config.frameStyle, size: 86)
            .padding(4)
            .background(AMPalette.card(theme), in: Circle())
            .accessibilityLabel("Фото профілю")
    }

    private var identity: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(name)
                    .font(.system(size: 25, weight: .bold,
                                  design: AMProfileTypography.design(for: config.typography)))
                    .tracking(-0.45)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(centered ? .center : .leading)
                if config.badge != "none" {
                    Image(systemName: config.badge)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                        .accessibilityLabel("Значок профілю")
                }
            }
            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 13))
                    .foregroundStyle(muted)
                    .multilineTextAlignment(centered ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    private func metric(_ count: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(textColor)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
private struct AMProfilePreviewSheet: View {
    let config: AMProfileConfig
    let theme: String
    let avatar: UIImage?
    let banner: UIImage?
    let trackCount: Int
    let favoritesCount: Int
    let playlistsCount: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 17) {
                    HStack(spacing: 8) {
                        Image(systemName: "eye")
                            .foregroundStyle(AMPalette.accent(theme))
                        Text("Вигляд профілю без кнопок редагування")
                            .font(.system(size: 12))
                            .foregroundStyle(AMPalette.secondary(theme))
                    }
                    AMProfileCard(config: config, theme: theme, avatar: avatar,
                                  banner: banner, trackCount: trackCount,
                                  favoritesCount: favoritesCount,
                                  playlistsCount: playlistsCount)
                    Label("Це попередній перегляд на твоєму iPhone. AMusic поки не публікує профілі в інтернеті та не показує їх іншим користувачам.",
                          systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(AMPalette.secondary(theme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(19)
            }
            .background(AMPalette.background(theme))
            .navigationTitle("Попередній перегляд")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .foregroundStyle(AMPalette.primary(theme))
        .tint(AMPalette.accent(theme))
        .preferredColorScheme(theme == "light" ? .light : .dark)
    }
}

private struct AMProfileEditorView: View {
    let theme: String
    let avatar: UIImage?
    let banner: UIImage?
    let trackCount: Int
    let favoritesCount: Int
    let playlistsCount: Int
    let onAvatarSelected: (UIImage) -> Void
    let onBannerSelected: (UIImage) -> Void
    let onRemoveAvatar: () -> Void
    let onRemoveBanner: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("amusic.nickname") private var nickname = "Мій профіль"
    @AppStorage("amusic.profile.frame") private var avatarFrame = "minimal"
    @AppStorage("amusic.profile.status.v1") private var profileStatus = ""
    @AppStorage("amusic.profile.bio.v1") private var profileBio = ""
    @AppStorage("amusic.profile.genre.v1") private var profileGenre = "Не вказано"
    @AppStorage("amusic.profile.accent.v1") private var profileAccent = "orange"
    @AppStorage("amusic.profile.cover.v1") private var profileCover = "waves"
    @AppStorage("amusic.profile.alignment.v1") private var profileAlignment = "center"
    @AppStorage("amusic.profile.badge.v1") private var profileBadge = "none"
    @AppStorage("amusic.profile.typography.v1") private var profileTypography = "classic"
    @AppStorage("amusic.profile.showStats.v1") private var profileShowStats = true
    @State private var editorTab = 0
    @State private var previewExpanded = true
    @State private var chooseAvatar = false
    @State private var chooseBanner = false
    @State private var chooseFrame = false
    @State private var showPreview = false
    @State private var showResetConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var highlight: Color { AMPalette.accent(profileAccent) }
    private var config: AMProfileConfig {
        AMProfileConfig(nickname: nickname, status: profileStatus, bio: profileBio,
                        genre: profileGenre, accent: profileAccent, cover: profileCover,
                        alignment: profileAlignment, badge: profileBadge,
                        typography: profileTypography, showStats: profileShowStats,
                        frameStyle: avatarFrame)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PROFILE STUDIO")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(2)
                            .foregroundStyle(highlight)
                        Text("Твій стиль")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    Button { showPreview = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 39, height: 39)
                            .background(AMPalette.card(theme), in: Circle())
                    }
                    .accessibilityLabel("Відкрити повний перегляд")
                }
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                        previewExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Label("Попередній перегляд", systemImage: "eye")
                        Spacer()
                        Image(systemName: previewExpanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AMPalette.secondary(theme))
                }
                .buttonStyle(.plain)
                if previewExpanded {
                    AMProfileCard(config: config, theme: theme,
                                  avatar: avatar, banner: banner,
                                  trackCount: trackCount,
                                  favoritesCount: favoritesCount,
                                  playlistsCount: playlistsCount)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Picker("Розділ редактора", selection: $editorTab) {
                    Text("Основне").tag(0)
                    Text("Стиль").tag(1)
                    Text("Деталі").tag(2)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Розділи налаштувань профілю")
                Group {
                    switch editorTab {
                    case 0:
                        identitySection
                        photosSection
                    case 1:
                        presetSection
                        styleSection
                    default:
                        displaySection
                        extraSection
                    }
                }
                Button(role: .destructive) { showResetConfirmation = true } label: {
                    Label("Скинути оформлення", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(13)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AMPalette.secondary(theme))
            }
            .padding(19)
            .padding(.bottom, 45)
        }
        .background(AMProfileStyle.background(theme))
        .navigationTitle("Оформити профіль")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Назад") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Готово") { dismiss() }
                    .fontWeight(.semibold)
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .foregroundStyle(AMPalette.primary(theme))
        .tint(AMProfileStyle.blue)
        .preferredColorScheme(theme == "light" ? .light : .dark)
        .sheet(isPresented: $chooseAvatar) {
            AMAvatarPhotoPicker { image in onAvatarSelected(image) }
        }
        .sheet(isPresented: $chooseBanner) {
            AMAvatarPhotoPicker { image in onBannerSelected(image) }
        }
        .sheet(isPresented: $chooseFrame) {
            AMAvatarFramePicker(theme: theme, image: avatar, selection: $avatarFrame, accentStyle: profileAccent)
        }
        .sheet(isPresented: $showPreview) {
            AMProfilePreviewSheet(config: config, theme: theme,
                                  avatar: avatar, banner: banner,
                                  trackCount: trackCount,
                                  favoritesCount: favoritesCount,
                                  playlistsCount: playlistsCount)
        }
        .confirmationDialog("Скинути оформлення профілю?", isPresented: $showResetConfirmation,
                            titleVisibility: .visible) {
            Button("Скинути", role: .destructive) {
                profileAccent = "orange"
                profileCover = "waves"
                profileAlignment = "center"
                profileBadge = "none"
                profileTypography = "classic"
                profileShowStats = true
                avatarFrame = "minimal"
            }
            Button("Скасувати", role: .cancel) {}
        } message: {
            Text("Фото, шапка, нікнейм, статус, опис і музика залишаться без змін.")
        }
    }

    private var presetSection: some View {
        section("Готові образи", symbol: "square.stack.3d.up") {
            Text("Один дотик — і стиль готовий. Фото й опис не змінюються.")
                .font(.system(size: 12))
                .foregroundStyle(AMPalette.secondary(theme))
            HStack(spacing: 8) {
                preset("Noir", icon: "moon.stars", color: "ice", cover: "noir", font: "classic", frame: "minimal")
                preset("Neon", icon: "waveform", color: "violet", cover: "glow", font: "rounded", frame: "neon")
                preset("Gold", icon: "sparkles", color: "gold", cover: "waves", font: "serif", frame: "gold")
            }
        }
    }

    private func preset(_ title: String, icon: String, color: String, cover: String,
                        font: String, frame: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                profileAccent = color
                profileCover = cover
                profileTypography = font
                avatarFrame = frame
            }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(AMPalette.accent(color))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AMPalette.primary(theme))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 87)
            .background(AMPalette.elevated(theme), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(profileAccent == color ? AMPalette.accent(color) : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var extraSection: some View {
        section("Швидкі налаштування", symbol: "slider.horizontal.3") {
            inputTitle("Швидкий статус")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(["Музика — мій світ", "На своїй хвилі", "Слухаю серцем", "Just music", "Без статусу"], id: \.self) { value in
                        Button {
                            profileStatus = value == "Без статусу" ? "" : value
                        } label: {
                            Text(value)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AMPalette.primary(theme))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(AMPalette.elevated(theme), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            action("Налаштувати рамку аватара", icon: "circle.dotted.circle") {
                chooseFrame = true
            }
            action("Повний перегляд профілю", icon: "arrow.up.left.and.arrow.down.right") {
                showPreview = true
            }
            Text("Налаштування зберігаються автоматично тільки на цьому пристрої.")
                .font(.system(size: 11))
                .foregroundStyle(AMPalette.secondary(theme))
        }
    }

    private var identitySection: some View {
        section("Інформація про тебе", symbol: "person.text.rectangle") {
            VStack(alignment: .leading, spacing: 11) {
                inputTitle("Нікнейм · \(nickname.count)/32")
                TextField("Ім'я профілю", text: $nickname)
                    .textInputAutocapitalization(.words)
                    .modifier(AMProfileInput(theme: theme))
                    .onChange(of: nickname) { _, value in
                        if value.count > 32 { nickname = String(value.prefix(32)) }
                    }
                inputTitle("Короткий статус · \(profileStatus.count)/55")
                TextField("Наприклад: Музика щодня", text: $profileStatus)
                    .modifier(AMProfileInput(theme: theme))
                    .onChange(of: profileStatus) { _, value in
                        if value.count > 55 { profileStatus = String(value.prefix(55)) }
                    }
                inputTitle("Про себе · \(profileBio.count)/180")
                TextField("Розкажи про свою музику...", text: $profileBio, axis: .vertical)
                    .lineLimit(3...6)
                    .modifier(AMProfileInput(theme: theme))
                    .onChange(of: profileBio) { _, value in
                        if value.count > 180 { profileBio = String(value.prefix(180)) }
                    }
                Picker("Улюблений жанр", selection: $profileGenre) {
                    ForEach(["Не вказано", "Поп", "Рок", "Хіп-хоп", "Електронна",
                             "Класична", "Джаз", "Інді", "Метал", "Lo-fi", "R&B", "Фонк", "Інше"], id: \.self) { genre in
                        Text(genre).tag(genre)
                    }
                }
                .font(.body)
            }
        }
    }

    private var photosSection: some View {
        section("Фото та шапка", symbol: "photo.on.rectangle") {
            VStack(spacing: 10) {
                action("Змінити аватарку", icon: "person.crop.circle") { chooseAvatar = true }
                action("Змінити шапку", icon: "photo") { chooseBanner = true }
                action("Рамка аватарки", icon: "circle.dotted.circle") { chooseFrame = true }
                if avatar != nil {
                    action("Прибрати аватарку", icon: "xmark.circle", destructive: true) {
                        onRemoveAvatar()
                    }
                }
                if banner != nil {
                    action("Прибрати шапку", icon: "xmark.circle", destructive: true) {
                        onRemoveBanner()
                    }
                }
            }
        }
    }

    private var styleSection: some View {
        section("Оформлення профілю", symbol: "paintpalette") {
            VStack(alignment: .leading, spacing: 13) {
                inputTitle("Акцентний колір")
                HStack(spacing: 12) {
                    ForEach(["orange", "violet", "ice", "mint", "rose", "gold"], id: \.self) { id in
                        Button {
                            withAnimation(reduceMotion ? nil : AMMotion.selection) {
                                profileAccent = id
                            }
                        } label: {
                            Circle()
                                .fill(AMPalette.accent(id))
                                .frame(width: 30, height: 30)
                                .padding(4)
                                .overlay {
                                    Circle()
                                        .strokeBorder(profileAccent == id
                                                      ? AMPalette.primary(theme) : .clear,
                                                      lineWidth: 2)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Колір \(id)")
                        .accessibilityAddTraits(profileAccent == id ? .isSelected : [])
                    }
                }
                inputTitle("Стиль шапки без фото")
                Picker("Стиль шапки", selection: $profileCover) {
                    Text("Спокійний").tag("waves")
                    Text("Акцент").tag("glow")
                    Text("Без тла").tag("noir")
                }
                .pickerStyle(.segmented)
                inputTitle("Розташування")
                Picker("Розташування", selection: $profileAlignment) {
                    Text("Ліворуч").tag("left")
                    Text("По центру").tag("center")
                }
                .pickerStyle(.segmented)
                inputTitle("Шрифт нікнейму")
                HStack(spacing: 12) {
                    Text("Мій профіль")
                        .font(.system(size: 20, weight: .semibold,
                                      design: AMProfileTypography.design(for: profileTypography)))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Picker("Шрифт нікнейму", selection: $profileTypography) {
                        Text("Класичний").tag("classic")
                        Text("Плавний").tag("rounded")
                        Text("Редакційний").tag("serif")
                        Text("Моно").tag("mono")
                    }
                    .pickerStyle(.menu)
                }
                Picker("Значок біля нікнейму", selection: $profileBadge) {
                    Text("Без значка").tag("none")
                    Label("Навушники", systemImage: "headphones").tag("headphones")
                    Label("Музика", systemImage: "music.note").tag("music.note")
                    Label("Зірка", systemImage: "star.fill").tag("star.fill")
                    Label("Хвиля", systemImage: "waveform").tag("waveform")
                }
                .font(.body)
            }
        }
    }

    private var displaySection: some View {
        section("Відображення", symbol: "eye") {
            Toggle("Показувати статистику музики", isOn: $profileShowStats)
                .font(.body)
            Text("Кількість треків, улюблених і плейлистів під описом профілю.")
                .font(.system(size: 11))
                .foregroundStyle(AMPalette.secondary(theme))
        }
    }

    private func section<Content: View>(_ title: String, symbol: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(AMPalette.secondary(theme))
                .padding(.leading, 16)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private func inputTitle(_ title: String) -> some View {
        Text(title)
            .font(.footnote)
            .foregroundStyle(AMPalette.secondary(theme))
    }

    private func action(_ title: String, icon: String, destructive: Bool = false,
                        run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack {
                Image(systemName: icon).frame(width: 25)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10))
            }
            .font(.body)
            .foregroundStyle(destructive ? Color.red : AMPalette.primary(theme))
            .padding(12)
            .background(AMPalette.elevated(theme), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(AMPressStyle())
    }
}

private struct AMProfileInput: ViewModifier {
    let theme: String
    func body(content: Content) -> some View {
        content
            .font(.body)
            .padding(12)
            .background(AMPalette.elevated(theme), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Profile frame styles (stored in existing UserDefaults key)
private enum AMAvatarFrameCatalog {
    static let styles = ["none", "minimal", "neon", "double", "gold",
                         "titanium", "glass", "orbit", "dashed", "prism"]

    static func title(_ style: String) -> String {
        switch style {
        case "none": return "Без рамки"
        case "minimal": return "Класична"
        case "neon": return "Неон"
        case "double": return "Подвійна"
        case "gold": return "Золота"
        case "titanium": return "Титан"
        case "glass": return "Скло"
        case "orbit": return "Орбіта"
        case "dashed": return "Пунктир"
        case "prism": return "Призма"
        default: return "Класична"
        }
    }
}

private struct AMFramedAvatar: View {
    let image: UIImage?
    let theme: String
    let frameStyle: String
    let size: CGFloat

    private var accent: Color { AMPalette.accent(theme) }

    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.065))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(accent)
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            switch frameStyle {
            case "minimal":
                Circle().strokeBorder(accent, lineWidth: max(2, size * 0.028))
            case "neon":
                Circle().strokeBorder(
                    LinearGradient(colors: [accent, .white, accent.opacity(0.65)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: max(3, size * 0.05))
            case "double":
                Circle().strokeBorder(accent, lineWidth: max(2, size * 0.027))
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.85), lineWidth: max(1, size * 0.013))
                            .padding(max(5, size * 0.09))
                    }
            case "gold":
                Circle().strokeBorder(
                    LinearGradient(colors: [Color(red: 1, green: 0.9, blue: 0.58),
                                            Color(red: 0.70, green: 0.40, blue: 0.1),
                                            Color(red: 1, green: 0.84, blue: 0.48)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: max(3, size * 0.05))
            case "titanium":
                Circle().strokeBorder(
                    LinearGradient(colors: [Color(white: 0.92), Color(white: 0.42),
                                            Color(white: 0.78)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: max(2.5, size * 0.039))
            case "glass":
                Circle().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.95), accent.opacity(0.32),
                                            .white.opacity(0.5)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: max(2.5, size * 0.041))
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.36), lineWidth: 1)
                            .padding(max(4, size * 0.067))
                    }
            case "orbit":
                Circle().strokeBorder(accent.opacity(0.68), lineWidth: max(1.5, size * 0.021))
                    .padding(max(1, size * 0.02))
                    .overlay {
                        Circle().trim(from: 0.06, to: 0.46)
                            .stroke(accent, style: StrokeStyle(lineWidth: max(2.5, size * 0.045),
                                                                lineCap: .round))
                            .rotationEffect(.degrees(-46))
                    }
            case "dashed":
                Circle().strokeBorder(accent, style: StrokeStyle(
                    lineWidth: max(2, size * 0.03), lineCap: .round,
                    dash: [max(2, size * 0.058), max(2, size * 0.048)]))
            case "prism":
                Circle().strokeBorder(
                    AngularGradient(colors: [accent, .purple, .cyan, .mint, accent],
                                    center: .center),
                    lineWidth: max(3, size * 0.05))
            default:
                EmptyView()
            }
        }
        .shadow(color: frameStyle == "neon" ? accent.opacity(0.5) : .clear,
                radius: size * 0.13)
    }
}

private struct AMAvatarFramePicker: View {
    let theme: String
    let image: UIImage?
    @Binding var selection: String
    var accentStyle: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    Text("Обери стиль аватарки")
                        .font(.system(size: 14))
                        .foregroundStyle(AMPalette.secondary(theme))
                    AMFramedAvatar(image: image, theme: accentStyle ?? theme, frameStyle: selection, size: 104)
                        .padding(.vertical, 10)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(AMAvatarFrameCatalog.styles, id: \.self) { style in
                            Button {
                                selection = style
                                UISelectionFeedbackGenerator().selectionChanged()
                            } label: {
                                VStack(spacing: 13) {
                                    AMFramedAvatar(image: image, theme: accentStyle ?? theme, frameStyle: style, size: 66)
                                    HStack(spacing: 7) {
                                        Text(AMAvatarFrameCatalog.title(style))
                                        if selection == style {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(AMPalette.accent(accentStyle ?? theme))
                                        }
                                    }
                                    .font(.system(size: 12, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(AMPalette.card(theme), in: RoundedRectangle(cornerRadius: 17))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 17)
                                        .strokeBorder(selection == style ? AMPalette.accent(accentStyle ?? theme) : .clear,
                                                      lineWidth: 1.5)
                                }
                            }
                            .buttonStyle(AMPressStyle())
                        }
                    }
                }
                .padding(18)
            }
            .background(AMPalette.background(theme))
            .navigationTitle("Рамка аватарки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .foregroundStyle(AMPalette.primary(theme))
        .tint(AMPalette.accent(accentStyle ?? theme))
        .preferredColorScheme(theme == "light" ? .light : .dark)
    }
}


// MARK: - Server-authorized Community moderation
private struct AMAdminCommunityTrack: Decodable, Identifiable {
    let id: UUID
    let owner_id: UUID
    let title: String
    let artist: String
    let audio_path: String
    let created_at: String
}

private struct AMAdminCommunityResponse: Decodable {
    let tracks: [AMAdminCommunityTrack]
}

@MainActor
private struct AMCommunityAdminView: View {
    @ObservedObject var cloud: AMCloudAuthStore
    let theme: String
    @State private var tracks: [AMAdminCommunityTrack] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var chosen: AMAdminCommunityTrack?
    @State private var search = ""
    private let endpoint = URL(string: "https://pnlmxtsvmlyaywbgzhht.supabase.co/functions/v1/amusic-community-admin")!
    private let publishable = "sb_publishable_-weL94RHO6GwLlBAT5TKgw_Cc1k6tA0"
    private var visibleTracks: [AMAdminCommunityTrack] {
        tracks.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.artist.localizedCaseInsensitiveContains(search) }
    }
    private func request(method: String, id: UUID? = nil) async throws -> Data {
        guard let token = cloud.currentCommunityAccessToken else {
            throw NSError(domain: "AMusicAdmin", code: 401, userInfo: [NSLocalizedDescriptionKey: "Спочатку увійди в акаунт AMusic Cloud у профілі."])
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = method
        req.setValue(publishable, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let id {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["track_id": id.uuidString.lowercased()])
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            var reason = "Сервер відмовив у доступі (HTTP \(response.statusCode))"
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = object["error"] as? String { reason = message }
            throw NSError(domain: "AMusicAdmin", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        return data
    }
    private func reload() async {
        guard !loading else { return }
        loading = true; errorText = nil
        defer { loading = false }
        do {
            let data = try await request(method: "GET")
            tracks = try JSONDecoder().decode(AMAdminCommunityResponse.self, from: data).tracks
        } catch { errorText = error.localizedDescription }
    }
    private func remove(_ track: AMAdminCommunityTrack) async {
        guard !loading else { return }
        loading = true; errorText = nil
        defer { loading = false }
        do {
            _ = try await request(method: "POST", id: track.id)
            tracks.removeAll { $0.id == track.id }
        } catch { errorText = error.localizedDescription }
    }
    var body: some View {
        List {
            Section {
                Text("Композиції всіх авторів. Видалення прибирає запис і його аудіофайл із хмари та не скасовує вже завантажені локальні копії.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("Пошук композиції", text: $search)
                    .textInputAutocapitalization(.never)
                Button("Оновити список", systemImage: "arrow.clockwise") { Task { await reload() } }
                    .disabled(loading)
            }
            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
            Section("Композиції (\(visibleTracks.count))") {
                ForEach(visibleTracks) { track in
                    HStack(spacing: 10) {
                        Image(systemName: "music.note").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).font(.subheadline.weight(.semibold))
                            Text(track.artist).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { chosen = track } label: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                        .disabled(loading)
                    }
                }
            }
        }
        .navigationTitle("Модерація Community")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading { ProgressView().controlSize(.large) } }
        .task { await reload() }
        .confirmationDialog("Видалити композицію з Community?", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } })) {
            Button("Видалити назавжди", role: .destructive) {
                guard let track = chosen else { return }
                chosen = nil
                Task { await remove(track) }
            }
            Button("Скасувати", role: .cancel) { chosen = nil }
        } message: {
            Text("Файл буде видалено з Supabase Storage для всіх користувачів. Цю дію неможливо скасувати.")
        }
    }
}

// MARK: - Live developer controls (no runtime code execution)

private struct AMDeveloperToolsView: View {
    @ObservedObject var music: MusicStore
    @ObservedObject var cloud: AMCloudAuthStore
    let theme: String
    let notesCount: Int
    let photosCount: Int

    @AppStorage("amusic.theme") private var selectedTheme = "orange"
    @AppStorage("amusic.profile.frame") private var avatarFrame = "minimal"
    @AppStorage("amusic.nickname") private var nickname = "Мій профіль"
    @AppStorage("amusic.dev.brand") private var brand = "AMusic"
    @AppStorage("amusic.dev.showYouTube") private var showYouTube = true
    @AppStorage("amusic.dev.compactRows") private var compactRows = false
    @AppStorage("amusic.dev.reduceMotion") private var reduceMotion = false
    @AppStorage("amusic.dev.showBadge") private var showBadge = false
    @State private var showResetConfirmation = false
    @State private var playlistDraft = ""

    private var accent: Color { AMPalette.accent(selectedTheme) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 17) {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(.green)
                        .frame(width: 59, height: 59)
                        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AMusic Studio")
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                        Text("Керування застосунком у реальному часі")
                            .font(.system(size: 11))
                            .foregroundStyle(AMPalette.secondary(selectedTheme))
                    }
                }
                .padding(.bottom, 5)

                HStack(spacing: 9) {
                    metric("\(music.tracks.count)", "Треки")
                    metric("\(music.playlists.count)", "Плейлисти")
                    metric("\(photosCount)", "Фото")
                    metric("\(notesCount)", "Нотатки")
                }

                section(title: "ОФОРМЛЕННЯ", symbol: "paintpalette") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Нікнейм профілю", text: $nickname)
                            .padding(12)
                            .background(AMPalette.elevated(selectedTheme),
                                        in: RoundedRectangle(cornerRadius: 11))
                            .onChange(of: nickname) { _, new in
                                if new.count > 32 { nickname = String(new.prefix(32)) }
                            }
                        TextField("Назва у верхньому меню", text: $brand)
                            .textInputAutocapitalization(.words)
                            .padding(12)
                            .background(AMPalette.elevated(selectedTheme),
                                        in: RoundedRectangle(cornerRadius: 11))
                            .onChange(of: brand) { _, new in
                                if new.count > 18 { brand = String(new.prefix(18)) }
                            }
                        HStack {
                            Text("Колір застосунку")
                            Spacer()
                            Picker("Тема", selection: $selectedTheme) {
                                Text("Помаранчева").tag("orange")
                                Text("Фіолетова").tag("violet")
                                Text("Блакитна").tag("ice")
                                Text("М'ятна").tag("mint")
                                Text("Рожева").tag("rose")
                                Text("Золота").tag("gold")
                                Text("Світла").tag("light")
                            }
                            .pickerStyle(.menu)
                        }
                        HStack {
                            Text("Рамка аватарки")
                            Spacer()
                            Picker("Рамка", selection: $avatarFrame) {
                                ForEach(AMAvatarFrameCatalog.styles, id: \.self) { style in
                                    Text(AMAvatarFrameCatalog.title(style)).tag(style)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        Toggle("Компактні рядки музики", isOn: $compactRows)
                        Toggle("Менше анімацій", isOn: $reduceMotion)
                        Toggle("Значок DEV біля назви", isOn: $showBadge)
                    }
                }

                section(title: "НАВІГАЦІЯ", symbol: "rectangle.3.group") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Показувати YouTube", isOn: $showYouTube)
                        Text("Приховування YouTube не впливає на локальну музику.")
                            .font(.system(size: 11))
                            .foregroundStyle(AMPalette.secondary(selectedTheme))
                    }
                }

                section(title: "БІБЛІОТЕКА", symbol: "square.stack") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            TextField("Назва нового плейлиста", text: $playlistDraft)
                                .padding(12)
                                .background(AMPalette.elevated(selectedTheme),
                                            in: RoundedRectangle(cornerRadius: 11))
                            Button {
                                if music.createPlaylist(playlistDraft) {
                                    playlistDraft = ""
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.black)
                                    .frame(width: 42, height: 42)
                                    .background(accent, in: RoundedRectangle(cornerRadius: 11))
                            }
                            .disabled(playlistDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Text("Редагування назви й обкладинки кожної пісні доступне в бібліотеці через •••.")
                            .font(.system(size: 11))
                            .foregroundStyle(AMPalette.secondary(selectedTheme))
                    }
                }

                section(title: "ПЛЕЄР", symbol: "slider.horizontal.3") {
                    VStack(spacing: 13) {
                        HStack {
                            Text("Гучність AMusic")
                            Spacer()
                            Text("\(Int(music.volume * 100))%")
                                .foregroundStyle(AMPalette.secondary(selectedTheme))
                        }
                        Slider(value: Binding(
                            get: { Double(music.volume) },
                            set: { music.updateVolume($0) }
                        ), in: 0...1)
                        HStack {
                            Text("Швидкість")
                            Spacer()
                            Picker("Швидкість", selection: Binding(
                                get: { music.rate },
                                set: { music.updateRate($0) }
                            )) {
                                Text("0.75×").tag(Float(0.75))
                                Text("1×").tag(Float(1))
                                Text("1.25×").tag(Float(1.25))
                                Text("1.5×").tag(Float(1.5))
                            }
                            .pickerStyle(.menu)
                        }
                        Toggle("Перемішування", isOn: Binding(
                            get: { music.shuffleEnabled },
                            set: { music.updateShuffle($0) }
                        ))
                        Toggle("Повтор треку", isOn: Binding(
                            get: { music.repeatTrack },
                            set: { music.updateRepeat($0) }
                        ))
                        HStack(spacing: 10) {
                            playerAction("backward.end.fill") { if music.current != nil { music.previous() } }
                            playerAction(music.isPlaying ? "pause.fill" : "play.fill") {
                                if music.isPlaying { music.pause() }
                                else if music.current != nil { music.resume() }
                            }
                            playerAction("forward.end.fill") { if music.current != nil { music.next() } }
                        }
                        .disabled(music.current == nil)
                        if let current = music.current {
                            Text("Зараз: \(current.title)")
                                .font(.system(size: 11))
                                .foregroundStyle(AMPalette.secondary(selectedTheme))
                                .lineLimit(1)
                        }
                        Button(role: .destructive) { music.clearQueue() } label: {
                            Label("Очистити чергу відтворення", systemImage: "trash")
                        }
                        .disabled(music.upcomingIDs.isEmpty)
                    }
                }

                section(title: "КЕРУВАННЯ COMMUNITY", symbol: "shield.lefthalf.filled") {
                    NavigationLink {
                        AMCommunityAdminView(cloud: cloud, theme: selectedTheme)
                    } label: {
                        Label("Керування музикою для всіх", systemImage: "music.note.list")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(13)
                            .background(AMPalette.elevated(selectedTheme), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    Text("Видалення чужих композицій доступне лише авторизованому адміністратору Supabase. Код Мого простору сам по собі не надає прав.")
                        .font(.system(size: 11))
                        .foregroundStyle(AMPalette.secondary(selectedTheme))
                }

                section(title: "ДІАГНОСТИКА", symbol: "waveform.path.ecg") {
                    VStack(alignment: .leading, spacing: 12) {
                        diagnostic("Статус плеєра", music.isPlaying ? "Відтворює" : "На паузі")
                        diagnostic("Черга", "\(music.upcomingIDs.count) композицій")
                        diagnostic("Обране", "\(music.favoriteIDs.count)")
                        diagnostic("Версія iOS", UIDevice.current.systemVersion)
                        diagnostic("Версія AMusic", AMRelease.version)
                        diagnostic("Версія пакета",
                                   Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Локальна збірка")
                        Text("Ці інструменти змінюють параметри, які вже підтримує AMusic. Додавання нових функцій і зміна Swift-коду потребують збірки нового IPA.")
                            .font(.system(size: 11))
                            .foregroundStyle(AMPalette.secondary(selectedTheme))
                    }
                }

                Button(role: .destructive) { showResetConfirmation = true } label: {
                    Label("Скинути налаштування розробника", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(15)
                        .background(AMPalette.card(selectedTheme),
                                    in: RoundedRectangle(cornerRadius: 14))
                }
                Text("Скидання не видаляє музику, фотографії чи нотатки.")
                    .font(.system(size: 11))
                    .foregroundStyle(AMPalette.secondary(selectedTheme))
            }
            .font(.system(size: 13))
            .padding(19)
        }
        .background(AMPalette.background(selectedTheme))
        .navigationTitle("Режим розробника")
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(AMPalette.primary(selectedTheme))
        .tint(accent)
        .preferredColorScheme(selectedTheme == "light" ? .light : .dark)
        .confirmationDialog("Скинути налаштування?", isPresented: $showResetConfirmation) {
            Button("Скинути оформлення й меню", role: .destructive) {
                brand = "AMusic"
                selectedTheme = "orange"
                avatarFrame = "minimal"
                showYouTube = true
                compactRows = false
                reduceMotion = false
                showBadge = false
            }
            Button("Скасувати", role: .cancel) {}
        } message: {
            Text("Налаштування звуку, музика, фото та нотатки залишаться.")
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(AMPalette.secondary(selectedTheme))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(AMPalette.card(selectedTheme), in: RoundedRectangle(cornerRadius: 13))
    }

    private func section<Content: View>(title: String, symbol: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(accent)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AMPalette.card(selectedTheme), in: RoundedRectangle(cornerRadius: 18))
    }

    private func playerAction(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 43)
                .background(AMPalette.elevated(selectedTheme),
                            in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(AMPressStyle())
    }

    private func diagnostic(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(AMPalette.secondary(selectedTheme))
            Spacer(minLength: 8)
            Text(value).fontWeight(.semibold).lineLimit(1)
        }
    }
}

private struct AMPrivateNotesView: View {
    @ObservedObject var store: AMPrivateSpaceStore
    let theme: String
    @State private var editingNote: AMPrivateNote?
    @State private var deleteNote: AMPrivateNote?
    private var accent: Color { AMPalette.accent(theme) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                if store.notes.isEmpty {
                    ContentUnavailableView("Нотаток ще немає", systemImage: "square.and.pencil",
                        description: Text("Натисни +, щоб створити першу нотатку."))
                        .padding(.top, 55)
                } else {
                    ForEach(store.notes) { note in
                        Button { editingNote = note } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(note.title.isEmpty ? "Без назви" : note.title)
                                        .font(.system(size: 16, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12))
                                        .foregroundStyle(AMPalette.secondary(theme))
                                }
                                Text(note.body.isEmpty ? "Порожня нотатка" : note.body)
                                    .font(.system(size: 13))
                                    .foregroundStyle(AMPalette.secondary(theme))
                                    .lineLimit(2)
                                Text(note.modifiedAt, style: .date)
                                    .font(.system(size: 11))
                                    .foregroundStyle(AMPalette.secondary(theme))
                            }
                            .padding(17)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AMPalette.card(theme))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(AMPressStyle())
                        .contextMenu {
                            Button(role: .destructive) { deleteNote = note } label: {
                                Label("Видалити", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(19)
        }
        .background(AMPalette.background(theme))
        .navigationTitle("Нотатки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editingNote = AMPrivateNote(title: "", body: "") } label: {
                    Image(systemName: "plus")
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(item: $editingNote) { note in
            AMPrivateNoteEditor(note: note, theme: theme, onSave: { store.save($0) })
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Видалити нотатку?", isPresented: Binding(
            get: { deleteNote != nil }, set: { if !$0 { deleteNote = nil } }
        ), titleVisibility: .visible) {
            Button("Видалити", role: .destructive) {
                if let deleteNote { store.delete(deleteNote) }
                deleteNote = nil
            }
            Button("Скасувати", role: .cancel) { deleteNote = nil }
        }
        .tint(accent)
    }
}

private struct AMPrivateNoteEditor: View {
    let note: AMPrivateNote
    let theme: String
    let onSave: (AMPrivateNote) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var bodyText: String

    init(note: AMPrivateNote, theme: String, onSave: @escaping (AMPrivateNote) -> Void) {
        self.note = note
        self.theme = theme
        self.onSave = onSave
        _title = State(initialValue: note.title)
        _bodyText = State(initialValue: note.body)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Назва нотатки", text: $title)
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .padding(14)
                    .background(AMPalette.card(theme))
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                TextEditor(text: $bodyText)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AMPalette.card(theme))
                    .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            .padding(18)
            .background(AMPalette.background(theme))
            .navigationTitle("Нотатка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Скасувати") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Зберегти") {
                        var edited = note
                        edited.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
                        edited.body = bodyText
                        onSave(edited)
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
            .tint(AMPalette.accent(theme))
            .foregroundStyle(AMPalette.primary(theme))
        }
        .preferredColorScheme(theme == "light" ? .light : .dark)
    }
}

private struct AMPrivatePhotosView: View {
    @ObservedObject var store: AMPrivateSpaceStore
    let theme: String
    @State private var showPhotoPicker = false
    @State private var openedPhoto: AMPrivatePhoto?
    @State private var deletePhoto: AMPrivatePhoto?
    private var accent: Color { AMPalette.accent(theme) }
    private let grid = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4),
                        GridItem(.flexible(), spacing: 4)]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 17) {
                Button { showPhotoPicker = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                        Text("Додати фотографії")
                        Spacer()
                        if store.isImporting { ProgressView().tint(.black) }
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(16)
                    .background(accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(store.isImporting)

                if store.photos.isEmpty {
                    ContentUnavailableView("Поки немає фото", systemImage: "photo.on.rectangle",
                        description: Text("Додай будь-які фотографії з галереї iPhone."))
                        .padding(.top, 32)
                } else {
                    LazyVGrid(columns: grid, spacing: 4) {
                        ForEach(store.photos) { photo in
                            Button { openedPhoto = photo } label: {
                                AMPrivatePhotoThumbnail(url: store.photoURL(photo))
                                    .aspectRatio(1, contentMode: .fill)
                                    .frame(maxWidth: .infinity)
                                    .clipped()
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { deletePhoto = photo } label: {
                                    Label("Видалити фото", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                Text("\(store.photos.count) фото · зберігаються в AMusic")
                    .font(.system(size: 11))
                    .foregroundStyle(AMPalette.secondary(theme))
            }
            .padding(17)
        }
        .background(AMPalette.background(theme))
        .navigationTitle("Фото")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPhotoPicker) {
            AMPrivateMultiPhotoPicker(onImageData: { data in
                // All UI/store work runs on the main actor.
                guard let image = UIImage(data: data) else { return }
                store.importPhoto(image)
            }, onDone: {
                showPhotoPicker = false
            })
        }
        .sheet(item: $openedPhoto) { photo in
            AMPrivatePhotoPreview(store: store, photo: photo, theme: theme)
        }
        .confirmationDialog("Видалити фото?", isPresented: Binding(
            get: { deletePhoto != nil }, set: { if !$0 { deletePhoto = nil } }
        ), titleVisibility: .visible) {
            Button("Видалити", role: .destructive) {
                if let deletePhoto { store.delete(deletePhoto) }
                deletePhoto = nil
            }
            Button("Скасувати", role: .cancel) { deletePhoto = nil }
        }
        .tint(accent)
    }
}


// Native PHPicker supports selecting multiple images from the iPhone Photos app.
// The same UIKit picker API is already used above for custom track art and avatar.
// Use Sendable image bytes to cross from NSItemProvider's worker thread
// back to the main actor. Passing UIImage / a plain closure across this
// boundary fails Swift 6 strict concurrency checks.
private struct AMPrivateMultiPhotoPicker: UIViewControllerRepresentable {
    let onImageData: @MainActor @Sendable (Data) -> Void
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 0 // Multiple selection.
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImageData: onImageData, onDone: onDone)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onImageData: @MainActor @Sendable (Data) -> Void
        let onDone: () -> Void

        init(onImageData: @escaping @MainActor @Sendable (Data) -> Void,
             onDone: @escaping () -> Void) {
            self.onImageData = onImageData
            self.onDone = onDone
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onDone()
            // A separate Sendable callback survives picker dismissal.
            let callback = onImageData
            for result in results {
                let provider = result.itemProvider
                guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    guard let image = object as? UIImage,
                          let data = image.jpegData(compressionQuality: 0.97) else { return }
                    // Data is Sendable; UIKit image creation runs on main.
                    DispatchQueue.main.async {
                        callback(data)
                    }
                }
            }
        }
    }
}

private struct AMPrivatePhotoThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.13)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: url) {
            image = UIImage(contentsOfFile: url.path)
        }
    }
}

private struct AMPrivatePhotoPreview: View {
    @ObservedObject var store: AMPrivateSpaceStore
    let photo: AMPrivatePhoto
    let theme: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                if let image = UIImage(contentsOfFile: store.photoURL(photo).path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    ContentUnavailableView("Фото не знайдено", systemImage: "photo")
                }
            }
            .background(Color.black)
            .navigationTitle("Фото")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Готово") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .confirmationDialog("Видалити фото?", isPresented: $confirmDelete) {
                Button("Видалити", role: .destructive) {
                    store.delete(photo)
                    dismiss()
                }
                Button("Скасувати", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
    }
}

import SwiftUI
import Foundation
import Security

// AMusic Cloud authentication. Existing local library is deliberately unaffected.
private enum AMCloudConfig {
    static let baseURL = URL(string: "https://pnlmxtsvmlyaywbgzhht.supabase.co")!
    static let publishableKey = "sb_publishable_-weL94RHO6GwLlBAT5TKgw_Cc1k6tA0"
    static let keychainService = "com.amusic.cloud.auth.v1"
}

private struct AMCloudAuthResponse: Decodable {
    struct User: Decodable { let id: UUID; let email: String? }
    let access_token: String?
    let refresh_token: String?
    let expires_in: Int?
    let user: User?
}

private struct AMCloudCredentials: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userID: UUID
    let email: String
}

private struct AMCloudAPIError: Decodable {
    let msg: String?
    let message: String?
    let error_description: String?
    let error: String?
}

@MainActor
final class AMCloudAuthStore: ObservableObject {
    @Published private(set) var email = ""
    @Published private(set) var userID: UUID?
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    private var credentials: AMCloudCredentials?

    init() {
        restoreLocalSession()
    }

    var isSignedIn: Bool { credentials != nil }
    var currentCommunityAccessToken: String? { credentials?.accessToken }

    private func restoreLocalSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AMCloudConfig.keychainService,
            kSecAttrAccount as String: "session",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let saved = try? JSONDecoder().decode(AMCloudCredentials.self, from: data) {
            credentials = saved
            email = saved.email
            userID = saved.userID
        }
    }

    private func save(_ session: AMCloudCredentials) throws {
        let bytes = try JSONEncoder().encode(session)
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AMCloudConfig.keychainService,
            kSecAttrAccount as String: "session"
        ]
        SecItemDelete(key as CFDictionary)
        var insert = key
        insert[kSecValueData as String] = bytes
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            throw NSError(domain: "AMusicCloud", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Не вдалося безпечно зберегти сесію."])
        }
        credentials = session
        email = session.email
        userID = session.userID
    }

    private func request(path: String, method: String = "POST", payload: [String: String], token: String? = nil) async throws -> AMCloudAuthResponse {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var components = URLComponents(url: AMCloudConfig.baseURL.appending(path: "auth/v1/\(parts[0])"), resolvingAgainstBaseURL: false)!
        if parts.count == 2 { components.percentEncodedQuery = String(parts[1]) }
        guard let url = components.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(AMCloudConfig.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let api = try? JSONDecoder().decode(AMCloudAPIError.self, from: data)
            let detail = api?.msg ?? api?.message ?? api?.error_description ?? api?.error
            throw NSError(domain: "AMusicCloud", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: detail ?? "Помилка авторизації (\(http.statusCode))."])
        }
        return try JSONDecoder().decode(AMCloudAuthResponse.self, from: data)
    }

    func signUp(email inputEmail: String, password: String) async {
        await perform {
            let normalized = inputEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let result = try await request(path: "signup", payload: ["email": normalized, "password": password])
            if let access = result.access_token,
               let refresh = result.refresh_token,
               let user = result.user {
                try save(AMCloudCredentials(accessToken: access, refreshToken: refresh,
                                            expiresAt: Date().addingTimeInterval(TimeInterval(result.expires_in ?? 3600)),
                                            userID: user.id, email: user.email ?? normalized))
                infoMessage = "Акаунт створено. Локальна музика залишилася на пристрої."
            } else {
                infoMessage = "Перевір пошту та підтвердь реєстрацію, потім увійди в акаунт."
            }
        }
    }

    func signIn(email inputEmail: String, password: String) async {
        await perform {
            let normalized = inputEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let result = try await request(path: "token?grant_type=password", payload: ["email": normalized, "password": password])
            guard let access = result.access_token, let refresh = result.refresh_token, let user = result.user else {
                throw NSError(domain: "AMusicCloud", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Сервер не повернув повну сесію."])
            }
            try save(AMCloudCredentials(accessToken: access, refreshToken: refresh,
                                        expiresAt: Date().addingTimeInterval(TimeInterval(result.expires_in ?? 3600)),
                                        userID: user.id, email: user.email ?? normalized))
            infoMessage = "Вхід успішний. Твоя локальна музика не змінена."
        }
    }

    func refreshSessionIfNeeded() async {
        guard let old = credentials, old.expiresAt <= Date().addingTimeInterval(120) else { return }
        do {
            let result = try await request(path: "token?grant_type=refresh_token", payload: ["refresh_token": old.refreshToken])
            guard let token = result.access_token, let refresh = result.refresh_token else { return }
            try save(AMCloudCredentials(accessToken: token, refreshToken: refresh,
                                        expiresAt: Date().addingTimeInterval(TimeInterval(result.expires_in ?? 3600)),
                                        userID: result.user?.id ?? old.userID,
                                        email: result.user?.email ?? old.email))
        } catch {
            errorMessage = "Не вдалося оновити сесію: \(error.localizedDescription)"
        }
    }

    func signOut() async {
        // Local media is not linked to the login state and is NEVER deleted on logout.
        if let access = credentials?.accessToken {
            _ = try? await request(path: "logout", payload: [:], token: access)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AMCloudConfig.keychainService,
            kSecAttrAccount as String: "session"
        ]
        SecItemDelete(query as CFDictionary)
        credentials = nil
        userID = nil
        email = ""
        infoMessage = "Вихід виконано. Локальна музика та плейлисти збережені."
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        infoMessage = nil
        defer { isBusy = false }
        do { try await operation() }
        catch { errorMessage = error.localizedDescription }
    }
}

struct AMCloudAccountScreen: View {
    @ObservedObject var cloud: AMCloudAuthStore
    @Environment(\.dismiss) private var dismiss
    @State private var registering = false
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showPassword = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(Color(red: 0.22, green: 0.62, blue: 0.95))
                    Text("AMusic Cloud")
                        .font(.largeTitle.bold())
                    if cloud.isSignedIn {
                        Label("Підключено", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(cloud.email).font(.headline)
                        Text("Твоя локальна бібліотека залишається на iPhone. Синхронізацію музики додамо окремим оновленням.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            Task { await cloud.signOut() }
                        } label: {
                            Text("Вийти з акаунта").frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Text(registering ? "Створити акаунт" : "Увійти в акаунт")
                            .font(.headline)
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .padding(14)
                            .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        HStack {
                            Group {
                                if showPassword {
                                    TextField("Пароль (від 6 символів)", text: $password)
                                } else {
                                    SecureField("Пароль (від 6 символів)", text: $password)
                                }
                            }
                            .textContentType(registering ? .newPassword : .password)
                            Button { showPassword.toggle() } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                            }
                        }
                        .padding(14)
                        .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        if registering {
                            SecureField("Повтори пароль", text: $confirmPassword)
                                .padding(14)
                                .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        }
                        Button {
                            Task {
                                if registering { await cloud.signUp(email: email, password: password) }
                                else { await cloud.signIn(email: email, password: password) }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if cloud.isBusy { ProgressView().tint(.white) }
                                Text(registering ? "Зареєструватися" : "Увійти")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(.white)
                            .background(Color(red: 0.22, green: 0.62, blue: 0.95), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(cloud.isBusy || !email.contains("@") || password.count < 6 || (registering && password != confirmPassword))
                        Button(registering ? "Маю акаунт — увійти" : "Немає акаунта — зареєструватися") {
                            registering.toggle()
                            cloud.errorMessage = nil
                            cloud.infoMessage = nil
                        }
                        .frame(maxWidth: .infinity)
                    }
                    if let error = cloud.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    if let info = cloud.infoMessage {
                        Label(info, systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 500, alignment: .leading)
                .padding(22)
            }
            .navigationTitle("Акаунт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .task { await cloud.refreshSessionIfNeeded() }
    }
}

// MARK: - AMusic Community Catalog v1 (separate from local and private cloud libraries)
private struct AMCommunityTrack: Decodable, Identifiable {
    let id: UUID
    let owner_id: UUID
    let title: String
    let artist: String
    let audio_path: String
    let artwork_path: String?
    let created_at: String
}

@MainActor
private final class AMCommunityService: ObservableObject {
    @Published var tracks: [AMCommunityTrack] = []
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    private let base = URL(string: "https://pnlmxtsvmlyaywbgzhht.supabase.co")!
    private let key = "sb_publishable_-weL94RHO6GwLlBAT5TKgw_Cc1k6tA0"

    private func call(_ path: String, token: String, method: String = "GET", body: Data? = nil, contentType: String? = nil) async throws -> Data {
        // Build the REST URL preserving query parameters after "?".
        // URL.appending(path:) encodes "?" as part of the table name (PGRST205).
        guard let endpoint = URL(string: base.absoluteString + "/" + path) else {
            throw NSError(domain: "AMusicCommunity", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Некоректна адреса AMusic Cloud"])
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "AMusicCommunity", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Помилка з'єднання"])
        }
        return data
    }

    func reload(token: String) async {
        busy = true; defer { busy = false }
        do {
            let data = try await call("rest/v1/amusic_public_tracks?select=*&is_visible=eq.true&order=created_at.desc&limit=100", token: token)
            tracks = try JSONDecoder().decode([AMCommunityTrack].self, from: data)
        } catch { self.error = error.localizedDescription }
    }

    func publish(file: URL, name: String, artist: String, png: URL?, token: String, user: UUID) async {
        busy = true; error = nil; notice = nil; defer { busy = false }
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        do {
            let ext = file.pathExtension.lowercased()
            let types = ["mp3":"audio/mpeg", "m4a":"audio/mp4", "aac":"audio/aac", "mp4":"audio/mp4"]
            guard let mime = types[ext] else { throw NSError(domain: "AMusic", code: 2, userInfo: [NSLocalizedDescriptionKey:"Дозволені MP3, M4A, AAC"]) }
            let bytes = try Data(contentsOf: file)
            guard !bytes.isEmpty, bytes.count <= 25 * 1024 * 1024 else { throw NSError(domain: "AMusic", code: 3, userInfo: [NSLocalizedDescriptionKey:"Аудіо має бути до 25 МБ"]) }
            let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            guard !cleanName.isEmpty else { throw NSError(domain:"AMusic",code:4,userInfo:[NSLocalizedDescriptionKey:"Укажи назву"]) }
            let id = UUID()
            let audioPath = "\(user.uuidString.lowercased())/\(id.uuidString.lowercased()).\(ext)"
            _ = try await call("storage/v1/object/amusic-community-audio/\(audioPath)", token: token, method:"POST", body:bytes, contentType:mime)
            var coverPath: String? = nil
            if let png {
                let scopedPNG = png.startAccessingSecurityScopedResource()
                defer { if scopedPNG { png.stopAccessingSecurityScopedResource() } }
                guard png.pathExtension.lowercased() == "png" else { throw NSError(domain:"AMusic",code:5,userInfo:[NSLocalizedDescriptionKey:"Обкладинка повинна бути PNG"]) }
                let imageData = try Data(contentsOf: png)
                guard imageData.count <= 2 * 1024 * 1024, imageData.starts(with: [137,80,78,71,13,10,26,10]) else { throw NSError(domain:"AMusic",code:6,userInfo:[NSLocalizedDescriptionKey:"Некоректний PNG або більше 2 МБ"]) }
                let path = "\(user.uuidString.lowercased())/\(id.uuidString.lowercased()).png"
                _ = try await call("storage/v1/object/amusic-community-artwork/\(path)", token: token, method:"POST", body:imageData, contentType:"image/png")
                coverPath = path
            }
            var entry: [String:Any] = ["owner_id":user.uuidString.lowercased(),"title":cleanName,"artist":String(artist.trimmingCharacters(in:.whitespacesAndNewlines).prefix(100)),"audio_path":audioPath,"mime_type":mime,"audio_bytes":bytes.count,"rights_confirmed":true]
            if let coverPath { entry["artwork_path"] = coverPath }
            _ = try await call("rest/v1/amusic_public_tracks", token:token, method:"POST", body:try JSONSerialization.data(withJSONObject:[entry]), contentType:"application/json")
            notice = "Композицію опубліковано"
            await reload(token:token)
        } catch { self.error = error.localizedDescription }
    }

    func download(_ track: AMCommunityTrack, token: String, to music: MusicStore) async {
        busy = true; error = nil; defer { busy = false }
        do {
            let data = try await call("storage/v1/object/authenticated/amusic-community-audio/\(track.audio_path)", token:token)
            let ext = (track.audio_path as NSString).pathExtension
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try data.write(to:url,options:.atomic)
            defer { try? FileManager.default.removeItem(at:url) }
            music.importFiles([url])
            notice = "Композицію додано локально"
        } catch { self.error = error.localizedDescription }
    }
}

// Native Files picker: copies the selected audio into the app temporary directory
// while the security-scoped URL is still available. Keeps source file untouched.
private struct AMCommunityDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [
            UTType.mp3, UTType.mpeg4Audio, UTType.audio
        ], asCopy: true)
        controller.allowsMultipleSelection = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onCancel(); return }
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("amusic-publish-\(UUID().uuidString).\(url.pathExtension.lowercased())")
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                onPick(destination)
            } catch { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

private struct AMCommunityScreen: View {
    @ObservedObject var cloud: AMCloudAuthStore
    @ObservedObject var music: MusicStore
    @StateObject private var service = AMCommunityService()
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var publishing = false
    @State private var file: URL?
    @State private var cover: URL?
    @State private var choosingAudio = false
    @State private var choosingCover = false
    @State private var choosingLocalTrack = false
    @State private var name = ""
    @State private var artist = ""
    @State private var rights = false
    private let blue = Color(red:0.20,green:0.55,blue:0.93)
    private var matches: [AMCommunityTrack] { service.tracks.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                if !cloud.isSignedIn {
                    ContentUnavailableView("Потрібен акаунт AMusic", systemImage:"person.crop.circle.badge.questionmark", description: Text("Увійди через Профіль → AMusic Cloud"))
                } else {
                    List {
                        TextField("Пошук композицій", text:$query)
                        ForEach(matches) { track in
                            HStack(spacing:12) {
                                Image(systemName:"music.note").foregroundStyle(blue).frame(width:36,height:36).background(blue.opacity(0.12),in:RoundedRectangle(cornerRadius:9))
                                VStack(alignment:.leading,spacing:3) {
                                    Text(track.title.count > 20 ? String(track.title.prefix(19)) + "…" : track.title).font(.subheadline.weight(.semibold))
                                    Text(track.artist).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { Task { if let token = await cloud.communityToken() { await service.download(track,token:token,to:music) } } } label: { Image(systemName:"arrow.down.to.line").font(.title3) }.buttonStyle(.borderless).disabled(service.busy)
                            }.padding(.vertical,5)
                        }
                    }.listStyle(.plain)
                }
            }
            .navigationTitle("Музика для всіх")
            .toolbar {
                ToolbarItem(placement:.topBarLeading) { Button("Назад") { dismiss() } }
                ToolbarItem(placement:.topBarTrailing) { Button { publishing = true } label: { Image(systemName:"plus") }.disabled(!cloud.isSignedIn) }
                ToolbarItem(placement:.topBarTrailing) { Button { Task { await refresh() } } label: { Image(systemName:"arrow.clockwise") }.disabled(service.busy) }
            }
            .task { await refresh() }
            .sheet(isPresented:$publishing) { publishSheet }
            .alert("AMusic",isPresented:Binding(get:{service.error != nil || service.notice != nil},set:{ if !$0 { service.error=nil; service.notice=nil } })) { Button("OK",role:.cancel){} } message: { Text(service.error ?? service.notice ?? "") }
        }
    }
    private func refresh() async { if let token = await cloud.communityToken() { await service.reload(token:token) } }
    private var publishSheet: some View {
        NavigationStack {
            Form {
                Section("Аудіо") {
                    Button { choosingAudio = true } label: {
                        Label(file?.lastPathComponent ?? "Вибрати MP3 / M4A / AAC у Файлах", systemImage: "folder")
                    }
                    Button { choosingLocalTrack = true } label: {
                        Label("Вибрати із локальної бібліотеки AMusic", systemImage: "music.note.list")
                    }
                    TextField("Назва композиції",text:$name).onChange(of:file) { _,newValue in if name.isEmpty, let newValue { name = newValue.deletingPathExtension().lastPathComponent } }
                    TextField("Виконавець",text:$artist)
                }
                Section("Обкладинка · необов'язково") {
                    Button { choosingCover = true } label: {
                        Label(cover == nil ? "Вибрати фото з галереї" : "Фото вибрано · змінити", systemImage: "photo.on.rectangle")
                    }
                    if cover != nil {
                        Button("Прибрати обкладинку", role: .destructive) { cover = nil }
                    }
                    Text("Фото буде перетворено на PNG. Максимум 2 МБ.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section { Toggle("Я маю право опублікувати цю композицію",isOn:$rights) }
                Section { Button("Опублікувати") { Task { await publish() } }.disabled(file == nil || !rights || name.trimmingCharacters(in:.whitespaces).isEmpty || service.busy) }
            }
            .navigationTitle("Опублікувати")
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Закрити") { publishing=false } } }
            .sheet(isPresented: $choosingAudio) {
                AMCommunityDocumentPicker { picked in
                    file = picked
                    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        name = picked.deletingPathExtension().lastPathComponent
                    }
                    choosingAudio = false
                } onCancel: {
                    choosingAudio = false
                }
            }
            .sheet(isPresented: $choosingCover) {
                AMPrivateMultiPhotoPicker(onImageData: { data in
                    guard let image = UIImage(data: data) else { return }
                    // Resize when necessary to keep within the server's 2 MiB cap.
                    var candidate = image
                    for _ in 0..<5 {
                        if let pngData = candidate.pngData(), pngData.count <= 2 * 1024 * 1024 {
                            let destination = FileManager.default.temporaryDirectory
                                .appendingPathComponent("amusic-community-cover-\(UUID().uuidString).png")
                            do {
                                try pngData.write(to: destination, options: .atomic)
                                cover = destination
                                service.error = nil
                            } catch { service.error = "Не вдалося зберегти вибрану обкладинку." }
                            return
                        }
                        let target = CGSize(width: max(1, candidate.size.width * 0.7),
                                            height: max(1, candidate.size.height * 0.7))
                        candidate = UIGraphicsImageRenderer(size: target).image { _ in
                            candidate.draw(in: CGRect(origin: .zero, size: target))
                        }
                    }
                    service.error = "Фото завелике для PNG до 2 МБ. Вибери інше."
                }, onDone: { choosingCover = false })
            }
            .sheet(isPresented: $choosingLocalTrack) {
                NavigationStack {
                    List(music.tracks) { track in
                        Button {
                            let localURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent(track.filename)
                            file = localURL
                            name = track.title
                            choosingLocalTrack = false
                        } label: {
                            Label(track.title, systemImage: "music.note")
                        }
                    }
                    .navigationTitle("Локальна музика")
                    .toolbar { ToolbarItem(placement: .topBarTrailing) {
                        Button("Закрити") { choosingLocalTrack = false }
                    }}
                }
            }
        }
    }
    private func publish() async {
        guard let file, let user = cloud.userID, let token = await cloud.communityToken() else { return }
        await service.publish(file:file,name:name,artist:artist.isEmpty ? "Невідомий виконавець":artist,png:cover,token:token,user:user)
        if service.error == nil { publishing=false; self.file=nil; cover=nil; name=""; artist=""; rights=false }
    }
}

extension AMCloudAuthStore {
    func communityToken() async -> String? {
        await refreshSessionIfNeeded()
        return currentCommunityAccessToken
    }
}


// MARK: - Private Telegram Sync (not part of public Community)
private struct AMTelegramSyncEntry: Decodable, Identifiable {
    let id: UUID
    let title: String
    let storage_path: String
}

// Local-only history of synchronization results. No credentials or file contents are stored.
private struct AMTelegramSyncHistoryItem: Identifiable, Codable {
    let id: UUID
    let when: Date
    let imported: Int
    let failed: Int
}

@MainActor
private final class AMTelegramSyncStore: ObservableObject {
    @Published var isSyncing = false
    @Published var notice: String?
    @Published var error: String?
    @Published var addedCount = 0
    @Published var statusLine = "Перевірка Cloud…"
    @Published var completedDownloads = 0
    @Published var expectedDownloads = 0
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var history: [AMTelegramSyncHistoryItem] = []
    @Published var autoSyncEnabled: Bool = UserDefaults.standard.object(forKey: "amusic.telegramSync.auto.v1") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSyncEnabled, forKey: "amusic.telegramSync.auto.v1") }
    }

    private let importedIDsKey = "amusic.telegramSync.importedIDs.v1"
    private let lastSyncKey = "amusic.telegramSync.lastChecked.v1"
    private let historyKey = "amusic.telegramSync.history.v1"
    private var lastAutoAttempt: Date?

    init() {
        lastSyncAt = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        if let bytes = UserDefaults.standard.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([AMTelegramSyncHistoryItem].self, from: bytes) {
            history = Array(decoded.prefix(8))
        }
    }

    /// Manual checks ignore the short automatic-check cooldown.
    func sync(cloud: AMCloudAuthStore, music: MusicStore, force: Bool = false) async {
        guard !isSyncing else { return }
        guard cloud.isSignedIn else {
            if force { error = "Спочатку увійди в AMusic Cloud через Профіль." }
            return
        }
        if !force {
            guard autoSyncEnabled else { return }
            if let lastAutoAttempt, Date().timeIntervalSince(lastAutoAttempt) < 20 { return }
            lastAutoAttempt = Date()
        }
        isSyncing = true
        error = nil
        notice = nil
        addedCount = 0
        completedDownloads = 0
        expectedDownloads = 0
        statusLine = "Перевіряємо приватний каталог…"
        defer { isSyncing = false }

        do {
            guard let token = await cloud.communityToken(), let userID = cloud.userID else {
                throw NSError(domain: "AMusicSync", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "Cloud-сесія недоступна. Увійди в акаунт ще раз."])
            }

            // Pages prevent the old 250-song limit from permanently hiding later uploads.
            let pageSize = 150
            var offset = 0
            var allEntries: [AMTelegramSyncEntry] = []
            while true {
                var components = URLComponents(
                    url: AMCloudConfig.baseURL.appending(path: "rest/v1/amusic_telegram_tracks"),
                    resolvingAgainstBaseURL: false
                )!
                components.queryItems = [
                    URLQueryItem(name: "select", value: "id,title,storage_path"),
                    URLQueryItem(name: "owner_id", value: "eq." + userID.uuidString.lowercased()),
                    URLQueryItem(name: "order", value: "created_at.asc,id.asc"),
                    URLQueryItem(name: "limit", value: String(pageSize)),
                    URLQueryItem(name: "offset", value: String(offset))
                ]
                guard let url = components.url else { throw URLError(.badURL) }
                var request = URLRequest(url: url)
                request.timeoutInterval = 35
                request.setValue(AMCloudConfig.publishableKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    throw NSError(domain: "AMusicSync", code: 11,
                                  userInfo: [NSLocalizedDescriptionKey: "Не вдалося відкрити Cloud-каталог. Перевір вхід та інтернет."])
                }
                let page = try JSONDecoder().decode([AMTelegramSyncEntry].self, from: data)
                allEntries.append(contentsOf: page)
                if page.count < pageSize { break }
                offset += page.count
            }

            let imported = Set(UserDefaults.standard.stringArray(forKey: importedIDsKey) ?? [])
            let pending = allEntries.filter { !imported.contains($0.id.uuidString.lowercased()) }
            expectedDownloads = pending.count
            statusLine = pending.isEmpty ? "Усе вже синхронізовано" : "Нових MP3: \(pending.count)"

            var successCount = 0
            var failureCount = 0
            var firstFailure: String?
            for entry in pending {
                statusLine = "Завантажено \(completedDownloads) із \(expectedDownloads)"
                defer { completedDownloads += 1 }
                let prefix = userID.uuidString.lowercased() + "/"
                guard entry.storage_path.hasPrefix(prefix),
                      !entry.storage_path.contains(".."),
                      entry.storage_path.hasSuffix(".mp3") else {
                    failureCount += 1
                    if firstFailure == nil { firstFailure = "Неправильний шлях MP3 у каталозі." }
                    continue
                }
                do {
                    let path = "storage/v1/object/authenticated/amusic-telegram-sync/" + entry.storage_path
                    var request = URLRequest(url: AMCloudConfig.baseURL.appending(path: path))
                    request.timeoutInterval = 120
                    request.setValue(AMCloudConfig.publishableKey, forHTTPHeaderField: "apikey")
                    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                    let (audio, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else {
                        throw NSError(domain: "AMusicSync", code: 12,
                                      userInfo: [NSLocalizedDescriptionKey: "Файл у Cloud недоступний. Перевір Storage."])
                    }
                    if try music.importSyncedAudio(audio, name: entry.title, sourceID: entry.id) {
                        successCount += 1
                    }
                } catch {
                    failureCount += 1
                    if firstFailure == nil { firstFailure = error.localizedDescription }
                }
            }
            addedCount = successCount
            let now = Date()
            lastSyncAt = now
            UserDefaults.standard.set(now, forKey: lastSyncKey)
            let record = AMTelegramSyncHistoryItem(id: UUID(), when: now,
                                                   imported: successCount, failed: failureCount)
            history.insert(record, at: 0)
            history = Array(history.prefix(8))
            UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: historyKey)

            if failureCount > 0 {
                notice = "Додано \(successCount), не вдалося завантажити \(failureCount)."
                self.error = firstFailure ?? "Частину файлів не вдалося завантажити. Спробуй ще раз."
            } else {
                notice = successCount == 0 ? "Нових композицій немає" : "Додано нових композицій: \(successCount)"
                self.error = nil
            }
            statusLine = notice ?? "Синхронізацію завершено"
        } catch {
            self.error = error.localizedDescription
            self.notice = "Синхронізація не завершена"
            self.statusLine = "Помилка синхронізації"
        }
    }
}

private struct AMTelegramSyncScreen: View {
    @ObservedObject var sync: AMTelegramSyncStore
    @ObservedObject var cloud: AMCloudAuthStore
    @ObservedObject var music: MusicStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Telegram → AMusic") {
                    Label("Приватні MP3, доступні офлайн", systemImage: "lock.shield")
                    Text("Твій Python-скрипт надсилає музику в Telegram та приватний Cloud. AMusic перевіряє нові файли при відкритті й після входу в Cloud.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !cloud.isSignedIn {
                        Label("Спочатку увійди в AMusic Cloud у Профілі.", systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                    Toggle("Автосинхронізація", isOn: $sync.autoSyncEnabled)
                        .disabled(!cloud.isSignedIn)
                    Button {
                        Task { await sync.sync(cloud: cloud, music: music, force: true) }
                    } label: {
                        HStack {
                            Label("Синхронізувати зараз", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if sync.isSyncing { ProgressView() }
                        }
                    }
                    .disabled(!cloud.isSignedIn || sync.isSyncing)
                }

                Section("Стан синхронізації") {
                    if sync.isSyncing {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(sync.statusLine).font(.subheadline)
                            if sync.expectedDownloads > 0 {
                                ProgressView(value: Double(sync.completedDownloads),
                                             total: Double(sync.expectedDownloads))
                                Text("\(sync.completedDownloads) із \(sync.expectedDownloads)")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else { ProgressView() }
                        }
                    } else if let notice = sync.notice {
                        Label(notice, systemImage: sync.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(sync.error == nil ? Color.green : Color.orange)
                    } else {
                        Text("Нові пісні автоматично перевірятимуться, коли AMusic активна.")
                            .foregroundStyle(.secondary)
                    }
                    if let error = sync.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    if let date = sync.lastSyncAt {
                        LabeledContent("Остання перевірка", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                if !sync.history.isEmpty {
                    Section("Історія") {
                        ForEach(sync.history.prefix(5)) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.when, format: .dateTime.day().month().hour().minute())
                                        .font(.subheadline)
                                    Text(item.failed > 0 ? "З помилками: \(item.failed)" : "Завершено")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("+\(item.imported)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(item.imported > 0 ? Color.green : Color.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Telegram Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
