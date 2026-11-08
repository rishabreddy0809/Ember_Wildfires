//  RateLimiter.swift
//  Keeps the app well below the FIRMS transaction limit.
//
//  FIRMS allows 5,000 transactions per MAP_KEY in each 10-minute window, and longer
//  date ranges can count as more than one transaction. This app sets a much stricter
//  limit for itself and also adds a short cooldown between refreshes, so pressing
//  ⌘R many times can never use up your key's limit.

import Foundation

nonisolated struct RateLimiter: Sendable {
    /// FIRMS documented window.
    static let window: TimeInterval = 10 * 60
    /// Self-imposed cap. It is far below FIRMS's 5,000 limit, to leave room for anything else using the same key.
    static let budgetPerWindow = 250
    /// Minimum time between refreshes.
    static let cooldown: TimeInterval = 15

    private var log: [(date: Date, cost: Int)] = []

    /// Transactions this app has used in the current 10-minute window.
    func used(at now: Date = .now) -> Int {
        log.filter { now.timeIntervalSince($0.date) < Self.window }.reduce(0) { $0 + $1.cost }
    }

    /// nil if a request costing `cost` may go ahead, otherwise how many seconds to wait.
    func waitTime(forCost cost: Int, at now: Date = .now) -> TimeInterval? {
        if let last = log.last?.date {
            let since = now.timeIntervalSince(last)
            if since < Self.cooldown { return Self.cooldown - since }
        }
        let recent = log.filter { now.timeIntervalSince($0.date) < Self.window }
        if recent.reduce(0, { $0 + $1.cost }) + cost > Self.budgetPerWindow,
           let oldest = recent.first?.date {
            return Self.window - now.timeIntervalSince(oldest)
        }
        return nil
    }

    mutating func record(cost: Int, at now: Date = .now) {
        log.removeAll { now.timeIntervalSince($0.date) >= Self.window }
        log.append((now, cost))
    }
}
