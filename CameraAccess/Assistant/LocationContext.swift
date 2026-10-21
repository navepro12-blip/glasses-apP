//
// LocationContext.swift
// Coarse "where am I" for Claude (weather, what's nearby, where did I park),
// battery-friendly: hundred-metre accuracy, 50 m distance filter, paused
// automatically when still. Reverse geocoding is throttled.
//

import CoreLocation
import Foundation

@MainActor
final class LocationContext: NSObject {
  static let shared = LocationContext()

  struct Fix: Sendable {
    let latitude: Double
    let longitude: Double
    let date: Date
  }

  private(set) var fix: Fix?
  private(set) var placeName: String = ""
  private(set) var authorized = false
  private var manager: CLLocationManager?
  private var lastGeocode: (Date, Double, Double)?
  private var running = false

  func start() {
    guard AssistantSettings.shared.locationEnabled else { return }
    if manager == nil {
      let m = CLLocationManager()
      m.delegate = self
      m.desiredAccuracy = kCLLocationAccuracyHundredMeters
      m.distanceFilter = 50
      m.pausesLocationUpdatesAutomatically = true
      m.activityType = .other
      manager = m
    }
    guard let manager else { return }
    switch manager.authorizationStatus {
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
    case .authorizedWhenInUse, .authorizedAlways:
      authorized = true
      if !running {
        running = true
        manager.startUpdatingLocation()
      }
    default:
      authorized = false
    }
  }

  func stop() {
    running = false
    manager?.stopUpdatingLocation()
  }

  /// A fresh single fix (waits up to ~4 s) — for "remember where I parked".
  func currentFix(maxWait: Double = 4) async -> Fix? {
    start()
    manager?.requestLocation()
    let deadline = Date().addingTimeInterval(maxWait)
    while Date() < deadline {
      if let fix, Date().timeIntervalSince(fix.date) < 120 { return fix }
      try? await Task.sleep(for: .milliseconds(250))
    }
    return fix
  }

  /// One line for the system prompt, or nil when unknown.
  var contextLine: String? {
    guard let fix else { return nil }
    let age = Int(Date().timeIntervalSince(fix.date) / 60)
    let coords = String(format: "%.4f, %.4f", fix.latitude, fix.longitude)
    let place = placeName.isEmpty ? "" : "\(placeName) "
    return "Nave's current location: \(place)(\(coords)), \(age) min ago."
  }

  private func apply(latitude: Double, longitude: Double) {
    fix = Fix(latitude: latitude, longitude: longitude, date: Date())
    // Reverse-geocode at most every 5 minutes or when moved > 300 m.
    if let last = lastGeocode {
      let moved = CLLocation(latitude: last.1, longitude: last.2)
        .distance(from: CLLocation(latitude: latitude, longitude: longitude))
      if Date().timeIntervalSince(last.0) < 300, moved < 300 { return }
    }
    lastGeocode = (Date(), latitude, longitude)
    Task { [weak self] in
      let name = await Self.geocode(latitude: latitude, longitude: longitude)
      if !name.isEmpty { self?.placeName = name }
    }
  }

  nonisolated private static func geocode(latitude: Double, longitude: Double) async -> String {
    let location = CLLocation(latitude: latitude, longitude: longitude)
    guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return "" }
    let parts = [placemark.thoroughfare, placemark.locality].compactMap { $0 }.filter { !$0.isEmpty }
    return parts.joined(separator: ", ")
  }
}

extension LocationContext: CLLocationManagerDelegate {
  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let last = locations.last else { return }
    let lat = last.coordinate.latitude
    let lon = last.coordinate.longitude
    Task { @MainActor in self.apply(latitude: lat, longitude: lon) }
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    Task { @MainActor in
      switch status {
      case .authorizedWhenInUse, .authorizedAlways:
        self.authorized = true
        self.start()
      default:
        self.authorized = false
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
