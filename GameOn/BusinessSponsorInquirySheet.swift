import SwiftUI

struct BusinessSponsorInquirySheet: View {
    @ObservedObject var viewModel: MapViewModel
    let businessId: UUID?
    let ownerEmail: String
    let selectedVenue: String

    @Environment(\.dismiss) private var dismiss

    @State private var businessName: String
    @State private var contactEmail: String
    @State private var venueLocation: String
    @State private var message: String
    @State private var budgetTimeframe: String
    @State private var isSending = false
    @State private var showSuccessAlert = false
    @State private var showFailureAlert = false
    @State private var validationMessage: String?

    init(
        viewModel: MapViewModel,
        businessId: UUID?,
        businessName: String,
        ownerEmail: String,
        selectedVenue: String
    ) {
        self.viewModel = viewModel
        self.businessId = businessId
        self.ownerEmail = ownerEmail
        self.selectedVenue = selectedVenue
        _businessName = State(initialValue: businessName)
        _contactEmail = State(initialValue: ownerEmail)
        _venueLocation = State(initialValue: selectedVenue)
        _message = State(initialValue: Self.defaultMessage)
        _budgetTimeframe = State(initialValue: "")
    }

    private static let defaultMessage =
        "I’m interested in paid advertising or sponsored placement for my venue on FanGeo. Please contact me with sponsorship options."

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private var trimmedBusinessName: String {
        businessName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedContactEmail: String {
        contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedVenueLocation: String {
        venueLocation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBudgetTimeframe: String {
        budgetTimeframe.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var subject: String {
        let name = trimmedBusinessName.isEmpty ? "Business" : trimmedBusinessName
        return "FanGeo Sponsor Inquiry - \(String(name.prefix(120)))"
    }

    private var canSubmit: Bool {
        !trimmedBusinessName.isEmpty
            && !trimmedContactEmail.isEmpty
            && !trimmedVenueLocation.isEmpty
            && !trimmedMessage.isEmpty
            && !isSending
    }

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                businessDetailsSection
                sponsorshipInterestSection
            }
            .navigationTitle("Sponsor Inquiry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await submit() } }
                        .disabled(!canSubmit)
                }
            }
            .overlay {
                if isSending {
                    ZStack {
                        Color.black.opacity(0.12).ignoresSafeArea()
                        ProgressView()
                            .padding(20)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .alert("Inquiry sent", isPresented: $showSuccessAlert) {
                Button("OK") { dismiss() }
            } message: {
                Text("FanGeo received your sponsorship inquiry.")
            }
            .alert("Couldn’t send", isPresented: $showFailureAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Unable to send the sponsor inquiry right now. Please try again later.")
            }
            .alert(
                "Check your inquiry",
                isPresented: Binding(
                    get: { validationMessage != nil },
                    set: { if !$0 { validationMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { validationMessage = nil }
            } message: {
                Text(validationMessage ?? "")
            }
        }
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Advertise with FanGeo", systemImage: "megaphone.fill")
                    .font(.headline.weight(.bold))
                Text("Tell the FanGeo team how you’d like to promote your bar, venue, or watch party to local fans.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var businessDetailsSection: some View {
        Section("Business details") {
            TextField("Business name", text: $businessName)
                .textInputAutocapitalization(.words)
            TextField("Contact email", text: $contactEmail)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Venue/location", text: $venueLocation)
                .textInputAutocapitalization(.words)
        }
    }

    private var sponsorshipInterestSection: some View {
        Section {
            messageEditor
            TextField("Optional budget/timeframe", text: $budgetTimeframe)
                .textInputAutocapitalization(.sentences)
        } header: {
            Text("Sponsorship interest")
        } footer: {
            Text("Sponsored placement is available to Business Regular and Business Pro accounts.")
        }
    }

    private var messageEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Message")
                .font(.subheadline.weight(.semibold))
            TextEditor(text: $message)
                .frame(minHeight: 140)
                .overlay(alignment: .topLeading) {
                    if trimmedMessage.isEmpty {
                        Text(Self.defaultMessage)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    @MainActor
    private func submit() async {
        guard canSubmit else { return }
        let body = emailBody()
        guard subject.count <= SupportRequestService.subjectMaxCharacters,
              body.count <= SupportRequestService.messageMaxCharacters else {
            validationMessage = "Please shorten your inquiry so FanGeo can receive it in one message."
            return
        }

        isSending = true
        defer { isSending = false }

        do {
            try await SupportRequestService().submitSupportRequest(
                category: .businessSupport,
                subject: subject,
                message: body,
                client: supabase
            )
#if DEBUG
            print("[SponsorInquiryDebug] submitted=true businessId=\(businessId?.uuidString.lowercased() ?? "nil") emailSent=true")
#endif
            showSuccessAlert = true
        } catch {
#if DEBUG
            print("[SponsorInquiryDebug] submitted=true businessId=\(businessId?.uuidString.lowercased() ?? "nil") emailSent=false")
            print("[SponsorInquiryDebug] failed error=\(error.localizedDescription)")
#endif
            if let supportError = error as? SupportRequestSubmitError,
               supportError == .prohibitedContent || supportError == .notSignedIn {
                validationMessage = supportError.localizedDescription
            } else {
                showFailureAlert = true
            }
        }
    }

    private func emailBody() -> String {
        let timestamp = Self.isoFormatter.string(from: Date())
        let budgetLine = trimmedBudgetTimeframe.isEmpty ? "Not provided" : trimmedBudgetTimeframe
        return """
        Sponsor inquiry

        Business ID: \(businessId?.uuidString.lowercased() ?? "nil")
        Business name: \(trimmedBusinessName)
        Owner email: \(ownerEmail.isEmpty ? "nil" : ownerEmail)
        Selected venue: \(trimmedVenueLocation)
        Contact email: \(trimmedContactEmail)
        Budget/timeframe: \(budgetLine)
        Timestamp: \(timestamp)

        Message:
        \(trimmedMessage)
        """
    }
}
