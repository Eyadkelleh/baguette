# Changelog

All notable changes to baguette will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For releases prior to this changelog, see the
[GitHub Releases](https://github.com/tddworks/baguette/releases) page.

## [Unreleased]

### Added

- **`baguette openurl <url>` — open a deep link on the booted simulator.**
  Dispatches through `xcrun simctl openurl`, but unlike every other tool it
  says what will actually happen first: an `https://` universal link lands in
  Safari on the simulator, not in your app, and if an app claims the domain
  iOS shows an "Open in …?" dialog that needs a tap. `DeepLink.routing`
  names the two cases so the warning is a modelled behaviour rather than a
  print statement.

- **`baguette schemes` — list the URL schemes installed apps answer to.**
  The inventory behind console completion, and useful alone when you know an
  app handles *something* but not what it's called. `--json` for machine use.
  Schemes are ranked with an app's own readable scheme ahead of its
  reverse-DNS and tool-injected (`exp+…`) aliases.

  Reading them takes two steps, because `simctl listapps` reports a curated
  metadata subset that does **not** include `CFBundleURLTypes`. It does report
  each app's on-disk `Path`, so schemes come from `<Path>/Info.plist` — which
  means we never guess CoreSimulator's container layout or its per-install
  UUIDs.

- **Deep-link URL bar in `baguette serve`.** A command bar in the focus page's
  toolbar: type a scheme fragment and it completes against the apps actually
  installed on the device (`avas-` → `avas-app://`), with inline ghost text
  plus a suggestion list, `↑`/`↓` history, and `Tab`/`→` to accept. Opening an
  https link shows the same Safari warning the CLI prints.

  Backed by two routes — `GET /simulators/<udid>/schemes?q=…` and
  `POST /simulators/<udid>/openurl?url=…`. Ranking and the warning copy both
  live server-side so the browser keeps no second copy that can drift; the bar
  itself is a dumb sender. Discovery is debounced and superseded responses are
  dropped, so typing never waits on the device.

---

## [0.1.82] - 2026-07-20

### Fixed

- **Xcode 27 support — SimulatorKit is found at its new location.** Xcode 27
  moved `SimulatorKit.framework` out of the developer directory
  (`Contents/Developer/Library/PrivateFrameworks/`) and up into
  `Contents/SharedFrameworks/`. Every `dlopen` site hardcoded the old path, so
  a machine whose only Xcode is 27 failed to load SimulatorKit at all and no
  simulator control worked ([#28]). Both layouts are now probed, oldest-first,
  so Xcode ≤26 resolves to exactly the path it always did. When neither
  location exists, the raw dyld error is replaced by a message naming both
  paths searched and pointing at `DEVELOPER_DIR`.

- **Xcode 27 support — device chrome renders again on 9-slice devices.**
  Xcode 27 stopped publishing `mainScreenWidth` / `mainScreenHeight` /
  `mainScreenScale` on a device type's `profile.plist` (124 of 124 device types
  carry them on Xcode 26; 0 of 124 on Xcode 27) and moved the same values into
  a sibling `capabilities.plist`. Only the 9-slice chrome path reads a screen
  size, so every iPad — plus iPhone 17e — lost its bezel while devices with a
  baked composite kept theirs. Both shapes are now read, preferring the
  profile's own keys. The `integrated` display is selected explicitly: the same
  list carries `tvOut` / `carPlay` entries at 720×480 and a resizable `scene`
  entry at 7680×4320, any of which would have sized a bezel wrongly ([#28]).

[#28]: https://github.com/tddworks/baguette/issues/28

---

## [0.1.81] - 2026-07-17

### Added

- **Virtual camera for camera-less simulators — unmodified apps see a working camera.** The preview-layer painting only shows frames in an app that already has a running `AVCaptureSession`, which needs a real `AVCaptureDevice` — a Mac *without* a camera has none, so real camera apps (expo-camera, VisionCamera, straight AVFoundation) never start and sit on a permission/loading screen. `SimCamVirtualCamera.m` mocks the *entire* capture graph at the public AVFoundation boundary (the [swmansion/SimCam](https://simcam.swmansion.com/) approach; fed from the shared buffer instead of a socket): a fabricated `AVCaptureDevice` from `defaultDeviceWithMediaType:`/`DiscoverySession.devices`, a **dummy `AVCaptureDeviceInput`** so the real initializer never dereferences the device format's private `FigCaptureSource` (which crashes on a fabricated device), session add-input/output + `startRunning` / `stopRunning` intercepted so no real (source-less) graph is built (that would hang ~9 s and stall the app), and a 30 fps timer that turns `/tmp/SimCam.bgra` into `CVPixelBuffer` → `CMSampleBuffer` delivered straight to the app's `AVCaptureVideoDataOutput` delegate — delivery follows the app's own session lifecycle, so a stopped session stops getting frames. With this, an app on a camera-less Mac gets a device, becomes "ready", and shows baguette's image/video/webcam — **no app edits**. **Injection is now cleaned up on teardown**: `camera_start` arms `DYLD_INSERT_LIBRARIES` (all apps), and `CameraSession.stop` disarms it (`launchctl unsetenv`) — fixing the well-known SimCam bug where the dylib stays injected into every launch until reboot. Known limits: the private `AVCaptureDeviceFormat` accessors the graph shims are iOS-version-specific (verified iOS 26 / expo-camera 57); `AVCaptureMetadataOutput` isn't fed synthesized barcodes yet (the camera shows, but a metadata-based scanner won't detect a code); the app must be relaunched *after* `camera_start`. See [`docs/features/camera.md`](docs/features/camera.md).
- **Image and video files as camera sources, alongside the live webcam.** The camera card now has a source selector — Webcam / Image / Video. Pick Image or Video, choose a file, and it streams into the simulator's camera through the *same* shared-memory BGRA pipeline the webcam uses: a still image drives a fixed viewfinder (a headshot for a profile-photo picker), a video loops forever (a barcode clip for a scanner). Because the pipeline below the frame *source* is source-agnostic, the vendored `VirtualCamera.dylib` needed **zero changes** — image/video frames are indistinguishable from webcam frames at the buffer boundary. The source is chosen by a new `CameraSource` value that the `CameraSession` routes to one of three `CameraCapture` producers: the existing `AVCameraCapture` (webcam), `ImageFileCapture` (decode once, re-emit at ~30 fps under an advancing sequence — the dylib's reader shows "No camera signal" after ~1 s of a stale sequence, so a still must keep the buffer fresh), and `VideoFileCapture` (an `AVAssetReader` behind the `VideoDecoder` collaborator, paced by presentation timestamps and rewound at EOF to loop). Both file sources downscale into the 1280×1280 canvas via the pure `ScaleToFit` — mandatory, since nothing downstream resizes and an oversized frame is dropped wholesale. Files reach the host over a new `POST /simulators/:udid/camera-source` route that stages the bytes into a **persistent per-udid slot** (they must outlive the request — the camera WS streams them later, unlike `/files` which `simctl` consumes inline); the browser never sends a host path — `camera_start` just names `"source": "image" | "video"` and the server resolves the staged file, clearing it when the socket closes. Browser/WebSocket-only, matching the existing camera surface. Known limits: video rotation metadata isn't applied (a phone clip may play sideways) and audio tracks are ignored. See [`docs/features/camera.md`](docs/features/camera.md).
- **Joystick-driven location — drive the simulator around a map, with `CLLocation.course` following the stick.** The focus-mode Location card gains a third **Walk** mode beside Point and Route, with two control schemes over one persistent heading: the thumbstick is **absolute** (angle = heading, deflection = speed), while the keyboard is **relative** — videogame tank controls, where `W`/`S` drive forward/reverse along the heading the device already has and `A`/`D` sweep that heading at 90°/s (including on the spot; hold `W`+`D` to drive an arc; arrows mirror WASD, `Shift` boosts ×3). Pick a speed preset (Walk 1.4 · Run 3.5 · Cycle 6 · Drive 13.4 · Highway 29 m/s) and the device walks — pin trailing behind it on the map, live compass showing the bearing. Heading is deliberately **state, not a property of the current vector**: the device still points somewhere when standing still, so the compass holds its bearing and `A`/`D` can pivot before `W` drives off. Walking records a trail (sampled every 4 m, not per frame), and **Replay** retraces it at whatever preset is selected at replay time — a footpath can be replayed at Highway speed. Replay reuses the existing `{waypoints,speed}` route body, so it too adds no wire and no Swift. Also `baguette location walk --udid <X> --bearing 90 --speed 5 <lat,lon>` for the shell, and wire JSON `{"latitude":…,"longitude":…,"bearing":…,"speed":…}` on `POST /simulators/<X>/location`. **The joystick sends a vector, never positions**, and that's the whole design: `simctl location set` costs ~277 ms a spawn (capping a per-tick joystick near a jerky 3.6 Hz) and pins a *stationary* point that locationd reports with `course = -1`, so no amount of re-pinning could ever express a direction of travel. A two-waypoint `start` route fixes both — it's fire-and-forget (returns in ~430 ms while the daemon interpolates in the background), a second `start` retargets mid-route in ~200 ms, and because the device genuinely travels the leg, locationd *derives* course and speed from the motion. So `LocationWalk` (origin + bearing + speed) projects a waypoint 600 s of travel along the bearing and reuses the existing `start` path: **no new Infrastructure, no new private API** — a walk *is* a route. Releasing the stick POSTs a plain point, whose `course = -1` is precisely "stopped", and snaps the device onto the browser's dead-reckoned pin (which mirrors `Coordinate.projected` exactly, so the local 60 fps animation and the device's track trace the same line while the wire stays near-silent: ≥250 ms between sends, skipped under 2° / 0.1 m/s of change, latest-wins in flight, 30 s keepalive). Two iOS-26 gotchas worth preserving, both measured against a booted sim: **(1)** locationd derives `CLLocation.course` on a **flat lat/lon grid** — `atan2(Δlon, Δlat)` on raw degrees, missing the `cos(latitude)` convergence of meridians — so a geodesically-correct due-NE route reports `Course,51.52` instead of 45° at lat 37 (cardinal bearings are immune; skew is 0° at the equator and ~18° at lat 60). Movement itself is on a true globe, so correct positions *force* a wrong course and the two can't both be right; baguette keeps positions truthful and documents the skew rather than deliberately walking the device off-course to flatter a broken derivation. **(2)** `CLHeading` — the actual compass — is unavailable in the simulator entirely (`CLLocationManager.headingAvailable() == false`, no magnetometer); only `course` is drivable, so an app calling `startUpdatingHeading` gets nothing there no matter what baguette does. See [`docs/features/location.md`](docs/features/location.md).

### Changed
- **Lower-latency H.264 (AVCC) streaming.** The single-sim tab (`/simulators/:udid`) defaults to H.264/AVCC while the device-farm grid uses MJPEG, and the AVCC path's felt "input latency" was dominated by frames sitting in the browser's WebCodecs `VideoDecoder` queue — the same decoder-hold the `AVCCStream` idle-pump already exists to work around. The `VTCompressionSession` now runs VideoToolbox's low-latency rate-control path (`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`) with `MaxFrameDelayCount = 0`, which shrinks the encode pipeline and signals a minimal decoded-picture buffer so the decoder emits each frame immediately instead of buffering — noticeably tighter interaction with no change to bitrate, fps, or scale. The encoder's tuning knobs are lifted into a pure, unit-tested `H264Tuning` value (`.lowLatency` preset) so the "what config do we want" decision is covered apart from the irreducible VideoToolbox calls that apply it. The AVCC decoder also gained a **non-blocking diagnostic**: on configure it logs whether the negotiated profile/level decodes in hardware (`mediaCapabilities.decodingInfo().powerEfficient`), so a silent software-decode fallback — brutal at full-res 60 fps — surfaces in the console instead of masquerading as input lag. MJPEG is unaffected.

---

## [0.1.80] - 2026-07-13

### Added
- **Copy out of the simulator onto the host Mac's clipboard — the sim→host direction, with Cmd+C.** Closes the gap the paste feature left open ("there's no sim→host reverse sync yet"): the interactive mirror of `paste`. Browser **Cmd+C / Ctrl+C** while the device screen has focus presses Cmd+C sim-side (so the focused field copies its selection into the simulator's pasteboard), then ferries that pasteboard onto the host Mac's clipboard **full-fidelity, images included** (`xcrun simctl pbsync <udid> host`) — the mirror of the Cmd+V paste carve-out. Three entry points share the path: the browser chord, wire JSON `{"type":"copy","press":true?}` on both `baguette serve`'s stream WS and `baguette input`'s stdin (acked WS-side with a typed `copy_result` frame), and `baguette clipboard copy --udid <UDID>` — a **pure ferry** (no keystroke, equivalent to `press:false`) that mirrors `clipboard sync` as the scripting primitive. Like `paste`, `copy` is deliberately **not** a `Gesture` (the pasteboard sync is an async host call out of reach of the sync, `Input`-only `Gesture.execute`), so both wire entry points intercept it ahead of the gesture pipeline via its own `Domain/Pasteboard/Copy` value + `App/CopyDispatch`. Built on one small addition — `Pasteboard.syncToHost()` (`pbsync <udid> host`, the exact mirror of `syncFromHost`'s `pbsync host <udid>`), fully unit-covered via `MockSubprocess`. One gotcha worth preserving: copy **reverses paste's order** — paste sets the pasteboard *before* the keystroke, copy reads it *after* — so a fixed ~200 ms settle covers the guest's key-event → `UIPasteboard` round-trip before the sync reads it back (a timing guess, not a handshake; `press:false` sidesteps it). Two more notes: copy only pulls a *selection* from views that honor hardware Cmd+C (editable fields) — elsewhere it's a no-op that just ferries the current pasteboard; and **browser Cmd+C targets the machine running baguette** (`pbsync … host` is the server's clipboard), which is exactly the local-dev case where the browser shares that Mac — a remote browser's Cmd+C lands on the server, not the viewer. No `navigator.clipboard` / Clipboard-API permission dance: the sync happens host-side. See [`docs/features/paste.md`](docs/features/paste.md).

---

## [0.1.79] - 2026-07-11

### Added
- **`serve --allowed-hosts` for reverse-proxy deployments.** The browser-security check only trusts loopback `Host` / `Origin` values, so requests reaching `baguette serve` through a reverse proxy got `403 forbidden origin` on every control route and stream WebSocket. `--allowed-hosts sim.example.com` (repeatable; `*.example.com` matches subdomains) trusts additional hostnames, ignoring ports since the public port belongs to the proxy. An allowed host is trusted both as a request `Host` and as a browser `Origin`, and allowed Origins get CORS headers and preflight responses so a web app on one trusted host can call the API on another. All other cross-site `Origin`s are still rejected and behaviour without the flag is unchanged.

---

## [0.1.78] - 2026-07-09

### Added
- **Paste & clipboard — real pasteboard support for the simulator.** Paste arbitrary unicode into the focused field (emoji, accents, non-Latin scripts — the path around `type`'s US-ASCII keystroke limit) by setting the sim's pasteboard and pressing Cmd+V, in one verb. Four entry points share one path: `baguette paste --udid <UDID> --text "…" [--no-press]`, `baguette clipboard get` (print the sim's pasteboard raw) / `baguette clipboard sync` (host → sim **full-fidelity, images included** — the media answer), wire JSON `{"type":"paste","text":"…","press":true?}` on both `baguette serve`'s stream WS and `baguette input`'s stdin, and browser Cmd+V/Ctrl+V while the device screen has focus. Previously the browser forwarded Cmd+V as a raw HID chord and iOS pasted its own **empty** pasteboard — a silent no-op, since nothing in the stream pipeline syncs the host clipboard the way Simulator.app does; the web UI now carves the paste chord out of keydown forwarding so the native `paste` event fires, reads `clipboardData` (no permission prompt, works over plain LAN http), and ships the text as a `paste` envelope, acked WS-side with a typed `paste_result` frame. `paste` is deliberately **not** a `Gesture`: the pasteboard set is an async host call out of reach of the sync, `Input`-only `Gesture.execute`, so both entry points intercept it ahead of the gesture pipeline (the `describe_ui` shape) via one shared `PasteDispatch`. Like the status bar this is a `simctl` path — `pbcopy | pbpaste | pbsync host` through the existing `Subprocess` collaborator, fully unit-covered via `MockSubprocess` — with one collaborator gotcha worth preserving: `pbcopy` reads its payload from **stdin**, so `Subprocess` grew a second, stdin-carrying `run` requirement (additive — the six existing adapters and their test suites are untouched); the no-stdin variant keeps `standardInput = nullDevice` for the Ctrl-C/SIGINT detachment `baguette logs` depends on, while the stdin variant writes a pipe off-thread so a >64 KB payload can't deadlock against a full pipe buffer. Known limits: the wire verb is text-only (for images, copy on the host and `clipboard sync`), and there's no sim→host reverse sync yet. See [`docs/features/paste.md`](docs/features/paste.md).
- **Drag-and-drop a folder-form `.app` bundle onto the device.** The focus page's drop target now takes all three app shapes: an `.ipa` (unchanged), a pre-zipped `.app`, and — new — the bare `.app` **directory** straight from Finder or a build products folder. A browser can't upload a directory as one file, so `sim-file-drop.js` walks the dropped bundle via `webkitGetAsEntry` and packs it into a **stored (uncompressed) zip built in-page** (local headers + CRC-32 + central directory, ~90 lines, no library), posting it as `<Name>.app.zip` to the same `POST /simulators/:udid/files` route. The Swift side gains the matching domain value: `AppArchive` (a `.zip` carrying one app) with pure classification, `ditto` argv projection, and an `installableApp(amongExtracted:)` locator (exactly one top-level `.app`; `__MACOSX` / dotfiles ignored; two apps refused as ambiguous), plus `apps().install(archive:)` on the `Apps` collection — extract, locate, then reuse the normal `AppBundle` install; both spawns run through the existing `Subprocess` collaborator, fully unit-covered via `MockSubprocess`. Two gotchas worth preserving: extraction uses `ditto -x -k` (not `unzip`) because it restores unix modes from the zip's external attributes, and the browser packer stamps every entry `0755` since the file-system entry API can't read permission bits — otherwise the installed app's binary comes out non-executable and won't launch. A zip that isn't a packed app fails as the upload's fault (`415` with the reason: "corrupt zip?" / "zip bomb?" when the contents blow past a 4 GiB decompression cap — refused up front from the central directory's declared sizes, with the extracted bytes re-measured as the backstop against forged headers / "no single `.app` bundle at the top level"), never a misleading simctl `500`. Known limits: the `.app` must sit at the zip's top level, and symlinks / empty dirs don't survive the browser packer (iOS-style shallow bundles carry neither). See [`docs/features/file-upload.md`](docs/features/file-upload.md).
- **Numpad forwarding.** The browser keyboard capture now recognises the Mac's physical numeric keypad — `Numpad0`–`Numpad9`, `NumpadDecimal`, `NumpadAdd` / `NumpadSubtract` / `NumpadMultiply` / `NumpadDivide`, keypad `NumpadEnter`, and `NumpadEqual` — and forwards each keystroke into the focused simulator with its **own** HID keypad usage (page 7, `0x54`–`0x63` plus `0x67`), distinct from the top-row digits. No wire or CLI change: numpad keys ride the existing `key` envelope (`{ "type": "key", "code": "Numpad5" }`) down the same `IndigoHIDMessageForHIDArbitrary(target, page:7, usage, op)` path already used for letters and digits, so `baguette key --code Numpad5` works from the CLI too. `Numpad0` takes `0x62` (last in the keypad block, the same last-place quirk as the top-row `Digit0`). `NumLock`/Clear is deliberately left out — iOS has no num-lock concept, so forwarding it would be a device no-op that needlessly swallowed the host key. See [`docs/features/keyboard.md`](docs/features/keyboard.md).

---

## [0.1.77] - 2026-06-24

### Added
- **Custom location — set the simulator's simulated GPS position.** Pin the booted simulator to a latitude/longitude, run a moving route between waypoints, or clear back to the device's live location. Three entry points share one path: `baguette location set --udid <UDID> <lat,lon>` / `baguette location start --udid <UDID> [--speed …] [--distance …] [--interval …] <lat,lon> <lat,lon>…` / `baguette location clear`, `POST` / `DELETE /simulators/:udid/location` on `baguette serve` (the `POST` body is a `{latitude,longitude}` point or a `{waypoints:[…],speed?}` route — a `waypoints` array selects the route path), and a focus-mode **Location** glass card with a Leaflet map: click to drop a pin and "Set location", or switch to Route mode and drop two or more waypoints to "Start route". The card also has a place-name **search** (OSM Nominatim geocoding) and a **locate-me** button (the host Mac's GPS via the browser geolocation API). Note `simctl location` is write-only — there's no read-back of the device's current simulated position, so the surface is intentionally `set` / `start` / `clear` with no `GET`. Like the status bar this is a `simctl` path, not SimulatorHID — `xcrun simctl location … set | start | clear` (the mechanism behind Xcode's **Features ▸ Location** menu) runs through the existing `Subprocess` collaborator and is fully unit-covered via `MockSubprocess`. The position is a single `lat,lon` **token** rather than `--lat` / `--lon` flags so a western/southern coordinate's leading `-` isn't mistaken for an option (pass `--` first for a negative *latitude*). One gotcha locked into the value type with a test: simctl mandates `.` decimal / `,` field separators, so `Coordinate.argument` is built from Swift's locale-independent `Double` formatting — never a locale-aware formatter that would emit a decimal comma. The map uses **Leaflet 1.9.4** vendored under `Resources/Web/vendor/leaflet/` (no bundler, no CDN); only the OSM map tiles are fetched at runtime. Known limits: named drive scenarios (`simctl location run`) aren't wired yet, and tile imagery needs network. See [`docs/features/location.md`](docs/features/location.md).

---

## [0.1.76] - 2026-06-22

### Added
- **Drag-and-drop file upload to the device.** Add a file to a booted simulator by handing it the file — drop an app to install it, drop a photo or video to land it in Photos. Three entry points share one path: `baguette install --udid <UDID> <path>` (an `.ipa` / `.app`), `baguette add-media --udid <UDID> <path>` (an image / video), and `POST /simulators/:udid/files?name=<filename>` on `baguette serve`, which the focus page's drag-and-drop target posts raw bytes to. The domain is modelled the way the user thinks of it — not a generic file classifier but the **two collections that live on a phone**: `Apps` (install an `AppBundle`) and `PhotoLibrary` (add a `MediaItem`), each hanging off `Simulator` beside `statusBar()`. Classification lives on the values themselves (`AppBundle.at` / `MediaItem.at`, pure extension checks), and the `serve` route is a thin "which collection?" dispatcher that routes by type and **refuses anything with no home on a simulator** (a `.pdf` gets a `415`, never a silent drop). Like the status bar this is a `simctl` path, not SimulatorHID — `xcrun simctl install` / `addmedia` run through the existing `Subprocess` collaborator and are fully unit-covered via `MockSubprocess`. The serve route stages the upload into a per-request temp dir (filename sanitised to its last path component so `?name=../…` can't escape) and rejects unsupported extensions before reading the body. Known limits: single files only (zip a folder `.app` to `.ipa` for the browser; the CLI takes a real `.app` directly), and the drop UI is focus-mode only for now. See [`docs/features/file-upload.md`](docs/features/file-upload.md).

---

## [0.1.75] - 2026-06-09

### Added
- **Status bar overrides.** Pin the booted simulator's status bar to a fixed state — time, carrier, data-network type, Wi-Fi / cellular mode + signal bars, battery state + level — or clear it back to live values. Three entry points share one path: `baguette status-bar override --udid <UDID> [flags…]` / `baguette status-bar clear`, `POST` / `DELETE /simulators/:udid/status-bar` on `baguette serve`, and a focus-mode **Status Bar** glass card (signal-bars toolbar button) that reads the device's current overrides on open (`GET …/status-bar`, parsed from `simctl status_bar … list`) and, on edit, sends **only the changed field** so simctl merges it in — changing Wi-Fi bars never flips the data-network indicator to "5G" or re-applies the battery. Unlike taps/swipes this is **not** a SimulatorHID path — it shells out to `xcrun simctl status_bar <udid> override | clear` (the same mechanism Xcode's Simulator menu uses), so the orchestration runs through the existing `Subprocess` collaborator and is fully unit-covered via `MockSubprocess`. The flag spellings (`5g-uwb`, `notSupported`, bar ranges 0-3 / 0-4, level 0-100) are verified against the Xcode 26 simctl surface and live in one Domain spelling table shared by the CLI, the HTTP body parser, and the argv projection. See [`docs/features/status-bar.md`](docs/features/status-bar.md).

---

## [0.1.74] - 2026-06-05

### Fixed
- **Server-side AX hit-test for `describeAt(point:)`.** The method was previously falling back to a client-side tree walk because the 0-arg `objectAtPoint:` variant has a chicken/egg problem with `bridgeDelegateToken` — the returned translation needs the token stamped before the call. `AXPTranslator` exposes a **3-arg** variant — `objectAtPoint:displayId:bridgeDelegateToken:` — that takes the token as a parameter, which the dispatcher entry registered in `hitTestServerSide` resolves correctly on the very first XPC sub-request. Meta's idb has used this selector internally for years (`FBSimulatorAccessibilityCommands.m`'s `FBAXTranslationRequest_Point`, backing its describe-point CLI). The practical payoff is that `describeAt(point:)` now returns elements the static tree walk *misses* — most notably SwiftUI tab-bar items inside an `AXGroup` that `describeAll` reports as childless. Falls back to the original client-side walk only when the AXP selector isn't present (defensive only — present on every AXP we've seen on Xcode 26+). Adds `AXFrameTransform.unmap(_:)` for the device-point → host-coordinate inverse and `AXPTranslatorAccessibility.supportsServerSideHitTest` as the capability gate; both fully unit-covered.

---

## [0.1.73] - 2026-05-13

### Changed
- Bug fixes and improvements.

---

## [0.1.72] - 2026-05-13

### Added
- **Virtual camera — pipe a Mac webcam into the iOS simulator's `AVCaptureVideoPreviewLayer` / `AVCapturePhotoOutput` / `UIImagePickerController`.** New WebSocket route `/simulators/:udid/camera` and a browser camera card (sidebar view) let the user pick a Mac camera (FaceTime HD, USB webcam, Continuity Camera), Start/Stop streaming, toggle Fit/Fill and Mirror, and watch a live FPS readout. The Mac side runs `AVCameraCapture` → `BGRAConverter` → `SharedMemoryFrameSink`, writing into `/tmp/SimCam.bgra` (24-byte LE header + BGRA pixels). The iOS-simulator side runs `VirtualCamera.dylib` (vendored under `VirtualCamera/` from `asc-pro/SimCam@ee513da7`, fat arm64 + x86_64, linker-signed adhoc), loaded via `DYLD_INSERT_LIBRARIES` armed on the simulator's launchd domain by `SimctlSimulatorInjection`. The dylib is bundled inside the baguette release tarball; `VirtualCameraInstaller` resolves it from `Bundle.module`, sha256-keys the bytes, and copies into a per-hash subdirectory under `~/Library/Application Support/Baguette/builds/` — the per-hash dir dodges iOS 26's simulator dyld page-hash cache rejecting replaced dylibs at the same path with `code:codesigning(3) invalid-page(2)`. Wire envelopes: `camera_list` / `camera_start` / `camera_stop` / `camera_set_flags` upstream, `camera_devices` / `camera_state` downstream. Domain bounded context `Domain/Camera/` is 100% unit-covered (`CameraFlags`, `CameraDevice`, `CameraFrame`, `SharedFrameLayout`, `BGRAConverter`, `CameraSession`, `CameraMessage`, `VirtualCameraInstallPlan`); infrastructure orchestrators (`AVCameraCapture`, `SimctlSimulatorInjection`, `SharedMemoryFrameSink`, `VirtualCameraInstaller`) ≥90% unit-covered via `MockVideoCapture` / `MockSubprocess` / temp-dir fixtures. Only `HostVideoCapture` (the `AVCaptureSession` plumbing) and `AVCameras` (the `AVCaptureDevice.DiscoverySession` enumeration) are integration-only. See [`docs/features/camera.md`](docs/features/camera.md).
- **`baguette double-tap` — one-shot native iOS double-tap from the CLI ([#11](https://github.com/tddworks/baguette/issues/11)).** New `baguette double-tap --udid <UDID> --x <X> --y <Y> --width <W> --height <H> [--interval <sec>] [--duration <sec>]` subcommand sequences a `touch1-down → touch1-up → touch1-down → touch1-up` recipe inside one process, separated by `duration` (per-tap hold, default 0.08 s) and `interval` (tap-1-up → tap-2-down gap, default 0.05 s). UIKit's `UITapGestureRecognizer(numberOfTapsRequired: 2)` and SwiftUI's `TapGesture(count: 2)` both fire on the result. The wire path (`baguette serve` WS / `baguette input` stdin) already covered this via four `touch1-*` lines on one long-lived connection; what was missing was a CLI shape that didn't pay the ~150–300 ms process-startup cost twice — back-to-back `baguette tap` invocations spent so long in process startup that the recognizer timed out between them. The four-line wire recipe is unchanged and remains the path for browser / scripting clients that need their own timing control. No new wire envelope (`{"type":"double-tap"}` is intentionally not added — the streaming primitives already produce the right HID sequence). See [`docs/features/double-tap.md`](docs/features/double-tap.md).

---

## [0.1.71] - 2026-05-12

### Changed
- Bug fixes and improvements.

---

## [0.1.70] - 2026-05-11

### Added
- **Baguette JS SDK (v0.1.0) + `/simulators/<UDID>/definition.json` endpoint — full browser-side refactor.** New SDK shape: `const sim = await Baguette.use({ host, udid, send }); sim.mount(container);` — two lines for the entire frontend interaction model. Replaces the page-level conflation of geometry math, wire-format translation, and DOM eventing with a domain-shaped composition under `Resources/Web/baguette/`: `Simulator → { screen, buttons[*], keyboard? }`, each part its own class, each owning its rendering AND its wire dispatch. Only `transport.js` knows the wire format; consumer pages never see envelopes. Adding Apple Watch / Apple TV / Vision Pro support is "add a `parts/<thing>.js`, no other change." The Swift `SimulatorDefinition.compose(...)` factory ships the per-simulator bootstrap (identity + screen rect + bezel image URLs + per-button envelope + image URLs + pre-computed CSS percent box + rest/hover/pressed transforms + z-order + optional keyboard part) so the JS does no geometry math, no anchor mirroring, no chrome→wire allow-list lookup. All three consumer pages — `sim-stream.js`, `sim-native.js` (with orientation-aware coord remap at the send boundary), `farm/farm-tile.js` (uses SDK parts à la carte) — now consume the SDK. **Deleted: `bezel-buttons.js` (383 LOC), `sim-input.js` (916 LOC), `sim-input-bridge.js` (106 LOC), `device-frame.js` (135 LOC), `keyboard-capture.js`.** The full MouseGestureSource gesture interpreter (drag, pinch, pan, edge-stream, wheel-as-2-finger with idle close, Safari gesture events, option-hover preview, touch) lives in `gestures/pointer-interpreter.js`; the focus-gated keyboard whitelist in `parts/keyboard.js`. Demo page at `/baguette-demo.html` exercises the SDK end-to-end. See [`docs/features/baguette-sdk.md`](docs/features/baguette-sdk.md).
- **Apple Watch hardware buttons (`digital-crown`, `side-button`, `left-side-button`).** Three new `Press`-compatible wire names cover the watch input surface end-to-end: the `baguette press` CLI, the wire JSON `{"type":"button"}`, and the actionable-bezel overlay on `/simulators/<UDID>` all accept them. Each rides `IndigoHIDMessageForHIDArbitrary` with the (page, usage) pair copied verbatim from `/Library/Developer/DeviceKit/Chrome/watch4.devicechrome/Contents/Resources/chrome.json` — `digital-crown` → page 12 / usage 64, `side-button` → page 12 / usage 149, `left-side-button` → page 0xFF01 / usage 512 (Apple's vendor-defined Watch action page). Before this change the actionable-bezel overlay rendered every watch button but every press was inert: `digital-crown` and `left-side-button` had no entry in the front-end wire-name table, and `side-button` mis-aliased to `power` (page 12 / usage 48), silently sending the wrong consumer code. Verified on `Apple Watch Ultra 2 (49mm)` running watchOS 11.2.

---

## [0.1.69] - 2026-05-09

### Added
- **Device orientation (`orientation`).** New `baguette orientation --udid <UDID> <portrait|landscape-left|landscape-right|portrait-upside-down>` CLI subcommand, `POST /simulators/:udid/orientation?value=<…>` HTTP route, and a single rotate icon in the focus-mode toolbar that cycles the device 90° clockwise on each click. All three surfaces feed `simulator.orientation().set(_:)`, which fires a `GSEventTypeDeviceOrientationChanged` mach message at the booted simulator's `PurpleWorkspacePort` — bypassing SimulatorKit's NSView path entirely so the host stays headless. Wire format (112-byte buffer, `msgh_size = 108`, `msgh_id = 0x7B`, GSEvent type `50 | 0x20000` at offset `0x18`, `UIDeviceOrientation` raw value at `0x4C`) is reverse-engineered from `Simulator.app`'s `[SimDevice(GSEvents) gsEventsSendOrientation:]` and matches idb's `PrivateHeaders/SimulatorApp/GSEvent.h`. iPhone UIKit silently ignores `portrait-upside-down` for apps that don't declare `UIInterfaceOrientationPortraitUpsideDown` (which is most Apple-shipped apps including SpringBoard / Photos / Settings) — Domain / CLI / HTTP still accept the value unconditionally, but the browser cycle button drops it on iPhone (3-step on phones via `chrome.json.identifier` prefix, 4-step on tablets) so every click visibly rotates.
- **Stream button on `/simulators` opens focus mode.** Clicking **Stream** in the simulator list now navigates to `/simulators/<UDID>` (the focus-mode page owned by `sim-native.js`) instead of swapping the inline `#simPluginView` in place. Browser back returns to the list, the URL is shareable, and the inline-view flash is gone. Inverse trip: a glass-pill **sidebar view** button at the bottom-left of focus mode (mirror of the theme toggle) navigates back to `/simulators#stream=<UDID>`; `sim-stream.js` reads the hash on load, fetches the device name, strips the hash, and auto-opens the inline `startStream` layout — so the user lands in the sidebar view directly without an extra click.

- **`IOHIDDigitizerDispatch` — coordinate input + system gestures on iOS 26 / Xcode 26.** New unified dispatch path for taps, swipes, streaming `touch1-*` chains, and the home-indicator system gestures (swipe-to-home, app switcher). The Xcode 26 SDK ships an `IndigoHIDMessageForMouseNSEvent` that produces messages iOS either misroutes to the home gesture or silently drops; the new path bypasses the regression by feeding the simulator a real hardware-shaped `IOHIDEvent` instead. Recipe: build an `IOHIDEventCreateDigitizerEvent` parent with an `IOHIDEventCreateDigitizerFingerEvent` child appended via `IOHIDEventAppendEvent`, run it through `IndigoHIDMessageForTrackpadEventFromHIDEventRef` (the only `*FromHIDEventRef` wrapper that accepts digitizer events), then patch four byte slots the wrapper leaves uninitialised — `0x6c` / `0x10c` with `0x32` (`IndigoHIDTouchTarget`) and `0x3a/0x3b` / `0xda/0xdb` with the `IndigoHIDEdge` bitmask (left=`0x02`, right=`0x04`, top=`0x08`, **bottom=`0x01`**). Bitmask values were derived empirically by sweeping `edge=0..4` through the working mouse-event signature and diffing produced bytes. `IndigoHIDInput.tap`, `swipe`, `touch1` (with optional `edge` field), and the new `swipeToHome` / `appSwitcher` buttons all route through this path; iOS's home-indicator gesture recognizer fires correctly on edge-flagged drags, and velocity/dwell discriminate Home from App Switcher inside iOS exactly as `Simulator.app` does. Verified end-to-end on iPhone 17 Pro Max / iOS 26.4 / Xcode 26: tap → app launches, edge swipe → home, slow edge drag with dwell → app-switcher cards. See [`docs/features/touches.md`](docs/features/touches.md) for the full recipe and the `diag-digitizer-trackpad` falsification probe.
- **`touch1-*` envelopes carry an optional `edge` field.** `bottom` / `top` / `left` / `right` flag every event in a streaming chain as a screen-edge system gesture. The browser focus-mode canvas auto-detects bottom-edge mousedown (drag start at `y/r.height ≥ 0.93`) and switches to live `touch1-*` streaming with `edge: "bottom"`, so iOS animates the home-card preview in real time as the user drags — same UX as dragging in `Simulator.app`, no client-side discriminator or buffered playback on release.
- **`app-switcher` and `swipe-to-home` virtual buttons.** Two new `Press`-compatible wire names route through `baguette press --udid …`, the wire JSON `{"type":"button"}`, the browser's `simInput.button(...)` bridge, and the focus-mode toolbar. Both ride the new digitizer dispatch with `edge=bottom`: `swipe-to-home` synthesizes a fast edge-flick (~12 × 16 ms steps to `y=0.30`); `app-switcher` synthesizes a slow drag-and-hold (~30 × 35 ms steps to `y=0.58` + 900 ms dwell). Use them when the agent wants the gesture vocabulary without managing a streaming chain manually; use streaming `touch1-*` with `edge: "bottom"` when the UI needs iOS's live preview during the drag.
- **Edge gestures fire in all four orientations.** The browser's orientation transport now rotates the `edge` flag alongside the touch coordinates so iOS's home-indicator gesture recognizer sees the correct physical-edge bit for the current rotation. Verified mapping for a visual-bottom drag: `portrait` → wire `bottom`, `landscape-left` (raw=4) → wire `right`, `portrait-upside-down` (raw=2) → wire `right`, `landscape-right` (raw=3) → wire `top`. CLI / wire callers still pass the device-frame edge directly; the orientation-aware remap is browser-side only.
- **Pull-down from the top edge opens the Lock Screen / Notification Center.** The browser canvas now detects a top-edge mousedown (`y / r.height ≤ 0.07`) the same way it detects a bottom-edge drag, and switches to live `touch1-*` streaming with `edge: "top"`. iOS's status-bar recognizer routes the swipe based on the start-x coordinate exactly like Simulator.app does — top-LEFT origin pulls the lock-screen cover sheet down, top-RIGHT origin opens Notification Center. Same UX as the bottom-edge home / app-switcher streaming: no client-side discriminator, iOS animates the cover sheet live as the cursor drags. Two new `Press`-compatible wire names back the canned shapes for CLI / scripting: `pull-down-to-lock-screen` (slow drag from `(0.25, 0.002)` to `(0.25, 0.55)` with `edge=top`) and `pull-down-to-notification-center` (slow drag from `(0.75, 0.002)` to `(0.75, 0.55)` with `edge=top`). Both ride `IOHIDDigitizerDispatch`.

### Fixed
- **App-switcher button no longer locks the screen ([#5](https://github.com/tddworks/baguette/issues/5)).** The third icon in the focus-mode toolbar carries the two-overlapping-squares glyph that mirrors `Simulator.app`'s app-switcher button, but it was wired to `simInput.button('lock')` — every click locked the device instead. The click now fires `simInput.button('app-switcher')` against the new virtual button described above. Lock remains reachable via `baguette press --udid … --button lock`; the focus-mode toolbar now matches `Simulator.app`'s Home / Screenshot / App Switcher trio.

### Changed
- **`app-switcher` button now rides the home-press recipe; the slow swipe-and-hold variant moves to `swipe-to-app-switcher`.** Originally `app-switcher` synthesized a slow edge-flagged drag from the home indicator with a 900 ms dwell at `y=0.58` and let iOS's home-indicator recognizer fire the multitasking carousel. That works but depends on the gesture path's velocity / dwell heuristics and rides the same digitizer dispatch as the home / lock-screen streams. `app-switcher` now decomposes into two consecutive `IndigoHIDMessageForButton` home presses ~150 ms apart — SpringBoard's own multitasking trigger, which fires on the home-button event source regardless of whether the device has physical home-button hardware. Cleaner, rotation-agnostic, and matches idb's `FBSimulatorPurpleHID` app-switcher path. The swipe-and-hold synthesis is preserved on the wire as a fifth virtual button, `swipe-to-app-switcher`, for callers that explicitly want the gesture path. Browser focus-mode toolbar's app-switcher icon now lands the home-press variant.

### Changed
- **`Simulator` is now a `@Mockable` protocol; `Simulators` is a true DDD repository.** The struct-with-`host`-delegation pattern grew to seven capability methods (`screen`, `input`, `accessibility`, `logs`, `orientation`, `boot`, `shutdown`) all parked on the aggregate, which read as a god-object. The aggregate now exposes only `all` / `find(udid:)` (plus the `running` / `available` / `listJSON` extensions); per-simulator capabilities live on the entity itself, owned by a new concrete `CoreSimulator` (Infrastructure) that holds a `DeviceHost` reference and resolves a fresh `SimDevice` on each operation. Domain default-impl extensions cover `canStream`, `canAcceptInput`, `json`, and `chrome(in:)`; identity getters and the new `SimulatorState` enum (lifted from the nested `Simulator.State`) are protocol contracts, not stored fields. Tests collapsed accordingly — 11 tautological / aggregate-delegation tests deleted, capability tests now drive `MockSimulator` directly via Mockable's auto-generated mock instead of `MockSimulators.screen(for: .value(s))`. CLI, HTTP, and browser surfaces are unchanged; this is a Domain rework only, motivated by giving each new capability (orientation just shipped, more coming) a stable home.
- **Boot in the simulator list no longer flashes the table.** Clicking **Boot** previously set `state.loading = true; render()` immediately, which wiped the device table and replaced it with a "Loading simulators…" placeholder before the POST even returned — the result felt like a full page refresh. The list now tracks per-device transition state in `state.pending` and shows an in-row "Booting…" / "Shutting down…" chip on just the affected row; the rest of the table stays put. The full-card placeholder is reserved for the *initial* fetch (`state.devices.length === 0`), so subsequent reloads (including the post-boot refresh) leave the existing list visible and only swap the row that changed.

---

## [0.1.68] - 2026-05-08

### Added
- **Accessibility inspector overlay in the browser UI.** Hovering the live stream now highlights the AX node under the cursor with a translucent box + role/label tooltip; clicking locks the selection and exposes **Copy id** / **Copy JSON** / **Tap (cx, cy)** actions. Two surfaces share one inspector module: a sidebar checkbox card on `/simulators` (sidebar mode) and a toolbar icon next to the bezel-actionable toggle on `/simulators/<UDID>` (focus mode), with selection details surfacing in a glass-styled floating panel anchored top-right of the device column. Hit-testing runs client-side against a cached AX tree (mirroring `AXNode.hitTest` on the Swift side, so the browser overlay and the `describe-ui --x --y` CLI always pick the same element). The cache is refreshed on every fresh hover (mouseenter on the screen) and every click — no polling timer; idle pages cost nothing. Reuses the existing `/simulators/:udid/stream` WebSocket (sends `{"type":"describe_ui"}`, receives `{"type":"describe_ui_result","ok":true,"tree":…}`); no new endpoints, no extra connections. The "Tap" button forwards the centre of the locked frame as a canonical `{"type":"tap","x":…,"y":…,"width":…,"height":…}` envelope, so the inspector composes with every gesture path. See [`docs/features/ax-inspector.md`](docs/features/ax-inspector.md).

### Changed
- **Logs panel no longer stalls the page under CoreDuet-chatter floods.** Server-side `LogBatcher` (`Domain/Logs/LogBatcher.swift`) coalesces emitted lines into bounded batches that flush either at a 200-line size cap or after a 50 ms time window, replacing the per-line `{"type":"log","line":"…"}` text frames with one `{"type":"log","lines":["…","…"]}` envelope per ~20 frames/sec; clients still tolerate the old single-line shape during rolling upgrades. The browser-side `LogPanel` (`Resources/Web/sim-logs.js`) now renders incrementally — only newly arrived lines pay the regex-colourize cost on a `DocumentFragment`-driven append, instead of `innerHTML`-rebuilding the whole 1500-row buffer per frame; filter / clear / level / reveal trigger a one-shot full rebuild. An `IntersectionObserver` pauses rendering entirely when the panel is hidden (collapsed sidebar, off-screen sheet) and does one rebuild on reveal. WS frame rate is now bounded at ~20/sec regardless of log volume, and per-frame DOM cost is O(new lines) instead of O(buffer). See [`docs/features/logs.md`](docs/features/logs.md).

---

## [0.1.67] - 2026-05-07

### Added
- **Live unified-log stream (`logs`).** New `baguette logs --udid <UDID> [--level …] [--style …] [--predicate …] [--bundle-id …]` CLI subcommand and dedicated `WS /simulators/:udid/logs?level=&style=&predicate=&bundleId=` socket stream the booted simulator's `os_log` output line-by-line, in real time. CLI writes one log line per stdout line and SIGINT (Ctrl-C) tears down cleanly; WS emits `{"type":"log","line":"<entry>"}` text frames bracketed by `log_started` / `log_stopped`. `--bundle-id` is a shorthand that translates to `process == "<id>"` and ANDs with an explicit `--predicate` when both are given. Adapter shells out to `xcrun simctl spawn <udid> log stream …` rather than calling `SimDevice.spawnWith…` directly — the direct path is published in CoreSimulator and *almost* works, but on iOS 26 the spawned `log` binary fails its `mbr_check_membership_ext("admin", …)` check unless the caller is Apple-signed (which `simctl` is and we aren't). simctl is guaranteed installed alongside our device set, so the indirection is cheap. Slimmer level set than the macOS host `log` binary: `default | info | debug` only — `notice / error / fault` are explicitly rejected at the wire because the iOS-runtime `log stream` doesn't accept them. See [`docs/features/logs.md`](docs/features/logs.md).
- **Accessibility tree extraction (`describe-ui`).** New `baguette describe-ui --udid <UDID> [--x <px> --y <px>]` CLI subcommand and `{"type":"describe_ui"}` WebSocket message dump the booted simulator's on-screen UI tree as JSON: per-node `role`, `label`, `value`, `identifier`, `frame` (in **device points**, ready to feed back into a `tap` envelope), plus `enabled` / `focused` / `hidden` traits and recursive `children`. Hit-test path returns the topmost AX element under a coordinate. Powered by the private `AccessibilityPlatformTranslation` framework's `AXPTranslator` — out of Simulator.app the tricky bit is wiring a `bridgeTokenDelegate` ourselves so the translator can route XPC requests to the right `SimDevice.sendAccessibilityRequestAsync:`; without that delegate every `frontmostApplication…` call returns `nil`. Cribbed the dispatcher pattern from `cameroncooke/AXe` and `Silbercue/SilbercueSwift`'s `AXPBridge.swift`. See [`docs/features/accessibility.md`](docs/features/accessibility.md).

### Fixed
- **Cloned simulators now resolve their bezel** ([#2](https://github.com/tddworks/baguette/issues/2)). `xcrun simctl clone` rewrites the device's display `name` (e.g. `iPhone 17 Pro Max` → `iPhone 17 pro max clone 1`), but `Simulator.chrome(in:)` was keying chrome lookup off that name — so `FileSystemChromeStore` searched for a non-existent `iPhone 17 pro max clone 1.simdevicetype` bundle and `/simulators/<udid>/chrome.json` + `/bezel.png` returned 404. `Simulator` now carries `deviceTypeName` (read from the live `SimDevice.deviceType.name`, which is stable across clones / renames) and chrome lookup keys off that. Falls back to the display `name` when the host doesn't supply one, so non-clones and existing tests behave identically.

---

## [0.1.66] - 2026-05-06

### Added
- **Hardware side buttons (action / volume-up / volume-down / power) on the wire and CLI.** Extended `DeviceButton` with the four arbitrary-HID side buttons and added `press(duration:on:)` so the rich domain owns its own dispatch. New CLI: `baguette press --button <name> [--duration <s>]` accepts the full set; the wire JSON gains an optional `duration` for long-press semantics ("Hold for Ring" on the action button, Siri / SOS on power, etc.). Routes through `IndigoHIDMessageForHIDArbitrary(target, page, usage, operation)` — the iOS-26-correct 4-arg shape, NOT the (page, usage, op, timestamp) signature some open-source loaders use. The browser bezel overlay measures real `mousedown` → `mouseup` and forwards the elapsed time, so click-and-hold on a side button just works. `siri` is still rejected (crashes `backboardd` through every known Indigo path). See [`docs/features/buttons.md`](docs/features/buttons.md).
- **Mac keyboard input on the wire, CLI, and web UI.** New `Key` / `TypeText` gestures and a focus-gated browser capture: when the device screen has focus, every supported keystroke is forwarded automatically; click out and the host browser shortcuts (Cmd+R, Cmd+T, …) work normally again. CLI mirrors the wire — `baguette key --code KeyA --modifiers shift,command [--duration <s>]` and `baguette type --text "hello"`. Phase 1 covers letters, digits, named specials (Enter / Escape / Backspace / Tab / Space / Arrow\*), US punctuation, and the four modifiers (shift / control / option / command); IME / non-Latin / emoji is deferred to phase 2's `IndigoHIDMessageForKeyboardNSEvent` path. Wire codes are W3C `KeyboardEvent.code` strings so the browser forwards events verbatim — no translation table on the JS side. Mounted on both focus mode (`/simulators/<udid>`) and the focused tile in the device farm. See [`docs/features/keyboard.md`](docs/features/keyboard.md).
- **`baguette list --json`** emits the same `{"running":[…],"available":[…]}` envelope that `/simulators.json` serves. Plain `baguette list` keeps its per-line projection so existing scripts that grep field-by-field don't break; `--json` opts into the structured shape for tools that want one parse + a `running` / `available` split. Reuses `Simulators.listJSON` so the CLI and HTTP outputs stay byte-identical.

### Changed
- **`/simulators` defaults to "All Runtimes"** so every booted simulator (e.g. iOS 26.2 alongside the latest 26.x) is visible on first load. The runtime dropdown now lists "All Runtimes" first, then "Latest Runtime", then individual runtimes; users who want only the latest can re-select it. Fixes a discoverability gap where a simulator booted on a non-latest runtime was hidden until the user scrolled the dropdown.

---

## [0.1.65] - 2026-05-04

### Changed
- Bug fixes and improvements.

---

## [0.1.64] - 2026-05-04

### Added
- **One-shot JPEG screenshot endpoint + CLI.** New `GET /simulators/:udid/screenshot.jpg[?quality=&scale=]` route on `baguette serve` returns the current framebuffer as `image/jpeg`, so embedding pages can refresh on demand with a plain `<img src="…?t=…">` — no WebSocket plumbing required. New `baguette screenshot --udid <UDID> [--output <path>] [--quality 0.85] [--scale 1]` CLI mirrors it; defaults write to stdout so it composes with shell redirection. Both share `ScreenSnapshot.capture(...)`: open Screen, await one IOSurface (2 s timeout with a single-shot guard for the timer / callback / start-throw race), encode via the existing `JPEGEncoder` + optional `Scaler`, stop. See [`docs/features/screenshot.md`](docs/features/screenshot.md).

---

## [0.1.63] - 2026-05-04

### Added
- **Focus mode at `/simulators/<udid>`** — visiting the deep-link URL directly now skips the device list and drops straight into a clean "play the simulator" view: the bezel takes the full viewport (height-driven) with a single floating glass toolbar above it, mirroring a SwiftUI `VStack { Toolbar; Device }`. The toolbar carries a clickable `‹ <name> · iOS <ver>` breadcrumb (back to list), an inline H.264 / MJPEG segmented control, action buttons (Home / Screenshot / App-switcher), and a live fps badge. Action buttons drive `SimInput.button(...)`; Screenshot grabs the live canvas and downloads a PNG. Reuses the existing `DeviceFrame`, `StreamSession`, `SimInput`, `MouseGestureSource`, and `PinchOverlay` modules — no new transport, no new server route. Lives in `Resources/Web/sim-native.html` + `sim-native.js`; loaded by `sim.html` and synchronously sets `window.__baguetteNativeMode` so `sim-list.js` bails out before painting the list shell.
- **Light + dark theme with manual toggle.** Focus mode tokenises every colour at `#simNativeView` (`--nv-page-bg`, `--nv-bar-bg`, `--nv-text`, …) and tracks `prefers-color-scheme` by default. A floating glass pill in the bottom-right corner (`__nativeToggleTheme`) lets the user pin a theme, persisted to `localStorage.baguette.simTheme`; the pinned attribute beats the media query so manual choice always wins over the OS preference. Sun icon shows in light theme, moon in dark.

### Changed
- **`SimInputBridge` is now shared by the single-device pages too.** `sim.html` loads `sim-input-bridge.js`, and both `sim-stream.js` (sidebar mode) and `sim-native.js` (focus mode) call `window.SimInputBridge.makeTransport(session, log)` instead of carrying private `toBaguetteWire` + `phasedTouchWire` copies. ~140 lines of duplicated dialect translation removed; `farm-tile.js`, `sim-stream.js`, and `sim-native.js` now share one source of truth for the SimInput → Baguette wire-format mapping.

---

## [0.1.62] - 2026-05-03

### Changed
- Bug fixes and improvements.

---

## [0.1.61] - 2026-05-03

### Fixed
- **`baguette serve` no longer fails to launch when Xcode lives outside `/Applications/Xcode.app`** ([#1](https://github.com/tddworks/baguette/issues/1)). Two layers:
  - **Link-time:** `Package.swift` was declaring `SimulatorKit` and `CoreSimulator` as `linkedFramework`s, which baked LC_LOAD_DYLIB entries that dyld had to resolve before `main()` ran — and the rpaths it baked alongside them only matched `/Applications/Xcode.app`. Users with Xcode at e.g. `/Applications/Xcode_26.app` got `Library not loaded: @rpath/SimulatorKit.framework` and an immediate abort. Nothing in `Sources/` actually `import`s either framework, so the entries (and their rpath / `-F` flags) are gone; the binary now starts cleanly anywhere.
  - **Runtime:** `CoreSimulators.developerDir()` blindly trusted `xcode-select -p`, which on many machines points at `/Library/Developer/CommandLineTools` (no SimulatorKit) — particularly after a user renames their Xcode bundle. The resolver now verifies that `SimulatorKit.framework` actually exists at the selected developer directory and, if not, scans `/Applications` for any `Xcode*.app` (preferring the canonical `Xcode.app`) whose `Contents/Developer` does have it.

---

## [0.1.6] - 2026-05-03

### Added
- **Browser-side recording.** Record button in the single-device sidebar (`/simulators/<udid>`) and the device-farm focus pane (`/farm`) captures the live view to a downloadable WebM/MP4. The recording reuses what's already on the page — bezel `<img>`, decoded canvas, PinchOverlay's existing dot positions — and composites them into a recording-only canvas while active; idle cost is zero. Chrome / Safari preference for MP4 (H.264), WebM (VP9 / VP8) fallback. Exposed as `BrowserRecorder` in `Resources/Web/recorder.js`. See [`docs/features/recording.md`](docs/features/recording.md).
- **Auto-bump live stream quality during recording.** When Record is pressed on `/simulators/<udid>`, the stream is reconfigured to scale=1, 60 fps, 8 Mbps so the source canvas is at native resolution before drawImage scales into the composite — restored to the user's previous preset on Stop.

### Changed
- **MediaRecorder defaults tuned for visible quality** — `videoBitsPerSecond: 12_000_000` and `imageSmoothingQuality: 'high'` on the compose canvas, both overridable per `BrowserRecorder` instance.
- 
---

## [0.1.5] - 2026-05-03

### Changed
- Bug fixes and improvements.

---

## [0.1.4] - 2026-05-03

### Added
- **Device farm — interactive multi-device control surface served by `baguette serve`.** A standalone web UI that streams every booted simulator side-by-side, with filtering, sorting, wall / list view modes, and live telemetry per tile. Pieces:
  - **Bezel display mode** with `DeviceFrame` integration; falls back to **9-slice bezel composition** when a device has no packaged frame asset. Chrome buttons can layer above the viewport via `onTop` z-order.
  - **Input round-trips through the existing pipeline** — `SimInputBridge` wires the farm UI's gestures, hardware buttons, and pinch overlay into `GestureDispatcher` → `IndigoHIDInput`, so anything the CLI can drive, the farm UI can drive.
  - **Focused tile mirroring** is a canvas copy — the focus pane re-parents the source canvas directly rather than spinning up a separate `<video>` element.

### Changed
- **Farm grid rendering optimized** — selection updates use delta diffs instead of full re-mounting; element mounting and bezel rendering reworked for fewer DOM writes per frame; wall view layout unified and flexbox-centered.

### Fixed
- **Wrapper sizing now matches bezel image dimensions** so device frames align in the farm grid.
- **Element rendering in raw (no-bezel) mode** correctly handles toggling display modes.
- **`ReconfigParser` number parsing** simplified to handle numeric casting consistently.

---

[Unreleased]: https://github.com/tddworks/baguette/compare/v0.1.82...HEAD
[0.1.82]: https://github.com/tddworks/baguette/compare/v0.1.81...v0.1.82
[0.1.81]: https://github.com/tddworks/baguette/compare/v0.1.80...v0.1.81
[0.1.80]: https://github.com/tddworks/baguette/compare/v0.1.79...v0.1.80
[0.1.79]: https://github.com/tddworks/baguette/compare/v0.1.78...v0.1.79
[0.1.78]: https://github.com/tddworks/baguette/compare/v0.1.77...v0.1.78
[0.1.77]: https://github.com/tddworks/baguette/compare/v0.1.76...v0.1.77
[0.1.76]: https://github.com/tddworks/baguette/compare/v0.1.75...v0.1.76
[0.1.75]: https://github.com/tddworks/baguette/compare/v0.1.74...v0.1.75
[0.1.74]: https://github.com/tddworks/baguette/compare/v0.1.73...v0.1.74
[0.1.73]: https://github.com/tddworks/baguette/compare/v0.1.72...v0.1.73
[0.1.72]: https://github.com/tddworks/baguette/compare/v0.1.71...v0.1.72
[0.1.71]: https://github.com/tddworks/baguette/compare/v0.1.70...v0.1.71
[0.1.70]: https://github.com/tddworks/baguette/compare/v0.1.69...v0.1.70
[0.1.69]: https://github.com/tddworks/baguette/compare/v0.1.68...v0.1.69
[0.1.68]: https://github.com/tddworks/baguette/compare/v0.1.67...v0.1.68
[0.1.67]: https://github.com/tddworks/baguette/compare/v0.1.66...v0.1.67
[0.1.66]: https://github.com/tddworks/baguette/compare/v0.1.65...v0.1.66
[0.1.65]: https://github.com/tddworks/baguette/compare/v0.1.64...v0.1.65
[0.1.64]: https://github.com/tddworks/baguette/compare/v0.1.63...v0.1.64
[0.1.63]: https://github.com/tddworks/baguette/compare/v0.1.62...v0.1.63
[0.1.62]: https://github.com/tddworks/baguette/compare/v0.1.61...v0.1.62
[0.1.61]: https://github.com/tddworks/baguette/compare/v0.1.6...v0.1.61
[0.1.6]: https://github.com/tddworks/baguette/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/tddworks/baguette/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/tddworks/baguette/compare/v0.1.1...v0.1.4
