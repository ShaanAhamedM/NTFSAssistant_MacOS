import SwiftUI

public struct HealthReportSheet: View {
    public let driveName: String
    public let report: String
    public let isClean: Bool
    @Environment(\.dismiss) private var dismiss
    
    public init(driveName: String, report: String, isClean: Bool) {
        self.driveName = driveName
        self.report = report
        self.isClean = isClean
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: isClean ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundColor(isClean ? .green : .red)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Volume Health Inspection")
                        .font(.headline)
                    Text(driveName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 4)
            
            Divider()
            
            Text("Diagnostic Output (ntfsfix -n):")
                .font(.caption)
                .foregroundColor(.secondary)
            
            ScrollView {
                Text(report.isEmpty ? "No output returned by diagnostic check." : report)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
            }
            .frame(height: 180)
            
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                } label: {
                    Label("Copy Log", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                if !isClean {
                    Text("⚠ Fast Startup / Dirty flag prevents safe R/W mounting")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
        }
        .padding(16)
        .frame(width: 480, height: 320)
    }
}
