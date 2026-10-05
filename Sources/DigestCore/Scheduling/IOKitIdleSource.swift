import CoreGraphics
import Foundation
import IOKit

/// Real idle signals. Not unit-tested (needs a console session); the policy is tested with a fake.
/// If IOKit can't be read, idle time is reported as 0, i.e. "user present": a missed night is cheaper
/// than a run that competes with the user.
public struct IOKitIdleSource: IdleSource {
    public init() {}

    public func idleSeconds() async -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return 0 }
        return value.doubleValue / 1_000_000_000   // nanoseconds
    }

    public func displayAsleep() async -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }
}
