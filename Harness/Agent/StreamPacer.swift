//
//  StreamPacer.swift
//  Harness
//

import Foundation
import Observation
import QuartzCore

/// Smooths bursty network text for display.
///
/// The network appends text in irregular bursts. The pacer buffers it and reveals it on every
/// display frame at an adaptive rate, `max(baseRate, backlog / targetLatency)`: slow streams look
/// steady, and fast streams never trail the network by much more than `targetLatency`.
/// It publishes whole words only, so a growing word never jumps to the next line.
@Observable
final class StreamPacer {
    /// Characters per second when the backlog is small.
    static let baseRate: Double = 60
    /// How far, in seconds, the display may trail the network.
    static let targetLatency: Double = 0.35
    /// After the stream ends, the rest of the text drains within this many seconds.
    static let finalDrain: Double = 0.5

    /// The text to show: whole words, revealed at a steady rhythm.
    private(set) var displayedText = ""

    @ObservationIgnored private var characters: [Character] = []
    /// Reveal position in characters. Fractional so that slow rates still advance each frame.
    @ObservationIgnored private var cursor: Double = 0
    @ObservationIgnored private var publishedCount = 0
    @ObservationIgnored private var isFinished = false
    @ObservationIgnored private var finishDeadline: CFTimeInterval = 0
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    @ObservationIgnored private var displayLink: CADisplayLink?

    /// Accepts the full text received so far. Network text only grows, so only the new suffix is buffered.
    func receive(_ fullText: String) {
        let newCharacters = fullText.dropFirst(characters.count)
        guard !newCharacters.isEmpty else { return }
        characters.append(contentsOf: newCharacters)
        startDisplayLink()
    }

    /// Marks the stream complete and waits until the rest of the text is on screen (at most about a second).
    func finish() async {
        isFinished = true
        finishDeadline = CACurrentMediaTime() + Self.finalDrain
        startDisplayLink()
        let hardStop = ContinuousClock.now + .seconds(Self.finalDrain + 0.5)
        while Int(cursor) < characters.count, ContinuousClock.now < hardStop {
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                break // Cancelled: show everything now.
            }
        }
        cursor = Double(characters.count)
        publish()
        stopDisplayLink()
    }

    /// Clears all text, ready for the next stream.
    func reset() {
        stopDisplayLink()
        characters = []
        cursor = 0
        publishedCount = 0
        isFinished = false
        if !displayedText.isEmpty { displayedText = "" }
    }

    // MARK: - Frame clock

    fileprivate func step(_ link: CADisplayLink) {
        let now = link.timestamp
        // Cap the step so that a stall (for example, the app in the background) does not dump text at once.
        let elapsed = lastTimestamp.map { min(now - $0, 0.1) } ?? link.duration
        lastTimestamp = now

        let backlog = Double(characters.count) - cursor
        guard backlog > 0 else {
            publish()
            // Nothing to reveal: stop until more text arrives, to save power.
            stopDisplayLink()
            return
        }

        var rate = max(Self.baseRate, backlog / Self.targetLatency)
        if isFinished {
            rate = max(rate, backlog / max(finishDeadline - now, link.duration))
        }
        cursor = min(Double(characters.count), cursor + rate * elapsed)
        publish()
    }

    private func publish() {
        var end = Int(cursor)
        let showEverything = isFinished && end >= characters.count
        if !showEverything {
            // Whole words only: stop before a word that is not complete yet.
            let nextIsWhitespace = end < characters.count && characters[end].isWhitespace
            if !nextIsWhitespace {
                while end > 0 && !characters[end - 1].isWhitespace { end -= 1 }
            }
        }
        guard end != publishedCount else { return }
        publishedCount = end
        displayedText = String(characters[0..<end])
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }
}

/// CADisplayLink keeps a strong reference to its target; the proxy holds the pacer weakly.
private final class DisplayLinkProxy: NSObject {
    weak var pacer: StreamPacer?

    init(_ pacer: StreamPacer) {
        self.pacer = pacer
    }

    @objc func step(_ link: CADisplayLink) {
        if let pacer {
            pacer.step(link)
        } else {
            link.invalidate()
        }
    }
}
