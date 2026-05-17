import CoreLocation
import MapKit
import SwiftUI

/// Fullscreen map pin placement for pickup game address (reverse geocode via ``MapViewModel.reverseGeocodeAddressFields``).
struct PickupGameMapLocationPickerSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let onCancel: () -> Void
    let onConfirm: (CLLocationCoordinate2D, String?, String?, String?, String?) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var pinCoordinate: CLLocationCoordinate2D
    @State private var cameraPosition: MapCameraPosition
    @State private var isResolvingAddress = false
    @State private var resolvedStreet: String?
    @State private var resolvedCity: String?
    @State private var resolvedState: String?
    @State private var resolvedPostalCode: String?
    @State private var resolveHint: String?
    @State private var resolveTask: Task<Void, Never>?

    init(
        viewModel: MapViewModel,
        initialCoordinate: CLLocationCoordinate2D,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (CLLocationCoordinate2D, String?, String?, String?, String?) -> Void
    ) {
        self.viewModel = viewModel
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _pinCoordinate = State(initialValue: initialCoordinate)
        let span = MKCoordinateSpan(latitudeDelta: 0.028, longitudeDelta: 0.028)
        _cameraPosition = State(initialValue: .region(MKCoordinateRegion(center: initialCoordinate, span: span)))
    }

    private var mainInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.primary
    }

    private var subInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.72) : Color.secondary
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                mapLayer

                VStack(spacing: 0) {
                    hintGlass
                    Spacer()
                        .allowsHitTesting(false)
                    confirmFloating
                }
                .padding(.horizontal, FGSpacing.lg)
                .padding(.top, 6)
                .padding(.bottom, 32)
                .allowsHitTesting(true)
            }
            .background(Color.black.opacity(colorScheme == .dark ? 0.2 : 0.06).ignoresSafeArea())
            .navigationTitle("Pick location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        resolveTask?.cancel()
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
        .task {
            await reverseGeocodePin()
        }
    }

    private var hintGlass: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tap the map to move the pin")
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(mainInk)
            Text(resolveHint ?? " ")
                .font(FGTypography.caption)
                .foregroundStyle(subInk)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(FGSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.42 : 0.06))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.12), radius: 22, y: 10)
    }

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                Annotation("Selected", coordinate: pinCoordinate) {
                    pickupDroppedPinChrome
                }
                .annotationTitles(.hidden)
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .automatic))
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let drag = hypot(value.translation.width, value.translation.height)
                        guard drag < 14 else { return }
                        if let coordinate = proxy.convert(value.location, from: .local) {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                                pinCoordinate = coordinate
                            }
                            scheduleReverseGeocode()
                        }
                    }
            )
        }
        .ignoresSafeArea()
    }

    private var pickupDroppedPinChrome: some View {
        Image(systemName: "mappin.circle.fill")
            .font(.system(size: 44))
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color.red, Color.white)
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            .accessibilityLabel("Dropped pin")
    }

    private var confirmFloating: some View {
        Button {
            resolveTask?.cancel()
            onConfirm(pinCoordinate, resolvedStreet, resolvedCity, resolvedState, resolvedPostalCode)
            dismiss()
        } label: {
            Text("Confirm Location")
                .font(FGTypography.cardTitle.weight(.semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, FGSpacing.md)
                .background {
                    Capsule(style: .continuous)
                        .fill(FGColor.brandGradient)
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
                        }
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.55 : 0.22), radius: 18, y: 10)
        }
        .buttonStyle(.plain)
    }

    private func scheduleReverseGeocode() {
        resolveTask?.cancel()
        resolveTask = Task {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            await reverseGeocodePin()
        }
    }

    private func reverseGeocodePin() async {
        await MainActor.run {
            isResolvingAddress = true
            resolveHint = "Resolving address…"
        }
        let fields = await viewModel.reverseGeocodeAddressFields(for: pinCoordinate)
        await MainActor.run {
            isResolvingAddress = false
            resolvedStreet = fields.street
            resolvedCity = fields.city
            resolvedState = fields.state
            resolvedPostalCode = fields.postalCode
            let stateLine = [fields.state, fields.postalCode]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let parts = [fields.street, fields.city, stateLine].compactMap { $0 }.filter { !$0.isEmpty }
            if parts.isEmpty {
                resolveHint = "Could not resolve address — you can still confirm and edit fields manually."
            } else {
                resolveHint = parts.joined(separator: ", ")
            }
        }
    }
}

