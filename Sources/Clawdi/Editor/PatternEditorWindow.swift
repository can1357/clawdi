import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PatternEditorWindowController: NSWindowController {
    private let model: PatternEditorModel

    init(
        pattern: PatternModel, presets: PresetStore, mappings: CellMappings, onChange: @escaping (PatternModel) -> Void
    ) {
        self.model = PatternEditorModel(pattern: pattern, presets: presets, mappings: mappings, onChange: onChange)
        let view = PatternEditorView(model: self.model)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 920, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Clawdi Pattern Editor"
        window.contentView = hosting
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func close() {
        model.flushPreview()
        super.close()
    }
}

@MainActor
final class PatternEditorModel: ObservableObject {
    @Published var pattern: PatternModel {
        didSet { schedulePreview() }
    }
    @Published var selectedPart: PatternPart = .head
    @Published var selectedColor: Color = .orange
    @Published var brush = 1
    @Published var erasing = false
    @Published var selectedPresetId: String?
    @Published var presetRevision = 0
    @Published var status = ""

    let presets: PresetStore
    let mappings: CellMappings
    let onChange: (PatternModel) -> Void
    let swatches = [
        "#FFFFFF", "#CFCFCF", "#8F8F8F", "#4A4A4A", "#000000",
        "#FFF0CF", "#FFD28A", "#E8953D", "#B85F1F", "#6F3513",
        "#E7D0A8", "#B9925B", "#886943", "#5B3E25", "#2B1A0F",
        "#FFE6EF", "#FFB8CF", "#F06C99", "#C93668", "#7A1638",
    ]

    private let presetPreviewRenderer: PresetPreviewRenderer
    private var previewTask: Task<Void, Never>?

    init(
        pattern: PatternModel, presets: PresetStore, mappings: CellMappings, onChange: @escaping (PatternModel) -> Void
    ) {
        let sanitized = pattern.sanitized()
        self.pattern = sanitized
        self.selectedPresetId = sanitized.selectedPresetId ?? presets.matchingPreset(for: sanitized)?.id
        self.presets = presets
        self.mappings = mappings
        self.onChange = onChange
        self.presetPreviewRenderer = PresetPreviewRenderer(mappings: mappings)
    }

    var allPresets: [PatternPreset] {
        _ = presetRevision
        return presets.all
    }

    var selectedPreset: PatternPreset? {
        guard let selectedPresetId else { return nil }
        return presets.all.first { $0.id == selectedPresetId }
    }

    var canExport: Bool {
        selectedPreset != nil || presets.matchingPreset(for: pattern) != nil
    }

    func previewImage(for preset: PatternPreset) -> NSImage? {
        presetPreviewRenderer.image(for: preset)
    }

    func dimensions(for part: PatternPart) -> (Int, Int) {
        PartSilhouettes.dimensions(part)
    }

    func isPaintable(x: Int, y: Int, part: PatternPart) -> Bool {
        PartSilhouettes.contains(part, x: x, y: y)
    }

    func paint(x: Int, y: Int) {
        let dims = dimensions(for: selectedPart)
        let color = NSColor(selectedColor).hexString
        let radius = max(1, min(5, brush))
        let startX = x - (radius - 1) / 2
        let startY = y - (radius - 1) / 2
        var spots = pattern.spots(for: selectedPart)
        var changed = false
        for yy in startY..<(startY + radius) where yy >= 0 && yy < dims.1 {
            for xx in startX..<(startX + radius)
            where xx >= 0 && xx < dims.0 && isPaintable(x: xx, y: yy, part: selectedPart) {
                spots.removeAll { $0.x == xx && $0.y == yy }
                if !erasing { spots.append(Spot(x: xx, y: yy, color: color)) }
                changed = true
            }
        }
        guard changed else { return }
        pattern.selectedPresetId = nil
        selectedPresetId = nil
        pattern.setSpots(spots, for: selectedPart)
    }

    func colorAt(x: Int, y: Int) -> Color {
        if let spot = pattern.spots(for: selectedPart).last(where: { $0.x == x && $0.y == y }),
            let color = NSColor(hex: spot.color)
        {
            return Color(color)
        }
        return Color(NSColor(hex: pattern.baseColor) ?? .black).opacity(
            isPaintable(x: x, y: y, part: selectedPart) ? 0.24 : 0.06)
    }

    func applyPreset(_ preset: PatternPreset) {
        var next = preset.pattern.sanitized()
        next.selectedPresetId = preset.id
        selectedPresetId = preset.id
        pattern = next
        status = "Applied \(preset.name)"
    }

    func setBaseColor(_ color: Color) { mutateCustom { $0.baseColor = NSColor(color).hexString } }
    func setEyeColor(_ color: Color) { mutateCustom { $0.eyeColor = NSColor(color).hexString } }
    func setEyeBgColor(_ color: Color) { mutateCustom { $0.eyeBgColor = NSColor(color).hexString } }
    func setOutlineColor(_ color: Color) { mutateCustom { $0.outlineColor = NSColor(color).hexString } }
    func setEyeLeftColor(_ color: Color) { mutateCustom { $0.eyeColorLeft = NSColor(color).hexString } }
    func setEyeRightColor(_ color: Color) { mutateCustom { $0.eyeColorRight = NSColor(color).hexString } }
    func setOddEye(_ value: Bool) { mutateCustom { $0.oddEye = value } }

    func saveCustom() {
        guard
            let name = promptText(
                "Save custom preset",
                text: selectedPreset?.builtIn == false ? selectedPreset?.name ?? "Custom" : "Custom", max: 60)
        else { return }
        do {
            let preset = try presets.add(name: name, pattern: pattern)
            presetRevision += 1
            applyPreset(preset)
            status = "Saved \(preset.name)"
        } catch {
            showError("Could not save preset.")
        }
    }

    func renameSelectedCustom() {
        guard let preset = selectedPreset, !preset.builtIn,
            let name = promptText("Rename preset", text: preset.name, max: 60)
        else { return }
        do {
            try presets.rename(id: preset.id, name: name)
            presets.reload()
            presetRevision += 1
            selectedPresetId = preset.id
            status = "Renamed preset"
        } catch {
            showError("Could not rename preset.")
        }
    }

    func deleteSelectedCustom() {
        guard let preset = selectedPreset, !preset.builtIn else { return }
        guard confirm("Delete “\(preset.name)”?") else { return }
        do {
            try presets.delete(id: preset.id)
            presets.reload()
            selectedPresetId = nil
            pattern.selectedPresetId = nil
            presetRevision += 1
            status = "Deleted \(preset.name)"
        } catch {
            showError("Could not delete preset.")
        }
    }

    func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try presets.importData(Data(contentsOf: url))
            presets.reload()
            presetRevision += 1
            if let preset = imported.first ?? presets.custom.last { applyPreset(preset) }
            status = imported.count == 1 ? "Imported preset" : "Imported \(imported.count) presets"
        } catch {
            showError("Could not import preset.")
        }
    }

    func exportSelectedPreset() {
        guard let preset = selectedPreset ?? presets.matchingPreset(for: pattern) else { return }
        do {
            guard let data = try presets.exportData(id: preset.id) else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = clawdiPatternExportFilename(name: preset.name)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            status = "Exported \(preset.name)"
        } catch {
            showError("Could not export preset.")
        }
    }

    func clearPart() {
        mutateCustom { $0.setSpots([], for: selectedPart) }
    }

    func clearAll() {
        mutateCustom { pattern in
            for part in PatternPart.allCases { pattern.setSpots([], for: part) }
        }
    }

    func flushPreview() {
        previewTask?.cancel()
        previewTask = nil
        onChange(pattern.sanitized())
    }

    private func mutateCustom(_ mutation: (inout PatternModel) -> Void) {
        var next = pattern
        next.selectedPresetId = nil
        mutation(&next)
        selectedPresetId = nil
        pattern = next
    }

    private func schedulePreview() {
        previewTask?.cancel()
        let next = pattern.sanitized()
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled else { return }
            self?.onChange(next)
        }
    }

    private func promptText(_ title: String, text: String, max: Int) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = text
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
        return value.isEmpty ? nil : value
    }

    private func confirm(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

@MainActor
private final class PresetPreviewRenderer {
    private let compositor: PixelCompositor?
    private var cache: [String: NSImage] = [:]

    init(mappings: CellMappings, bundle: Bundle = .main) {
        if let library = try? PoseLibrary.load(bundle: bundle) {
            self.compositor = PixelCompositor(library: library, mappings: mappings)
        } else {
            self.compositor = nil
        }
    }

    func image(for preset: PatternPreset) -> NSImage? {
        let key = cacheKey(for: preset)
        if let cached = cache[key] { return cached }
        guard let compositor,
            let cgImage = compositor.render(state: renderState(for: preset.pattern))
        else { return nil }
        let image = NSImage(
            cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        cache[key] = image
        return image
    }

    private func renderState(for pattern: PatternModel) -> RenderState {
        var state = RenderState()
        state.pattern = pattern.sanitized()
        state.tracking = TrackingOffsets(
            pupils: CGPoint(x: 0.5, y: 0.125),
            eyes: CGPoint(x: 0.25, y: 0.125),
            face: CGPoint(x: 0.375, y: 0.25),
            body: CGPoint(x: 0.125, y: 0.125)
        )
        state.showName = false
        return state
    }

    private func cacheKey(for preset: PatternPreset) -> String {
        let pattern = preset.pattern.sanitized()
        return [
            preset.id,
            preset.updatedAt,
            pattern.baseColor,
            pattern.eyeColor,
            pattern.eyeBgColor,
            pattern.outlineColor,
            pattern.oddEye ? "1" : "0",
            pattern.eyeColorLeft,
            pattern.eyeColorRight,
            spotsKey(pattern.head),
            spotsKey(pattern.body),
            spotsKey(pattern.tail),
            spotsKey(pattern.legFl),
            spotsKey(pattern.legFr),
            spotsKey(pattern.legRl),
            spotsKey(pattern.legRr),
            spotsKey(pattern.earL),
            spotsKey(pattern.earR),
        ].joined(separator: "|")
    }

    private func spotsKey(_ spots: [Spot]) -> String {
        spots.map { "\($0.x),\($0.y),\($0.color)" }.joined(separator: ";")
    }
}

struct PatternEditorView: View {
    @ObservedObject var model: PatternEditorModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            presets
            Divider()
            editor
        }
        .padding()
        .frame(minWidth: 860, minHeight: 660)
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Presets").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.allPresets) { preset in
                        Button {
                            model.applyPreset(preset)
                        } label: {
                            HStack(spacing: 10) {
                                PresetPreviewThumbnail(image: model.previewImage(for: preset))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(preset.builtIn ? "Built-in" : "Custom")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(model.selectedPresetId == preset.id ? .accentColor : nil)
                    }
                }
            }
            HStack {
                Button("Save custom") { model.saveCustom() }
                Button("Import") { model.importPreset() }
            }
            HStack {
                Button("Rename") { model.renameSelectedCustom() }.disabled(model.selectedPreset?.builtIn != false)
                Button("Delete") { model.deleteSelectedCustom() }.disabled(model.selectedPreset?.builtIn != false)
            }
            Button("Export selected") { model.exportSelectedPreset() }.disabled(!model.canExport)
            Button("Clear all") { if confirm("Clear all painted spots?") { model.clearAll() } }
            if !model.status.isEmpty { Text(model.status).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(width: 230)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Part", selection: $model.selectedPart) {
                ForEach(PatternPart.allCases) { Text(title(for: $0)).tag($0) }
            }
            .pickerStyle(.segmented)

            colorControls
            brushControls
            paintGrid
            swatches
        }
    }

    private var colorControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ColorPicker(
                    "Base",
                    selection: Binding(
                        get: { color(model.pattern.baseColor, fallback: .black) }, set: { model.setBaseColor($0) }))
                ColorPicker(
                    "Eyes",
                    selection: Binding(
                        get: { color(model.pattern.eyeColor, fallback: .black) }, set: { model.setEyeColor($0) }))
                ColorPicker(
                    "Eye bg",
                    selection: Binding(
                        get: { color(model.pattern.eyeBgColor, fallback: .white) }, set: { model.setEyeBgColor($0) }))
                ColorPicker(
                    "Outline",
                    selection: Binding(
                        get: { color(model.pattern.outlineColor, fallback: .white) }, set: { model.setOutlineColor($0) }
                    ))
                Toggle("Odd-eye", isOn: Binding(get: { model.pattern.oddEye }, set: { model.setOddEye($0) }))
            }
            if model.pattern.oddEye {
                HStack {
                    ColorPicker(
                        "Left eye",
                        selection: Binding(
                            get: { color(model.pattern.eyeColorLeft, fallback: .black) },
                            set: { model.setEyeLeftColor($0) }))
                    ColorPicker(
                        "Right eye",
                        selection: Binding(
                            get: { color(model.pattern.eyeColorRight, fallback: .black) },
                            set: { model.setEyeRightColor($0) }))
                }
            }
        }
    }

    private var brushControls: some View {
        HStack {
            ColorPicker("Brush color", selection: $model.selectedColor)
            Picker("Brush", selection: $model.brush) {
                ForEach([1, 2, 3, 5], id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Toggle("Erase", isOn: $model.erasing)
            Button("Clear part") { if confirm("Clear \(title(for: model.selectedPart)) spots?") { model.clearPart() } }
        }
    }

    private var paintGrid: some View {
        let dims = model.dimensions(for: model.selectedPart)
        return ScrollView([.horizontal, .vertical]) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 1), count: dims.0), spacing: 1) {
                ForEach(0..<(dims.0 * dims.1), id: \.self) { idx in
                    let x = idx % dims.0
                    let y = idx / dims.0
                    Rectangle()
                        .fill(model.colorAt(x: x, y: y))
                        .border(Color.gray.opacity(0.35))
                        .frame(width: 22, height: 22)
                        .opacity(model.isPaintable(x: x, y: y, part: model.selectedPart) ? 1 : 0.35)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in model.paint(x: x, y: y) })
                }
            }
            .padding(2)
        }
        .frame(maxWidth: .infinity, maxHeight: 390, alignment: .topLeading)
        .background(Color.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var swatches: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Swatches")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28)), count: 5), spacing: 6) {
                ForEach(model.swatches, id: \.self) { hex in
                    Rectangle()
                        .fill(color(hex, fallback: .black))
                        .border(Color.gray.opacity(0.5))
                        .frame(width: 26, height: 26)
                        .onTapGesture {
                            model.selectedColor = color(hex, fallback: .black)
                            model.erasing = false
                        }
                }
            }
        }
    }

    private func color(_ hex: String, fallback: NSColor) -> Color {
        Color(NSColor(hex: hex) ?? fallback)
    }

    private func title(for part: PatternPart) -> String {
        switch part {
        case .head: return "Head"
        case .body: return "Body"
        case .tail: return "Tail"
        case .legFl: return "Front L"
        case .legFr: return "Front R"
        case .legRl: return "Rear L"
        case .legRr: return "Rear R"
        case .earL: return "Ear L"
        case .earR: return "Ear R"
        }
    }

    private func confirm(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private struct PresetPreviewThumbnail: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.05))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .padding(4)
            }
        }
        .frame(width: 52, height: 52)
    }
}
