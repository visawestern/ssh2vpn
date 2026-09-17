import Foundation
import NetworkExtension

/// Точка входа system extension (по темплейту Apple здесь top-level код;
/// @main — эквивалент, immune к parse-as-library режиму драйвера).
/// Вся логика туннеля — в PacketTunnelProvider (общий файл с iOS).
@main
struct PacketTunnelExtMain {
    static func main() {
        autoreleasepool {
            NEProvider.startSystemExtensionMode()
        }
        dispatchMain()
    }
}
