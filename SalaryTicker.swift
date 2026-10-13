import AppKit
import SwiftUI
import ServiceManagement

// MARK: - 설정

struct Config: Equatable {
    var payType: PayType
    var amount: Double         // 입력한 금액 (월급·주급·연봉 중 payType 기준)
    var payday: Int            // 월급·연봉: 매월 급여일 (31 = 말일)
    var payWeekday: Int        // 주급: 급여 요일 (1=일 ... 7=토)
    var startMinutes: Int      // 출근 (자정 기준 분)
    var endMinutes: Int        // 퇴근
    var lunchEnabled: Bool
    var lunchStart: Int
    var lunchEnd: Int
    var workdays: Set<Int>     // Calendar weekday: 1=일 ... 7=토
    var currency: String       // 금액 단위 (환전 없이 기호·소수점만 바뀜)
    var iconMode: IconMode
    var customIcon: String

    static let defaults = Config(
        payType: .monthly, amount: 3_000_000, payday: 25, payWeekday: 6,
        startMinutes: 9 * 60, endMinutes: 18 * 60,
        lunchEnabled: true, lunchStart: 12 * 60, lunchEnd: 13 * 60,
        workdays: [2, 3, 4, 5, 6],
        currency: "KRW",
        iconMode: .phase, customIcon: "banknote"
    )

    static func load() -> Config {
        let d = UserDefaults.standard
        guard d.object(forKey: "monthlySalary") != nil else { return .defaults }
        let payday = d.integer(forKey: "payday")
        return Config(
            payType: PayType(rawValue: d.integer(forKey: "payType")) ?? .monthly,
            amount: d.double(forKey: "monthlySalary"),
            payday: (1...31).contains(payday) ? payday : 25,
            payWeekday: (1...7).contains(d.integer(forKey: "payWeekday")) ? d.integer(forKey: "payWeekday") : 6,
            startMinutes: d.integer(forKey: "startMinutes"),
            endMinutes: d.integer(forKey: "endMinutes"),
            lunchEnabled: d.bool(forKey: "lunchEnabled"),
            lunchStart: d.integer(forKey: "lunchStart"),
            lunchEnd: d.integer(forKey: "lunchEnd"),
            workdays: Set((d.array(forKey: "workdays") as? [Int]) ?? [2, 3, 4, 5, 6]),
            currency: d.string(forKey: "currency") ?? "KRW",
            iconMode: IconMode(rawValue: d.integer(forKey: "iconMode")) ?? .phase,
            customIcon: iconSymbols.contains(d.string(forKey: "customIcon") ?? "") ? d.string(forKey: "customIcon")! : "banknote"
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(payType.rawValue, forKey: "payType")
        d.set(amount, forKey: "monthlySalary")
        d.set(payday, forKey: "payday")
        d.set(payWeekday, forKey: "payWeekday")
        d.set(startMinutes, forKey: "startMinutes")
        d.set(endMinutes, forKey: "endMinutes")
        d.set(lunchEnabled, forKey: "lunchEnabled")
        d.set(lunchStart, forKey: "lunchStart")
        d.set(lunchEnd, forKey: "lunchEnd")
        d.set(Array(workdays), forKey: "workdays")
        d.set(currency, forKey: "currency")
        d.set(iconMode.rawValue, forKey: "iconMode")
        d.set(customIcon, forKey: "customIcon")
    }

    /// 한 급여 기간(월급·연봉은 한 달, 주급은 일주일)에 받는 금액
    var periodPay: Double { payType == .annual ? amount / 12 : amount }

    /// 하루 실근무 초 (점심 제외)
    var dailyWorkSeconds: Double { workedSeconds(atMinute: Double(endMinutes)) }

    /// 출근부터 `minute`(자정 기준, 소수 허용)까지 실제 일한 초
    func workedSeconds(atMinute minute: Double) -> Double {
        let s = Double(startMinutes), e = Double(endMinutes)
        guard e > s else { return 0 }
        var worked = min(max(minute, s), e) - s
        if lunchEnabled, lunchEnd > lunchStart {
            let ls = max(Double(lunchStart), s), le = min(Double(lunchEnd), e)
            if le > ls { worked -= min(max(minute, ls), le) - ls }
        }
        return max(worked, 0) * 60
    }
}

// MARK: - 계산

enum Phase { case beforeWork, working, lunch, afterWork, dayOff }

struct Snapshot: Equatable {
    var accumulated: Double = 0   // 지난 급여일부터 누적
    var today: Double = 0
    var perSecond: Double = 0
    var perHour: Double = 0
    var todayProgress: Double = 0
    var periodProgress: Double = 0
    var phase: Phase = .dayOff
    var workdaysInPeriod = 0
    var daysUntilPayday = 0
    var nextPayday = Date()
}

/// 해당 월의 월급날 (그 달에 그 날짜가 없으면 말일)
func paydayDate(year: Int, month: Int, day: Int, cal: Calendar) -> Date {
    let first = cal.date(from: DateComponents(year: year, month: month, day: 1))!
    let last = cal.range(of: .day, in: .month, for: first)!.count
    return cal.date(from: DateComponents(year: year, month: month, day: min(day, last)))!
}

func compute(_ c: Config, now: Date = Date()) -> Snapshot {
    let cal = Calendar.current
    var snap = Snapshot()
    let today = cal.startOfDay(for: now)

    // 급여 기간: [지난 급여일, 다음 급여일)
    let start: Date, end: Date
    if c.payType == .weekly {
        let back = (cal.component(.weekday, from: today) - c.payWeekday + 7) % 7
        start = cal.date(byAdding: .day, value: -back, to: today)!
        end = cal.date(byAdding: .day, value: 7, to: start)!
    } else {
        let ym = cal.dateComponents([.year, .month], from: now)
        var s = paydayDate(year: ym.year!, month: ym.month!, day: c.payday, cal: cal)
        if s > today {
            let p = cal.dateComponents([.year, .month], from: cal.date(byAdding: .month, value: -1, to: s)!)
            s = paydayDate(year: p.year!, month: p.month!, day: c.payday, cal: cal)
        }
        let n = cal.dateComponents([.year, .month], from: cal.date(byAdding: .month, value: 1, to: s)!)
        start = s
        end = paydayDate(year: n.year!, month: n.month!, day: c.payday, cal: cal)
    }
    snap.nextPayday = end
    snap.daysUntilPayday = cal.dateComponents([.day], from: today, to: end).day ?? 0

    var pastWorkdays = 0
    var day = start
    while day < end {
        if c.workdays.contains(cal.component(.weekday, from: day)) {
            snap.workdaysInPeriod += 1
            if day < today { pastWorkdays += 1 }
        }
        day = cal.date(byAdding: .day, value: 1, to: day)!
    }

    let daily = c.dailyWorkSeconds
    guard snap.workdaysInPeriod > 0, daily > 0 else { return snap }
    let perDay = c.periodPay / Double(snap.workdaysInPeriod)
    snap.perSecond = perDay / daily
    snap.perHour = snap.perSecond * 3600

    let t = cal.dateComponents([.hour, .minute, .second], from: now)
    let minuteNow = Double(t.hour! * 60 + t.minute!) + Double(t.second!) / 60

    if c.workdays.contains(cal.component(.weekday, from: now)) {
        let worked = c.workedSeconds(atMinute: minuteNow)
        snap.today = worked * snap.perSecond
        snap.todayProgress = worked / daily
        if minuteNow < Double(c.startMinutes) { snap.phase = .beforeWork }
        else if minuteNow >= Double(c.endMinutes) { snap.phase = .afterWork }
        else if c.lunchEnabled, minuteNow >= Double(c.lunchStart), minuteNow < Double(c.lunchEnd) { snap.phase = .lunch }
        else { snap.phase = .working }
    }
    snap.accumulated = Double(pastWorkdays) * perDay + snap.today
    snap.periodProgress = c.periodPay > 0 ? snap.accumulated / c.periodPay : 0
    return snap
}

enum PayType: Int, CaseIterable {
    case monthly = 0, weekly = 1, annual = 2
    var label: String {
        switch self {
        case .monthly: "월급"
        case .weekly: "주급"
        case .annual: "연봉"
        }
    }
    /// 급여를 받는 단위 (연봉도 매달 나눠 받는다)
    var payName: String { self == .weekly ? "주급" : "월급" }
}

enum IconMode: Int, CaseIterable {
    case phase = 0, custom = 1, none = 2
    var label: String {
        switch self {
        case .phase: "상태별 자동"
        case .custom: "직접 고르기"
        case .none: "아이콘 없음"
        }
    }
}

/// 메뉴막대에 쓸 수 있는 SF Symbols — 컬러 이모지는 메뉴막대에서 단색으로 뭉개진다
let iconSymbols = [
    "banknote", "wonsign.circle", "dollarsign.circle", "eurosign.circle", "yensign.circle",
    "creditcard", "chart.line.uptrend.xyaxis", "clock", "flame", "sparkles",
]

func symbolImage(_ name: String) -> NSImage? {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
    img?.isTemplate = true
    return img
}

struct Currency: Hashable {
    let code: String, symbol: String, name: String, decimals: Int
    static let all: [Currency] = [
        .init(code: "KRW", symbol: "₩", name: "원", decimals: 0),
        .init(code: "USD", symbol: "$", name: "미국 달러", decimals: 2),
        .init(code: "EUR", symbol: "€", name: "유로", decimals: 2),
        .init(code: "JPY", symbol: "¥", name: "엔", decimals: 0),
        .init(code: "CNY", symbol: "元", name: "위안", decimals: 2),
        .init(code: "GBP", symbol: "£", name: "파운드", decimals: 2),
        .init(code: "CAD", symbol: "C$", name: "캐나다 달러", decimals: 2),
        .init(code: "AUD", symbol: "A$", name: "호주 달러", decimals: 2),
        .init(code: "SGD", symbol: "S$", name: "싱가포르 달러", decimals: 2),
        .init(code: "HKD", symbol: "HK$", name: "홍콩 달러", decimals: 2),
        .init(code: "CHF", symbol: "CHF ", name: "스위스 프랑", decimals: 2),
        .init(code: "VND", symbol: "₫", name: "베트남 동", decimals: 0),
    ]
    static func of(_ code: String) -> Currency { all.first { $0.code == code } ?? all[0] }
}

nonisolated(unsafe) private var formatters: [Int: NumberFormatter] = [:]

func money(_ v: Double, _ code: String) -> String {
    let c = Currency.of(code)
    let f = formatters[c.decimals] ?? {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = c.decimals
        f.maximumFractionDigits = c.decimals
        f.roundingMode = .down
        formatters[c.decimals] = f
        return f
    }()
    return c.symbol + (f.string(from: NSNumber(value: v)) ?? "0")
}

extension Phase {
    var symbol: String {
        switch self {
        case .working: "banknote"
        case .lunch: "fork.knife"
        case .beforeWork: "cup.and.saucer"
        case .afterWork: "house"
        case .dayOff: "beach.umbrella"
        }
    }
    var text: String {
        switch self {
        case .working: "지금 버는 중"
        case .lunch: "점심시간 (잠시 멈춤)"
        case .beforeWork: "출근 전"
        case .afterWork: "오늘 일 끝!"
        case .dayOff: "오늘은 쉬는 날"
        }
    }
}

// MARK: - 모델

/// 1초마다 바뀌는 값은 따로 둔다 — 설정 창이 매초 다시 그려지지 않도록
@MainActor
final class LiveSnapshot: ObservableObject {
    @Published var value = Snapshot()
}

@MainActor
final class Ticker: ObservableObject {
    @Published var config: Config { didSet { config.save(); refresh() } }
    /// 패널이 열려 있을 때만 갱신 — 닫혀 있으면 SwiftUI는 아무 일도 하지 않는다
    let live = LiveSnapshot()
    var panelVisible = false { didSet { if panelVisible { refresh() } } }
    var onTick: ((Snapshot) -> Void)?

    init() { config = Config.load() }

    func refresh() {
        let s = compute(config)
        onTick?(s)
        if panelVisible, s != live.value { live.value = s }
    }
}

// MARK: - 패널 (메뉴막대 클릭 시)

struct PanelView: View {
    @ObservedObject var ticker: Ticker
    @ObservedObject var live: LiveSnapshot
    var openSettings: () -> Void

    var body: some View {
        let s = live.value
        let cur = ticker.config.currency
        let progress = min(max(s.periodProgress, 0), 1)
        VStack(alignment: .leading, spacing: 14) {
            // 헤더
            HStack {
                Text("지난 급여일 이후").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Label(s.phase.text, systemImage: s.phase.symbol)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }

            // 누적 금액
            VStack(alignment: .leading, spacing: 8) {
                Text(money(s.accumulated, cur))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(Color.accentColor.gradient)
                            .frame(width: max(g.size.width * progress, progress > 0 ? 6 : 0))
                    }
                }
                .frame(height: 6)
                HStack {
                    Text("\(ticker.config.payType.payName)의 \(Int(progress * 100))%")
                    Spacer()
                    Text(s.daysUntilPayday == 0 ? "오늘 급여일 🎉" : "급여일까지 D-\(s.daysUntilPayday)")
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            // 통계 카드
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    card("오늘 번 돈", money(s.today, cur), sub: "근무 \(Int(min(s.todayProgress, 1) * 100))%")
                    card("시급", money(s.perHour, cur), sub: "초당 " + perSecondText(s.perSecond, cur))
                }
                GridRow {
                    card("다음 급여일", s.nextPayday.formatted(.dateTime.month().day()),
                         sub: s.nextPayday.formatted(.dateTime.weekday(.wide)))
                    card("급여 기간 근무일", "\(s.workdaysInPeriod)일", sub: ticker.config.payType.label + " 기준")
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button(action: openSettings) {
                    Label("설정", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
                Button { NSApp.terminate(nil) } label: {
                    Label("종료", systemImage: "power").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func card(_ title: String, _ value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(sub).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func perSecondText(_ v: Double, _ code: String) -> String {
        let c = Currency.of(code)
        return c.symbol + String(format: "%.\(c.decimals + 2)f", v)
    }
}

// MARK: - 설정 창

struct TimeField: View {
    let title: String
    @Binding var minutes: Int
    var body: some View {
        let date = Binding<Date>(
            get: { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date())! },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes = c.hour! * 60 + c.minute!
            })
        DatePicker(title, selection: date, displayedComponents: .hourAndMinute)
    }
}

struct SettingsView: View {
    @ObservedObject var ticker: Ticker
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private let dayNames = ["일", "월", "화", "수", "목", "금", "토"]

    private var previewSymbol: String? {
        switch ticker.config.iconMode {
        case .phase: compute(ticker.config).phase.symbol
        case .custom: ticker.config.customIcon
        case .none: nil
        }
    }

    var body: some View {
        Form {
            Section("급여") {
                Picker("급여 종류", selection: $ticker.config.payType) {
                    ForEach(PayType.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("단위", selection: $ticker.config.currency) {
                    ForEach(Currency.all, id: \.code) { c in
                        Text("\(c.symbol.trimmingCharacters(in: .whitespaces))  \(c.name) (\(c.code))").tag(c.code)
                    }
                }
                LabeledContent("\(ticker.config.payType.label) (세후)") {
                    HStack(spacing: 4) {
                        Text(Currency.of(ticker.config.currency).symbol).foregroundStyle(.secondary)
                        TextField("", value: $ticker.config.amount, format: .number)
                            .multilineTextAlignment(.trailing)
                            .labelsHidden()
                    }
                }
                if ticker.config.payType == .weekly {
                    Picker("급여 요일", selection: $ticker.config.payWeekday) {
                        ForEach(1...7, id: \.self) { Text("매주 \(dayNames[$0 - 1])요일").tag($0) }
                    }
                } else {
                    Picker("급여일", selection: $ticker.config.payday) {
                        ForEach(1...30, id: \.self) { Text("매월 \($0)일").tag($0) }
                        Text("매월 말일").tag(31)
                    }
                    if ticker.config.payType == .annual {
                        LabeledContent("한 달 기준") {
                            Text(money(ticker.config.periodPay, ticker.config.currency)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("근무 시간") {
                TimeField(title: "출근", minutes: $ticker.config.startMinutes)
                TimeField(title: "퇴근", minutes: $ticker.config.endMinutes)
                Toggle("점심시간 제외", isOn: $ticker.config.lunchEnabled)
                if ticker.config.lunchEnabled {
                    TimeField(title: "점심 시작", minutes: $ticker.config.lunchStart)
                    TimeField(title: "점심 끝", minutes: $ticker.config.lunchEnd)
                }
                LabeledContent("근무 요일") {
                    HStack(spacing: 4) {
                        ForEach(1...7, id: \.self) { wd in
                            let on = ticker.config.workdays.contains(wd)
                            Button {
                                if on { ticker.config.workdays.remove(wd) } else { ticker.config.workdays.insert(wd) }
                            } label: {
                                Text(dayNames[wd - 1])
                                    .font(.callout.weight(on ? .semibold : .regular))
                                    .foregroundStyle(on ? Color.white : Color.secondary)
                                    .frame(width: 28, height: 24)
                                    .background(on ? Color.accentColor : Color.primary.opacity(0.06),
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Section("메뉴막대 표시") {
                Picker("아이콘", selection: $ticker.config.iconMode) {
                    ForEach(IconMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if ticker.config.iconMode == .phase {
                    LabeledContent("상태") {
                        HStack(spacing: 10) {
                            ForEach([Phase.working, .lunch, .beforeWork, .afterWork, .dayOff], id: \.self) { p in
                                Image(systemName: p.symbol).help(p.text)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                if ticker.config.iconMode == .custom {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                        ForEach(iconSymbols, id: \.self) { name in
                            let on = ticker.config.customIcon == name
                            Button { ticker.config.customIcon = name } label: {
                                Image(systemName: name)
                                    .font(.system(size: 15))
                                    .frame(maxWidth: .infinity, minHeight: 30)
                                    .background(on ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05),
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? Color.accentColor : .clear, lineWidth: 1.5))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                LabeledContent("미리보기") {
                    HStack(spacing: 4) {
                        if let sym = previewSymbol { Image(systemName: sym) }
                        Text(money(compute(ticker.config).accumulated, ticker.config.currency)).monospacedDigit()
                    }
                }
            }
            Section {
                Toggle("로그인 시 자동 실행", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            } footer: {
                Text("지난 급여일부터 일한 시간만큼 쌓여요. (급여 ÷ 이번 급여 기간 근무일 ÷ 하루 근무시간) 연봉은 12로 나눠 매달 받는 것으로 계산해요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 앱

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let ticker = Ticker()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var settingsWindow: NSWindow?
    var timer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PanelView(ticker: ticker, live: ticker.live) { [weak self] in self?.openSettings() })

        statusItem.button?.imagePosition = .imageLeading
        var lastTitle = "", lastSymbol: String?? = .none
        ticker.onTick = { [weak self] s in
            guard let self, let button = self.statusItem.button else { return }
            let c = self.ticker.config
            let sym: String? = switch c.iconMode {
            case .phase: s.phase.symbol
            case .custom: c.customIcon
            case .none: nil
            }
            if lastSymbol != .some(sym) { button.image = sym.flatMap(symbolImage); lastSymbol = .some(sym) }
            let title = (sym == nil ? "" : " ") + money(s.accumulated, c.currency)
            if title != lastTitle { button.title = title; lastTitle = title }
        }
        ticker.refresh()

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ticker.refresh() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t

        if UserDefaults.standard.object(forKey: "monthlySalary") == nil { openSettings() }
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            ticker.panelVisible = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) { ticker.panelVisible = false }

    func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(ticker: ticker)))
            w.title = "월급티커 설정"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
            // 창을 닫으면 SwiftUI 뷰를 통째로 해제해 메모리를 돌려준다
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settingsWindow = nil }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
