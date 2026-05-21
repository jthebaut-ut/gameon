import SwiftUI

struct AppLanguage: Identifiable, Hashable {
    let code: String
    let nativeName: String
    let englishName: String
    let flag: String

    var id: String { code }
}

enum L10n {
    static let appLanguageKey = "appLanguage"
    static let defaultLanguageCode = "en"

    static let supportedLanguages: [AppLanguage] = [
        AppLanguage(code: "en", nativeName: "English", englishName: "English", flag: "🇺🇸"),
        AppLanguage(code: "es", nativeName: "Español", englishName: "Spanish", flag: "🇪🇸"),
        AppLanguage(code: "fr", nativeName: "Français", englishName: "French", flag: "🇫🇷"),
        AppLanguage(code: "pt", nativeName: "Português", englishName: "Portuguese", flag: "🇵🇹"),
        AppLanguage(code: "de", nativeName: "Deutsch", englishName: "German", flag: "🇩🇪"),
        AppLanguage(code: "it", nativeName: "Italiano", englishName: "Italian", flag: "🇮🇹"),
        AppLanguage(code: "pl", nativeName: "Polski", englishName: "Polish", flag: "🇵🇱"),
        AppLanguage(code: "ru", nativeName: "Русский", englishName: "Russian", flag: "🇷🇺")
    ]

    static func normalizedLanguageCode(_ raw: String?) -> String {
        let code = (raw ?? defaultLanguageCode)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard supportedLanguages.contains(where: { $0.code == code }) else {
            return defaultLanguageCode
        }
        return code
    }

    static func language(for raw: String?) -> AppLanguage {
        let code = normalizedLanguageCode(raw)
        return supportedLanguages.first(where: { $0.code == code }) ?? supportedLanguages[0]
    }

    static func t(_ key: String, languageCode: String? = nil) -> String {
        let code = normalizedLanguageCode(languageCode ?? UserDefaults.standard.string(forKey: appLanguageKey))
        let localized = localizedString(key, languageCode: code)
        let resolved = localized == key ? localizedString(key, languageCode: defaultLanguageCode) : localized
        let value = resolved == key ? key : resolved
#if DEBUG
        print("[LocalizationDebug] localizedKeyUsed=\(key)")
#endif
        return value
    }

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
        .onAppear {
#if DEBUG
            print("[LocalizationDebug] languageSettingVisible=true")
            print("[LocalizationDebug] selectedLanguage=\(selectedLanguage.code)")
#endif
        }
    }
}
