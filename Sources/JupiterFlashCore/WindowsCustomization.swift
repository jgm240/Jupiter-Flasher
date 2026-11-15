// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Mac region settings that can be carried over to the Windows install.
public struct RegionSettings: Sendable, Equatable {
    public var locale: String?     // Windows locale tag, e.g. "de-DE"
    public var timeZone: String?   // Windows time zone name, e.g. "W. Europe Standard Time"

    /// Windows locales we're confident exist; anything else is skipped rather than risk a bad answer file.
    static let knownLocales: Set<String> = [
        "en-US", "en-GB", "en-AU", "en-CA", "en-IE", "en-NZ", "en-IN", "en-ZA", "en-SG",
        "de-DE", "de-AT", "de-CH", "fr-FR", "fr-CA", "fr-BE", "fr-CH", "es-ES", "es-MX", "es-AR", "es-CO", "es-CL",
        "it-IT", "it-CH", "pt-BR", "pt-PT", "nl-NL", "nl-BE", "sv-SE", "nb-NO", "da-DK", "fi-FI", "is-IS",
        "pl-PL", "cs-CZ", "sk-SK", "hu-HU", "ro-RO", "bg-BG", "el-GR", "tr-TR", "ru-RU", "uk-UA", "hr-HR", "sl-SI",
        "lt-LT", "lv-LV", "et-EE", "ja-JP", "ko-KR", "zh-CN", "zh-TW", "zh-HK", "he-IL", "ar-SA", "ar-AE", "ar-EG",
        "hi-IN", "th-TH", "vi-VN", "id-ID", "ms-MY",
    ]

    /// IANA identifier → Windows time zone name (only zones whose Windows name is certain).
    static let windowsZones: [String: String] = [
        "UTC": "UTC", "GMT": "UTC", "Etc/UTC": "UTC",
        "America/New_York": "Eastern Standard Time", "America/Toronto": "Eastern Standard Time", "America/Detroit": "Eastern Standard Time",
        "America/Chicago": "Central Standard Time", "America/Denver": "Mountain Standard Time",
        "America/Los_Angeles": "Pacific Standard Time", "America/Vancouver": "Pacific Standard Time",
        "America/Anchorage": "Alaskan Standard Time", "Pacific/Honolulu": "Hawaiian Standard Time",
        "America/Sao_Paulo": "E. South America Standard Time", "America/Argentina/Buenos_Aires": "Argentina Standard Time",
        "Europe/London": "GMT Standard Time", "Europe/Dublin": "GMT Standard Time", "Europe/Lisbon": "GMT Standard Time",
        "Europe/Berlin": "W. Europe Standard Time", "Europe/Vienna": "W. Europe Standard Time", "Europe/Zurich": "W. Europe Standard Time",
        "Europe/Amsterdam": "W. Europe Standard Time", "Europe/Rome": "W. Europe Standard Time", "Europe/Stockholm": "W. Europe Standard Time",
        "Europe/Oslo": "W. Europe Standard Time", "Europe/Luxembourg": "W. Europe Standard Time",
        "Europe/Paris": "Romance Standard Time", "Europe/Madrid": "Romance Standard Time",
        "Europe/Brussels": "Romance Standard Time", "Europe/Copenhagen": "Romance Standard Time",
        "Europe/Prague": "Central Europe Standard Time", "Europe/Budapest": "Central Europe Standard Time",
        "Europe/Warsaw": "Central European Standard Time", "Europe/Zagreb": "Central European Standard Time",
        "Europe/Helsinki": "FLE Standard Time", "Europe/Kyiv": "FLE Standard Time", "Europe/Kiev": "FLE Standard Time",
        "Europe/Riga": "FLE Standard Time", "Europe/Tallinn": "FLE Standard Time", "Europe/Vilnius": "FLE Standard Time",
        "Europe/Sofia": "FLE Standard Time", "Europe/Athens": "GTB Standard Time", "Europe/Bucharest": "GTB Standard Time",
        "Europe/Moscow": "Russian Standard Time", "Europe/Istanbul": "Turkey Standard Time",
        "Asia/Tokyo": "Tokyo Standard Time", "Asia/Seoul": "Korea Standard Time", "Asia/Shanghai": "China Standard Time",
        "Asia/Hong_Kong": "China Standard Time", "Asia/Kolkata": "India Standard Time", "Asia/Calcutta": "India Standard Time",
        "Asia/Singapore": "Singapore Standard Time", "Asia/Dubai": "Arabian Standard Time", "Asia/Jerusalem": "Israel Standard Time",
        "Africa/Cairo": "Egypt Standard Time", "Africa/Johannesburg": "South Africa Standard Time",
        "Australia/Sydney": "AUS Eastern Standard Time", "Australia/Melbourne": "AUS Eastern Standard Time",
        "Pacific/Auckland": "New Zealand Standard Time",
    ]

    /// Settings of this Mac. Fields are nil when they can't be mapped with confidence.
    public static var current: RegionSettings {
        var tag: String?
        if let lang = Locale.current.language.languageCode?.identifier, let region = Locale.current.region?.identifier {
            let t = "\(lang)-\(region)"
            if knownLocales.contains(t) { tag = t }
        }
        return RegionSettings(locale: tag, timeZone: windowsZones[TimeZone.current.identifier])
    }
}

/// Options applied through an `autounattend.xml` at the root of the install media.
public struct WindowsCustomization: Sendable, Equatable, Codable {
    public var bypassHardwareChecks = false   // Windows 11: TPM, Secure Boot, RAM, CPU, storage checks
    public var skipOnlineAccount = false      // no Microsoft-account / network requirement
    public var localAccountName = ""          // created (blank password) when skipOnlineAccount is on
    public var skipPrivacyQuestions = false
    public var disableBitLocker = false       // no automatic device encryption
    public var useMacRegion = false
    public init() {}

    public var isEmpty: Bool {
        !(bypassHardwareChecks || skipOnlineAccount || skipPrivacyQuestions || disableBitLocker || useMacRegion)
    }

    /// Returns a problem description, or nil when the name is acceptable.
    public static func accountNameProblem(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return nil }
        if n.count > 20 { return "User names can be at most 20 characters." }
        if n.rangeOfCharacter(from: CharacterSet(charactersIn: "\"/\\[]:;|=,+*?<>@")) != nil {
            return "The user name can't contain \" / \\ [ ] : ; | = , + * ? < > @"
        }
        if n.allSatisfy({ $0 == "." }) { return "The user name can't consist only of dots." }
        if n.unicodeScalars.contains(where: { $0.value < 32 }) { return "The user name contains invalid characters." }
        return nil
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Builds the answer file. `architecture` is "amd64", "x86" or "arm64".
    public func unattendXML(architecture arch: String, region: RegionSettings = .current) -> String {
        func component(_ name: String, _ body: String) -> String {
            """
                <component name="\(name)" processorArchitecture="\(arch)" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            \(body)
                </component>
            """
        }
        func runSync(_ commands: [String]) -> String {
            var s = "      <RunSynchronous>\n"
            for (i, c) in commands.enumerated() {
                s += "        <RunSynchronousCommand wcm:action=\"add\">\n          <Order>\(i + 1)</Order>\n          <Path>\(Self.esc(c))</Path>\n        </RunSynchronousCommand>\n"
            }
            return s + "      </RunSynchronous>"
        }
        var passes: [String] = []

        // windowsPE: runs inside Setup before the hardware checks.
        if bypassHardwareChecks {
            let keys = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck", "BypassCPUCheck", "BypassStorageCheck"]
            var cmds = keys.map { "reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \($0) /t REG_DWORD /d 1 /f" }
            cmds.append("reg add HKLM\\SYSTEM\\Setup\\MoSetup /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f")
            passes.append("  <settings pass=\"windowsPE\">\n\(component("Microsoft-Windows-Setup", runSync(cmds)))\n  </settings>")
        }

        // specialize
        if disableBitLocker {
            let cmd = "reg add HKLM\\SYSTEM\\CurrentControlSet\\Control\\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f"
            passes.append("  <settings pass=\"specialize\">\n\(component("Microsoft-Windows-Deployment", runSync([cmd])))\n  </settings>")
        }

        // oobeSystem
        var comps: [String] = []
        var shell = ""
        var oobe = ""
        if skipOnlineAccount {
            oobe += "        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>\n        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>\n"
        }
        if skipPrivacyQuestions { oobe += "        <ProtectYourPC>3</ProtectYourPC>\n" }
        if !oobe.isEmpty { shell += "      <OOBE>\n\(oobe)      </OOBE>\n" }
        let name = localAccountName.trimmingCharacters(in: .whitespaces)
        if skipOnlineAccount, !name.isEmpty, Self.accountNameProblem(name) == nil {
            shell += """
                  <UserAccounts>
                    <LocalAccounts>
                      <LocalAccount wcm:action="add">
                        <Name>\(Self.esc(name))</Name>
                        <DisplayName>\(Self.esc(name))</DisplayName>
                        <Group>Administrators</Group>
                        <Password>
                          <Value></Value>
                          <PlainText>true</PlainText>
                        </Password>
                      </LocalAccount>
                    </LocalAccounts>
                  </UserAccounts>

            """
        }
        if useMacRegion, let tz = region.timeZone { shell += "      <TimeZone>\(Self.esc(tz))</TimeZone>\n" }
        if !shell.isEmpty { comps.append(component("Microsoft-Windows-Shell-Setup", String(shell.dropLast()))) }
        if useMacRegion, let loc = region.locale {
            let l = Self.esc(loc)
            comps.append(component("Microsoft-Windows-International-Core",
                "      <InputLocale>\(l)</InputLocale>\n      <SystemLocale>\(l)</SystemLocale>\n      <UserLocale>\(l)</UserLocale>"))
        }
        if !comps.isEmpty { passes.append("  <settings pass=\"oobeSystem\">\n\(comps.joined(separator: "\n"))\n  </settings>") }

        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<unattend xmlns=\"urn:schemas-microsoft-com:unattend\">\n\(passes.joined(separator: "\n"))\n</unattend>\n"
    }
}
