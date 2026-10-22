import Foundation

/// 写操作前的一道型号门禁：一代模块（QDC507 / EG25）和二代（IG832）严格分开。
/// 识别不出型号时一律按「不允许写」处理 —— 宁可让客户多插一次线，
/// 也不能把一代专属的组件写进别的模块。
public enum ModuleGate {
    /// 一代基带的身份关键词（ATI / QGMR 里出现任一即认）。
    public static let generationOneKeywords = ["QDC507", "EG25"]
    /// 一代通话组件（qdc507_*.ko）只在这条内核线上验证过。
    public static let voiceKernelPrefix = "3.18.44"

    /// model / revision / build 任一字段命中一代关键词即放行；全部为空或
    /// 都不命中按「未识别」拒绝。
    public static func isGenerationOne(model: String?,
                                       revision: String? = nil,
                                       build: String? = nil) -> Bool {
        let fields = [model, revision, build]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
        guard !fields.isEmpty else { return false }
        return fields.contains { text in
            generationOneKeywords.contains { text.contains($0) }
        }
    }

    /// 通话组件安装前的内核校验：必须落在 3.18.44 线上。
    public static func voiceKernelSupported(_ kernel: String?) -> Bool {
        guard let kernel = kernel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !kernel.isEmpty else { return false }
        return kernel.hasPrefix(voiceKernelPrefix)
    }
}

/// 门禁拒绝时的错误信息（给界面和命令行共用）。
public enum ModuleGateError: Error, LocalizedError, Equatable {
    case unsupportedModule(model: String)
    case unsupportedKernel(kernel: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedModule(let model):
            let shown = model.isEmpty ? "未识别" : model
            return "这不是一代模块（QDC507/EG25，识别到：\(shown)）。"
                + "为避免损坏模块，已拒绝写入；只允许诊断。"
        case .unsupportedKernel(let kernel):
            let shown = kernel.isEmpty ? "未读到" : kernel
            return "模块内核与通话组件不匹配（需要 \(ModuleGate.voiceKernelPrefix).*，"
                + "识别到：\(shown)）。已拒绝安装。"
        }
    }
}

/// 从 AT 会话读身份并执行门禁。
public enum ModuleIdentityGate {
    public static func read(_ session: ATSession) throws -> ModuleIdentity {
        let ati = try session.send("ATI", timeout: 5)
        let revision = try? session.send("AT+QGMR", timeout: 5)
        return ATParsers.identity(fromATI: ati, revision: revision)
    }

    /// 读身份 → 必须识别为一代，否则抛错。所有会改模块的入口都先走这里。
    @discardableResult
    public static func requireGenerationOne(_ session: ATSession) throws -> ModuleIdentity {
        let identity = try read(session)
        let supported = ModuleGate.isGenerationOne(
            model: identity.model,
            revision: identity.revision,
            build: identity.firmwareBuild)
        guard supported else {
            throw ModuleGateError.unsupportedModule(model: identity.model)
        }
        return identity
    }
}
