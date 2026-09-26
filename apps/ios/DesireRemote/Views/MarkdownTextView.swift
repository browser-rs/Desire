import MarkdownUI
import SwiftUI

struct MarkdownTextView: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    private var bubbleTheme: Theme {
        // 边距收紧到气泡内合适的呼吸感；表格横向滚动（手机宽度放不下）。
        // gitHub 主题的链接色是"白底深绿"——暗色气泡里看不清，统一改主题色；
        // 行内代码前景显式 primary（主题默认在暗色下发灰）。
        Theme.gitHub
            .text {
                ForegroundColor(.primary)
            }
            .link {
                ForegroundColor(Color.accentColor)
                UnderlineStyle(.single)
            }
            .code {
                ForegroundColor(.primary)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.35))
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.2))
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.08))
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownMargin(top: 0, bottom: 8)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 2, bottom: 2)
            }
            .blockquote { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(.em(0.95))
                    }
                    .markdownMargin(top: 6, bottom: 6)
            }
            .codeBlock { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(.em(0.92))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        colorScheme == .dark ? Color(rgba: 0xffff_ff14) : Color(rgba: 0x1b1f_230d)
                    )
                    .markdownMargin(top: 8, bottom: 8)
            }
            .table { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .fixedSize(horizontal: true, vertical: false)
                }
                .scrollBounceBehavior(.basedOnSize)
                .markdownTableBorderStyle(.init(
                    color: colorScheme == .dark ? Color(rgba: 0x4244_4eff) : Color(rgba: 0xe4e4_e8ff)
                ))
                .markdownTableBackgroundStyle(.alternatingRows(
                    colorScheme == .dark ? Color(rgba: 0x1819_1dff) : .white,
                    colorScheme == .dark ? Color(rgba: 0x2526_2aff) : Color(rgba: 0xf7f7_f9ff)
                ))
                .markdownMargin(top: 8, bottom: 12)
            }
            .thematicBreak {
                Divider()
                    .markdownMargin(top: 12, bottom: 12)
            }
    }

    var body: some View {
        // 不加 .id(text)：流式更新时每个 token 都会换文本，加 id 会整棵重建、
        // 未闭合的 Markdown 闪成空/原文。外层 ForEach 已按 message.id 稳定身份。
        Markdown(text)
            .markdownTheme(bubbleTheme)
            .textSelection(.enabled)
    }
}


// MARK: - 工具调用行（assistant 帧：调用名；点击展开参数摘要）

