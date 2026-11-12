import SwiftUI
import AVFoundation
import Accelerate
import UniformTypeIdentifiers

@main
struct RiffnoteApp: App {
    @StateObject private var model = AudioModel()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model).frame(minWidth: 920, minHeight: 650)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Playback") {
                Button("Open Audio…") { model.openFile() }.keyboardShortcut("o", modifiers: .command)
                Button(model.isPlaying ? "Pause" : "Play") { model.togglePlayback() }.keyboardShortcut(.space, modifiers: [])
                Button("Add Marker") { model.addMarker() }.keyboardShortcut("m", modifiers: [])
            }
        }
    }
}

struct Marker: Codable, Identifiable { var id = UUID(); var time: Double; var label: String }
struct LoopPoint: Codable, Identifiable { var id = UUID(); var name: String; var start: Double; var end: Double }
struct SessionData: Codable { var markers: [Marker] = []; var loops: [LoopPoint] = [] }

@MainActor final class AudioModel: ObservableObject {
    @Published var title = "No Audio Open"
    @Published var duration: Double = 0
    @Published var position: Double = 0
    @Published var isPlaying = false
    @Published var speed: Double = 1
    @Published var pitch: Double = 0
    @Published var lowGain: Double = 0
    @Published var midGain: Double = 0
    @Published var highGain: Double = 0
    @Published var markers: [Marker] = []
    @Published var loops: [LoopPoint] = []
    @Published var spectrum: [Double] = []
    @Published var errorMessage: String?
    @Published var selectedLoop: UUID?
    @Published var repeatTrack = false
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let eq = AVAudioUnitEQ(numberOfBands: 3)
    private var file: AVAudioFile?
    private var timer: Timer?
    private var audioURL: URL?
    private var playbackStartPosition: Double = 0
    private var waveform: [Float] = []
    private var bookmarkURL: URL? {
        guard let audioURL else { return nil }
        let key = audioURL.standardizedFileURL.path.data(using: .utf8)!.base64EncodedString().replacingOccurrences(of: "/", with: "_")
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Riffnote", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(key + ".json")
    }
    init() {
        eq.bands[0].filterType = .lowShelf; eq.bands[0].frequency = 200
        eq.bands[1].filterType = .parametric; eq.bands[1].frequency = 1000; eq.bands[1].bandwidth = 1
        eq.bands[2].filterType = .highShelf; eq.bands[2].frequency = 5000
        engine.attach(player); engine.attach(timePitch); engine.attach(eq)
        engine.connect(player, to: timePitch, format: nil); engine.connect(timePitch, to: eq, format: nil); engine.connect(eq, to: engine.mainMixerNode, format: nil)
        try? engine.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in Task { @MainActor in self?.updatePosition() } }
    }
    func openFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio, .movie]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func load(_ url: URL) {
        do {
            player.stop(); engine.stop(); try engine.start()
            let audio = try AVAudioFile(forReading: url); file = audio; audioURL = url; title = url.deletingPathExtension().lastPathComponent
            duration = Double(audio.length) / audio.processingFormat.sampleRate; position = 0; isPlaying = false
            waveform = Self.makeWaveform(audio)
            if let path = bookmarkURL, let data = try? Data(contentsOf: path), let session = try? JSONDecoder().decode(SessionData.self, from: data) { markers = session.markers; loops = session.loops }
            else { markers = []; loops = [] }
            selectedLoop = nil; analyze(at: 0)
        } catch { errorMessage = "Could not open the file. Make sure it’s a supported audio file and try again." }
    }
    private static func makeWaveform(_ file: AVAudioFile) -> [Float] {
        let frames = AVAudioFrameCount(file.length); guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return [] }
        do { try file.read(into: buffer) } catch { return [] }
        guard let channels = buffer.floatChannelData else { return [] }
        let n = Int(buffer.frameLength); let hop = max(1, n / 2400); var result: [Float] = []; result.reserveCapacity(2400)
        for start in stride(from: 0, to: n, by: hop) {
            let end = min(start + hop, n); var peak: Float = 0
            for i in start..<end { for c in 0..<Int(buffer.format.channelCount) { peak = max(peak, abs(channels[c][i])) } }
            result.append(peak)
        }
        return result
    }
    func togglePlayback() { isPlaying ? pause() : play() }
    func play() {
        guard let file else { return }
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying {
            if position >= duration { position = 0 }
            let frame = AVAudioFramePosition(position * file.processingFormat.sampleRate)
            guard let buffer = readBuffer(from: frame) else { return }
            playbackStartPosition = position
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil); player.play(); isPlaying = true
        }
    }
    private func readBuffer(from frame: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        guard let file else { return nil }
        let remaining = max(0, file.length - frame); let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(file.processingFormat.sampleRate * max(0.1, duration - position))))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return nil }
        do { file.framePosition = frame; try file.read(into: buffer); return buffer } catch { return nil }
    }
    func pause() { player.pause(); isPlaying = false }
    func seek(_ time: Double) {
        position = min(max(0, time), duration); analyze(at: position)
        guard isPlaying else { return }; player.stop(); isPlaying = false; play()
    }
    private func updatePosition() {
        guard isPlaying, let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime), let file else { return }
        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        position = min(duration, playbackStartPosition + elapsed * speed)
        if let loop = activeLoop, position >= loop.end {
            player.stop(); position = loop.start; isPlaying = false; play(); return
        }
        if position >= duration {
            if repeatTrack { player.stop(); position = 0; isPlaying = false; play() }
            else { pause(); position = duration }
        }
        _ = file
    }
    func setSpeed(_ value: Double) { speed = value; timePitch.rate = Float(value) }
    func setPitch(_ value: Double) { pitch = value; timePitch.pitch = Float(value * 100) }
    func setEQ() { eq.bands[0].gain = Float(lowGain); eq.bands[1].gain = Float(midGain); eq.bands[2].gain = Float(highGain) }
    func addMarker() { markers.append(Marker(time: position, label: "Marker \(markers.count + 1)")); save() }
    func rename(_ marker: Marker, to name: String) { guard let i = markers.firstIndex(where: {$0.id == marker.id}) else { return }; markers[i].label = name; save() }
    func delete(_ marker: Marker) { markers.removeAll{$0.id == marker.id}; save() }
    func createLoop() {
        let start = max(0, position - 2), end = min(duration, position + 2)
        createLoop(start: start, end: end)
    }
    func createLoop(start: Double, end: Double) {
        let lower = min(max(0, start), duration)
        let upper = min(max(lower + 0.1, end), duration)
        guard upper > lower else { return }
        let loop = LoopPoint(name: "Loop \(loops.count + 1)", start: lower, end: upper)
        loops.append(loop); selectedLoop = loop.id; seek(lower); save()
    }
    func selectLoop(_ loop: LoopPoint) { selectedLoop = loop.id; seek(loop.start) }
    func updateLoopName(_ loop: LoopPoint, _ name: String) { guard let i = loops.firstIndex(where: {$0.id == loop.id}) else { return }; loops[i].name = name; save() }
    func removeLoop(_ loop: LoopPoint) { loops.removeAll{$0.id == loop.id}; if selectedLoop == loop.id { selectedLoop = nil }; save() }
    func jumpMarker(_ marker: Marker) { seek(marker.time) }
    private func save() { guard let bookmarkURL, let data = try? JSONEncoder().encode(SessionData(markers: markers, loops: loops)) else { return }; try? data.write(to: bookmarkURL, options: .atomic) }
    func analyze(at time: Double) {
        guard let file else { spectrum = []; return }
        let rate = file.processingFormat.sampleRate; let size = 4096
        guard let buffer = readRawSegment(file: file, at: AVAudioFramePosition(time * rate), count: size), let channel = buffer.floatChannelData?[0] else { return }
        var samples = Array(UnsafeBufferPointer(start: channel, count: min(size, Int(buffer.frameLength))))
        if samples.count < size { samples += Array(repeating: 0, count: size - samples.count) }
        var window = [Float](repeating: 0, count: size); vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM)); vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(size))
        let half = size / 2; var real = [Float](repeating: 0, count: half); var imag = [Float](repeating: 0, count: half)
        for k in 1..<half { var re: Float = 0; var im: Float = 0; for n in 0..<size { let a = 2 * Float.pi * Float(k * n) / Float(size); re += samples[n] * cos(a); im -= samples[n] * sin(a) }; real[k] = re; imag[k] = im }
        var mags = [Double](repeating: 0, count: 96)
        for midi in 24...119 { let hz = 440 * pow(2, Double(midi - 69) / 12); let bin = min(half - 1, max(1, Int(hz * Double(size) / rate))); mags[midi - 24] = Double(hypot(real[bin], imag[bin])) }
        let maxMag = max(mags.max() ?? 1, 0.000001); spectrum = mags.map { min(1, $0 / maxMag) }
    }
    private func readRawSegment(file: AVAudioFile, at position: AVAudioFramePosition, count: Int) -> AVAudioPCMBuffer? {
        let p = min(max(0, position), max(0, file.length - 1)); guard let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        do { file.framePosition = p; try file.read(into: b); return b } catch { return nil }
    }
    var waveformData: [Float] { waveform }
    var activeLoop: LoopPoint? { loops.first(where: {$0.id == selectedLoop}) }
}

struct ContentView: View {
    @EnvironmentObject var model: AudioModel
    @State private var loopSelectionMode = false
    @State private var loopDragStart: Double?
    @State private var loopDragEnd: Double?
    @State private var loopSelection: (start: Double, end: Double)?
    @State private var analysisPresented = false
    @State private var isDropTarget = false
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls.padding(.horizontal, 24).padding(.vertical, 12)
            Divider()
            timeline.frame(maxHeight: .infinity)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                loopPanel.frame(maxWidth: .infinity)
                Divider()
                markerPanel.frame(maxWidth: .infinity)
            }.frame(height: 190)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isDropTarget {
                Text("Drop an audio file to open it")
                    .font(.headline)
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 2))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget, perform: loadDroppedAudio)
        .sheet(isPresented: $analysisPresented) { analysisPanel.frame(width: 360, height: 520).padding(20) }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
    }
    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.path").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) { Text("Riffnote").font(.headline); Text(model.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Button { analysisPresented = true } label: { Label("Analysis", systemImage: "slider.horizontal.3") }
            Button { model.openFile() } label: { Label("Open Audio", systemImage: "folder") }.keyboardShortcut("o", modifiers: .command).buttonStyle(.borderedProminent)
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }
    private func loadDroppedAudio(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let droppedURL = item as? URL {
                url = droppedURL
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = nil
            }
            guard let url else { return }
            Task { @MainActor in model.load(url) }
        }
        return true
    }
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TRACK").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.duration > 0 {
                    Button {
                        loopSelectionMode.toggle()
                        loopDragStart = nil; loopDragEnd = nil
                        loopSelection = nil
                    } label: {
                        Label(loopSelectionMode ? "Cancel" : "Select Section", systemImage: loopSelectionMode ? "xmark" : "repeat")
                    }.controlSize(.small).tint(loopSelectionMode ? .orange : .accentColor)
                }
                if loopSelectionMode { Button { createSelectedLoop() } label: { Label("Create Loop", systemImage: "repeat") }.controlSize(.small).buttonStyle(.borderedProminent).disabled(loopSelection == nil) }
                Text(loopSelectionMode ? "Drag across the track, then click Create Loop" : "Click the waveform to seek").font(.caption).foregroundStyle(.tertiary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.075))
                    if model.waveformData.isEmpty { ContentUnavailableView("Open an Audio File", systemImage: "waveform", description: Text("Load an audio file to get started")).foregroundStyle(.white.opacity(0.7)) }
                    else {
                        Canvas { context, size in
                            let values = model.waveformData
                            let rulerHeight: CGFloat = 25
                            let waveHeight = size.height - rulerHeight
                            let mid = waveHeight / 2
                            let step = size.width / CGFloat(values.count)
                            for (i, value) in values.enumerated() { let x = CGFloat(i) * step; let h = max(1, CGFloat(value) * mid * 0.9); context.fill(Path(roundedRect: CGRect(x: x, y: mid-h, width: max(1, step*0.75), height: h*2), cornerRadius: 1), with: .color(.accentColor.opacity(0.8))) }
                            if let loop = model.activeLoop { let a = size.width * CGFloat(loop.start / max(model.duration,0.001)); let b = size.width * CGFloat(loop.end / max(model.duration,0.001)); context.fill(Path(CGRect(x:a,y:0,width:max(0,b-a),height:waveHeight)), with: .color(.green.opacity(0.12))) }
                            if let selection = loopSelection {
                                let a = size.width * CGFloat(selection.start / max(model.duration,0.001))
                                let b = size.width * CGFloat(selection.end / max(model.duration,0.001))
                                context.fill(Path(CGRect(x:a,y:0,width:max(1,b-a),height:waveHeight)), with: .color(.orange.opacity(0.25)))
                            }
                            if let first = loopDragStart, let last = loopDragEnd {
                                let a = size.width * CGFloat(min(first,last) / max(model.duration,0.001))
                                let b = size.width * CGFloat(max(first,last) / max(model.duration,0.001))
                                context.fill(Path(CGRect(x:a,y:0,width:max(1,b-a),height:waveHeight)), with: .color(.orange.opacity(0.25)))
                            }
                            for marker in model.markers {
                                let markerX = size.width * CGFloat(marker.time / max(model.duration, 0.001))
                                var markerPath = Path(); markerPath.move(to: CGPoint(x: markerX, y: 0)); markerPath.addLine(to: CGPoint(x: markerX, y: waveHeight))
                                context.stroke(markerPath, with: .color(.orange), lineWidth: 1.5)
                            }
                            let playheadX = size.width * CGFloat(model.position / max(model.duration, 0.001))
                            var playhead = Path(); playhead.move(to: CGPoint(x: playheadX, y: 0)); playhead.addLine(to: CGPoint(x: playheadX, y: waveHeight))
                            context.stroke(playhead, with: .color(.yellow), lineWidth: 2)
                            context.fill(Path(ellipseIn: CGRect(x: playheadX - 4, y: 0, width: 8, height: 8)), with: .color(.yellow))

                            var ruler = Path(); ruler.move(to: CGPoint(x: 0, y: waveHeight)); ruler.addLine(to: CGPoint(x: size.width, y: waveHeight))
                            context.stroke(ruler, with: .color(.white.opacity(0.25)), lineWidth: 1)
                            let interval: Double = model.duration <= 90 ? 5 : model.duration <= 300 ? 10 : model.duration <= 900 ? 30 : model.duration <= 3600 ? 60 : 300
                            var tick = 0.0
                            while tick <= model.duration {
                                let tickX = size.width * CGFloat(tick / max(model.duration, 0.001))
                                let major = tick.truncatingRemainder(dividingBy: interval * 2) == 0
                                var tickPath = Path(); tickPath.move(to: CGPoint(x: tickX, y: waveHeight)); tickPath.addLine(to: CGPoint(x: tickX, y: waveHeight + (major ? 8 : 4)))
                                context.stroke(tickPath, with: .color(.white.opacity(0.35)), lineWidth: 1)
                                if major {
                                    let label = Text(time(tick)).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.65))
                                    context.draw(label, at: CGPoint(x: min(max(18, tickX), size.width - 18), y: waveHeight + 17))
                                }
                                tick += interval
                            }
                            if model.duration.truncatingRemainder(dividingBy: interval * 2) > 0 {
                                let endLabel = Text(time(model.duration)).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.65))
                                context.draw(endLabel, at: CGPoint(x: size.width - 18, y: waveHeight + 17))
                            }
                        }
                        .contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                let time = min(model.duration, max(0, model.duration * Double(g.location.x / proxy.size.width)))
                                if loopSelectionMode {
                                    if loopDragStart == nil { loopDragStart = time }
                                    loopDragEnd = time
                                } else { model.seek(time) }
                            }
                            .onEnded { g in
                                guard loopSelectionMode, let start = loopDragStart else { return }
                                let end = min(model.duration, max(0, model.duration * Double(g.location.x / proxy.size.width)))
                                if abs(end-start) >= 0.1 { loopSelection = (min(start,end), max(start,end)) }
                                loopDragStart = nil; loopDragEnd = nil
                            })
                    }
                }
            }.frame(minHeight: 190, maxHeight: .infinity)
            HStack { Text("Click the track to seek").font(.caption2).foregroundStyle(.tertiary); Spacer(); Text("\(model.markers.count) markers · \(model.loops.count) loops").font(.caption2).foregroundStyle(.tertiary) }
        }.padding(18)
    }
    private var markerPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Markers").font(.subheadline.weight(.semibold)); Spacer(); Button { model.addMarker() } label: { Image(systemName: "plus") }.help("Add a marker at the current position") }
            if model.markers.isEmpty { Text("Add reference points to the track.").font(.caption).foregroundStyle(.tertiary).padding(.top, 8) }
            List {
                ForEach(model.markers) { marker in HStack(spacing: 8) {
                    Button { model.jumpMarker(marker) } label: { Text(time(marker.time)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }.buttonStyle(.plain)
                    TextField("Name", text: Binding(get: { marker.label }, set: { model.rename(marker, to: $0) })).textFieldStyle(.plain).font(.caption)
                    Spacer(minLength: 0)
                    Button { model.delete(marker) } label: { Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary) }.buttonStyle(.plain)
                }}
            }.listStyle(.plain)
        }.padding(14)
    }
    private var loopPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Loops").font(.subheadline.weight(.semibold)); Spacer() }
            if model.loops.isEmpty { Text("Save sections to repeat while practicing.").font(.caption).foregroundStyle(.tertiary).padding(.top, 8) }
            List { ForEach(model.loops) { loop in HStack(spacing: 8) {
                Button { model.selectLoop(loop) } label: { Image(systemName: model.selectedLoop == loop.id ? "checkmark.circle.fill" : "circle").foregroundStyle(model.selectedLoop == loop.id ? .green : .secondary) }.buttonStyle(.plain).help(model.selectedLoop == loop.id ? "Loop in use" : "Use this loop")
                TextField("Loop name", text: Binding(get: { loop.name }, set: { model.updateLoopName(loop, $0) })).textFieldStyle(.plain).font(.caption)
                if model.selectedLoop == loop.id { Text("In Use").font(.caption2.weight(.medium)).foregroundStyle(.green) }
                Text("\(time(loop.start))–\(time(loop.end))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                Button { model.removeLoop(loop) } label: { Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary) }.buttonStyle(.plain)
            }.padding(.vertical, 2).listRowBackground(model.selectedLoop == loop.id ? Color.green.opacity(0.08) : Color.clear) } }.listStyle(.plain)
        }.padding(14)
    }
    private var controls: some View {
        HStack(spacing: 16) {
            Button { model.togglePlayback() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 38) }.buttonStyle(.borderedProminent).keyboardShortcut(.space, modifiers: [])
            Toggle(isOn: $model.repeatTrack) { Image(systemName: "repeat.1") }.toggleStyle(.button).help("Repeat track")
            Button { adjustSpeed(by: -0.1) } label: { Image(systemName: "minus") }.help("Slow down")
            Text(String(format: "%.0f%%", model.speed * 100)).font(.system(.caption, design: .monospaced)).frame(width: 42)
            Button { adjustSpeed(by: 0.1) } label: { Image(systemName: "plus") }.help("Speed up")
            Spacer()
        }
    }
    private func adjustSpeed(by amount: Double) {
        let adjusted = min(2, max(0.25, ((model.speed + amount) * 100).rounded() / 100))
        model.setSpeed(adjusted)
    }
    private func createSelectedLoop() {
        guard let selection = loopSelection else { return }
        model.createLoop(start: selection.start, end: selection.end)
        loopSelection = nil
        loopSelectionMode = false
    }
    private var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Analysis").font(.headline); Spacer(); Button("Done") { analysisPresented = false } }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("EQ").font(.subheadline.weight(.semibold)); Spacer(); Button("Reset") { model.lowGain=0; model.midGain=0; model.highGain=0; model.setEQ() }.font(.caption) }
                eqRow("Low", value: Binding(get:{model.lowGain},set:{model.lowGain=$0;model.setEQ()}))
                eqRow("Mid", value: Binding(get:{model.midGain},set:{model.midGain=$0;model.setEQ()}))
                eqRow("High", value: Binding(get:{model.highGain},set:{model.highGain=$0;model.setEQ()}))
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Spettro").font(.subheadline.weight(.semibold)); Spacer(); Button { model.analyze(at: model.position) } label: { Image(systemName: "arrow.clockwise") }.help("Analizza la posizione corrente") }
                Text("Estimate of the notes in the audio").font(.caption).foregroundStyle(.secondary)
                SpectrumView(values: model.spectrum).frame(height: 150)
                PianoKeyboard(spectrum: model.spectrum).frame(height: 78)
                Text("Use this analysis as a listening aid. Harmonics and complex sounds still require listening by ear.").font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }.padding(16)
    }
    private func eqRow(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 7) { Text(label).font(.caption).frame(width: 42, alignment: .leading); Slider(value: value, in: -12...12); Text(String(format:"%+.0f",value.wrappedValue)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing) }
    }
    private func time(_ seconds: Double) -> String { guard seconds.isFinite else { return "0:00" }; let s = Int(max(0,seconds)); return String(format:"%d:%02d",s/60,s%60) }
}

struct SpectrumView: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in Canvas { context, size in
            for i in 0..<12 { let y = size.height * CGFloat(i) / 11; var line = Path(); line.move(to: CGPoint(x:0,y:y)); line.addLine(to: CGPoint(x:size.width,y:y)); context.stroke(line, with:.color(.secondary.opacity(0.12)), lineWidth:1) }
            guard values.count == 96 else { return }
            let w = size.width / CGFloat(values.count)
            for i in values.indices { let h = CGFloat(values[i]) * size.height; let rect = CGRect(x:CGFloat(i)*w, y:size.height-h, width:max(1,w-1), height:h); context.fill(Path(roundedRect:rect,cornerRadius:1),with:.color(.cyan.opacity(0.8))) }
        }}.background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:6))
    }
}
struct PianoKeyboard: View {
    let spectrum: [Double]
    private let black = Set([1,3,6,8,10])
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width / 14
            ZStack(alignment:.topLeading) {
                HStack(spacing:1) { ForEach(0..<14,id:\.self) { i in let midi = 48+i; Rectangle().fill(Color.white).overlay(Rectangle().stroke(Color.gray.opacity(0.6),lineWidth:1)).overlay(alignment:.bottom) { if i % 2 == 0 { Text(noteName(midi)).font(.system(size:8)).foregroundStyle(.secondary).padding(.bottom,3) } }.overlay { if spectrum.count > midi-24 && spectrum[midi-24] > 0.15 { Rectangle().fill(Color.accentColor.opacity(0.28)) } } } }
                ForEach(0..<14,id:\.self) { i in let pitchClass = (48+i)%12; if black.contains(pitchClass) { let x = CGFloat(i+1)*width-width*0.33; Rectangle().fill(Color.black).frame(width:width*0.66,height:geo.size.height*0.62).offset(x:x) } }
            }.clipShape(RoundedRectangle(cornerRadius:4))
        }
    }
    private func noteName(_ midi:Int) -> String { ["C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"][midi%12] }
}
