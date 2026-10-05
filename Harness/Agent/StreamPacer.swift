//
//  StreamPacer.swift
//  Harness
//

import Foundation
import Observation
import QuartzCore
import SwiftUI

/// Smooths bursty network text for display, block by block.
///
/// Text is split into the blocks `MarkdownText` renders: paragraphs, list items, and headings
/// (never inside a code fence). On each display frame:
/// - If the next block has fully arrived, it is revealed as one unit with a short fade
///   (`blockReveal`). All complete blocks that are waiting are revealed together, at most once per
///   `minimumBlockInterval`, so a queue never builds lag.
/// - If the next block is still arriving, the pacer waits until its first character is
///   `targetLatency` old. If the block completes in that time, it is revealed as a block. If not, it is
///   revealed word by word at `max(baseRate, backlog / targetLatency)`, whole words only, so a growing
///   word never jumps lines.
/// Fast streams therefore show finished blocks and slow streams show words, without any throughput
/// threshold: the mode follows from whether a block completes within the latency budget. The decision
/// is made once per block, so the mode never flaps within a block.
@Observable
final class StreamPacer {
    /// Characters per second for word reveal when the backlog is small.
    static let baseRate: Double = 60
    /// How far, in seconds, word reveal may trail the network.
    static let targetLatency: Double = 0.35
    /// After the stream ends, the rest of the text appears within this many seconds.
    static let finalDrain: Double = 0.5
    /// Nothing is shown for this long after the first text arrives. A reply that completes in this
    /// window appears all at once, with one fade.
    static let initialHold: CFTimeInterval = 0.3
    /// Minimum time between block reveals.
    static let minimumBlockInterval: CFTimeInterval = 0.12
    /// The fade used when blocks appear. Views pair it with an opacity + 6 pt upward slide transition.
    static let blockReveal = Animation.easeOut(duration: 0.15)

    /// The text to show.
    private(set) var displayedText = ""
    /// Set by the view when the end of the displayed text is below the visible area. Nobody is
    /// watching there, so the pacer reveals everything at once until the reveal point is visible again.
    @ObservationIgnored var isRevealPointOffscreen = false

    @ObservationIgnored private var characters: [Character] = []
    /// One entry per network update: the character count after it, and when it arrived.
    @ObservationIgnored private var arrivals: [(endCount: Int, time: CFTimeInterval)] = []
    /// Reveal position in characters. Fractional so that slow word reveal still advances each frame.
    @ObservationIgnored private var cursor: Double = 0
    @ObservationIgnored private var publishedCount = 0
    @ObservationIgnored private var isFinished = false
    @ObservationIgnored private var finishDeadline: CFTimeInterval = 0
    @ObservationIgnored private var holdUntil: CFTimeInterval?
    @ObservationIgnored private var lastBlockReveal: CFTimeInterval = 0
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    @ObservationIgnored private var displayLink: CADisplayLink?

    // Incremental block scanner state.
    /// Start index of every block after the first, ascending. A block starts after a blank line outside a code fence.
    @ObservationIgnored private(set) var blockStarts: [Int] = []
    @ObservationIgnored private var scanIndex = 0
    @ObservationIgnored private var lineStart = 0
    @ObservationIgnored private var inCodeFence = false
    @ObservationIgnored private var blockHasContent = false

    // MARK: - Input

    /// Accepts the full text received so far. Network text only grows, so only the new suffix is buffered.
    func receive(_ fullText: String) {
        let newCharacters = fullText.dropFirst(characters.count)
        guard !newCharacters.isEmpty else { return }
        let now = CACurrentMediaTime()
        if holdUntil == nil { holdUntil = now + Self.initialHold }
        characters.append(contentsOf: newCharacters)
        arrivals.append((characters.count, now))
        scanForBlocks()
        startDisplayLink()
    }

    /// Marks the stream complete and waits until all text is on screen (at most about a second).
    func finish() async {
        isFinished = true
        guard !characters.isEmpty else { return }

        // Short reply: it completed inside the initial hold, so show it all in one fade.
        if publishedCount == 0, let holdUntil, CACurrentMediaTime() < holdUntil {
            revealAll()
            return
        }

        finishDeadline = CACurrentMediaTime() + Self.finalDrain
        startDisplayLink()
        let hardStop = ContinuousClock.now + .seconds(Self.finalDrain + 0.5)
        while publishedCount < characters.count, ContinuousClock.now < hardStop {
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                break // Cancelled: show everything now.
            }
        }
        revealAll()
    }

    /// Clears all text, ready for the next stream.
    func reset() {
        stopDisplayLink()
        characters = []
        arrivals = []
        cursor = 0
        publishedCount = 0
        isFinished = false
        holdUntil = nil
        lastBlockReveal = 0
        blockStarts = []
        scanIndex = 0
        lineStart = 0
        inCodeFence = false
        blockHasContent = false
        if !displayedText.isEmpty { displayedText = "" }
    }

    // MARK: - Blocks

    /// Finds block boundaries in newly received text. Blocks match what `MarkdownText` renders as
    /// separate views: paragraphs (ended by a blank line), and each list item and heading line.
    /// Nothing inside a code fence is a boundary.
    private func scanForBlocks() {
        while scanIndex < characters.count {
            if characters[scanIndex] == "\n" {
                let line = characters[lineStart..<scanIndex]
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                if trimmed.starts(with: ["`", "`", "`"]) {
                    inCodeFence.toggle()
                    blockHasContent = true
                } else if inCodeFence {
                    blockHasContent = true
                } else if trimmed.allSatisfy(\.isWhitespace) {
                    if blockHasContent { addBoundary(scanIndex + 1) }
                } else if Self.isListItemOrHeading(trimmed) {
                    // The line is its own block: end any paragraph before it, and end it at its newline.
                    if blockHasContent { addBoundary(lineStart) }
                    addBoundary(scanIndex + 1)
                } else {
                    blockHasContent = true
                }
                lineStart = scanIndex + 1
            }
            scanIndex += 1
        }
    }

    private func addBoundary(_ index: Int) {
        if index > (blockStarts.last ?? 0) { blockStarts.append(index) }
        blockHasContent = false
    }

    /// Same rules as `MarkdownBlock.parse`: "- ", "* ", "+ ", "1. ", or "# " … "###### ".
    private static func isListItemOrHeading(_ line: ArraySlice<Character>) -> Bool {
        if line.starts(with: ["-", " "]) || line.starts(with: ["*", " "]) || line.starts(with: ["+", " "]) { return true }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, line.dropFirst(digits.count).starts(with: [".", " "]) { return true }
        let hashes = line.prefix(while: { $0 == "#" }).count
        return (1...6).contains(hashes) && line.dropFirst(hashes).first == " "
    }

    /// The end (exclusive) of the block that contains `position`, if that block has fully arrived.
    private func completeBlockEnd(containing position: Int) -> Int? {
        if let next = blockStarts.first(where: { $0 > position }) { return next }
        return isFinished ? characters.count : nil
    }

    private func isBlockStart(_ position: Int) -> Bool {
        position == 0 || blockStarts.contains(position)
    }

    /// When the character at `position` arrived from the network.
    private func arrivalTime(of position: Int) -> CFTimeInterval? {
        arrivals.first { $0.endCount > position }?.time
    }

    // MARK: - Frame clock

    fileprivate func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let elapsed = lastTimestamp.map { min(now - $0, 0.1) } ?? link.duration
        lastTimestamp = now

        let count = characters.count
        let position = Int(cursor)
        guard position < count else {
            publish(animated: false)
            stopDisplayLink() // Nothing to reveal: stop until more text arrives, to save power.
            return
        }
        if let holdUntil, now < holdUntil { return }

        // Below the fold: skip pacing.
        if isRevealPointOffscreen {
            cursor = Double(count)
            publish(animated: false)
            return
        }

        // Block mode: the next block has fully arrived. Reveal it, plus any complete blocks behind it.
        if isBlockStart(position), var end = completeBlockEnd(containing: position) {
            guard now - lastBlockReveal >= Self.minimumBlockInterval else { return }
            while end < count, let next = completeBlockEnd(containing: end) { end = next }
            cursor = Double(end)
            lastBlockReveal = now
            publish(animated: true)
            return
        }

        // At the start of a block that is still arriving: wait while it is younger than the latency
        // budget. A fast stream completes it in that time (block mode on the next frame); a slow one
        // does not, and word reveal starts. The decision is made once per block, so modes never flap.
        if isBlockStart(position), let arrived = arrivalTime(of: position), now - arrived < Self.targetLatency {
            return
        }

        // Word mode: the block is still arriving (or was when its reveal started). Stop at its end,
        // so the next block gets its own block-or-word decision.
        let limit = completeBlockEnd(containing: position) ?? count
        let backlog = Double(count) - cursor
        var rate = max(Self.baseRate, backlog / Self.targetLatency)
        if isFinished {
            rate = max(rate, backlog / max(finishDeadline - now, link.duration))
        }
        cursor = min(Double(limit), cursor + rate * elapsed)
        publish(animated: false)
    }

    private func revealAll() {
        stopDisplayLink()
        cursor = Double(characters.count)
        publish(animated: true)
    }

    private func publish(animated: Bool) {
        var end = Int(cursor)
        let atBlockEnd = end == characters.count ? isFinished : blockStarts.contains(end)
        if !atBlockEnd {
            // Whole words only: stop before a word that is not complete yet.
            let nextIsWhitespace = end < characters.count && characters[end].isWhitespace
            if !nextIsWhitespace {
                while end > 0 && !characters[end - 1].isWhitespace { end -= 1 }
            }
        }
        guard end != publishedCount else { return }
        publishedCount = end
        let text = String(characters[0..<end])
        if animated {
            withAnimation(Self.blockReveal) { displayedText = text }
        } else {
            displayedText = text
        }
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
