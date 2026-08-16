import Foundation
import CoreLocation

/// One-shot device location fetcher used when no photo has GPS and no address is given.
/// Requests When-In-Use permission if needed; returns nil gracefully on denial or timeout.
///
/// Also exposes an `authorizationStatus` you can await, which is what the map view uses to make
/// sure permission is granted *before* asking for the blue-dot location.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    private var authContinuations: [CheckedContinuation<CLAuthorizationStatus, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Force the When-In-Use prompt now (returns the resolved status). Safe to call repeatedly —
    /// re-prompts only when the status is `.notDetermined`.
    @discardableResult
    func requestAuthorization() async -> CLAuthorizationStatus {
        let current = manager.authorizationStatus
        if current != .notDetermined { return current }

        manager.requestWhenInUseAuthorization()
        return await withCheckedContinuation { (cont: CheckedContinuation<CLAuthorizationStatus, Never>) in
            authContinuations.append(cont)
        }
    }

    /// Ask for the current device location, or nil if unavailable/denied. Times out after ~4s.
    func currentLocation() async -> CLLocation? {
        let status = await requestAuthorization()
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            return await requestLocationWithTimeout()
        default:
            return nil
        }
    }

    private func requestLocationWithTimeout() async -> CLLocation? {
        return await withCheckedContinuation { [weak self] (continuation: CheckedContinuation<CLLocation?, Never>) in
            guard let self else {
                continuation.resume(returning: nil)
                return
            }
            self.locationContinuation = continuation
            self.manager.requestLocation()

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                await MainActor.run {
                    self?.resume(with: nil)
                }
            }
        }
    }

    private func resume(with location: CLLocation?) {
        guard let continuation = locationContinuation else { return }
        self.locationContinuation = nil
        continuation.resume(returning: location)
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let best = locations.last
        Task { @MainActor in
            self.resume(with: best)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.resume(with: nil)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            let waiting = self.authContinuations
            self.authContinuations = []
            for cont in waiting { cont.resume(returning: status) }
        }
    }
}
