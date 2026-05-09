import SwiftUI

// MARK: - Legal & Safety (draft in-app policies; not legal advice)

enum SettingsLegalDocumentKind: String, Identifiable {
    case privacyPolicy
    case termsOfService
    case communityGuidelines
    case safetyReporting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacyPolicy: return "Privacy Policy"
        case .termsOfService: return "Terms of Service"
        case .communityGuidelines: return "Community Guidelines"
        case .safetyReporting: return "Safety & Reporting"
        }
    }

    var rowSubtitle: String {
        switch self {
        case .privacyPolicy: return "How we use and protect your information."
        case .termsOfService: return "Rules for using GameOn."
        case .communityGuidelines: return "Be respectful and play fair."
        case .safetyReporting: return "Get help and report concerns."
        }
    }

    var systemImage: String {
        switch self {
        case .privacyPolicy: return "hand.raised.fill"
        case .termsOfService: return "doc.text.fill"
        case .communityGuidelines: return "person.3.fill"
        case .safetyReporting: return "shield.lefthalf.filled"
        }
    }

    /// Placeholder date shown on every sheet (update when policies are revised).
    static let lastUpdatedDisplay = "May 9, 2026"

    var draftSections: [SettingsLegalContentSection] {
        switch self {
        case .privacyPolicy:
            return [
                .init(heading: "Overview", body: """
                This Privacy Policy describes how GameOn (the app) handles information in plain language. It is a draft for in-app display until final policies are published. It is not legal advice.
                """),
                .init(heading: "Account data", body: """
                When you create an account, we may collect information you provide such as email, display name, and authentication identifiers needed to sign you in and secure your account.
                """),
                .init(heading: "Location & map", body: """
                Map and discovery features may use your device location or region you choose to show nearby venues and events. You can control location access in iOS Settings for GameOn. We use this to improve relevance, not to sell your precise movements.
                """),
                .init(heading: "Uploaded photos", body: """
                Profile photos, venue photos, and similar uploads are stored so you and others can see them as intended in the app (for example venue listings or your avatar). Do not upload images you do not have rights to share.
                """),
                .init(heading: "Chats & messages", body: """
                Direct messages and similar communications are processed to deliver them between users and to enforce safety (for example moderation, abuse prevention, and legal requirements where applicable).
                """),
                .init(heading: "Reports & moderation", body: """
                When you report content or users, we process the information you submit and related context so our team can review. We may retain reports as needed to operate the service and protect the community.
                """),
                .init(heading: "Venue owner data", body: """
                Venue owners may provide business details, photos, schedules, and contact information shown in the app. This information is used to operate venue features and communicate about your listing.
                """),
                .init(heading: "Account deletion", body: """
                You may delete your account from Settings where available. Deletion removes or anonymizes your personal data as described in the deletion flow, subject to legal or legitimate retention needs (for example fraud prevention or unresolved disputes).
                """),
                .init(heading: "Contact", body: """
                For privacy questions, use the support or contact channel listed when available. This draft will be replaced or supplemented by a hosted policy when GameOn goes to production.
                """)
            ]
        case .termsOfService:
            return [
                .init(heading: "Overview", body: """
                These Terms of Service are a draft summary of rules for using GameOn. A final agreement may add detail about liability, disputes, and updates. Using the app means you agree to follow these rules and any future version we post in-app.
                """),
                .init(heading: "Acceptable use", body: """
                Use GameOn only for lawful purposes. Do not interfere with the app, other users, or our systems. Do not attempt to access data you are not allowed to see or to reverse engineer the service in ways that violate law or our policies.
                """),
                .init(heading: "Venue owner responsibilities", body: """
                If you manage a venue listing, you are responsible for accurate information (hours, location, games, photos) and for complying with laws that apply to your business and advertising. Misleading or fraudulent listings are not allowed.
                """),
                .init(heading: "User-generated content", body: """
                You keep rights to content you create, but you give GameOn permission to host, display, and distribute it as needed to run the service. You confirm you have the right to post what you upload.
                """),
                .init(heading: "No harassment, spam, or abuse", body: """
                Do not harass, threaten, impersonate, or abuse others. Do not spam, manipulate ratings or attendance, or use the app to promote scams. We may suspend or remove accounts that break these rules.
                """),
                .init(heading: "App limitations", body: """
                GameOn is provided as-is to the extent allowed by law. We do not guarantee uninterrupted service, accuracy of every listing, or outcomes of reports. Features may change or be discontinued with reasonable notice where practical.
                """)
            ]
        case .communityGuidelines:
            return [
                .init(heading: "Overview", body: """
                GameOn is a sports and venue community. These guidelines set expectations for everyone. They work alongside our Terms and Safety materials.
                """),
                .init(heading: "Photos & media", body: """
                Do not post nudity, sexually explicit imagery, or otherwise inappropriate photos in profiles, venues, or social features. Keep content suitable for a general audience in public areas of the app.
                """),
                .init(heading: "Respect & harassment", body: """
                Treat fans, venue staff, and other users with respect. No bullying, hate, threats, or targeted harassment. Disagree without attacking people.
                """),
                .init(heading: "Spam & manipulation", body: """
                Do not flood comments or messages, create fake engagement, or misrepresent who you are to gain an unfair advantage. One account per person where required.
                """),
                .init(heading: "Venues & listings", body: """
                Do not create fake venues or impersonate a business you do not represent. Venue information should be honest so fans can trust what they see on the map and in event listings.
                """),
                .init(heading: "Sports & community behavior", body: """
                Keep rivalries friendly. No incitement to violence, dangerous meetups, or illegal activity. Follow venue rules when you attend events in real life.
                """),
                .init(heading: "Enforcement", body: """
                We may warn, remove content, or restrict accounts that violate these guidelines. Serious or repeated violations may lead to permanent suspension.
                """)
            ]
        case .safetyReporting:
            return [
                .init(heading: "Overview", body: """
                Your safety matters. This page explains how reporting and blocking work inside GameOn. It is a draft; detailed help links may be added later.
                """),
                .init(heading: "How to report", body: """
                • Users: Use report options where available in profiles, chat, or related screens.\n\
                • Messages & conversations: Report from the message or conversation context where the app provides a report action.\n\
                • Venues & activity: Use reporting or flag flows on venue-related content (such as comments) when offered.\n\
                Provide accurate information so reviewers can understand what happened.
                """),
                .init(heading: "Blocking", body: """
                Blocking helps limit unwanted contact from another user in supported areas of the app (for example direct chat). Blocked users may not see all of the same features toward you. Blocking does not guarantee someone cannot encounter you outside the app.
                """),
                .init(heading: "Admin review", body: """
                Reports are reviewed by the GameOn team. We may take actions such as warnings, content removal, or account suspension depending on severity and repeat behavior. Not every report will result in the outcome you expect, but we take credible reports seriously.
                """),
                .init(heading: "Misuse of reporting", body: """
                Do not file false or malicious reports. Abuse of reporting tools may lead to restrictions on your account.
                """),
                .init(heading: "Emergencies", body: """
                If you or someone else is in immediate danger, contact local emergency services right away. GameOn cannot replace police, medical, or crisis responders. The app is not monitored in real time for every emergency.
                """)
            ]
        }
    }
}

struct SettingsLegalContentSection: Hashable {
    let heading: String
    let body: String
}

struct SettingsLegalDocumentSheet: View {
    let document: SettingsLegalDocumentKind
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Last updated: \(SettingsLegalDocumentKind.lastUpdatedDisplay)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Draft — for in-app reference only; not legal advice.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(document.draftSections, id: \.self) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.heading)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(section.body)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(.ultraThinMaterial)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.visible)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
            }
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
