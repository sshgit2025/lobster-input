import SwiftUI

struct OnboardingView: View {

    @Binding var isPresented: Bool

    @State private var currentPage = 0

    private var steps: [OnboardingStep] {
        [
            OnboardingStep(icon: "mic.fill", title: L10n.onboardingVoiceTitle, desc: L10n.onboardingStep1),
            OnboardingStep(icon: "wand.and.stars", title: L10n.onboardingPolishTitle, desc: L10n.onboardingStep2),
            OnboardingStep(icon: "arrow.triangle.2.circlepath", title: L10n.onboardingRewriteTitle, desc: L10n.onboardingStep3),
        ]
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            TabView(selection: $currentPage) {
                ForEach(steps.indices, id: \.self) { idx in
                    VStack(spacing: 20) {
                        ZStack {
                            Circle()
                                .fill(LobsterWaterPalette.surfaceMutedColor)
                                .frame(width: 120, height: 120)
                            Image(systemName: steps[idx].icon)
                                .font(.system(size: 56))
                                .foregroundStyle(LobsterWaterPalette.accentColor)
                        }

                        Text(steps[idx].title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(LobsterWaterPalette.textColor)

                        Text(steps[idx].desc)
                            .font(.body)
                            .foregroundStyle(LobsterWaterPalette.mutedColor)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(height: 300)

            Spacer()

            Button {
                if currentPage < steps.count - 1 {
                    withAnimation { currentPage += 1 }
                } else {
                    isPresented = false
                }
            } label: {
                Text(currentPage < steps.count - 1 ? L10n.btnNext : L10n.onboardingStart)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(LobsterWaterPalette.accentColor)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(LobsterWaterPalette.panelColor.ignoresSafeArea())
    }
}

private struct OnboardingStep {
    let icon: String
    let title: String
    let desc: String
}
