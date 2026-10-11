import AppKit
import XCTest
@testable import Goldfish

final class ClipboardSoundServiceTests: IsolatedTestCase {
  private var defaults: UserDefaults!
  private var settings: SettingsModel!

  override func setUpWithError() throws {
    defaults = makeTestDefaults()
    settings = SettingsModel(defaults: defaults)
  }

  func testSoundPreferencesAreOptInPersistIndependentlyAndClampVolume() {
    XCTAssertFalse(settings.copySoundEnabled)
    XCTAssertFalse(settings.pasteSoundEnabled)
    XCTAssertEqual(settings.soundVolume, 0.30)
    var changes: [SettingsModel.Change] = []
    settings.observe { changes.append($0) }
    settings.copySoundEnabled = true
    settings.pasteSoundEnabled = true
    settings.soundVolume = 0.18
    XCTAssertEqual(changes, [.soundEffects, .soundEffects, .soundEffects])
    var restored = SettingsModel(defaults: defaults)
    XCTAssertTrue(restored.copySoundEnabled)
    XCTAssertTrue(restored.pasteSoundEnabled)
    XCTAssertEqual(restored.soundVolume, 0.18)
    settings.copySoundEnabled = false
    restored = SettingsModel(defaults: defaults)
    XCTAssertFalse(restored.copySoundEnabled)
    XCTAssertTrue(restored.pasteSoundEnabled)
    settings.soundVolume = -2
    XCTAssertEqual(settings.soundVolume, 0)
    settings.soundVolume = 3
    XCTAssertEqual(settings.soundVolume, 1)
    settings.soundVolume = .nan
    XCTAssertEqual(settings.soundVolume, 0.30)
    defaults.set(Double.infinity, forKey: SettingsModel.Keys.soundVolume)
    XCTAssertEqual(SettingsModel(defaults: defaults).soundVolume, 0.30)
  }

  func testDisabledCuesAreSilentAndPreviewsDoNotEnableThem() {
    var now: TimeInterval = 0
    var played: [ClipboardSound] = []
    let sound = makeService(uptime: { now }, output: { cue, _ in
      played.append(cue); return true
    })
    XCTAssertFalse(sound.play(.copy))
    XCTAssertFalse(sound.play(.paste))
    XCTAssertTrue(sound.play(.copy, preview: true))
    XCTAssertFalse(settings.copySoundEnabled)
    now = 1
    settings.pasteSoundEnabled = true
    XCTAssertFalse(sound.play(.copy))
    XCTAssertTrue(sound.play(.paste))
    now = 2
    settings.soundVolume = 0
    XCTAssertFalse(sound.play(.paste))
    XCTAssertFalse(sound.play(.copy, preview: true))
    XCTAssertEqual(played, [.copy, .paste])
  }

  func testRapidCopiesDoNotStackAndBecomeQuieterUntilTheBurstEnds() {
    settings.copySoundEnabled = true
    settings.pasteSoundEnabled = true
    var now: TimeInterval = 0
    var played: [(ClipboardSound, Float)] = []
    let sound = makeService(uptime: { now }, output: { cue, volume in
      played.append((cue, volume)); return true
    })
    XCTAssertTrue(sound.play(.copy))
    for _ in 0..<10 { now += 0.01; XCTAssertFalse(sound.play(.copy)) }
    XCTAssertEqual(played.count, 1)
    now = 0.21; XCTAssertTrue(sound.play(.copy))
    now = 0.42; XCTAssertTrue(sound.play(.copy))
    XCTAssertEqual(played.count, 3)
    guard played.count == 3 else { return }
    XCTAssertLessThan(played[1].1, played[0].1)
    XCTAssertLessThan(played[2].1, played[1].1)
    now = 0.43; XCTAssertFalse(sound.play(.paste), "Even different cues must not overlap")
    now = 0.56; XCTAssertTrue(sound.play(.paste), "A quick copy-paste pair can have distinct feedback")
    now = 2; XCTAssertTrue(sound.play(.copy))
    XCTAssertEqual(played.last?.1, played.first?.1)
    XCTAssertEqual(played.count, 5, "Suppressed sounds must never be queued")
  }

  func testUnavailableOutputDoesNotPreventTheNextCue() {
    settings.copySoundEnabled = true
    var available = false
    let sound = makeService(uptime: { 0 }, output: { _, _ in available })
    XCTAssertFalse(sound.play(.copy))
    available = true
    XCTAssertTrue(sound.play(.copy))
  }

  func testPreviewCanInterruptBusyOutputAndRewindsTheCue() {
    let player = TestSound()
    let service = ClipboardSoundService(settings: settings, uptime: { 0 }, makeSound: { _ in player })
    XCTAssertTrue(service.play(.copy, preview: true))
    player.currentTime = 0.05
    XCTAssertTrue(service.play(.copy, preview: true), "A preview is an explicit request, not a copy burst")
    XCTAssertEqual(player.currentTime, 0)
    XCTAssertEqual(player.starts, 2)
    XCTAssertEqual(player.stops, 1)
    XCTAssertFalse(settings.copySoundEnabled)
  }

  func testFailedPlayerIsRecreatedWithoutDelayingTheNextAttempt() {
    settings.copySoundEnabled = true
    var attempts = 0
    let service = ClipboardSoundService(settings: settings, uptime: { 0 }, makeSound: { _ in
      attempts += 1
      let player = TestSound()
      let available = attempts > 1
      player.output = { _ in available }
      return player
    })
    XCTAssertFalse(service.play(.copy))
    XCTAssertTrue(service.play(.copy))
    XCTAssertEqual(attempts, 2, "An unavailable output must not leave a broken player cached")
  }

  func testBothCuesDecodeAsShortQuietAudioWithoutAbruptEdges() throws {
    for cue in ClipboardSound.allCases {
      let data = cue.waveData
      let sound = try XCTUnwrap(NSSound(data: data))
      XCTAssertGreaterThan(sound.duration, 0.04)
      XCTAssertLessThan(sound.duration, 0.12)
      let bytes = Array(data.dropFirst(44))
      let samples = stride(from: 0, to: bytes.count, by: 2).map {
        Double(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / Double(Int16.max)
      }
      XCTAssertEqual(samples.first, 0)
      XCTAssertEqual(samples.last, 0)
      let peak = try XCTUnwrap(samples.map(abs).max())
      XCTAssertGreaterThan(peak, 0.1)
      XCTAssertLessThan(peak, 0.65, "Retain headroom even at full user volume")
      XCTAssertLessThan(abs(samples.reduce(0, +) / Double(samples.count)), 0.01)
      let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
      XCTAssertGreaterThan(rms, 0.065, "The click must have enough body to be audible at a quiet setting")
      XCTAssertLessThan(rms, 0.18, "Keep a short transient rather than a sustained alert")
      if let directory = ProcessInfo.processInfo.environment["GOLDFISH_SOUND_REVIEW"] {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(cue == .copy ? "copy.wav" : "paste.wav"))
      }
    }
    XCTAssertNotEqual(ClipboardSound.copy.waveData, ClipboardSound.paste.waveData)
  }

  private func makeService(uptime: @escaping () -> TimeInterval,
    output: @escaping (ClipboardSound, Float) -> Bool) -> ClipboardSoundService {
    ClipboardSoundService(settings: settings, uptime: uptime, makeSound: { cue in
      let player = TestSound()
      player.output = { output(cue, $0) }
      return player
    })
  }
}

/// Device playback can remain active after the audible samples have ended.
/// Keep that state until stopped so tests exercise the real playback branch.
private final class TestSound: ClipboardSoundPlayback {
  private var reportsPlaybackInProgress = false
  private(set) var starts = 0
  private(set) var stops = 0
  var output: (Float) -> Bool = { _ in true }
  var isPlaying: Bool { reportsPlaybackInProgress }
  var volume: Float = 1
  var currentTime: TimeInterval = 0

  func play() -> Bool {
    guard output(volume) else { return false }
    starts += 1
    reportsPlaybackInProgress = true
    return true
  }

  func stop() -> Bool {
    stops += 1
    reportsPlaybackInProgress = false
    return true
  }
}
