import AVFoundation
import Foundation

@MainActor
final class SoundPlayer {
    private var players: [String: AVAudioPlayer] = [:]
    /// `startPurring` is driven from the frame loop every tick while the cursor pets the head;
    /// this flag makes repeat calls free instead of hitting AVAudioPlayer properties at 120 Hz.
    private var purringActive = false

    func playCompletion(volume: Double) { play("meow", volume: clamped(volume)) }
    func playReminder(volume: Double, repeatAfter: Bool = false) {
        let alertVolume = clamped(volume * 2.4)
        play("meow-alert", volume: alertVolume)
        if repeatAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.play("meow-alert", volume: alertVolume) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { self.play("meow-alert", volume: alertVolume) }
        }
    }
    func startPurring() {
        guard !purringActive else { return }
        purringActive = true
        loop("purring", volume: 0.28)
    }
    func stopPurring() {
        guard purringActive else { return }
        purringActive = false
        players["purring"]?.stop()
        players["purring"]?.currentTime = 0
    }

    private func play(_ name: String, volume: Double) {
        let volume = clamped(volume)
        guard volume > 0, let player = player(name) else { return }
        player.numberOfLoops = 0
        player.volume = Float(volume)
        player.currentTime = 0
        player.play()
    }

    private func loop(_ name: String, volume: Double) {
        guard let player = player(name) else { return }
        player.numberOfLoops = -1
        player.volume = Float(clamped(volume))
        if !player.isPlaying { player.play() }
    }

    private func clamped(_ volume: Double) -> Double {
        min(1, max(0, volume))
    }

    private func player(_ name: String) -> AVAudioPlayer? {
        if let p = players[name] { return p }
        guard
            let url = Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: "sounds")
                ?? Bundle.main.url(forResource: name, withExtension: "m4a"), let p = try? AVAudioPlayer(contentsOf: url)
        else { return nil }
        p.prepareToPlay()
        players[name] = p
        return p
    }
}
