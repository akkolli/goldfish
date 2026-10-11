import AppKit

enum TransferSound: CaseIterable, Hashable {
  case copy, paste

  /// An original miniature shutter: a crisp contact followed by a softer latch.
  /// Paste has a slightly deeper, wider double click. No ringing or long tail.
  var waveData: Data {
    let sampleRate = 44_100
    let duration = self == .copy ? 0.075 : 0.095
    let pitch = self == .copy ? 1.0 : 0.82
    let latchDelay = self == .copy ? 0.016 : 0.026
    let latchLevel = self == .copy ? 0.48 : 0.72
    let count = Int(Double(sampleRate) * duration)
    var samples = [Double]()
    samples.reserveCapacity(count)
    var noiseState: UInt32 = self == .copy ? 0xC011 : 0xFA57
    var filteredNoise = 0.0

    func contact(_ time: Double, texture: Double) -> Double {
      guard time >= 0 else { return 0 }
      let attack = pow(sin(min(1, time / 0.0006) * .pi / 2), 2)
      let snap = 0.30 * sin(2 * .pi * 1_850 * pitch * time) * exp(-time / 0.003)
      let body = 0.42 * sin(2 * .pi * 820 * pitch * time) * exp(-time / 0.010)
      let grain = 0.85 * texture * exp(-time / 0.006)
      return attack * (snap + body + grain)
    }

    for index in 0..<count {
      let time = Double(index) / Double(sampleRate)
      noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
      let noise = Double(noiseState) / Double(UInt32.max) * 2 - 1
      filteredNoise += 0.32 * (noise - filteredNoise)
      let release = min(1, Double(count - 1 - index) / Double(sampleRate) / 0.006)
      samples.append(
        (contact(time, texture: filteredNoise) + latchLevel * contact(time - latchDelay, texture: filteredNoise)) * release * release)
    }
    let gain = 0.60 / max(0.001, samples.map(abs).max() ?? 1)
    var pcm = Data(capacity: count * 2)
    for sample in samples { pcm.appendLittleEndian(Int16((sample * gain * Double(Int16.max)).rounded())) }
    var data = Data("RIFF".utf8)
    data.appendLittleEndian(UInt32(36 + pcm.count))
    data.append(Data("WAVEfmt ".utf8))
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))  // Linear PCM
    data.appendLittleEndian(UInt16(1))  // Mono, centered in both ears
    data.appendLittleEndian(UInt32(sampleRate))
    data.appendLittleEndian(UInt32(sampleRate * 2))
    data.appendLittleEndian(UInt16(2))
    data.appendLittleEndian(UInt16(16))
    data.append(Data("data".utf8))
    data.appendLittleEndian(UInt32(pcm.count))
    data.append(pcm)
    return data
  }
}

protocol ClipboardSoundPlayback: AnyObject {
  var isPlaying: Bool { get }
  var volume: Float { get set }
  var currentTime: TimeInterval { get set }
  @discardableResult func play() -> Bool
  @discardableResult func stop() -> Bool
}

extension NSSound: ClipboardSoundPlayback {}

/// Owned by the app and used on its main queue. Playback never queues work or
/// modifies system volume. Existing capture exclusions determine copy feedback.
final class TransferSounds {
  private let settings: SettingsModel
  private let uptime: () -> TimeInterval
  private let makeSound: (TransferSound) -> ClipboardSoundPlayback?
  private var sounds: [TransferSound: ClipboardSoundPlayback] = [:]
  private var lastSound: TransferSound?
  private var lastPlayedAt: TimeInterval?
  private var burstCount = 0

  init(
    settings: SettingsModel, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    makeSound: @escaping (TransferSound) -> ClipboardSoundPlayback? = { NSSound(data: $0.waveData) }
  ) {
    self.settings = settings
    self.uptime = uptime
    self.makeSound = makeSound
  }

  @discardableResult func play(_ cue: TransferSound, preview: Bool = false) -> Bool {
    let enabled = cue == .copy ? settings.copySoundEnabled : settings.pasteSoundEnabled
    guard preview || enabled, settings.soundVolume > 0 else { return false }
    let now = uptime()
    let elapsed = lastPlayedAt.map { now - $0 } ?? .infinity
    // Leave air between cues; bursts become quieter and are never replayed later.
    guard preview || elapsed >= (lastSound == cue ? 0.20 : 0.12) else { return false }
    let nextBurst = preview || elapsed >= 0.8 ? 1 : min(burstCount + 1, 4)
    let softness: Float = [1, 0.85, 0.70, 0.60][nextBurst - 1]
    let volume = Float(settings.soundVolume) * softness
    if sounds[cue] == nil { sounds[cue] = makeSound(cue) }
    guard let sound = sounds[cue] else { return false }
    // Bluetooth output can remain "playing" long after these samples finish.
    // The interval above limits repeats; release the old playback instead of
    // dropping a valid cue while the device drains its output buffers.
    for previous in sounds.values where previous.isPlaying { previous.stop() }
    sound.currentTime = 0
    sound.volume = volume
    let didPlay = sound.play()
    if didPlay {
      lastPlayedAt = now
      lastSound = cue
      burstCount = nextBurst
    } else {
      sounds[cue] = nil
    }
    return didPlay
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}
