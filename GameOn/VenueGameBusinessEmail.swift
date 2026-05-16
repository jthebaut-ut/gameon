import SwiftUI

// MARK: - Venue business contact email (Discover / detail / calendar / Following / Manage Games)

enum VenueGameBusinessEmail {

    /// Public listings: hide when venue row is explicitly archived.
    static func venueListingIsEligibleForPublicContact(bar: BarVenue) -> Bool {
        let st = bar.adminStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if st == "archived" { return false }
        return true
    }

    /// Business / owner contact: strict-valid ``BarVenue/ownerEmail`` (Discover merges `venues.owner_email` then active `businesses.owner_email`), non-archived venue listing.
    static func resolvedDisplayEmail(for bar: BarVenue) -> String? {
        guard venueListingIsEligibleForPublicContact(bar: bar) else { return nil }
        let raw = bar.ownerEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        let norm = OwnerBusinessEmail.normalized(raw)
        guard OwnerBusinessEmail.isValidStrict(norm) else { return nil }
        return norm
    }

    /// From a ``VenueEventRow`` (Manage Games / Following); archived events are excluded.
    static func resolvedDisplayEmail(forEvent row: VenueEventRow) -> String? {
        let st = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if st == "archived" { return nil }
        let raw = row.owner_email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        let norm = OwnerBusinessEmail.normalized(raw)
        guard OwnerBusinessEmail.isValidStrict(norm) else { return nil }
        return norm
    }

    static func logDebug(venueId: UUID?, venueName: String, resolvedBusinessEmail: String?, source: String) {
#if DEBUG
        print("[VenueGameEmailDebug] venueId=\(venueId?.uuidString.lowercased() ?? "nil")")
        print("[VenueGameEmailDebug] venueName=\(venueName)")
        print("[VenueGameEmailDebug] resolvedBusinessEmail=\(resolvedBusinessEmail ?? "nil")")
        print("[VenueGameEmailDebug] source=\(source)")
#endif
    }

    static func logDebug(bar: BarVenue) {
        let resolved = resolvedDisplayEmail(for: bar)
        let source: String
        if !venueListingIsEligibleForPublicContact(bar: bar) {
            source = "ineligible_admin_status=\(bar.adminStatus ?? "nil")"
        } else if resolved == nil {
            source = "missing_or_invalid_public_owner_email"
        } else if let rawV = bar.venueOwnerEmailRaw,
                  OwnerBusinessEmail.isValidStrict(OwnerBusinessEmail.normalized(rawV)),
                  OwnerBusinessEmail.normalized(rawV) == resolved {
            source = "venues.owner_email"
        } else if bar.businessId != nil {
            source = "businesses.owner_email_fallback"
        } else {
            source = "venues.owner_email"
        }
        logDebug(venueId: bar.id, venueName: bar.name, resolvedBusinessEmail: resolved, source: source)
    }

    static func logDebug(venueEventRow row: VenueEventRow, resolvedEmail: String?, source: String) {
        let vid = row.venue_id
        let name = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        logDebug(venueId: vid, venueName: name, resolvedBusinessEmail: resolvedEmail, source: source)
    }

    /// Encoded `mailto:` URL for a validated business email string.
    static func mailtoURL(for email: String) -> URL? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "@%+._-")
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmed
        return URL(string: "mailto:\(encoded)")
    }
}

/// Discover venue detail / card: visibility + `mailto:` opens (DEBUG).
enum VenueEmailActionDebug {
    /// Venue detail load: raw row fields + resolved visibility (exact log keys for email affordance debugging).
    static func logLoad(bar: BarVenue, businessClaimStatus: VenueOwnershipClaimStatus? = nil) {
#if DEBUG
        logCore(bar: bar, emailActionVisibleOverride: nil, openedMailto: nil, businessClaimStatus: businessClaimStatus)
#endif
    }

    static func log(bar: BarVenue, emailActionVisible: Bool, openedMailto: String?, businessClaimStatus: VenueOwnershipClaimStatus? = nil) {
#if DEBUG
        logCore(bar: bar, emailActionVisibleOverride: emailActionVisible, openedMailto: openedMailto, businessClaimStatus: businessClaimStatus)
#endif
    }

#if DEBUG
    private static func logCore(
        bar: BarVenue,
        emailActionVisibleOverride: Bool?,
        openedMailto: String?,
        businessClaimStatus: VenueOwnershipClaimStatus?
    ) {
        let resolved = VenueGameBusinessEmail.resolvedDisplayEmail(for: bar)
        let visible = emailActionVisibleOverride ?? (resolved != nil)
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\n", with: " ")
        }
        func escOpt(_ s: String?) -> String {
            (s ?? "nil").replacingOccurrences(of: "\n", with: " ")
        }
        print("[VenueEmailActionDebug] venueId=\(bar.id.uuidString.lowercased())")
        print("[VenueEmailActionDebug] venueName=\(esc(bar.name))")
        print("[VenueEmailActionDebug] rawOwnerEmail=\(escOpt(bar.venueOwnerEmailRaw))")
        print("[VenueEmailActionDebug] rawBusinessEmail=\(escOpt(bar.businessOwnerEmailRaw))")
        print("[VenueEmailActionDebug] rawContactEmail=\(escOpt(bar.contactEmailRaw))")
        print("[VenueEmailActionDebug] resolvedBusinessEmail=\(escOpt(resolved))")
        print("[VenueEmailActionDebug] emailActionVisible=\(visible)")
        print("[VenueEmailActionDebug] \(emailActionDebugReasonLine(bar: bar))")
        if let businessClaimStatus {
            print("[VenueEmailActionDebug] claimStatus=\(venueOwnershipClaimStatusDebugLabel(businessClaimStatus))")
        }
        if let openedMailto {
            print("[VenueEmailActionDebug] openedMailto=\(esc(openedMailto))")
        }
    }

    /// Explains why the Email affordance is off (or `reason=visible`).
    private static func emailActionDebugReasonLine(bar: BarVenue) -> String {
        let resolved = VenueGameBusinessEmail.resolvedDisplayEmail(for: bar)
        if resolved != nil {
            return "reason=visible"
        }
        if !VenueGameBusinessEmail.venueListingIsEligibleForPublicContact(bar: bar) {
            return "reason=hidden_archived_or_ineligible_listing"
        }
        let rawO = (bar.venueOwnerEmailRaw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawB = (bar.businessOwnerEmailRaw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawO.isEmpty || !rawB.isEmpty {
            return "reason=hidden_invalid_public_email"
        }
        return "reason=hidden_no_owner_email_or_business_email"
    }

    private static func venueOwnershipClaimStatusDebugLabel(_ s: VenueOwnershipClaimStatus) -> String {
        switch s {
        case .unclaimed: return "unclaimed"
        case .pendingReview: return "pendingReview"
        case .approved: return "approved"
        case .alreadyClaimedByOtherBusiness: return "alreadyClaimedByOtherBusiness"
        case .rejected: return "rejected"
        }
    }
#endif
}

/// Tappable `mailto:` row; hidden by caller when email is nil.
struct VenueGameBusinessContactEmailRow: View {
    let email: String
    /// Hero / gradient backgrounds (Venue detail): higher-contrast secondary on white.
    var heroOnDarkBackground: Bool = false
    /// Optional override (e.g. Following tab palette).
    var secondaryForeground: Color? = nil
    /// Called right before opening Mail (e.g. venue detail DEBUG).
    var onWillOpenMail: ((URL) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    private var foreground: Color {
        if let secondaryForeground { return secondaryForeground }
        if heroOnDarkBackground {
            return Color.white.opacity(0.88)
        }
        return FGColor.secondaryText(colorScheme)
    }

    private var mailURL: URL? {
        VenueGameBusinessEmail.mailtoURL(for: email)
    }

    var body: some View {
        Button {
            guard let mailURL else { return }
            onWillOpenMail?(mailURL)
            openURL(mailURL)
        } label: {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "envelope.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(foreground)
                Text(email)
                    .font(FGTypography.caption)
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Email venue")
        .accessibilityHint("Opens Mail")
    }
}
