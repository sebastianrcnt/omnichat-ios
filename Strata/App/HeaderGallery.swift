#if DEBUG && os(iOS)
import SwiftUI

/// `-StrataHeaderGallery 1`: instead of the app, the chat header in several candidate layouts, each over a strip of
/// reply text so the glass shows what it does over content. For comparing designs on a simulator; nothing is wired.
struct HeaderGallery: View {
    @Environment(\.theme) private var theme

    static var isRequested: Bool { UserDefaults.standard.integer(forKey: "StrataHeaderGallery") > 0 }
    /// `-StrataHeaderGallery 2`: the soft top edge (no band) instead of the hard one, with the glass-backed candidates first.
    private var soft: Bool { UserDefaults.standard.integer(forKey: "StrataHeaderGallery") == 2 }

    private let title = "Pi 코딩 에이전트 익스텐션 설명"
    private let model = "Muse Spark 1.3 Contributor"
    private let fraction = 0.28

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.sm) {
                if soft {
                    candidate("C  title in its own glass · soft edge") { titleGlass }
                    candidate("D  one glass bar · soft edge") { oneBar }
                    candidate("E  model pill, no title · soft edge") { modelPill }
                    candidate("F  Claude-like: buttons only · soft edge") { buttonsOnly }
                    candidate("A  current · soft edge (before)") { current }
                } else {
                    candidate("A  current") { current }
                    candidate("B  centered title") { centered }
                    candidate("C  title in its own glass") { titleGlass }
                    candidate("D  one glass bar") { oneBar }
                    candidate("E  model pill, no title") { modelPill }
                    candidate("F  Claude-like: buttons only") { buttonsOnly }
                }
            }
            .padding(.vertical, DS.Spacing.md)
        }
        .background(theme.background)
    }

    private func candidate<Header: View>(_ name: String, @ViewBuilder header: () -> Header) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption.weight(.semibold)).foregroundStyle(theme.accent).padding(.horizontal, DS.Spacing.md)
            // Like the chat: reply text scrolled up under the header, with the list's hard top edge effect.
            ScrollView {
                Text("네이버 항공에서 인천-코타키나발루 찾아보고 있어요. 팝업 닫고 검색 이어갈게요. 출발지는 서울/인천, 도착지는 코타키나발루로 잡았어요. 날짜 선택해볼게요. 출발일은 다음 달 셋째 주로 잡고 가격을 비교해 볼게요.")
                    .font(DS.Typography.answer)
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, DS.Spacing.page)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .scrollEdgeEffectStyle(soft ? .soft : .hard, for: .top)
            .safeAreaBar(edge: .top) {
                header()
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
            }
            .frame(height: 150)
        }
    }

    // MARK: Pieces

    private var sidebar: some View { GlassIconButton(systemName: "line.3.horizontal", label: "Sidebar") {} }

    private var titleText: some View {
        Text(verbatim: title).font(DS.Typography.title).foregroundStyle(theme.textPrimary).lineLimit(1)
    }

    private var modelText: some View {
        HStack(spacing: 2) {
            Text(verbatim: model).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .font(DS.Typography.uiCaption)
        .foregroundStyle(theme.textSecondary)
    }

    private var ringAndMenu: some View {
        HStack(spacing: 0) {
            ContextRing(fraction: fraction).frame(width: DS.IconSize.controlDiameter, height: DS.IconSize.controlDiameter)
            GlassIconMenuPlain(systemName: "ellipsis", label: "More") { Button("New Chat") {} }
        }
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    // MARK: Candidates

    private var current: some View {
        GlassEffectContainer(spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                sidebar
                VStack(alignment: .leading, spacing: 0) {
                    titleText
                    Spacer(minLength: DS.Spacing.xxs)
                    modelText
                }
                .frame(height: DS.IconSize.controlDiameter, alignment: .leading)
                Spacer(minLength: 0)
                ringAndMenu
            }
        }
    }

    private var centered: some View {
        GlassEffectContainer(spacing: DS.Spacing.sm) {
            ZStack {
                VStack(spacing: 1) {
                    titleText.font(DS.Typography.uiEmphasis)
                    modelText
                }
                .padding(.horizontal, 64 + DS.Spacing.xl)
                HStack {
                    sidebar
                    Spacer()
                    ringAndMenu
                }
            }
        }
    }

    private var titleGlass: some View {
        GlassEffectContainer(spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                sidebar
                VStack(alignment: .leading, spacing: 0) {
                    titleText.font(DS.Typography.uiEmphasis)
                    modelText
                }
                .padding(.horizontal, DS.Spacing.md)
                .frame(height: DS.IconSize.controlDiameter)
                .glassEffect(.regular.interactive(), in: Capsule())
                Spacer(minLength: 0)
                ringAndMenu
            }
        }
    }

    private var oneBar: some View {
        HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: DS.IconSize.headerIcon, weight: .medium))
                .frame(width: DS.IconSize.controlDiameter, height: DS.IconSize.controlDiameter)
            VStack(alignment: .leading, spacing: 0) {
                titleText.font(DS.Typography.uiEmphasis)
                modelText
            }
            Spacer(minLength: DS.Spacing.sm)
            ContextRing(fraction: fraction).frame(width: DS.IconSize.controlDiameter, height: DS.IconSize.controlDiameter)
            GlassIconMenuPlain(systemName: "ellipsis", label: "More") { Button("New Chat") {} }
        }
        .frame(height: DS.IconSize.controlDiameter + 4)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var modelPill: some View {
        GlassEffectContainer(spacing: DS.Spacing.sm) {
            ZStack {
                HStack(spacing: 4) {
                    Text(verbatim: "Muse Spark 1.3").font(DS.Typography.uiEmphasis).foregroundStyle(theme.textPrimary)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, DS.Spacing.lg)
                .frame(height: DS.IconSize.controlDiameter)
                .glassEffect(.regular.interactive(), in: Capsule())
                HStack {
                    sidebar
                    Spacer()
                    ringAndMenu
                }
            }
        }
    }

    private var buttonsOnly: some View {
        GlassEffectContainer(spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                sidebar
                Spacer()
                ContextRing(fraction: fraction)
                    .frame(width: DS.IconSize.controlDiameter, height: DS.IconSize.controlDiameter)
                    .glassEffect(.regular.interactive(), in: Circle())
                HStack(spacing: 0) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: DS.IconSize.headerIcon, weight: .medium))
                        .frame(width: DS.IconSize.controlDiameter, height: DS.IconSize.controlDiameter)
                    GlassIconMenuPlain(systemName: "ellipsis", label: "More") { Button("New Chat") {} }
                }
                .glassEffect(.regular.interactive(), in: Capsule())
            }
        }
    }
}
#endif
