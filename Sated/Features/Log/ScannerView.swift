import SwiftData
import SwiftUI
import VisionKit

/// Scan a barcode (looked up in Open Food Facts) or a Nutrition Facts label (read on device).
///
/// Label mode finds the panel among everything the camera sees, outlines it, reads its rows with
/// rules and votes the values across frames (`LabelScanSession`). Once everything is read and
/// adds up, it stops by itself and shows the values to check.
struct ScannerView: View {
    let meal: Meal
    var onAdded: () -> Void = {}

    enum Mode: String, CaseIterable, Identifiable {
        case barcode = "Barcode"
        case label = "Nutrition Label"
        var id: String { rawValue }
    }

    enum Phase: Equatable {
        case scanning
        case looking
        case found(FoodItem)
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var mode: Mode = .barcode
    @State private var phase: Phase = .scanning
    @State private var scan = ScanFeed()
    @State private var detail: FoodItem?
    @State private var lastBarcode: String?
    @State private var label = LabelScanSession()
    @State private var review: LabelDraft?

    private var canScan: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        ZStack {
            if canScan {
                DataScanner(mode: mode, feed: scan)
                    .id(mode)
                    .ignoresSafeArea()
                if mode == .label {
                    LabelPanelOutline(rect: label.panelRect)
                        .ignoresSafeArea()
                }
            } else {
                ContentUnavailableView(
                    "Camera Unavailable",
                    systemImage: "camera.fill",
                    description: Text("Scanning needs camera access. Turn it on in Settings › Sated › Camera.")
                )
            }

            VStack(spacing: 16) {
                topBar
                Spacer()
                // Labels are read with rules on the device, so both modes work everywhere.
                Picker("Scan mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .glassEffect(.regular, in: .capsule)
                resultCard
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .onChange(of: scan.barcode) { _, code in
            guard mode == .barcode, phase == .scanning, let code, code != lastBarcode else { return }
            lastBarcode = code
            Task { await lookUp(code) }
        }
        .onChange(of: scan.pieces) { _, pieces in
            guard mode == .label, phase == .scanning, review == nil else { return }
            label.update(pieces)
        }
        .onChange(of: label.isComplete) { _, complete in
            guard complete, mode == .label else { return }
            Task { await finishLabel(source: .camera, reading: label.confirmed.filled(from: label.leading)) }
        }
        .onChange(of: mode) { restart() }
        .sheet(item: $review) { draft in
            NavigationStack {
                LabelReviewView(draft: draft, meal: meal) {
                    dismiss()
                    onAdded()
                } onRescan: {
                    restart()
                }
            }
            .interactiveDismissDisabled()
        }
        .sheet(item: $detail) { food in
            NavigationStack {
                FoodDetailView(food: food, meal: meal) {
                    dismiss()
                    onAdded()
                }
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
            Spacer()
            Text(meal.name)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .glassEffect(.regular, in: .capsule)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var resultCard: some View {
        switch phase {
        case .scanning:
            if mode == .label {
                labelCard
            } else {
                hint("Point the camera at a barcode")
            }
        case .looking:
            HStack(spacing: 12) {
                ProgressView()
                Text(mode == .barcode ? "Looking it up…" : "Reading the label…")
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 32))
        case .found(let food):
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(food.source == .openFoodFacts ? "FOUND · OPEN FOOD FACTS" : "READ FROM LABEL", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    Text(food.name).font(.headline)
                    Text(food.listDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 10) {
                    Button("Details") { detail = food }
                        .buttonStyle(.glass)
                        .frame(maxWidth: .infinity)
                    Button("Add") {
                        FoodLog.add(food, servings: 1, meal: meal, in: context)
                        dismiss()
                        onAdded()
                    }
                    .buttonStyle(.glassProminent)
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 32))
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Button("Scan Again") { restart() }
                .buttonStyle(.glass)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 32))
        }
    }

    /// The checklist, a hint, and, if it's taking a while, the fallbacks.
    private var labelCard: some View {
        VStack(spacing: 14) {
            Text(label.hint)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .animation(.snappy, value: label.hint)
            LabelChecklist(confirmed: label.confirmed, leading: label.leading)
            if label.isStuck {
                HStack(spacing: 10) {
                    if OnDeviceModel.availability == .available {
                        Button("Read with AI") {
                            Task { await readWithModel() }
                        }
                        .buttonStyle(.glass)
                        .frame(maxWidth: .infinity)
                    }
                    Button("Enter Manually") {
                        Task { await finishLabel(source: .manual, reading: label.best) }
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
        .animation(.snappy, value: label.isStuck)
    }

    private func restart() {
        phase = .scanning
        lastBarcode = nil
        scan.barcode = nil
        scan.pieces = []
        label.reset()
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .glassEffect(.regular, in: .capsule)
    }

    private func lookUp(_ barcode: String) async {
        phase = .looking
        do {
            let food = try await OpenFoodFacts(userAgent: AppConfig.userAgent).product(barcode: barcode)
            phase = .found(food)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The fallback: the on-device model reads the panel's text (only the panel's).
    private func readWithModel() async {
        let lines = label.panelLines
        guard !lines.isEmpty else { return }
        phase = .looking
        do {
            let reading = try await LabelReader.read(lines)
            // Anything the rules already confirmed wins over the model.
            await finishLabel(source: .model, reading: label.confirmed.filled(from: reading))
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't read the label. Try again with the whole panel in view.")
        }
    }

    /// Takes a picture of the panel for the review screen, then shows it.
    private func finishLabel(source: LabelDraft.Source, reading: LabelReading) async {
        guard review == nil else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        var photo: UIImage?
        if let captured = await scan.capturePhoto() {
            photo = label.panelRect.map { LabelPhoto.crop(captured, to: $0, viewSize: scan.viewSize) } ?? captured
        }
        phase = .scanning
        review = LabelDraft(reading: reading, photo: photo, source: source)
    }
}

/// What the camera currently sees, shared between the scanner and the screen.
@Observable
final class ScanFeed {
    var barcode: String?
    /// Recognized text with its position, in the camera view's coordinates.
    var pieces: [TextPiece] = []
    @ObservationIgnored weak var controller: DataScannerViewController?

    var viewSize: CGSize { controller?.view.bounds.size ?? .zero }

    /// A still of what the camera sees now.
    func capturePhoto() async -> UIImage? {
        guard let controller else { return nil }
        return try? await controller.capturePhoto()
    }
}

/// VisionKit's live scanner, set up for barcodes or for text.
private struct DataScanner: UIViewControllerRepresentable {
    var mode: ScannerView.Mode
    var feed: ScanFeed

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let types: Set<DataScannerViewController.RecognizedDataType> = mode == .barcode
            ? [.barcode(symbologies: [.ean13, .ean8, .upce, .code128])]
            : [.text()]
        let scanner = DataScannerViewController(
            recognizedDataTypes: types,
            qualityLevel: mode == .barcode ? .balanced : .accurate,
            recognizesMultipleItems: mode == .label,
            isHighFrameRateTrackingEnabled: false,
            // Label mode draws its own outline around the panel instead.
            isHighlightingEnabled: mode == .barcode
        )
        scanner.delegate = context.coordinator
        feed.controller = scanner
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        if !controller.isScanning { try? controller.startScanning() }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(feed: feed) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let feed: ScanFeed

        init(feed: ScanFeed) { self.feed = feed }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            update(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            update(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            update(allItems)
        }

        private func update(_ items: [RecognizedItem]) {
            var pieces: [TextPiece] = []
            for item in items {
                switch item {
                case .barcode(let barcode):
                    if let value = barcode.payloadStringValue, feed.barcode != value { feed.barcode = value }
                case .text(let text):
                    let corners = [text.bounds.topLeft, text.bounds.topRight, text.bounds.bottomLeft, text.bounds.bottomRight]
                    let xs = corners.map(\.x), ys = corners.map(\.y)
                    let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                    pieces.append(TextPiece(text: text.transcript, rect: rect))
                @unknown default:
                    break
                }
            }
            if pieces != feed.pieces { feed.pieces = pieces }
        }
    }
}
