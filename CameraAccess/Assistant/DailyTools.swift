//
// DailyTools.swift
// Everyday helpers for an all-day wearer: Apple Reminders and Calendar
// (EventKit), spoken timers (local notification + chime in the ear), and
// hands-off navigation (Waze / Apple Maps).
//

import EventKit
import Foundation
import UIKit
import UserNotifications

// MARK: - Dates

enum IsraelClock {
  static let zone = TimeZone(identifier: "Asia/Jerusalem") ?? .current

  /// "Wednesday 21.10.2026 14:05 (Asia/Jerusalem)" — for the system prompt.
  static var nowLine: String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = zone
    f.dateFormat = "EEEE yyyy-MM-dd HH:mm"
    return "\(f.string(from: Date())) (\(zone.identifier))"
  }

  /// Parses "2026-10-21T17:00" / "2026-10-21 17:00" / "2026-10-21T17:00:00+03:00" (local zone when none).
  static func parse(_ s: String) -> Date? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: t) { return d }
    for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = zone
      f.dateFormat = fmt
      if let d = f.date(from: t) { return d }
    }
    return nil
  }

  static func speakable(_ d: Date, withDate: Bool = true) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "he_IL")
    f.timeZone = zone
    f.dateFormat = withDate ? "EEEE d.M HH:mm" : "HH:mm"
    return f.string(from: d)
  }
}

// MARK: - Reminders & Calendar

/// EKEventStore is documented thread-safe; the box lets a nonisolated helper
/// use it for the callback-style reminder fetch.
final class EventStoreBox: @unchecked Sendable {
  let store = EKEventStore()
}

@MainActor
final class CalendarAgent {
  static let shared = CalendarAgent()
  private let box = EventStoreBox()
  private var store: EKEventStore { box.store }

  func addReminder(title: String, dueAt: String?, inMinutes: Int?, notes: String?) async -> String {
    let granted = (try? await store.requestFullAccessToReminders()) ?? false
    guard granted else { return "No access to Reminders — allow it in iPhone Settings → Privacy → Reminders." }
    let reminder = EKReminder(eventStore: store)
    reminder.title = title
    reminder.notes = notes
    reminder.calendar = store.defaultCalendarForNewReminders()
    var due: Date?
    if let inMinutes, inMinutes > 0 { due = Date().addingTimeInterval(Double(inMinutes) * 60) }
    else if let dueAt { due = IsraelClock.parse(dueAt) }
    if let due {
      var cal = Calendar.current
      cal.timeZone = IsraelClock.zone
      reminder.dueDateComponents = cal.dateComponents([.year, .month, .day, .hour, .minute], from: due)
      reminder.addAlarm(EKAlarm(absoluteDate: due))
    }
    do {
      try store.save(reminder, commit: true)
      if let due { return "Reminder saved: '\(title)' at \(IsraelClock.speakable(due))." }
      return "Reminder saved: '\(title)' (no time)."
    } catch {
      return "Couldn't save the reminder: \(error.localizedDescription)"
    }
  }

  func openReminders(limit: Int = 12) async -> String {
    let granted = (try? await store.requestFullAccessToReminders()) ?? false
    guard granted else { return "No access to Reminders — allow it in iPhone Settings." }
    let lines = await Self.fetchIncomplete(box: box)
    guard !lines.isEmpty else { return "No open reminders." }
    return "Open reminders:\n" + lines.prefix(limit).joined(separator: "\n")
  }

  nonisolated private static func fetchIncomplete(box: EventStoreBox) async -> [String] {
    let predicate = box.store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
    return await withCheckedContinuation { (c: CheckedContinuation<[String], Never>) in
      box.store.fetchReminders(matching: predicate) { reminders in
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "EEEE d.M HH:mm"
        let lines = (reminders ?? []).map { r -> String in
          var line = "- \(r.title ?? "")"
          if let comps = r.dueDateComponents, let d = Calendar.current.date(from: comps) { line += " (\(f.string(from: d)))" }
          return line
        }
        c.resume(returning: lines)
      }
    }
  }

  /// Events for a day: 0 = today, 1 = tomorrow…
  func agenda(dayOffset: Int) async -> String {
    let granted = (try? await store.requestFullAccessToEvents()) ?? false
    guard granted else { return "No access to the Calendar — allow it in iPhone Settings → Privacy → Calendars." }
    var cal = Calendar.current
    cal.timeZone = IsraelClock.zone
    let start = cal.startOfDay(for: cal.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date())
    let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    let events = store.events(matching: predicate).sorted {
      ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast)
    }
    let label = dayOffset == 0 ? "today" : dayOffset == 1 ? "tomorrow" : "in \(dayOffset) days"
    guard !events.isEmpty else { return "Nothing in the calendar \(label)." }
    let lines = events.prefix(15).map { e -> String in
      let from = IsraelClock.speakable(e.startDate ?? start, withDate: false)
      let to = IsraelClock.speakable(e.endDate ?? start, withDate: false)
      let when = e.isAllDay ? "all day" : "\(from)–\(to)"
      var line = "- \(when): \(e.title ?? "")"
      if let loc = e.location, !loc.isEmpty { line += " @ \(loc)" }
      return line
    }
    return "Calendar \(label) (\(IsraelClock.speakable(start))):\n" + lines.joined(separator: "\n")
  }

  func addEvent(title: String, startAt: String, minutes: Int, location: String?) async -> String {
    let granted = (try? await store.requestFullAccessToEvents()) ?? false
    guard granted else { return "No access to the Calendar — allow it in iPhone Settings." }
    guard let start = IsraelClock.parse(startAt) else { return "Couldn't understand the start time '\(startAt)'. Use YYYY-MM-DDTHH:MM." }
    let event = EKEvent(eventStore: store)
    event.title = title
    event.startDate = start
    event.endDate = start.addingTimeInterval(Double(max(15, minutes)) * 60)
    event.location = location
    event.calendar = store.defaultCalendarForNewEvents
    event.addAlarm(EKAlarm(relativeOffset: -15 * 60))
    do {
      try store.save(event, span: .thisEvent, commit: true)
      return "Event saved: '\(title)' on \(IsraelClock.speakable(start))."
    } catch {
      return "Couldn't save the event: \(error.localizedDescription)"
    }
  }
}

// MARK: - Timers

@MainActor
final class TimerAgent {
  static let shared = TimerAgent()

  struct Running: Identifiable {
    let id: String
    let label: String
    let ends: Date
    let task: Task<Void, Never>
  }

  private(set) var timers: [Running] = []

  func set(seconds: Int, label: String) async -> String {
    guard seconds > 0 else { return "The duration must be positive." }
    let id = UUID().uuidString
    let ends = Date().addingTimeInterval(Double(seconds))
    let name = label.isEmpty ? "טיימר" : label

    // Local notification so it also fires when the app is in the background.
    let center = UNUserNotificationCenter.current()
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
    let content = UNMutableNotificationContent()
    content.title = "⏱ \(name)"
    content.body = "הזמן נגמר"
    content.sound = .default
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Double(seconds), repeats: false)
    try? await center.add(UNNotificationRequest(identifier: "timer-" + id, content: content, trigger: trigger))

    let task = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      self?.timers.removeAll { $0.id == id }
      Chime.playTimer()
      SpeechOutput.shared.enqueue("\(name) — הזמן נגמר")
    }
    timers.append(Running(id: id, label: name, ends: ends, task: task))
    return "Timer '\(name)' set for \(Self.describe(seconds)) (ends \(IsraelClock.speakable(ends, withDate: false)))."
  }

  func cancelAll() -> String {
    guard !timers.isEmpty else { return "No timers running." }
    let ids = timers.map { "timer-" + $0.id }
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    timers.forEach { $0.task.cancel() }
    let n = timers.count
    timers.removeAll()
    return "Cancelled \(n) timer(s)."
  }

  func status() -> String {
    guard !timers.isEmpty else { return "No timers running." }
    return timers.map { t in
      let left = max(0, Int(t.ends.timeIntervalSinceNow))
      return "- \(t.label): \(Self.describe(left)) left"
    }.joined(separator: "\n")
  }

  static func describe(_ seconds: Int) -> String {
    if seconds >= 3600 { return "\(seconds / 3600) h \((seconds % 3600) / 60) min" }
    if seconds >= 60 { return "\(seconds / 60) min \(seconds % 60) s" }
    return "\(seconds) s"
  }
}

// MARK: - Navigation

enum Navigator {
  @MainActor static func navigate(to destination: String) async -> String {
    let q = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return "No destination given." }
    let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
    if let waze = URL(string: "waze://?q=\(encoded)&navigate=yes"), UIApplication.shared.canOpenURL(waze) {
      await UIApplication.shared.open(waze)
      return "Opened Waze navigating to \(q)."
    }
    if let maps = URL(string: "http://maps.apple.com/?daddr=\(encoded)&dirflg=d") {
      await UIApplication.shared.open(maps)
      return "Opened Apple Maps with directions to \(q)."
    }
    return "Couldn't open navigation."
  }

  @MainActor static func navigate(latitude: Double, longitude: Double, label: String) async -> String {
    if let waze = URL(string: "waze://?ll=\(latitude),\(longitude)&navigate=yes"), UIApplication.shared.canOpenURL(waze) {
      await UIApplication.shared.open(waze)
      return "Opened Waze to \(label)."
    }
    if let maps = URL(string: "http://maps.apple.com/?daddr=\(latitude),\(longitude)&dirflg=w") {
      await UIApplication.shared.open(maps)
      return "Opened Apple Maps to \(label)."
    }
    return "Couldn't open navigation."
  }
}
