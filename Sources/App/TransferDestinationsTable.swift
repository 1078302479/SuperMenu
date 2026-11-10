import AppKit
import SwiftUI

/// The reference page uses a selectable, editable table, not a folder-authorization checklist.
struct TransferDestinationsTable: NSViewRepresentable {
    @ObservedObject var model: SettingsModel
    var isFavorites = false

    private var folders: WritableKeyPath<Settings, SavedFolders?> {
        isFavorites ? \.favorites : \.copyDestinations
    }
    private var selection: ReferenceWritableKeyPath<SettingsModel, Int?> {
        isFavorites ? \.selectedFavoriteID : \.selectedTransferID
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, folders: folders, selection: selection) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TransferListScrollView()
        scroll.borderType = .lineBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .controlBackgroundColor
        table.style = .plain
        table.rowHeight = 35
        table.intercellSpacing = NSSize(width: 10, height: 0)
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (id, title, width) in [("icon", "图标", 45.0), ("path", "真实路径", 330.0), ("name", "显示名称（双击编辑 / 按住拖拽）", 260.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "icon" ? 45 : (id == "path" ? 150 : 180)
            column.resizingMask = id == "icon" ? [] : [.autoresizingMask, .userResizingMask]
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.editName(_:))
        table.registerForDraggedTypes([Coordinator.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.synchronizing = true
        defer { coordinator.synchronizing = false }
        let next = model.settings[keyPath: folders]?.entries ?? []
        if coordinator.entries != next {
            coordinator.entries = next
            coordinator.table?.reloadData()
        }
        if let id = model[keyPath: selection], let row = next.firstIndex(where: { $0.id == id }) {
            if coordinator.table?.selectedRow != row { coordinator.table?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        } else { coordinator.table?.deselectAll(nil) }
        scroll.tile()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let dragType = NSPasteboard.PasteboardType("io.github.1078302479.SuperMenu.transfer-row")
        var model: SettingsModel
        var entries: [SavedFolder] = []
        weak var table: NSTableView?
        var synchronizing = false
        let folders: WritableKeyPath<Settings, SavedFolders?>
        let selection: ReferenceWritableKeyPath<SettingsModel, Int?>

        init(model: SettingsModel, folders: WritableKeyPath<Settings, SavedFolders?>,
             selection: ReferenceWritableKeyPath<SettingsModel, Int?>) {
            self.model = model
            self.folders = folders
            self.selection = selection
        }

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard entries.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
            let entry = entries[row]
            if id == "icon" {
                let view = NSImageView()
                view.image = MenuIcons.folder(at: URL(fileURLWithPath: entry.path))
                view.imageScaling = .scaleProportionallyDown
                return view
            }
            let field: NSTextField
            if id == "name" {
                let editor = MenuNameField()
                editor.stringValue = entry.name
                editor.isEnabled = model.storageAvailable
                editor.saveName = { [weak self] name in
                    guard let self else { return }
                    self.model.setSystemPreference { $0[keyPath: self.folders]?.rename(id: entry.id, to: name) }
                }
                field = editor
            } else {
                field = NSTextField(labelWithString: (entry.path as NSString).abbreviatingWithTildeInPath)
            }
            field.font = .systemFont(ofSize: 13)
            field.lineBreakMode = .byTruncatingMiddle
            field.isEditable = false
            field.isSelectable = false
            let cell = NSTableCellView()
            cell.identifier = NSUserInterfaceItemIdentifier(id)
            cell.textField = field
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        @objc func editName(_ sender: NSTableView) {
            guard sender.clickedColumn == 2, entries.indices.contains(sender.clickedRow),
                  let cell = sender.view(atColumn: 2, row: sender.clickedRow, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField as? MenuNameField else { return }
            field.beginEditing()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !synchronizing, let table else { return }
            model[keyPath: selection] = entries.indices.contains(table.selectedRow) ? entries[table.selectedRow].id : nil
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard entries.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(String(entries[row].id), forType: Self.dragType)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard let source = info.draggingSource as? NSTableView, source === tableView else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let source = info.draggingSource as? NSTableView, source === tableView,
                  let value = info.draggingPasteboard.string(forType: Self.dragType), let id = Int(value),
                  entries.contains(where: { $0.id == id }) else { return false }
            model.setSystemPreference { $0[keyPath: folders]?.move(id: id, to: row) }
            model[keyPath: selection] = id
            return true
        }
    }
}

private final class TransferListScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let table = documentView as? NSTableView, table.tableColumns.count == 3 else { return }
        let available = max(330, contentSize.width - 75)
        let nameWidth = max(180, available * 0.35)
        let pathWidth = max(150, available - nameWidth)
        if abs(table.tableColumns[1].width - pathWidth) > 0.5 { table.tableColumns[1].width = pathWidth }
        if abs(table.tableColumns[2].width - nameWidth) > 0.5 { table.tableColumns[2].width = nameWidth }
    }
}
