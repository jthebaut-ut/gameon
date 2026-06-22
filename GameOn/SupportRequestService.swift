import Foundation
import Supabase

enum SupportRequestCategory: String, CaseIterable, Identifiable {
    case bugReport = "bug_report"
    case question = "question"
    case featureRequest = "feature_request"
    case accountIssue = "account_issue"
    case businessSupport = "business_support"
    case other = "other"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .bugReport: return "Bug Report"
        case .question: return "Question"
        case .featureRequest: return "Feature Request"
        case .accountIssue: return "Account Issue"
        case .businessSupport: return "Business Support"
        case .other: return "Other"
        }
    }

    /// Contextual hint under the issue type picker.
    var exampleHelperLine: String? {
        switch self {
        case .bugReport:
            return "Example: The map is frozen or messages are not loading."
        case .question:
            return "Example: How do I save a game to my calendar?"
        case .featureRequest:
            return "Example: I'd love a way to filter live games by league."
        case .accountIssue:
            return "Example: I cannot sign in or reset my password."
        case .businessSupport:
            return "Example: I need help claiming or editing my venue."
        case .other:
            return "Example: General feedback or anything else we can help with."
        }
    }
}

enum SupportRequestSubmitError: LocalizedError, Equatable {
    case notSignedIn
    case rateLimited(String)
    case prohibitedContent
    case emailSendFailed

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Please sign in to contact support."
        case .rateLimited(let message):
            return message
        case .prohibitedContent:
            return ModerationService.profanityRejectionUserMessage()
        case .emailSendFailed:
            return "Unable to send support request right now. Please try again later."
        }
    }
}

/// Persists optional `support_requests` rows and sends admin email via ``notify-support-request`` Edge Function.
struct SupportRequestService {
    static let messageMaxCharacters = 1000
    static let subjectMaxCharacters = 200

    private struct SupportRequestRow: Encodable {
        let user_id: UUID
        let category: String
        let subject: String
        let message: String
        let app_version: String?
    }

    private struct NotifySupportRequestPayload: Encodable {
        let category: String
        let subject: String
        let message: String
        let app_version: String?
        let client_timestamp: String
    }

    private struct NotifySupportRequestResponse: Decodable {
        let ok: Bool?
        let error: String?
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func appVersionLine() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let vt = v.trimmingCharacters(in: .whitespacesAndNewlines)
        let bt = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if vt.isEmpty, bt.isEmpty { return "" }
        if bt.isEmpty { return vt }
        if vt.isEmpty { return "build \(bt)" }
        return "\(vt) (\(bt))"
    }

    func submitSupportRequest(
        category: SupportRequestCategory,
        subject: String,
        message: String,
        client: SupabaseClient
    ) async throws {
        let userId: UUID
        do {
            userId = try await client.auth.session.user.id
        } catch {
            throw SupportRequestSubmitError.notSignedIn
        }
        let sub = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sub.isEmpty, !msg.isEmpty else {
            throw SupportRequestSubmitError.emailSendFailed
        }
        if sub.count > Self.subjectMaxCharacters || msg.count > Self.messageMaxCharacters {
            throw SupportRequestSubmitError.emailSendFailed
        }

        if let limitMessage = RateLimitService.checkSupportRequestSubmit(userId: userId) {
#if DEBUG
            print("[Support] support request blocked by cooldown")
#endif
            throw SupportRequestSubmitError.rateLimited(limitMessage)
        }

        if ModerationService.containsProfanity(msg) {
            throw SupportRequestSubmitError.prohibitedContent
        }

#if DEBUG
        print("[Support] support request submitted")
#endif

        let appVer = Self.appVersionLine()
        let appVerField: String? = appVer.isEmpty ? nil : appVer
        let row = SupportRequestRow(
            user_id: userId,
            category: category.rawValue,
            subject: sub,
            message: msg,
            app_version: appVerField
        )

        do {
            _ = try await client
                .from("support_requests")
                .insert(row)
                .execute()
        } catch {
#if DEBUG
            print("[Support] support_requests insert skipped or failed:", error)
#endif
        }

        let ts = Self.iso.string(from: Date())
        let payload = NotifySupportRequestPayload(
            category: category.rawValue,
            subject: sub,
            message: msg,
            app_version: appVerField,
            client_timestamp: ts
        )

#if DEBUG
        print("[Support] support email queued")
#endif

        do {
            let response: NotifySupportRequestResponse = try await client.functions.invoke(
                "notify-support-request",
                options: FunctionInvokeOptions(method: .post, body: payload)
            )
            if response.ok != true {
                if response.error == "prohibited_content" {
                    throw SupportRequestSubmitError.prohibitedContent
                }
                throw SupportRequestSubmitError.emailSendFailed
            }
        } catch let error as FunctionsError {
#if DEBUG
            if case let .httpError(status, data) = error {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[Support] notify-support-request httpError status=\(status) body=\(body)")
            } else {
                print("[Support] notify-support-request FunctionsError:", error)
            }
#endif
            if case let .httpError(_, data) = error,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["error"] as? String) == "prohibited_content" {
                throw SupportRequestSubmitError.prohibitedContent
            }
            throw SupportRequestSubmitError.emailSendFailed
        } catch let err as SupportRequestSubmitError {
            throw err
        } catch {
#if DEBUG
            print("[Support] notify-support-request failed:", error)
#endif
            throw SupportRequestSubmitError.emailSendFailed
        }

        RateLimitService.recordSupportRequestSubmit(userId: userId)
    }
}
