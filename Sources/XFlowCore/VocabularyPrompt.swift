public enum VocabularyPrompt {
    /// Seeded from the terms that were provably mangled without it: RBAC came
    /// back as "आरबैक", SOX as "शॉक्स", and "risk owner" as "response और".
    /// Users should edit this to match their own jargon — it is the highest
    /// leverage accuracy knob in the app.
    public static let `default` = """
    RBAC, SOX, RACM, risk owner, auditor, engagement, control, internal audit, \
    super admin, screen, scope, dashboard, workflow, compliance
    """
}
