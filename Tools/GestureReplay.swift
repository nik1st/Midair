// Replays a gesture journal through the same engine as the app: what it did, and what it would do with other
// thresholds or the legacy layout. Build and run from the project root:
//   swiftc -parse-as-library -O Midair/Core/*.swift Tools/LegacyGestureEngine.swift Tools/GestureReplay.swift -o /tmp/gesture-replay
//   /tmp/gesture-replay <journal.jsonl | folder> [key=value ...] [preset=old|defaults] [--b key=value ...]
//                       [around=second] [window=3,0.5] [--csv]
// Keys are GestureConfig fields (the legacy layout's fields with preset=old); a typo in a name stops the run.
// preset=old runs the frames through the layout from before 1 November 2026, preset=defaults takes the current
// thresholds instead of the recorded ones (personal settings stay). After --b a second variant is given: the events
// of both are matched by time. around prints the frames around that second, counted from the first frame; window
// sets the window around the ⌃⌥⌘M and ⌃⌥⌘N marks, in seconds before and after. A folder is replayed in full, with
// totals per journal and per activity.
// Without keys the replay must match the journal by action kind: this checks that the journal is complete.
import CoreGraphics
import Foundation

@main
struct GestureReplay {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("gesture-replay: \(error)\n".utf8))
            exit(2)
        }
    }

    static func run(_ arguments: [String]) throws {
        guard let path = arguments.first else {
            print("Usage: gesture-replay <journal.jsonl | folder> [key=value ...] [preset=old|defaults] [--b ...] [around=sec] [window=before,after] [--csv]")
            return
        }
        var options = Options()
        var variants = [Variant(name: "A")]
        for argument in arguments.dropFirst() {
            if argument == "--b" {
                variants.append(Variant(name: "B"))
                continue
            }
            if argument == "--csv" {
                options.csv = true
                continue
            }
            if argument == "--frames" {
                options.frames = true
                continue
            }
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw ReplayError("unrecognized argument \"\(argument)\"") }
            switch parts[0] {
            case "around":
                guard let value = Double(parts[1]) else { throw ReplayError("around expects a number of seconds") }
                options.around = value
            case "window":
                let values = parts[1].split(separator: ",").compactMap { Double($0) }
                guard values.count == 2 else { throw ReplayError("window expects two numbers: before,after") }
                options.window = (values[0], values[1])
            case "preset":
                guard let preset = Variant.Preset(rawValue: parts[1]) else { throw ReplayError("preset must be old or defaults") }
                variants[variants.count - 1].preset = preset
            default:
                variants[variants.count - 1].overrides[parts[0]] = Self.value(parts[1])
            }
        }
        for variant in variants { try variant.validate() }

        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else { throw ReplayError("no such file: \(path)") }
        let files = isDirectory.boolValue
            ? try FileManager.default.contentsOfDirectory(atPath: expanded).filter { $0.hasSuffix(".jsonl") }.sorted()
                .map { (expanded as NSString).appendingPathComponent($0) }
            : [expanded]

        var totals = variants.map { _ in Totals() }
        if options.csv { print(GestureEvent.csvHeader) }
        for file in files {
            let journal = try Journal(path: file)
            var runs = try variants.map { try Run(variant: $0, journal: journal, options: options) }
            for index in runs.indices { runs[index].replay(journal) }
            for (index, run) in runs.enumerated() { totals[index].add(run) }
            if options.frames {
                print("t,phase,gap,finger,speed,travel,length,edge,fist,two,hold,pinky,joints,notes,acts,scrollDy,cx,cy")
                runs[0].frameRows.forEach { print($0) }
                continue
            }
            if options.csv {
                for run in runs { run.events.forEach { print($0.csv(journal: journal.name, variant: run.variant.name, start: journal.start)) } }
            } else if files.count == 1 {
                Report.single(journal, runs: runs, options: options)
            } else {
                Report.line(journal, runs: runs)
            }
        }
        if files.count > 1, !options.csv { Report.totals(totals, variants: variants) }
    }

    static func value(_ text: String) -> Any {
        if let bool = Bool(text) { return bool }
        if let int = Int(text) { return int }
        if let double = Double(text) { return double }
        return text
    }
}

struct ReplayError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    var csv = false
    /// Per-frame table of the first variant instead of the report: time, phase, features, decisions, actions, cursor.
    var frames = false
    var around: Double?
    var window = (before: 3.0, after: 0.5)
}

/// A set of thresholds for one replay: the layout and keys on top of the settings from the journal.
struct Variant {
    enum Preset: String {
        case journal, old, defaults
    }

    var name: String
    var preset = Preset.journal
    var overrides: [String: Any] = [:]

    var title: String {
        let keys = overrides.keys.sorted().map { "\($0)=\(overrides[$0]!)" }
        let preset = preset == .journal ? "journal" : "preset=\(preset.rawValue)"
        return ([preset] + keys).joined(separator: " ")
    }

    func validate() throws {
        let known = preset == .old ? LegacyGestureConfig.keys : GestureConfig.keys
        if let unknown = overrides.keys.sorted().first(where: { !known.contains($0) }) {
            throw ReplayError("no field \"\(unknown)\" in the \(preset == .old ? "legacy layout " : "")settings")
        }
    }

    /// Variant settings built from the journal's `config` record.
    func engine(for record: [String: Any], current: (any ReplayEngine)?) throws -> any ReplayEngine {
        var values = record
        let version = values["version"] as? Int ?? 1
        // Thresholds of one layout don't fit another: only the personal settings carry over.
        // The legacy layout wrote journals without a version, i.e. version 1.
        let keepsThresholds = preset == .old ? version < 2 : preset == .journal && version >= GestureConfig.currentVersion
        if !keepsThresholds { values = values.filter { GestureConfig.personalKeys.contains($0.key) } }
        if preset != .old { values["version"] = GestureConfig.currentVersion }
        for (key, value) in overrides { values[key] = value }
        let data = try JSONSerialization.data(withJSONObject: values)
        do {
            if preset == .old {
                var engine = current as? OldEngine ?? OldEngine()
                engine.engine.config = try JSONDecoder().decode(LegacyGestureConfig.self, from: data)
                return engine
            }
            var engine = current as? CurrentEngine ?? CurrentEngine()
            engine.engine.config = try JSONDecoder().decode(GestureConfig.self, from: data)
            return engine
        } catch {
            throw ReplayError("failed to decode the settings: \(error)")
        }
    }
}

// MARK: - Engines

protocol ReplayEngine {
    /// Drops low-confidence joints the same way the app did while recording.
    func visible(_ hand: HandPose) -> HandPose
    var phase: String { get }
    var notes: [String] { get }
    mutating func process(_ hand: HandPose?, other: HandPose?, time: Double, dark: Bool, limited: Bool) -> [PointerAction]
    mutating func handOver(at time: Double) -> [PointerAction]
    mutating func reset()
    /// What the engine looked at in this frame.
    func describe(_ hand: HandPose?) -> String
    /// How the replay cursor moved, if the engine drives one.
    var cursorSummary: String? { get }
}

extension ReplayEngine {
    var cursorSummary: String? { nil }
}

/// The replay cursor on a 16-inch MacBook Pro screen: moves stop at the screen edges, and a rewind returns to
/// where the move began, as in InputInjector. The engine uses it to keep the hand inside the work area.
struct SimulatedCursor {
    let size = CGSize(width: 1728, height: 1117)
    private(set) var location = CGPoint(x: 864, y: 558)
    private var origins: [(time: Double, location: CGPoint)] = []
    /// Moves that hit a screen edge, and the cursor's path length in points.
    private(set) var edgeHits = 0
    private(set) var path = 0.0

    var context: CursorContext {
        CursorContext(position: CGPoint(x: location.x / (size.width - 1), y: location.y / (size.height - 1)), size: size)
    }

    mutating func apply(_ actions: [PointerAction], time: Double) {
        for action in actions {
            switch action {
            case let .move(dx, dy):
                origins.removeAll { $0.time < time - 1 }
                origins.append((time, location))
                let target = CGPoint(x: location.x + dx, y: location.y + dy)
                let clamped = CGPoint(x: min(max(target.x, 0), size.width - 1), y: min(max(target.y, 0), size.height - 1))
                if clamped != target { edgeHits += 1 }
                path += hypot(clamped.x - location.x, clamped.y - location.y)
                location = clamped
            case let .rewind(since):
                guard let target = origins.first(where: { $0.time >= since })?.location else { continue }
                origins = []
                location = target
            default:
                break
            }
        }
    }
}

struct CurrentEngine: ReplayEngine {
    var engine = GestureEngine()
    var cursor = SimulatedCursor()

    func visible(_ hand: HandPose) -> HandPose { engine.config.visible(hand) }
    var phase: String { engine.phase.rawValue }
    var notes: [String] { engine.notes }

    var cursorSummary: String? {
        String(format: "cursor: path %.0fk points, screen edge hits %ld", cursor.path / 1000, cursor.edgeHits)
    }

    mutating func process(_ hand: HandPose?, other: HandPose?, time: Double, dark: Bool, limited: Bool) -> [PointerAction] {
        if engine.isLowLight != dark { engine.isLowLight = dark }
        engine.isExposureLimited = limited
        engine.cursor = cursor.context
        let actions = engine.process(hand: hand, other: other, time: time)
        cursor.apply(actions, time: time)
        return actions
    }

    mutating func handOver(at time: Double) -> [PointerAction] {
        let actions = engine.handOver(at: time)
        cursor.apply(actions, time: time)
        return actions
    }
    mutating func reset() { engine.reset() }

    func describe(_ hand: HandPose?) -> String {
        let f = engine.features
        func number(_ value: Double?) -> String { value.map { String(format: "%4.2f", $0) } ?? "  - " }
        func flag(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no " } ?? " - " }
        let finger = switch f.finger {
        case .indexTip?: "idx "
        case .middleTip?: "mid "
        default: "  - "
        }
        return String(format: "%-9@ gap %@ %@ speed %5.1f travel %@ length %@ edge %@ fist %@ two %@ joints %2ld",
                      phase as NSString, number(f.gap) as NSString, finger as NSString, f.speed, number(f.travel) as NSString,
                      number(f.fingerLength) as NSString, number(f.edgeRatio) as NSString, flag(f.fist) as NSString,
                      flag(f.twoFingers) as NSString, hand?.visibleJointCount ?? 0)
    }
}

struct OldEngine: ReplayEngine {
    var engine = LegacyGestureEngine()

    func visible(_ hand: HandPose) -> HandPose { hand.filtered(minConfidence: 0.3) }
    var phase: String { engine.phase.rawValue }
    var notes: [String] { [] }

    mutating func process(_ hand: HandPose?, other: HandPose?, time: Double, dark: Bool, limited: Bool) -> [PointerAction] {
        if engine.isLowLight != dark { engine.isLowLight = dark }
        return engine.process(hand: hand, time: time).map(\.current)
    }

    mutating func handOver(at time: Double) -> [PointerAction] { engine.handOver(at: time).map(\.current) }
    mutating func reset() { engine.reset() }

    func describe(_ hand: HandPose?) -> String {
        func gap(_ tip: HandJoint) -> String { hand?.pinchRatio(tip).map { String(format: "%4.2f", $0) } ?? "  - " }
        return String(format: "%-9@ index %@ middle %@ joints %2ld", phase as NSString, gap(.indexTip) as NSString,
                      gap(.middleTip) as NSString, hand?.visibleJointCount ?? 0)
    }
}

// MARK: - Journal

struct Journal {
    let name: String
    let records: [[String: Any]]
    /// Time of the first frame: the report's seconds are counted from it.
    let start: Double
    let version: Int
    var marks: [(kind: String, time: Double)] {
        records.compactMap { record in
            guard let kind = record["k"] as? String, kind == "mark" || kind == "miss", let time = record["t"] as? Double else { return nil }
            return (kind, time)
        }
    }

    init(path: String) throws {
        name = (path as NSString).lastPathComponent
        let text = try String(contentsOfFile: path, encoding: .utf8)
        records = text.split(separator: "\n").compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
        start = records.first { $0["k"] as? String == "frame" }?["t"] as? Double ?? 0
        let config = records.first { $0["k"] as? String == "config" }?["config"] as? [String: Any]
        version = config?["version"] as? Int ?? 1
    }

    /// A hand from a journal frame with all the recorded joints. Journals from before 1 November 2026 have no
    /// confidences: they record only the joints that passed the 0.3 threshold, and those get confidence 1.
    static func pose(_ record: [String: Any], key suffix: String = "") -> HandPose? {
        guard let values = record["hand" + suffix] as? [Any], let aspect = record["aspect"] as? Double else { return nil }
        let levels = record["conf" + suffix] as? [Double]
        var points: [HandJoint: CGPoint] = [:]
        var confidences: [HandJoint: Double] = [:]
        for joint in HandJoint.allCases {
            let index = joint.rawValue * 2
            guard index + 1 < values.count, let x = values[index] as? Double, let y = values[index + 1] as? Double else { continue }
            points[joint] = CGPoint(x: x, y: y)
            if let levels, joint.rawValue < levels.count { confidences[joint] = levels[joint.rawValue] }
        }
        let side = (record["side"] as? String).flatMap(Chirality.init(rawValue:))
        return HandPose(points: points, confidences: confidences, chirality: side, aspect: aspect)
    }
}

// MARK: - Replay

struct GestureEvent {
    enum Kind: String, CaseIterable {
        case click = "click", double = "double", drag = "drag", right = "right", scroll = "scroll", rewind = "rewind"
    }

    var kind: Kind
    var start: Double
    var end: Double
    /// How many points the cursor moved with the button held, or how many pixels were scrolled.
    var path = 0.0
    var activity: String
    var context: String

    static let csvHeader = "journal,variant,kind,start,end,duration,path,activity"

    func csv(journal: String, variant: String, start origin: Double) -> String {
        String(format: "%@,%@,%@,%.3f,%.3f,%.3f,%.0f,%@", journal, variant, kind.rawValue, start - origin, end - origin,
               end - start, path, activity)
    }
}

struct Run {
    let variant: Variant
    let options: Options
    private(set) var engine: any ReplayEngine = CurrentEngine()
    private(set) var events: [GestureEvent] = []
    private(set) var frames = 0
    private(set) var matched = 0
    /// Comparing with the journal only makes sense if the variant repeats what was running during recording.
    let checksJournal: Bool
    private(set) var details: [String] = []
    private(set) var frameRows: [String] = []
    private(set) var phaseTime: [String: Double] = [:]
    private(set) var noteCounts: [String: Int] = [:]
    private(set) var handTime = 0.0
    private(set) var shadowTime = 0.0
    private(set) var activityTime: [String: Double] = [:]
    private var activity = "unspecified"
    private var lastFrame: Double?
    private var press: (time: Double, path: Double, context: String)?
    private var scroll: (time: Double, path: Double, context: String)?
    private var lastClick: Double?

    init(variant: Variant, journal: Journal, options: Options) throws {
        self.variant = variant
        self.options = options
        checksJournal = variant.overrides.isEmpty
            && (variant.preset == .old ? journal.version < 2
                : variant.preset == .journal && journal.version >= GestureConfig.currentVersion)
        // A journal without a settings record: default thresholds.
        engine = try variant.engine(for: [:], current: nil)
        for record in journal.records where record["k"] as? String == "config" {
            engine = try variant.engine(for: record["config"] as? [String: Any] ?? [:], current: nil)
            break
        }
    }

    mutating func replay(_ journal: Journal) {
        var configured = false
        for record in journal.records {
            guard let kind = record["k"] as? String, let time = record["t"] as? Double else { continue }
            switch kind {
            case "config":
                // The first record was already applied at creation; later ones change the thresholds mid-journal.
                if configured, let config = record["config"] as? [String: Any],
                   let updated = try? variant.engine(for: config, current: engine) {
                    engine = updated
                }
                configured = true
            case "reset":
                engine.reset()
                closePress(at: time)
            case "handover":
                track(engine.handOver(at: time), time: time, hand: nil)
            case "activity":
                activity = record["label"] as? String ?? "unspecified"
            case "frame":
                guard (record["fed"] as? Int) == 1 else {
                    lastFrame = nil
                    continue
                }
                let raw = Journal.pose(record)
                let hand = raw.map(engine.visible)
                let other = Journal.pose(record, key: "2").map(engine.visible)
                let actions = engine.process(hand, other: other, time: time, dark: (record["dark"] as? Int) == 1,
                                             limited: (record["ael"] as? Int) == 1)
                frames += 1
                let logged = (record["acts"] as? [String] ?? []).map(Self.kind)
                if actions.map(GestureRecorderFormat.describe).map(Self.kind) == logged { matched += 1 }
                let dt = lastFrame.map { min(time - $0, 0.1) } ?? 0
                lastFrame = time
                phaseTime[engine.phase, default: 0] += dt
                if hand != nil {
                    handTime += dt
                    activityTime[activity, default: 0] += dt
                }
                if (record["out"] as? Int) == 0 { shadowTime += dt }
                for note in engine.notes { noteCounts[Self.noteKind(note), default: 0] += 1 }
                track(actions, time: time, hand: hand)
                if options.frames, let current = engine as? CurrentEngine {
                    let f = current.engine.features
                    func number(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "" }
                    func flag(_ value: Bool?) -> String { value.map { $0 ? "1" : "0" } ?? "" }
                    let finger = f.finger == .indexTip ? "i" : f.finger == .middleTip ? "m" : ""
                    let acts = actions.map(GestureRecorderFormat.describe).map(Self.kind).joined(separator: " ")
                    frameRows.append([String(format: "%.3f", time - journal.start), engine.phase, number(f.gap), finger,
                                      number(f.speed), number(f.travel), number(f.fingerLength), number(f.edgeRatio),
                                      flag(f.fist), flag(f.twoFingers), flag(f.twoFingersHold), number(f.pinkyGap),
                                      "\(hand?.visibleJointCount ?? 0)",
                                      engine.notes.joined(separator: ";"), acts,
                                      String(format: "%.1f", actions.reduce(0.0) { sum, action in
                                          if case let .scroll(_, dy, _) = action { return sum + dy }
                                          return sum
                                      }),
                                      String(format: "%.0f", current.cursor.location.x),
                                      String(format: "%.0f", current.cursor.location.y)].joined(separator: ","))
                }
                if let around = options.around, abs(time - journal.start - around) <= 1.5 {
                    let acts = actions.map(GestureRecorderFormat.describe).joined(separator: "; ")
                    let notes = engine.notes.isEmpty ? "" : " [" + engine.notes.joined(separator: ", ") + "]"
                    details.append(String(format: "%7.2f  ", time - journal.start) + engine.describe(hand) + "  " + acts + notes)
                }
            default:
                break
            }
        }
    }

    /// Splits actions into events: click (press and release without cursor travel), drag, double-click,
    /// right-click, scroll and cursor rewind.
    private mutating func track(_ actions: [PointerAction], time: Double, hand: HandPose?) {
        for action in actions {
            switch action {
            case .leftDown:
                press = (time, 0, engine.describe(hand))
            case let .move(dx, dy):
                if press != nil { press?.path += hypot(dx, dy) }
            case .moveTo:
                break
            case .leftUp:
                guard let started = press else { continue }
                press = nil
                if started.path < 6 {
                    let isDouble = lastClick.map { time - $0 <= 0.5 } ?? false
                    events.append(GestureEvent(kind: isDouble ? .double : .click, start: started.time, end: time,
                                               path: started.path, activity: activity, context: started.context))
                    lastClick = isDouble ? nil : time
                } else {
                    events.append(GestureEvent(kind: .drag, start: started.time, end: time, path: started.path,
                                               activity: activity, context: started.context))
                    lastClick = nil
                }
            case .rightClick:
                events.append(GestureEvent(kind: .right, start: time, end: time, activity: activity, context: engine.describe(hand)))
            case let .scroll(dx, dy, phase):
                switch phase {
                case .began: scroll = (time, hypot(dx, dy), engine.describe(hand))
                case .changed: scroll?.path += hypot(dx, dy)
                case .ended:
                    if let started = scroll {
                        events.append(GestureEvent(kind: .scroll, start: started.time, end: time, path: started.path,
                                                   activity: activity, context: started.context))
                    }
                    scroll = nil
                case .momentumBegan, .momentum, .momentumEnded: break
                }
            case .rewind:
                events.append(GestureEvent(kind: .rewind, start: time, end: time, activity: activity, context: engine.describe(hand)))
            }
        }
    }

    /// A reset (pause for the keyboard, gestures turned off) releases the button.
    private mutating func closePress(at time: Double) {
        guard press != nil else { return }
        track([.leftUp], time: time, hand: nil)
    }

    func count(_ kind: GestureEvent.Kind) -> Int {
        events.count { $0.kind == kind }
    }

    /// Kind of an action without numbers: coordinates in the journal are rounded, so replayed moves differ slightly.
    static func kind(_ description: String) -> String {
        let words = description.split(separator: " ")
        return words.first == "scroll" ? "scroll \(words.last ?? "")" : String(words.first ?? "")
    }

    /// A decision without details: "pinch blocked: speed" and "pinch blocked: rearm" count separately, no numbers.
    static func noteKind(_ note: String) -> String { note }
}

/// The same action notation as in `GestureRecorder.describe`.
enum GestureRecorderFormat {
    static func describe(_ action: PointerAction) -> String {
        switch action {
        case let .move(dx, dy): String(format: "move %.4f %.4f", dx, dy)
        case let .moveTo(x, y): String(format: "moveTo %.4f %.4f", x, y)
        case .leftDown: "down"
        case .leftUp: "up"
        case .rightClick: "right"
        case let .scroll(dx, dy, phase): String(format: "scroll %.4f %.4f ", dx, dy) + "\(phase)"
        case let .rewind(since): String(format: "rewind %.4f", since)
        }
    }
}

// MARK: - Report

struct Totals {
    var handTime = 0.0
    var counts: [GestureEvent.Kind: Int] = [:]
    var activityTime: [String: Double] = [:]
    var activityCounts: [String: [GestureEvent.Kind: Int]] = [:]

    mutating func add(_ run: Run) {
        handTime += run.handTime
        for (label, time) in run.activityTime { activityTime[label, default: 0] += time }
        for event in run.events {
            counts[event.kind, default: 0] += 1
            activityCounts[event.activity, default: [:]][event.kind, default: 0] += 1
        }
    }
}

enum Report {
    static let kinds: [GestureEvent.Kind] = [.click, .double, .drag, .right, .scroll, .rewind]

    static func single(_ journal: Journal, runs: [Run], options: Options) {
        let first = runs[0]
        let shadow = first.handTime > 0 ? Int((first.shadowTime / max(first.phaseTime.values.reduce(0, +), 0.001) * 100).rounded()) : 0
        print(String(format: "Journal %@: hand in frame %.1f s, engine frames %ld, shadow %ld%%", journal.name, first.handTime,
                     first.frames, shadow))
        for run in runs {
            print("")
            var title = "Variant \(run.variant.name) (\(run.variant.title))"
            if run.checksJournal { title += ": \(run.matched) of \(run.frames) frames match the journal" }
            print(title)
            print("  " + counts(run.events, hours: run.handTime / 3600))
            let phases = run.phaseTime.sorted { $0.value > $1.value }.map { phase, time in
                String(format: "%@ %.0f%%", phase, time / max(run.phaseTime.values.reduce(0, +), 0.001) * 100)
            }
            print("  phases: " + phases.joined(separator: ", "))
            if let cursor = run.engine.cursorSummary { print("  " + cursor) }
            if !run.noteCounts.isEmpty {
                print("  decisions: " + run.noteCounts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            }
            if !run.events.isEmpty {
                print("")
                print("     time  event       dur   path  at start")
                for event in run.events {
                    print(String(format: "  %7.2f  %-9@  %4.2f  %5.0f  ", event.end - journal.start, event.kind.rawValue as NSString,
                                 event.end - event.start, event.path) + event.context)
                }
            }
        }
        if runs.count == 2 { compare(runs[0], runs[1], journal: journal) }
        marks(journal, runs: runs, options: options)
        for run in runs where !run.details.isEmpty {
            print("\nFrames of variant \(run.variant.name) around \(options.around ?? 0) s:")
            run.details.forEach { print($0) }
        }
    }

    static func line(_ journal: Journal, runs: [Run]) {
        let parts = runs.map { "\($0.variant.name): " + counts($0.events, hours: $0.handTime / 3600) }
        print(String(format: "%@  hand %.0f s  ", journal.name, runs[0].handTime) + parts.joined(separator: "  |  "))
    }

    static func totals(_ totals: [Totals], variants: [Variant]) {
        for (variant, total) in zip(variants, totals) {
            print("\nTotal for variant \(variant.name) (\(variant.title)), hand in frame \(String(format: "%.1f", total.handTime / 3600)) h:")
            print("  " + rates(total.counts, hours: total.handTime / 3600))
            for (label, time) in total.activityTime.sorted(by: { $0.value > $1.value }) {
                print(String(format: "  %-13@ %5.1f h  ", label as NSString, time / 3600) + rates(total.activityCounts[label] ?? [:], hours: time / 3600))
            }
        }
    }

    static func counts(_ events: [GestureEvent], hours: Double) -> String {
        var counts: [GestureEvent.Kind: Int] = [:]
        for event in events { counts[event.kind, default: 0] += 1 }
        return rates(counts, hours: hours)
    }

    /// Counts with a rate per hour of hand-in-frame time. For zero, the upper 95% bound by the rule of three: 3/T.
    static func rates(_ counts: [GestureEvent.Kind: Int], hours: Double) -> String {
        kinds.map { kind in
            let count = counts[kind] ?? 0
            guard hours > 0 else { return "\(kind.rawValue) \(count)" }
            return count == 0 ? String(format: "%@ 0 (<%.1f/h)", kind.rawValue, 3 / hours)
                : String(format: "%@ %ld (%.1f/h)", kind.rawValue, count, Double(count) / hours)
        }.joined(separator: ", ")
    }

    /// Pairwise comparison on the same frames: events are matched by end time with a 150 ms tolerance.
    static func compare(_ a: Run, _ b: Run, journal: Journal) {
        var unmatched = Array(b.events.indices)
        var lines: [String] = []
        for event in a.events {
            let nearest = unmatched.min { abs(b.events[$0].end - event.end) < abs(b.events[$1].end - event.end) }
            guard let index = nearest, abs(b.events[index].end - event.end) <= 0.15 else {
                lines.append(String(format: "  %7.2f  missing in B: %@", event.end - journal.start, event.kind.rawValue))
                continue
            }
            unmatched.removeAll { $0 == index }
            if b.events[index].kind != event.kind {
                lines.append(String(format: "  %7.2f  changed kind: %@ became %@", event.end - journal.start, event.kind.rawValue,
                                    b.events[index].kind.rawValue))
            }
        }
        for index in unmatched {
            lines.append(String(format: "  %7.2f  appeared in B: %@", b.events[index].end - journal.start, b.events[index].kind.rawValue))
        }
        print("\nA vs B on the same frames: \(lines.isEmpty ? "identical" : "\(lines.count) difference(s)")")
        lines.sorted().forEach { print($0) }
    }

    /// A window around each human mark: what happened nearby and the last event of each kind before it.
    static func marks(_ journal: Journal, runs: [Run], options: Options) {
        let marks = journal.marks
        guard !marks.isEmpty else { return }
        let falses = marks.count { $0.kind == "mark" }
        print("\nMarks ⌃⌥⌘M (false trigger): \(falses), ⌃⌥⌘N (miss): \(marks.count - falses); window \(options.window.before) s before and \(options.window.after) s after")
        for mark in marks {
            print(String(format: "\n  %7.2f  %@", mark.time - journal.start, mark.kind == "mark" ? "false trigger" : "miss"))
            for run in runs {
                let inside = run.events.filter { $0.end >= mark.time - options.window.before && $0.end <= mark.time + options.window.after }
                let near = inside.map { String(format: "%.2f %@", $0.end - journal.start, $0.kind.rawValue) }
                let last = kinds.compactMap { kind in
                    run.events.last { $0.kind == kind && $0.end <= mark.time }.map { String(format: "%@ %.2f", kind.rawValue, $0.end - journal.start) }
                }
                print("    \(run.variant.name): events nearby: " + (near.isEmpty ? "none" : near.joined(separator: ", "))
                      + "; last before it: " + (last.isEmpty ? "none" : last.joined(separator: ", ")))
                for event in inside { print("       " + event.context) }
            }
        }
    }
}
