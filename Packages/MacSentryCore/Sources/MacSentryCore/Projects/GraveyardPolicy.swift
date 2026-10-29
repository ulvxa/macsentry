import Foundation

public enum GraveyardPolicy {
    public static let defaultIdleDays = 90
    public static let ideRecentWindow: TimeInterval = 24 * 60 * 60
    public static let ideBundleIDs = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.google.android.studio",
        "com.unity3d.UnityEditor5.x",
    ]

    public static func lastActivity(of project: Project) -> Date {
        max(project.lastCommitAt ?? project.lastModifiedAt, project.lastModifiedAt)
    }

    public static func age(of project: Project, now: Date) -> TimeInterval {
        now.timeIntervalSince(lastActivity(of: project))
    }

    public static func isIdle(_ project: Project, idleDays: Int = defaultIdleDays, now: Date) -> Bool {
        age(of: project, now: now) >= TimeInterval(idleDays) * 24 * 60 * 60
    }

    public static func idle(_ projects: [GraveyardProject], idleDays: Int = defaultIdleDays, now: Date) -> [GraveyardProject] {
        projects.filter { isIdle($0.project, idleDays: idleDays, now: now) }
    }

    public static func isBlockedByIDE(project: Project, inventory: any AppInventory, now: Date) -> Bool {
        guard age(of: project, now: now) < ideRecentWindow else { return false }
        return ideBundleIDs.contains { inventory.isRunning(bundleID: $0) }
    }

    public static func isPreselected(_ artifact: Candidate, in project: GraveyardProject) -> Bool {
        project.uncommitted == .clean && artifact.tier == .green && artifact.action == .quarantine
    }

    public static func defaultSelection(for project: GraveyardProject) -> [Candidate] {
        project.artifacts.filter { isPreselected($0, in: project) }
    }
}
