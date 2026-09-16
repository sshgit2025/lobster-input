/// PermissionGateView.swift
/// 权限管理面板 — 沙棕极简风格
import SwiftUI

struct PermissionGateView: View {
    var onDone: (() -> Void)? = nil
    @ObservedObject private var pm = PermissionManager.shared
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        ZStack {
            Cyber.panelBg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                CyberDivider()
                permissionList
                CyberDivider()
                footer
            }
        }
        .frame(width: CyberLayout.permW)
        .onAppear { pm.refreshStatuses() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(pm.allGranted ? Cyber.accent : Cyber.warning)
                    .frame(width: 42, height: 42)
                    .background((pm.allGranted ? Cyber.accent : Cyber.warning).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke((pm.allGranted ? Cyber.accent : Cyber.warning).opacity(0.22), lineWidth: 1))
                if !pm.allGranted {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12))
                        .foregroundStyle(.white, Cyber.warning).offset(x: 4, y: -4)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(pm.allGranted ? L10n.permFullyAuthorized : L10n.permPartialAuth)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Cyber.textBright)
                Text(pm.allGranted ? L10n.permAllOk : L10n.permSomeMissing)
                    .font(.system(size: 13)).foregroundStyle(Cyber.textDim)
            }
            Spacer()
        }.padding(.horizontal, 24).padding(.vertical, 20)
    }

    private var permissionList: some View {
        VStack(spacing: 0) {
            PermRow(icon: "mic", iconColor: Cyber.warning, title: L10n.permMicrophone, description: L10n.permMicrophoneDesc, status: pm.microphoneStatus,
                onAuth: { if pm.microphoneStatus == .notDetermined { Task { await pm.requestMicrophone() } } else { pm.openMicrophoneSettings() } },
                onRevoke: { pm.openMicrophoneSettings() })
            CyberDivider().padding(.leading, 58)
            PermRow(icon: "figure.wave", iconColor: Cyber.accent, title: L10n.permAccessibility, description: L10n.permAccessibilityDesc, status: pm.accessibilityStatus,
                onAuth: { pm.requestAccessibilityIfNeeded(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pm.openAccessibilitySettings() } },
                onRevoke: { pm.openAccessibilitySettings() })
            CyberDivider().padding(.leading, 58)
            PermRow(icon: "camera.viewfinder", iconColor: Cyber.accent, title: L10n.permScreenCapture, description: L10n.permScreenCaptureDesc, status: pm.screenCaptureStatus,
                onAuth: { if !pm.requestScreenCaptureIfNeeded() { pm.openScreenCaptureSettings() } },
                onRevoke: { pm.openScreenCaptureSettings() },
                isOptional: true)
        }
    }

    private var footer: some View {
        HStack {
            Button { pm.refreshStatuses() } label: {
                HStack(spacing: 8) { Image(systemName: "arrow.clockwise").font(.system(size: 12)); Text(L10n.btnRefresh).font(.system(size: 13, weight: .medium)) }
                    .foregroundStyle(Cyber.textDim)
            }.buttonStyle(.plain)
            Spacer()
            Button(L10n.btnDone) { onDone?() }.buttonStyle(NeonButtonStyle(color: Cyber.accent))
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }
}

private struct PermRow: View {
    let icon: String; let iconColor: Color; let title: String; let description: String
    let status: PermissionStatus; let onAuth: () -> Void; let onRevoke: () -> Void
    var isOptional: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(iconColor)
                    .frame(width: 36, height: 36)
                    .background(iconColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(iconColor.opacity(0.2), lineWidth: 1))
                statusDot
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Cyber.textBright)
                    if isOptional {
                        Text(L10n.permissionOptional).font(.system(size: 10, weight: .medium)).foregroundStyle(Cyber.textGhost)
                    }
                }
                Text(description).font(.system(size: 12)).foregroundStyle(Cyber.textGhost)
            }
            Spacer()
            actionButton
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    @ViewBuilder private var statusDot: some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.white, Cyber.accent).offset(x: 4, y: 4)
        case .denied, .notDetermined:
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.white, Cyber.warning).offset(x: 4, y: 4)
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch status {
        case .granted:
            Button { onRevoke() } label: { Text(L10n.manage).font(.system(size: 12, weight: .medium)).foregroundStyle(Cyber.textGhost) }.buttonStyle(.plain)
        case .denied, .notDetermined:
            Button(L10n.permGoAuth) { onAuth() }.buttonStyle(NeonButtonStyle(color: iconColor))
        }
    }
}
