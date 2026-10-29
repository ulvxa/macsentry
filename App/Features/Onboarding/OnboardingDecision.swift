enum OnboardingDecision {
    static func shouldPresent(hasFullDiskAccess: Bool, limitedMode: Bool) -> Bool {
        !hasFullDiskAccess && !limitedMode
    }
}
