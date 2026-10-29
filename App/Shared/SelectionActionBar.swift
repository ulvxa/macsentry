import SwiftUI

struct SelectionAction {
    let title: String
    var shortTitle: String?
    var systemImage: String?
    var role: ButtonRole?
    var disabledReason: String?
    var hint: String?
    let perform: () -> Void
}

struct SelectionActionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    let itemCount: Int
    let bytes: Int64
    var chipText: String?
    let primary: SelectionAction
    var secondary: SelectionAction?
    var selectDefault: SelectionAction?
    let clear: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: Space.s) {
            HStack(spacing: Space.s) {
                chip
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("sel.chip", in: namespace)
                if itemCount > 0 {
                    actionButton(primary, prominent: true)
                        .glassEffectID("sel.primary", in: namespace)
                    if let secondary {
                        actionButton(secondary, prominent: false)
                            .glassEffectID("sel.secondary", in: namespace)
                    }
                    Button(action: clear) {
                        Label("Clear Selection", systemImage: "xmark")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Clear Selection")
                    .glassEffectID("sel.clear", in: namespace)
                }
            }
        }
        .controlSize(.large)
        .animation(reduceMotion ? nil : .bouncy(duration: 0.4), value: itemCount > 0)
        .padding(.bottom, Space.l)
        .frame(maxWidth: .infinity)
        .focusSection()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { model.bottomChromeInset = $0 })
        .onDisappear { model.bottomChromeInset = 0 }
    }

    private var chip: some View {
        HStack(spacing: Space.s) {
            if let chipText {
                Text(chipText)
                    .font(.callout)
            } else if itemCount > 0 {
                Text("\(itemCount.formatted()) selected")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            } else {
                Text("None selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let selectDefault {
                    Button(selectDefault.title, action: selectDefault.perform)
                        .buttonStyle(.borderless)
                        .font(.callout.weight(.medium))
                        .disabled(selectDefault.disabledReason != nil)
                }
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actionButton(_ action: SelectionAction, prominent: Bool) -> some View {
        let button = Button(role: action.role, action: action.perform) {
            ViewThatFits(in: .horizontal) {
                label(action.title, action.systemImage)
                if let shortTitle = action.shortTitle {
                    label(shortTitle, action.systemImage)
                }
            }
        }
        .disabled(action.disabledReason != nil)
        .help(action.disabledReason ?? action.hint ?? action.title)
        .accessibilityLabel(action.title)
        .accessibilityHint(action.hint ?? "")
        if prominent {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }

    @ViewBuilder
    private func label(_ title: String, _ systemImage: String?) -> some View {
        if let systemImage {
            Label(title, systemImage: systemImage).lineLimit(1)
        } else {
            Text(title).lineLimit(1)
        }
    }
}
