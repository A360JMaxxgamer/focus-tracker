import AppKit

/// A connected display. `bounds` is in global CoreGraphics coordinates (origin top-left of the main display).
struct DisplayInfo: Equatable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let bounds: CGRect

    /// Converts a point relative to this display (0...1 on both axes, top-left origin) to global CG coordinates.
    func globalPoint(relative p: CGPoint) -> CGPoint {
        CGPoint(x: bounds.minX + p.x * bounds.width, y: bounds.minY + p.y * bounds.height)
    }

    func relativePoint(global p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - bounds.minX) / bounds.width, y: (p.y - bounds.minY) / bounds.height)
    }

    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
}

enum Displays {
    static func all() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            return DisplayInfo(id: id, uuid: uuid(of: id), name: screen.localizedName, bounds: CGDisplayBounds(id))
        }
    }

    static func uuid(of id: CGDirectDisplayID) -> String {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, cfUUID) else { return "display-\(id)" }
        return string as String
    }

    static func display(containing p: CGPoint) -> DisplayInfo? {
        all().first { $0.bounds.contains(p) }
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    private static var mainHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    /// CG (top-left origin) -> AppKit (bottom-left origin).
    static func toAppKit(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: mainHeight - p.y) }

    /// AppKit (bottom-left origin) -> CG (top-left origin).
    static func toCG(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: mainHeight - p.y) }

    /// Which edges of `display` touch another display, as relative sides.
    static func sharedEdges(of display: DisplayInfo, among displays: [DisplayInfo]) -> Set<Edge> {
        var edges = Set<Edge>()
        let b = display.bounds
        for other in displays where other.id != display.id {
            let o = other.bounds
            let verticalOverlap = min(b.maxY, o.maxY) - max(b.minY, o.minY) > 40
            let horizontalOverlap = min(b.maxX, o.maxX) - max(b.minX, o.minX) > 40
            if verticalOverlap && abs(b.maxX - o.minX) < 2 { edges.insert(.right) }
            if verticalOverlap && abs(b.minX - o.maxX) < 2 { edges.insert(.left) }
            if horizontalOverlap && abs(b.maxY - o.minY) < 2 { edges.insert(.bottom) }
            if horizontalOverlap && abs(b.minY - o.maxY) < 2 { edges.insert(.top) }
        }
        return edges
    }

    enum Edge: Hashable { case left, right, top, bottom }
}
