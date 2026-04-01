import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var inputURLs: [URL] = []
    @State private var isProcessing = false
    @State private var statusMessage = "Drop CR3 files here or click \"Select Files\" to begin."
    @State private var progress: Double = 0
    @State private var showFilePicker = false
    @State private var previewImage: NSImage?
    @State private var enableFisheye = false

    private let converter = SpatialImageConverter()
    private let fisheyeProcessor = FisheyeProcessor()

    private let supportedTypes: [UTType] = [
        UTType(filenameExtension: "cr3") ?? .rawImage,
        .rawImage,
        .tiff,
        .jpeg,
        .png
    ].compactMap { $0 }

    var body: some View {
        VStack(spacing: 20) {
            Text("fishEye")
                .font(.largeTitle.bold())
            Text("Spatial Image Converter")
                .font(.headline)
                .foregroundStyle(.secondary)

            // Drop zone / Preview
            dropZone
                .frame(minHeight: 250)

            // File list
            if !inputURLs.isEmpty {
                fileList
            }

            // Fisheye processing toggle
            Toggle("Canon Dual Fisheye Lens", isOn: $enableFisheye)
                .help("Enable processing for Canon RF-S 3.9mm f/3.5 STM Dual Fisheye lens: circle detection, left/right swap, chromatic aberration correction, and equirectangular projection.")
                .disabled(isProcessing)

            // Controls
            HStack(spacing: 16) {
                Button("Select Files") {
                    showFilePicker = true
                }
                .disabled(isProcessing)

                Button("Convert All") {
                    Task { await convertAll() }
                }
                .disabled(inputURLs.isEmpty || isProcessing)
                .buttonStyle(.borderedProminent)

                if !inputURLs.isEmpty {
                    Button("Clear") {
                        inputURLs.removeAll()
                        previewImage = nil
                        statusMessage = "Drop CR3 files here or click \"Select Files\" to begin."
                        progress = 0
                    }
                    .disabled(isProcessing)
                }
            }

            // Progress
            if isProcessing {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(statusMessage.contains("Error") ? .red : .secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(30)
        .frame(minWidth: 500, minHeight: 550)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            handleFileSelection(result)
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(.quaternary)

            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Drop side-by-side stereo images here")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
    }

    // MARK: - File List

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Selected files (\(inputURLs.count)):")
                .font(.caption.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(inputURLs, id: \.self) { url in
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(maxHeight: 80)
        }
    }

    // MARK: - Actions

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            inputURLs = urls
            loadPreview(from: urls.first)
            statusMessage = "\(urls.count) file(s) selected. Click \"Convert All\" to create spatial images."
        case .failure(let error):
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                urls.append(url)
            }
        }

        group.notify(queue: .main) {
            inputURLs = urls
            loadPreview(from: urls.first)
            statusMessage = "\(urls.count) file(s) dropped. Click \"Convert All\" to create spatial images."
        }
    }

    private func loadPreview(from url: URL?) {
        guard let url else {
            previewImage = nil
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            if let nsImage = NSImage(contentsOf: url) {
                DispatchQueue.main.async {
                    previewImage = nsImage
                }
            }
        }
    }

    private func convertAll() async {
        isProcessing = true
        progress = 0

        // Ask user for output directory
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Output Folder"
        panel.message = "Select a folder to save the spatial HEIC files."

        guard panel.runModal() == .OK, let outputDir = panel.url else {
            isProcessing = false
            statusMessage = "Conversion cancelled."
            return
        }

        let total = inputURLs.count
        var successCount = 0
        var errorCount = 0
        var lastError = ""

        let didAccessOutput = outputDir.startAccessingSecurityScopedResource()

        for (index, inputURL) in inputURLs.enumerated() {
            let baseName = inputURL.deletingPathExtension().lastPathComponent
            let outputURL = outputDir.appendingPathComponent("\(baseName)_spatial.heic")

            statusMessage = "Converting \(index + 1)/\(total): \(inputURL.lastPathComponent)..."

            let didAccessInput = inputURL.startAccessingSecurityScopedResource()

            do {
                try converter.convert(
                    input: inputURL, output: outputURL,
                    fisheyeProcessor: enableFisheye ? fisheyeProcessor : nil)
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    successCount += 1
                } else {
                    errorCount += 1
                    statusMessage = "Error: file was not created at \(outputURL.path)"
                }
            } catch {
                errorCount += 1
                lastError = "\(inputURL.lastPathComponent): \(error.localizedDescription)"
                statusMessage = "Error converting \(lastError)"
            }

            if didAccessInput { inputURL.stopAccessingSecurityScopedResource() }
            progress = Double(index + 1) / Double(total)
        }

        if didAccessOutput { outputDir.stopAccessingSecurityScopedResource() }

        isProcessing = false
        if errorCount == 0 {
            statusMessage = "Done! \(successCount) spatial image(s) saved to \(outputDir.lastPathComponent)/."
        } else {
            statusMessage = "Error: \(lastError)"
        }
    }
}

#Preview {
    ContentView()
}
