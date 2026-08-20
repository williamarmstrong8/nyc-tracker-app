import SwiftUI
import MapKit
import CoreLocation

/// Place a venue by hand, for the ones Apple Maps has never heard of.
///
/// Food trucks, pop-ups, a stall in a market, the bar with no sign — these do
/// not appear in `MKLocalSearch`, so every other path in the app dead-ends on
/// them. This is the escape hatch: name it, then say where it is either by
/// dragging the map under the pin or by typing an address.
///
/// ## Why the pin does not move
///
/// The marker is a fixed overlay at the centre of the map and the *map* moves
/// beneath it, rather than a draggable annotation. Dragging an annotation on a
/// touchscreen means the thing you are positioning spends the whole gesture
/// under your thumb; moving the map keeps the target visible the entire time.
/// It is also how Apple's own "adjust location" pickers behave, so it needs no
/// explaining.
///
/// The venue this produces has no `externalPOIId` — there is no MapKit record to
/// point at. Server-side dedupe falls back to name + geohash, which is the right
/// behaviour: two people pinning the same truck a few metres apart should still
/// land on one place.
struct DropPinView: View {
    /// Where to open the map. The user's current location, the photos' GPS, or
    /// whatever the caller was already looking at.
    let initialCoordinate: CLLocationCoordinate2D?
    /// Pre-fills the name field — usually whatever the user already typed before
    /// discovering that MapKit had nothing.
    let initialName: String
    /// Pop this screen once a place is produced.
    ///
    /// True for callers whose next step replaces the content underneath (the
    /// capture flow swaps its stage, and the pop does not happen on its own).
    /// False for callers that present something *over* this screen — popping and
    /// presenting in the same turn races, and the sheet loses.
    let dismissesOnDone: Bool
    let onDone: (VenueCandidate) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var camera: MapCameraPosition
    @State private var centerCoordinate: CLLocationCoordinate2D
    @State private var name: String
    @State private var addressText: String = ""
    @State private var category: PlaceCategory = .restaurant
    @State private var isLocating = false
    /// Once the user types an address themselves, panning the map stops
    /// overwriting it. Reverse geocoding a food truck's corner returns the
    /// nearest building, which is rarely what they meant to write.
    @State private var addressIsUserWritten = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case name, address }

    init(
        initialCoordinate: CLLocationCoordinate2D?,
        initialName: String = "",
        dismissesOnDone: Bool = true,
        onDone: @escaping (VenueCandidate) -> Void
    ) {
        self.initialCoordinate = initialCoordinate
        self.initialName = initialName
        self.dismissesOnDone = dismissesOnDone
        self.onDone = onDone

        let start = initialCoordinate ?? CaptureCoordinator.nycFallback
        _centerCoordinate = State(initialValue: start)
        _name = State(initialValue: initialName)
        _camera = State(initialValue: .region(
            MKCoordinateRegion(
                center: start,
                latitudinalMeters: Self.initialSpanMeters,
                longitudinalMeters: Self.initialSpanMeters
            )
        ))
    }

    /// Tight enough that a pin means a specific corner rather than a block.
    private static let initialSpanMeters: CLLocationDistance = 400

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !trimmedName.isEmpty }

    var body: some View {
        VStack(spacing: 16) {
            // Deliberately OUTSIDE the ScrollView. A Map nested in a vertical
            // scroll view competes with it for the drag gesture — and the drag
            // is the entire control here, so losing it half the time makes the
            // screen feel broken.
            mapPicker
                .padding(.horizontal, 20)
                .padding(.top, 12)

            ScrollView {
                VStack(spacing: 18) {
                    fields
                    saveButton
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Drop a pin")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                Button("Done") { focusedField = nil }
            }
        }
        .task {
            // Only fill the address in from the map when the caller did not
            // already know where we are — otherwise the first reverse geocode
            // would race the user's own typing.
            await describeCenter()
        }
    }

    // MARK: - Map

    private var mapPicker: some View {
        VStack(spacing: 10) {
            ZStack {
                Map(position: $camera) {
                    UserAnnotation()
                }
                .mapControlVisibility(.hidden)
                .onMapCameraChange(frequency: .onEnd) { context in
                    centerCoordinate = context.region.center
                    Task { await describeCenter() }
                }
                // The marker sits above the map and never moves. `allowsHitTesting`
                // off so it cannot swallow the pan gesture it is centred in.
                .overlay { centerMarker.allowsHitTesting(false) }
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                if isLocating {
                    ProgressView()
                        .padding(10)
                        .background(.regularMaterial, in: Circle())
                }
            }

            HStack(spacing: 10) {
                Text("Drag the map to position the pin")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button {
                    Haptics.tap()
                    Task { await centerOnCurrentLocation() }
                } label: {
                    Label("Use my location", systemImage: "location.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass)
                .disabled(isLocating)
            }
        }
    }

    /// A pin whose *tip* is at the centre of the map, not its middle — the
    /// offset is half the glyph's height, so what the marker points at is what
    /// gets saved.
    private var centerMarker: some View {
        Image(systemName: "mappin")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            .offset(y: -17)
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledField(
                title: "Name",
                text: $name,
                placeholder: "e.g. Birria-Landia truck"
            )
            .focused($focusedField, equals: .name)

            VStack(alignment: .leading, spacing: 6) {
                LabeledField(
                    title: "Address (optional)",
                    text: $addressText,
                    placeholder: "e.g. Roosevelt Ave & 78th St"
                )
                .focused($focusedField, equals: .address)
                .onChange(of: addressText) { _, _ in
                    if focusedField == .address { addressIsUserWritten = true }
                }

                if addressIsUserWritten {
                    Button {
                        Haptics.tap()
                        Task { await movePinToTypedAddress() }
                    } label: {
                        Label("Move the pin to this address", systemImage: "mappin.and.ellipse")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Type")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Type", selection: $category) {
                    ForEach(PlaceCategory.allCases, id: \.self) { option in
                        Text(option.rawValue.capitalized).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.primary)
            }
        }
    }

    private var saveButton: some View {
        Button {
            Haptics.tap()
            onDone(candidate())
            if dismissesOnDone { dismiss() }
        } label: {
            Text("Use this place")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.glassProminent)
        .disabled(!canSave)
    }

    // MARK: - Actions

    private func candidate() -> VenueCandidate {
        VenueCandidate(
            // A local id, because there is no MapKit record to name. Only used
            // for view identity — `externalPOIId` staying nil is what tells the
            // rest of the app this place came from a person, not from Apple.
            id: UUID().uuidString,
            name: trimmedName,
            category: category,
            coordinate: centerCoordinate,
            address: addressText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            externalPOIId: nil
        )
    }

    private func describeCenter() async {
        guard !addressIsUserWritten else { return }
        let described = await LocationResolver.describe(coordinate: centerCoordinate)
        // Re-check: the geocode is a round trip, and the user may have started
        // typing while it was in flight.
        guard !addressIsUserWritten else { return }
        addressText = described.address ?? ""
    }

    private func movePinToTypedAddress() async {
        focusedField = nil
        isLocating = true
        defer { isLocating = false }

        guard let coordinate = await LocationResolver.locate(address: addressText) else { return }
        centerCoordinate = coordinate
        withAnimation(.easeInOut(duration: 0.4)) {
            camera = .region(
                MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: Self.initialSpanMeters,
                    longitudinalMeters: Self.initialSpanMeters
                )
            )
        }
    }

    private func centerOnCurrentLocation() async {
        isLocating = true
        defer { isLocating = false }

        guard let location = await LocationProvider.shared.currentLocation() else { return }
        centerCoordinate = location.coordinate
        // Panning the map to your own position is a strong signal that whatever
        // address was in the box is stale, so let the reverse geocode win again.
        addressIsUserWritten = false
        withAnimation(.easeInOut(duration: 0.4)) {
            camera = .region(
                MKCoordinateRegion(
                    center: location.coordinate,
                    latitudinalMeters: Self.initialSpanMeters,
                    longitudinalMeters: Self.initialSpanMeters
                )
            )
        }
        await describeCenter()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
