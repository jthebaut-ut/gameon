import SwiftUI

// MARK: - Legal & Safety (draft in-app policies; not legal advice)

enum FanGeoLegalLinks {
    static let supportEmail = "support@fangeosports.com"
    static let supportEmailURL = URL(string: "mailto:\(supportEmail)")!
    static let communityGuidelines = URL(string: "https://fangeosports.com/community-guidelines")!
    static let trustSafety = URL(string: "https://fangeosports.com/trust-safety")!
    static let privacyPolicy = URL(string: "https://fangeosports.com/privacy")!
    static let termsOfService = URL(string: "https://fangeosports.com/terms")!
}

enum SettingsLegalDocumentKind: String, Identifiable, Hashable {
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
        case .safetyReporting: return "Trust & Safety"
        }
    }

    var rowSubtitle: String {
        switch self {
        case .privacyPolicy: return "How FanGeo protects your information."
        case .termsOfService: return "Rules for using FanGeo."
        case .communityGuidelines: return "Community standards for FanGeo."
        case .safetyReporting: return "How FanGeo handles reports and moderation."
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
    static let lastUpdatedDisplay = "May 22, 2026"

    var draftSections: [SettingsLegalContentSection] {
        switch self {
        case .privacyPolicy:
            return [
                .init(heading: "Overview", body: """
                This Privacy Policy explains how FanGeo collects, uses, shares, and retains information when you use the app. This in-app version is a draft for App Store submission and should be reviewed before public launch.
                """),
                .init(heading: "Account and profile data", body: """
                We collect information you provide or create for your account, such as email address, display name, username, bio, avatar, authentication identifiers, favorite teams, saved venues, saved games, attendance/interest signals, notification preferences, live visibility settings, blocks, reports, and similar profile or preference data.
                """),
                .init(heading: "Location and discovery", body: """
                FanGeo may use your device location, map region, searched city, or venue location to show nearby sports bars, games, pickup activity, and local fan activity. You can control device location access in iOS Settings. Venue and business listings may include addresses, coordinates, photos, hours, contact details, and claim or ownership information submitted by venue owners.
                """),
                .init(heading: "Messages, Fan Chats, and user content", body: """
                FanGeo processes user-generated content such as direct messages, private conversations, Fan Chats, comments, venue/event posts, photos, reports, and related metadata so the app can deliver conversations, preserve thread context, enforce safety rules, investigate abuse, and maintain service integrity.
                """),
                .init(heading: "Reports and moderation", body: """
                When you report a user, comment, message, conversation, venue, or other content, we process your report, selected reason, optional details, reported content, message or conversation context where supported, timestamps, account identifiers, and moderation status. Moderation records may be retained to protect users, enforce rules, and comply with legal or App Store obligations.
                """),
                .init(heading: "Ads, analytics, and diagnostics", body: """
                FanGeo uses Google AdMob to show ads. AdMob may receive device, ad interaction, approximate location, and advertising identifier information depending on your device settings and consent choices. FanGeo may also use app diagnostics, logs, performance data, and crash-related information to debug, prevent abuse, and improve reliability. Debug logs are intended for operations and testing, not for selling personal information.
                """),
                .init(heading: "Third-party services", body: """
                FanGeo relies on service providers such as Supabase for authentication, database, storage, realtime features, and edge functions; Google AdMob for ads; Apple platform services; and sports data providers such as TheSportsDB for schedules and live match data. These providers process data as needed to provide their services.
                """),
                .init(heading: "Account deletion", body: """
                Deleting your account removes or anonymizes your public profile and personal preferences. Some messages, comments, reports, and moderation records may be retained and shown as "Deleted User" to preserve conversation integrity, safety, and legal/compliance records. Deleted accounts cannot log back in unless FanGeo support restores or reactivates the account.
                """),
                .init(heading: "Data retention", body: """
                We keep account and app data while needed to operate FanGeo, provide requested features, prevent abuse, resolve disputes, comply with law, and maintain safety records. Retention periods vary by data type. Public or shared content may remain after deletion when necessary to preserve conversations, reports, moderation history, venue records, business claims, or legal/compliance records.
                """),
                .init(heading: "Contact", body: """
                For privacy or deletion questions, use the support channel available in the app or the final support contact listed in the hosted policy before launch.
                """)
            ]
        case .termsOfService:
            return [
                .init(heading: "Overview", body: """
                These Terms of Service are draft rules for using FanGeo. By using the app, creating an account, posting content, sending messages, submitting reports, claiming a venue, or managing a business listing, you agree to follow these terms and any final version posted before public launch.
                """),
                .init(heading: "Acceptable use", body: """
                Use FanGeo only for lawful, personal, and legitimate business-listing purposes. Do not misuse the service, spam, scrape, crawl, harvest data, manipulate attendance or ratings, interfere with app security, bypass access controls, or attempt to access accounts, messages, reports, admin tools, venue tools, or data you are not authorized to use.
                """),
                .init(heading: "User content", body: """
                You are responsible for content you create, upload, send, or submit, including profile details, avatars, Fan Chats, direct messages, reports, pickup activity, venue photos, business information, and venue game schedules. You keep your ownership rights, but you give FanGeo permission to host, display, store, moderate, reproduce, and distribute your content as needed to operate, improve, and protect the service.
                """),
                .init(heading: "No harassment or unsafe conduct", body: """
                Sports rivalry and spirited debate are welcome. Harassment, threats, hate speech, doxxing, sexual exploitation, targeted abuse, impersonation, stalking, scams, and encouragement of illegal or unsafe behavior are not allowed. Do not use FanGeo to organize unsafe meetups or pressure users to share private information.
                """),
                .init(heading: "Venue and business claims", body: """
                If you claim or manage a venue, business account, or location, you confirm that you are authorized to do so and that the information you submit is accurate. FanGeo may review, reject, approve, archive, remove, or limit venue and business claims or listings that are inaccurate, fraudulent, duplicate, unsafe, inactive, or violate these terms.
                """),
                .init(heading: "Moderation and enforcement", body: """
                FanGeo may review reports, remove or hide content, restrict features, block access, suspend accounts, delete accounts, preserve records, or take other action when we believe these terms, Community Guidelines, safety rules, law, or App Store requirements have been violated. We may also preserve content or records where needed for safety, compliance, dispute resolution, or legal reasons.
                """),
                .init(heading: "App limitations", body: """
                FanGeo is provided as-is to the extent allowed by law. We do not guarantee uninterrupted service, exact venue data, complete sports schedules, ad availability, report outcomes, or that every user or venue will act safely. Features may change, be limited, or be discontinued.
                """)
            ]
        case .communityGuidelines:
            return [
                .init(heading: "Sports rivalry is fine; abuse is not", body: """
                Cheer hard, debate teams, and talk trash about the scoreboard, but do not target people with harassment, threats, hate speech, slurs, bullying, stalking, sexual comments, or repeated unwanted contact.
                """),
                .init(heading: "Not allowed", body: """
                - Harassment, bullying, threats, or targeted abuse
                - Hate speech, racism, slurs, or discrimination
                - Doxxing, sharing private information, or pressuring users to reveal personal details
                - Impersonating users, venues, teams, leagues, FanGeo, or public figures
                - Spam, scams, phishing, fake promotions, scraping, or repeated disruptive posts
                - Unsafe meetup behavior, coercion, stalking, or encouraging violence or illegal acts
                - Sexual exploitation, explicit content, or content involving minors
                """),
                .init(heading: "Fan Chats and comments", body: """
                Keep Fan Chats and venue/event comments useful for the local sports crowd. Do not derail threads with spam, personal attacks, false venue information, or coordinated abuse. Comments may be hidden, removed, or reviewed when reported or when they appear to violate these guidelines.
                """),
                .init(heading: "DMs and friend interactions", body: """
                Direct messages are for respectful conversation with people who accepted a friend connection. Do not send abusive, threatening, sexual, scam, spam, or repeated unwanted messages. If someone asks you to stop, stop.
                """),
                .init(heading: "Report and block", body: """
                Report abusive users, comments, messages, or conversations using the in-app report tools where available. Block users who should not contact you. Reports help FanGeo review safety issues, but they should be truthful and made in good faith.
                """),
                .init(heading: "Enforcement", body: """
                FanGeo may warn users, remove content, hide comments, restrict messaging, suspend accounts, delete accounts, preserve reports, or take other action depending on severity, context, and repeat behavior.
                """),
                .init(heading: "Your agreement", body: """
                By using FanGeo, you agree to follow these guidelines and help maintain a respectful sports community.
                """)
            ]
        case .safetyReporting:
            return [
                .init(heading: "Overview", body: """
                Your safety matters. FanGeo provides reporting and blocking tools for abusive behavior, UGC, DMs, Fan Chats, comments, conversations, and venue-related issues where supported in the app. Reports are reviewed under FanGeo's Community Guidelines.
                """),
                .init(heading: "What you can report", body: """
                Use in-app report or flag actions where available, including user reports, Fan Chat comments, direct messages, conversations, venue listings, and venue/event content. Clear, accurate details help moderators understand what happened.
                """),
                .init(heading: "Comments & fan updates", body: """
                Each user can have one active report per comment. You can remove an accidental report by tapping the red flag again before thresholds apply. Multiple unique active reports may trigger automatic hiding from public view while content is reviewed. If a comment was already auto-hidden, removing a report does not automatically restore it.
                """),
                .init(heading: "Private conversation reporting", body: """
                From a direct chat, you can report the conversation or supported message content for moderator review. DM reports may include the selected review window only, along with related metadata needed to evaluate the report. Submitting a report does not automatically ban a user, delete messages, hide the chat, or notify the person you reported. FanGeo may apply cooldowns, duplicate-report limits, and abuse-prevention checks.
                """),
                .init(heading: "Blocking", body: """
                Users can block other users from interacting with them where blocking is supported, including direct chat surfaces. Blocking limits unwanted contact in FanGeo; it does not prevent someone from contacting you outside FanGeo.
                """),
                .init(heading: "Moderation review", body: """
                Moderation review may include report details, reporter and reported account identifiers, timestamps, selected reasons, reported comments or messages, limited surrounding context, moderation decisions, and records needed for safety or compliance. Moderation records may be retained for safety. Moderators may warn users, hide or delete content, restrict features, restrict abusive users, suspend accounts, delete accounts, or preserve records depending on severity and repeat behavior.
                """),
                .init(heading: "App Store compliance", body: """
                FanGeo includes in-app reporting and moderation escalation mechanisms for UGC and private messaging. Users can block other users from interacting with them where blocking is supported in the app.
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
    var embedsInNavigationStack = true
    var showsCloseButton = true
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @ViewBuilder
    var body: some View {
        if embedsInNavigationStack {
            NavigationStack {
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
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
        .navigationTitle(localizedDocumentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var localizedDocumentTitle: String {
        switch document {
        case .communityGuidelines:
            return L10n.t("community_guidelines", languageCode: appLanguageRaw)
        case .safetyReporting:
            return document.title
        default:
            return document.title
        }
    }
}
