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
        case .termsOfService: return "Rules for using FanGeo."
        case .communityGuidelines: return "Rules, reporting, and moderation in FanGeo."
        case .safetyReporting: return "How reports are reviewed and when content may hide."
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
                This Privacy Policy describes how FanGeo (the app) handles information in plain language. It is a draft for in-app display until final policies are published. It is not legal advice.
                """),
                .init(heading: "Account data", body: """
                When you create an account, we may collect information you provide such as email, display name, and authentication identifiers needed to sign you in and secure your account.
                """),
                .init(heading: "Location & map", body: """
                Map and discovery features may use your device location or region you choose to show nearby venues and events. You can control location access in iOS Settings for FanGeo. We use this to improve relevance, not to sell your precise movements.
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
                For privacy questions, use the support or contact channel listed when available. This draft will be replaced or supplemented by a hosted policy when FanGeo goes to production.
                """)
            ]
        case .termsOfService:
            return [
                .init(heading: "Overview", body: """
                These Terms of Service are a draft summary of rules for using FanGeo. A final agreement may add detail about liability, disputes, and updates. Using the app means you agree to follow these rules and any future version we post in-app.
                """),
                .init(heading: "Acceptable use", body: """
                Use FanGeo only for lawful purposes. Do not interfere with the app, other users, or our systems. Do not attempt to access data you are not allowed to see or to reverse engineer the service in ways that violate law or our policies.
                """),
                .init(heading: "Venue owner responsibilities", body: """
                If you manage a venue listing, you are responsible for accurate information (hours, location, games, photos) and for complying with laws that apply to your business and advertising. Misleading or fraudulent listings are not allowed.
                """),
                .init(heading: "User-generated content", body: """
                You keep rights to content you create, but you give FanGeo permission to host, display, and distribute it as needed to run the service. You confirm you have the right to post what you upload.
                """),
                .init(heading: "No harassment, spam, or abuse", body: """
                Do not harass, threaten, impersonate, or abuse others. Do not spam, manipulate ratings or attendance, or use the app to promote scams. We may suspend or remove accounts that break these rules.
                """),
                .init(heading: "App limitations", body: """
                FanGeo is provided as-is to the extent allowed by law. We do not guarantee uninterrupted service, accuracy of every listing, or outcomes of reports. Features may change or be discontinued with reasonable notice where practical.
                """)
            ]
        case .communityGuidelines:
            return [
                .init(heading: "Community rules", body: """
                • No hate speech, racism, slurs, or discrimination.\n\
                • No harassment, bullying, threats, or targeted abuse.\n\
                • No nudity, sexually explicit content, or inappropriate images.\n\
                • No illegal activity or promotion of illegal behavior.\n\
                • No impersonation of another user, venue, team, or organization.\n\
                • No spam, scams, phishing, fake promotions, or repeated disruptive posts.\n\
                • Keep comments, fan updates, and private messages respectful.
                """),
                .init(heading: "Reporting comments", body: """
                You can report venue/event comments or fan updates that break these rules. Each account may have only one active report per comment. If you reported something by mistake, tap the red flag again to remove your own report. Only active reports count toward moderation thresholds.
                """),
                .init(heading: "Auto-hide threshold", body: """
                When a comment has three active reports from different users, FanGeo may automatically hide it from public view and send it for moderator review. If a comment was already auto-hidden, removing a report afterward does not automatically show it again.
                """),
                .init(heading: "Moderator review", body: """
                FanGeo moderators may restore, keep hidden, or delete reported content. Severe or repeated violations may result in warnings, temporary restrictions, suspension, or account removal.
                """),
                .init(heading: "Private chat safety", body: """
                Private messaging is available only after the other person accepts your friend request. You can block other users from interacting with you where the app supports it (for example direct chat). Report abusive behavior. FanGeo may restrict accounts that misuse private messaging.
                """),
                .init(heading: "Private conversation reporting", body: """
                You can report a private conversation for moderator review. Only one open report per conversation per account. Submitting a report does not automatically ban anyone or notify the other person. Moderators review submissions; serious or repeat abuse may lead to stronger action. The app limits rapid or duplicate reports, and false or abusive reporting may affect your account.
                """),
                .init(heading: "Your agreement", body: """
                By using FanGeo, you agree to follow these guidelines and help maintain a respectful sports community.
                """)
            ]
        case .safetyReporting:
            return [
                .init(heading: "Overview", body: """
                Your safety matters. Reports are reviewed by FanGeo. This page summarizes how reporting works in the app today.
                """),
                .init(heading: "What you can report", body: """
                Use in-app report or flag actions where available—for example user reports, direct messages and conversations, venue listings, and venue/event comments or fan updates. Clear, accurate details help moderators understand what happened.
                """),
                .init(heading: "Comments & fan updates", body: """
                Each user can have one active report per comment. You can remove an accidental report by tapping the red flag again before thresholds apply. Up to three unique active reports from different users may trigger automatic hiding from public view while content is reviewed. If a comment was already auto-hidden, removing a report does not automatically restore it.
                """),
                .init(heading: "Private conversation reporting", body: """
                From a direct chat, you can report the conversation or a specific message. One open conversation report per account per thread helps prevent spam. Optional report details are limited in length and checked for harmful language. Submitting a report does not automatically ban a user, delete messages, hide the chat, or notify the person you reported. FanGeo applies short cooldowns and per-account limits on how often you can submit conversation reports. Moderators review credible reports; serious or repeated abuse may lead to warnings, restrictions, suspension, or removal. Filing false or malicious reports is not allowed and may limit your account.
                """),
                .init(heading: "Blocking", body: """
                Users can block other users from interacting with them where blocking is supported (for example direct chat). Blocking limits unwanted contact in the app; it does not prevent someone from contacting you outside FanGeo.
                """),
                .init(heading: "Moderation & misuse", body: """
                Moderators may warn users, hide or delete content, restrict features, suspend accounts, or remove accounts depending on severity and repeat behavior. Credible reports are taken seriously; outcomes may vary. Do not file false or malicious reports—misuse may lead to restrictions on your account.
                """),
                .init(heading: "App Store compliance", body: """
                Private messaging includes user reporting and moderation escalation mechanisms. Users can block other users from interacting with them where blocking is supported in the app.
                """),
                .init(heading: "Emergencies", body: """
                If you or someone else is in immediate danger, contact your local emergency services right away. FanGeo is not a crisis service and cannot replace police, medical, or other emergency responders.
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
