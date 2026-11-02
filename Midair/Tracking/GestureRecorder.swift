import Foundation

/// Gesture engine log for analyzing false triggers: every hand pose with Vision confidences, the engine phase,
/// its actions and decisions in words, plus the person's marks (⌃⌥⌘M false trigger, ⌃⌥⌘N miss) and activity
/// labels. The poses are enough to replay the engine with different thresholds (`Tools/GestureReplay.swift`).
/// The log has no camera frames, only joint coordinates.
///
/// JSON Lines format: one object per line, the `k` field sets the record type. Written only from the pipeline queue.
final class GestureRecorder {
    let url: URL
    private let handle: FileHandle
    private var buffer = ""
    private var lastFlush = Date()

    init() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Midair", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A log is started on every activation of gestures or the shadow log: keep the 29 previous ones, 30 with the new one.
        // Records needed for longer should be moved to another folder.
        let journals = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("gestures-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in journals.dropFirst(29) {
            try? FileManager.default.removeItem(at: old)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        url = directory.appending(path: "gestures-\(formatter.string(from: Date())).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func config(_ config: GestureConfig, time: Double) {
        let json = (try? JSONEncoder().encode(config)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        append(#"{"k":"config","t":\#(Self.number(time)),"config":\#(json)}"#)
    }

    /// A frame of the leading camera. `hand` is taken before low-confidence points are cut off (the engine does that),
    /// so here all points come with confidences. `fed` is false when the engine didn't see the frame: gestures are
    /// paused (`sus`) because the person reached for the keyboard or mouse. `out` means the actions went to the system,
    /// not just to the window: without it the log is a shadow one.
    func frame(time: Double, source: CameraSource, hand: HandPose?, other: HandPose?, dark: Bool, brightness: Double?, lux: Double?,
               exposureLimited: Bool?, fed: Bool, out: Bool, suspended: Bool, phase: GesturePhase,
               actions: [PointerAction], notes: [String]) {
        var line = #"{"k":"frame","t":\#(Self.number(time)),"src":"\#(source)","dark":\#(dark ? 1 : 0)"#
        line += #","bright":\#(brightness.map(Self.number) ?? "null"),"lux":\#(lux.map(Self.number) ?? "null")"#
        line += #","ael":\#(exposureLimited.map { $0 ? "1" : "0" } ?? "null")"#
        line += #","fed":\#(fed ? 1 : 0),"out":\#(out ? 1 : 0),"sus":\#(suspended ? 1 : 0)"#
        if let hand {
            line += #","aspect":\#(Self.number(hand.aspect)),"side":\#(hand.chirality.map { "\"\($0.rawValue)\"" } ?? "null")"#
            line += Self.joints(hand, key: "")
        } else {
            line += #","hand":null"#
        }
        // The second hand is recorded only when it's in the frame: its fist holds two-handed scrolling.
        if let other { line += Self.joints(other, key: "2") }
        line += #","phase":"\#(phase.rawValue)","acts":\#(Self.list(actions))"#
        if !notes.isEmpty { line += #","why":\#(Self.strings(notes))"# }
        append(line + "}")
    }

    /// An event without a frame: `reset`, `handover`, `mark` (the person's false trigger mark), `miss` (a gesture
    /// didn't work) or `activity` with the activity label in `label`.
    func event(_ kind: String, time: Double, actions: [PointerAction] = [], label: String? = nil) {
        let extra = label.map { #","label":"\#($0)""# } ?? ""
        append(#"{"k":"\#(kind)","t":\#(Self.number(time)),"acts":\#(Self.list(actions))\#(extra)}"#)
    }

    func close() {
        flush()
        try? handle.close()
    }

    private func append(_ line: String) {
        buffer += line
        buffer += "\n"
        if buffer.utf8.count > 64 * 1024 || Date().timeIntervalSince(lastFlush) > 1 { flush() }
    }

    private func flush() {
        lastFlush = Date()
        guard !buffer.isEmpty else { return }
        try? handle.write(contentsOf: Data(buffer.utf8))
        buffer = ""
    }

    /// Hand joints and confidences: `hand` and `conf`, for the second hand `hand2` and `conf2`.
    private static func joints(_ hand: HandPose, key suffix: String) -> String {
        let joints = HandJoint.allCases.map { joint in
            hand[joint].map { "\(number(Double($0.x))),\(number(Double($0.y)))" } ?? "null,null"
        }
        // Round down to hundredths: a point passes the confidence threshold in the replay exactly when it did in the app.
        let confidences = hand.confidences.map { String(format: "%.2f", ($0 * 100).rounded(.down) / 100) }
        return #","hand\#(suffix)":[\#(joints.joined(separator: ","))],"conf\#(suffix)":[\#(confidences.joined(separator: ","))]"#
    }

    private static func list(_ actions: [PointerAction]) -> String {
        strings(actions.map(describe))
    }

    private static func strings(_ values: [String]) -> String {
        "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    /// The same action record as in `Tools/GestureReplay.swift`: the replay checks itself against the log with it.
    static func describe(_ action: PointerAction) -> String {
        switch action {
        case let .move(dx, dy): "move \(number(dx)) \(number(dy))"
        case let .moveTo(x, y): "moveTo \(number(x)) \(number(y))"
        case .leftDown: "down"
        case .leftUp: "up"
        case .rightClick: "right"
        case let .scroll(dx, dy, phase): "scroll \(number(dx)) \(number(dy)) \(phase)"
        case let .rewind(since): "rewind \(number(since))"
        }
    }

    static func number(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

}
