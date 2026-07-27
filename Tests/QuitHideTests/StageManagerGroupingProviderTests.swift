import ApplicationServices
import Testing
@testable import QuitHide

@Suite("Stage Manager accessibility attribute policy")
struct StageManagerGroupingProviderTests {
    @Test("Normal missing optional attributes remain non-fatal")
    func normalMissingOptionalAttributes() {
        #expect(StageManagerAXAttributeReadPolicy.shouldTreatAsMissing(
            attributeName: kAXRoleAttribute as CFString,
            error: .attributeUnsupported,
            required: false
        ))
        #expect(StageManagerAXAttributeReadPolicy.shouldTreatAsMissing(
            attributeName: kAXRoleAttribute as CFString,
            error: .noValue,
            required: false
        ))
    }

    @Test("WindowManager's missing optional identifier is non-fatal")
    func windowManagerIdentifierCompatibility() {
        #expect(StageManagerAXAttributeReadPolicy.shouldTreatAsMissing(
            attributeName: kAXIdentifierAttribute as CFString,
            error: .illegalArgument,
            required: false
        ))
    }

    @Test("Illegal argument remains fatal outside the observed compatibility case")
    func illegalArgumentIsStillStrict() {
        #expect(!StageManagerAXAttributeReadPolicy.shouldTreatAsMissing(
            attributeName: kAXIdentifierAttribute as CFString,
            error: .illegalArgument,
            required: true
        ))
        #expect(!StageManagerAXAttributeReadPolicy.shouldTreatAsMissing(
            attributeName: kAXRoleAttribute as CFString,
            error: .illegalArgument,
            required: false
        ))
        #expect(!StageManagerAXAttributeReadPolicy.shouldTreatAsMissing(
            attributeName: kAXIdentifierAttribute as CFString,
            error: .cannotComplete,
            required: false
        ))
    }
}
