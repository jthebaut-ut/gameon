import AuthenticationServices
import CryptoKit
import Security
import SwiftUI

struct FanGeoAppleSignInButton: View {
    @ObservedObject var viewModel: MapViewModel
    let accountMode: AppleAuthAccountMode
    var entryPoint: AppleAuthEntryPoint = .signIn

    @Environment(\.colorScheme) private var colorScheme
    @State private var currentNonce: String?
    @State private var isAuthorizing = false

    var body: some View {
        SignInWithAppleButton(.continue) { request in
            let nonce = Self.randomNonceString()
            currentNonce = nonce
            isAuthorizing = true
            print("[AppleAuthDebug] buttonTapped=true accountMode=\(accountMode.rawValue) entryPoint=\(entryPoint.rawValue)")
            if entryPoint == .fanSignup {
                print("[FanSignupDebug] appleButtonTapped=true")
            }
            print("[AppleAuthDebug] authorizationStarted=true")
            Task {
                await viewModel.clearAppleAuthMessage(accountMode: accountMode, reason: "retry")
            }
            request.requestedScopes = [.fullName, .email]
            request.nonce = Self.sha256(nonce)
        } onCompletion: { result in
            handleAuthorizationResult(result)
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 48)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .disabled(isAuthorizing)
        .opacity(isAuthorizing ? 0.72 : 1)
    }

    private func handleAuthorizationResult(_ result: Result<ASAuthorization, Error>) {
        defer { isAuthorizing = false }

        switch result {
        case .success(let authorization):
            print("[AppleAuthDebug] authorizationCompletion=success")
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                print("[AppleAuthDebug] credentialReceived=false credentialType=\(type(of: authorization.credential))")
                Task { await viewModel.handleAppleAuthFailure(message: "Apple sign in returned an unexpected credential type.", accountMode: accountMode) }
                return
            }
            print("[AppleAuthDebug] credentialReceived=true userIdentifierPresent=\(!credential.user.isEmpty)")
            print("[AppleAuthDebug] authorizationCodeExists=\(credential.authorizationCode != nil)")
            print("[AppleAuthDebug] identityTokenExists=\(credential.identityToken != nil)")
            guard let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8),
                  let rawNonce = currentNonce else {
                print("[AppleAuthDebug] identityTokenReceived=false rawNonceExists=\(currentNonce != nil)")
                Task { await viewModel.handleAppleAuthFailure(message: "Apple sign in did not return a valid identity token.", accountMode: accountMode) }
                return
            }
            print("[AppleAuthDebug] identityTokenReceived=true identityTokenLength=\(identityToken.count)")
            if entryPoint == .fanSignup {
                print("[FanSignupDebug] appleCredentialReady=true emailProvidedByApple=\(credential.email != nil)")
            }
            Task {
                await viewModel.signInWithAppleIdentityToken(
                    identityToken,
                    rawNonce: rawNonce,
                    email: credential.email,
                    fullName: credential.fullName,
                    accountMode: accountMode,
                    entryPoint: entryPoint
                )
            }

        case .failure(let error):
            let nsError = error as NSError
            print("[AppleAuthDebug] authorizationCompletion=failure domain=\(nsError.domain) code=\(nsError.code) localized=\(error.localizedDescription) raw=\(String(reflecting: error))")
            if nsError.domain == ASAuthorizationError.errorDomain,
               nsError.code == ASAuthorizationError.canceled.rawValue {
                print("[AppleAuthDebug] authorizationCancelled=true")
                return
            }
            Task { await viewModel.handleAppleAuthFailure(message: error.localizedDescription, accountMode: accountMode) }
        }
    }

    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            guard status == errSecSuccess else {
                fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(status)")
            }

            for random in randoms {
                guard remainingLength > 0 else { break }
                if random < UInt8(charset.count) {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }

        return result
    }

    private static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.map { String(format: "%02x", $0) }.joined()
    }
}
