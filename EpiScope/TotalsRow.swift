import AppKit

// The totals strip under the session table: one figure per column that has one,
// aligned to the column it belongs to.
//
// It is a sibling of the scroll view, not a row in the table: a row would sort,
// scroll away and be selectable, and the number a table is read for should not
// be any of those. Column geometry is asked of the table on every draw and
// converted through the view hierarchy, so a resized, reordered, hidden or
// horizontally scrolled column carries its total with it.
@MainActor
final class TotalsRowView: NSView {
    weak var table: NSOutlineView?

    // Values are handed over already formatted: the table's own cells format
    // theirs with the same helpers, and a second implementation here would
    // drift from them.
    private var values: [NSUserInterfaceItemIdentifier: String] = [:]
    private var alignments: [NSUserInterfaceItemIdentifier: NSTextAlignment] = [:]

    static let height: CGFloat = 26

    func setValues(_ values: [NSUserInterfaceItemIdentifier: String],
                   alignments: [NSUserInterfaceItemIdentifier: NSTextAlignment]) {
        self.values = values
        self.alignments = alignments
        needsDisplay = true
    }

    // The strip follows the table's horizontal scroll, so it has to repaint on
    // it — and on anything that moves a column.
    func observe(scrollView: NSScrollView) {
        scrollView.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        for name in [NSView.boundsDidChangeNotification] {
            center.addObserver(self, selector: #selector(geometryChanged),
                               name: name, object: scrollView.contentView)
        }
        for name in [NSTableView.columnDidResizeNotification,
                     NSTableView.columnDidMoveNotification] {
            center.addObserver(self, selector: #selector(geometryChanged),
                               name: name, object: table)
        }
    }

    @objc private func geometryChanged() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()

        guard let table else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                   weight: .semibold)
        for (index, column) in table.tableColumns.enumerated() where !column.isHidden {
            guard let text = values[column.identifier], !text.isEmpty else { continue }
            var rect = convert(table.rect(ofColumn: index), from: table)
            // Only the horizontal span is the column's; vertically the rect
            // still describes the table, which sits above this strip — asking
            // whether it intersects `bounds` was asking whether the table
            // overlaps the totals, and the answer is always no.
            guard rect.maxX > 0, rect.minX < bounds.width else { continue }
            rect.origin.y = 0
            rect.size.height = bounds.height
            // The same 4 pt a table cell keeps off the column edge, so a total
            // lines up with the figures above it.
            rect = rect.insetBy(dx: 4, dy: 0)

            let style = NSMutableParagraphStyle()
            style.alignment = alignments[column.identifier] ?? .left
            style.lineBreakMode = .byTruncatingTail
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ])
            let size = attributed.size()
            let y = (bounds.height - size.height) / 2
            attributed.draw(in: NSRect(x: rect.minX, y: y,
                                       width: rect.width, height: size.height))
        }
    }
}
