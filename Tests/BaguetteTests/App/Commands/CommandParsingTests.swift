import Testing
import ArgumentParser
@testable import Baguette

/// Parses each subcommand from argv and asserts the @Option/@OptionGroup
/// wiring + CommandConfiguration metadata. `run()` itself talks to
/// CoreSimulators / stdin / signals, so it stays out of coverage by
/// design — these tests only pin the structure.
@Suite("CommandParsing")
struct CommandParsingTests {

    // MARK: - root

    @Test func `baguette root lists every subcommand`() {
        let cfg = Baguette.configuration
        #expect(cfg.commandName == "baguette")
        let names = cfg.subcommands.map { $0.configuration.commandName }
        #expect(Set(names) == [
            "list", "boot", "shutdown", "input", "stream",
            "tap", "double-tap", "swipe", "pinch", "pan", "press",
            "key", "type", "paste", "clipboard",
            "chrome", "screenshot", "describe-ui", "logs", "serve",
            "orientation", "status-bar", "location", "install", "add-media",
            "openurl", "schemes",
            "diag-digitizer-trackpad",
        ])
    }

    // MARK: - openurl / schemes

    @Test func `openurl parses the url argument`() throws {
        let cmd = try OpenURLCommand.parse(["--udid", "U", "myapp://profile/42"])
        #expect(cmd.url == "myapp://profile/42")
        #expect(OpenURLCommand.configuration.commandName == "openurl")
    }

    @Test func `openurl requires a url`() {
        #expect(throws: (any Error).self) { try OpenURLCommand.parse(["--udid", "U"]) }
    }

    @Test func `schemes parses --udid`() throws {
        let cmd = try SchemesCommand.parse(["--udid", "U"])
        #expect(cmd.options.udid == "U")
        #expect(SchemesCommand.configuration.commandName == "schemes")
    }

    @Test func `baguette root exposes version`() {
        #expect(Baguette.configuration.version == baguetteVersion)
        #expect(!baguetteVersion.isEmpty)
    }

    // MARK: - list

    @Test func `list parses --device-set`() throws {
        let cmd = try ListCommand.parse(["--device-set", "/tmp/set"])
        #expect(cmd.deviceSet == "/tmp/set")
        #expect(ListCommand.configuration.commandName == "list")
    }

    @Test func `list defaults device-set to nil`() throws {
        let cmd = try ListCommand.parse([])
        #expect(cmd.deviceSet == nil)
        #expect(cmd.json == false)
    }

    @Test func `list parses --json flag`() throws {
        let cmd = try ListCommand.parse(["--json"])
        #expect(cmd.json == true)
    }

    // MARK: - boot / shutdown share DeviceOption

    @Test func `boot requires --udid`() throws {
        let cmd = try BootCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.options.deviceSet == nil)
        #expect(BootCommand.configuration.commandName == "boot")
    }

    @Test func `boot rejects argv without --udid`() {
        #expect(throws: (any Error).self) {
            try BootCommand.parse([])
        }
    }

    @Test func `shutdown carries udid + device-set`() throws {
        let cmd = try ShutdownCommand.parse([
            "--udid", "XYZ", "--device-set", "/var/sims",
        ])
        #expect(cmd.options.udid == "XYZ")
        #expect(cmd.options.deviceSet == "/var/sims")
        #expect(ShutdownCommand.configuration.commandName == "shutdown")
    }

    // MARK: - input

    @Test func `input parses --udid`() throws {
        let cmd = try InputCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(InputCommand.configuration.commandName == "input")
    }

    // MARK: - orientation

    @Test func `orientation parses portrait`() throws {
        let cmd = try OrientationCommand.parse(["--udid", "U", "portrait"])
        #expect(cmd.options.udid == "U")
        #expect(cmd.value == .portrait)
        #expect(OrientationCommand.configuration.commandName == "orientation")
    }

    @Test func `orientation parses landscape-left`() throws {
        let cmd = try OrientationCommand.parse(["--udid", "U", "landscape-left"])
        #expect(cmd.value == .landscapeLeft)
    }

    @Test func `orientation parses landscape-right`() throws {
        let cmd = try OrientationCommand.parse(["--udid", "U", "landscape-right"])
        #expect(cmd.value == .landscapeRight)
    }

    @Test func `orientation parses portrait-upside-down`() throws {
        let cmd = try OrientationCommand.parse(["--udid", "U", "portrait-upside-down"])
        #expect(cmd.value == .portraitUpsideDown)
    }

    @Test func `orientation rejects unknown values`() {
        #expect(throws: (any Error).self) {
            try OrientationCommand.parse(["--udid", "U", "sideways"])
        }
    }

    @Test func `orientation rejects argv without --udid`() {
        #expect(throws: (any Error).self) {
            try OrientationCommand.parse(["portrait"])
        }
    }

    // MARK: - status-bar

    @Test func `status-bar lists override and clear leaves`() {
        let names = StatusBarCommand.configuration.subcommands.map { $0.configuration.commandName }
        #expect(Set(names) == ["override", "clear"])
        #expect(StatusBarCommand.configuration.commandName == "status-bar")
    }

    @Test func `status-bar override parses every field into a typed override`() throws {
        let cmd = try StatusBarCommand.Override.parse([
            "--udid", "U",
            "--time", "9:41",
            "--operator-name", "Baguette",
            "--data-network", "5g",
            "--wifi-mode", "active",
            "--wifi-bars", "3",
            "--cellular-mode", "active",
            "--cellular-bars", "4",
            "--battery-state", "charged",
            "--battery-level", "68",
        ])
        #expect(cmd.options.udid == "U")
        #expect(cmd.override == StatusBarOverride(
            time: "9:41",
            operatorName: "Baguette",
            dataNetwork: .fiveG,
            wifiMode: .active,
            wifiBars: 3,
            cellularMode: .active,
            cellularBars: 4,
            batteryState: .charged,
            batteryLevel: 68
        ))
    }

    @Test func `status-bar override with no fields builds an empty override`() throws {
        let cmd = try StatusBarCommand.Override.parse(["--udid", "U"])
        #expect(cmd.override.isEmpty)
    }

    @Test func `status-bar override rejects an unknown data network`() {
        #expect(throws: (any Error).self) {
            try StatusBarCommand.Override.parse(["--udid", "U", "--data-network", "6g"])
        }
    }

    @Test func `status-bar override requires --udid`() {
        #expect(throws: (any Error).self) {
            try StatusBarCommand.Override.parse(["--battery-level", "50"])
        }
    }

    @Test func `status-bar clear parses --udid`() throws {
        let cmd = try StatusBarCommand.Clear.parse(["--udid", "U"])
        #expect(cmd.options.udid == "U")
        #expect(StatusBarCommand.Clear.configuration.commandName == "clear")
    }

    // MARK: - location

    @Test func `location lists set start walk and clear leaves`() {
        let names = LocationCommand.configuration.subcommands.map { $0.configuration.commandName }
        #expect(Set(names) == ["set", "start", "walk", "clear"])
        #expect(LocationCommand.configuration.commandName == "location")
    }

    @Test func `location set parses a lat,lon token into a coordinate`() throws {
        let cmd = try LocationCommand.Set.parse(["--udid", "U", "37.3318,-122.0312"])
        #expect(cmd.options.udid == "U")
        #expect(cmd.coordinate == Coordinate(latitude: 37.3318, longitude: -122.0312))
        #expect(LocationCommand.Set.configuration.commandName == "set")
    }

    @Test func `location set rejects an out-of-range coordinate`() throws {
        let cmd = try LocationCommand.Set.parse(["--udid", "U", "120,0"])
        #expect(cmd.coordinate == nil)
    }

    @Test func `location set requires --udid`() {
        #expect(throws: (any Error).self) {
            try LocationCommand.Set.parse(["1,2"])
        }
    }

    @Test func `location start parses waypoints and tuning into a route`() throws {
        let cmd = try LocationCommand.Start.parse([
            "--udid", "U", "--speed", "260", "--distance", "1000",
            "37.6,-122.4", "40.6,-73.8",
        ])
        #expect(cmd.route == LocationRoute(
            waypoints: [
                Coordinate(latitude: 37.6, longitude: -122.4)!,
                Coordinate(latitude: 40.6, longitude: -73.8)!,
            ],
            speed: 260, distance: 1000
        ))
    }

    @Test func `location start with a single waypoint builds no route`() throws {
        let cmd = try LocationCommand.Start.parse(["--udid", "U", "37.6,-122.4"])
        #expect(cmd.route == nil)
    }

    @Test func `location walk parses a bearing and speed into a vector`() throws {
        let cmd = try LocationCommand.Walk.parse([
            "--udid", "U", "--bearing", "90", "--speed", "5", "37.3349,-122.0090",
        ])
        #expect(cmd.options.udid == "U")
        #expect(cmd.walk == LocationWalk(
            origin: Coordinate(latitude: 37.3349, longitude: -122.0090)!,
            bearing: Bearing(degrees: 90),
            speed: 5
        ))
        #expect(LocationCommand.Walk.configuration.commandName == "walk")
    }

    @Test func `location walk normalises a bearing off the compass circle`() throws {
        let cmd = try LocationCommand.Walk.parse([
            "--udid", "U", "--bearing", "450", "--speed", "5", "1,2",
        ])
        #expect(cmd.walk?.bearing == Bearing(degrees: 90))
    }

    @Test func `location walk builds no vector for a non-positive speed`() throws {
        let cmd = try LocationCommand.Walk.parse([
            "--udid", "U", "--bearing", "0", "--speed", "0", "1,2",
        ])
        #expect(cmd.walk == nil)
    }

    @Test func `location walk builds no vector from an out-of-range origin`() throws {
        let cmd = try LocationCommand.Walk.parse([
            "--udid", "U", "--bearing", "0", "--speed", "5", "120,0",
        ])
        #expect(cmd.walk == nil)
    }

    @Test func `location clear parses --udid`() throws {
        let cmd = try LocationCommand.Clear.parse(["--udid", "U"])
        #expect(cmd.options.udid == "U")
        #expect(LocationCommand.Clear.configuration.commandName == "clear")
    }

    // MARK: - paste

    @Test func `paste parses --text and defaults to pressing`() throws {
        let cmd = try PasteCommand.parse(["--udid", "U", "--text", "héllo 🥖"])
        #expect(cmd.options.udid == "U")
        #expect(cmd.text == "héllo 🥖")
        #expect(cmd.press == true)
        #expect(PasteCommand.configuration.commandName == "paste")
    }

    @Test func `paste parses --no-press`() throws {
        let cmd = try PasteCommand.parse(["--udid", "U", "--text", "x", "--no-press"])
        #expect(cmd.press == false)
    }

    @Test func `paste requires --text`() {
        #expect(throws: (any Error).self) {
            try PasteCommand.parse(["--udid", "U"])
        }
    }

    @Test func `paste requires --udid`() {
        #expect(throws: (any Error).self) {
            try PasteCommand.parse(["--text", "x"])
        }
    }

    // MARK: - clipboard

    @Test func `clipboard lists get, sync and copy leaves`() {
        let names = ClipboardCommand.configuration.subcommands.map { $0.configuration.commandName }
        #expect(Set(names) == ["get", "sync", "copy"])
        #expect(ClipboardCommand.configuration.commandName == "clipboard")
    }

    @Test func `clipboard copy parses --udid`() throws {
        let cmd = try ClipboardCommand.Copy.parse(["--udid", "U"])
        #expect(cmd.options.udid == "U")
        #expect(ClipboardCommand.Copy.configuration.commandName == "copy")
    }

    @Test func `clipboard get parses --udid`() throws {
        let cmd = try ClipboardCommand.Get.parse(["--udid", "U"])
        #expect(cmd.options.udid == "U")
        #expect(ClipboardCommand.Get.configuration.commandName == "get")
    }

    @Test func `clipboard sync parses --udid`() throws {
        let cmd = try ClipboardCommand.Sync.parse(["--udid", "U"])
        #expect(cmd.options.udid == "U")
        #expect(ClipboardCommand.Sync.configuration.commandName == "sync")
    }

    // MARK: - install / add-media

    @Test func `install parses --udid and a file path`() throws {
        let cmd = try InstallCommand.parse(["--udid", "U", "/tmp/MyApp.ipa"])
        #expect(cmd.options.udid == "U")
        #expect(cmd.path == "/tmp/MyApp.ipa")
        #expect(InstallCommand.configuration.commandName == "install")
    }

    @Test func `install requires --udid`() {
        #expect(throws: (any Error).self) {
            try InstallCommand.parse(["/tmp/MyApp.ipa"])
        }
    }

    @Test func `install requires a path argument`() {
        #expect(throws: (any Error).self) {
            try InstallCommand.parse(["--udid", "U"])
        }
    }

    @Test func `add-media parses --udid and a file path`() throws {
        let cmd = try AddMediaCommand.parse(["--udid", "U", "/tmp/clip.mov"])
        #expect(cmd.options.udid == "U")
        #expect(cmd.path == "/tmp/clip.mov")
        #expect(AddMediaCommand.configuration.commandName == "add-media")
    }

    @Test func `add-media requires --udid`() {
        #expect(throws: (any Error).self) {
            try AddMediaCommand.parse(["/tmp/clip.mov"])
        }
    }

    // MARK: - diag-digitizer-trackpad

    @Test func `diag-digitizer-trackpad parses --udid`() throws {
        let cmd = try DiagDigitizerTrackpadCommand.parse(["--udid", "U"])
        #expect(cmd.options.udid == "U")
        #expect(DiagDigitizerTrackpadCommand.configuration.commandName == "diag-digitizer-trackpad")
    }

    // MARK: - stream

    @Test func `stream defaults match StreamConfig.default`() throws {
        let cmd = try StreamCommand.parse(["--udid", "ABC"])
        #expect(cmd.format == "mjpeg")
        #expect(cmd.fps == 60)
        #expect(cmd.quality == 0.70)
        #expect(cmd.bitrate == StreamConfig.default.bitrateBps)
        #expect(cmd.scale == StreamConfig.default.scale)
        #expect(StreamCommand.configuration.commandName == "stream")
    }

    @Test func `stream accepts every tunable knob`() throws {
        let cmd = try StreamCommand.parse([
            "--udid", "ABC",
            "--format", "avcc",
            "--fps", "30",
            "--quality", "0.9",
            "--bitrate", "8000000",
            "--scale", "2",
        ])
        #expect(cmd.format == "avcc")
        #expect(cmd.fps == 30)
        #expect(cmd.quality == 0.9)
        #expect(cmd.bitrate == 8_000_000)
        #expect(cmd.scale == 2)
    }

    // MARK: - gesture commands

    @Test func `tap parses point + size + duration`() throws {
        let cmd = try TapCommand.parse([
            "--udid", "ABC",
            "--x", "10", "--y", "20",
            "--width", "390", "--height", "844",
            "--duration", "0.1",
        ])
        #expect(cmd.x == 10 && cmd.y == 20)
        #expect(cmd.width == 390 && cmd.height == 844)
        #expect(cmd.duration == 0.1)
        #expect(TapCommand.configuration.commandName == "tap")
    }

    @Test func `tap duration defaults to 0.05`() throws {
        let cmd = try TapCommand.parse([
            "--udid", "ABC",
            "--x", "1", "--y", "2",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.duration == 0.05)
    }

    @Test func `double-tap parses point + size + interval + duration`() throws {
        let cmd = try DoubleTapCommand.parse([
            "--udid", "ABC",
            "--x", "220", "--y", "480",
            "--width", "402", "--height", "874",
            "--interval", "0.12",
            "--duration", "0.05",
        ])
        #expect(cmd.x == 220 && cmd.y == 480)
        #expect(cmd.width == 402 && cmd.height == 874)
        #expect(cmd.interval == 0.12)
        #expect(cmd.duration == 0.05)
        #expect(DoubleTapCommand.configuration.commandName == "double-tap")
    }

    @Test func `double-tap interval and duration default to observed-working cadence`() throws {
        let cmd = try DoubleTapCommand.parse([
            "--udid", "ABC",
            "--x", "1", "--y", "2",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.interval == 0.05)
        #expect(cmd.duration == 0.08)
    }

    @Test func `swipe parses start + end + size`() throws {
        let cmd = try SwipeCommand.parse([
            "--udid", "ABC",
            "--start-x", "0", "--start-y", "0",
            "--end-x", "100", "--end-y", "200",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.startX == 0 && cmd.startY == 0)
        #expect(cmd.endX == 100 && cmd.endY == 200)
        #expect(cmd.duration == 0.25)
        #expect(SwipeCommand.configuration.commandName == "swipe")
    }

    @Test func `pinch parses centre + spread`() throws {
        let cmd = try PinchCommand.parse([
            "--udid", "ABC",
            "--cx", "100", "--cy", "200",
            "--start-spread", "50", "--end-spread", "150",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.cx == 100 && cmd.cy == 200)
        #expect(cmd.startSpread == 50 && cmd.endSpread == 150)
        #expect(cmd.duration == 0.6)
        #expect(PinchCommand.configuration.commandName == "pinch")
    }

    @Test func `pan parses two contacts + delta`() throws {
        let cmd = try PanCommand.parse([
            "--udid", "ABC",
            "--x1", "10", "--y1", "20",
            "--x2", "30", "--y2", "40",
            "--dx", "5", "--dy=-5",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.x1 == 10 && cmd.y1 == 20)
        #expect(cmd.x2 == 30 && cmd.y2 == 40)
        #expect(cmd.dx == 5 && cmd.dy == -5)
        #expect(cmd.duration == 0.5)
        #expect(PanCommand.configuration.commandName == "pan")
    }

    @Test func `press parses --button`() throws {
        let cmd = try PressCommand.parse(["--udid", "ABC", "--button", "home"])
        #expect(cmd.button == "home")
        #expect(PressCommand.configuration.commandName == "press")
    }

    // MARK: - screenshot

    @Test func `screenshot defaults match snapshot helper`() throws {
        let cmd = try ScreenshotCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.output == nil)
        #expect(cmd.quality == 0.85)
        #expect(cmd.scale == 1)
        #expect(ScreenshotCommand.configuration.commandName == "screenshot")
    }

    @Test func `screenshot accepts --output --quality --scale`() throws {
        let cmd = try ScreenshotCommand.parse([
            "--udid", "ABC",
            "--output", "/tmp/x.jpg",
            "--quality", "0.5",
            "--scale", "2",
        ])
        #expect(cmd.output == "/tmp/x.jpg")
        #expect(cmd.quality == 0.5)
        #expect(cmd.scale == 2)
    }

    // MARK: - describe-ui

    @Test func `describe-ui requires --udid and defaults to full tree`() throws {
        let cmd = try DescribeUICommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.x == nil && cmd.y == nil)
        #expect(cmd.output == nil)
        #expect(DescribeUICommand.configuration.commandName == "describe-ui")
    }

    @Test func `describe-ui accepts --x --y --output`() throws {
        let cmd = try DescribeUICommand.parse([
            "--udid", "ABC",
            "--x", "120", "--y", "400",
            "--output", "/tmp/tree.json",
        ])
        #expect(cmd.x == 120 && cmd.y == 400)
        #expect(cmd.output == "/tmp/tree.json")
    }

    // MARK: - logs

    @Test func `logs requires --udid and defaults level + style`() throws {
        let cmd = try LogsCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.level == "info")
        #expect(cmd.style == "default")
        #expect(cmd.predicate == nil)
        #expect(cmd.bundleId == nil)
        #expect(LogsCommand.configuration.commandName == "logs")
    }

    @Test func `logs accepts --level --style --predicate --bundle-id`() throws {
        let cmd = try LogsCommand.parse([
            "--udid", "ABC",
            "--level", "debug",
            "--style", "json",
            "--predicate", #"subsystem == "com.apple.UIKit""#,
            "--bundle-id", "com.example.app",
        ])
        #expect(cmd.level == "debug")
        #expect(cmd.style == "json")
        #expect(cmd.predicate == #"subsystem == "com.apple.UIKit""#)
        #expect(cmd.bundleId == "com.example.app")
    }

    // MARK: - serve

    @Test func `serve defaults bind to 127.0.0.1:8421`() throws {
        let cmd = try ServeCommand.parse([])
        #expect(cmd.host == "127.0.0.1")
        #expect(cmd.port == 8421)
        #expect(cmd.deviceSet == nil)
        #expect(ServeCommand.configuration.commandName == "serve")
    }

    @Test func `serve overrides host + port + device-set`() throws {
        let cmd = try ServeCommand.parse([
            "--host", "0.0.0.0",
            "--port", "9000",
            "--device-set", "/tmp/sims",
        ])
        #expect(cmd.host == "0.0.0.0")
        #expect(cmd.port == 9000)
        #expect(cmd.deviceSet == "/tmp/sims")
    }
}
