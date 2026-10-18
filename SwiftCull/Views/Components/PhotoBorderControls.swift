import SwiftUI
import AppKit

struct PhotoBorderControls: View {
    @Binding var configuration: PhotoBorderConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("输出比例").font(.subheadline.weight(.medium))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(PhotoBorderConfiguration.Aspect.allCases) { aspect in
                        Button {
                            configuration.aspect = aspect
                        } label: {
                            Text(aspect.title)
                                .font(.system(size: 12, weight: configuration.aspect == aspect ? .semibold : .regular))
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .background(configuration.aspect == aspect ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035),
                                            in: RoundedRectangle(cornerRadius: 6))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(configuration.aspect == aspect ? Color.accentColor.opacity(0.6) : .clear)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("边框比例 \(aspect.title)")
                        .accessibilityAddTraits(configuration.aspect == aspect ? .isSelected : [])
                    }
                }
                Text(configuration.aspect == .original ? "四边等宽留白，照片保持完整。" : "居中放置完整照片，通过留白匹配比例。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("边框宽度").font(.subheadline.weight(.medium))
                    Spacer()
                    Text(String(format: "%.1f%%", configuration.widthPercent))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $configuration.widthPercent, in: 0...15, step: 0.1)
                    .accessibilityLabel("边框宽度")
                HStack {
                    Text("以画布短边为基准").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认") { configuration.widthPercent = PhotoBorderConfiguration().widthPercent }
                        .font(.caption).buttonStyle(.borderless)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("边框颜色").font(.subheadline.weight(.medium))
                HStack(spacing: 5) {
                    ForEach(PhotoBorderConfiguration.palette, id: \.hex) { swatch in
                        Button { configuration.colorHex = swatch.hex } label: {
                            Circle()
                                .fill(Color(nsColor: PhotoBorderConfiguration(colorHex: swatch.hex).color))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                                .padding(2)
                                .overlay(Circle().strokeBorder(configuration.colorHex == swatch.hex ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain).help(swatch.name)
                        .accessibilityLabel("\(swatch.name)色边框")
                    }
                }
                ColorPicker("自定义颜色", selection: Binding(
                    get: { Color(nsColor: configuration.color) },
                    set: { configuration.setColor(NSColor($0)) }
                ), supportsOpacity: false)
                .font(.caption)
            }
        }
    }
}
