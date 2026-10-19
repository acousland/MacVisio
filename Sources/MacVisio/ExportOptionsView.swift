import AppKit
import MacVisioInfrastructure

/// Save-panel drafts are tied to the page identities and revision displayed
/// when the panel opens. Applying them to another revision requires review.
final class ExportOptionsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private struct PageChoice {
        var id: UUID
        var title: String
        var size: String
    }
    private let input: LifecycleJobInput
    private let format: OwnedExportFormat
    private let activePageID: UUID
    private let foregroundIDs: [UUID]
    private let paperSize: CGSize
    private let capturedSelection: RasterExportSelection?
    private var pages: [PageChoice]
    let resolutionField = NSTextField(string: "144")
    let rasterBoundsMode = NSPopUpButton(frame: .zero, pullsDown: false)
    let transparencyButton = NSButton(checkboxWithTitle: "Transparent page background", target: nil, action: nil)
    let jpegQualityPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let sizeLabel = NSTextField(labelWithString: "")
    let pageMode = NSPopUpButton(frame: .zero, pullsDown: false)
    let table = NSTableView()
    let moveUpButton = NSButton(title: "Move Up", target: nil, action: nil)
    let moveDownButton = NSButton(title: "Move Down", target: nil, action: nil)

    init(snapshot: Diagram, format: OwnedExportFormat, allPages: Bool, input: LifecycleJobInput,
         selection: RasterExportSelection? = nil) {
        self.input = input
        self.format = format
        capturedSelection = selection
        activePageID = snapshot.page.id
        foregroundIDs = snapshot.orderedPages.filter { $0.isBackground != true }.map(\.id)
        paperSize = CGSize(width: snapshot.page.paperWidth, height: snapshot.page.paperHeight)
        let ordinals = Dictionary(uniqueKeysWithValues: snapshot.pages.enumerated().map { ($0.element.id, $0.offset + 1) })
        pages = snapshot.orderedPages.map {
            PageChoice(id: $0.id, title: "\(ordinals[$0.id] ?? 0). \($0.name)\($0.isBackground == true ? " (background)" : "")",
                       size: String(format: "%.1f × %.1f mm", $0.paperWidth / 72 * 25.4, $0.paperHeight / 72 * 25.4))
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: format == .pdf ? 290 : (format.isRaster ? 158 : 118)))
        if format.isRaster { makeRasterControls() }
        if format == .pdf {
            makePageControls(allPages: allPages)
            let initial = Set(allPages ? foregroundIDs : [activePageID])
            table.selectRowIndexes(IndexSet(pages.indices.filter { initial.contains(pages[$0].id) }), byExtendingSelection: false)
            updatePageControls()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func options(for currentInput: LifecycleJobInput, activePageID currentPageID: UUID,
                 selection currentSelection: RasterExportSelection? = nil) throws -> OwnedExportOptions {
        guard currentInput == input, currentPageID == activePageID else {
            throw DiagramError.invalid("The drawing or active page changed while export options were open. Reopen Export to review the current pages.")
        }
        var result = OwnedExportOptions()
        switch format {
        case .png, .jpeg, .tiff:
            guard let dpi = Double(resolutionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw DiagramError.invalid("Enter a \(format.displayName) resolution between 36 and 1200 dpi.")
            }
            result.rasterDPI = dpi
            result.transparentBackground = transparencyButton.state == .on
            if format == .jpeg {
                guard JPEGExportQuality.allCases.indices.contains(jpegQualityPicker.indexOfSelectedItem) else {
                    throw DiagramError.invalid("Choose a JPEG quality preset.")
                }
                result.jpegQuality = JPEGExportQuality.allCases[jpegQualityPicker.indexOfSelectedItem]
            }
            try result.validateRasterFormat(format)
            try result.validateRasterDPI()
            guard RasterExportRegion.allCases.indices.contains(rasterBoundsMode.indexOfSelectedItem) else {
                throw DiagramError.invalid("Choose a \(format.displayName) output region.")
            }
            result.rasterRegion = RasterExportRegion.allCases[rasterBoundsMode.indexOfSelectedItem]
            if result.rasterRegion == .page {
                try result.validateRasterDimensions(result.rasterSize(width: paperSize.width, height: paperSize.height), format: format)
            } else if result.rasterRegion == .selection {
                guard let capturedSelection, !capturedSelection.isEmpty else {
                    throw DiagramError.invalid("Select one or more objects before opening Export.")
                }
                guard capturedSelection == currentSelection, capturedSelection.input == currentInput,
                      capturedSelection.pageID == currentPageID else { throw LifecycleJobError.staleInput }
                result.rasterSelection = capturedSelection
            }
        case .pdf:
            switch pageMode.indexOfSelectedItem {
            case 0: result.pdfPageIDs = [activePageID]
            case 1: result.pdfPageIDs = foregroundIDs
            default: result.pdfPageIDs = table.selectedRowIndexes.map { pages[$0].id }
            }
            guard result.pdfPageIDs?.isEmpty == false else { throw DiagramError.invalid("Select at least one page to export.") }
        default: break
        }
        return result
    }

    private func makeRasterControls() {
        let boundsLabel = NSTextField(labelWithString: "\(format.displayName) bounds:")
        boundsLabel.frame = NSRect(x: 0, y: 128, width: 82, height: 20); addSubview(boundsLabel)
        rasterBoundsMode.frame = NSRect(x: 85, y: 121, width: 365, height: 28)
        rasterBoundsMode.addItems(withTitles: ["Page", "Drawing content (including off-page artwork)", "Selection"])
        rasterBoundsMode.menu?.autoenablesItems = false
        rasterBoundsMode.item(at: 2)?.isEnabled = capturedSelection?.isEmpty == false
        rasterBoundsMode.target = self; rasterBoundsMode.action = #selector(rasterBoundsChanged(_:))
        rasterBoundsMode.setAccessibilityLabel("\(format.displayName) output bounds")
        addSubview(rasterBoundsMode)
        let label = NSTextField(labelWithString: "Resolution:")
        label.frame = NSRect(x: 0, y: 88, width: 82, height: 20); addSubview(label)
        resolutionField.frame = NSRect(x: 85, y: 85, width: 80, height: 24)
        resolutionField.delegate = self
        resolutionField.setAccessibilityLabel("\(format.displayName) resolution in dots per inch")
        addSubview(resolutionField)
        let units = NSTextField(labelWithString: "dpi (36–1200)")
        units.frame = NSRect(x: 173, y: 88, width: 180, height: 20); addSubview(units)
        if format == .jpeg {
            let quality = NSTextField(labelWithString: "JPEG quality:")
            quality.frame = NSRect(x: 0, y: 55, width: 100, height: 20); addSubview(quality)
            jpegQualityPicker.frame = NSRect(x: 105, y: 48, width: 345, height: 28)
            jpegQualityPicker.addItems(withTitles: JPEGExportQuality.allCases.map(\.title))
            jpegQualityPicker.selectItem(at: 1)
            jpegQualityPicker.setAccessibilityLabel("JPEG compression quality")
            addSubview(jpegQualityPicker)
        } else {
            transparencyButton.frame = NSRect(x: 0, y: 53, width: 350, height: 24)
            addSubview(transparencyButton)
        }
        sizeLabel.frame = NSRect(x: 0, y: 28, width: 455, height: 20); addSubview(sizeLabel)
        let note = NSTextField(labelWithString: format == .jpeg
            ? "JPEG is lossy with white background; assigned background art is included."
            : "Assigned background artwork stays visible within output bounds.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 0, y: 5, width: 455, height: 20); addSubview(note)
        updateRasterSize()
    }

    private func makePageControls(allPages: Bool) {
        let label = NSTextField(labelWithString: "PDF pages:")
        label.frame = NSRect(x: 0, y: 260, width: 82, height: 20); addSubview(label)
        pageMode.frame = NSRect(x: 85, y: 255, width: 365, height: 28)
        pageMode.addItems(withTitles: ["Current page", "All foreground pages", "Selected pages in listed order"])
        pageMode.selectItem(at: allPages ? 1 : 0)
        pageMode.target = self; pageMode.action = #selector(pageModeChanged(_:))
        pageMode.setAccessibilityLabel("PDF page selection")
        addSubview(pageMode)
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        name.title = "Page"; name.width = 285
        let size = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        size.title = "Paper size"; size.width = 145
        table.addTableColumn(name); table.addTableColumn(size)
        table.frame = NSRect(x: 0, y: 0, width: 450, height: 178)
        table.autoresizingMask = [.width]
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("Pages in PDF export order")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 68, width: 450, height: 178))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = table; addSubview(scroll)
        moveUpButton.frame = NSRect(x: 0, y: 33, width: 100, height: 28)
        moveDownButton.frame = NSRect(x: 105, y: 33, width: 110, height: 28)
        moveUpButton.target = self; moveUpButton.action = #selector(movePDFSelectionUp(_:))
        moveDownButton.target = self; moveDownButton.action = #selector(movePDFSelectionDown(_:))
        addSubview(moveUpButton); addSubview(moveDownButton)
        let note = NSTextField(labelWithString: "Command-click to select pages. Assigned backgrounds are included.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 0, y: 4, width: 460, height: 20); addSubview(note)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard pages.indices.contains(row) else { return nil }
        return tableColumn?.identifier.rawValue == "size" ? pages[row].size : pages[row].title
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updatePageControls() }
    func controlTextDidChange(_ obj: Notification) { updateRasterSize() }
    @objc func pageModeChanged(_ sender: Any?) { updatePageControls() }
    @objc func rasterBoundsChanged(_ sender: Any?) { updateRasterSize() }
    @objc private func movePDFSelectionUp(_ sender: Any?) { moveSelection(by: -1) }
    @objc private func movePDFSelectionDown(_ sender: Any?) { moveSelection(by: 1) }

    private func updateRasterSize() {
        var options = OwnedExportOptions()
        options.rasterDPI = Double(resolutionField.stringValue) ?? .nan
        if (try? options.validateRasterDPI()) == nil || (try? options.validateRasterFormat(format)) == nil {
            sizeLabel.stringValue = "Enter a \(format.displayName) resolution between 36 and 1200 dpi."
        } else if rasterBoundsMode.indexOfSelectedItem != 0 {
            sizeLabel.stringValue = "Crop size is measured during export (+1 pixel per side)."
        } else if let size = try? options.rasterSize(width: paperSize.width, height: paperSize.height),
                  (try? options.validateRasterDimensions(size, format: format)) != nil {
            sizeLabel.stringValue = "\(size.width) × \(size.height) pixels; physical paper size is preserved."
        } else {
            sizeLabel.stringValue = format == .jpeg ? "JPEG limit: 65,000 pixels per side / 100 million total."
                : "Enter a supported resolution within the 100 million pixel limit."
        }
    }
    private func updatePageControls() {
        let custom = pageMode.indexOfSelectedItem == 2
        table.isEnabled = custom
        let selected = table.selectedRowIndexes
        moveUpButton.isEnabled = custom && selected.contains { $0 > 0 && !selected.contains($0 - 1) }
        moveDownButton.isEnabled = custom && selected.contains { $0 + 1 < pages.count && !selected.contains($0 + 1) }
    }
    private func moveSelection(by delta: Int) {
        guard pageMode.indexOfSelectedItem == 2, pages.count > 1 else { return }
        let selectedIDs = Set(table.selectedRowIndexes.map { pages[$0].id })
        if delta < 0 {
            for index in 1..<pages.count where selectedIDs.contains(pages[index].id) && !selectedIDs.contains(pages[index - 1].id) {
                pages.swapAt(index, index - 1)
            }
        } else {
            for index in (0..<(pages.count - 1)).reversed() where selectedIDs.contains(pages[index].id) && !selectedIDs.contains(pages[index + 1].id) {
                pages.swapAt(index, index + 1)
            }
        }
        table.reloadData()
        table.selectRowIndexes(IndexSet(pages.indices.filter { selectedIDs.contains(pages[$0].id) }), byExtendingSelection: false)
        updatePageControls()
    }
}
