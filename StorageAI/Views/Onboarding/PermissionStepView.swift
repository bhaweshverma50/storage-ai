import SwiftUI

struct PermissionStepView: View {
    let title: String
    let description: String
    let actionTitle: String
    let action: () -> Void
    var isGranted: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            // Status icon
            ZStack {
                Circle()
                    .fill(isGranted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                    .frame(width: 48, height: 48)
                
                Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(isGranted ? .green : .orange)
            }
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Action button
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    VStack {
        PermissionStepView(
            title: "Full Disk Access",
            description: "Required to scan all files",
            actionTitle: "Check Access",
            action: {},
            isGranted: false
        )
        
        PermissionStepView(
            title: "Full Disk Access",
            description: "Access granted",
            actionTitle: "Verified",
            action: {},
            isGranted: true
        )
    }
    .padding()
}
