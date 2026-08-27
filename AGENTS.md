# Project Instructions

## SwiftUI Experience

- Follow current SwiftUI best practices and Apple's Human Interface Guidelines for every UI change.
- Prefer native SwiftUI navigation, presentation, controls, state flow, accessibility, and platform behavior.
- Make the app feel like a first-party Apple app: interactions must be predictable, responsive, stable, and visually consistent with iOS.
- Keep navigation and presentation state explicit, typed, and owned by the appropriate parent. Avoid competing sources of truth and unintended nested navigation stacks.
- Use the system control that matches the interaction. Do not imitate standard iOS behavior with custom gestures or styling when SwiftUI already provides the correct semantic control.
- Do not use delays, lifecycle timing tricks, UIKit bridging, or visual patches to conceal an architectural issue. When UIKit is genuinely required, isolate it and document why SwiftUI is insufficient.
- Preserve system back, dismissal, focus, scrolling, Dynamic Type, VoiceOver, compact and regular size classes, light and dark appearance, and safe-area behavior.
- Before considering a UI change complete, exercise its full interaction cycle: present, interact, select, cancel, tap outside, dismiss, navigate forward, and navigate back. Check for flicker, stale state, overlapping presentations, layout jumps, and console warnings.
- Build after SwiftUI changes and treat new deprecations, runtime presentation warnings, and navigation inconsistencies as defects to investigate rather than harmless noise.
