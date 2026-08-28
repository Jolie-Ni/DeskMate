//
//  DSFields.swift
//  Text input: single-line field, search field, multiline editor.
//
//  All three share one focus language — the stroke goes from a faint hairline
//  to solid celadon and a soft glow appears. That's the only focus signal;
//  there is no colour change to the fill.
//

import SwiftUI

// MARK: - Text field

struct DSTextField: View {
    @Environment(\.dsTheme) private var theme
    @FocusState private var isFocused: Bool

    let placeholder: String
    @Binding var text: String
    var label: String? = nil
    var systemImage: String? = nil
    /// Shown in seal red beneath the field. Non-nil puts the field in an error state.
    var errorText: String? = nil
    var helperText: String? = nil
    var isSecure: Bool = false
    #if os(iOS)
    var keyboard: UIKeyboardType = .default
    #endif
    var submitLabel: SubmitLabel = .done
    var onSubmit: () -> Void = {}

    private var hasError: Bool { errorText != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(0.75)) {
            if let label {
                DSEyebrow(text: label)
            }

            HStack(spacing: theme.space(1.25)) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isFocused ? theme.accentDeep : theme.inkTertiary)
                }

                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .font(theme.body)
                .foregroundStyle(theme.ink)
                .tint(theme.accentDeep)
                #if os(iOS)
                .keyboardType(keyboard)
                #endif
                .submitLabel(submitLabel)
                .focused($isFocused)
                .onSubmit(onSubmit)

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(theme.inkTertiary.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, theme.space(1.75))
            .frame(height: 50)
            .background { fieldBackground }

            if let errorText {
                fieldFootnote(errorText, color: theme.critical, icon: "exclamationmark.circle.fill")
            } else if let helperText {
                fieldFootnote(helperText, color: theme.inkTertiary, icon: nil)
            }
        }
        .animation(DSMotion.fade, value: isFocused)
        .animation(DSMotion.fade, value: hasError)
    }

    private var fieldBackground: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusField, style: .continuous)
        return shape
            .fill(theme.fieldFill)
            .overlay {
                shape.strokeBorder(
                    hasError ? theme.critical
                             : (isFocused ? theme.fieldStrokeFocused : theme.fieldStroke),
                    lineWidth: isFocused || hasError ? 1.5 : theme.hairlineWidth
                )
            }
            .shadow(
                color: isFocused ? theme.accent.opacity(0.22) : .clear,
                radius: isFocused ? 8 : 0,
                y: 2
            )
    }

    @ViewBuilder
    private func fieldFootnote(_ text: String, color: Color, icon: String?) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(theme.footnote)
        }
        .foregroundStyle(color)
        .padding(.leading, 2)
    }
}

// MARK: - Search field

struct DSSearchField: View {
    @Environment(\.dsTheme) private var theme
    @FocusState private var isFocused: Bool

    var placeholder: String = "Search"
    @Binding var text: String
    /// Shows a Cancel button while focused.
    var showsCancel: Bool = true

    var body: some View {
        HStack(spacing: theme.space(1.25)) {
            HStack(spacing: theme.space(1)) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isFocused ? theme.accentDeep : theme.inkTertiary)

                TextField(placeholder, text: $text)
                    .font(theme.body)
                    .foregroundStyle(theme.ink)
                    .tint(theme.accentDeep)
                    .focused($isFocused)
                    .submitLabel(.search)

                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(theme.inkTertiary.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, theme.space(1.5))
            .frame(height: 44)
            .dsGlass(radius: theme.radiusField, elevation: .flush, emphasis: isFocused ? 0.06 : 0)

            if showsCancel && isFocused {
                Button("Cancel") {
                    text = ""
                    isFocused = false
                }
                .buttonStyle(.ds(.quiet, size: .small))
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(DSMotion.tap, value: isFocused)
        .animation(DSMotion.fade, value: text.isEmpty)
    }
}

// MARK: - Multiline editor

struct DSTextEditor: View {
    @Environment(\.dsTheme) private var theme
    @FocusState private var isFocused: Bool

    let placeholder: String
    @Binding var text: String
    var label: String? = nil
    var minHeight: CGFloat = 120
    /// Optional character budget. Shows a counter that turns ochre near the limit.
    var characterLimit: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(0.75)) {
            if let label {
                DSEyebrow(text: label)
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(theme.body)
                        .foregroundStyle(theme.inkTertiary)
                        .padding(.horizontal, theme.space(1.75) + 5)
                        .padding(.vertical, theme.space(1.5) + 8)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $text)
                    .font(theme.body)
                    .foregroundStyle(theme.ink)
                    .tint(theme.accentDeep)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .padding(.horizontal, theme.space(1.5))
                    .padding(.vertical, theme.space(1.5))
            }
            .frame(minHeight: minHeight, alignment: .topLeading)
            .background {
                let shape = RoundedRectangle(cornerRadius: theme.radiusField, style: .continuous)
                shape
                    .fill(theme.fieldFill)
                    .overlay {
                        shape.strokeBorder(
                            isFocused ? theme.fieldStrokeFocused : theme.fieldStroke,
                            lineWidth: isFocused ? 1.5 : theme.hairlineWidth
                        )
                    }
                    .shadow(
                        color: isFocused ? theme.accent.opacity(0.22) : .clear,
                        radius: isFocused ? 8 : 0,
                        y: 2
                    )
            }

            if let characterLimit {
                HStack {
                    Spacer()
                    Text("\(text.count) / \(characterLimit)")
                        .font(theme.footnote)
                        .monospacedDigit()
                        .foregroundStyle(
                            text.count > characterLimit ? theme.critical
                                : (text.count > characterLimit * 4 / 5 ? theme.attention : theme.inkTertiary)
                        )
                }
            }
        }
        .animation(DSMotion.fade, value: isFocused)
    }
}
