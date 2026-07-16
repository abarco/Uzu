import SwiftUI

struct ProjectView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 64))
                .foregroundStyle(.red)
            Text("Uzu")
                .font(.largeTitle.bold())
            Text("Record your first part. Everything you add next will play along with it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

#Preview {
    ProjectView()
}
