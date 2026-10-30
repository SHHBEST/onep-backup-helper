import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    static let brand = Color(red: 0.025, green: 0.45, blue: 0.52)
    static let teal = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.36, green: 0.84, blue: 0.87, alpha: 1)
        }
        return NSColor(srgbRed: 0.025, green: 0.45, blue: 0.52, alpha: 1)
    })
    static let blue = Color(red: 0.18, green: 0.43, blue: 0.88)
    static let muted = Color.secondary
    static let line = Color.primary.opacity(0.065)
    static let radius: CGFloat = 26
}

struct Atmosphere: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                (scheme == .dark ? Color(red: 0.07, green: 0.12, blue: 0.17) : Color(red: 0.94, green: 0.97, blue: 0.99))
                Ellipse().fill(Color.cyan.opacity(scheme == .dark ? 0.13 : 0.15))
                    .frame(width: 660, height: 540).blur(radius: 85)
                    .position(x: proxy.size.width * 0.68, y: proxy.size.height * 0.42)
                Ellipse().fill(Color.blue.opacity(scheme == .dark ? 0.11 : 0.08))
                    .frame(width: 580, height: 370).blur(radius: 90)
                    .position(x: proxy.size.width * 0.98, y: proxy.size.height)
                Ellipse().fill(Color.white.opacity(scheme == .dark ? 0.035 : 0.7))
                    .frame(width: 520, height: 600).blur(radius: 80)
                    .position(x: proxy.size.width * 0.44, y: 0)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 17).padding(.vertical, 11)
            .background(.primary.opacity(configuration.isPressed ? 0.09 : 0.045), in: Capsule())
            .contentShape(Capsule())
    }
}

struct AccentButton: View {
    let title: String
    var symbol = "arrow.right"
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(title)
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 23).padding(.vertical, 12)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(Theme.teal)
        .disabled(disabled)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appearance") private var appearance = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            Atmosphere()
            HStack(spacing: 0) {
                Sidebar(model: model).frame(width: 206)
                Rectangle().fill(Theme.line).frame(width: 1)
                VStack(spacing: 0) {
                    header
                    ScrollView {
                        VStack(spacing: 22) {
                            if let result = model.result {
                                ResultView(model: model, result: result)
                                    .transition(.opacity)
                            } else {
                                FileWorkspace(model: model)
                                workflow
                            }
                            safetyNote
                        }
                        .frame(maxWidth: 780)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 26).padding(.bottom, 12)
                    }
                    .scrollIndicators(.hidden)
                    footer
                }
                .padding(.horizontal, 35).padding(.top, 45).padding(.bottom, 23)
            }
        }
        .frame(minWidth: 920, minHeight: 690)
        .tint(Theme.teal)
        .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.result != nil)
        .sheet(item: $model.panel) { panel in
            if panel == .keys { KeyView(model: model) } else { GuideView() }
        }
        .alert(item: Binding(get: { model.panel == nil ? model.notice : nil }, set: { model.notice = $0 })) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("知道了")))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !model.busy { Task { await model.refresh() } }
        }
        .onAppear { AppDelegate.showMainWindow = { openWindow(id: "main") } }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 9) {
                Text(model.operation.title)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .tracking(-0.7)
                Text(model.operation.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Label("仅本机处理", systemImage: "network.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.teal)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
                .help("App 不上传文件，也不访问网络。")
            Menu {
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag(0)
                    Text("浅色").tag(1)
                    Text("深色").tag(2)
                }
            } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 13)).frame(width: 24, height: 27)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("切换外观").help("跟随系统、浅色或深色")
        }
    }

    private var workflow: some View {
        HStack(alignment: .top, spacing: 12) {
            workflowStep("1", "选择项目", model.operation == .encrypt ? "文件或整个文件夹" : "需要处理的 age 密文")
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary).padding(.top, 6)
            workflowStep("2", model.operation == .verify ? "核对记录" : model.operation == .encrypt ? "公钥加密" : "私钥解密",
                         model.operation == .verify ? "对照旁边的 SHA256" : model.operation == .encrypt ? "文件夹自动打包 ZIP" : "文件夹自动还原")
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary).padding(.top, 6)
            workflowStep("3", model.operation == .verify ? "查看结果" : "保存结果",
                         model.operation == .verify ? "仍建议定期试解密" : "同目录保存，不覆盖旧文件")
        }
        .padding(.horizontal, 6).padding(.top, 2)
    }

    private func workflowStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(number).font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.teal).frame(width: 23, height: 23)
                .background(Theme.teal.opacity(0.07), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var safetyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.operation == .decrypt ? "exclamationmark.shield" : "info.circle")
                .font(.system(size: 14)).foregroundStyle(model.operation == .decrypt ? .orange : Theme.teal)
            Text(model.operation.note).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(15)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 13))
    }

    private var footer: some View {
        HStack {
            Label("age v1.3.2", systemImage: "lock.shield")
            Text("开放格式，长期可恢复")
            Spacer()
            Button("恢复前要知道什么") { model.panel = .guide }
                .buttonStyle(.plain).foregroundStyle(Theme.teal).disabled(model.busy)
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(.top, 19)
    }
}

struct Sidebar: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Theme.brand.gradient)
                    Image(systemName: "lock.shield.fill").font(.system(size: 21)).foregroundStyle(.white)
                }.frame(width: 39, height: 43)
                VStack(alignment: .leading, spacing: 4) {
                    Text("1P 备份助手").font(.system(size: 14, weight: .semibold))
                    Text("留一份安心").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 19).padding(.bottom, 39)

            Text("备份工具").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                .padding(.leading, 24).padding(.bottom, 12)
            VStack(spacing: 7) {
                ForEach(Operation.allCases) { mode in
                    Button { model.changeOperation(mode) } label: {
                        HStack(spacing: 11) {
                            Image(systemName: mode.symbol).font(.system(size: 15, weight: .medium)).frame(width: 21)
                            Text(mode.title).font(.system(size: 12, weight: model.operation == mode ? .semibold : .medium))
                            Spacer()
                            if model.operation == mode {
                                Circle().fill(Theme.teal).frame(width: 5, height: 5)
                            }
                        }
                        .foregroundStyle(model.operation == mode ? Theme.teal : .primary.opacity(0.65))
                        .padding(.horizontal, 14).frame(height: 43)
                        .background {
                            if model.operation == mode {
                                RoundedRectangle(cornerRadius: 15).fill(.white.opacity(scheme == .dark ? 0.06 : 0.45))
                                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 15))
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain).disabled(model.busy)
                    .accessibilityIdentifier("nav-\(mode.rawValue)")
                }
            }.padding(.horizontal, 12)

            Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 23).padding(.vertical, 24)
            sidebarUtility("密钥与恢复", "key.horizontal") { model.panel = .keys }
            sidebarUtility("使用指南", "book.closed") { model.panel = .guide }
            Spacer(minLength: 25)

            Button { model.panel = .keys } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Circle().fill(model.hasPublic && model.hasPrivate ? Theme.teal : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(model.keySummary).font(.system(size: 10, weight: .medium))
                    }
                    Text(model.hasPrivate ? "私钥只在本机读取\n请记得保管离机副本" : "加密之前，先为恢复做好准备")
                        .font(.system(size: 10)).lineSpacing(4).foregroundStyle(.secondary)
                    HStack {
                        Text("管理密钥").font(.system(size: 10, weight: .medium))
                        Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                    }.foregroundStyle(Theme.teal)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 17))
            }
            .buttonStyle(.plain).disabled(model.busy)
            .padding(.horizontal, 15)
            Text("属于你，也只属于你。")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .padding(.leading, 24).padding(.top, 22)
        }
        .padding(.top, 56).padding(.bottom, 26)
        .background(.ultraThinMaterial)
    }

    private func sidebarUtility(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 25).padding(.vertical, 11)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.busy)
    }
}

struct VaultIllustration: View {
    var symbol: String = "lock.fill"
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            Ellipse().fill(Theme.teal.opacity(0.13)).frame(width: 130, height: 22).blur(radius: 14).offset(y: 68)
            RoundedRectangle(cornerRadius: 28)
                .fill(LinearGradient(colors: [Color.cyan.opacity(0.12), Theme.blue.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 102, height: 108).rotationEffect(.degrees(-13)).offset(x: -17, y: -5)
                .overlay {
                    RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.5), lineWidth: 1)
                        .frame(width: 102, height: 108).rotationEffect(.degrees(-13)).offset(x: -17, y: -5)
                }
            RoundedRectangle(cornerRadius: 28)
                .fill(LinearGradient(colors: [Color.white.opacity(0.85), Color.cyan.opacity(0.13)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 108, height: 112).rotationEffect(.degrees(10)).offset(x: 12, y: -4)
                .shadow(color: Theme.teal.opacity(0.08), radius: 8, y: 7)
            ZStack {
                RoundedRectangle(cornerRadius: 27)
                    .fill(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().stroke(Theme.teal.opacity(0.16), lineWidth: 1).padding(19)
                Circle().fill(.white.opacity(0.25)).padding(24)
                Image(systemName: symbol)
                    .font(.system(size: 29, weight: .medium)).foregroundStyle(Theme.brand)
                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.8))
                    .frame(width: 5, height: 20).offset(x: -46, y: -19)
                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.8))
                    .frame(width: 5, height: 20).offset(x: -46, y: 20)
            }
            .frame(width: 112, height: 116)
            .glassEffect(reduceTransparency ? .identity : .regular.tint(.cyan.opacity(0.08)), in: RoundedRectangle(cornerRadius: 27))
            .overlay(RoundedRectangle(cornerRadius: 27).stroke(.white.opacity(0.7), lineWidth: 1))
            .shadow(color: Theme.teal.opacity(0.12), radius: 18, y: 13)
        }
        .frame(width: 195, height: 160)
        .accessibilityHidden(true)
    }
}

struct FileWorkspace: View {
    @ObservedObject var model: AppModel
    @State private var targeted = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 0) {
            if let file = model.selection {
                selectedFile(file)
            } else {
                VaultIllustration(symbol: model.operation == .encrypt ? "lock.fill" : model.operation == .decrypt ? "lock.open.fill" : "checkmark.shield.fill")
                    .padding(.top, 24)
                Text(model.operation.dropTitle)
                    .font(.system(size: 21, weight: .medium, design: .rounded)).tracking(-0.5)
                    .padding(.top, 3)
                Text(model.operation.dropHint).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 12)
                Button { model.chooseFile() } label: {
                    Label(model.operation == .encrypt ? "选择文件或文件夹" : "选择文件", systemImage: "plus").padding(.horizontal, 16).padding(.vertical, 8)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.glass).buttonBorderShape(.capsule).padding(.top, 23)
                .accessibilityIdentifier("choose-file")
                HStack(spacing: 5) {
                    Image(systemName: "command").font(.system(size: 9))
                    Text("O 选择文件")
                }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 13).padding(.bottom, 27)
            }
        }
        .frame(maxWidth: .infinity).frame(minHeight: 350)
        .background((scheme == .dark ? Color.white.opacity(0.035) : Color.white.opacity(0.63)), in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(targeted ? Theme.teal.opacity(0.6) : .white.opacity(scheme == .dark ? 0.12 : 0.9), lineWidth: targeted ? 2 : 1)
        }
        .shadow(color: Theme.teal.opacity(0.035), radius: 30, y: 12)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.busy else { return false }
            model.accept(urls)
            return true
        } isTargeted: { targeted = $0 }
    }

    private func selectedFile(_ file: URL) -> some View {
        VStack(spacing: 19) {
            ZStack {
                RoundedRectangle(cornerRadius: 21).fill(Theme.teal.opacity(0.07)).frame(width: 76, height: 84)
                Image(systemName: model.selectionIsFolder ? "folder" : model.operation == .encrypt ? "doc.zipper" : "lock.doc")
                    .font(.system(size: 34, weight: .light)).foregroundStyle(Theme.teal)
            }.padding(.top, 28)
            VStack(spacing: 8) {
                Text(file.lastPathComponent).font(.system(size: 17, weight: .semibold))
                    .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center).textSelection(.enabled)
                Text("\(model.fileSize) · \(file.deletingLastPathComponent().lastPathComponent)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }.padding(.horizontal, 25)
            if model.busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.taskLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            } else {
                HStack(spacing: 12) {
                    Button("重新选择") { model.chooseFile() }.buttonStyle(QuietButtonStyle())
                    AccentButton(title: model.operation.action, disabled: !model.canRun) { model.perform() }
                        .accessibilityIdentifier("perform-operation")
                }
                if !model.canRun {
                    Button(model.operation == .decrypt ? "缺少私钥，前往恢复" : "先配置密钥，再开始备份") { model.panel = .keys }
                        .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Theme.teal)
                }
            }
            Text(model.operation == .verify ? "仅计算摘要，不读取私钥" : "结果保存在原文件旁边，不覆盖已有文件")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.bottom, 23)
        }
    }
}

struct ResultView: View {
    @ObservedObject var model: AppModel
    let result: JobResult
    @State private var copied = false
    var body: some View {
        VStack(spacing: 19) {
            ZStack {
                Circle().fill(Theme.teal.opacity(0.08)).frame(width: 76, height: 76)
                Image(systemName: "checkmark.seal.fill").font(.system(size: 43, weight: .light)).foregroundStyle(Theme.teal)
            }.padding(.top, 25)
            VStack(spacing: 9) {
                Text(result.operation == .encrypt ? "备份已加密" : result.operation == .decrypt ? "备份已解密" : "校验记录一致")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                Text(result.operation == .encrypt ? (result.isFolder ? "文件夹已打包为 ZIP 并加密，解密时会自动还原文件夹。" : "密文与校验文件已保存，可以一起备份到别处。") : result.operation == .decrypt ? (result.isFolder ? "文件夹已还原，里面的文件均为明文，请妥善保管。" : "这是明文文件，请妥善处理并及时清理。") : "文件与这份 SHA256 记录一致；仍需另行验证恢复能力。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Image(systemName: result.operation == .decrypt && result.isFolder ? "folder" : result.operation == .decrypt ? "doc" : "lock.doc").font(.system(size: 24)).foregroundStyle(Theme.teal)
                VStack(alignment: .leading, spacing: 5) {
                    Text(result.file.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(result.file.deletingLastPathComponent().path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(15).background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 28)
            if let digest = result.digest {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("SHA256").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button(copied ? "已复制" : "复制摘要") { model.copy(digest); copied = true }
                            .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Theme.teal)
                    }
                    Text(digest).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 31)
            }
            HStack(spacing: 12) {
                Button("继续处理文件") { model.result = nil; model.selection = nil }
                    .buttonStyle(QuietButtonStyle())
                AccentButton(title: "在访达中显示", symbol: "folder") { model.reveal(result.file) }
            }.padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(.white.opacity(0.5), lineWidth: 1))
    }
}

struct KeyView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label("密钥与恢复", systemImage: "key.horizontal").font(.system(size: 23, weight: .semibold, design: .rounded))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 29, height: 29) }
                    .buttonStyle(.glass).disabled(model.busy).accessibilityLabel("关闭密钥管理")
            }
            Text("公钥负责加密，私钥负责找回。备份文件和私钥，请分开保管。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                keyState("公钥", present: model.hasPublic, detail: "可公开，用于加密")
                keyState("私钥", present: model.hasPrivate, detail: "必须备份，不要分享")
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("当前公钥").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button(copied ? "已复制" : "复制公钥") { model.copy(model.publicKey); copied = true }
                        .buttonStyle(.plain).foregroundStyle(Theme.teal).font(.system(size: 11)).disabled(!model.hasPublic)
                }
                Text(model.publicKey.isEmpty ? "尚未配置公钥" : model.publicKey)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().opacity(0.6)
                Text(model.supportPath.isEmpty ? "密钥文件夹尚未就绪" : model.supportPath)
                    .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                Button { model.chooseKeyLocation() } label: {
                    Label("更改密钥位置…", systemImage: "folder.badge.gearshape")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.teal).disabled(model.busy)
                .accessibilityIdentifier("change-key-location")
            }
            .padding(17).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 17))
            HStack(spacing: 12) {
                if !model.hasPublic {
                    AccentButton(title: model.hasPrivate ? "从私钥恢复公钥" : "生成密钥", symbol: "key", disabled: model.busy) { model.generateKeys() }
                }
                Button("打开密钥文件夹") { model.reveal(URL(fileURLWithPath: model.supportPath)) }
                    .buttonStyle(QuietButtonStyle()).disabled(model.busy || (!model.hasPublic && !model.hasPrivate))
                Spacer(minLength: 0)
                Button { model.selftest() } label: { Label("运行自检", systemImage: "checkmark.shield") }
                    .buttonStyle(QuietButtonStyle()).disabled(model.busy || !model.hasPublic || !model.hasPrivate)
            }
            if model.busy {
                HStack { ProgressView().controlSize(.small); Text(model.taskLabel).font(.system(size: 11)) }
            } else if let feedback = model.keyFeedback {
                Label(feedback, systemImage: model.selftestPassed ? "checkmark.circle" : "info.circle")
                    .font(.system(size: 11)).foregroundStyle(Theme.teal).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Menu("导出密钥 .txt") {
                    Button("导出公钥 .txt…") { model.exportKeyText(privateKey: false) }.disabled(!model.hasPublic)
                    Button("导出私钥 .txt…") { model.exportKeyText(privateKey: true) }.disabled(!model.hasPrivate)
                }
                .fixedSize().disabled(model.busy)
                Button { model.importKeyText() } label: { Label("导入密钥文本…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(QuietButtonStyle()).disabled(model.busy)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("请为恢复留一条独立的路", systemImage: "externaldrive.badge.checkmark")
                    .font(.system(size: 12, weight: .semibold))
                Text("将 private.key 另存到移动硬盘和异地介质。离机副本建议用独立强口令加密，云端不要上传明文私钥。恢复口令不要只存于这份密码库中。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                if model.hasPublic && !model.hasPrivate {
                    Text("这里只能加密，不能恢复。请找回原私钥；新密钥无法解密旧备份。")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                }
            }
            .padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.teal.opacity(0.055), in: RoundedRectangle(cornerRadius: 17))
        }
        .padding(30).frame(width: 620)
        .background(.regularMaterial)
        .interactiveDismissDisabled(model.busy)
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("知道了")))
        }
    }

    private func keyState(_ title: String, present: Bool, detail: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: present ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 20)).foregroundStyle(present ? Theme.teal : .secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(title)\(present ? "已配置" : "未配置")").font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(15).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct GuideView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("让备份，也能被找回。")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(.glass)
            }
            guideRow("square.and.arrow.up", "文件与文件夹，都能备份", "在「加密备份」选择文件或整个文件夹。文件夹自动打包 ZIP 再加密，解密时还原文件夹。请避开云同步的明文目录。")
            guideRow("externaldrive", "两份文件，一起保管", "将 .age 与 .sha256 一起复制到 NAS 或其他介质。原始明文不会自动删除。")
            guideRow("key.horizontal", "私钥要有离机副本", "私钥丢失，备份也无法恢复。为离机私钥加上独立口令，并将恢复口令保存在密码库以外。")
            guideRow("arrow.counterclockwise", "亲手试一次恢复", "将备份放进空文件夹，切换到「解密恢复」。首次使用、换机或换密钥后，请确认离机私钥副本也能恢复。")
            guideRow("checkmark.shield", "定期校验，也定期解密", "SHA256 可发现与记录不一致的文件，但不能防止密文和记录同时被替换，也不能证明私钥可用。")
            Text("全部操作在本机完成 · 无网络请求 · 不自动删除文件 · 不覆盖已有备份")
                .font(.system(size: 10)).foregroundStyle(Theme.teal)
        }
        .padding(32).frame(width: 620).background(.regularMaterial)
    }

    private func guideRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 17) {
            Image(systemName: symbol).font(.system(size: 21, weight: .light))
                .foregroundStyle(Theme.teal).frame(width: 28).padding(.top, 2)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            }
        }
    }
}
