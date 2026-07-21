import Foundation
import Security

/// Reads the code-signing identity of an executable on disk.
public enum CodeSignInspector {
    /// Returns nil when the path doesn't exist or can't be evaluated at all.
    public static func inspect(path: String) -> SignatureInfo? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(filePath: path) as CFURL

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let code = staticCode
        else { return nil }

        // Identity check only: skipping content validation matters because a
        // full static validate hashes every byte of the target — tens of
        // seconds for big app bundles, and we run this for dozens of items.
        // What we report is therefore the signing identity, not content
        // integrity (that's Gatekeeper's job).
        let identityOnly = SecCSFlags(
            rawValue: SecCSFlags.RawValue(kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
        )
        let validity = SecStaticCodeCheckValidity(code, identityOnly, nil)
        if validity == errSecCSUnsigned {
            return SignatureInfo(kind: .unsigned)
        }

        var infoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF
        )
        guard infoStatus == errSecSuccess, let info = infoCF as? [String: Any] else {
            return SignatureInfo(kind: validity == errSecSuccess ? .adhoc : .invalid)
        }

        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let leafSummary = certificates?.first
            .flatMap { SecCertificateCopySubjectSummary($0) as String? }

        if validity != errSecSuccess {
            return SignatureInfo(kind: .invalid, developerName: developerName(from: leafSummary), teamID: teamID)
        }

        guard let leafSummary else {
            // Valid signature with no certificate chain = ad-hoc.
            return SignatureInfo(kind: .adhoc, teamID: teamID)
        }

        // The leaf subject is attacker-controlled in a self-signed
        // certificate — a subject that says "Software Signing" proves
        // nothing. Trust classification requires the chain to anchor at
        // Apple's root; requirement checks validate the chain without
        // re-hashing content, so the identity-only performance holds.
        if satisfies(code, requirement: "anchor apple", flags: identityOnly) {
            return SignatureInfo(kind: .apple, developerName: "Apple", teamID: teamID)
        }
        if satisfies(code, requirement: "anchor apple generic", flags: identityOnly) {
            if leafSummary.contains("Apple Mac OS Application Signing") {
                return SignatureInfo(kind: .appStore, developerName: developerName(from: leafSummary), teamID: teamID)
            }
            return SignatureInfo(kind: .developerID, developerName: developerName(from: leafSummary), teamID: teamID)
        }
        // Signed with certificates but no Apple anchor: self-signed or a
        // foreign CA. Untrusted, whatever its subject claims to be.
        return SignatureInfo(kind: .untrusted, developerName: developerName(from: leafSummary), teamID: teamID)
    }

    private static func satisfies(_ code: SecStaticCode, requirement text: String, flags: SecCSFlags) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// "Developer ID Application: Docker Inc (9BNSXJN65R)" -> "Docker Inc"
    static func developerName(from summary: String?) -> String? {
        guard var name = summary else { return nil }
        for prefix in ["Developer ID Application: ", "Apple Development: ", "Apple Distribution: ", "3rd Party Mac Developer Application: "] {
            if name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
                break
            }
        }
        // Strip a trailing "(TEAMID)".
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            let candidate = String(name[..<open]).trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty { name = candidate }
        }
        return name.isEmpty ? nil : name
    }
}
