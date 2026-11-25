import Foundation

@main
struct GuestRAMBudgetTests {
    static func main() {
        let m1 = GuestRAMBudget(physicalMemoryBytes: 7644 << 20, jitCacheMB: 1024)
        precondition(m1.physicalRAMMB == 7644)
        precondition(m1.allPhysicalRAMMB == 7644, "Use detected RAM, not the marketed 8 GB.")
        precondition(m1.estimatedJITFootprintMB == 1792)
        precondition(m1.notice(for: 7644)?.isHighRisk == true)
        precondition(m1.notice(for: 8192)?.isHighRisk == true)
        precondition(m1.notice(for: 16384)?.isHighRisk == true)
        precondition(GuestRAMBudget.isValidPortableRAMMB(16384), "Warnings must not prohibit high allocations.")
        precondition(GuestRAMBudget.isValidPortableRAMMB(7644), "Do not round a full-RAM configuration down.")

        for value in [-1024, 0, 1023, 16385, Int.max, Int.min] {
            precondition(!GuestRAMBudget.isValidPortableRAMMB(value))
            precondition(m1.notice(for: value)?.isHighRisk == true)
        }
        for value in [1024, 1536, 4096, 7644, 16384] {
            precondition(GuestRAMBudget.isValidPortableRAMMB(value))
        }

        let large = GuestRAMBudget(physicalMemoryBytes: 32768 << 20, jitCacheMB: 1536)
        precondition(large.allPhysicalRAMMB == 16384, "Keep the app's supported configuration range.")
        precondition(large.notice(for: 4096) == nil)
        precondition(large.notice(for: 1024)?.isHighRisk == false)
        let smallerCache = GuestRAMBudget(physicalMemoryBytes: 7644 << 20, jitCacheMB: 512)
        precondition(smallerCache.allPhysicalRAMMB == m1.allPhysicalRAMMB, "JIT changes advice, never the requested RAM.")
        precondition(GuestRAMBudget.text(7644) == "7.46 GB")
        precondition(GuestRAMBudget.text(3584) == "3.5 GB")
        precondition(GuestRAMBudget.text(4096) == "4 GB")
        precondition(GuestRAMBudget.text(512) == "512 MB")
        print("Guest RAM advice and full-allocation tests passed")
    }
}
