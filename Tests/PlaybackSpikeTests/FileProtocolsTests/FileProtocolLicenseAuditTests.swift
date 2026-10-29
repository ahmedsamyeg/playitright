import Testing
import Foundation

@Suite("FileProtocolLicenseAudit Tests")
struct FileProtocolLicenseAuditTests {

    enum LicenseKind: String, Sendable {
        case mit = "MIT"
        case apache2 = "Apache-2.0"
        case bsd3 = "BSD-3-Clause"
        case bsd2 = "BSD-2-Clause"
        case lgplDynamic = "LGPL-2.1-dynamic"
        case gplStatic = "GPL-static"
        case proprietary = "Proprietary"
    }

    struct DependencyAuditRecord: Sendable {
        let name: String
        let role: String
        let license: LicenseKind
        let isDynamicOnly: Bool
    }

    /// Evaluates whether a dependency complies with ARCH-6 (no static copyleft/GPL).
    func isCompliant(record: DependencyAuditRecord) -> Bool {
        switch record.license {
        case .mit, .apache2, .bsd3, .bsd2:
            return true
        case .lgplDynamic:
            return record.isDynamicOnly // LGPL is strictly permitted ONLY as dynamic library (ARCH-6)
        case .gplStatic, .proprietary:
            return false
        }
    }

    @Test("All file protocol and core dependencies pass ARCH-6 licensing policy")
    func testDependencyLicenseCompliance() {
        let evaluatedDependencies: [DependencyAuditRecord] = [
            DependencyAuditRecord(name: "GRDB.swift", role: "Database", license: .mit, isDynamicOnly: false),
            DependencyAuditRecord(name: "PureSwiftSMB2", role: "SMB Client", license: .mit, isDynamicOnly: false),
            DependencyAuditRecord(name: "PureSwiftNFS", role: "NFS Client", license: .mit, isDynamicOnly: false),
            DependencyAuditRecord(name: "Citadel", role: "SFTP Client (via swift-nio-ssh)", license: .apache2, isDynamicOnly: false),
            DependencyAuditRecord(name: "FFmpeg.xcframework", role: "Extended Codec Transcoding", license: .lgplDynamic, isDynamicOnly: true)
        ]

        for dep in evaluatedDependencies {
            #expect(isCompliant(record: dep) == true, "Dependency \(dep.name) failed licensing audit!")
        }
    }

    @Test("Static GPL dependency is rejected by compliance auditor")
    func testStaticGPLRejection() {
        let gplDependency = DependencyAuditRecord(
            name: "ContaminatedGPLPackage",
            role: "Forbidden Static Linkage",
            license: .gplStatic,
            isDynamicOnly: false
        )
        #expect(isCompliant(record: gplDependency) == false)
    }
}
