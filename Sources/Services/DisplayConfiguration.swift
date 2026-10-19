import ApplicationServices
import CoreGraphics
import Foundation

/// Describes the currently connected displays and derives a stable signature from them.
struct DisplayConfiguration: Equatable {
    struct Display: Equatable {
        var uuid: String
        var bounds: CGRect
        var pixelWidth: Int
        var pixelHeight: Int
        var isBuiltin: Bool
    }

    var displays: [Display]

    /// Reads the active displays from CoreGraphics.
    static func current() -> DisplayConfiguration {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return DisplayConfiguration(displays: []) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return DisplayConfiguration(displays: []) }

        let displays = ids.prefix(Int(count)).map { id -> Display in
            // The UUID survives port changes, unlike the CGDirectDisplayID.
            var uuidString = "id-\(id)"
            if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
               let str = CFUUIDCreateString(nil, uuid) as String? {
                uuidString = str
            }
            let mode = CGDisplayCopyDisplayMode(id)
            return Display(uuid: uuidString,
                           bounds: CGDisplayBounds(id),
                           pixelWidth: mode?.pixelWidth ?? Int(CGDisplayPixelsWide(id)),
                           pixelHeight: mode?.pixelHeight ?? Int(CGDisplayPixelsHigh(id)),
                           isBuiltin: CGDisplayIsBuiltin(id) != 0)
        }
        return DisplayConfiguration(displays: displays.sorted { $0.uuid < $1.uuid })
    }

    /// Identity of this arrangement: UUID, pixel size and global origin of every display.
    var signature: String {
        displays.map { "\($0.uuid):\($0.pixelWidth)x\($0.pixelHeight)@\(Int($0.bounds.minX)),\(Int($0.bounds.minY))" }
            .joined(separator: "|")
    }

    /// Human-friendly label such as "Laptop + 1 external".
    var name: String {
        let externals = displays.filter { !$0.isBuiltin }.count
        let hasLaptop = displays.contains { $0.isBuiltin }
        switch (hasLaptop, externals) {
        case (_, _) where displays.isEmpty: return "No displays"
        case (true, 0): return "Laptop only"
        case (true, let n): return "Laptop + \(n) external"
        case (false, 1): return "1 external display"
        case (false, let n): return "\(n) external displays"
        }
    }

    var detail: String {
        displays.map { "\($0.pixelWidth)×\($0.pixelHeight)" }.joined(separator: " + ")
    }

    /// Keeps a frame reachable: frames touching any display are kept, others are moved into the nearest display.
    func clamp(_ frame: CGRect) -> CGRect {
        let screens = displays.map(\.bounds)
        guard !screens.isEmpty, !screens.contains(where: { $0.intersects(frame) }) else { return frame }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let nearest = screens.min { distance(center, $0) < distance(center, $1) } ?? screens[0]
        let width = min(frame.width, nearest.width)
        let height = min(frame.height, nearest.height)
        let x = min(max(frame.minX, nearest.minX), nearest.maxX - width)
        let y = min(max(frame.minY, nearest.minY), nearest.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
