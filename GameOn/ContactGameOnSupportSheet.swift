import SwiftUI

/// Settings → Help & Support: contact form for App Store compliance and user support.
struct ContactGameOnSupportSheet: View {
    @ObservedObject var viewModel: MapViewModel
    var onRequestSignIn: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var category: SupportRequestCategory = .technicalIssue
    @State private var subject: String = ""
    @State private var message: String = ""
    @State private var isSending = false
    @State private var showSuccessAlert = false
    @State private var showFailureAlert = false
    @State private var validationMessage: String?

    private var trimmedSubject: String {
        subject.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmedSubject.isEmpty
            && !trimmedMessage.isEmpty
            && trimmedSubject.count <= SupportRequestService.subjectMaxCharacters
            && trimmedMessage.count <= SupportRequestService.messageMaxCharacters
            && !isSending
    }

    private var hasAuthSession: Bool {
        viewModel.isLoggedIn || viewModel.isVenueOwnerLoggedIn
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        FanGeoInlineLogoView(variant: .white, width: 104, innerPadding: 6)
                        Spacer()
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                if !hasAuthSession {
                    Section {
                        Text("Please sign in with your FanGeo or venue account to send a support message.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Sign in or create account") {
                            dismiss()
                            onRequestSignIn()
                        }
                    }
                } else {
                    Section {
                        TextField("Subject", text: $subject)
                            .textInputAutocapitalization(.sentences)

                        Picker("Category", selection: $category) {
                            ForEach(SupportRequestCategory.allCases) { cat in
                                Text(cat.displayTitle).tag(cat)
                            }
                        }

                        if let line = category.exampleHelperLine, !line.isEmpty {
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Message")
                                .font(.subheadline.weight(.semibold))
                            TextEditor(text: $message)
                                .frame(minHeight: 140)
                                .overlay(alignment: .topLeading) {
                                    if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text("Describe your question or issue…")
                                            .foregroundStyle(.tertiary)
                                            .padding(.top, 8)
                                            .padding(.leading, 4)
                                            .allowsHitTesting(false)
                                    }
                                }
                            Text("\(message.count) / \(SupportRequestService.messageMaxCharacters)")
                                .font(.caption)
                                .foregroundStyle(
                                    message.count > SupportRequestService.messageMaxCharacters ? Color.red : .secondary
                                )
                        }
                    } footer: {
                        Text("Screenshots are not yet supported. Please describe the issue in your message.")
                            .font(.caption)
                    }

                    Section {
                        Text("For emergencies or immediate danger, contact local emergency services.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
            }
            .navigationTitle("Contact Support")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if hasAuthSession {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") { Task { await send() } }
                            .disabled(!canSend)
                    }
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
            .alert("Sent", isPresented: $showSuccessAlert) {
                Button("OK") { dismiss() }
            } message: {
                Text("Your support request has been sent to FanGeo.")
            }
            .alert("Couldn’t send", isPresented: $showFailureAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Unable to send support request right now. Please try again later.")
            }
            .alert(
                "Check your message",
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

    @MainActor
    private func send() async {
        guard trimmedSubject.count <= SupportRequestService.subjectMaxCharacters else {
            validationMessage = "Subject may be at most \(SupportRequestService.subjectMaxCharacters) characters."
            return
        }
        guard trimmedMessage.count <= SupportRequestService.messageMaxCharacters else {
            validationMessage = "Message may be at most \(SupportRequestService.messageMaxCharacters) characters."
            return
        }

        isSending = true
        defer { isSending = false }

        do {
            try await SupportRequestService().submitSupportRequest(
                category: category,
                subject: subject,
                message: message,
                client: supabase
            )
            showSuccessAlert = true
        } catch let err as SupportRequestSubmitError {
            switch err {
            case .prohibitedContent, .rateLimited, .notSignedIn:
                validationMessage = err.localizedDescription
            case .emailSendFailed:
                showFailureAlert = true
            }
        } catch {
            showFailureAlert = true
        }
    }
}
