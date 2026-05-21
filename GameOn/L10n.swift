import SwiftUI

struct AppLanguage: Identifiable, Hashable {
    let code: String
    let nativeName: String
    let englishName: String
    let flag: String

    var id: String { code }
}

enum LocalizationDiagnostics {
    static let enabled = false
}

enum L10n {
    static let appLanguageKey = "appLanguage"
    static let defaultLanguageCode = "en"
#if DEBUG
    private static var missingKeysLogged: Set<String> = []
#endif

    static let supportedLanguages: [AppLanguage] = [
        AppLanguage(code: "en", nativeName: "English", englishName: "English", flag: "🇺🇸"),
        AppLanguage(code: "es", nativeName: "Español", englishName: "Spanish", flag: "🇪🇸"),
        AppLanguage(code: "fr", nativeName: "Français", englishName: "French", flag: "🇫🇷"),
        AppLanguage(code: "pt", nativeName: "Português", englishName: "Portuguese", flag: "🇵🇹"),
        AppLanguage(code: "de", nativeName: "Deutsch", englishName: "German", flag: "🇩🇪"),
        AppLanguage(code: "it", nativeName: "Italiano", englishName: "Italian", flag: "🇮🇹"),
        AppLanguage(code: "pl", nativeName: "Polski", englishName: "Polish", flag: "🇵🇱"),
        AppLanguage(code: "ru", nativeName: "Русский", englishName: "Russian", flag: "🇷🇺"),
        AppLanguage(code: "sq", nativeName: "Shqip", englishName: "Albanian", flag: "🇦🇱"),
        AppLanguage(code: "zh-Hans", nativeName: "中文（简体）", englishName: "Simplified Chinese", flag: "🇨🇳")
    ]

    static func normalizedLanguageCode(_ raw: String?) -> String {
        let code = (raw ?? defaultLanguageCode)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return supportedLanguages.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }?.code
            ?? defaultLanguageCode
    }

    static func language(for raw: String?) -> AppLanguage {
        let code = normalizedLanguageCode(raw)
        return supportedLanguages.first(where: { $0.code == code }) ?? supportedLanguages[0]
    }

    static func t(_ key: String, languageCode: String? = nil) -> String {
        let code = normalizedLanguageCode(languageCode ?? UserDefaults.standard.string(forKey: appLanguageKey))
        let localized = localizedString(key, languageCode: code)
        let shouldFallback = localized == key && code != defaultLanguageCode
        let resolved = localized == key ? localizedString(key, languageCode: defaultLanguageCode) : localized
        let value = resolved == key ? key : resolved
#if DEBUG
        if LocalizationDiagnostics.enabled {
            print("[LocalizationDebug] localizedKeyUsed=\(key)")
        }
        if localized == key {
            logMissingKeyOnce(key)
        }
        if shouldFallback, LocalizationDiagnostics.enabled {
            print("[LocalizationDebug] fallbackToEnglish=true")
        }
#endif
        return value
    }

#if DEBUG
    static func logMissingKeyOnce(_ key: String, prefix: String = "missingKey") {
        guard missingKeysLogged.insert("\(prefix):\(key)").inserted else { return }
        print("[LocalizationDebug] \(prefix)=\(key)")
    }
#endif

    private static func localizedString(_ key: String, languageCode: String) -> String {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

struct FanGeoLanguageSelectionView: View {
    @Binding var selectionRaw: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var selectedLanguage: AppLanguage {
        L10n.language(for: selectionRaw)
    }

    var body: some View {
        List {
            Section {
                ForEach(L10n.supportedLanguages) { language in
                    Button {
                        selectionRaw = language.code
#if DEBUG
                        print("[LocalizationDebug] selectedLanguage=\(language.code)")
#endif
                    } label: {
                        HStack(spacing: 12) {
                            Text(language.flag)
                                .font(.system(size: 23))
                                .frame(width: 30)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(language.nativeName)
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                Text(language.englishName)
                                    .font(FGTypography.caption)
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                            }

                            Spacer(minLength: 0)

                            if selectedLanguage.code == language.code {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(FGColor.accentGreen)
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
        .navigationTitle(L10n.t("language", languageCode: selectionRaw))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
#if DEBUG
                    print("[LocalizationDebug] languageDoneTapped=true")
#endif
                    dismiss()
                } label: {
                    Text(L10n.t("done", languageCode: selectionRaw))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.accentGreen)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background {
                            Capsule(style: .continuous)
                                .fill(.ultraThinMaterial)
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.78))
                        }
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.64), lineWidth: 0.75)
                        }
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.08), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("done", languageCode: selectionRaw))
            }
        }
        .onAppear {
#if DEBUG
            print("[LocalizationDebug] languageSettingVisible=true")
            print("[LocalizationDebug] selectedLanguage=\(selectedLanguage.code)")
            print("[LocalizationDebug] addedLanguage=sq")
            print("[LocalizationDebug] albanianVisible=\(L10n.supportedLanguages.contains { $0.code == "sq" })")
            print("[LocalizationDebug] addedLanguage=zh-Hans")
            print("[LocalizationDebug] chineseSimplifiedVisible=\(L10n.supportedLanguages.contains { $0.code == "zh-Hans" })")
#endif
        }
    }
}
