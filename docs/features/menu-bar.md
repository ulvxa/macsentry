# Menu Bar and Disk Pressure

Small always available panel showing disk health. Not a scheduler: it never starts scans on its own.

## Behavior
- `MenuBarExtra` with `.menuBarExtraStyle(.window)`, toggle in Settings > General (default on)
- Menu bar label: SF Symbol `internaldrive` plus free space in compact form (`212 GB`). Option to show icon only
- App keeps running when the main window closes: `NSApplicationDelegate.applicationShouldTerminateAfterLastWindowClosed` returns false while the menu bar extra is enabled
- Launch at login: `SMAppService.mainApp.register()` / `unregister()`, toggle in Settings > General

## Panel Content (width 320)
- Free space big number and percentage, glass card
- Sparkline of free space for the last 30 days (`Swift Charts` `LineMark`, monochrome, no axes, min and max labels)
- Rows: Reclaimable from last scan, In quarantine, In Trash
- Buttons: Scan Now (glassProminent, opens main window on finish), Open MacSentry, Open Quarantine
- Warning row when below threshold: `exclamationmark.triangle` plus "Low disk space"

## Sampling
- `DiskMonitor` actor samples every 15 minutes while the app runs, and on wake from sleep (`NSWorkspace.didWakeNotification`)
- Uses `URLResourceValues` on `/`: `volumeTotalCapacity`, `volumeAvailableCapacity`, `volumeAvailableCapacityForImportantUsage`
- Stores `disk_sample` rows, sparkline aggregates to one point per 6 hours

## Low Space Notification
- Threshold in Settings: absolute GB (default 30 GB) based on `important_free`
- Fires a `UNUserNotification` once when crossing below the threshold. Re arms only after free space goes back above threshold plus 5 GB hysteresis
- Notification action "Review" opens the Overview
- Permission requested the first time the user enables notifications in Settings, not on first launch

## API

```swift
public actor DiskMonitor {
    public func start(interval: Duration) async
    public func stop()
    public func currentSample() throws -> DiskSample
    public func history(days: Int) async throws -> [DiskSample]
    public var events: AsyncStream<DiskEvent> { get }   // .sample(DiskSample), .crossedBelowThreshold, .recovered
}
```

## Edge Cases
- Notifications denied: Settings shows the state and a button to open Notification settings, no repeated prompts
- Clock changes or sleep for days: sparkline just has gaps, no interpolation
- `important_free` can exceed `available` (purgeable space): show `important_free` as the headline, tooltip explains purgeable space
- Menu bar extra disabled while main window closed: app quits normally
