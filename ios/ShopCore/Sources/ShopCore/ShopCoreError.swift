/// ShopCore 的统一错误。`invalid` 对应服务器的 `rejected: invalid`（§4.4、§5.0）：
/// 模型层在构造时就拒掉超限或格式不对的输入，界面拿到错误后不让提交。
public enum ShopCoreError: Error, Equatable, Sendable {
    case invalid(String)
}

@inline(__always)
func invalid(_ reason: String) -> ShopCoreError { .invalid(reason) }
