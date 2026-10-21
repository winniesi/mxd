import Foundation

struct Config: Codable {
    var dpi: Int? = 1000
    /// "freespin" | "ratchet" | "unchanged"
    var wheel: String = "freespin"
    /// "cycle_desktops" | "mission_control" | "none"
    var modeShift: String = "cycle_desktops"
    /// "mission_control" | "cycle_desktops" | "passthrough"
    var middle: String = "mission_control"
    var backForward: BackForward = BackForward()

    struct BackForward: Codable {
        /// Apps that don't understand mouse buttons 4/5 natively; they get Cmd+[ / Cmd+] instead.
        var keyboardNavApps: [String] = ["com.apple.finder", "com.apple.Safari"]
    }

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mxd/config.json")

    static func load() -> Config {
        guard let data = try? Data(contentsOf: path) else {
            log("no config at \(path.path), using defaults")
            return Config()
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            log("config parse error: \(error), using defaults")
            return Config()
        }
    }
}

extension Config {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        dpi = try c.decodeIfPresent(Int.self, forKey: .dpi) ?? d.dpi
        wheel = try c.decodeIfPresent(String.self, forKey: .wheel) ?? d.wheel
        modeShift = try c.decodeIfPresent(String.self, forKey: .modeShift) ?? d.modeShift
        middle = try c.decodeIfPresent(String.self, forKey: .middle) ?? d.middle
        backForward = try c.decodeIfPresent(BackForward.self, forKey: .backForward) ?? d.backForward
    }
}

extension Config.BackForward {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyboardNavApps = try c.decodeIfPresent([String].self, forKey: .keyboardNavApps)
            ?? Config.BackForward().keyboardNavApps
    }
}
