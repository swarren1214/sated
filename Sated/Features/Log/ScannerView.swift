import SwiftData
import SwiftUI
import VisionKit

/// Scan a barcode (looked up in Open Food Facts) or a Nutrition Facts label (read on device).
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

    private var canScan: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        ZStack {
            if canScan {
                DataScanner(mode: mode, feed: scan)
                    .id(mode)
                    .ignoresSafeArea()
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
                if OnDeviceModel.isOffered {
                    Picker("Scan mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    .glassEffect(.regular, in: .capsule)
                }
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
        .onChange(of: mode) { restart() }
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
                .frame(height: 36)
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
                Button {
                    Task { await readLabel() }
                } label: {
                    Label("Read Label", systemImage: "text.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
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

    private func restart() {
        phase = .scanning
        lastBarcode = nil
        scan.barcode = nil
        scan.textLines = []
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .frame(height: 40)
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

    private func readLabel() async {
        let lines = scan.textLines
        guard !lines.isEmpty else {
            phase = .failed(LabelReader.ReadError.notALabel.localizedDescription)
            return
        }
        phase = .looking
        do {
            let food = try await LabelReader.read(lines, name: "Scanned food")
            phase = .found(food)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't read the label. Try again with the whole panel in view.")
        }
    }
}

/// What the camera currently sees, shared between the scanner and the screen.
@Observable
final class ScanFeed {
    var barcode: String?
    var textLines: [String] = []
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
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
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
            var lines: [String] = []
            for item in items {
                switch item {
                case .barcode(let barcode):
                    if let value = barcode.payloadStringValue, feed.barcode != value { feed.barcode = value }
                case .text(let text):
                    lines.append(text.transcript)
                @unknown default:
                    break
                }
            }
            if !lines.isEmpty { feed.textLines = lines }
        }
    }
}
