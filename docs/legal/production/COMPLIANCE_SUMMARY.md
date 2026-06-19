# FanGeo Sports — Legal & Compliance Summary

**Prepared from codebase inspection**  
**Effective date of policy documents:** June 16, 2026  
**Support contact:** support@fangeosports.com

---

## Document Package

Production-ready policy documents are located in `docs/legal/production/`:

| Document | Web (HTML) | Word-friendly |
|----------|------------|---------------|
| Privacy Policy | `privacy-policy.html` | `privacy-policy.docx.md` |
| Terms of Service | `terms-of-service.html` | `terms-of-service.docx.md` |
| Trust & Safety Policy | `trust-safety-policy.html` | `trust-safety-policy.docx.md` |
| Community Guidelines | `community-guidelines.html` | `community-guidelines.docx.md` |

**Hosted URL placeholders (publish before App Store release):**

- https://fangeosports.com/privacy
- https://fangeosports.com/terms
- https://fangeosports.com/trust-safety
- https://fangeosports.com/community-guidelines

**Word usage:** Open any `*.docx.md` file in Microsoft Word and use **Save As → Word Document (.docx)**. Formatting uses plain headings and bullets designed for clean Word import.

---

## 1. App Store Review Compliance

### Implemented and aligned

| Requirement | Implementation evidence |
|-------------|-------------------------|
| Account creation | Email/password and Sign in with Apple (`FanGeoAppleSignInButton.swift`, `MapViewModel+AuthAndProfile.swift`) |
| Account deletion | Fan deletion via `request_delete_my_account` RPC; business deletion via `delete_business_account_cascade` (`SettingsScreen.swift`, `MapViewModel+AccountDeletion.swift`) |
| In-app legal access | Settings legal sheets + signup links (`SettingsLegalSafetyViews.swift`, `FanSignupView.swift`) |
| UGC surfaces | Fan Chats, DMs, profiles, avatars, venue photos, pickup listings |
| Report mechanism | Comment flags; DM user/conversation/message reports (`ModerationService.swift`, `DirectChatView.swift`, `VenueEventCommentsView.swift`) |
| Block mechanism | `ModerationService.block` enforced server-side; DM and social surfaces (`RecoveredSocialChatViews.swift`) |
| Moderation escalation | Auto-hide at 3 comment reports; auto-remove DM at 3 message reports; admin email edge functions |
| ATT disclosure | `NSUserTrackingUsageDescription` in `AdMob-Info.plist` |
| Photo library disclosure | `NSPhotoLibraryUsageDescription` in project build settings |
| Location disclosure | When-in-use location string in project build settings |
| Calendar disclosure | EventKit usage string in project build settings |
| Ads disclosure | Google AdMob banner + native; UMP + pre-consent flow (`AdMobBannerView.swift`, `FanSpotApp.swift`) |

### Gaps and risks for App Store review

| Gap | Severity | Notes |
|-----|----------|-------|
| **In-app policies still labeled “Draft”** | High | `SettingsLegalDocumentSheet` displays “Draft — for in-app reference only; not legal advice.” Hosted production URLs should replace or supplement in-app drafts before submission. |
| **Hosted policy URLs not live** | High | App Store Connect requires working Privacy Policy URL. Placeholder domains must be published. |
| **No in-app profile report UI** | Medium | Users can report via DMs; there is no standalone “Report profile” action. Support form covers gaps, but App Review may ask for broader UGC reporting. |
| **Venue report API without UI** | Medium | `ModerationService.reportVenue` exists but has no Swift UI call sites. Policies route venue issues to support instead. |
| **Some notification toggles not wired** | Low–Medium | Settings toggles for favorite-team-nearby and several pickup notification types appear without delivery code. Do not market these in App Store copy until implemented. |
| **Admin moderation UI unwired** | Low (internal) | `AdminScreen.swift` exists but is not navigable; global DM/user report review is operations/backend only. |
| **Business Pro billing copy** | Medium | `BusinessMembership.swift` includes “Business Pro billing is coming soon” while StoreKit entitlement paths exist. Ensure App Store IAP metadata matches live purchase behavior. |
| **APNs entitlement environment** | Medium (release ops) | `GameOn.entitlements` shows `aps-environment = development`. Production archive must use production push environment. |
| **Legal entity details** | Medium | Policies use “FanGeo Sports” but registered legal entity name, address, and DMCA agent (if hosting UGC at scale) are not in codebase. Counsel should confirm. |
| **Age gate not enforced in UI** | Medium | Terms state 13+ minimum, but signup does not collect birthdate or block under-13 users programmatically. |

---

## 2. GDPR Considerations (EEA / UK)

### Covered in Privacy Policy

- Categories of personal data collected (account, UGC, location, ads, analytics, moderation)
- Purposes and legal bases (contract, legitimate interests, consent)
- Third-party processors (Supabase, Google AdMob, Apple, sports data providers)
- Retention and deletion behavior
- International transfer disclosure (U.S. processing)
- Rights to access, correct, delete, object, withdraw consent, and complain

### Gaps

| Gap | Recommendation |
|-----|----------------|
| **No in-app data export** | Provide a manual export process via support@fangeosports.com or build a data access/export feature before broad EEA launch. |
| **No dedicated EU/UK representative named** | Appoint an Article 27 representative if required based on user volume and targeting. |
| **DPIA not documented** | Consider a Data Protection Impact Assessment for DMs, location, ads, and moderation snapshots. |
| **Consent records** | UMP handles ad consent; document how consent records are retained for audit. |
| **Fan deletion retains auth.users** | `request_delete_my_account` anonymizes profile but preserves `auth.users` per migration comments. Privacy Policy discloses retention; confirm this meets GDPR erasure expectations or add auth deletion where lawful. |

---

## 3. U.S. Privacy Considerations

### Covered

- CCPA/CPRA-style rights section in Privacy Policy
- Children’s privacy (13+ statement; no knowing collection under 13)
- Account deletion disclosures aligned with in-app copy
- California opt-out context for ad tracking via iOS Settings and UMP

### Gaps

| Gap | Recommendation |
|-----|----------------|
| **No “Do Not Sell or Share” web link** | If targeting California users at scale, publish a CPRA notice and honor opt-out of sale/share for advertising where required. |
| **State privacy laws (CO, CT, VA, etc.)** | Assess applicability as user base grows; policies are generally compatible but may need state-specific addenda. |
| **Registered business address** | Add legal business address to hosted policies if required by state law or App Store. |

---

## 4. AdMob / Google Consent Disclosures

### Implemented

| Element | Detail |
|---------|--------|
| Ad formats | Banner (`discover.bottomStrip`) and native (`chat.inboxFeed`, `going.proGamesFeed`, `live.feed`, `venue.commentsFeed`, `venue.gamesFeed`) |
| Production ad units | App ID `ca-app-pub-9637364906993742~5547329973`; banner `.../6964124517`; native `.../7885775201` |
| Consent flow | Pre-consent sheet → UMP `requestConsentInfoUpdate` → `ConsentForm.loadAndPresentIfRequired` → ATT → `MobileAds.start` if `canRequestAds` |
| Re-consent | Settings “Privacy & Ad Choices” when `privacyOptionsRequirementStatus == .required` |
| ATT string | “FanGeo uses your data to show more relevant ads and support the app.” |
| SKAdNetwork | 48 identifiers in `AdMob-Info.plist` |

### Disclosed in Privacy Policy

- Google AdMob as advertising partner
- IDFA/ad identifiers where permitted
- UMP consent signals
- User controls via iOS Settings and in-app privacy options

### Gaps

| Gap | Recommendation |
|-----|----------------|
| **Link to Google’s ad policy / partner disclosures** | Add links to [Google Privacy Policy](https://policies.google.com/privacy) and AdMob program policies on hosted Privacy Policy. |
| **TestFlight test ad behavior** | Release builds with sandbox receipts can enable test ad units via `AdDiagnostics` — not a public user issue, but avoid TestFlight screenshots showing test ads. |
| **App Store Privacy Nutrition Labels** | Manually verify labels match: email, user ID, location (coarse/precise), photos, UGC, diagnostics, advertising data, product interaction. |

---

## 5. User-Generated Content Moderation Disclosures

### Implemented features reflected in policies

| Feature | Behavior |
|---------|----------|
| Fan Chat comments | 160-char limit; profanity filter; flag reports; auto-hide at 3 unique reports |
| Direct messages | Friend-gated; report user/conversation/message; auto-remove message at 3 reports |
| Blocking | Bidirectional enforcement on DMs, friend requests, discovery-related RPCs |
| User bans | `user_bans` table; `get_my_active_ban` RPC; full-screen `AccountSuspensionGateView` |
| Business bans | `business_bans` table; separate business suspension gate |
| Account disable | `user_profiles.admin_status == "disabled"` forces logout |
| Venue owner tools | Flagged comments review in Settings; delete comment or dismiss report |
| Support escalation | `SupportRequestService` + `notify-support-request` edge function |
| Admin alerts | Email on DM/user/conversation/message reports and comment threshold alerts |

### Policy accuracy choices (intentional)

- **Venue listing reports:** Not exposed in UI; policies direct users to support for venue/business issues rather than claiming an in-app venue report button.
- **Profile reports:** Not exposed as standalone UI; DM report paths and support cover user misconduct.
- **Reports do not auto-ban:** Accurately disclosed per `Safety_Reporting.md` and app behavior.

### Moderation gaps

| Gap | Risk |
|-----|------|
| No in-app global admin review UI for DM/user/conversation reports | Operational burden; slower response times |
| Venue owner flagged-comments loader may surface reports beyond owner scope | Internal tooling accuracy issue; not a policy gap but affects trust |
| Client profanity filter only | Server-side content policy enforcement should be verified for all UGC paths |
| Block does not auto-unfriend (code TODO) | Users may still appear as friends while blocked on some surfaces — document or fix |

---

## 6. Feature-to-Policy Mapping (Inspection Checklist)

| Feature area | Inspected | Reflected in policies |
|--------------|-----------|----------------------|
| Authentication (email, Apple) | Yes | Yes |
| Fan vs business account separation | Yes | Yes |
| Guest discover browsing | Yes | Yes |
| User profiles (avatar, bio, handle, teams) | Yes | Yes |
| Business accounts & Business Pro | Yes | Yes |
| Venue management & claims | Yes | Yes |
| Pickup games (fans only) | Yes | Yes |
| Fan Chats / comments | Yes | Yes |
| Direct messages & friends | Yes | Yes |
| Reports & moderation | Yes | Yes |
| Blocking | Yes | Yes |
| User/business bans | Yes | Yes |
| Location (when in use) | Yes | Yes |
| Push notifications (local + APNs pro alerts) | Yes | Yes |
| Apple Calendar sync (opt-in) | Yes | Yes |
| AdMob + UMP + ATT | Yes | Yes |
| First-party analytics (Supabase) | Yes | Yes |
| Photos/avatars (Supabase Storage) | Yes | Yes |
| Account deletion (fan & business) | Yes | Yes |
| Admin review tools | Partial (backend/email; limited in-app) | Yes (disclosed accurately) |

**Not referenced in policies (not implemented or not user-facing):**

- Google/Facebook/phone login
- Interstitial or rewarded ads
- In-app global admin dashboard for end users
- Venue in-app report button
- Third-party analytics SDKs (Firebase, etc.)
- Always-on background location

---

## 7. Recommended Pre-Launch Checklist

1. **Legal review** — Have counsel review all four documents, entity name, governing law, and deletion/retention language.
2. **Publish hosted URLs** — Upload HTML versions to fangeosports.com paths listed above.
3. **Update in-app links** — Point Settings and signup flows to hosted URLs; remove “Draft” labeling from production builds.
4. **App Store Connect** — Enter Privacy Policy URL, age rating questionnaire, privacy nutrition labels, and UGC safety questionnaire answers consistent with these documents.
5. **Verify IAP** — Align Business Pro App Store product metadata with live StoreKit behavior.
6. **Production push** — Confirm APNs production entitlement in release archive.
7. **Support workflow** — Train support on report handling, deletion appeals, and GDPR/CCPA requests at support@fangeosports.com.
8. **Optional product fixes** — Profile report button, venue report UI, wire or remove dormant notification toggles, fix admin/venue-owner tooling gaps.

---

## 8. Disclaimer

These documents were generated from inspection of the FanGeo iOS codebase and existing legal drafts. They are intended for production preparation but **do not constitute legal advice**. FanGeo Sports should obtain qualified legal counsel before App Store submission and before operating in regulated jurisdictions.

---

**Document version:** 1.0  
**Inspection date:** June 16, 2026
